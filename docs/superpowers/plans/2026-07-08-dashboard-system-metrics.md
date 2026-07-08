# Dashboard System Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add host-level system metrics (load average, memory usage, uptime, active `rclone` process count) to the backup monitoring dashboard, collected in the same 2-minute cycle as everything else.

**Architecture:** `monitoring/backup_status.sh` (runs via cron on arch03/04/05) gains a new data-collection block that reads `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime`, and `pgrep -c -x rclone`, and folds the result into a new `system` key in the JSON it already writes to `/var/lib/backup-status/status.json`. No new cron jobs, timers, or SSH forced-commands — this rides the existing collection/aggregation/render pipeline unchanged. `monitoring/dashboard.html` gains a new rendering block on each host card to display it.

**Tech Stack:** bash, python3 (already a dependency of `backup_status.sh` for JSON assembly), vanilla JS (`monitoring/dashboard.html` has no framework/build step).

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-07-08-dashboard-system-metrics-design.md` — read this first for the full rationale.
- Data collection must use `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime` directly (not `top`/`vmstat` output parsing — those hosts run varying util-linux versions with inconsistent batch-mode output).
- Memory calculation uses `MemAvailable` (not `MemFree`) from `/proc/meminfo`.
- Process count uses `pgrep -c -x rclone` (exact name match, matches the `pkill -x rclone` convention already used in `backup/rclone_backup_unified_v4.0.0.sh`'s `ceph_watchdog_recover()` — never `-f`).
- If any part of the new collection fails, the whole `system` key becomes JSON `null` for that cycle — the script must never fail/exit non-zero because of this new block (matches the existing `last_success: null`-on-failure pattern already in the file).
- No color thresholds/alerting for these metrics in the dashboard — purely informational display, per the approved design.
- New JSON key is called exactly `system`, sibling to the existing `disk` key, with sub-keys exactly `load_avg` (array of 3 floats), `memory` (`{used_gb, total_gb, percent}`), `boot_at` (ISO-8601 string, same format as other timestamps in this file, i.e. `date -Iseconds`-compatible with colon offset), `rclone_processes` (int).

---

### Task 1: Collect and emit system metrics in backup_status.sh

**Files:**
- Modify: `monitoring/backup_status.sh:106-153` (insert new collection block after the existing disk block, before `RUNNING_ACTIVE`; extend the final python JSON-assembly heredoc and its argv)
- Test: none exist for this repo (ops shell scripts, no test framework) — verification is via direct execution, both standalone (this task) and live-host (post-merge, done by whoever deploys)

**Interfaces:**
- Produces: a new bash variable `SYSTEM_JSON` holding either a JSON object string (`{"load_avg": [...], "memory": {...}, "boot_at": "...", "rclone_processes": N}`) or the literal string `null`, ready to be passed as a positional arg into the existing final python heredoc at `monitoring/backup_status.sh` (the block starting `python3 - "$HOST" "$GENERATED_AT" ...` around line 117).
- Consumes: `$GENERATED_AT` (already computed earlier in the file, line 20) — needed to compute `boot_at` from uptime seconds.

- [ ] **Step 1: Write a standalone verification script exercising the exact new logic**

Create `/tmp/test_system_metrics.sh` (scratch file, not part of the repo) with exactly the block you will add to `backup_status.sh` in Step 3, wired to print `$SYSTEM_JSON` at the end:

```bash
#!/bin/bash
set -uo pipefail
GENERATED_AT=$(date -Iseconds)

LOAD1=0; LOAD5=0; LOAD15=0
LOADAVG_LINE=$(cat /proc/loadavg 2>/dev/null)
if [[ -n "$LOADAVG_LINE" ]]; then
  read -r LOAD1 LOAD5 LOAD15 _ < <(echo "$LOADAVG_LINE")
fi

MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
MEM_TOTAL_KB=${MEM_TOTAL_KB:-0}
MEM_AVAIL_KB=${MEM_AVAIL_KB:-0}

UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
UPTIME_SECONDS=${UPTIME_SECONDS:-0}

RCLONE_PROCESSES=$(pgrep -c -x rclone 2>/dev/null)
RCLONE_PROCESSES=${RCLONE_PROCESSES:-0}

