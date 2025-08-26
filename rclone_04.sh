#!/usr/bin/env bash

# Конфигурация
BACKUP_USER="backup_user"
LOGDIR="/var/log/backup"
LOCKFILE="/var/lock/backup.lock"
EXCLUDE_FILE="/usr/local/bin/scripts/exclude-file.txt"
DELETE_BACKUP="/backup/deleted"
MAIN_BACKUP="/backup/main"
SOURCEDIRS=("/ceph/data/exp/idream/")
RCLONE_TRANSFERS=${RCLONE_TRANSFERS:-30}
RCLONE_CHECKERS=${RCLONE_CHECKERS:-8}
RCLONE_RETRIES=${RCLONE_RETRIES:-5}

# Инициализация логирования
TIMESTAMP=$(date +'%Y-%m-%d_%H-%M')
LOGFILE="$LOGDIR/backup_$TIMESTAMP.log"
mkdir -p "$LOGDIR" || { echo "Не удалось создать $LOGDIR" >&2; exit 1; }

# Ротация логов
find "$LOGDIR" -type f -name 'backup_*' -mtime +30 -delete
if [[ $(find "$LOGDIR" -type f | wc -l) -gt 100 ]]; then
    log ERROR "Слишком много лог-файлов в $LOGDIR"
    exit 1
fi

# Конфигурация rclone
RCLONE_CONFIG=$(rclone config file | awk -F': ' '{print $2}' | xargs)
if [[ -z "$RCLONE_CONFIG" ]]; then
    log WARNING "Конфигурационный файл rclone не найден, продолжаем без --config"
    unset RCLONE_CONFIG
else
    log INFO "Используется конфигурационный файл rclone: $RCLONE_CONFIG"
    export RCLONE_CONFIG
fi
export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES

# Проверка файла исключений
log INFO "Проверка файла исключений: $EXCLUDE_FILE"
if [[ ! -f "$EXCLUDE_FILE" ]]; then
    log ERROR "Файл исключений $EXCLUDE_FILE не найден"
    exit 1
fi
if [[ ! -r "$EXCLUDE_FILE" ]]; then
    log ERROR "Файл исключений $EXCLUDE_FILE не доступен для чтения"
    exit 1
fi
if [[ ! -s "$EXCLUDE_FILE" ]]; then
    log WARNING "Файл исключений $EXCLUDE_FILE пустой"
fi
log INFO "Содержимое exclude-файла: $(cat "$EXCLUDE_FILE" 2>/dev/null || echo 'Не удалось прочитать')"

# Блокировка с использованием flock
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log ERROR "Скрипт уже запущен. Выход."
    exit 1
fi
trap 'flock -u 200; rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

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

# Проверка Ceph
check_ceph_access() {
    if ! grep -q '/ceph' /etc/fstab; then
        log ERROR "/ceph не настроен в fstab"
        return 1
    fi

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

    if ! ls /ceph &>/dev/null; then
        log ERROR "Нет прав доступа к /ceph. Проверить права пользователя $BACKUP_USER"
        return 1
    fi

    for dir in "${SOURCEDIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log ERROR "Директория $dir недоступна"
            return 1
        fi
    done

    # Проверка состояния Ceph через SSH и podman
    if command -v ssh >/dev/null; then
        if ! ssh cephsvc05 "podman exec ceph-mon-cephsvc05 ceph status" >/dev/null; then
            log WARNING "Проблемы с состоянием Ceph-кластера"
        else
            log INFO "Ceph-кластер в порядке"
        fi
    else
        log WARNING "Команда ssh недоступна, пропускаем проверку состояния Ceph"
    fi

    return 0
}

# Частичная валидация
validate_backup() {
    local src=$1
    local dst=$2
    log INFO "Начата частичная валидация: $src -> $dst"

    local src_count=$(rclone lsf "$src" --files-only | wc -l)
    local dst_count=$(rclone lsf "$dst" --files-only | wc -l)

    if [[ "$src_count" -eq "$dst_count" ]]; then
        log INFO "Валидация успешна: количество файлов совпадает ($src_count)"
        return 0
    else
        log ERROR "Валидация не пройдена: $src_count файлов в источнике, $dst_count в бэкапе"
        return 1
    fi
}

