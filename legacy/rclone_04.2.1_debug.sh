#!/usr/bin/env bash
#
# rclone_04.2.1_debug.sh - Отладочная версия для выявления проблемы
# =================================================================
# Добавлено детальное трассирование для выявления точки сбоя
# 

# Проверка минимальной версии bash (требуется 4.0+ для современных функций)
if ((BASH_VERSINFO[0] < 4)); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее. Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

# Строгий режим выполнения скрипта + отладочная трассировка
set -eEuo pipefail
set -x  # ДОБАВЛЕНО: включение режима трассировки для отладки

# Установка безопасного разделителя полей
IFS=$'\n\t'

# Установка ограничительной маски прав доступа
umask 027

# Установка локали для предсказуемого поведения команд
export LANG=C LC_ALL=C

# shellcheck disable=SC2034  # Переменная используется в функциях
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.1-debug"
readonly REQUIRED_RCLONE_VERSION="1.60"

echo "DEBUG: Инициализация переменных завершена" >&2

# ============================================================================
# КОНФИГУРАЦИЯ И НАСТРОЙКИ
# ============================================================================

readonly BACKUP_USER="${BACKUP_USER:-backup_user}"
readonly LOGDIR="${LOGDIR:-/var/log/backup}"
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
readonly EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"
readonly DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
readonly MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"

echo "DEBUG: Конфигурационные переменные установлены" >&2

# Обработка списка исходных директорий с безопасным разбором
if [[ -n "${SOURCEDIRS:-}" ]]; then
    IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS"
else
    readonly -a SOURCEDIRS_ARRAY=('/ceph/data/exp/idream/')
fi

echo "DEBUG: Исходные директории: ${SOURCEDIRS_ARRAY[*]}" >&2

# Конфигурация производительности rclone
readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"
readonly PARALLEL="${PARALLEL:-4}"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly MAX_LOGFILES="${MAX_LOGFILES:-100}"
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"

echo "DEBUG: Все переменные конфигурации установлены" >&2

# ============================================================================
# ВАЛИДАЦИЯ КОНФИГУРАЦИИ
# ============================================================================

echo "DEBUG: Начало валидации исходных директорий" >&2

