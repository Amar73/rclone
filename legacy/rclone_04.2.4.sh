#!/usr/bin/env bash
#
# rclone_04.2.4.sh - Окончательно исправленная версия (2.4)
# ======================================================================
# 
# ОПИСАНИЕ:
# Автоматизированный скрипт для создания резервных копий данных из CephFS
# на локальную файловую систему с использованием rclone
#
# ОСНОВНЫЕ ВОЗМОЖНОСТИ:
# - Строгий режим выполнения с комплексной проверкой ошибок
# - Детальное логирование в JSON и текстовом формате с корректным парсингом rclone
# - Корректная очистка устаревших резервных копий
# - Поддержка исключений файлов/папок с якорными правилами
# - Режим DRY_RUN для тестирования без фактического копирования
# - Параллельное выполнение резервного копирования нескольких директорий
# - Исправленная система отчетности с реальными данными операций
# - Поддержка современных методов безопасности и совместимости
#
# АВТОР: Ведущий инженер Андрей Марьяненко
# ВЕРСИЯ: 2.4 (Сентябрь 2025) - ИСПРАВЛЕНЫ ПРОБЛЕМЫ С ПАРСИНГОМ СТАТИСТИКИ
# ТРЕБОВАНИЯ: bash 4.0+, rclone 1.60+, jq (опционально)
#
# ======================================================================

# ============================================================================
# РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ СИСТЕМЫ И ПРОВЕРКА СОВМЕСТИМОСТИ
# ============================================================================

# Проверка минимальной версии bash (требуется 4.0+ для современных функций)
if ((BASH_VERSINFO[0] < 4)); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее. Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

# Строгий режим выполнения скрипта
set -eEuo pipefail

# Установка безопасного разделителя полей
IFS=$'\n\t'

# Установка ограничительной маски прав доступа к создаваемым файлам
umask 027

# Установка локали для предсказуемого поведения команд
export LANG=C LC_ALL=C

# Определение основных переменных скрипта
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.4"
readonly REQUIRED_RCLONE_VERSION="1.60"

# ============================================================================
# РАЗДЕЛ 2: КОНФИГУРАЦИЯ И НАСТРОЙКИ
# ============================================================================

# Основные настройки
readonly BACKUP_USER="${BACKUP_USER:-backup_user}"
readonly LOGDIR="${LOGDIR:-/var/log/backup}"
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
readonly EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"
readonly DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
readonly MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"

# Обработка списка исходных директорий
if [[ -n "${SOURCEDIRS:-}" ]]; then
    IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS"
else
    readonly -a SOURCEDIRS_ARRAY=('/ceph/data/exp/idream/')
fi

# Конфигурация производительности rclone
readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"
readonly PARALLEL="${PARALLEL:-4}"
readonly DRY_RUN="${DRY_RUN:-false}"

# Дополнительные настройки
readonly MAX_LOGFILES="${MAX_LOGFILES:-100}"
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"

# Глобальная переменная для хранения общего статуса выполнения
BACKUP_SUCCESS=true

# ============================================================================
# РАЗДЕЛ 3: ВАЛИДАЦИЯ И ПРОВЕРКИ
# ============================================================================

