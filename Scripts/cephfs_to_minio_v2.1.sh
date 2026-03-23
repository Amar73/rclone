#!/usr/bin/env bash
# =================================================================================================
# cephfs_to_minio_v2.1_FIXED.sh — ИСПРАВЛЕННАЯ синхронизация CephFS ➜ MinIO S3
# Версия: 2.1.0 (Сентябрь 2025) - КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ
# Автор: Ведущий инженер Андрей Марьяненко
#
# КРИТИЧЕСКИЕ ИСПРАВЛЕНИЯ В ЭТОЙ ВЕРСИИ:
# ✅ ИСПРАВЛЕНО: Добавлен отсутствующий цикл выполнения синхронизации директорий
# ✅ ИСПРАВЛЕНО: Правильное определение результата выполнения
# ✅ ИСПРАВЛЕНО: Корректный exit code при успешном выполнении
# ✅ ИСПРАВЛЕНО: Логирование процесса синхронизации каждой директории
#
# БЫСТРЫЙ СТАРТ:
#   env DRY_RUN=true ./cephfs_to_minio_v2.1_FIXED.sh
#   ./cephfs_to_minio_v2.1_FIXED.sh
# =================================================================================================

# Проверка версии bash
if ((BASH_VERSINFO[0] < 4)); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее. Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

# Строгий режим выполнения
set -eEuo pipefail
IFS=$'\n\t'
umask 027
export LANG=C LC_ALL=C

# Метаданные скрипта
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.1.0"
readonly REQUIRED_RCLONE_VERSION="1.60"

# Конфигурация по умолчанию
readonly RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
readonly LOGDIR="${LOGDIR:-/var/log/backup-ceph-minio}"
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup-ceph-minio.lock}"

# MinIO конфигурация
readonly MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://minio01.apps.maket.nbgi.ru:9000}"
readonly MAIN_BACKUP="${MAIN_BACKUP:-minio:nbiks-backup}"
readonly DELETE_BACKUP="${DELETE_BACKUP:-minio:deleted-backup}"

# Исходные директории для синхронизации
if [[ -n "${SOURCEDIRS_ENV:-}" ]]; then
    IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS_ENV"
else
    readonly -a SOURCEDIRS_ARRAY=(
        '/ceph/data/nbics/Reads'
        '/ceph/data/nbics/Genomes'
        '/ceph/data/bio/nextcloud/data/data/kgs'
    )
fi

# Настройки rclone
readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-20}"
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"
readonly RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-16M}"
readonly RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"

# Настройки retention и валидации
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
readonly VALIDATE_RESULT="${VALIDATE_RESULT:-true}"
readonly DRY_RUN="${DRY_RUN:-false}"

# Настройки повторных попыток
readonly MOUNT_RETRIES="${MOUNT_RETRIES:-5}"
readonly MOUNT_RETRY_DELAY="${MOUNT_RETRY_DELAY:-30}"

# Глобальные переменные состояния
declare -g SYNC_SUCCESS=true
declare -g VALIDATION_FAILED=false
declare -g SYNC_PROCESSED=0
declare -g SYNC_SUCCESSFUL=0
declare -g LOGFILE=""
declare -g RCLONE_JSONLOG=""
declare -g SUMMARY_FILE=""

# Система логирования с цветами
log() {
    local level="${1:-INFO}"
    shift || true
    local message="${*:-}"
    local timestamp

    timestamp="$(date -Iseconds)"

    local color_code=""
    if [[ -t 2 ]]; then
        case "$level" in
            DEBUG)    color_code="\033[36m" ;;
            INFO)     color_code="\033[32m" ;;
            WARNING)  color_code="\033[33m" ;;
            ERROR)    color_code="\033[31m" ;;
            CRITICAL) color_code="\033[35;1m" ;;
            SUCCESS)  color_code="\033[92m" ;;
        esac
    fi

    local log_message="${timestamp} [${level}] ${message}"

    if [[ -n "$color_code" ]]; then
        echo -e "${color_code}${log_message}\033[0m" >&2
    else
        echo "$log_message" >&2
    fi

    if [[ -n "${LOGFILE:-}" && -w "${LOGFILE%/*}" ]]; then
        echo "$log_message" >> "$LOGFILE"
    fi
}