# Функция валидации путей источников
validate_source_directories() {
    echo "DEBUG: Вход в функцию validate_source_directories" >&2
    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        echo "DEBUG: Проверка директории: $dir" >&2
        
        # Проверка, что все пути начинаются с /ceph
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            echo "ОШИБКА: Источник '$dir' не находится внутри /ceph" >&2
            echo "Все пути источников должны начинаться с /ceph/ для безопасности" >&2
            exit 1
        fi
        echo "DEBUG: Путь $dir прошел проверку префикса /ceph" >&2
        
        # Проверка отсутствия опасных конструкций в пути
        if [[ "$dir" =~ \.\./|\$\(|\`|\; ]]; then
            echo "ОШИБКА: Обнаружены потенциально опасные символы в пути '$dir'" >&2
            exit 1
        fi
        echo "DEBUG: Путь $dir прошел проверку безопасности" >&2
    done
    echo "DEBUG: validate_source_directories завершена успешно" >&2
}

echo "DEBUG: Запуск validate_source_directories" >&2
validate_source_directories
echo "DEBUG: validate_source_directories выполнена" >&2

echo "DEBUG: Начало проверки необходимых команд" >&2

# Функция проверки необходимых команд  
check_required_commands() {
    echo "DEBUG: Вход в функцию check_required_commands" >&2
    local cmd missing_commands=()
    
    local required_commands=(
        "rclone"
        "mount"
        "mountpoint"
        "find"
        "awk"
        "date"
        "mkdir"
        "flock"
    )
    
    for cmd in "${required_commands[@]}"; do
        echo "DEBUG: Проверка команды: $cmd" >&2
        if ! command -v "$cmd" &>/dev/null; then
            echo "DEBUG: Команда $cmd не найдена" >&2
            missing_commands+=("$cmd")
        else
            echo "DEBUG: Команда $cmd найдена" >&2
        fi
    done
    
    if ((${#missing_commands[@]} > 0)); then
        echo "ОШИБКА: Не найдены необходимые команды: ${missing_commands[*]}" >&2
        echo "Установите недостающие пакеты и повторите запуск" >&2
        exit 1
    fi
    echo "DEBUG: check_required_commands завершена успешно" >&2
}

echo "DEBUG: Запуск check_required_commands" >&2
check_required_commands
echo "DEBUG: check_required_commands выполнена" >&2

echo "DEBUG: Начало проверки версии rclone" >&2

# Функция проверки версии rclone
check_rclone_version() {
    echo "DEBUG: Вход в функцию check_rclone_version" >&2
    local rclone_version
    
    if ! rclone_version=$(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//'); then
        echo "ОШИБКА: Не удалось определить версию rclone" >&2
        exit 1
    fi
    
    echo "DEBUG: Версия rclone: $rclone_version" >&2
    
    # Простая проверка версии (предполагаем семантическое версионирование)
    local required_major required_minor current_major current_minor
    IFS='.' read -r required_major required_minor _ <<< "$REQUIRED_RCLONE_VERSION"
    IFS='.' read -r current_major current_minor _ <<< "$rclone_version"
    
    if ((current_major < required_major || (current_major == required_major && current_minor < required_minor))); then
        echo "ПРЕДУПРЕЖДЕНИЕ: Рекомендуется rclone версии $REQUIRED_RCLONE_VERSION или новее" >&2
        echo "Текущая версия: $rclone_version" >&2
        echo "Продолжение работы может привести к неожиданному поведению" >&2
    fi
    echo "DEBUG: check_rclone_version завершена успешно" >&2
}

echo "DEBUG: Запуск check_rclone_version" >&2
check_rclone_version
echo "DEBUG: check_rclone_version выполнена" >&2

echo "DEBUG: Валидация завершена, начинаем инициализацию логирования" >&2

# ============================================================================
# СИСТЕМА ЛОГИРОВАНИЯ (УПРОЩЕННАЯ ДЛЯ ОТЛАДКИ)
# ============================================================================

log() {
    local level="${1:-INFO}"
    shift || true
    local message="${*:-}"
    local timestamp
    
    timestamp="$(date -Iseconds)"
    local log_message="${timestamp} [${level}] ${message}"
    
    echo "$log_message" >&2
    
    if [[ -n "${LOGFILE:-}" && -w "${LOGFILE%/*}" ]]; then
        echo "$log_message" >> "$LOGFILE"
    fi
}

echo "DEBUG: Функция log определена" >&2

# Создание необходимых директорий
create_directories() {
    echo "DEBUG: Вход в функцию create_directories" >&2
    local dir
    for dir in "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"; do
        echo "DEBUG: Проверка директории: $dir" >&2
        if [[ ! -d "$dir" ]]; then
            echo "DEBUG: Создание директории: $dir" >&2
            mkdir -p "$dir" || {
                echo "ОШИБКА: Не удалось создать директорию: $dir" >&2
                exit 1
            }
        fi
        
        if [[ ! -w "$dir" ]]; then
            echo "ОШИБКА: Нет прав на запись в директорию: $dir" >&2
            exit 1
        fi
        echo "DEBUG: Директория $dir проверена и готова" >&2
    done
    echo "DEBUG: create_directories завершена успешно" >&2
}

echo "DEBUG: Запуск create_directories" >&2
create_directories
echo "DEBUG: create_directories выполнена" >&2

# Инициализация логирования  
initialize_logging() {
    echo "DEBUG: Вход в функцию initialize_logging" >&2
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
    
    readonly LOGFILE="$LOGDIR/backup_${timestamp}.log"
    readonly RCLONE_JSONLOG="$LOGDIR/backup_${timestamp}.jsonl"
    readonly SUMMARY_JSON="$LOGDIR/backup_${timestamp}.summary.json" 
    readonly SUMMARY_TXT="$LOGDIR/backup_${timestamp}.summary.txt"
    
    echo "DEBUG: Файлы логов инициализированы" >&2
    echo "DEBUG: LOGFILE=$LOGFILE" >&2
    
    log INFO "=== ЗАПУСК СКРИПТА РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "Версия скрипта: $SCRIPT_VERSION"
    log INFO "Пользователь: $(whoami)"
    log INFO "Hostname: $(hostname -f 2>/dev/null || hostname)"
    log INFO "Рабочая директория: $(pwd)"
    log INFO "PID процесса: $$"
    log INFO "Режим DRY_RUN: $DRY_RUN"
    
    echo "DEBUG: initialize_logging завершена успешно" >&2
}

echo "DEBUG: Запуск initialize_logging" >&2
initialize_logging
echo "DEBUG: initialize_logging выполнена" >&2

# Ротация логов
rotate_logs() {
    echo "DEBUG: Вход в функцию rotate_logs" >&2
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
    echo "DEBUG: rotate_logs завершена успешно" >&2
}

echo "DEBUG: Запуск rotate_logs" >&2
rotate_logs
echo "DEBUG: rotate_logs выполнена" >&2

echo "DEBUG: Начинаем инициализацию системы блокировки" >&2

# ============================================================================
# СИСТЕМА БЛОКИРОВКИ (ИСПРАВЛЕННАЯ)
# ============================================================================

LOCK_FD=""

cleanup() {
    echo "DEBUG: Вход в функцию cleanup" >&2
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
    echo "DEBUG: cleanup завершена" >&2
    
    exit $exit_code
}

signal_handler() {
    local signal=$1
    echo "DEBUG: Получен сигнал $signal" >&2
    log WARNING "Получен сигнал $signal - начинаем корректное завершение работы"
    exit 130
}

echo "DEBUG: Регистрация trap обработчиков" >&2
trap cleanup EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP
echo "DEBUG: trap обработчики зарегистрированы" >&2

echo "DEBUG: Создание файла блокировки" >&2

# Современная реализация блокировки
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1))); then
    echo "DEBUG: Используем современный метод блокировки" >&2
    exec {LOCK_FD}>"$LOCKFILE" || {
        echo "ОШИБКА: Не удалось создать файл блокировки: $LOCKFILE" >&2
        exit 1
    }
else
    echo "DEBUG: Используем совместимый метод блокировки" >&2
    LOCK_FD=200
    exec 200>"$LOCKFILE" || {
        echo "ОШИБКА: Не удалось создать файл блокировки: $LOCKFILE" >&2
        exit 1
    }
fi

echo "DEBUG: Файл блокировки создан, дескриптор: $LOCK_FD" >&2

if ! flock -n "$LOCK_FD"; then
    log ERROR "Другой экземпляр скрипта уже выполняется"
    log ERROR "Файл блокировки: $LOCKFILE"
    exit 1
fi

log INFO "Блокировка получена (дескриптор: $LOCK_FD), продолжаем выполнение"
echo "DEBUG: Блокировка успешно получена" >&2

# ============================================================================
# ИНИЦИАЛИЗАЦИЯ RCLONE
# ============================================================================

echo "DEBUG: Начинаем инициализацию rclone" >&2

initialize_rclone_config() {
    echo "DEBUG: Вход в функцию initialize_rclone_config" >&2
    log INFO "Инициализация конфигурации rclone"
    
    local rclone_config_output rclone_config_path
    
    if rclone_config_output=$(rclone config file 2>/dev/null); then
        echo "DEBUG: Вывод rclone config file: $rclone_config_output" >&2
        rclone_config_path=$(echo "$rclone_config_output" | awk -F': ' '/Configuration file is stored at:/ {print $2}' | xargs 2>/dev/null || true)
        echo "DEBUG: Извлеченный путь: '$rclone_config_path'" >&2
        
        if [[ -n "$rclone_config_path" && -r "$rclone_config_path" ]]; then
            export RCLONE_CONFIG="$rclone_config_path"
            log INFO "Используется конфигурационный файл rclone: $RCLONE_CONFIG"
        else
            log WARNING "Конфигурационный файл rclone не найден или недоступен: $rclone_config_path"
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
    echo "DEBUG: initialize_rclone_config завершена успешно" >&2
}

echo "DEBUG: Запуск initialize_rclone_config" >&2
initialize_rclone_config
echo "DEBUG: initialize_rclone_config выполнена" >&2

# ============================================================================
# ПРОВЕРКА ФАЙЛА ИСКЛЮЧЕНИЙ
# ============================================================================

echo "DEBUG: Начинаем проверку файла исключений" >&2

validate_exclude_file() {
    echo "DEBUG: Вход в функцию validate_exclude_file" >&2
    log INFO "Проверка файла исключений: $EXCLUDE_FILE"
    
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений не найден: $EXCLUDE_FILE"
        exit 1
    fi
    echo "DEBUG: Файл исключений существует" >&2
    
    if [[ ! -r "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений недоступен для чтения: $EXCLUDE_FILE"
        exit 1
    fi
    echo "DEBUG: Файл исключений доступен для чтения" >&2
    
    if [[ ! -s "$EXCLUDE_FILE" ]]; then
        log WARNING "Файл исключений пустой: $EXCLUDE_FILE"
    else
        local exclude_count
        exclude_count=$(wc -l < "$EXCLUDE_FILE")
        log INFO "Загружено $exclude_count правил исключения из файла $EXCLUDE_FILE"
        echo "DEBUG: Количество правил исключения: $exclude_count" >&2
    fi
    
    local line_number=0 invalid_lines=()
    while IFS= read -r line; do
        ((line_number++))
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ \$\(|\`|\; ]]; then
            invalid_lines+=("$line_number: $line")
        fi
    done < "$EXCLUDE_FILE"
    
    if ((${#invalid_lines[@]} > 0)); then
        log ERROR "Обнаружены потенциально опасные правила исключения:"
        printf '  %s\n' "${invalid_lines[@]}" >&2
        exit 1
    fi
    
    log INFO "Валидация файла исключений завершена успешно"
    echo "DEBUG: validate_exclude_file завершена успешно" >&2
}

echo "DEBUG: Запуск validate_exclude_file" >&2
validate_exclude_file
echo "DEBUG: validate_exclude_file выполнена" >&2

echo "DEBUG: ВСЕ ИНИЦИАЛИЗАЦИОННЫЕ ФУНКЦИИ ВЫПОЛНЕНЫ УСПЕШНО" >&2
echo "DEBUG: Скрипт должен продолжить работу..." >&2

# Здесь должны быть остальные функции, но для отладки останавливаемся
# чтобы увидеть где именно происходит сбой

log INFO "ОТЛАДКА: Все проверки пройдены, скрипт готов к основной работе"
echo "DEBUG: Достигнут конец отладочного скрипта" >&2

# Если мы дошли до этого места - значит проблема не в инициализации
log INFO "=== ОТЛАДОЧНЫЙ СКРИПТ ЗАВЕРШЕН УСПЕШНО ==="
exit 0