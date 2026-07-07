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
import json, sys

path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
    stats = d.get('statistics', {})
    print(json.dumps({
        'finished_at': d.get('timestamp'),
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
SERVICE_STATE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
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
  STARTED_AT_RAW=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null)
  STARTED_AT=$(date -d "$STARTED_AT_RAW" -Iseconds 2>/dev/null || echo "null")
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

RUNNING_ACTIVE=false
[[ "$SERVICE_STATE" == "active" || "$SERVICE_STATE" == "activating" ]] && RUNNING_ACTIVE=true

STATUS_TMP="$STATUS_FILE.tmp.$$"
python3 - "$HOST" "$GENERATED_AT" "$LAST_SUCCESS_JSON" "$RUNNING_ACTIVE" "$STARTED_AT" \
  "$CHECKS_DONE" "$CHECKS_TOTAL" "$PERCENT" "$CEPH_MOUNTED" "$CEPH_ACCESSIBLE" \
  "$LAST_MDS_INCIDENT" "$DISK_USED_PERCENT" "$DISK_AVAIL" > "$STATUS_TMP" <<'PYEOF'
import json, sys

(host, generated_at, last_success_json, running_active, started_at,
 checks_done, checks_total, percent, ceph_mounted, ceph_accessible,
 last_mds, disk_pct, disk_avail) = sys.argv[1:14]

last_success = json.loads(last_success_json) if last_success_json != "null" else None

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