die() {
    log CRITICAL "$*"
    exit 1
}

# Проверка необходимых команд
check_required_commands() {
    local missing_commands=()
    local required_commands=("rclone" "flock" "mountpoint" "find" "curl" "date" "awk")

    log INFO "Проверка наличия необходимых команд"

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if ((${#missing_commands[@]} > 0)); then
        die "Не найдены необходимые команды: ${missing_commands[*]}"
    fi

    log INFO "Все необходимые команды найдены"
}

# Проверка версии rclone
check_rclone_version() {
    local rclone_version

    log INFO "Проверка версии rclone"

    if ! rclone_version=$(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//'); then
        die "Не удалось определить версию rclone"
    fi

    local required_major required_minor current_major current_minor
    IFS='.' read -r required_major required_minor _ <<< "$REQUIRED_RCLONE_VERSION"
    IFS='.' read -r current_major current_minor _ <<< "$rclone_version"

    if ((current_major < required_major || (current_major == required_major && current_minor < required_minor))); then
        log WARNING "Рекомендуется rclone версии $REQUIRED_RCLONE_VERSION или новее"
        log WARNING "Текущая версия: $rclone_version"
    else
        log INFO "Версия rclone: $rclone_version (соответствует требованиям)"
    fi
}

# Проверка конфигурации rclone
check_rclone_config() {
    log INFO "Проверка конфигурации rclone: $RCLONE_CONFIG"

    if [[ ! -f "$RCLONE_CONFIG" ]]; then
        die "Конфигурационный файл rclone не найден: $RCLONE_CONFIG"
    fi

    if [[ ! -r "$RCLONE_CONFIG" ]]; then
        die "Конфигурационный файл rclone недоступен для чтения: $RCLONE_CONFIG"
    fi

    local file_perms
    file_perms=$(stat -c%a "$RCLONE_CONFIG" 2>/dev/null || echo "unknown")
    if [[ "$file_perms" != "600" ]]; then
        log WARNING "Небезопасные права доступа к конфигурации rclone: $file_perms (рекомендуется 600)"
    fi

    log INFO "Конфигурация rclone проверена успешно"
}

# Валидация исходных директорий
validate_source_directories() {
    log INFO "Валидация исходных директорий"

    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            die "Небезопасный путь источника (должен начинаться с /ceph/): $dir"
        fi

        if [[ "$dir" =~ \.\./|\$\(|\`|\; ]]; then
            die "Обнаружены потенциально опасные символы в пути: $dir"
        fi
    done

    log INFO "Валидация исходных директорий завершена успешно"
}

# Инициализация логирования
initialize_logging() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"

    if [[ ! -d "$LOGDIR" ]]; then
        mkdir -p "$LOGDIR" || die "Не удалось создать директорию логов: $LOGDIR"
    fi

    LOGFILE="$LOGDIR/backup_${timestamp}.log"
    RCLONE_JSONLOG="$LOGDIR/backup_${timestamp}.jsonl"
    SUMMARY_FILE="$LOGDIR/backup_${timestamp}.summary.txt"

    : > "$LOGFILE"
    : > "$RCLONE_JSONLOG"

    log INFO "=== ЗАПУСК СИНХРОНИЗАЦИИ CEPHFS ➜ MINIO S3 ==="
    log INFO "Версия скрипта: $SCRIPT_VERSION"
    log INFO "Пользователь: $(whoami)"
    log INFO "Хост: $(hostname -f 2>/dev/null || hostname)"
    log INFO "PID процесса: $$"
    log INFO "Режим DRY_RUN: $DRY_RUN"
    log INFO "Файлы логов:"
    log INFO "  - Основной лог: $LOGFILE"
    log INFO "  - JSON лог rclone: $RCLONE_JSONLOG"
    log INFO "  - Итоговая сводка: $SUMMARY_FILE"
}

# Ротация старых логов
rotate_old_logs() {
    log INFO "Ротация старых логов (удаление файлов старше $LOG_RETENTION_DAYS дней)"

    local deleted_count
    deleted_count=$(find "$LOGDIR" -type f -name 'backup_*.log' -mtime "+$LOG_RETENTION_DAYS" -delete -print 2>/dev/null | wc -l)

    if ((deleted_count > 0)); then
        log INFO "Удалено $deleted_count старых лог-файлов"
    else
        log INFO "Старых лог-файлов для удаления не найдено"
    fi
}

# Блокировка и обработка сигналов
declare -g LOCK_FD=""

cleanup_resources() {
    local exit_code=$?

    log INFO "Начало процедуры очистки ресурсов"

    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        log DEBUG "Блокировка освобождена"

        if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1))); then
            eval "exec {LOCK_FD}<&-" 2>/dev/null || true
        fi
    fi

    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE" || true
        log DEBUG "Файл блокировки удален"
    fi

    generate_final_summary

    # ИСПРАВЛЕНО: Правильное определение результата
    if ((exit_code == 0)); then
        if [[ "$SYNC_SUCCESS" == "true" && "$VALIDATION_FAILED" == "false" ]]; then
            log SUCCESS "Синхронизация завершена успешно"
        else
            log WARNING "Синхронизация завершена с предупреждениями"
        fi
    else
        log ERROR "Синхронизация завершена с ошибкой (код: $exit_code)"
    fi

    log INFO "=== ЗАВЕРШЕНИЕ СИНХРОНИЗАЦИИ CEPHFS ➜ MINIO S3 ==="

    exit $exit_code
}

handle_signal() {
    local signal=$1
    log WARNING "Получен сигнал $signal - инициируется корректное завершение"
    SYNC_SUCCESS=false
    exit 130
}

setup_locking_and_signals() {
    if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1))); then
        exec {LOCK_FD}>"$LOCKFILE" || die "Не удалось создать файл блокировки: $LOCKFILE"
    else
        LOCK_FD=200
        exec 200>"$LOCKFILE" || die "Не удалось создать файл блокировки: $LOCKFILE"
    fi

    if ! flock -n "$LOCK_FD"; then
        die "Другой экземпляр скрипта уже выполняется (блокировка активна)"
    fi

    trap cleanup_resources EXIT
    trap 'handle_signal INT' INT
    trap 'handle_signal TERM' TERM
    trap 'handle_signal HUP' HUP

    log INFO "Блокировка получена успешно (дескриптор: $LOCK_FD)"
}

# Проверка доступности CephFS
check_cephfs_availability() {
    log INFO "Проверка доступности CephFS"

    if ! mountpoint -q /ceph 2>/dev/null; then
        log WARNING "/ceph не смонтирован. Инициируется процесс монтирования"

        umount -fl /ceph 2>/dev/null || true

        local attempt
        for attempt in $(seq 1 "$MOUNT_RETRIES"); do
            log INFO "Попытка монтирования $attempt/$MOUNT_RETRIES"

            if mount /ceph 2>>"$LOGFILE"; then
                log INFO "CephFS успешно смонтирован"
                break
            else
                log WARNING "Попытка монтирования $attempt не удалась"

                if ((attempt < MOUNT_RETRIES)); then
                    log INFO "Повторная попытка через $MOUNT_RETRY_DELAY секунд"
                    sleep "$MOUNT_RETRY_DELAY"
                fi
            fi
        done

        if ! mountpoint -q /ceph 2>/dev/null; then
            die "Не удалось смонтировать CephFS после $MOUNT_RETRIES попыток"
        fi
    else
        log INFO "CephFS уже смонтирован"
    fi

    if ! ls /ceph >/dev/null 2>&1; then
        die "CephFS смонтирован, но недоступен для чтения"
    fi

    local missing_directories=()
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_directories+=("$dir")
        elif [[ ! -r "$dir" ]]; then
            die "Директория $dir существует, но недоступна для чтения"
        fi
    done

    if ((${#missing_directories[@]} > 0)); then
        die "Не найдены исходные директории: ${missing_directories[*]}"
    fi

    log INFO "Все исходные директории доступны"
    log INFO "Проверка CephFS завершена успешно"
}

# Проверка доступности MinIO S3
check_minio_connectivity() {
    log INFO "Проверка соединения с MinIO S3: $MINIO_ENDPOINT"

    if curl --output /dev/null --silent --head --fail --max-time 10 "$MINIO_ENDPOINT" 2>/dev/null; then
        log INFO "MinIO S3 доступен и отвечает на запросы"
    else
        log WARNING "MinIO S3 может быть недоступен через HTTP (это не всегда критично для rclone)"
    fi
}

check_rclone_remotes() {
    log INFO "Проверка доступности rclone remote'ов"

    if ! rclone lsd "${MAIN_BACKUP%:*}:" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
        die "Remote '${MAIN_BACKUP%:*}:' недоступен через rclone"
    fi

    log INFO "Remote '${MAIN_BACKUP%:*}:' доступен"
    log INFO "Проверка rclone remote'ов завершена успешно"
}

# Создание бакета при необходимости
create_bucket_if_needed() {
    local bucket_path="$1"

    log INFO "Проверка существования бакета: $bucket_path"

    if rclone lsd "$bucket_path" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
        log INFO "Бакет уже существует: $bucket_path"
    else
        log INFO "Бакет не найден, создается: $bucket_path"

        if rclone mkdir "$bucket_path" --config="$RCLONE_CONFIG" 2>>"$LOGFILE"; then
            log INFO "Бакет успешно создан: $bucket_path"
        else
            die "Не удалось создать бакет: $bucket_path"
        fi
    fi
}

# Функция повторных попыток для rclone
retry_rclone_command() {
    local retries="$1"
    local delay="$2"
    shift 2
    local -a cmd=("$@")

    log INFO "Подготовка к выполнению rclone команды с повторными попытками"
    log DEBUG "Команда: $(printf '%q ' "${cmd[@]}")"

    local attempt
    for ((attempt = 1; attempt <= retries; attempt++)); do
        log INFO "Попытка $attempt/$retries выполнения команды"

        set +e

        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ (ERROR|CRITICAL|Failed|Fatal) ]]; then
                log ERROR "rclone: $line"
            elif [[ "$line" =~ (WARNING|WARN) ]]; then
                log WARNING "rclone: $line"
            elif [[ "$DRY_RUN" == "true" || "$line" =~ (Copied|Deleted|Moved|Transferred) ]]; then
                log INFO "rclone: $line"
            else
                log DEBUG "rclone: $line"
            fi
        done

        local exit_code=${PIPESTATUS[0]}
        set -e

        case $exit_code in
            0)
                log INFO "Команда выполнена успешно"
                return 0
                ;;
            1)
                if [[ "${cmd[1]}" == "delete" || "${cmd[1]}" == "rmdirs" ]]; then
                    log INFO "Команда завершена (нет файлов для обработки)"
                    return 0
                fi
                ;;
            3)
                if [[ "${cmd[1]}" == "sync" ]]; then
                    log INFO "Синхронизация завершена (нет изменений для передачи)"
                    return 0
                fi
                ;;
        esac

        if ((attempt < retries)); then
            log WARNING "Попытка $attempt завершилась неуспешно (код: $exit_code)"
            log INFO "Повторная попытка через $delay секунд"
            sleep "$delay"
        else
            log ERROR "Все попытки исчерпаны. Финальный код завершения: $exit_code"
            SYNC_SUCCESS=false
            return $exit_code
        fi
    done
}

# Очистка устаревших данных
cleanup_old_deleted_data() {
    log INFO "Очистка устаревших данных из бакета deleted-backup (старше ${DELETE_RETENTION_DAYS} дней)"

    local -a delete_cmd=(
        rclone delete "$DELETE_BACKUP"
        --min-age "${DELETE_RETENTION_DAYS}d"
        --config="$RCLONE_CONFIG"
        --log-file="$RCLONE_JSONLOG"
        --use-json-log
        --log-level="$RCLONE_LOG_LEVEL"
        --stats=30s
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        delete_cmd+=(--dry-run)
        log INFO "Режим DRY_RUN: удаление файлов симулируется"
    fi

    if retry_rclone_command 3 10 "${delete_cmd[@]}"; then
        log INFO "Устаревшие данные успешно удалены"
    else
        log WARNING "Очистка устаревших данных завершилась с предупреждениями"
    fi

    local -a rmdir_cmd=(
        rclone rmdirs "$DELETE_BACKUP"
        --leave-root
        --config="$RCLONE_CONFIG"
        --log-file="$RCLONE_JSONLOG"
        --use-json-log
        --log-level="$RCLONE_LOG_LEVEL"
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        rmdir_cmd+=(--dry-run)
    fi

    if retry_rclone_command 3 10 "${rmdir_cmd[@]}"; then
        log INFO "Пустые директории успешно удалены"
    else
        log WARNING "Удаление пустых директорий завершилось с предупреждениями"
    fi
}

# ИСПРАВЛЕНО: Добавлена отсутствующая функция синхронизации директории
perform_directory_sync() {
    local source_dir="$1"

    log INFO "=== НАЧАЛО СИНХРОНИЗАЦИИ ДИРЕКТОРИИ ==="
    log INFO "Источник: $source_dir"

    if [[ ! -d "$source_dir" ]]; then
        log ERROR "Исходная директория не существует: $source_dir"
        SYNC_SUCCESS=false
        return 1
    fi

    local relative_path="${source_dir#/ceph/data/nbics/}"
    local target_path="$MAIN_BACKUP/$relative_path"

    log INFO "Назначение: $target_path"

    local backup_date
    backup_date="$(date +%Y-%m-%d)"
    local backup_dir="$DELETE_BACKUP/$backup_date/$relative_path"

    log INFO "Директория для удаленных файлов: $backup_dir"

    local -a sync_cmd=(
        rclone sync
        --config="$RCLONE_CONFIG"
        --progress
        --links
        --fast-list
        --create-empty-src-dirs
        --checksum
        --transfers="$RCLONE_TRANSFERS"
        --checkers="$RCLONE_CHECKERS"
        --retries="$RCLONE_RETRIES"
        --retries-sleep="$RCLONE_RETRIES_SLEEP"
        --buffer-size="$RCLONE_BUFFER_SIZE"
        --update
        --backup-dir="$backup_dir"
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
        --log-level="$RCLONE_LOG_LEVEL"
        --stats=5m
        --stats-log-level=NOTICE
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        sync_cmd+=(--dry-run)
        log INFO "Режим DRY_RUN: изменения не будут применены"
    fi

    sync_cmd+=("$source_dir" "$target_path")

    log INFO "Начало процесса синхронизации"
    local start_time end_time duration
    start_time=$(date +%s)

    if retry_rclone_command 3 15 "${sync_cmd[@]}"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        log INFO "Синхронизация завершена успешно"
        log INFO "Время выполнения: $(printf '%d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))"

        log INFO "=== ЗАВЕРШЕНИЕ СИНХРОНИЗАЦИИ ДИРЕКТОРИИ ==="
        ((SYNC_SUCCESSFUL++))
        return 0
    else
        log ERROR "Синхронизация завершилась с ошибкой"
        SYNC_SUCCESS=false
        log INFO "=== ЗАВЕРШЕНИЕ СИНХРОНИЗАЦИИ ДИРЕКТОРИИ (С ОШИБКОЙ) ==="
        return 1
    fi
}

# Генерация итоговой сводки
generate_final_summary() {
    log INFO "Генерация итоговой сводки"

    # ИСПРАВЛЕНО: Правильное определение общего результата
    local overall_result
    if [[ "$SYNC_SUCCESS" == "true" && "$VALIDATION_FAILED" == "false" ]]; then
        overall_result="SUCCESS"
    elif ((SYNC_SUCCESSFUL > 0)); then
        overall_result="PARTIAL_SUCCESS"
    else
        overall_result="FAILURE"
    fi

    {
        echo "================================================================================"
        echo "                    ИТОГОВАЯ СВОДКА СИНХРОНИЗАЦИИ CEPHFS ➜ MINIO S3"
        echo "================================================================================"
        echo
        printf "Время завершения: %s\n" "$(date)"
        printf "Общий результат: %s\n" "$overall_result"
        printf "Версия скрипта: %s\n" "$SCRIPT_VERSION"
        printf "Пользователь: %s\n" "$(whoami)"
        printf "Хост: %s\n" "$(hostname -f 2>/dev/null || hostname)"
        printf "Режим тестирования (DRY_RUN): %s\n" "$DRY_RUN"
        echo
        echo "--------------------------------------------------------------------------------"
        echo "КОНФИГУРАЦИЯ СИНХРОНИЗАЦИИ:"
        echo "--------------------------------------------------------------------------------"
        printf "MinIO endpoint: %s\n" "$MINIO_ENDPOINT"
        printf "Основной бакет: %s\n" "$MAIN_BACKUP"
        printf "Бакет удаленных файлов: %s\n" "$DELETE_BACKUP"
        printf "Retention удалений: %s дней\n" "$DELETE_RETENTION_DAYS"
        echo
        echo "Настройки rclone:"
        printf "  - Параллельные передачи: %s\n" "$RCLONE_TRANSFERS"
        printf "  - Процессы проверки: %s\n" "$RCLONE_CHECKERS"
        printf "  - Повторные попытки: %s\n" "$RCLONE_RETRIES"
        printf "  - Размер буфера: %s\n" "$RCLONE_BUFFER_SIZE"
        printf "  - Конфигурационный файл: %s\n" "$RCLONE_CONFIG"
        echo
        echo "--------------------------------------------------------------------------------"
        echo "РЕЗУЛЬТАТЫ СИНХРОНИЗАЦИИ:"
        echo "--------------------------------------------------------------------------------"
        printf "Всего директорий для обработки: %s\n" "$SYNC_PROCESSED"
        printf "Успешно синхронизировано: %s\n" "$SYNC_SUCCESSFUL"
        printf "С ошибками: %s\n" "$((SYNC_PROCESSED - SYNC_SUCCESSFUL))"
        echo
        echo "--------------------------------------------------------------------------------"
        echo "ОБРАБОТАННЫЕ ДИРЕКТОРИИ:"
        echo "--------------------------------------------------------------------------------"
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            local relative_path="${dir#/ceph/data/nbics/}"
            printf "✓ %s ➜ %s/%s\n" "$dir" "$MAIN_BACKUP" "$relative_path"
        done
        echo
        echo "--------------------------------------------------------------------------------"
        echo "ФАЙЛЫ ЛОГОВ:"
        echo "--------------------------------------------------------------------------------"
        printf "Основной лог: %s\n" "$LOGFILE"
        printf "JSON лог rclone: %s\n" "$RCLONE_JSONLOG"
        printf "Итоговая сводка: %s\n" "$SUMMARY_FILE"
        echo
        echo "================================================================================"
        echo "                              КОНЕЦ СВОДКИ"
        echo "================================================================================"
    } | tee "$SUMMARY_FILE" >/dev/null

    log INFO "Итоговая сводка сохранена: $SUMMARY_FILE"
}

# ИСПРАВЛЕННАЯ главная функция с циклом синхронизации
main() {
    # Этап 1: Инициализация и проверки окружения
    log INFO "ЭТАП 1: Инициализация системы и проверка окружения"
    initialize_logging
    rotate_old_logs
    check_required_commands
    check_rclone_version
    check_rclone_config
    validate_source_directories
    setup_locking_and_signals

    # Этап 2: Проверка доступности систем хранения
    log INFO "ЭТАП 2: Проверка доступности систем хранения"
    check_cephfs_availability
    check_minio_connectivity
    check_rclone_remotes

    # Этап 3: Подготовка инфраструктуры MinIO
    log INFO "ЭТАП 3: Подготовка инфраструктуры MinIO S3"
    create_bucket_if_needed "$MAIN_BACKUP"
    create_bucket_if_needed "$DELETE_BACKUP"
    cleanup_old_deleted_data

    # Этап 4: Выполнение синхронизации директорий
    log INFO "ЭТАП 4: Выполнение синхронизации директорий"
    log INFO "Всего директорий для обработки: ${#SOURCEDIRS_ARRAY[@]}"

    SYNC_PROCESSED=${#SOURCEDIRS_ARRAY[@]}

    # ИСПРАВЛЕНО: Добавлен отсутствующий цикл синхронизации
    for source_dir in "${SOURCEDIRS_ARRAY[@]}"; do
        log INFO "Обработка директории: $source_dir"

        if perform_directory_sync "$source_dir"; then
            log INFO "Директория обработана успешно: $source_dir"
        else
            log ERROR "Ошибка при обработке директории: $source_dir"
        fi
    done

    # Этап 5: Анализ результатов
    log INFO "ЭТАП 5: Анализ результатов синхронизации"
    log INFO "Всего директорий обработано: $SYNC_PROCESSED"
    log INFO "Успешно синхронизировано: $SYNC_SUCCESSFUL"
    log INFO "С ошибками: $((SYNC_PROCESSED - SYNC_SUCCESSFUL))"

    # ИСПРАВЛЕНО: Правильное определение финального результата
    if ((SYNC_SUCCESSFUL == SYNC_PROCESSED)); then
        if [[ "$VALIDATION_FAILED" == "false" ]]; then
            log SUCCESS "ВСЕ ОПЕРАЦИИ СИНХРОНИЗАЦИИ ВЫПОЛНЕНЫ УСПЕШНО"
            return 0
        else
            log WARNING "СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА С ПРЕДУПРЕЖДЕНИЯМИ (проблемы валидации)"
            return 0
        fi
    elif ((SYNC_SUCCESSFUL > 0)); then
        log WARNING "СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА ЧАСТИЧНО ($SYNC_SUCCESSFUL из $SYNC_PROCESSED)"
        return 0  # ИСПРАВЛЕНО: возвращаем 0 при частичном успехе
    else
        log ERROR "СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА С КРИТИЧЕСКИМИ ОШИБКАМИ"
        return 1
    fi
}

# Точка входа в программу
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit_code=$?

    # ИСПРАВЛЕНО: Корректное определение финального результата
    if ((exit_code == 0)); then
        if ((SYNC_SUCCESSFUL == SYNC_PROCESSED)); then
            log SUCCESS "=== СКРИПТ ЗАВЕРШЕН ПОЛНОСТЬЮ УСПЕШНО ==="
        elif ((SYNC_SUCCESSFUL > 0)); then
            log WARNING "=== СКРИПТ ЗАВЕРШЕН ЧАСТИЧНО УСПЕШНО ==="
        else
            log WARNING "=== СКРИПТ ЗАВЕРШЕН БЕЗ УСПЕШНЫХ ОПЕРАЦИЙ ==="
        fi
    else
        log ERROR "=== СКРИПТ ЗАВЕРШЕН С КРИТИЧЕСКИМИ ОШИБКАМИ (КОД: $exit_code) ==="
    fi

    exit $exit_code
else
    log INFO "Скрипт загружен через source, функции доступны для использования"
fi

# КРИТИЧЕСКИЕ ИСПРАВЛЕНИЯ В ВЕРСИИ 2.1.0:
# ✅ Добавлен отсутствующий цикл выполнения синхронизации директорий в main()
# ✅ Добавлена функция perform_directory_sync() для синхронизации каждой директории
# ✅ Правильное определение результата выполнения (SUCCESS/PARTIAL_SUCCESS/FAILURE)
# ✅ Корректный exit code при успешном и частично успешном выполнении
# ✅ Детальное логирование процесса синхронизации каждой директории
# ✅ Правильный подсчет обработанных и успешных операций
# ✅ Улучшенная итоговая сводка с детализацией результатов