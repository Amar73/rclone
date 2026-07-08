#!/usr/bin/env bash

# Логирование с временной меткой
TIMESTAMP=$(date +'%Y-%m-%d_%H-%M')
LOGDIR="/var/log/backup"
LOGFILE="$LOGDIR/backup_$TIMESTAMP.log"
mkdir -p "$LOGDIR" || { echo "Не удалось создать $LOGDIR" >&2; exit 1; }

# Конфигурация rclone
#RCLONE_CONFIG="$(rclone config file | cut -d' ' -f2)"
RCLONE_CONFIG=$(rclone config file | awk -F': ' '{print $2}' | xargs)
export RCLONE_CONFIG

# Настройки производительности rclone
RCLONE_TRANSFERS=${RCLONE_TRANSFERS:-30}
RCLONE_RETRIES=${RCLONE_RETRIES:-5}
export RCLONE_TRANSFERS RCLONE_RETRIES

# Файл исключений
EXCLUDE_FILE="/usr/local/bin/scripts/exclude-file.txt"
export EXCLUDE_FILE
if [[ ! -f "$EXCLUDE_FILE" ]]; then
    log ERROR "Файл исключений $EXCLUDE_FILE не найден"
    exit 1
fi

# Блокировка повторного запуска скрипта
LOCKFILE="/var/lock/backup.lock"
if ! ( set -o noclobber; echo "$$" > "$LOCKFILE" ) 2> /dev/null; then
    echo "Скрипт уже запущен. Выход." >&2 | tee -a "$LOGFILE"
    exit 1
fi
trap 'rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

# Настройки путей
DELETE_BACKUP="/backup/deleted"
MAIN_BACKUP="/backup/main"
SOURCEDIRS=("/ceph/data/exp/idream/")

# Создание директорий до всего остального
log INFO "Создание директорий резервного копирования..."
mkdir -p "$MAIN_BACKUP" "$DELETE_BACKUP" || {
    log ERROR "Не удалось создать директории $MAIN_BACKUP или $DELETE_BACKUP"
    exit 1
}

