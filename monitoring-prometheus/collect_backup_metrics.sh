#!/bin/bash
# Собирает статус бэкапов с бэкап-хостов по SSH и отдаёт его в _render_metrics.py,
# который пишет .prom-файл для textfile-коллектора node_exporter на arch-b.
#
# Запускается по таймеру backup-metrics.timer (см. deploy/).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Директория textfile-коллектора node_exporter (дефолт пакета Debian).
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
OUT_FILE="$TEXTFILE_DIR/rclone_backup.prom"

SSH_USER="${SSH_USER:-root}"

# Хосты опрашиваются по SSH-алиасу. Имя хоста в метриках берётся ИМЕННО отсюда,
# а не из вывода `hostname` на той стороне: arch04/arch05 исторически представляются
# как "arch03" (клоны шаблона VM), и доверять их самоидентификации нельзя.
#
# Тип определяет способ снятия статуса:
#   arch0x      — готовый backup_status.sh --print, отдаёт JSON
#   minio_bsd   — FreeBSD, cephtominio_*.sh, разбор артефактов в /var/log/rclone-sync
#   minio_linux — Linux, cephfs_to_minio_*.sh, /var/log/backup-ceph-minio
declare -A HOST_TYPE=(
  [arch03]=arch0x
  [arch04]=arch0x
  [arch05]=arch0x
  [archminio01]=minio_bsd
  [archminio02]=minio_linux
)
HOSTS=(arch03 arch04 arch05 archminio01 archminio02)

# На arch0X уже развёрнут скрипт статуса — переиспользуем его как есть.
ARCH0X_CMD="${ARCH0X_CMD:-/usr/local/bin/scripts/backup_status.sh --print}"

# На archminio аналога нет: бэкапы там запускаются вручную и их скрипты подлежат
# переработке. До тех пор снимаем минимальный, устойчивый к смене формата логов
# сигнал — время последней записи в лог и итог по бакетам из .status.tsv.
# Формат вывода — простые key=value, чтобы не зависеть от python на той стороне.
read -r -d '' MINIO_BSD_CMD <<'EOF'
echo "reached=1"
d=/var/log/rclone-sync
newest=$(ls -t $d/* 2>/dev/null | head -1)
[ -n "$newest" ] && echo "last_run_epoch=$(stat -f %m "$newest")"
f=$(ls -t $d/*.status.tsv 2>/dev/null | head -1)
if [ -n "$f" ]; then
  echo "buckets_ok=$(awk -F'\t' '$2=="OK"' "$f" | wc -l | tr -d ' ')"
  echo "buckets_failed=$(awk -F'\t' '$2=="FAIL"' "$f" | wc -l | tr -d ' ')"
fi
EOF

read -r -d '' MINIO_LINUX_CMD <<'EOF'
echo "reached=1"
d=/var/log/backup-ceph-minio
newest=$(ls -t $d/* 2>/dev/null | head -1)
[ -n "$newest" ] && echo "last_run_epoch=$(stat -c %Y "$newest")"
EOF

remote_cmd_for() {
  case "$1" in
    arch0x)      printf '%s' "$ARCH0X_CMD" ;;
    minio_bsd)   printf '%s' "$MINIO_BSD_CMD" ;;
    minio_linux) printf '%s' "$MINIO_LINUX_CMD" ;;
  esac
}

fetch_one() {
  local host="$1" cmd="$2"
  # ControlMaster=no/ControlPath=none — не переиспользовать чужие мультиплексные
  # сокеты: при отладке этой инфраструктуры они уже приводили к тому, что ответ
  # приходил не от того хоста, за который его принимали.
  timeout 20 ssh -o BatchMode=yes \
                 -o ConnectTimeout=8 \
                 -o ControlMaster=no \
                 -o ControlPath=none \
                 "${SSH_USER}@${host}" "$cmd" 2>/dev/null
}

mkdir -p "$TEXTFILE_DIR" || exit 1

{
  # Первая строка — метка времени старта сбора (unix seconds), нужна рендереру
  # для расчёта длительности сбора.
  date +%s
  for h in "${HOSTS[@]}"; do
    t="${HOST_TYPE[$h]}"
    echo "---HOST:${h}:${t}---"
    fetch_one "$h" "$(remote_cmd_for "$t")"
    echo "---END:${h}---"
  done
} | python3 "$SCRIPT_DIR/_render_metrics.py" "$OUT_FILE"
