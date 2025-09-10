#!/usr/local/bin/bash
#
# Скрипт для резервного копирования Ceph S3 → MinIO S3
# -------------------------------------------------------
# Поддерживает расширенное логирование, проверку состояния хранилищ,
# надежную обработку ошибок, гибкие параметры и безопасное выполнение.
#
# Автор: [УКАЖИТЕ СВОЕ ИМЯ]
# Версия: 3.0 (сентябрь 2025)
#

# ----------------------------#
# 0. ВКЛЮЧЕНИЕ СТРОГОГО РЕЖИМА
# ----------------------------#
set -eEuo pipefail
IFS=$'\n\t'
umask 027

# ---------------------------#
# 1. БАЗОВЫЕ НАСТРОЙКИ
# ---------------------------#
readonly LOGDIR="/var/log/rclone-backup"
readonly LOCKFILE="/var/lock/backup.lock"
readonly RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
readonly MAX_LOGFILES=100
readonly LOG_RETENTION_DAYS=30
readonly RETENTION_DAYS=30
readonly RCLONE_TRANSFERS=30
readonly RCLONE_CHECKERS=20
readonly RCLONE_RETRIES=5
readonly RCLONE_PARALLEL=4
readonly RCLONE_UPLOAD_CONCURRENCY=8
readonly RCLONE_CHUNK_SIZE="64M"
readonly DELETE_BACKUP="minio:backup-deleted"
readonly SCRIPT_VER="3.0"
timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
readonly LOGFILE="$LOGDIR/backup_${timestamp}.log"

# ----------------------------#
# 2. КОМАНДЫ-ДЕПЕНДЕНСИС
# ----------------------------#
check_required_commands() {
    local required=(bash flock rclone find mkdir date stat wc xargs tee)
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Не найдена команда: $cmd" >&2
            exit 1
        }
    done
}

check_required_commands

# ----------------------------#
# 3. СИСТЕМА ЛОГИРОВАНИЯ
# ----------------------------#
log() {
    # log <LEVEL> <MSG>
    local level="${1:-INFO}"
    local msg="${2:-}"
    echo "$(date +'%Y-%m-%d %T') [$level] $msg" | tee -a "$LOGFILE"
}

# ----------------------------#
# 4. РОТАЦИЯ ЛОГОВ
# ----------------------------#
rotate_logs() {
    find "$LOGDIR" -type f -name 'backup_*' -mtime +$LOG_RETENTION_DAYS -delete
    local count
    count=$(find "$LOGDIR" -type f -name 'backup_*' 2>/dev/null | wc -l || echo 0)
    if ((count > MAX_LOGFILES)); then
        log "WARNING" "Слишком много лог-файлов ($count > $MAX_LOGFILES)"
    fi
}

mkdir -p "$LOGDIR" || { echo "Не удалось создать $LOGDIR" >&2; exit 1; }
rotate_logs

# ----------------------------#
# 5. ПРОВЕРКА RCLONE КОНФИГА
# ----------------------------#
if [[ ! -f "$RCLONE_CONFIG" ]]; then
    log "ERROR" "Конфиг rclone не найден: $RCLONE_CONFIG"
    exit 1
fi
if [[ "$(stat -f %Sp "$RCLONE_CONFIG")" != "-rw-------" ]]; then
    log "WARNING" "Рекомендуется: chmod 600 $RCLONE_CONFIG"
fi

# ----------------------------#
# 6. ЗАЩИТА ОТ ПАРАЛЛЕЛЬНОГО ЗАПУСКА
# ----------------------------#
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log "ERROR" "Скрипт уже запущен."
    exit 1
fi
trap 'flock -u 200; rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

# ----------------------------#
# 7. МАССИВ БАКЕТОВ ДЛЯ СИНХРОНИЗАЦИИ
# ----------------------------#
buckets=(
    "test:nbgi-db-public"
    "test:nbgi-db-dev"
    "test:nbgi-db-private"
    "test:nbgi-tps"
    # ... (добавьте остальные бакеты)
)

# ----------------------------#
# 8. ПРОВЕРКА ДОСТУПНОСТИ ХРАНИЛИЩ
# ----------------------------#
check_storage_access() {
    local remotes=("test" "minio" "registry" "backup" "default" "nbgi-init-sequencing" "nbgi-init-gd")
    for remote in "${remotes[@]}"; do
        if ! rclone lsd "$remote:" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
            log "ERROR" "S3 хранилище $remote недоступно"
            return 1
        fi
    done
    log "INFO" "Все S3 хранилища доступны"
    return 0
}

# ----------------------------#
# 9. ФУНКЦИИ ДОПОМОГАТЕЛЬНОЙ ОБРАБОТКИ
# ----------------------------#