# Функция логирования
log() {
    local level=${1:-ERROR}
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

# Проверка монтирования Ceph
check_ceph_access() {
    # Проверка fstab
    if ! grep -q '/ceph' /etc/fstab; then
        log ERROR "/ceph не настроен в fstab"
        return 1
    fi

    # Проверка монтирования
    if ! mountpoint -q /ceph; then
        log WARNING "/ceph не смонтирован. Начинаем попытки монтирования..."

        for attempt in {1..5}; do
            log INFO "Попытка монтирования $attempt/5..."
            umount -fl /ceph 2>/dev/null
            if mount /ceph; then
                log INFO "Успешно смонтировано /ceph"
                break
            else
                log ERROR "Неудачная попытка монтирования. Повтор через 30 сек..."
                sleep 30
            fi
        done

        if ! mountpoint -q /ceph; then
            log ERROR "Не удалось смонтировать Ceph после 5 попыток"
            return 1
        fi
    fi

    # Проверка прав доступа
    if ! ls /ceph &>/dev/null; then
        log ERROR "Нет прав доступа к /ceph. Проверить права пользователя"
        return 1
    fi

    # Проверка доступности директорий
    for dir in "${SOURCEDIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log ERROR "Директория $dir недоступна"
            return 1
        fi
    done

    return 0
}

# Валидация бэкапа
#validate_backup() {
#    local src=$1
#    local dst=$2
#    log INFO "Начата валидация: $src -> $dst"
#
#    if ! rclone check "$src" "$dst" \
#        --config="$RCLONE_CONFIG" \
#        --log-level=INFO \
#        --log-file="$LOGFILE"; then
#
#        log ERROR "Валидация $src не пройдена"
#        return 1
#    fi
#
#    log INFO "Валидация $src успешно завершена"
#    return 0
#}

# Удаление устаревших данных
cleanup_old_backups() {
    log INFO "Начата очистка устаревших данных из $DELETE_BACKUP"

    # Проверка доступности backup директорий
    if [[ ! -d "$DELETE_BACKUP" ]]; then
        log ERROR "Директория $DELETE_BACKUP недоступна"
        return 1
    fi

    # Удаляем данные старше 30 дней через rclone
    if ! retry_command "rclone purge --min-age 30d '$DELETE_BACKUP' --config='$RCLONE_CONFIG' --log-level=INFO --log-file='$LOGFILE'"; then
        log ERROR "Ошибка при очистке устаревших данных"
        return 1
    fi

    # Удаляем старые логи
    find "$LOGDIR" -type f -name 'backup_*' -mtime +30 -delete
    log INFO "Очистка завершена успешно"
}

# Обработка отдельной директории
backup_dir() {
    local dir=$1
    log INFO "Начат бэкап: $dir"

    # Формируем корректный путь назначения без дублирования
    local dest_dir="${MAIN_BACKUP}/ceph${dir#/ceph}"
    mkdir -p "$(dirname "$dest_dir")" || {
        log ERROR "Не удалось создать $dest_dir"
        return 1
    }

    # Проверка доступа к исходной директории
    if ! ls "$dir" &>/dev/null; then
        log ERROR "Нет доступа к исходной директории: $dir"
        return 1
    fi

    # Настройки rclone
    local RCLONE_FLAGS=(
        "--progress"
        "--links"
        "--fast-list"
        "--create-empty-src-dirs"
        "--checksum"
        "--transfers=$RCLONE_TRANSFERS"
        "--retries=$RCLONE_RETRIES"
        "--retries-sleep=10s"
        "--update"
        "--backup-dir=$DELETE_BACKUP/$(date +%F)"
        "--log-file=$LOGFILE"
        "--log-level=INFO"
        "--exclude-from=$EXCLUDE_FILE"
    )

    # Выполнение синхронизации
    local cmd="rclone sync ${RCLONE_FLAGS[*]} '$dir' '$dest_dir'"
    log DEBUG "Выполняемая команда: $cmd"

    if ! retry_command "$cmd" 3 15; then
        log ERROR "Бэкап $dir завершился ошибкой"
        return 1
    fi

#    # Валидация результата
#    validate_backup "$dir" "$dest_dir" || return 1
#    log INFO "Бэкап $dir успешно завершен"
}

# Экспорт всех необходимых функций
export -f log
export -f retry_command
export -f check_ceph_access
#export -f validate_backup
export -f cleanup_old_backups
export -f backup_dir

# Основная функция бэкапа
perform_backup() {
    # Подготовка директорий
    mkdir -p "$MAIN_BACKUP" "$DELETE_BACKUP" || {
        log ERROR "Ошибка создания директорий"
        return 1
    }

    # Проверка Ceph
    if ! check_ceph_access; then
        return 1
    fi

    # Очистка устаревших данных
    cleanup_old_backups || log WARNING "Проблемы с очисткой, но продолжаем..."

    # Параллельная обработка директорий
    export -f backup_dir
    export RCLONE_CONFIG RCLONE_TRANSFERS RCLONE_RETRIES LOGFILE MAIN_BACKUP DELETE_BACKUP

    printf "%s\0" "${SOURCEDIRS[@]}" | xargs -0 -n1 -P4 -I{} bash -c '
        backup_dir "$1" || exit 1
    ' _ {} || return 1

    return 0
}

# Основной поток
log INFO "***** Начат процесс резервного копирования *****"
log INFO "Запуск от пользователя: $(whoami)"
log INFO "Права на /ceph: $(ls -ld /ceph)"
log INFO "Права на /backup: $(ls -ld /backup)"
log INFO "Версия rclone: $(rclone --version | head -n1)"
log INFO "Конфиг rclone: $RCLONE_CONFIG"
log INFO "Параметры: transfers=$RCLONE_TRANSFERS retries=$RCLONE_RETRIES"

if perform_backup; then
    log INFO "Все бэкапы успешно завершены"
else
    log ERROR "Бэкап завершился с ошибками"
    exit 1
fi