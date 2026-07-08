#!/bin/bash
# Генерирует /var/lib/backup-status/status.json для дашборда мониторинга.
# Без аргументов — пересчитать статус (режим cron).
# --print — просто вывести уже посчитанный файл (используется как forced-command по SSH).
set -uo pipefail

STATUS_DIR="/var/lib/backup-status"
STATUS_FILE="$STATUS_DIR/status.json"
LOG_DIR="/var/log/backup"
SERVICE_NAME="rclone-backup.service"

if [[ "${1:-}" == "--print" ]]; then
  cat "$STATUS_FILE" 2>/dev/null || echo '{"error":"status file not found"}'
  exit 0
fi

mkdir -p "$STATUS_DIR"

HOST=$(hostname -s)
GENERATED_AT=$(date -Iseconds)

# --- last_success: разбираем самый свежий *.summary.json ---
LATEST_SUMMARY=$(ls -t "$LOG_DIR"/*.summary.json 2>/dev/null | head -1)
if [[ -n "$LATEST_SUMMARY" ]]; then
  LAST_SUCCESS_JSON=$(python3 - "$LATEST_SUMMARY" <<'PYEOF'
import json, subprocess, sys

path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
    stats = d.get('statistics', {})
    finished_at = d.get('timestamp')
    if finished_at:
        # Normalize to the same colon-offset ISO-8601 form the rest of this
        # script uses (date -Iseconds), same as last_mds_incident below --
        # the summary JSON's own 'timestamp' field uses a non-colon offset
        # (e.g. +0300) that not every JS Date parser accepts.
        try:
            normalized = subprocess.run(
                ['date', '-d', finished_at, '-Iseconds'],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
            if normalized:
                finished_at = normalized
        except Exception:
            pass
    print(json.dumps({
        'finished_at': finished_at,
        'result': d.get('result'),
        'files_copied': stats.get('transfers', 0),
        'files_deleted': stats.get('deletes', 0),
        'errors': stats.get('errors', 0),
        'duration_sec': stats.get('elapsed_time_seconds', 0),
    }))
except Exception as e:
    print(json.dumps({'error': str(e)}))
PYEOF
)
else
  LAST_SUCCESS_JSON='null'
fi

# --- running_now: активен ли сервис бэкапа, и насколько далеко продвинулся ---
SERVICE_STATE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
SERVICE_STATE=${SERVICE_STATE:-unknown}
CHECKS_DONE=0
CHECKS_TOTAL=0
PERCENT=0
STARTED_AT="null"
if [[ "$SERVICE_STATE" == "active" || "$SERVICE_STATE" == "activating" ]]; then
  CURRENT_LOG=$(ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | head -1)
  LAST_CHECK_LINE=$(grep -oE 'Checks:[[:space:]]+[0-9]+ */ *[0-9]+' "$CURRENT_LOG" 2>/dev/null | tail -1)
  if [[ -n "$LAST_CHECK_LINE" ]]; then
    CHECKS_DONE=$(echo "$LAST_CHECK_LINE" | grep -oE '[0-9]+' | sed -n '1p')
    CHECKS_TOTAL=$(echo "$LAST_CHECK_LINE" | grep -oE '[0-9]+' | sed -n '2p')
  fi
  CHECKS_DONE=${CHECKS_DONE:-0}
  CHECKS_TOTAL=${CHECKS_TOTAL:-0}
  if [[ "$CHECKS_TOTAL" -gt 0 ]]; then
    PERCENT=$(( CHECKS_DONE * 100 / CHECKS_TOTAL ))
  fi
  STARTED_AT_RAW=$(systemctl show "$SERVICE_NAME" -p ExecMainStartTimestamp 2>/dev/null)
  STARTED_AT_RAW="${STARTED_AT_RAW#ExecMainStartTimestamp=}"
  if [[ -n "$STARTED_AT_RAW" ]]; then
    STARTED_AT=$(date -d "$STARTED_AT_RAW" -Iseconds 2>/dev/null || echo "null")
  else
    STARTED_AT="null"
  fi
fi

# --- ceph: смонтирован ли, реально ли доступен, когда был последний сбой ---
CEPH_MOUNTED=false
mount | grep -q ' ceph ' && CEPH_MOUNTED=true

CEPH_ACCESSIBLE=false
timeout 3 stat /ceph >/dev/null 2>&1 && CEPH_ACCESSIBLE=true

LAST_MDS_INCIDENT="null"
LAST_MDS_LINE=$(dmesg -T 2>/dev/null | grep -i "rejected session" | tail -1)
if [[ -n "$LAST_MDS_LINE" ]]; then
  LAST_MDS_RAW=$(echo "$LAST_MDS_LINE" | sed -E 's/^\[(.*)\].*/\1/')
  LAST_MDS_INCIDENT=$(date -d "$LAST_MDS_RAW" -Iseconds 2>/dev/null || echo "null")
fi

# --- disk: место на /backup ---
DISK_LINE=$(df -h /backup 2>/dev/null | tail -1)
DISK_USED_PERCENT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')
DISK_AVAIL=$(echo "$DISK_LINE" | awk '{print $4}')
DISK_USED_PERCENT=${DISK_USED_PERCENT:-0}
DISK_AVAIL=${DISK_AVAIL:-"?"}

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

# boot_at is computed here via `date`, not inside the python heredoc below --
# python's date-parsing stdlib helper for ISO-8601 strings isn't available
# until Python 3.7, and even then it can't parse the colon-less UTC offset
# (e.g. +0300) that `date -Iseconds` produces on these hosts until Python
# 3.11. Same idiom as last_success/last_mds_incident above: let `date` do the
# date arithmetic and hand python an already-formatted string.
BOOT_AT=$(date -d "@$(( $(date +%s) - UPTIME_SECONDS ))" -Iseconds 2>/dev/null)

RCLONE_PROCESSES=$(pgrep -c -x rclone 2>/dev/null)
RCLONE_PROCESSES=${RCLONE_PROCESSES:-0}

SYSTEM_JSON=$(python3 - "$LOAD1" "$LOAD5" "$LOAD15" "$MEM_TOTAL_KB" "$MEM_AVAIL_KB" \
  "$BOOT_AT" "$RCLONE_PROCESSES" "$GENERATED_AT" <<'PYEOF'
import json, sys

load1, load5, load15, total_kb, avail_kb, boot_at_str, rclone_procs, generated_at = sys.argv[1:9]

try:
    total_kb = int(total_kb)
    avail_kb = int(avail_kb)
    if total_kb <= 0:
        raise ValueError("MemTotal missing or zero")
    if not boot_at_str:
        raise ValueError("boot_at unavailable")
    used_gb = round((total_kb - avail_kb) / 1024 / 1024, 1)
    total_gb = round(total_kb / 1024 / 1024, 1)
    percent = round((total_kb - avail_kb) / total_kb * 100)

    data = {
        "load_avg": [float(load1), float(load5), float(load15)],
        "memory": {"used_gb": used_gb, "total_gb": total_gb, "percent": percent},
        "boot_at": boot_at_str,
        "rclone_processes": int(rclone_procs),
    }
    print(json.dumps(data))
except Exception:
    print("null")
PYEOF
)

RUNNING_ACTIVE=false
[[ "$SERVICE_STATE" == "active" || "$SERVICE_STATE" == "activating" ]] && RUNNING_ACTIVE=true

STATUS_TMP="$STATUS_FILE.tmp.$$"
python3 - "$HOST" "$GENERATED_AT" "$LAST_SUCCESS_JSON" "$RUNNING_ACTIVE" "$STARTED_AT" \
  "$CHECKS_DONE" "$CHECKS_TOTAL" "$PERCENT" "$CEPH_MOUNTED" "$CEPH_ACCESSIBLE" \
  "$LAST_MDS_INCIDENT" "$DISK_USED_PERCENT" "$DISK_AVAIL" "$SYSTEM_JSON" > "$STATUS_TMP" <<'PYEOF'
import json, sys

(host, generated_at, last_success_json, running_active, started_at,
 checks_done, checks_total, percent, ceph_mounted, ceph_accessible,
 last_mds, disk_pct, disk_avail, system_json) = sys.argv[1:15]

last_success = json.loads(last_success_json) if last_success_json != "null" else None
system = json.loads(system_json) if system_json != "null" else None

running_now = {"active": running_active == "true"}
if running_now["active"]:
    running_now.update({
        "started_at": None if started_at == "null" else started_at,
        "checks_done": int(checks_done),
        "checks_total": int(checks_total),
        "percent": int(percent),
    })

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
print(json.dumps(data, indent=2))
PYEOF
PY_EXIT=$?

if [[ $PY_EXIT -eq 0 ]]; then
  mv "$STATUS_TMP" "$STATUS_FILE"
else
  echo "backup_status.sh: python3 status generation failed (exit $PY_EXIT); leaving previous $STATUS_FILE untouched" >&2
  rm -f "$STATUS_TMP"
  exit 1
fi
