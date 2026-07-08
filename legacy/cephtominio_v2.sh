#!/usr/local/bin/bash
# Логирование с временной меткой
TIMESTAMP=$(date +'%Y-%m-%d_%H-%M')
LOGDIR="/var/log/rclone-backup"
LOGFILE="$LOGDIR/backup_$TIMESTAMP.log"
mkdir -p "$LOGDIR" || { echo "Не удалось создать $LOGDIR" >&2; exit 1; }

# Конфигурация rclone
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
export RCLONE_CONFIG

# Проверка доступности конфига
if [ ! -f "$RCLONE_CONFIG" ]; then
    log ERROR "Конфиг rclone не найден: $RCLONE_CONFIG"
    exit 1
fi

# Настройки производительности rclone
RCLONE_TRANSFERS=${RCLONE_TRANSFERS:-50}
RCLONE_RETRIES=${RCLONE_RETRIES:-10}
RCLONE_CHECKERS=${RCLONE_CHECKERS:-50}
export RCLONE_TRANSFERS RCLONE_RETRIES RCLONE_CHECKERS

# Блокировка повторного запуска
LOCKFILE="/var/lock/backup.lock"
if ! ( set -o noclobber; echo "$$" > "$LOCKFILE" ) 2> /dev/null; then
    echo "Скрипт уже запущен. Выход." >&2 | tee -a "$LOGFILE"
    exit 1
fi
trap 'rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

# Настройки очистки
DELETE_BACKUP="minio:backup-deleted"
RETENTION_DAYS=30

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

# Функция логирования
log() {
    local level=${1:-INFO}
    local msg="${2}"
    echo "$(date +'%Y-%m-%d %T') [$level] $msg" | tee -a "$LOGFILE"
}

# Функция повторных попыток
retry_command() {
    local cmd="$1"
    local retries=${2:-3}
    local delay=${3:-10}
    for attempt in $(seq 1 $retries); do
        log INFO "Попытка $attempt/$retries: $cmd"
        if eval "$cmd"; then
            return 0
        else
            log WARNING "Ошибка выполнения: $cmd (попытка $attempt/$retries)"
            sleep $delay
        fi
    done
    log ERROR "Не удалось выполнить команду после $retries попыток: $cmd"
    return 1
}

# Создание бакета при отсутствии
create_bucket_if_not_exists() {
    local remote="$1"
    local bucket="$2"
    if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" > /dev/null 2>&1; then
        log INFO "Бакет $bucket не существует. Создание..."
        if ! rclone mkdir "$remote:$bucket" --config="$RCLONE_CONFIG"; then
            log ERROR "Не удалось создать бакет $bucket"
            return 1
        fi
    fi
}

# Проверка существования backup-dir
create_bucket_if_not_exists "minio" "backup-deleted"

# Валидация бэкапа
#validate_backup() {
#    local src="$1"
#    local dst="$2"
#    log INFO "Начата валидация: $src -> $dst"
#    if ! rclone check "$src" "$dst" \
#        --config="$RCLONE_CONFIG" \
#        --log-level=INFO \
#        --log-file="$LOGFILE" \
#        --one-way; then  # Добавлен флаг для односторонней проверки
#        log ERROR "Валидация $src не пройдена"
#        return 1
#    fi
#    log INFO "Валидация $src успешно завершена"
#}

# Удаление устаревших данных
cleanup_old_backups() {
    log INFO "Начата очистка устаревших данных из $DELETE_BACKUP"
    if ! retry_command "rclone purge --min-age ${RETENTION_DAYS}d '$DELETE_BACKUP' \
        --config='$RCLONE_CONFIG' \
        --s3-force-path-style \
        --no-check-certificate \
        --log-level=INFO \
        --log-file='$LOGFILE'" 3 15; then
        log ERROR "Ошибка при очистке устаревших данных"
        return 1
    fi
    find "$LOGDIR" -type f -name 'backup_*' -mtime +30 -delete
    log INFO "Очистка завершена успешно"
}

# Исправленные флаги rclone (удален конфликтующий --verbose)
RCLONE_FLAGS="--progress \
    --check-first \
    --checkers=$RCLONE_CHECKERS \
    --stats=60s \
    --fast-list \
    --retries-sleep=10s \
    --update \
    --s3-upload-concurrency=20 \
    --checksum \
    --s3-force-path-style \
    --no-check-certificate \
    --log-file=$LOGFILE \
    --log-level=INFO \
    --backup-dir=$DELETE_BACKUP/$(date +%F)"

# Экспорт функций для параллельного выполнения
export -f log
export -f retry_command
export -f create_bucket_if_not_exists
#export -f validate_backup
export RCLONE_CONFIG RCLONE_TRANSFERS RCLONE_RETRIES RCLONE_CHECKERS LOGFILE DELETE_BACKUP RCLONE_FLAGS

# Основной процесс бэкапа
log INFO "***** Начат процесс резервного копирования *****"
log INFO "Запуск от пользователя: $(whoami)"
log INFO "Версия rclone: $(rclone --version | head -n1)"
log INFO "Конфиг rclone: $RCLONE_CONFIG"
log INFO "Параметры: transfers=$RCLONE_TRANSFERS retries=$RCLONE_RETRIES checkers=$RCLONE_CHECKERS"

# Определение функции для обработки бакета
process_bucket() {
    local bucket="$1"
    local source_remote="${bucket%%:*}"
    local source_bucket="${bucket#*:}"
    local target_bucket="${source_remote}"
    local target_path="minio:${target_bucket}/${source_bucket}"
    
    log INFO "Проверка существования бакета: $target_bucket"
    if ! create_bucket_if_not_exists "minio" "$target_bucket"; then
        return 1
    fi
    
    log INFO "Синхронизация бакета: $bucket -> $target_path"
    if ! retry_command "rclone copy \"$bucket\" \"$target_path\" \
        --config=\"$RCLONE_CONFIG\" \
        $RCLONE_FLAGS" 3 15; then
        log ERROR "Ошибка при синхронизации бакета: $bucket"
        return 1
    fi
    
#    if ! validate_backup "$bucket" "$target_path"; then
#        return 1
#    fi
}
export -f process_bucket

# Параллельная обработка бакетов
log INFO "Начата синхронизация бакетов (параллельно: 4 потока)"
if ! printf "%s\0" "${buckets[@]}" | xargs -0 -n1 -P4 -I{} bash -c 'process_bucket "$@"' _ {}; then
    log ERROR "Ошибки при синхронизации бакетов"
    exit 1
fi

# Очистка устаревших данных
cleanup_old_backups || log WARNING "Проблемы с очисткой, проверьте логи"

log INFO "Процесс бэкапа завершен успешно"
exit 0