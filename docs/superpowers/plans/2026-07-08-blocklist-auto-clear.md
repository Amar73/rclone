# ceph_watchdog Blocklist Auto-Clear Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `ceph_watchdog_recover()` self-clear its own Ceph OSD blocklist entry (via a new, narrowly-scoped `client.watchdog` credential) as a fallback after 5 normal remount attempts fail, instead of waiting up to an hour for the blocklist entry to expire on its own.

**Architecture:** A new pure function `ceph_watchdog_clear_own_blocklist()` queries `ceph osd blocklist ls` (via a new restricted credential), matches entries against the host's own IP addresses, and removes matches. `ceph_watchdog_recover()` calls it once, only after its existing 5-attempt remount loop has exhausted, and makes one more `mount` attempt if anything was cleared.

**Tech Stack:** bash (same file as the rest of `ceph_watchdog`), Ceph CLI (`ceph osd blocklist ls`/`rm`) via a new scoped keyring, deployed identically to arch03/04/05.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-07-08-blocklist-auto-clear-design.md` — read this first.
- New credential (`client.watchdog`) capability is exactly: `mon 'allow rw, allow command "osd blocklist rm", allow command "osd blocklist ls"'` — no other capabilities.
- Credential storage on each host: `/etc/ceph/ceph.watchdog.conf` (new, correct mon IPs — do NOT touch or reuse the existing `/etc/ceph/ceph.conf`, which is stale/broken) and `/etc/ceph/ceph.watchdog.keyring`.
- The new fallback logic activates **only** after all `CEPH_WATCHDOG_REMOUNT_ATTEMPTS` normal remount attempts have failed — the existing 5-attempt loop itself must not change.
- Any failure in the new blocklist-clearing logic (unreachable mon, missing credential, no matching entries) must fall through to the existing `"не удалось перемонтировать /ceph после N попыток"` error path unchanged — never a new crash/exit path.
- All new Ceph CLI calls must be wrapped in `timeout` — no unbounded network calls, consistent with the rest of `ceph_watchdog_recover()`.

---

### Task 1: Add `ceph_watchdog_clear_own_blocklist()` and wire it into `ceph_watchdog_recover()`

**Files:**
- Modify: `backup/rclone_backup_unified_v4.0.0.sh:801-816` (new constants, next to the existing `CEPH_WATCHDOG_*` constants)
- Modify: `backup/rclone_backup_unified_v4.0.0.sh` (new function, placed immediately before `ceph_watchdog_recover()`)
- Modify: `backup/rclone_backup_unified_v4.0.0.sh` (inside `ceph_watchdog_recover()`, between the closing `done` of the 5-attempt loop and the final `log ERROR "не удалось перемонтировать..."`)
- Test: none exist for this repo (ops shell script, no test framework) — verification is a standalone script using a fake `ceph` executable, described below

**Interfaces:**
- Produces: `ceph_watchdog_clear_own_blocklist()` — no arguments, returns `0` if at least one blocklist entry matching this host's own IP was found and successfully removed via `ceph osd blocklist rm`, returns `1` otherwise (nothing to clear, no match, or the `rm` call itself failed). Uses the module-level `log()` function already defined earlier in this file (same convention as every other function here).
- Consumes: nothing from other tasks — this is the only task in this plan that touches code.

- [ ] **Step 1: Add the new constants**

Edit `backup/rclone_backup_unified_v4.0.0.sh`. Insert immediately after line 816 (`readonly CEPH_WATCHDOG_STOP_WAIT_TIMEOUT=150`):

```bash

