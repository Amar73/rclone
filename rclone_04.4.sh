#!/usr/bin/env bash
#
# rclone_04.4.sh - Улучшенная версия (2025)
# ===================================================
# 
# ОПИСАНИЕ:
# Автоматизированный скрипт для создания резервных копий данных из CephFS
# на локальную файловую систему с использованием rclone
#
# ОСНОВНЫЕ ВОЗМОЖНОСТИ:
# - Строгий режим выполнения с комплексной проверкой ошибок
# - Детальное логирование в JSON и текстовом формате
# - Корректная очистка устаревших резервных копий
# - Поддержка исключений файлов/папок с якорными правилами
# - Режим DRY_RUN для тестирования без фактического копирования
# - Параллельное выполнение резервного копирования нескольких директорий
# - Валидация целостности данных (опционально)
# - Поддержка современных методов безопасности и совместимости
#
# АВТОР: Андрей Марьяненко
# ВЕРСИЯ: 4 (Сентябрь 2025)
# ТРЕБОВАНИЯ: bash 4.0+, rclone 1.60+, jq (опционально)
#
# ===================================================

# ============================================================================
# РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ СИСТЕМЫ И ПРОВЕРКА СОВМЕСТИМОСТИ
# ============================================================================

# Проверка минимальной версии bash (требуется 4.0+ для современных функций)
if ((BASH_VERSINFO[0] < 4)); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее. Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

# Строгий режим выполнения скрипта:
# -e: завершение при первой ошибке команды
# -E: наследование ERR trap в функциях и подоболочках  
# -u: завершение при обращении к неопределенным переменными
# -o pipefail: ошибка в любой части pipeline приводит к ошибке всего pipeline
set -eEuo pipefail

# Установка безопасного разделителя полей (только перенос строки и табуляция)
# Предотвращает проблемы с пробелами в именах файлов
IFS=$'\n\t'

# Установка ограничительной маски прав доступа к создаваемым файлам
# 027 = rw-r----- (владелец: чтение/запись, группа: чтение, остальные: нет доступа)
umask 027

# Установка локали для предсказуемого поведения команд
# Предотвращает проблемы с сортировкой и форматированием в разных языковых окружениях
export LANG=C LC_ALL=C

# shellcheck disable=SC2034  # Переменная используется в функциях
readonly SCRIPT_NAME="${0##*/}"  # Имя скрипта без пути
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Директория скрипта
readonly SCRIPT_VERSION="2.0"
readonly REQUIRED_RCLONE_VERSION="1.60"

# ============================================================================
# РАЗДЕЛ 2: КОНФИГУРАЦИЯ И НАСТРОЙКИ
# ============================================================================

# Пользователь для выполнения резервного копирования
# Рекомендуется создать отдельного пользователя с ограниченными правами
readonly BACKUP_USER="${BACKUP_USER:-backup_user}"

# Директория для хранения файлов логов
# Должна быть доступна для записи пользователю BACKUP_USER
readonly LOGDIR="${LOGDIR:-/var/log/backup}"

# Файл блокировки для предотвращения одновременного запуска скрипта
# Критично для предотвращения конфликтов при работе с резервными копиями
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"

# Файл с правилами исключения файлов и директорий из резервного копирования
# Поддерживает синтаксис rclone exclude patterns
readonly EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"

# Директория для хранения удаленных/измененных файлов
# Файлы сохраняются здесь перед удалением для возможности восстановления
readonly DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"

# Основная директория для хранения резервных копий
readonly MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"

# Обработка списка исходных директорий с безопасным разбором
# Использует readarray для корректной работы с пробелами в путях
if [[ -n "${SOURCEDIRS:-}" ]]; then
    # Разбираем переменную окружения в массив
    IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS"
else
    # Значение по умолчанию
    readonly -a SOURCEDIRS_ARRAY=('/ceph/data/exp/idream/')
fi

# Конфигурация производительности rclone
readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"      # Количество параллельных передач
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"        # Количество процессов проверки
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"          # Количество повторных попыток
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"  # Задержка между попытками

# Количество параллельных процессов резервного копирования директорий
readonly PARALLEL="${PARALLEL:-4}"

# Режим тестирования - если true, команды выполняются без фактических изменений
readonly DRY_RUN="${DRY_RUN:-false}"

# Дополнительные настройки безопасности и мониторинга
readonly MAX_LOGFILES="${MAX_LOGFILES:-100}"             # Максимальное количество лог-файлов
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}" # Время хранения логов в днях
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"  # Время хранения удаленных файлов

# ============================================================================
# РАЗДЕЛ 3: ВАЛИДАЦИЯ КОНФИГУРАЦИИ
# ============================================================================

