#!/usr/local/bin/bash
# Настройки
LOCK_FILE="/tmp/backup_buckets.lock"
LOG_DIR="/var/log/rclone-backup"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOG_DIR}/${DATE}.log"
MINIO_REMOTE="minio"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RCLONE_FLAGS="--progress --check-first --transfers=50 --checkers=100 \
        --stats=60s --fast-list --retries=5 --update \
        --s3-upload-concurrency=20 --checksum \
        --log-file=$LOG_FILE --log-level ERROR"

# Функция для записи логов
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

create_bucket_if_not_exists() {
    local remote="$1"
    local bucket="$2"

    if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" > /dev/null 2>&1; then
        log_message "Бакет $bucket не существует. Создание бакета..."
        rclone mkdir "$remote:$bucket" --config="$RCLONE_CONFIG"

        if [ $? -eq 0 ]; then
            log_message "Бакет $bucket успешно создан."
        else
            log_message "Не удалось создать бакет $bucket."
            exit 1
        fi
    else
        log_message "Бакет $bucket уже существует."
    fi
}

# Список бакетов для бэкапа
buckets=(
    "test:db-ncbi-genbank"
    "test:db-ncbi-pubmed"
    "test:db-ncbi-refseq"
    "test:db-ncbi-bioproject"
    "test:db-ncbi-biosample"
    "test:db-ncbi-pub"
    "test:db-ncbi-sra"
    "test:db-ncbi-snp"
    "test:db-ncbi-genomes"
    "test:db-ncbi-blast"
)

# Начало бэкапа
log_message "Начало процесса бэкапа."

# Проверяем и создаем целевой бакет в MinIO
create_bucket_if_not_exists "$MINIO_REMOTE" "db-ncbi"

for bucket in "${buckets[@]}"; do
    source_remote="${bucket%%:*}"
    source_bucket="${bucket#*:}"
    target_path="${MINIO_REMOTE}:db-ncbi/${source_bucket}"

    log_message "Синхронизация бакета: $bucket -> $target_path"
    rclone copy "$bucket" "$target_path" \
        --config="$RCLONE_CONFIG" \
        $RCLONE_FLAGS

    if [ $? -eq 0 ]; then
        log_message "Успешно завершена синхронизация бакета: $bucket"
    else
        log_message "Ошибка при синхронизации бакета: $bucket"
    fi
done

exit 0
