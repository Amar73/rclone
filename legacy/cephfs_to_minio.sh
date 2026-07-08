#!/usr/bin/env bash

# Конфигурация rclone
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
export RCLONE_CONFIG

# MinIO конфигурация
MINIO_ENDPOINT="https://minio01.apps.maket.nbgi.ru:9000"

# Блокировка повторного запуска
LOCKFILE="/var/lock/backup-ceph-minio.lock"
if ! ( set -o noclobber; echo "$$" > "$LOCKFILE" ) 2> /dev/null; then
    echo "Скрипт уже запущен. Выход." >&2
    exit 1
fi
trap 'rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

# Настройки путей
LOGDIR="/var/log/backup-ceph-minio"
TIMESTAMP=$(date +'%Y-%m-%d_%H-%M')
LOGFILE="$LOGDIR/backup_$TIMESTAMP.log"
MAIN_BACKUP="minio:nbiks-backup"
DELETE_BACKUP="minio:deleted-backup"
SOURCEDIRS=(
    "/ceph/data/nbics/Reads"
    "/ceph/data/nbics/Genomes"
)

# Функция логирования
log() {
    local level=${1:-INFO}
    local msg="${2}"
    echo "$(date +'%Y-%m-%d %T') [$level] $msg" | tee -a "$LOGFILE"
}

# Проверка монтирования и доступности Ceph FS
check_ceph_access() {
    # Проверяем точку монтирования
    if ! mountpoint -q /ceph; then
        log WARNING "/ceph не смонтирован. Попытка монтирования..."
        umount -fl /ceph 2>/dev/null

        # Параметры для повторных попыток монтирования
        local retries=5
        local delay=30

        for attempt in $(seq 1 $retries); do
            log INFO "Попытка $attempt/$retries: Монтирование /ceph..."
            if mount /ceph; then
                log INFO "Точка /ceph успешно смонтирована."
                break
            else
                log WARNING "Не удалось смонтировать /ceph. Повтор через $delay секунд..."
                sleep $delay
            fi
        done

        # Если после всех попыток монтирование не удалось
        if ! mountpoint -q /ceph; then
            log ERROR "Не удалось смонтировать /ceph после $retries попыток."
            return 1
        fi
    fi

    # Проверяем доступность критичных директорий
    for dir in "${SOURCEDIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log ERROR "Директория $dir недоступна"
            return 1
        fi
    done

    return 0
}

## Проверка доступности MinIO S3
#check_minio_connection() {
#    log INFO "Проверка соединения с MinIO S3..."
#    if ! curl --output /dev/null --silent --head --fail "$MINIO_ENDPOINT"; then
#        log ERROR "MinIO S3 недоступен: $MINIO_ENDPOINT"
#        return 1
#    fi
#    log INFO "Соединение с MinIO S3 успешно установлено."
#}

# Создание бакетов на MinIO S3, если они не существуют
create_bucket_if_not_exists() {
    local bucket="$1"

    # Проверяем, существует ли бакет
    if ! rclone lsd "$bucket" --config="$RCLONE_CONFIG" > /dev/null 2>&1; then
        log INFO "Бакет $bucket не существует. Создание бакета..."
        if ! rclone mkdir "$bucket" --config="$RCLONE_CONFIG"; then
            log ERROR "Не удалось создать бакет $bucket."
            return 1
        fi
        log INFO "Бакет $bucket успешно создан."
    else
        log INFO "Бакет $bucket уже существует."
    fi
}

# Удаление устаревших данных из бакета DELETED
cleanup_old_deleted_data() {
    log INFO "Проверка и удаление устаревших данных из бакета DELETED..."

    # Определяем дату, старше которой данные считаются устаревшими (30 дней назад)
    OLDER_THAN=$(date -d "-30 days" +%Y-%m-%dT%H:%M:%SZ)

    # Удаляем файлы старше 30 дней
    if ! rclone delete --min-age "$OLDER_THAN" "$DELETE_BACKUP" --config="$RCLONE_CONFIG"; then
        log ERROR "Ошибка при удалении устаревших данных из бакета DELETED."
        return 1
    fi
    log INFO "Устаревшие данные из бакета DELETED успешно удалены."
}

# Функция для повторных попыток выполнения команды
retry_command() {
    local cmd="$1"
    local retries=${2:-3}
    local delay=${3:-10}

    for attempt in $(seq 1 $retries); do
        log INFO "Попытка $attempt/$retries: $cmd"
        if eval "$cmd"; then
            log INFO "Команда успешно выполнена: $cmd"
            return 0
        else
            log WARNING "Попытка $attempt/$retries завершилась ошибкой. Повтор через $delay секунд..."
            sleep $delay
        fi
    done

    log ERROR "Команда завершилась ошибкой после $retries попыток: $cmd"
    return 1
}

# Основная функция бэкапа
perform_backup() {
    # Создаем необходимые директории логов
    mkdir -p "$LOGDIR" || {
        log ERROR "Не удалось создать директорию для логов: $LOGDIR"
        return 1
    }

    # Ротация логов (удаление старых логов)
    find "$LOGDIR" -type f -name 'backup_*' -mtime +30 -delete

    # Проверяем доступность Ceph FS
    if ! check_ceph_access; then
        log ERROR "Ошибка доступа к Ceph FS. Прерывание бэкапа."
        return 1
    fi

#    # Проверяем доступность MinIO S3
#    if ! check_minio_connection; then
#        log ERROR "MinIO S3 недоступен. Прерывание бэкапа."
#        return 1
#    fi

    # Создаем бакеты на MinIO S3
    if ! create_bucket_if_not_exists "$MAIN_BACKUP"; then
        log ERROR "Ошибка создания бакета $MAIN_BACKUP. Прерывание бэкапа."
        return 1
    fi

    if ! create_bucket_if_not_exists "$DELETE_BACKUP"; then
        log ERROR "Ошибка создания бакета $DELETE_BACKUP. Прерывание бэкапа."
        return 1
    fi

    # Очистка устаревших данных из бакета DELETED
    if ! cleanup_old_deleted_data; then
        log WARNING "Ошибка при очистке устаревших данных из бакета DELETED. Продолжение работы."
    fi

    # Настройки rclone
    RCLONE_FLAGS="--progress --links --fast-list --create-empty-src-dirs \
        --checksum --transfers=20 --retries=5 --retries-sleep=10s \
        --update --checksum --log-file=$LOGFILE --log-level INFO"

    # Выполняем бэкап каждой директории
    for dir in "${SOURCEDIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            log INFO "Начато резервное копирование: $dir"

            # Определяем целевой путь в MinIO S3
            target_path="$MAIN_BACKUP/${dir#/ceph/data/nbics/}"

            # Выполнение бэкапа с перемещением удаленных файлов в DELETED
            cmd="rclone sync \
                --backup-dir=\"$DELETE_BACKUP/${dir#/ceph/data/nbics/}\" \
                $RCLONE_FLAGS \
                \"$dir\" \"$target_path\""

            if retry_command "$cmd"; then
                log INFO "Бэкап успешно завершен: $dir -> $target_path"
            else
                log ERROR "Ошибка при выполнении бэкапа: $dir -> $target_path"
                return 1
            fi
        else
            log WARNING "Директория не существует: $dir"
        fi
    done
}

# Основной поток выполнения
log INFO "Начат процесс резервного копирования из Ceph FS в MinIO S3"

perform_backup && log INFO "Бэкап успешно завершен" || {
    log ERROR "Бэкап завершился с ошибкой"
    exit 1
}

exit 0