# Учётные данные для узкого client.watchdog (только osd blocklist ls/rm) —
# отдельные от основного /etc/ceph/ceph.conf на этих хостах, который
# устарел и указывает на несуществующие mon IP.
readonly CEPH_WATCHDOG_CONF="/etc/ceph/ceph.watchdog.conf"
readonly CEPH_WATCHDOG_KEYRING="/etc/ceph/ceph.watchdog.keyring"
readonly CEPH_WATCHDOG_BLOCKLIST_TIMEOUT=10
```

- [ ] **Step 2: Add the new function**

Edit `backup/rclone_backup_unified_v4.0.0.sh`. Insert the new function immediately before the `ceph_watchdog_recover()` function definition (i.e., right before the line `ceph_watchdog_recover() {`):

```bash
# Ищет записи Ceph OSD blocklist, совпадающие с собственными IP этого
# хоста, и снимает их. Возвращает 0, если хотя бы одна запись была
# найдена и успешно снята, 1 иначе (нечего снимать, нет совпадений,
# или сама команда rm не удалась). Любая ошибка здесь (недоступные
# мониторы, отсутствующий keyring) должна тихо приводить к 1, а не
# прерывать вызывающую функцию.
ceph_watchdog_clear_own_blocklist() {
    local own_ips
    own_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

    local blocklist_entries
    blocklist_entries=$(timeout "$CEPH_WATCHDOG_BLOCKLIST_TIMEOUT" \
        ceph -c "$CEPH_WATCHDOG_CONF" --keyring "$CEPH_WATCHDOG_KEYRING" \
        osd blocklist ls 2>/dev/null | awk '{print $1}')

    if [[ -z "$own_ips" || -z "$blocklist_entries" ]]; then
        return 1
    fi

    local cleared=false
    local entry ip
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            if [[ "$entry" == "$ip:"* ]]; then
                log INFO "ceph_watchdog: найдена собственная запись в blocklist:" \
                          "$entry. Снимаю блокировку."
                if timeout "$CEPH_WATCHDOG_BLOCKLIST_TIMEOUT" \
                    ceph -c "$CEPH_WATCHDOG_CONF" --keyring "$CEPH_WATCHDOG_KEYRING" \
                    osd blocklist rm "$entry" >/dev/null 2>&1; then
                    cleared=true
                fi
            fi
        done <<< "$own_ips"
    done <<< "$blocklist_entries"

    if [[ "$cleared" == "true" ]]; then
        return 0
    fi
    return 1
}

```

- [ ] **Step 3: Wire the fallback into `ceph_watchdog_recover()`**

Edit `backup/rclone_backup_unified_v4.0.0.sh`. Find this exact block (the end of the 5-attempt remount loop, followed by the final error path):

```bash
        if (( attempt < CEPH_WATCHDOG_REMOUNT_ATTEMPTS )); then
            sleep "$CEPH_WATCHDOG_REMOUNT_SLEEP"
        fi
    done

    log ERROR "ceph_watchdog: не удалось перемонтировать /ceph после" \
              "$CEPH_WATCHDOG_REMOUNT_ATTEMPTS попыток. Продолжаю наблюдение."
    flock -u "$recover_lock_fd"
    exec {recover_lock_fd}>&-
    return 1
}
```

Replace it with (only the new block between `done` and the final `log ERROR` is new — the rest is unchanged, shown here for exact placement):

```bash
        if (( attempt < CEPH_WATCHDOG_REMOUNT_ATTEMPTS )); then
            sleep "$CEPH_WATCHDOG_REMOUNT_SLEEP"
        fi
    done

    if ceph_watchdog_clear_own_blocklist; then
        log INFO "ceph_watchdog: попытка перемонтирования после снятия blocklist"
        if timeout -k "$CEPH_WATCHDOG_TIMEOUT_KILL_GRACE" "$CEPH_WATCHDOG_MOUNT_TIMEOUT" mount /ceph 2>>"$LOGFILE" && ceph_watchdog_check; then
            log INFO "ceph_watchdog: снята собственная блокировка, /ceph перемонтирован"
            flock -u "$recover_lock_fd"
            exec {recover_lock_fd}>&-
            return 0
        fi
    fi

    log ERROR "ceph_watchdog: не удалось перемонтировать /ceph после" \
              "$CEPH_WATCHDOG_REMOUNT_ATTEMPTS попыток. Продолжаю наблюдение."
    flock -u "$recover_lock_fd"
    exec {recover_lock_fd}>&-
    return 1
}
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n backup/rclone_backup_unified_v4.0.0.sh`
Expected: no output, exit code 0.

- [ ] **Step 5: Write and run a standalone test for `ceph_watchdog_clear_own_blocklist()` using a fake `ceph` executable**

`timeout` requires a real executable on `PATH` — it cannot wrap a bash function — so the test fixture must be a fake `ceph` **script**, not a function.

Create `/tmp/fake_ceph_bin/ceph` (make sure the directory exists first: `mkdir -p /tmp/fake_ceph_bin`):

```bash
#!/bin/bash
# Fake `ceph` for testing ceph_watchdog_clear_own_blocklist() in isolation.
# Reads which fixture to use from the CEPH_WATCHDOG_TEST_FIXTURE env var.
if [[ "$*" == *"osd blocklist ls"* ]]; then
    case "$CEPH_WATCHDOG_TEST_FIXTURE" in
        own_ip_present)
            echo "$CEPH_WATCHDOG_TEST_OWN_IP:0/1234567890 2026-07-08T20:39:03.436151+0300"
            echo "listed 1 entries"
            ;;
        other_ip_only)
            echo "10.99.99.99:0/9999999999 2026-07-08T20:39:03.436151+0300"
            echo "listed 1 entries"
            ;;
        empty)
            echo "listed 0 entries"
            ;;
    esac
    exit 0
elif [[ "$*" == *"osd blocklist rm"* ]]; then
    exit 0
fi
exit 1
```

Make it executable: `chmod +x /tmp/fake_ceph_bin/ceph`

Create `/tmp/test_clear_blocklist.sh`:

```bash
#!/bin/bash
set -uo pipefail