# Очистка устаревших данных
cleanup_old_backups() {
    log INFO "Начата очистка устаревших данных из $DELETE_BACKUP"

    if [[ ! -d "$DELETE_BACKUP" ]]; then
        log ERROR "Директория $DELETE_BACKUP недоступна"
        return 1
    fi

    local purge_cmd="rclone purge --min-age 30d '$DELETE_BACKUP' --log-level=INFO --log-file='$LOGFILE'"
    [[ -n "$RCLONE_CONFIG" ]] && purge_cmd="$purge_cmd --config='$RCLONE_CONFIG'"
    if ! retry_command "$purge_cmd"; then
        log ERROR "Ошибка при очистке устаревших данных"
        return 1
    fi

    log INFO "Очистка завершена успешно"
}

# Обработка директории
backup_dir() {
    local dir=$1
    log INFO "Начат бэкап: $dir"
    log INFO "Повторная проверка exclude-файла в backup_dir: $EXCLUDE_FILE"
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений $EXCLUDE_FILE не найден в backup_dir"
        return 1
    fi
    if [[ ! -r "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений $EXCLUDE_FILE не доступен для чтения в backup_dir"
        return 1
    fi
    log INFO "Содержимое exclude-файла в backup_dir: $(cat "$EXCLUDE_FILE" 2>/dev/null || echo 'Не удалось прочитать')"

    local dest_dir="${MAIN_BACKUP}/ceph${dir#/ceph}"
    mkdir -p "$(dirname "$dest_dir")" || {
        log ERROR "Не удалось создать $dest_dir"
        return 1
    }

    if ! ls "$dir" &>/dev/null; then
        log ERROR "Нет доступа к исходной директории: $dir"
        return 1
    fi

    local RCLONE_FLAGS=(
        --progress
        --links
        --fast-list
        --create-empty-src-dirs
        --checksum
        "--transfers=$RCLONE_TRANSFERS"
        "--checkers=$RCLONE_CHECKERS"
        "--retries=$RCLONE_RETRIES"
        "--retries-sleep=10s"
        --update
        "--backup-dir=$DELETE_BACKUP/$(date +%F)"
        "--log-file=$LOGFILE"
        --log-level=INFO
        "--exclude-from=$EXCLUDE_FILE"
    )

    [[ -n "$RCLONE_CONFIG" ]] && RCLONE_FLAGS+=(--config="$RCLONE_CONFIG")

    local cmd=(rclone sync "${RCLONE_FLAGS[@]}" "$dir" "$dest_dir")
    log DEBUG "Выполняемая команда: ${cmd[*]}"

    if ! retry_command "${cmd[*]}" 3 15; then
        log ERROR "Бэкап $dir завершился ошибкой"
        return 1
    fi

    validate_backup "$dir" "$dest_dir" || return 1
    log INFO "Бэкап $dir успешно завершен"
}

# Экспорт функций и переменных
export -f log retry_command check_ceph_access validate_backup cleanup_old_backups backup_dir
export RCLONE_CONFIG RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES LOGFILE MAIN_BACKUP DELETE_BACKUP EXCLUDE_FILE

# Основная функция
perform_backup() {
    mkdir -p "$MAIN_BACKUP" "$DELETE_BACKUP" || {
        log ERROR "Ошибка создания директорий"
        return 1
    }

    if ! check_ceph_access; then
        return 1
    fi

    cleanup_old_backups || log WARNING "Проблемы с очисткой, но продолжаем..."

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
log INFO "Параметры: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES"

if perform_backup; then
    log INFO "Все бэкапы успешно завершены"
else
    log ERROR "Бэкап завершился с ошибками"
    exit 1
fi