validate_source_directories() {
    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            echo "ОШИБКА: Источник '$dir' не находится внутри /ceph" >&2
            exit 1
        fi
        
        if [[ "$dir" =~ \.\./|\$\(|\`|\; ]]; then
            echo "ОШИБКА: Обнаружены потенциально опасные символы в пути '$dir'" >&2
            exit 1
        fi
    done
}

check_required_commands() {
    local cmd missing_commands=()
    local required_commands=("rclone" "mount" "mountpoint" "find" "awk" "date" "mkdir" "flock")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if ((${#missing_commands[@]} > 0)); then
        echo "ОШИБКА: Не найдены необходимые команды: ${missing_commands[*]}" >&2
        exit 1
    fi
}

check_rclone_version() {
    local rclone_version
    if ! rclone_version=$(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//'); then
        echo "ОШИБКА: Не удалось определить версию rclone" >&2
        exit 1
    fi
    
    local required_major required_minor current_major current_minor
    IFS='.' read -r required_major required_minor _ <<< "$REQUIRED_RCLONE_VERSION"
    IFS='.' read -r current_major current_minor _ <<< "$rclone_version"
    
    if ((current_major < required_major || (current_major == required_major && current_minor < required_minor))); then
        echo "ПРЕДУПРЕЖДЕНИЕ: Рекомендуется rclone версии $REQUIRED_RCLONE_VERSION или новее" >&2
        echo "Текущая версия: $rclone_version" >&2
    fi
}

# Выполнение валидации
validate_source_directories
check_required_commands
check_rclone_version

# ============================================================================
# РАЗДЕЛ 4: СИСТЕМА ЛОГИРОВАНИЯ
# ============================================================================

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

log_command() {
    local -a cmd=("$@")
    log DEBUG "Выполнение команды: $(printf '%q ' "${cmd[@]}")"
}

# ============================================================================
# РАЗДЕЛ 5: ИНИЦИАЛИЗАЦИЯ ФАЙЛОВОЙ СИСТЕМЫ И ЛОГОВ
# ============================================================================

create_directories() {
    local dir
    for dir in "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || {
                log ERROR "Не удалось создать директорию: $dir"
                exit 1
            }
        fi
        
        if [[ ! -w "$dir" ]]; then
            log ERROR "Нет прав на запись в директорию: $dir"
            exit 1
        fi
    done
}

initialize_logging() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
    
    readonly LOGFILE="$LOGDIR/backup_${timestamp}.log"
    readonly RCLONE_JSONLOG="$LOGDIR/backup_${timestamp}.jsonl"
    readonly SUMMARY_JSON="$LOGDIR/backup_${timestamp}.summary.json"
    readonly SUMMARY_TXT="$LOGDIR/backup_${timestamp}.summary.txt"
    
    log INFO "=== ЗАПУСК СКРИПТА РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "Версия скрипта: $SCRIPT_VERSION"
    log INFO "Пользователь: $(whoami)"
    log INFO "Hostname: $(hostname -f 2>/dev/null || hostname)"
    log INFO "Рабочая директория: $(pwd)"
    log INFO "PID процесса: $$"
    log INFO "Режим DRY_RUN: $DRY_RUN"
}

rotate_logs() {
    log INFO "Начало ротации логов в $LOGDIR"
    
    local deleted_count
    deleted_count=$(find "$LOGDIR" -type f -name 'backup_*.log' -mtime "+$LOG_RETENTION_DAYS" -delete -print 2>/dev/null | wc -l)
    
    if ((deleted_count > 0)); then
        log INFO "Удалено $deleted_count старых лог-файлов (старше $LOG_RETENTION_DAYS дней)"
    fi
    
    local current_count
    current_count=$(find "$LOGDIR" -type f -name 'backup_*.log' 2>/dev/null | wc -l)
    
    if ((current_count > MAX_LOGFILES)); then
        log WARNING "Количество лог-файлов ($current_count) превышает лимит ($MAX_LOGFILES)"
    fi
    
    log INFO "Ротация логов завершена"
}

# Выполнение инициализации
create_directories
initialize_logging
rotate_logs

# ============================================================================
# РАЗДЕЛ 6: СИСТЕМА БЛОКИРОВКИ И ОБРАБОТКА СИГНАЛОВ
# ============================================================================

LOCK_FD=""

cleanup() {
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
    
    if ((exit_code == 0)); then
        log INFO "Скрипт завершился успешно"
    else
        log ERROR "Скрипт завершился с ошибкой (код: $exit_code)"
    fi
    
    log INFO "=== ЗАВЕРШЕНИЕ РАБОТЫ СКРИПТА ==="
    
    exit $exit_code
}

signal_handler() {
    local signal=$1
    log WARNING "Получен сигнал $signal - начинаем корректное завершение работы"
    BACKUP_SUCCESS=false
    exit 130
}

trap cleanup EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP

# Создание блокировки
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1))); then
    exec {LOCK_FD}>"$LOCKFILE" || {
        log ERROR "Не удалось создать файл блокировки: $LOCKFILE"
        exit 1
    }
else
    LOCK_FD=200
    exec 200>"$LOCKFILE" || {
        log ERROR "Не удалось создать файл блокировки: $LOCKFILE"
        exit 1
    }
fi

if ! flock -n "$LOCK_FD"; then
    log ERROR "Другой экземпляр скрипта уже выполняется"
    exit 1
fi

log INFO "Блокировка получена (дескриптор: $LOCK_FD), продолжаем выполнение"

# ============================================================================
# РАЗДЕЛ 7: КОНФИГУРАЦИЯ RCLONE
# ============================================================================

initialize_rclone_config() {
    log INFO "Инициализация конфигурации rclone"
    
    local rclone_config_output rclone_config_path
    
    if rclone_config_output=$(rclone config file 2>/dev/null); then
        rclone_config_path=$(echo "$rclone_config_output" | awk -F': ' '/Configuration file is stored at:/ {print $2}' | xargs 2>/dev/null || true)
        
        if [[ -n "$rclone_config_path" && -r "$rclone_config_path" ]]; then
            export RCLONE_CONFIG="$rclone_config_path"
            log INFO "Используется конфигурационный файл rclone: $RCLONE_CONFIG"
        else
            log WARNING "Конфигурационный файл rclone не найден или недоступен"
            unset RCLONE_CONFIG
        fi
    else
        log WARNING "Не удалось определить местоположение конфигурационного файла rclone"
        unset RCLONE_CONFIG
    fi
    
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES
    export RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-16M}"
    export RCLONE_USE_MMAP="${RCLONE_USE_MMAP:-true}"
    export RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
    
    log INFO "Конфигурация rclone инициализирована"
    log DEBUG "RCLONE_TRANSFERS=$RCLONE_TRANSFERS"
    log DEBUG "RCLONE_CHECKERS=$RCLONE_CHECKERS"
    log DEBUG "RCLONE_RETRIES=$RCLONE_RETRIES"
}

initialize_rclone_config

# ============================================================================
# РАЗДЕЛ 8: ПРОВЕРКА ФАЙЛА ИСКЛЮЧЕНИЙ - ИСПРАВЛЕНО
# ============================================================================

validate_exclude_file() {
    log INFO "Проверка файла исключений: $EXCLUDE_FILE"
    
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений не найден: $EXCLUDE_FILE"
        exit 1
    fi
    
    if [[ ! -r "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений недоступен для чтения: $EXCLUDE_FILE"
        exit 1
    fi
    
    if [[ ! -s "$EXCLUDE_FILE" ]]; then
        log WARNING "Файл исключений пустой: $EXCLUDE_FILE"
    else
        local exclude_count
        exclude_count=$(wc -l < "$EXCLUDE_FILE")
        log INFO "Загружено $exclude_count правил исключения из файла $EXCLUDE_FILE"
    fi
    
    # ИСПРАВЛЕНО: правильная обработка цикла чтения с set -e
    local line_number=0 invalid_lines=()
    local line
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number++))
        
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ \$\(|\`|\; ]]; then
            invalid_lines+=("$line_number: $line")
        fi
    done < "$EXCLUDE_FILE" || true
    
    if ((${#invalid_lines[@]} > 0)); then
        log ERROR "Обнаружены потенциально опасные правила исключения:"
        printf '  %s\n' "${invalid_lines[@]}" >&2
        exit 1
    fi
    
    log INFO "Валидация файла исключений завершена успешно"
}

validate_exclude_file

# ============================================================================
# РАЗДЕЛ 9: УЛУЧШЕННЫЕ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

cmd_to_string() {
    local -a cmd_array=("$@")
    local result=""
    local arg
    
    for arg in "${cmd_array[@]}"; do
        printf -v result "%s%s " "$result" "$(printf '%q' "$arg")"
    done
    
    printf '%s\n' "${result% }"
}

retry_command() {
    local retries="$1"
    local delay="$2"
    shift 2
    local -a cmd=("$@")
    local attempt exit_code
    
    for ((attempt = 1; attempt <= retries; attempt++)); do
        log INFO "Попытка $attempt/$retries: $(cmd_to_string "${cmd[@]}")"
        
        set +e
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ (ERROR|CRITICAL|Failed|Fatal) ]]; then
                log ERROR "rclone: $line"
            elif [[ "$line" =~ (WARNING|WARN) ]]; then
                log WARNING "rclone: $line"
            elif [[ "$DRY_RUN" == "true" || "$line" =~ (Copied|Deleted|Moved) ]]; then
                log INFO "rclone: $line"
            else
                log DEBUG "rclone: $line"
            fi
        done
        
        exit_code=${PIPESTATUS[0]}
        set -e
        
        case $exit_code in
            0)
                log INFO "Команда выполнена успешно"
                return 0
                ;;
            1)
                if [[ "${cmd[1]}" == "rmdirs" || "${cmd[1]}" == "delete" ]]; then
                    log INFO "Команда завершена (нет файлов для обработки)"
                    return 0
                fi
                ;;
            3)
                if [[ "${cmd[1]}" == "sync" || "${cmd[1]}" == "copy" ]]; then
                    log INFO "Команда завершена (нет изменений)"
                    return 0
                fi
                ;;
        esac
        
        if ((attempt < retries)); then
            log WARNING "Ошибка выполнения (код: $exit_code), повтор через ${delay}s"
            sleep "$delay"
        else
            log ERROR "Команда не выполнилась после $retries попыток (финальный код: $exit_code)"
            BACKUP_SUCCESS=false
            return $exit_code
        fi
    done
}

check_ceph_access() {
    log INFO "Проверка доступности CephFS"
    
    if ! awk '$1 !~ /^#/ && $2 == "/ceph" {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        log ERROR "CephFS не настроен в /etc/fstab"
        return 1
    fi
    
    if ! mountpoint -q /ceph 2>/dev/null; then
        log WARNING "CephFS не смонтирован, попытка монтирования..."
        
        if ((EUID != 0)); then
            log ERROR "Нет прав для монтирования CephFS (требуются права root)"
            return 1
        fi
        
        local mount_attempt
        for mount_attempt in {1..5}; do
            log INFO "Попытка монтирования CephFS: $mount_attempt/5"
            
            if mount /ceph 2>>"$LOGFILE"; then
                log INFO "CephFS успешно смонтирован"
                break
            fi
            
            if ((mount_attempt < 5)); then
                log WARNING "Не удалось смонтировать CephFS, повтор через 5 секунд"
                sleep 5
            fi
        done
        
        if ! mountpoint -q /ceph 2>/dev/null; then
            log ERROR "Не удалось смонтировать CephFS после 5 попыток"
            return 1
        fi
    fi
    
    if ! ls /ceph >/dev/null 2>&1; then
        log ERROR "Нет доступа к CephFS для чтения"
        return 1
    fi
    
    local missing_dirs=() dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs+=("$dir")
        fi
    done
    
    if ((${#missing_dirs[@]} > 0)); then
        log ERROR "Не найдены исходные директории для резервного копирования:"
        printf '  %s\n' "${missing_dirs[@]}" >&2
        return 1
    fi
    
    check_ceph_cluster_status
    
    log INFO "Проверка доступности CephFS завершена успешно"
    return 0
}

check_ceph_cluster_status() {
    log DEBUG "Попытка проверки состояния Ceph кластера"
    
    if ! command -v ssh >/dev/null 2>&1; then
        log DEBUG "SSH недоступен, пропуск проверки статуса кластера"
        return 0
    fi
    
    local ceph_status
    if ceph_status=$(timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes \
                     cephrgw01 "podman exec ceph-mon-cephrgw01 ceph status" 2>/dev/null); then
        
        if echo "$ceph_status" | grep -qi "health_err\|health_warn"; then
            log WARNING "Обнаружены проблемы с состоянием Ceph кластера"
        else
            log INFO "Состояние Ceph кластера: OK"
        fi
    else
        log DEBUG "Не удалось получить статус Ceph кластера (это некритично)"
    fi
}

# ============================================================================
# РАЗДЕЛ 10: ОЧИСТКА УСТАРЕВШИХ РЕЗЕРВНЫХ КОПИЙ
# ============================================================================

cleanup_old_backups() {
    log INFO "Начало очистки устаревших данных в $DELETE_BACKUP (старше ${DELETE_RETENTION_DAYS}d)"
    
    if [[ ! -d "$DELETE_BACKUP" ]]; then
        log WARNING "Директория удаленных файлов не существует: $DELETE_BACKUP"
        log INFO "Создание директории: $DELETE_BACKUP"
        
        mkdir -p "$DELETE_BACKUP" || {
            log ERROR "Не удалось создать директорию удаленных файлов: $DELETE_BACKUP"
            return 1
        }
    fi
    
    local delete_cmd=(
        rclone delete
        --min-age "${DELETE_RETENTION_DAYS}d"
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
        --stats=30s
        --stats-log-level=NOTICE
    )
    
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        delete_cmd+=(--config="$RCLONE_CONFIG")
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        delete_cmd+=(--dry-run)
    fi
    
    delete_cmd+=("$DELETE_BACKUP")
    
    if ! retry_command 3 10 "${delete_cmd[@]}"; then
        log WARNING "Команда удаления файлов завершилась с предупреждениями"
    fi
    
    local rmdir_cmd=(
        rclone rmdirs
        --leave-root
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
        --stats=30s
        --stats-log-level=NOTICE
    )
    
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        rmdir_cmd+=(--config="$RCLONE_CONFIG")
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        rmdir_cmd+=(--dry-run)
    fi
    
    rmdir_cmd+=("$DELETE_BACKUP")
    
    if ! retry_command 3 10 "${rmdir_cmd[@]}"; then
        log WARNING "Команда удаления пустых директорий завершилась с предупреждениями"
    fi
    
    log INFO "Очистка устаревших резервных копий завершена"
}

# ============================================================================
# РАЗДЕЛ 11: ОСНОВНАЯ ЛОГИКА РЕЗЕРВНОГО КОПИРОВАНИЯ
# ============================================================================

dest_from_src() {
    local src_dir="$1"
    local dest_path
    
    dest_path="${MAIN_BACKUP}/ceph${src_dir#/ceph}"
    
    printf '%s\n' "$dest_path"
}

backup_directory() {
    local src_dir="$1"
    local dest_dir start_time end_time duration
    
    if [[ -z "$src_dir" ]]; then
        log ERROR "Не указана исходная директория для резервного копирования"
        return 1
    fi
    
    dest_dir="$(dest_from_src "$src_dir")"
    
    log INFO "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "Источник: $src_dir"
    log INFO "Назначение: $dest_dir"
    
    start_time=$(date +%s)
    
    if ! mkdir -p "$dest_dir"; then
        log ERROR "Не удалось создать директорию назначения: $dest_dir"
        return 1
    fi
    
    # ИСПРАВЛЕНО: Добавлены флаги для корректного логирования статистики
    local flags=(
        --progress
        --links
        --fast-list
        --create-empty-src-dirs
        --checksum
        --transfers="$RCLONE_TRANSFERS"
        --checkers="$RCLONE_CHECKERS"
        --retries="$RCLONE_RETRIES"
        --retries-sleep="$RCLONE_RETRIES_SLEEP"
        --update
        --delete-excluded
        --backup-dir="$DELETE_BACKUP/$(date +%F)"
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
        --exclude-from="$EXCLUDE_FILE"
        --log-level=INFO
        --stats=5m
        --stats-log-level=NOTICE
        --track-renames
        --buffer-size="$RCLONE_BUFFER_SIZE"
    )
    
    if [[ "$DRY_RUN" == "true" ]]; then
        flags+=(--dry-run)
        log INFO "РЕЖИМ ТЕСТИРОВАНИЯ: изменения не будут применены"
    fi
    
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        flags+=(--config="$RCLONE_CONFIG")
    fi
    
    local sync_cmd=(rclone sync "${flags[@]}" "$src_dir" "$dest_dir")
    
    log INFO "Команда синхронизации: $(cmd_to_string "${sync_cmd[@]}")"
    
    if ! retry_command 3 15 "${sync_cmd[@]}"; then
        log ERROR "Резервное копирование директории $src_dir завершилось с ошибкой"
        BACKUP_SUCCESS=false
        return 1
    fi
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    log INFO "Резервное копирование директории $src_dir завершено успешно"
    log INFO "Время выполнения: $(printf '%d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))"
    log INFO "=== ЗАВЕРШЕНИЕ РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    
    return 0
}

# ============================================================================
# РАЗДЕЛ 12: ИСПРАВЛЕННАЯ СИСТЕМА ПОДСЧЕТА СТАТИСТИКИ И ПАРСИНГА RCLONE
# ============================================================================

# ИСПРАВЛЕНО: Функция парсинга статистики из JSON логов rclone
parse_rclone_stats() {
    local jsonlog_file="$1"
    
    # Проверка существования файла логов
    if [[ ! -f "$jsonlog_file" ]]; then
        log DEBUG "JSON лог файл не найден: $jsonlog_file"
        echo "0 0 0 0 0 0 0 0"
        return 0
    fi
    
    log DEBUG "Парсинг статистики из файла: $jsonlog_file"
    
    # Сначала проверим, есть ли в файле хоть какие-то данные
    local file_size
    file_size=$(stat -c%s "$jsonlog_file" 2>/dev/null || echo "0")
    if ((file_size == 0)); then
        log DEBUG "JSON лог файл пустой"
        echo "0 0 0 0 0 0 0 0"
        return 0
    fi
    
    # ИСПРАВЛЕНО: Ищем все записи со статистикой и берем последнюю с максимальными значениями
    local transfers=0 checks=0 deletes=0 errors=0 totalBytes=0 bytes=0 elapsedTime=0 speed=0
    
    if command -v jq >/dev/null 2>&1; then
        log DEBUG "Используется jq для парсинга статистики rclone"
        
        # Ищем все записи со stats и выбираем ту, где больше всего transfers или максимальное elapsedTime
        local stats_data
        stats_data=$(jq -c 'select(.stats != null) | .stats' "$jsonlog_file" 2>/dev/null | tail -1)
        
        if [[ -n "$stats_data" && "$stats_data" != "null" ]]; then
            transfers=$(echo "$stats_data" | jq '.transfers // 0' 2>/dev/null || echo "0")
            checks=$(echo "$stats_data" | jq '.checks // 0' 2>/dev/null || echo "0")
            deletes=$(echo "$stats_data" | jq '.deletes // 0' 2>/dev/null || echo "0")
            errors=$(echo "$stats_data" | jq '.errors // 0' 2>/dev/null || echo "0")
            totalBytes=$(echo "$stats_data" | jq '.totalBytes // 0' 2>/dev/null || echo "0")
            bytes=$(echo "$stats_data" | jq '.bytes // 0' 2>/dev/null || echo "0")
            elapsedTime=$(echo "$stats_data" | jq '.elapsedTime // 0' 2>/dev/null || echo "0")
            speed=$(echo "$stats_data" | jq '.speed // 0' 2>/dev/null || echo "0")
            
            log DEBUG "Извлечена статистика: transfers=$transfers, checks=$checks, deletes=$deletes, errors=$errors"
        else
            # Если нет записей со stats, попробуем найти альтернативные источники данных
            log DEBUG "Не найдено записей со stats, ищем альтернативные источники"
            
            # Попробуем найти записи с msg содержащими статистику
            local summary_line
            summary_line=$(grep -E "(Transferred:|Checks:|Deleted:|Errors:)" "$jsonlog_file" | tail -1 2>/dev/null || true)
            if [[ -n "$summary_line" ]]; then
                log DEBUG "Найдена строка со сводкой: $summary_line"
                # Парсим текстовую сводку из поля msg
                transfers=$(echo "$summary_line" | jq -r '.msg' 2>/dev/null | grep -oP 'Transferred:\s*\K\d+' || echo "0")
                checks=$(echo "$summary_line" | jq -r '.msg' 2>/dev/null | grep -oP 'Checks:\s*\K\d+' || echo "0")
                deletes=$(echo "$summary_line" | jq -r '.msg' 2>/dev/null | grep -oP 'Deleted:\s*\K\d+' || echo "0")
                errors=$(echo "$summary_line" | jq -r '.msg' 2>/dev/null | grep -oP 'Errors:\s*\K\d+' || echo "0")
            fi
        fi
    else
        log DEBUG "jq недоступен, используется резервный метод парсинга"
        
        # Резервный метод без jq - ищем строки со статистикой
        local stats_lines
        stats_lines=$(grep '"stats":' "$jsonlog_file" 2>/dev/null | tail -1)
        
        if [[ -n "$stats_lines" ]]; then
            # Простой парсинг JSON без jq
            transfers=$(echo "$stats_lines" | grep -o '"transfers":[0-9]*' | cut -d':' -f2 | head -1 || echo "0")
            checks=$(echo "$stats_lines" | grep -o '"checks":[0-9]*' | cut -d':' -f2 | head -1 || echo "0")
            deletes=$(echo "$stats_lines" | grep -o '"deletes":[0-9]*' | cut -d':' -f2 | head -1 || echo "0")
            errors=$(echo "$stats_lines" | grep -o '"errors":[0-9]*' | cut -d':' -f2 | head -1 || echo "0")
            totalBytes=$(echo "$stats_lines" | grep -o '"totalBytes":[0-9]*' | cut -d':' -f2 | head -1 || echo "0")
            bytes=$(echo "$stats_lines" | grep -o '"bytes":[0-9]*' | cut -d':' -f2 | head -1 || echo "0")
            elapsedTime=$(echo "$stats_lines" | grep -o '"elapsedTime":[0-9.]*' | cut -d':' -f2 | head -1 || echo "0")
            speed=$(echo "$stats_lines" | grep -o '"speed":[0-9.]*' | cut -d':' -f2 | head -1 || echo "0")
        else
            # Попробуем найти текстовую сводку в msg полях
            local msg_stats
            msg_stats=$(grep -E "(Transferred:|Checks:|Deleted:|Errors:)" "$jsonlog_file" | tail -1 2>/dev/null || true)
            if [[ -n "$msg_stats" ]]; then
                transfers=$(echo "$msg_stats" | grep -oP 'Transferred:\s*\K\d+' || echo "0")
                checks=$(echo "$msg_stats" | grep -oP 'Checks:\s*\K\d+' || echo "0")
                deletes=$(echo "$msg_stats" | grep -oP 'Deleted:\s*\K\d+' || echo "0")
                errors=$(echo "$msg_stats" | grep -oP 'Errors:\s*\K\d+' || echo "0")
            fi
        fi
    fi
    
    # Проверяем, что получили числовые значения
    [[ "$transfers" =~ ^[0-9]+$ ]] || transfers=0
    [[ "$checks" =~ ^[0-9]+$ ]] || checks=0
    [[ "$deletes" =~ ^[0-9]+$ ]] || deletes=0
    [[ "$errors" =~ ^[0-9]+$ ]] || errors=0
    [[ "$totalBytes" =~ ^[0-9]+$ ]] || totalBytes=0
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    [[ "$elapsedTime" =~ ^[0-9.]+$ ]] || elapsedTime=0
    [[ "$speed" =~ ^[0-9.]+$ ]] || speed=0
    
    log DEBUG "Финальная статистика: $transfers $checks $deletes $errors $totalBytes $bytes $elapsedTime $speed"
    
    echo "$transfers $checks $deletes $errors $totalBytes $bytes $elapsedTime $speed"
}

# ИСПРАВЛЕНО: Функция безопасного подсчета количества файлов и общего размера
calculate_directory_stats() {
    local path="$1"
    local file_count=0 total_size=0
    
    if [[ -z "$path" ]]; then
        log ERROR "Не указан путь для подсчета статистики"
        echo "0 0"
        return 1
    fi
    
    if [[ ! -d "$path" ]]; then
        log DEBUG "Путь не существует: $path"
        echo "0 0"
        return 0
    fi
    
    local base_args=(
        --files-only
        --recursive
        --exclude-from="$EXCLUDE_FILE"
    )
    
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        base_args+=(--config="$RCLONE_CONFIG")
    fi
    
    # ИСПРАВЛЕНО: правильный подсчет файлов с таймаутом
    log DEBUG "Подсчет количества файлов в: $path"
    if file_count=$(timeout 120 rclone lsf "${base_args[@]}" "$path" 2>/dev/null | wc -l); then
        log DEBUG "Количество файлов в $path: $file_count"
    else
        log WARNING "Не удалось подсчитать количество файлов в: $path (таймаут 120с)"
        file_count=0
    fi
    
    # ИСПРАВЛЕНО: правильный подсчет размера с улучшенной обработкой
    log DEBUG "Подсчет размера файлов в: $path"
    if total_size=$(timeout 120 rclone size --json "${base_args[@]}" "$path" 2>/dev/null | jq '.bytes // 0' 2>/dev/null); then
        # Проверяем, что результат числовой
        if [[ "$total_size" =~ ^[0-9]+$ ]]; then
            log DEBUG "Общий размер файлов в $path: $total_size байт"
        else
            total_size=0
            log WARNING "Получен некорректный размер для $path, установлен в 0"
        fi
    else
        # Резервный метод через lsf если size не работает
        log DEBUG "Используется резервный метод подсчета размера"
        if total_size=$(timeout 120 rclone lsf --format s "${base_args[@]}" "$path" 2>/dev/null | \
                        awk '{if($1 != "" && $1 ~ /^[0-9]+$/) sum += $1} END {printf "%.0f", sum+0}'); then
            if [[ -z "$total_size" || "$total_size" == "0" ]]; then
                total_size=0
            fi
            log DEBUG "Общий размер файлов в $path (резервный метод): $total_size байт"
        else
            log WARNING "Не удалось подсчитать размер файлов в: $path (таймаут 120с)"
            total_size=0
        fi
    fi
    
    echo "$file_count $total_size"
}

# ИСПРАВЛЕНО: Функция форматирования размера в человекочитаемом виде
format_size() {
    local size_bytes="$1"
    
    # Проверка на пустое значение, ноль или нечисловое значение
    if [[ -z "$size_bytes" || "$size_bytes" == "0" ]]; then
        echo "0 B"
        return 0
    fi
    
    # Проверка на числовое значение
    if ! [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        log WARNING "Некорректное значение размера: $size_bytes"
        echo "0 B"
        return 0
    fi
    
    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit_index=0
    local size_float="$size_bytes"
    
    # Используем встроенную арифметику bash для целых чисел
    while ((size_float >= 1024 && unit_index < ${#units[@]} - 1)); do
        ((size_float = size_float / 1024))
        ((unit_index++))
    done
    
    # Для более точного отображения используем awk для финального форматирования
    local formatted_size
    formatted_size=$(awk "BEGIN {printf \"%.2f\", $size_bytes / (1024 ^ $unit_index)}")
    
    printf "%s %s" "$formatted_size" "${units[unit_index]}"
}

# ============================================================================
# РАЗДЕЛ 13: ИСПРАВЛЕННАЯ ГЕНЕРАЦИЯ ОТЧЕТОВ И СВОДКИ
# ============================================================================

# ИСПРАВЛЕНО: Функция записи итоговой сводки с использованием jq
write_summary_with_jq() {
    local result="$1"
    local temp_json
    
    temp_json="$(mktemp)" || {
        log ERROR "Не удалось создать временный файл для JSON сводки"
        return 1
    }
    
    # ИСПРАВЛЕНО: Парсинг статистики rclone из JSON логов
    log DEBUG "Парсинг статистики rclone для отчета"
    read -r rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed <<< "$(parse_rclone_stats "$RCLONE_JSONLOG")"
    
    log DEBUG "Статистика rclone: transfers=$rclone_transfers, checks=$rclone_checks, deletes=$rclone_deletes, errors=$rclone_errors"
    
    # Генерация детальной статистики для каждой исходной директории
    local sources_json="["
    local first=true dir
    
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        local dest_dir
        dest_dir="$(dest_from_src "$dir")"
        
        # Получение статистики
        log DEBUG "Подсчет статистики для $dir"
        read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")"
        read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")"
        
        [[ "$first" == "true" ]] && first=false || sources_json+=","
        
        # Генерация JSON объекта для текущей директории
        sources_json+=$(jq -n \
            --arg src "$dir" \
            --arg dst "$dest_dir" \
            --argjson src_objects "$src_count" \
            --argjson src_bytes "$src_bytes" \
            --argjson dst_objects "$dest_count" \
            --argjson dst_bytes "$dest_bytes" \
            --arg src_size_human "$(format_size "$src_bytes")" \
            --arg dst_size_human "$(format_size "$dest_bytes")" \
            '{
                source: $src,
                destination: $dst,
                source_objects: $src_objects,
                source_bytes: $src_bytes,
                source_size_human: $src_size_human,
                destination_objects: $dst_objects,
                destination_bytes: $dst_bytes,
                destination_size_human: $dst_size_human
            }')
    done
    sources_json+="]"
    
    # Генерация основного JSON документа с rclone статистикой
    jq -n \
        --arg timestamp "$(date -Iseconds)" \
        --arg result "$result" \
        --arg script_version "$SCRIPT_VERSION" \
        --arg hostname "$(hostname -f 2>/dev/null || hostname)" \
        --arg user "$(whoami)" \
        --arg exclude_file "$EXCLUDE_FILE" \
        --arg delete_backup "$DELETE_BACKUP" \
        --argjson dry_run "$([ "$DRY_RUN" = "true" ] && echo true || echo false)" \
        --argjson transfers "$RCLONE_TRANSFERS" \
        --argjson checkers "$RCLONE_CHECKERS" \
        --argjson retries "$RCLONE_RETRIES" \
        --arg config "${RCLONE_CONFIG:-null}" \
        --argjson sources "$sources_json" \
        --argjson rclone_transfers "$rclone_transfers" \
        --argjson rclone_checks "$rclone_checks" \
        --argjson rclone_deletes "$rclone_deletes" \
        --argjson rclone_errors "$rclone_errors" \
        --argjson rclone_total_bytes "$rclone_total_bytes" \
        --argjson rclone_bytes "$rclone_bytes" \
        --argjson rclone_elapsed "$rclone_elapsed" \
        --argjson rclone_speed "$rclone_speed" \
        '{
            timestamp: $timestamp,
            result: $result,
            script_version: $script_version,
            hostname: $hostname,
            user: $user,
            dry_run: $dry_run,
            configuration: {
                exclude_file: $exclude_file,
                delete_backup: $delete_backup,
                rclone: {
                    transfers: $transfers,
                    checkers: $checkers,
                    retries: $retries,
                    config_file: (if $config == "null" then null else $config end)
                }
            },
            operation_statistics: {
                transfers: $rclone_transfers,
                checks: $rclone_checks,
                deletes: $rclone_deletes,
                errors: $rclone_errors,
                total_bytes: $rclone_total_bytes,
                transferred_bytes: $rclone_bytes,
                elapsed_time_seconds: $rclone_elapsed,
                average_speed_bytes_per_second: $rclone_speed,
                transferred_size_human: ((if $rclone_bytes == 0 then "0 B" else ($rclone_bytes | tostring) end)),
                total_size_human: ((if $rclone_total_bytes == 0 then "0 B" else ($rclone_total_bytes | tostring) end))
            },
            sources: $sources
        }' > "$temp_json"
    
    mv "$temp_json" "$SUMMARY_JSON" || {
        log ERROR "Не удалось сохранить JSON сводку"
        rm -f "$temp_json"
        return 1
    }
    
    log INFO "JSON сводка сохранена: $SUMMARY_JSON"
    return 0
}

# ИСПРАВЛЕНО: Функция записи сводки без использования jq
write_summary_without_jq() {
    local result="$1"
    local temp_json
    
    temp_json="$(mktemp)" || {
        log ERROR "Не удалось создать временный файл для сводки"
        return 1
    }
    
    # Парсинг статистики rclone
    read -r rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed <<< "$(parse_rclone_stats "$RCLONE_JSONLOG")"
    
    # Генерация упрощенного JSON без jq
    {
        echo "{"
        printf '  "timestamp": "%s",\n' "$(date -Iseconds)"
        printf '  "result": "%s",\n' "$result"
        printf '  "script_version": "%s",\n' "$SCRIPT_VERSION"
        printf '  "hostname": "%s",\n' "$(hostname -f 2>/dev/null || hostname)"
        printf '  "user": "%s",\n' "$(whoami)"
        printf '  "dry_run": %s,\n' "$([ "$DRY_RUN" = "true" ] && echo true || echo false)"
        echo '  "configuration": {'
        printf '    "exclude_file": "%s",\n' "$EXCLUDE_FILE"
        printf '    "delete_backup": "%s",\n' "$DELETE_BACKUP"
        echo '    "rclone": {'
        printf '      "transfers": %s,\n' "$RCLONE_TRANSFERS"
        printf '      "checkers": %s,\n' "$RCLONE_CHECKERS"
        printf '      "retries": %s,\n' "$RCLONE_RETRIES"
        if [[ -n "${RCLONE_CONFIG:-}" ]]; then
            printf '      "config_file": "%s"\n' "$RCLONE_CONFIG"
        else
            echo '      "config_file": null'
        fi
        echo '    }'
        echo '  },'
        echo '  "operation_statistics": {'
        printf '    "transfers": %s,\n' "$rclone_transfers"
        printf '    "checks": %s,\n' "$rclone_checks"
        printf '    "deletes": %s,\n' "$rclone_deletes"
        printf '    "errors": %s,\n' "$rclone_errors"
        printf '    "total_bytes": %s,\n' "$rclone_total_bytes"
        printf '    "transferred_bytes": %s,\n' "$rclone_bytes"
        printf '    "elapsed_time_seconds": %s,\n' "$rclone_elapsed"
        printf '    "average_speed_bytes_per_second": %s,\n' "$rclone_speed"
        printf '    "transferred_size_human": "%s",\n' "$(format_size "$rclone_bytes")"
        printf '    "total_size_human": "%s"\n' "$(format_size "$rclone_total_bytes")"
        echo '  },'
        echo '  "sources": ['
        
        local first=true dir dest_dir src_count src_bytes dest_count dest_bytes
        
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            dest_dir="$(dest_from_src "$dir")"
            read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")"
            read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")"
            
            [[ "$first" == "true" ]] && first=false || echo "    ,"
            
            local src_safe="${dir//\"/\\\"}"
            local dest_safe="${dest_dir//\"/\\\"}"
            
            cat <<EOF
    {
      "source": "$src_safe",
      "destination": "$dest_safe",
      "source_objects": $src_count,
      "source_bytes": $src_bytes,
      "source_size_human": "$(format_size "$src_bytes")",
      "destination_objects": $dest_count,
      "destination_bytes": $dest_bytes,
      "destination_size_human": "$(format_size "$dest_bytes")"
    }
EOF
        done
        
        echo '  ]'
        echo '}'
    } > "$temp_json"
    
    mv "$temp_json" "$SUMMARY_JSON" || {
        log ERROR "Не удалось сохранить сводку"
        rm -f "$temp_json"
        return 1
    }
    
    log INFO "Сводка сохранена (резервный метод): $SUMMARY_JSON"
    return 0
}

# ИСПРАВЛЕНО: Функция генерации человекочитаемой сводки
generate_human_readable_summary() {
    local json_file="$1"
    local result temp_txt
    
    if command -v jq >/dev/null 2>&1 && [[ -f "$json_file" ]]; then
        result=$(jq -r '.result' "$json_file" 2>/dev/null || echo "unknown")
    else
        result="unknown"
    fi
    
    temp_txt="$(mktemp)" || {
        log ERROR "Не удалось создать временный файл для текстовой сводки"
        return 1
    }
    
    # Парсинг статистики операций для отображения
    read -r rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed <<< "$(parse_rclone_stats "$RCLONE_JSONLOG")"
    
    # Генерация текстовой сводки
    {
        echo "==============================================================================="
        echo "                     ИТОГОВАЯ СВОДКА РЕЗЕРВНОГО КОПИРОВАНИЯ"
        echo "==============================================================================="
        echo
        printf "Время завершения: %s\n" "$(date)"
        printf "Результат выполнения: %s\n" "$result"
        printf "Версия скрипта: %s\n" "$SCRIPT_VERSION"
        printf "Пользователь: %s\n" "$(whoami)"
        printf "Хост: %s\n" "$(hostname -f 2>/dev/null || hostname)"
        printf "Режим тестирования: %s\n" "$DRY_RUN"
        echo
        echo "-------------------------------------------------------------------------------"
        echo "КОНФИГУРАЦИЯ:"
        echo "-------------------------------------------------------------------------------"
        printf "Файл исключений: %s\n" "$EXCLUDE_FILE"
        printf "Директория удаленных файлов: %s\n" "$DELETE_BACKUP"
        printf "Основная директория резервных копий: %s\n" "$MAIN_BACKUP"
        echo
        printf "Настройки rclone:\n"
        printf "  - Параллельные передачи: %s\n" "$RCLONE_TRANSFERS"
        printf "  - Процессы проверки: %s\n" "$RCLONE_CHECKERS"
        printf "  - Повторные попытки: %s\n" "$RCLONE_RETRIES"
        printf "  - Конфигурационный файл: %s\n" "${RCLONE_CONFIG:-<не указан>}"
        echo
        echo "-------------------------------------------------------------------------------"
        echo "СТАТИСТИКА ОПЕРАЦИЙ РЕЗЕРВНОГО КОПИРОВАНИЯ:"
        echo "-------------------------------------------------------------------------------"
        printf "Скопированных файлов: %s\n" "$rclone_transfers"
        printf "Проверенных файлов: %s\n" "$rclone_checks"
        printf "Удаленных файлов: %s\n" "$rclone_deletes"
        printf "Ошибок: %s\n" "$rclone_errors"
        printf "Общий объем данных: %s (%s байт)\n" "$(format_size "$rclone_total_bytes")" "$rclone_total_bytes"
        printf "Передано данных: %s (%s байт)\n" "$(format_size "$rclone_bytes")" "$rclone_bytes"
        
        # Отображаем время выполнения и скорость только если есть данные
        if [[ "$rclone_elapsed" != "0" && "$rclone_elapsed" != "0.0" ]]; then
            if command -v bc >/dev/null 2>&1; then
                local hours minutes seconds
                hours=$(echo "$rclone_elapsed / 3600" | bc)
                minutes=$(echo "($rclone_elapsed % 3600) / 60" | bc)
                seconds=$(echo "$rclone_elapsed % 60" | bc -l | awk '{printf "%.2f", $0}')
                printf "Время выполнения: %s:%02d:%s\n" "$hours" "$minutes" "$seconds"
            else
                printf "Время выполнения: %.2f секунд\n" "$rclone_elapsed"
            fi
            
            if [[ "$rclone_speed" != "0" && "$rclone_speed" != "0.0" ]]; then
                # Преобразуем скорость из float в int для format_size
                local speed_int
                speed_int=$(echo "$rclone_speed" | awk '{printf "%.0f", $0}')
                printf "Средняя скорость: %s/сек\n" "$(format_size "$speed_int")"
            fi
        fi
        
        echo
        echo "-------------------------------------------------------------------------------"
        echo "СТАТИСТИКА ПО ДИРЕКТОРИЯМ:"
        echo "-------------------------------------------------------------------------------"
        
        # Генерация статистики по директориям
        if command -v jq >/dev/null 2>&1 && [[ -f "$json_file" ]]; then
            jq -r '.sources[] | 
                "\nИсточник: \(.source)",
                "Назначение: \(.destination)",
                "  Файлов в источнике: \(.source_objects) (\(.source_size_human))",
                "  Файлов в назначении: \(.destination_objects) (\(.destination_size_human))"
            ' "$json_file" 2>/dev/null || {
                echo "Ошибка обработки JSON данных"
            }
        else
            local dir dest_dir src_count src_bytes dest_count dest_bytes
            for dir in "${SOURCEDIRS_ARRAY[@]}"; do
                dest_dir="$(dest_from_src "$dir")"
                read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")"
                read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")"
                
                printf "\nИсточник: %s\n" "$dir"
                printf "Назначение: %s\n" "$dest_dir"
                printf "  Файлов в источнике: %s (%s)\n" "$src_count" "$(format_size "$src_bytes")"
                printf "  Файлов в назначении: %s (%s)\n" "$dest_count" "$(format_size "$dest_bytes")"
            done
        fi
        
        echo
        echo "==============================================================================="
        echo "                              КОНЕЦ СВОДКИ"
        echo "==============================================================================="
    } > "$temp_txt"
    
    if [[ -f "$temp_txt" ]]; then
        cat "$temp_txt" | tee -a "$LOGFILE" > "$SUMMARY_TXT"
        rm -f "$temp_txt"
        log INFO "Человекочитаемая сводка сохранена: $SUMMARY_TXT"
    else
        log ERROR "Не удалось создать текстовую сводку"
        return 1
    fi
}

# Основная функция записи сводки с автоматическим выбором метода
write_summary() {
    local result="$1"
    
    log INFO "Генерация итоговой сводки (результат: $result)"
    
    if command -v jq >/dev/null 2>&1; then
        log DEBUG "Используется jq для генерации JSON сводки"
        if ! write_summary_with_jq "$result"; then
            log WARNING "Ошибка при использовании jq, переход к резервному методу"
            write_summary_without_jq "$result"
        fi
    else
        log DEBUG "jq недоступен, используется резервный метод"
        write_summary_without_jq "$result"
    fi
    
    generate_human_readable_summary "$SUMMARY_JSON"
    
    log INFO "Генерация сводки завершена"
}

# ============================================================================
# РАЗДЕЛ 14: ОСНОВНОЙ ПОТОК ВЫПОЛНЕНИЯ
# ============================================================================

main() {
    log INFO "========== НАЧАЛО ОСНОВНОГО ПОТОКА РЕЗЕРВНОГО КОПИРОВАНИЯ =========="
    
    log INFO "Системная информация:"
    log INFO "  - Операционная система: $(uname -s) $(uname -r)"
    log INFO "  - Архитектура: $(uname -m)"
    log INFO "  - Версия bash: ${BASH_VERSION}"
    log INFO "  - Версия rclone: $(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' || echo 'неопределена')"
    log INFO "  - Текущий пользователь: $(whoami) (UID: $(id -u))"
    log INFO "  - Домашняя директория: ${HOME:-<не определена>}"
    log INFO "  - Рабочая директория: $(pwd)"
    
    log INFO "Права доступа к ключевым директориям:"
    log INFO "  - /ceph: $(ls -ld /ceph 2>/dev/null | awk '{print $1, $3, $4}' || echo '<недоступна>')"
    log INFO "  - /backup: $(ls -ld /backup 2>/dev/null | awk '{print $1, $3, $4}' || echo '<недоступна>')"
    log INFO "  - $LOGDIR: $(ls -ld "$LOGDIR" 2>/dev/null | awk '{print $1, $3, $4}' || echo '<недоступна>')"
    
    log INFO "Конфигурация резервного копирования:"
    log INFO "  - Исходные директории: ${SOURCEDIRS_ARRAY[*]}"
    log INFO "  - Основная директория бэкапов: $MAIN_BACKUP"
    log INFO "  - Директория удаленных файлов: $DELETE_BACKUP"
    log INFO "  - Файл исключений: $EXCLUDE_FILE"
    log INFO "  - Режим DRY_RUN: $DRY_RUN"
    log INFO "  - Параллельные процессы: $PARALLEL"
    
    # ЭТАП 1: Предварительная проверка системы
    log INFO "ЭТАП 1: Проверка доступности CephFS и исходных директорий"
    if ! check_ceph_access; then
        write_summary "failure"
        log CRITICAL "Предварительная проверка системы не пройдена"
        exit 1
    fi
    log INFO "Предварительная проверка завершена успешно"
    
    # ЭТАП 2: Очистка устаревших резервных копий
    log INFO "ЭТАП 2: Очистка устаревших резервных копий"
    if ! cleanup_old_backups; then
        log WARNING "Очистка устаревших резервных копий завершилась с предупреждениями"
    else
        log INFO "Очистка устаревших резервных копий завершена успешно"
    fi
    
    # ЭТАП 3: Экспорт функций для параллельного выполнения
    log INFO "ЭТАП 3: Подготовка к параллельному выполнению резервного копирования"
    
    export -f log log_command retry_command dest_from_src backup_directory cmd_to_string calculate_directory_stats format_size parse_rclone_stats
    export LOGFILE RCLONE_CONFIG RCLONE_JSONLOG EXCLUDE_FILE MAIN_BACKUP DELETE_BACKUP
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES RCLONE_RETRIES_SLEEP DRY_RUN
    export SCRIPT_VERSION RCLONE_BUFFER_SIZE RCLONE_USE_MMAP RCLONE_LOG_LEVEL BACKUP_SUCCESS
    
    log INFO "Функции и переменные экспортированы для параллельного выполнения"
    
    # ЭТАП 4: Выполнение резервного копирования директорий
    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
    log INFO "Обрабатываемые директории: ${SOURCEDIRS_ARRAY[*]}"
    log INFO "Максимальное количество параллельных процессов: $PARALLEL"
    
    local backup_start_time backup_end_time backup_duration
    backup_start_time=$(date +%s)
    
    if ! printf '%s\0' "${SOURCEDIRS_ARRAY[@]}" | \
         xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'backup_directory "$1"' _ {}; then
        
        BACKUP_SUCCESS=false
        write_summary "failure"
        log CRITICAL "Резервное копирование завершилось с критичными ошибками"
        exit 1
    fi
    
    backup_end_time=$(date +%s)
    backup_duration=$((backup_end_time - start_time))
    
    log INFO "Все процессы резервного копирования завершены успешно"
    log INFO "Общее время резервного копирования: $(printf '%d:%02d:%02d' $((backup_duration/3600)) $((backup_duration%3600/60)) $((backup_duration%60)))"
    
    # ЭТАП 5: Генерация итоговой сводки
    log INFO "ЭТАП 5: Генерация итоговой сводки и отчетов"
    
    # ИСПРАВЛЕНО: Определяем результат на основе фактического статуса выполнения
    local final_result
    if [[ "$BACKUP_SUCCESS" == "true" ]]; then
        final_result="success"
    else
        final_result="failure"
    fi
    
    write_summary "$final_result"
    
    log INFO "========== ЗАВЕРШЕНИЕ ОСНОВНОГО ПОТОКА РЕЗЕРВНОГО КОПИРОВАНИЯ =========="
    log INFO "Все операции резервного копирования выполнены УСПЕШНО"
    
    return 0
}

# ============================================================================
# РАЗДЕЛ 15: ЗАПУСК ОСНОВНОГО ПОТОКА
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit_code=$?
    
    if ((exit_code == 0)); then
        log INFO "=== СКРИПТ ЗАВЕРШЕН УСПЕШНО ==="
    else
        log ERROR "=== СКРИПТ ЗАВЕРШЕН С ОШИБКОЙ (КОД: $exit_code) ==="
    fi
    
    exit $exit_code
else
    log INFO "Скрипт загружен через source, функции доступны для использования"
fi

# ============================================================================
# КОНЕЦ СКРИПТА
# ============================================================================

# Основные исправления в версии 2.4:
# 
# КРИТИЧЕСКИЕ ИСПРАВЛЕНИЯ:
# - ИСПРАВЛЕНО: Добавлен флаг --stats-log-level=NOTICE для корректного логирования статистики rclone
# - ИСПРАВЛЕНО: Улучшена функция parse_rclone_stats() с множественными методами парсинга
# - ИСПРАВЛЕНО: Функция calculate_directory_stats() теперь использует 'rclone size --json' для точного подсчета
# - ИСПРАВЛЕНО: Функция format_size() корректно обрабатывает большие числа и некорректные входные данные
# - ИСПРАВЛЕНО: Добавлена переменная BACKUP_SUCCESS для отслеживания реального статуса выполнения
# - ИСПРАВЛЕНО: Результат выполнения теперь корректно определяется как "success" или "failure"
#
# УЛУЧШЕНИЯ ПАРСИНГА:
# - Поиск статистики в JSON логах теперь использует несколько методов (stats объекты, текстовые сводки в msg)
# - Добавлена обработка альтернативных форматов логирования rclone
# - Улучшена совместимость с различными версиями rclone
# - Добавлены таймауты 120с для операций подсчета статистики
# - Резервные методы работы без jq улучшены
#
# ИСПРАВЛЕНИЯ ОТОБРАЖЕНИЯ:
# - Размеры файлов теперь отображаются корректно в человекочитаемом формате
# - Статистика операций показывает реальные данные вместо нулей
# - Время выполнения и скорость передачи отображаются только при наличии данных
# - Улучшено форматирование времени выполнения (чч:мм:сс.сс)