SCRIPT=/home/amar/Amar73/rclone/backup/rclone_backup_unified_v4.0.0.sh

# Extract just the constants block and the new function for isolated testing
# (sourcing the whole script would try to acquire the production lock file
# and run main() logic that doesn't apply here).
CONST_START=$(grep -n "^readonly CEPH_WATCHDOG_CHECK_INTERVAL" "$SCRIPT" | head -1 | cut -d: -f1)
FUNC_END=$(grep -n "^ceph_watchdog_recover() {" "$SCRIPT" | head -1 | cut -d: -f1)
FUNC_END=$((FUNC_END - 1))
sed -n "${CONST_START},${FUNC_END}p" "$SCRIPT" > /tmp/extracted_blocklist_logic.sh

log() { echo "[$1] ${*:2}" >&2; }
export -f log

source /tmp/extracted_blocklist_logic.sh

export PATH="/tmp/fake_ceph_bin:$PATH"

OWN_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
if [[ -z "$OWN_IP" ]]; then
    echo "FAIL: could not determine this sandbox's own IP for the test"
    exit 1
fi

echo "=== Case 1: own IP present in blocklist -> expect rc=0 ==="
CEPH_WATCHDOG_TEST_FIXTURE=own_ip_present CEPH_WATCHDOG_TEST_OWN_IP="$OWN_IP" ceph_watchdog_clear_own_blocklist
rc1=$?
echo "rc=$rc1"
[[ $rc1 -eq 0 ]] && echo "PASS" || echo "FAIL"

echo "=== Case 2: only someone else's IP in blocklist -> expect rc=1 ==="
CEPH_WATCHDOG_TEST_FIXTURE=other_ip_only ceph_watchdog_clear_own_blocklist
rc2=$?
echo "rc=$rc2"
[[ $rc2 -eq 1 ]] && echo "PASS" || echo "FAIL"

echo "=== Case 3: empty blocklist -> expect rc=1 ==="
CEPH_WATCHDOG_TEST_FIXTURE=empty ceph_watchdog_clear_own_blocklist
rc3=$?
echo "rc=$rc3"
[[ $rc3 -eq 1 ]] && echo "PASS" || echo "FAIL"
```

Run: `bash /tmp/test_clear_blocklist.sh`

Expected output: all three cases print `PASS` (`rc=0` for Case 1, `rc=1` for Case 2 and Case 3).

- [ ] **Step 6: Clean up test artifacts**

Run: `rm -rf /tmp/fake_ceph_bin /tmp/test_clear_blocklist.sh /tmp/extracted_blocklist_logic.sh`

- [ ] **Step 7: Commit**

```bash
git add backup/rclone_backup_unified_v4.0.0.sh
git commit -m "Add ceph_watchdog blocklist auto-clear fallback after failed remounts"
```

---

## Post-plan: cluster credential provisioning and live deployment (controller, not a coding task)

This plan's Task 1 only adds code that *uses* `/etc/ceph/ceph.watchdog.conf` and `/etc/ceph/ceph.watchdog.keyring` — it does not and cannot create them (no host/cluster access from a subagent's sandbox). Before this feature can work live, the controller must, using the already-established access path (amar319 → wn75 → cephrgw01 → `podman exec ceph-mon-cephrgw01`):

1. Create the credential: `ceph auth get-or-create client.watchdog mon 'allow rw, allow command "osd blocklist rm", allow command "osd blocklist ls"'`
2. Retrieve its keyring content and write it to `/etc/ceph/ceph.watchdog.keyring` (mode 0600, root-owned) on arch03, arch04, and arch05.
3. Write `/etc/ceph/ceph.watchdog.conf` on each of the three hosts with the current real mon IPs (172.17.200.85, 172.17.200.86, 172.17.200.87 — confirm against `ceph -s`/`ceph mon dump` on cephrgw01 at deployment time, don't assume these stay fixed) and the cluster's `fsid`.
4. Deploy the updated `backup/rclone_backup_unified_v4.0.0.sh` to arch03 (backup existing script first, `bash -n` check — same pattern as every previous deployment to this file this project).
5. Live-test on arch03: create a synthetic blocklist entry for the host's own IP (`ceph osd blocklist add <arch03-ip>:0/1 <short-duration>` from cephrgw01, or trigger a real eviction if one is naturally observed), then run the extracted-function smoke test (same `sed`-extraction pattern used for every prior `ceph_watchdog_recover()` live test in this project) to confirm `ceph_watchdog_clear_own_blocklist` finds and removes the synthetic entry, and that a subsequent `mount /ceph` succeeds.
6. Once arch03 is validated, repeat steps 2-4 for arch04 and arch05 (the credential from step 1 is cluster-wide, reused as-is; only the per-host keyring/conf file deployment repeats).
