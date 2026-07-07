#!/bin/bash
# Забирает status.json с arch03/04/05 через ограниченный ключ мониторинга,
# складывает в ~/backup-monitor/www/status.json для дашборда.
# Хосты, недоступные в этот раз, помечаются stale:true, но не теряют
# последние известные данные.
set -uo pipefail

OUTDIR="$HOME/backup-monitor"
WWWDIR="$OUTDIR/www"
STATE_FILE="$OUTDIR/state.json"
OUT_FILE="$WWWDIR/status.json"
SSH_CONFIG="$HOME/.ssh/monitor_config"
HOSTS=(arch03 arch04 arch05)

mkdir -p "$WWWDIR"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

NOW=$(date -Iseconds)

fetch_one() {
  local host="$1"
  ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ControlMaster=no -o ControlPath=none "${host}-mon" 2>/dev/null
}

{
  echo "$NOW"
  for h in "${HOSTS[@]}"; do
    echo "---HOST:$h---"
    fetch_one "$h"
    echo "---END:$h---"
  done
} | python3 "$OUTDIR/_merge_status.py" "$STATE_FILE" "$OUT_FILE"
