#!/usr/local/bin/bash

# Настройки
LOCK_FILE="/var/lock/backup.lock"
LOG_DIR="/var/log/rclone-backup"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOGFILE="${LOG_DIR}/${DATE}.log"
MINIO_REMOTE="minio"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RCLONE_FLAGS="--progress --check-first --transfers=50 --checkers=100 \
    --stats=60s --fast-list --retries=5 --retries-sleep=10s --update \
    --s3-upload-concurrency=20 --verbose --checksum \
    --log-file=$LOGFILE --log-level ERROR"

# Создаем директорию для логов
mkdir -p "$LOG_DIR"

# Блокировка повторного запуска
if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2> /dev/null; then
    echo "Скрипт уже запущен. Выход." >&2
    exit 1
fi
trap 'rm -f "$LOCK_FILE"; exit $?' INT TERM EXIT

# Функция логирования
log() {
    local level=${1:-INFO}
    local msg="${2}"
    echo "$(date +'%Y-%m-%d %T') [$level] $msg" | tee -a "$LOGFILE"
}

create_bucket_if_not_exists() {
    local remote="$1"
    local bucket="$2"

# Проверяем, существует ли бакет
    if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" > /dev/null 2>&1; then
        log INFO "Бакет $bucket не существует. Создание бакета..."
        rclone mkdir "$remote:$bucket" --config="$RCLONE_CONFIG"

        if [ $? -eq 0 ]; then
            log INFO "Бакет $bucket успешно создан."
        else
            log ERROR "Не удалось создать бакет $bucket."
            exit 1
        fi
    else
        log INFO "Бакет $bucket уже существует."
    fi
}

# Список бакетов для бэкапа
buckets=(
    "test:nbgi-db-public"
    "test:nbgi-db-dev"
    "test:nbgi-db-private"
    "test:nbgi-tps"
    "test:nbgi-db-test"
    "test:db-arb-silva"
    "test:db-metagenomics"
    "test:3dparty-db-test"
    "nbgi-init-sequencing:nbgi-private-init-sequencing"
    "nbgi-init-sequencing:nbgi-public-init-sequencing"
    "nbgi-init-gd:nbgi-private-init-gd"
    "nbgi-init-gd:nbgi-public-init-gd"
    "registry:docker-registry"
    "backup:backup-psql"
    "backup:backup-vm"
    "test:db-meta"
    "test:db-pmc"
    "test:db-pdb"
    "test:db-ena"
    "test:db-ebi"
    "test:3rdparty-db-prod"
    "test:db-card-blast"
    "registry:pypi-registry"
    "default:k8s-logs"
)

# Начало бэкапа
log INFO "Начало процесса бэкапа."

for bucket in "${buckets[@]}"; do
    source_remote="${bucket%%:*}"
    source_bucket="${bucket#*:}"
    target_bucket="${source_remote}"
    target_path="${MINIO_REMOTE}:${target_bucket}/${source_bucket}"
    
    log INFO "Проверка существования бакета: $target_bucket"
    create_bucket_if_not_exists "$MINIO_REMOTE" "$target_bucket"
    
    log INFO "Синхронизация бакета: $bucket -> $target_path"
    rclone copy "$bucket" "$target_path" \
        --config="$RCLONE_CONFIG" \
        $RCLONE_FLAGS
    
    if [ $? -eq 0 ]; then
        log INFO "Успешно завершена синхронизация бакета: $bucket"
    else
        log ERROR "Ошибка при синхронизации бакета: $bucket"
    fi
done

log INFO "Процесс бэкапа завершен."
exit 0