SYSTEM_JSON=$(python3 - "$LOAD1" "$LOAD5" "$LOAD15" "$MEM_TOTAL_KB" "$MEM_AVAIL_KB" \
  "$UPTIME_SECONDS" "$RCLONE_PROCESSES" "$GENERATED_AT" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta

load1, load5, load15, total_kb, avail_kb, uptime_s, rclone_procs, generated_at = sys.argv[1:9]

try:
    total_kb = int(total_kb)
    avail_kb = int(avail_kb)
    if total_kb <= 0:
        raise ValueError("MemTotal missing or zero")
    used_gb = round((total_kb - avail_kb) / 1024 / 1024, 1)
    total_gb = round(total_kb / 1024 / 1024, 1)
    percent = round((total_kb - avail_kb) / total_kb * 100)

    boot_dt = datetime.fromisoformat(generated_at) - timedelta(seconds=int(uptime_s))
    boot_at = boot_dt.isoformat()

    data = {
        "load_avg": [float(load1), float(load5), float(load15)],
        "memory": {"used_gb": used_gb, "total_gb": total_gb, "percent": percent},
        "boot_at": boot_at,
        "rclone_processes": int(rclone_procs),
    }
    print(json.dumps(data))
except Exception:
    print("null")
PYEOF
)

echo "$SYSTEM_JSON"
```

- [ ] **Step 2: Run it and verify valid JSON with the expected 4 keys**

Run: `bash /tmp/test_system_metrics.sh | python3 -c "import json,sys; d=json.load(sys.stdin); assert set(d.keys())=={'load_avg','memory','boot_at','rclone_processes'}, d.keys(); assert len(d['load_avg'])==3; assert set(d['memory'].keys())=={'used_gb','total_gb','percent'}; print('OK', d)"`

Expected: prints `OK {...}` with real-looking values (e.g. `load_avg` three small floats, `memory.total_gb` matching this machine's actual RAM, `rclone_processes` almost certainly `0` in a dev sandbox — that's correct, not a bug).

- [ ] **Step 3: Test the null-fallback path**

Run: `bash -c 'GENERATED_AT=$(date -Iseconds); MEM_TOTAL_KB=0; MEM_AVAIL_KB=0; python3 -c "
import json
from datetime import datetime, timedelta
total_kb, avail_kb = 0, 0
try:
    if total_kb <= 0:
        raise ValueError(\"MemTotal missing or zero\")
    print(\"should not reach here\")
except Exception:
    print(\"null\")
"'`

Expected: prints `null` — confirms the try/except in the Step 1 python block correctly falls back to `null` when `MemTotal` is `0` (simulating `/proc/meminfo` being unreadable), rather than crashing or emitting garbage.

- [ ] **Step 4: Insert the real block into backup_status.sh**

Edit `monitoring/backup_status.sh`. Insert the following block immediately after line 111 (`DISK_AVAIL=${DISK_AVAIL:-"?"}`) and before line 113 (`RUNNING_ACTIVE=false`):

```bash
# --- system: load average, память, аптайм, кол-во процессов rclone ---
LOAD1=0; LOAD5=0; LOAD15=0
LOADAVG_LINE=$(cat /proc/loadavg 2>/dev/null)
if [[ -n "$LOADAVG_LINE" ]]; then
  read -r LOAD1 LOAD5 LOAD15 _ < <(echo "$LOADAVG_LINE")
fi

MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
MEM_TOTAL_KB=${MEM_TOTAL_KB:-0}
MEM_AVAIL_KB=${MEM_AVAIL_KB:-0}

UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
UPTIME_SECONDS=${UPTIME_SECONDS:-0}

RCLONE_PROCESSES=$(pgrep -c -x rclone 2>/dev/null)
RCLONE_PROCESSES=${RCLONE_PROCESSES:-0}

SYSTEM_JSON=$(python3 - "$LOAD1" "$LOAD5" "$LOAD15" "$MEM_TOTAL_KB" "$MEM_AVAIL_KB" \
  "$UPTIME_SECONDS" "$RCLONE_PROCESSES" "$GENERATED_AT" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta

load1, load5, load15, total_kb, avail_kb, uptime_s, rclone_procs, generated_at = sys.argv[1:9]

try:
    total_kb = int(total_kb)
    avail_kb = int(avail_kb)
    if total_kb <= 0:
        raise ValueError("MemTotal missing or zero")
    used_gb = round((total_kb - avail_kb) / 1024 / 1024, 1)
    total_gb = round(total_kb / 1024 / 1024, 1)
    percent = round((total_kb - avail_kb) / total_kb * 100)

    boot_dt = datetime.fromisoformat(generated_at) - timedelta(seconds=int(uptime_s))
    boot_at = boot_dt.isoformat()

    data = {
        "load_avg": [float(load1), float(load5), float(load15)],
        "memory": {"used_gb": used_gb, "total_gb": total_gb, "percent": percent},
        "boot_at": boot_at,
        "rclone_processes": int(rclone_procs),
    }
    print(json.dumps(data))
except Exception:
    print("null")
PYEOF
)

```

- [ ] **Step 5: Wire SYSTEM_JSON into the final JSON assembly**

Edit `monitoring/backup_status.sh` lines 116-153 (the `STATUS_TMP=...` block through the end of the python heredoc). Change the python3 invocation's argument list (originally lines 117-119) from:

```bash
STATUS_TMP="$STATUS_FILE.tmp.$$"
python3 - "$HOST" "$GENERATED_AT" "$LAST_SUCCESS_JSON" "$RUNNING_ACTIVE" "$STARTED_AT" \
  "$CHECKS_DONE" "$CHECKS_TOTAL" "$PERCENT" "$CEPH_MOUNTED" "$CEPH_ACCESSIBLE" \
  "$LAST_MDS_INCIDENT" "$DISK_USED_PERCENT" "$DISK_AVAIL" > "$STATUS_TMP" <<'PYEOF'
```

to:

```bash
STATUS_TMP="$STATUS_FILE.tmp.$$"
python3 - "$HOST" "$GENERATED_AT" "$LAST_SUCCESS_JSON" "$RUNNING_ACTIVE" "$STARTED_AT" \
  "$CHECKS_DONE" "$CHECKS_TOTAL" "$PERCENT" "$CEPH_MOUNTED" "$CEPH_ACCESSIBLE" \
  "$LAST_MDS_INCIDENT" "$DISK_USED_PERCENT" "$DISK_AVAIL" "$SYSTEM_JSON" > "$STATUS_TMP" <<'PYEOF'
```

Then, inside that same heredoc, change the python argv-unpacking line (originally lines 122-124) from:

```python
(host, generated_at, last_success_json, running_active, started_at,
 checks_done, checks_total, percent, ceph_mounted, ceph_accessible,
 last_mds, disk_pct, disk_avail) = sys.argv[1:14]
```

to:

```python
(host, generated_at, last_success_json, running_active, started_at,
 checks_done, checks_total, percent, ceph_mounted, ceph_accessible,
 last_mds, disk_pct, disk_avail, system_json) = sys.argv[1:15]
```

Add a new line right after the existing `last_success = json.loads(...)` line (originally line 126):

```python
last_success = json.loads(last_success_json) if last_success_json != "null" else None
system = json.loads(system_json) if system_json != "null" else None
```

And add `"system": system,` as a new key in the `data = {...}` dict (originally lines 137-151), placed after the existing `"disk": {...}` entry:

```python
data = {
    "host": host,
    "generated_at": generated_at,
    "last_success": last_success,
    "running_now": running_now,
    "ceph": {
        "mounted": ceph_mounted == "true",
        "accessible": ceph_accessible == "true",
        "last_mds_incident": None if last_mds == "null" else last_mds,
    },
    "disk": {
        "backup_used_percent": int(disk_pct) if disk_pct.isdigit() else None,
        "backup_avail_human": disk_avail,
    },
    "system": system,
}
```

- [ ] **Step 6: Syntax-check the modified script**

Run: `bash -n monitoring/backup_status.sh`
Expected: no output, exit code 0.

- [ ] **Step 7: Clean up the scratch test script**

Run: `rm -f /tmp/test_system_metrics.sh`

- [ ] **Step 8: Commit**

```bash
git add monitoring/backup_status.sh
git commit -m "Add system metrics (load avg, memory, uptime, rclone process count) to backup_status.sh"
```

---

### Task 2: Render system metrics on the dashboard

**Files:**
- Modify: `monitoring/dashboard.html:70-138` (add a `humanDuration()` helper near `humanAgo()`; extend `renderCard()` to render the new `system` block)

**Interfaces:**
- Consumes: `data.system` from the per-host object in `status.json`, shaped exactly as Task 1 produces: `{load_avg: [number, number, number], memory: {used_gb: number, total_gb: number, percent: number}, boot_at: string, rclone_processes: number} | null`.
- Produces: nothing consumed by later tasks — this is the last task in the plan.

- [ ] **Step 1: Add a `humanDuration` helper next to the existing `humanAgo`**

Edit `monitoring/dashboard.html`. Insert immediately after the existing `humanAgo` function (after line 68, i.e. right after its closing `}`):

```javascript
function humanDuration(iso) {
  if (!iso) return "нет данных";
  const totalHours = hoursSince(iso);
  const days = Math.floor(totalHours / 24);
  const hours = Math.round(totalHours % 24);
  if (days > 0) return `${days} дн ${hours} ч`;
  return `${hours} ч`;
}
```

- [ ] **Step 2: Render the system block in renderCard()**

Edit `monitoring/dashboard.html`. In `renderCard()`, insert a new block immediately after the existing `ceph-line` block ends (after the line `html += \`</div>\`;` that closes the ceph-line div, i.e. right after line 120, and before the `const history = ...` line at 122):

```javascript
  const system = data.system;
  if (system) {
    html += `<div class="row"><span>Load average</span><b>${system.load_avg.map(v => v.toFixed(2)).join(' / ')}</b></div>`;
    html += `<div class="row"><span>Память</span><b>${system.memory.used_gb} / ${system.memory.total_gb} ГБ (${system.memory.percent}%)</b></div>`;
    html += `<div class="row"><span>Аптайм</span><b>${humanDuration(system.boot_at)}</b></div>`;
    html += `<div class="row"><span>Процессы rclone</span><b>${system.rclone_processes}</b></div>`;
  }
```

No new CSS is needed — this reuses the existing `.row` class already styled at the top of the file (line 32).

- [ ] **Step 3: Manually verify rendering with a mock status.json**

Create a temporary local copy for manual inspection — this file is scratch, not committed:

```bash
cat > /tmp/mock_status.json <<'EOF'
{
  "generated_at": "2026-07-08T12:00:00+03:00",
  "hosts": {
    "arch03": {
      "generated_at": "2026-07-08T12:00:00+03:00",
      "last_success": {"finished_at": "2026-07-08T06:00:00+03:00", "files_copied": 10, "files_deleted": 0, "errors": 0},
      "running_now": {"active": false},
      "ceph": {"mounted": true, "accessible": true, "last_mds_incident": null},
      "disk": {"backup_used_percent": 23, "backup_avail_human": "94T"},
      "system": {"load_avg": [0.52, 0.61, 0.58], "memory": {"used_gb": 12.3, "total_gb": 64.0, "percent": 19}, "boot_at": "2026-07-01T08:00:00+03:00", "rclone_processes": 4}
    },
    "arch04": {
      "generated_at": "2026-07-08T12:00:00+03:00",
      "last_success": {"finished_at": "2026-07-08T06:00:00+03:00", "files_copied": 10, "files_deleted": 0, "errors": 0},
      "running_now": {"active": false},
      "ceph": {"mounted": true, "accessible": true, "last_mds_incident": null},
      "disk": {"backup_used_percent": 40, "backup_avail_human": "50T"},
      "system": null
    }
  }
}
EOF
cp monitoring/dashboard.html /tmp/dashboard_test.html
cp /tmp/mock_status.json /tmp/status.json
cd /tmp && python3 -m http.server 8099 &
```

Open `http://localhost:8099/dashboard_test.html` in a browser (rename fetch target or just confirm the page loads `status.json` from the same directory — `/tmp/dashboard_test.html` fetching `/tmp/status.json` via relative path works since `python3 -m http.server` serves the `/tmp` directory).

Expected: `arch03`'s card shows 4 new rows (Load average `0.52 / 0.61 / 0.58`, Память `12.3 / 64.0 ГБ (19%)`, Аптайм `7 дн 4 ч`, Процессы rclone `4`). `arch04`'s card shows NO new rows at all (since its `system` is `null`) and does not error/show "undefined" anywhere on the card.

- [ ] **Step 4: Stop the test server and clean up**

Run: `kill %1; rm -f /tmp/mock_status.json /tmp/status.json /tmp/dashboard_test.html`

- [ ] **Step 5: Commit**

```bash
git add monitoring/dashboard.html
git commit -m "Render system metrics (load avg, memory, uptime, rclone processes) on dashboard cards"
```