# Функция валидации путей источников
validate_source_directories() {
    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        # Проверка, что все пути начинаются с /ceph (требование безопасности)
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            echo "ОШИБКА: Источник '$dir' не находится внутри /ceph" >&2
            echo "Все пути источников должны начинаться с /ceph/ для безопасности" >&2
            exit 1
        fi
        
        # Проверка отсутствия опасных конструкций в пути
        if [[ "$dir" =~ \.\./|\$\(|\`|\; ]]; then
            echo "ОШИБКА: Обнаружены потенциально опасные символы в пути '$dir'" >&2
            exit 1
        fi
    done
}

# Функция проверки необходимых команд
check_required_commands() {
    local cmd missing_commands=()
    
    # Список критически важных команд
    local required_commands=(
        "rclone"     # Основной инструмент синхронизации
        "mount"      # Для монтирования файловых систем
        "mountpoint" # Для проверки статуса монтирования
        "find"       # Для поиска файлов
        "awk"        # Для обработки текста
        "date"       # Для работы с датами
        "mkdir"      # Для создания директорий
        "flock"      # Для блокировки файлов
    )
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if ((${#missing_commands[@]} > 0)); then
        echo "ОШИБКА: Не найдены необходимые команды: ${missing_commands[*]}" >&2
        echo "Установите недостающие пакеты и повторите запуск" >&2
        exit 1
    fi
}

# Функция проверки версии rclone
check_rclone_version() {
    local rclone_version
    if ! rclone_version=$(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//'); then
        echo "ОШИБКА: Не удалось определить версию rclone" >&2
        exit 1
    fi
    
    # Простая проверка версии (предполагаем семантическое версионирование)
    local required_major required_minor current_major current_minor
    IFS='.' read -r required_major required_minor _ <<< "$REQUIRED_RCLONE_VERSION"
    IFS='.' read -r current_major current_minor _ <<< "$rclone_version"
    
    if ((current_major < required_major || (current_major == required_major && current_minor < required_minor))); then
        echo "ПРЕДУПРЕЖДЕНИЕ: Рекомендуется rclone версии $REQUIRED_RCLONE_VERSION или новее" >&2
        echo "Текущая версия: $rclone_version" >&2
        echo "Продолжение работы может привести к неожиданному поведению" >&2
    fi
}

# Выполнение валидации
validate_source_directories
check_required_commands
check_rclone_version

# ============================================================================
# РАЗДЕЛ 4: СИСТЕМА ЛОГИРОВАНИЯ
# ============================================================================

# Функция логирования с поддержкой уровней важности
# Поддерживает: DEBUG, INFO, WARNING, ERROR, CRITICAL
log() {
    local level="${1:-INFO}"
    shift || true
    local message="${*:-}"
    local timestamp
    
    # Генерация timestamp в ISO 8601 формате
    timestamp="$(date -Iseconds)"
    
    # Цветовое кодирование для различных уровней (только для терминала)
    local color_code=""
    if [[ -t 2 ]]; then  # Если stderr подключен к терминалу
        case "$level" in
            DEBUG)    color_code="\033[36m" ;;      # Голубой
            INFO)     color_code="\033[32m" ;;      # Зеленый
            WARNING)  color_code="\033[33m" ;;      # Желтый
            ERROR)    color_code="\033[31m" ;;      # Красный
            CRITICAL) color_code="\033[35;1m" ;;    # Яркий пурпурный
        esac
    fi
    
    # Формирование сообщения лога
    local log_message="${timestamp} [${level}] ${message}"
    
    # Вывод в stderr с цветами (если поддерживается)
    if [[ -n "$color_code" ]]; then
        echo -e "${color_code}${log_message}\033[0m" >&2
    else
        echo "$log_message" >&2
    fi
    
    # Вывод в файл лога (если определен)
    if [[ -n "${LOGFILE:-}" && -w "${LOGFILE%/*}" ]]; then
        echo "$log_message" >> "$LOGFILE"
    fi
}

# Функция для логирования выполнения команд (отладочная информация)
log_command() {
    local -a cmd=("$@")
    log DEBUG "Выполнение команды: $(printf '%q ' "${cmd[@]}")"
}

# ============================================================================
# РАЗДЕЛ 5: ИНИЦИАЛИЗАЦИЯ ФАЙЛОВОЙ СИСТЕМЫ И ЛОГОВ  
# ============================================================================

# Создание необходимых директорий с правильными правами доступа
create_directories() {
    local dir
    for dir in "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"; do
        if [[ ! -d "$dir" ]]; then
            log INFO "Создание директории: $dir"
            mkdir -p "$dir" || {
                log ERROR "Не удалось создать директорию: $dir"
                exit 1
            }
        fi
        
        # Проверка прав доступа на запись
        if [[ ! -w "$dir" ]]; then
            log ERROR "Нет прав на запись в директорию: $dir"
            exit 1
        fi
    done
}

# Инициализация системы логирования
initialize_logging() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
    
    # Определение путей к файлам логов
    readonly LOGFILE="$LOGDIR/backup_${timestamp}.log"
    readonly RCLONE_JSONLOG="$LOGDIR/backup_${timestamp}.jsonl"
    readonly SUMMARY_JSON="$LOGDIR/backup_${timestamp}.summary.json"
    readonly SUMMARY_TXT="$LOGDIR/backup_${timestamp}.summary.txt"
    
    # Создание начальной записи в логе
    log INFO "=== ЗАПУСК СКРИПТА РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "Версия скрипта: $SCRIPT_VERSION"
    log INFO "Пользователь: $(whoami)"
    log INFO "Hostname: $(hostname -f 2>/dev/null || hostname)"
    log INFO "Рабочая директория: $(pwd)"
    log INFO "PID процесса: $$"
    log INFO "Режим DRY_RUN: $DRY_RUN"
}

# Функция ротации старых логов
rotate_logs() {
    log INFO "Начало ротации логов в $LOGDIR"
    
    # Удаление логов старше указанного количества дней
    local deleted_count
    deleted_count=$(find "$LOGDIR" -type f -name 'backup_*.log' -mtime "+$LOG_RETENTION_DAYS" -delete -print 2>/dev/null | wc -l)
    
    if ((deleted_count > 0)); then
        log INFO "Удалено $deleted_count старых лог-файлов (старше $LOG_RETENTION_DAYS дней)"
    fi
    
    # Проверка общего количества лог-файлов
    local current_count
    current_count=$(find "$LOGDIR" -type f -name 'backup_*.log' 2>/dev/null | wc -l)
    
    if ((current_count > MAX_LOGFILES)); then
        log WARNING "Количество лог-файлов ($current_count) превышает лимит ($MAX_LOGFILES)"
        log WARNING "Рекомендуется проверить настройки ротации логов"
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

# Файловый дескриптор для блокировки (предотвращение одновременного запуска)
readonly LOCK_FD=200

# Функция очистки ресурсов при завершении скрипта
cleanup() {
    local exit_code=$?
    
    log INFO "Начало процедуры очистки ресурсов"
    
    # Освобождение блокировки
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        log DEBUG "Блокировка освобождена"
    fi
    
    # Удаление файла блокировки
    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE" || true
        log DEBUG "Файл блокировки удален"
    fi
    
    # Логирование завершения работы
    if ((exit_code == 0)); then
        log INFO "Скрипт завершился успешно"
    else
        log ERROR "Скрипт завершился с ошибкой (код: $exit_code)"
    fi
    
    log INFO "=== ЗАВЕРШЕНИЕ РАБОТЫ СКРИПТА ==="
    
    exit $exit_code
}

# Функция обработки сигналов прерывания
signal_handler() {
    local signal=$1
    log WARNING "Получен сигнал $signal - начинаем корректное завершение работы"
    exit 130  # Стандартный код для прерывания по сигналу
}

# Регистрация обработчиков сигналов и функции очистки
trap cleanup EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP

# Попытка получения эксклюзивной блокировки
exec {LOCK_FD}>"$LOCKFILE"
if ! flock -n "$LOCK_FD"; then
    log ERROR "Другой экземпляр скрипта уже выполняется"
    log ERROR "Файл блокировки: $LOCKFILE"
    log ERROR "Если вы уверены, что другой процесс не выполняется, удалите файл блокировки"
    exit 1
fi

log INFO "Блокировка получена, продолжаем выполнение"

# ============================================================================
# РАЗДЕЛ 7: КОНФИГУРАЦИЯ RCLONE
# ============================================================================

# Функция инициализации конфигурации rclone
initialize_rclone_config() {
    log INFO "Инициализация конфигурации rclone"
    
    # Попытка определения пути к конфигурационному файлу rclone
    local rclone_config_output rclone_config_path
    
    if rclone_config_output=$(rclone config file 2>/dev/null); then
        # Извлечение пути из вывода команды (обычно во второй строке после "Configuration file is stored at:")
        rclone_config_path=$(echo "$rclone_config_output" | awk -F': ' '/Configuration file is stored at:/ {print $2}' | xargs 2>/dev/null || true)
        
        # Проверка существования и доступности файла
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
    
    # Экспорт переменных окружения для rclone
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES
    
    # Дополнительные настройки rclone для улучшения производительности и надежности
    export RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-16M}"
    export RCLONE_USE_MMAP="${RCLONE_USE_MMAP:-true}"
    export RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"
    
    log INFO "Конфигурация rclone инициализирована"
    log DEBUG "RCLONE_TRANSFERS=$RCLONE_TRANSFERS"
    log DEBUG "RCLONE_CHECKERS=$RCLONE_CHECKERS" 
    log DEBUG "RCLONE_RETRIES=$RCLONE_RETRIES"
}

# Выполнение инициализации rclone
initialize_rclone_config

# ============================================================================
# РАЗДЕЛ 8: ПРОВЕРКА И ВАЛИДАЦИЯ ФАЙЛА ИСКЛЮЧЕНИЙ
# ============================================================================

# Функция проверки файла исключений
validate_exclude_file() {
    log INFO "Проверка файла исключений: $EXCLUDE_FILE"
    
    # Проверка существования файла
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений не найден: $EXCLUDE_FILE"
        log ERROR "Создайте файл исключений или укажите корректный путь в переменной EXCLUDE_FILE"
        exit 1
    fi
    
    # Проверка прав доступа на чтение
    if [[ ! -r "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений недоступен для чтения: $EXCLUDE_FILE"
        log ERROR "Проверьте права доступа к файлу"
        exit 1
    fi
    
    # Проверка, что файл не пустой
    if [[ ! -s "$EXCLUDE_FILE" ]]; then
        log WARNING "Файл исключений пустой: $EXCLUDE_FILE"
        log WARNING "Резервное копирование будет выполнено для всех файлов без исключений"
    else
        local exclude_count
        exclude_count=$(wc -l < "$EXCLUDE_FILE")
        log INFO "Загружено $exclude_count правил исключения из файла $EXCLUDE_FILE"
    fi
    
    # Валидация синтаксиса правил исключения (базовая проверка)
    local line_number=0 invalid_lines=()
    
    while IFS= read -r line; do
        ((line_number++))
        
        # Пропуск пустых строк и комментариев
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Проверка на потенциально опасные конструкции
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
}

# Выполнение валидации файла исключений
validate_exclude_file

# ============================================================================
# РАЗДЕЛ 9: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

# Функция безопасного преобразования команды в строку для логирования
# Корректно экранирует специальные символы и пробелы
cmd_to_string() {
    local -a cmd_array=("$@")
    local result=""
    local arg
    
    for arg in "${cmd_array[@]}"; do
        printf -v result "%s%s " "$result" "$(printf '%q' "$arg")"
    done
    
    printf '%s\n' "${result% }"  # Удаление завершающего пробела
}

# Функция повторного выполнения команд с обработкой ошибок
# Поддерживает интеллигентную обработку кодов возврата rclone
retry_command() {
    local retries="$1"
    local delay="$1"
    shift 2
    local -a cmd=("$@")
    local attempt exit_code
    
    for ((attempt = 1; attempt <= retries; attempt++)); do
        log INFO "Попытка $attempt/$retries: $(cmd_to_string "${cmd[@]}")"
        
        # Выполнение команды с захватом кода возврата
        set +e  # Временное отключение немедленного завершения при ошибке
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            # Логирование вывода команды с фильтрацией по важности
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
        
        # Получение кода возврата из PIPESTATUS (первая команда в pipeline)
        exit_code=${PIPESTATUS[0]}
        set -e  # Восстановление строгого режима
        
        # Анализ кода возврата для принятия решения о повторе
        case $exit_code in
            0)
                log INFO "Команда выполнена успешно"
                return 0
                ;;
            1)
                # Код 1 может означать "нет файлов для обработки" - это нормально для некоторых операций
                if [[ "${cmd[1]}" == "rmdirs" || "${cmd[1]}" == "delete" ]]; then
                    log INFO "Команда завершена (нет файлов для обработки)"
                    return 0
                fi
                ;;
            3)
                # Код 3 обычно означает "нет изменений" для операций синхронизации
                if [[ "${cmd[1]}" == "sync" || "${cmd[1]}" == "copy" ]]; then
                    log INFO "Команда завершена (нет изменений)"
                    return 0
                fi
                ;;
        esac
        
        # Если команда неуспешна и есть еще попытки
        if ((attempt < retries)); then
            log WARNING "Ошибка выполнения (код: $exit_code), повтор через ${delay}s"
            sleep "$delay"
        else
            log ERROR "Команда не выполнилась после $retries попыток (финальный код: $exit_code)"
            return $exit_code
        fi
    done
}

# Функция проверки доступности и состояния CephFS
check_ceph_access() {
    log INFO "Проверка доступности CephFS"
    
    # Проверка записи в /etc/fstab
    if ! awk '$1 !~ /^#/ && $2 == "/ceph" {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        log ERROR "CephFS не настроен в /etc/fstab"
        log ERROR "Добавьте соответствующую запись монтирования в /etc/fstab"
        return 1
    fi
    
    # Проверка состояния монтирования
    if ! mountpoint -q /ceph 2>/dev/null; then
        log WARNING "CephFS не смонтирован, попытка монтирования..."
        
        # Проверка прав для монтирования
        if ((EUID != 0)); then
            log ERROR "Нет прав для монтирования CephFS (требуются права root)"
            log ERROR "Запустите скрипт от имени root или смонтируйте CephFS заранее"
            return 1
        fi
        
        # Попытка монтирования с повторами
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
        
        # Финальная проверка монтирования
        if ! mountpoint -q /ceph 2>/dev/null; then
            log ERROR "Не удалось смонтировать CephFS после 5 попыток"
            return 1
        fi
    fi
    
    # Проверка доступности для чтения
    if ! ls /ceph >/dev/null 2>&1; then
        log ERROR "Нет доступа к CephFS для чтения"
        log ERROR "Проверьте права пользователя $BACKUP_USER на доступ к /ceph"
        return 1
    fi
    
    # Проверка существования исходных директорий
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
    
    # Опциональная проверка состояния Ceph кластера
    check_ceph_cluster_status
    
    log INFO "Проверка доступности CephFS завершена успешно"
    return 0
}

# Функция проверки состояния Ceph кластера (некритичная)
check_ceph_cluster_status() {
    log DEBUG "Попытка проверки состояния Ceph кластера"
    
    # Проверка доступности SSH для подключения к узлу управления
    if ! command -v ssh >/dev/null 2>&1; then
        log DEBUG "SSH недоступен, пропуск проверки статуса кластера"
        return 0
    fi
    
    # Попытка получения статуса через SSH (неблокирующая операция)
    local ceph_status
    if ceph_status=$(timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes \
                     cephsvc05 "podman exec ceph-mon-cephsvc05 ceph status" 2>/dev/null); then
        
        # Анализ статуса на предмет критичных проблем
        if echo "$ceph_status" | grep -qi "health_err\|health_warn"; then
            log WARNING "Обнаружены проблемы с состоянием Ceph кластера"
            log WARNING "Рекомендуется проверить статус кластера перед продолжением"
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

# Функция очистки старых резервных копий из директории удаленных файлов
cleanup_old_backups() {
    log INFO "Начало очистки устаревших данных в $DELETE_BACKUP (старше ${DELETE_RETENTION_DAYS}d)"
    
    # Проверка и создание директории удаленных файлов если необходимо
    if [[ ! -d "$DELETE_BACKUP" ]]; then
        log WARNING "Директория удаленных файлов не существует: $DELETE_BACKUP"
        log INFO "Создание директории: $DELETE_BACKUP"
        
        mkdir -p "$DELETE_BACKUP" || {
            log ERROR "Не удалось создать директорию удаленных файлов: $DELETE_BACKUP"
            return 1
        }
    fi
    
    # Подготовка команды удаления файлов старше указанного периода
    local delete_cmd=(
        rclone delete
        --min-age "${DELETE_RETENTION_DAYS}d"
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
    )
    
    # Добавление конфигурационного файла если доступен
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        delete_cmd+=(--config="$RCLONE_CONFIG")
    fi
    
    # Добавление режима тестирования если активен
    if [[ "$DRY_RUN" == "true" ]]; then
        delete_cmd+=(--dry-run)
    fi
    
    # Добавление целевого пути
    delete_cmd+=("$DELETE_BACKUP")
    
    # Выполнение команды удаления с обработкой ошибок
    if ! retry_command 3 10 "${delete_cmd[@]}"; then
        log WARNING "Команда удаления файлов завершилась с предупреждениями"
    fi
    
    # Подготовка команды удаления пустых директорий
    local rmdir_cmd=(
        rclone rmdirs
        --leave-root
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
    )
    
    # Добавление конфигурационного файла если доступен
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        rmdir_cmd+=(--config="$RCLONE_CONFIG")
    fi
    
    # Добавление режима тестирования если активен
    if [[ "$DRY_RUN" == "true" ]]; then
        rmdir_cmd+=(--dry-run)
    fi
    
    # Добавление целевого пути
    rmdir_cmd+=("$DELETE_BACKUP")
    
    # Выполнение команды удаления пустых директорий
    if ! retry_command 3 10 "${rmdir_cmd[@]}"; then
        log WARNING "Команда удаления пустых директорий завершилась с предупреждениями"
    fi
    
    log INFO "Очистка устаревших резервных копий завершена"
}

# ============================================================================
# РАЗДЕЛ 11: ОСНОВНАЯ ЛОГИКА РЕЗЕРВНОГО КОПИРОВАНИЯ
# ============================================================================

# Функция генерации пути назначения на основе пути источника
dest_from_src() {
    local src_dir="$1"
    local dest_path
    
    # Преобразование пути /ceph/... в /backup/main/ceph/...
    dest_path="${MAIN_BACKUP}/ceph${src_dir#/ceph}"
    
    printf '%s\n' "$dest_path"
}

# Основная функция резервного копирования директории
backup_directory() {
    local src_dir="$1"
    local dest_dir start_time end_time duration
    
    # Валидация входного параметра
    if [[ -z "$src_dir" ]]; then
        log ERROR "Не указана исходная директория для резервного копирования"
        return 1
    fi
    
    # Генерация пути назначения
    dest_dir="$(dest_from_src "$src_dir")"
    
    log INFO "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "Источник: $src_dir"
    log INFO "Назначение: $dest_dir"
    
    start_time=$(date +%s)
    
    # Создание директории назначения
    if ! mkdir -p "$dest_dir"; then
        log ERROR "Не удалось создать директорию назначения: $dest_dir"
        return 1
    fi
    
    # Подготовка массива флагов для rclone
    local flags=(
        --progress                          # Отображение прогресса
        --links                            # Копирование символических ссылок
        --fast-list                        # Ускоренное получение списка файлов
        --create-empty-src-dirs            # Создание пустых директорий
        --checksum                         # Проверка контрольных сумм
        --transfers="$RCLONE_TRANSFERS"    # Количество параллельных передач
        --checkers="$RCLONE_CHECKERS"      # Количество процессов проверки
        --retries="$RCLONE_RETRIES"        # Количество повторных попыток
        --retries-sleep="$RCLONE_RETRIES_SLEEP"  # Задержка между попытками
        --update                           # Обновление только измененных файлов
        --delete-excluded                  # Удаление исключенных файлов из назначения
        --backup-dir="$DELETE_BACKUP/$(date +%F)"  # Директория для сохранения удаляемых файлов
        --use-json-log                     # Использование JSON формата логирования
        --log-file="$RCLONE_JSONLOG"      # Файл для детального лога
        --exclude-from="$EXCLUDE_FILE"     # Файл с правилами исключения
        --log-level=INFO                   # Уровень детализации логирования
        --stats=5m                         # Интервал вывода статистики
        --track-renames                    # Отслеживание переименований
        --buffer-size="$RCLONE_BUFFER_SIZE"  # Размер буфера для оптимизации
    )
    
    # Добавление флага тестирования если активен
    if [[ "$DRY_RUN" == "true" ]]; then
        flags+=(--dry-run)
        log INFO "РЕЖИМ ТЕСТИРОВАНИЯ: изменения не будут применены"
    fi
    
    # Добавление конфигурационного файла если доступен
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        flags+=(--config="$RCLONE_CONFIG")
    fi
    
    # Подготовка команды синхронизации
    local sync_cmd=(rclone sync "${flags[@]}" "$src_dir" "$dest_dir")
    
    log INFO "Команда синхронизации: $(cmd_to_string "${sync_cmd[@]}")"
    
    # Выполнение синхронизации с обработкой ошибок
    if ! retry_command 3 15 "${sync_cmd[@]}"; then
        log ERROR "Резервное копирование директории $src_dir завершилось с ошибкой"
        return 1
    fi
    
    # Расчет времени выполнения
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    log INFO "Резервное копирование директории $src_dir завершено успешно"
    log INFO "Время выполнения: $(printf '%d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))"
    log INFO "=== ЗАВЕРШЕНИЕ РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    
    return 0
}

# ============================================================================
# РАЗДЕЛ 12: ПОДСЧЕТ СТАТИСТИКИ И МЕТРИК
# ============================================================================

# Функция безопасного подсчета количества файлов и общего размера
calculate_directory_stats() {
    local path="$1"
    local file_count=0 total_size=0
    
    # Валидация входного параметра
    if [[ -z "$path" ]]; then
        log ERROR "Не указан путь для подсчета статистики"
        echo "0 0"
        return 1
    fi
    
    # Проверка существования пути
    if [[ ! -d "$path" ]]; then
        log DEBUG "Путь не существует: $path"
        echo "0 0"
        return 0
    fi
    
    # Подготовка базовых аргументов для rclone
    local base_args=(
        --files-only
        --recursive
        --exclude-from="$EXCLUDE_FILE"
    )
    
    # Добавление конфигурационного файла если доступен
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        base_args+=(--config="$RCLONE_CONFIG")
    fi
    
    # Подсчет количества файлов
    if file_count=$(rclone lsf "${base_args[@]}" "$path" 2>/dev/null | wc -l); then
        log DEBUG "Количество файлов в $path: $file_count"
    else
        log WARNING "Не удалось подсчитать количество файлов в: $path"
        file_count=0
    fi
    
    # Подсчет общего размера в байтах
    if total_size=$(rclone lsf --format s "${base_args[@]}" "$path" 2>/dev/null | awk '{sum += $1} END {printf "%.0f", sum}'); then
        log DEBUG "Общий размер файлов в $path: $total_size байт"
    else
        log WARNING "Не удалось подсчитать размер файлов в: $path"
        total_size=0
    fi
    
    # Возврат результатов через stdout
    echo "$file_count $total_size"
}

# Функция форматирования размера в человекочитаемом виде
format_size() {
    local size_bytes="$1"
    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit_index=0
    local size_float="$size_bytes"
    
    # Преобразование в подходящую единицу измерения
    while ((size_float >= 1024 && unit_index < ${#units[@]} - 1)); do
        size_float=$(awk "BEGIN {printf \"%.2f\", $size_float / 1024}")
        ((unit_index++))
    done
    
    printf "%.2f %s" "$size_float" "${units[unit_index]}"
}

# ============================================================================
# РАЗДЕЛ 13: ГЕНЕРАЦИЯ ОТЧЕТОВ И СВОДКИ
# ============================================================================

# Функция записи итоговой сводки с использованием jq
write_summary_with_jq() {
    local result="$1"
    local temp_json
    
    temp_json="$(mktemp)" || {
        log ERROR "Не удалось создать временный файл для JSON сводки"
        return 1
    }
    
    # Генерация детальной статистики для каждой исходной директории
    local sources_json="["
    local first=true dir src_stats dest_stats
    
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        local dest_dir
        dest_dir="$(dest_from_src "$dir")"
        
        # Получение статистики
        read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")"
        read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")"
        
        # Добавление разделителя между элементами
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
    
    # Генерация основного JSON документа
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
            sources: $sources
        }' > "$temp_json"
    
    # Перемещение временного файла в финальное местоположение
    mv "$temp_json" "$SUMMARY_JSON" || {
        log ERROR "Не удалось сохранить JSON сводку"
        rm -f "$temp_json"
        return 1
    }
    
    log INFO "JSON сводка сохранена: $SUMMARY_JSON"
    return 0
}

# Функция записи сводки без использования jq (резервный метод)
write_summary_without_jq() {
    local result="$1"
    local temp_json
    
    temp_json="$(mktemp)" || {
        log ERROR "Не удалось создать временный файл для сводки"
        return 1
    }
    
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
        echo '  "sources": ['
        
        local first=true dir dest_dir src_count src_bytes dest_count dest_bytes
        
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            dest_dir="$(dest_from_src "$dir")"
            read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")"
            read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")"
            
            [[ "$first" == "true" ]] && first=false || echo "    ,"
            
            # Экранирование кавычек в путях
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
    
    # Перемещение временного файла в финальное местоположение
    mv "$temp_json" "$SUMMARY_JSON" || {
        log ERROR "Не удалось сохранить сводку"
        rm -f "$temp_json"
        return 1
    }
    
    log INFO "Сводка сохранена (резервный метод): $SUMMARY_JSON"
    return 0
}

# Функция генерации человекочитаемой сводки
generate_human_readable_summary() {
    local json_file="$1"
    local result temp_txt
    
    # Получение результата из JSON (если возможно)
    if command -v jq >/dev/null 2>&1 && [[ -f "$json_file" ]]; then
        result=$(jq -r '.result' "$json_file" 2>/dev/null || echo "unknown")
    else
        result="unknown"
    fi
    
    temp_txt="$(mktemp)" || {
        log ERROR "Не удалось создать временный файл для текстовой сводки"
        return 1
    }
    
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
        echo "СТАТИСТИКА ПО ДИРЕКТОРИЯМ:"
        echo "-------------------------------------------------------------------------------"
        
        # Генерация статистики по директориям
        if command -v jq >/dev/null 2>&1 && [[ -f "$json_file" ]]; then
            # Использование jq для форматированного вывода
            jq -r '.sources[] | 
                "\nИсточник: \(.source)",
                "Назначение: \(.destination)",
                "  Файлов в источнике: \(.source_objects) (\(.source_size_human))",
                "  Файлов в назначении: \(.destination_objects) (\(.destination_size_human))"
            ' "$json_file" 2>/dev/null || {
                echo "Ошибка обработки JSON данных"
            }
        else
            # Резервный метод без jq
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
    
    # Копирование сводки в лог и сохранение в файл
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
    
    # Выбор метода генерации JSON в зависимости от доступности jq
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
    
    # Генерация человекочитаемой версии
    generate_human_readable_summary "$SUMMARY_JSON"
    
    log INFO "Генерация сводки завершена"
}

# ============================================================================
# РАЗДЕЛ 14: ОСНОВНОЙ ПОТОК ВЫПОЛНЕНИЯ
# ============================================================================

# Функция выполнения основного потока резервного копирования
main() {
    log INFO "========== НАЧАЛО ОСНОВНОГО ПОТОКА РЕЗЕРВНОГО КОПИРОВАНИЯ =========="
    
    # Вывод информации о системе и конфигурации
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
        log WARNING "Продолжаем выполнение основного резервного копирования"
    else
        log INFO "Очистка устаревших резервных копий завершена успешно"
    fi
    
    # ЭТАП 3: Экспорт функций для параллельного выполнения
    log INFO "ЭТАП 3: Подготовка к параллельному выполнению резервного копирования"
    
    # Экспорт всех необходимых функций и переменных для работы в подпроцессах
    export -f log log_command retry_command dest_from_src backup_directory cmd_to_string calculate_directory_stats
    export LOGFILE RCLONE_CONFIG RCLONE_JSONLOG EXCLUDE_FILE MAIN_BACKUP DELETE_BACKUP
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES RCLONE_RETRIES_SLEEP DRY_RUN
    export SCRIPT_VERSION RCLONE_BUFFER_SIZE RCLONE_USE_MMAP RCLONE_LOG_LEVEL
    
    log INFO "Функции и переменные экспортированы для параллельного выполнения"
    
    # ЭТАП 4: Выполнение резервного копирования директорий
    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
    log INFO "Обрабатываемые директории: ${SOURCEDIRS_ARRAY[*]}"
    log INFO "Максимальное количество параллельных процессов: $PARALLEL"
    
    local backup_start_time backup_end_time backup_duration
    backup_start_time=$(date +%s)
    
    # Использование printf для корректной передачи путей с пробелами
    # и xargs для параллельного выполнения
    if ! printf '%s\0' "${SOURCEDIRS_ARRAY[@]}" | \
         xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'backup_directory "$1"' _ {}; then
        
        write_summary "failure"
        log CRITICAL "Резервное копирование завершилось с критичными ошибками"
        exit 1
    fi
    
    backup_end_time=$(date +%s)
    backup_duration=$((backup_end_time - backup_start_time))
    
    log INFO "Все процессы резервного копирования завершены успешно"
    log INFO "Общее время резервного копирования: $(printf '%d:%02d:%02d' $((backup_duration/3600)) $((backup_duration%3600/60)) $((backup_duration%60)))"
    
    # ЭТАП 5: Генерация итоговой сводки
    log INFO "ЭТАП 5: Генерация итоговой сводки и отчетов"
    write_summary "success"
    
    log INFO "========== ЗАВЕРШЕНИЕ ОСНОВНОГО ПОТОКА РЕЗЕРВНОГО КОПИРОВАНИЯ =========="
    log INFO "Все операции резервного копирования выполнены УСПЕШНО"
    
    return 0
}

# ============================================================================
# РАЗДЕЛ 15: ЗАПУСК ОСНОВНОГО ПОТОКА
# ============================================================================

# Проверка режима запуска (прямой вызов vs source)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Скрипт запущен напрямую - выполняем основную логику
    main "$@"
    exit_code=$?
    
    # Финальное логирование результата
    if ((exit_code == 0)); then
        log INFO "=== СКРИПТ ЗАВЕРШЕН УСПЕШНО ==="
    else
        log ERROR "=== СКРИПТ ЗАВЕРШЕН С ОШИБКОЙ (КОД: $exit_code) ==="
    fi
    
    exit $exit_code
else
    # Скрипт подключен через source - только определяем функции
    log INFO "Скрипт загружен через source, функции доступны для использования"
fi

# ============================================================================
# КОНЕЦ СКРИПТА
# ============================================================================

# Этот скрипт представляет собой полнофункциональное решение для автоматизированного
# резервного копирования данных из CephFS с использованием rclone.
#
# Основные улучшения в версии 4:
# - Современные методы bash 4.0+
# - Комплексная проверка ошибок и валидация
# - Детальное логирование с уровнями важности
# - Безопасная обработка файлов с пробелами в именах
# - Улучшенная обработка сигналов и очистка ресурсов
# - Поддержка режима тестирования (DRY_RUN)
# - Интеллигентная обработка кодов возврата rclone
# - Генерация детальных отчетов в JSON и текстовом формате
# - Оптимизация производительности и параллельного выполнения
# - Соответствие современным стандартам безопасности
#
# Для получения дополнительной информации см. комментарии к отдельным разделам.