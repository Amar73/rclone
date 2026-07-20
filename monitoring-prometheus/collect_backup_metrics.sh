#!/bin/bash
# Собирает статус бэкапов с arch03/04/05 по SSH и отдаёт его в _render_metrics.py,
# который пишет .prom-файл для textfile-коллектора node_exporter на arch-b.
#
# Переиспользует уже развёрнутый на тех хостах /usr/local/bin/scripts/backup_status.sh:
# на самих arch0X ничего менять не требуется.
#
# Запускается по таймеру backup-metrics.timer (см. deploy/).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Директория textfile-коллектора node_exporter (дефолт пакета Debian).
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
OUT_FILE="$TEXTFILE_DIR/rclone_backup.prom"

# Хосты опрашиваются по SSH-алиасу. Имя хоста в метриках берётся ИМЕННО отсюда,
# а не из вывода `hostname` на той стороне: arch04/arch05 исторически представляются
# как "arch03" (клоны шаблона VM), и доверять их самоидентификации нельзя.
HOSTS=(arch03 arch04 arch05)

SSH_USER="${SSH_USER:-root}"
REMOTE_CMD="${REMOTE_CMD:-/usr/local/bin/scripts/backup_status.sh --print}"

fetch_one() {
  local host="$1"
  # ControlMaster=no/ControlPath=none — не переиспользовать чужие мультиплексные
  # сокеты: при отладке этой инфраструктуры они уже приводили к тому, что ответ
  # приходил не от того хоста, за который его принимали.
  timeout 20 ssh -o BatchMode=yes \
                 -o ConnectTimeout=8 \
                 -o ControlMaster=no \
                 -o ControlPath=none \
                 "${SSH_USER}@${host}" "$REMOTE_CMD" 2>/dev/null
}

mkdir -p "$TEXTFILE_DIR" || exit 1

{
  # Первая строка — метка времени старта сбора (unix seconds), нужна рендереру
  # для расчёта длительности сбора.
  date +%s
  for h in "${HOSTS[@]}"; do
    echo "---HOST:$h---"
    fetch_one "$h"
    echo "---END:$h---"
  done
} | python3 "$SCRIPT_DIR/_render_metrics.py" "$OUT_FILE"