retry_command() {
    # retry_command <count> <delay> <CMD_STRING>
    local retries="${1:-3}"
    local delay="${2:-10}"
    shift 2
    local cmd="$*"
    for attempt in $(seq 1 "$retries"); do
        log "INFO" "Попытка $attempt/$retries: $cmd"
        if eval "$cmd"; then
            return 0
        else
            log "WARNING" "Ошибка: $cmd (попытка $attempt/$retries)"
            sleep "$delay"
        fi
    done
    log "ERROR" "Команда не выполнена после $retries попыток: $cmd"
    return 1
}

create_bucket_if_not_exists() {
    local remote="$1"
    local bucket="$2"
    if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
        log "INFO" "Создание бакета $remote:$bucket"
        retry_command 3 10 "rclone mkdir '$remote:$bucket' --config='$RCLONE_CONFIG'" || return 1
    fi
    return 0
}

# ----------------------------#
# 10. СИНХРОНИЗАЦИЯ ОДНОГО БАКЕТА
# ----------------------------#
sync_bucket() {
    local src="$1"
    local src_remote="${src%%:*}"
    local src_bucket="${src#*:}"
    local dst_remote="minio"
    local dst_bucket="$src_remote"
    local dst_path="${dst_remote}:${dst_bucket}/${src_bucket}"

    create_bucket_if_not_exists "$dst_remote" "$dst_bucket" || return 1
    log "INFO" "Старт синхронизации $src -> $dst_path"
    retry_command 3 15 \
      rclone sync "$src" "$dst_path" \
        --config="$RCLONE_CONFIG" \
        --transfers=$RCLONE_TRANSFERS \
        --checkers=$RCLONE_CHECKERS \
        --retries=$RCLONE_RETRIES \
        --s3-upload-concurrency=$RCLONE_UPLOAD_CONCURRENCY \
        --s3-chunk-size=$RCLONE_CHUNK_SIZE \
        --stats=60s \
        --fast-list \
        --checksum \
        --s3-force-path-style \
        --no-check-certificate \
        --log-file="$LOGFILE" \
        --log-level=INFO \
        --backup-dir="${DELETE_BACKUP}/$(date +%F)" \
        --update \
        --delete-during \
        --size-only \
        --use-server-modtime \
        --create-empty-src-dirs
}

# ----------------------------#
# 11. ВАЛИДАЦИЯ БАКЕТА
# ----------------------------#
validate_bucket() {
    local src="$1"
    local dst="$2"
    local src_count dst_count

    src_count=$(rclone lsf "$src" --files-only --config="$RCLONE_CONFIG" | wc -l)
    dst_count=$(rclone lsf "$dst" --files-only --config="$RCLONE_CONFIG" | wc -l)

    if [[ "$src_count" -eq "$dst_count" ]]; then
        log "INFO" "Валидация успешна: файлов $src_count"
    else
        log "ERROR" "Валидация не пройдена: источник $src_count, дестин $dst_count"
    fi
}

# -----------------------------#
# 12. ОЧИСТКА УСТАРЕВШЕГО БЭКАПА
# -----------------------------#
cleanup_old_backups() {
    log "INFO" "Очистка резервных файлов старше $RETENTION_DAYS дней"
    retry_command 3 15 \
      rclone delete "$DELETE_BACKUP" \
        --min-age "${RETENTION_DAYS}d" \
        --config="$RCLONE_CONFIG" \
        --s3-force-path-style \
        --no-check-certificate \
        --log-level=INFO \
        --log-file="$LOGFILE"
}

# -----------------------------------------#
# 13. ОСНОВНАЯ ФУНКЦИЯ СИНХРОНИЗАЦИИ БАКЕТОВ
# -----------------------------------------#
main() {
    log "INFO" "===== Запуск резервного копирования (версия $SCRIPT_VER) ====="
    log "INFO" "Пользователь: $(whoami), Rclone: $(rclone --version | head -n1)"
    log "INFO" "Конфиг: $RCLONE_CONFIG, Время: $(date)"

    if ! check_storage_access; then
        log "ERROR" "Доступ к хранилищам невозможен"
        exit 1
    fi

    create_bucket_if_not_exists "minio" "backup-deleted"

    # Параллельная обработка бакетов
    log "INFO" "Синхронизация бакетов (до $RCLONE_PARALLEL потоков)"
    for bucket in "${buckets[@]}"; do
      (
        if sync_bucket "$bucket"; then
            src="$bucket"
            dst="minio:${bucket%%:*}/${bucket#*:}"
            validate_bucket "$src" "$dst"
            log "INFO" "Бакет $bucket синхронизирован успешно"
        else
            log "ERROR" "Ошибка синхронизации $bucket"
        fi
      ) &
      # ограничение числа параллельных потоков
      if [[ $(jobs -r -p | wc -l) -ge $RCLONE_PARALLEL ]]; then
        wait -n
      fi
    done
    wait

    cleanup_old_backups
    log "INFO" "Все бакеты обработаны."
}

main "$@"