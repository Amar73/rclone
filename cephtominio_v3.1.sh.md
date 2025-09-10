Привет! Ты эксперт в области FreeBSD, MinIO и CEPH.
С сервера на FreeBSD 14.2 есть доступ к хранилищам Ceph S3 и MinIO S3.
Мне нужно создать новый bash скрипт синхронизации бакетов, координально изменив и улучшив старый bash скрипт.
Для этого нужно использовать самые последнии практики и рекомендации по наптсанию скриптов на bash.
Есть старый bash скрипт, с помощью которого утилитой rclone происходит синхронизация бакетов 
из хранилища Ceph S3 в хранилище MinIO S3:

```bash
#!/usr/local/bin/bash

# Конфигурация
LOGDIR="/var/log/rclone-backup"
LOCKFILE="/var/lock/backup.lock"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
DELETE_BACKUP="minio:backup-deleted"
RETENTION_DAYS=30
RCLONE_TRANSFERS=${RCLONE_TRANSFERS:-50}
RCLONE_CHECKERS=${RCLONE_CHECKERS:-50}
RCLONE_RETRIES=${RCLONE_RETRIES:-10}
RCLONE_PARALLEL=${RCLONE_PARALLEL:-4}
RCLONE_FLAGS=(
    "--progress"
    "--check-first"
    "--transfers=$RCLONE_TRANSFERS"
    "--checkers=$RCLONE_CHECKERS"
    "--stats=60s"
    "--fast-list"
    "--retries=$RCLONE_RETRIES"
    "--retries-sleep=10s"
    "--update"
    "--s3-upload-concurrency=20"
    "--checksum"
    "--s3-force-path-style"
    "--no-check-certificate"
    "--log-file=$LOGFILE"
    "--log-level=INFO"
    "--backup-dir=$DELETE_BACKUP/$(date +%F)"
)

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

# Проверка конфигурации rclone
if [[ ! -f "$RCLONE_CONFIG" ]]; then
    log ERROR "Конфиг rclone не найден: $RCLONE_CONFIG"
    exit 1
fi
if [[ "$(stat -f %Sp "$RCLONE_CONFIG")" != "-rw-------" ]]; then
    log WARNING "Небезопасные права доступа к $RCLONE_CONFIG. Рекомендуется: chmod 600 $RCLONE_CONFIG"
fi

# Блокировка с использованием flock
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log ERROR "Скрипт уже запущен. Выход."
    exit 1
fi
trap 'flock -u 200; rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

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

# Проверка доступности хранилищ
check_storage_access() {
    log INFO "Проверка доступности хранилищ..."

    # Список уникальных remote'ов
    local remotes=("test" "nbgi-init-sequencing" "nbgi-init-gd" "registry" "backup" "default" "minio")
    for remote in "${remotes[@]}"; do
        if ! rclone lsd "$remote:" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
            log ERROR "Хранилище $remote недоступно"
            return 1
        fi
        log INFO "Хранилище $remote доступно"
    done

    # Проверка состояния Ceph через SSH
    if command -v ssh >/dev/null; then
        if ! ssh svc02 "podman exec ceph-mon-svc02 ceph status" >/dev/null; then
            log WARNING "Проблемы с состоянием Ceph-кластера"
        else
            log INFO "Ceph-кластер в порядке"
        fi
    else
        log WARNING "Команда ssh недоступна, пропускаем проверку состояния Ceph"
    fi

    return 0
}

# Создание бакета при отсутствии
create_bucket_if_not_exists() {
    local remote="$1"
    local bucket="$2"
    if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
        log INFO "Бакет $bucket не существует. Создание..."
        if ! retry_command "rclone mkdir '$remote:$bucket' --config='$RCLONE_CONFIG'" 3 10; then
            log ERROR "Не удалось создать бакет $bucket"
            return 1
        fi
        log INFO "Бакет $bucket успешно создан"
    else
        log INFO "Бакет $bucket уже существует"
    fi
    return 0
}

# Частичная валидация
validate_backup() {
    local src="$1"
    local dst="$2"
    log INFO "Начата частичная валидация: $src -> $dst"

    local src_count=$(rclone lsf "$src" --files-only --config="$RCLONE_CONFIG" | wc -l)
    local dst_count=$(rclone lsf "$dst" --files-only --config="$RCLONE_CONFIG" | wc -l)

    if [[ "$src_count" -eq "$dst_count" ]]; then
        log INFO "Валидация успешна: количество файлов совпадает ($src_count)"
        return 0
    else
        log ERROR "Валидация не пройдена: $src_count файлов в источнике, $dst_count в бэкапе"
        return 1
    fi
}

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
    log INFO "Очистка завершена успешно"
}

# Обработка бакета
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
    if ! retry_command "rclone copy '$bucket' '$target_path' \
        --config='$RCLONE_CONFIG' ${RCLONE_FLAGS[*]}" 3 15; then
        log ERROR "Ошибка при синхронизации бакета: $bucket"
        return 1
    fi

    if ! validate_backup "$bucket" "$target_path"; then
        return 1
    fi
    log INFO "Синхронизация бакета $bucket успешно завершена"
}
export -f process_bucket log retry_command create_bucket_if_not_exists validate_backup
export RCLONE_CONFIG RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES LOGFILE DELETE_BACKUP

# Основная функция
perform_backup() {
    # Проверка хранилищ
    if ! check_storage_access; then
        log ERROR "Ошибка проверки доступности хранилищ"
        return 1
    fi

    # Проверка backup-deleted
    create_bucket_if_not_exists "minio" "backup-deleted" || return 1

    # Параллельная обработка бакетов
    log INFO "Начата синхронизация бакетов (параллельно: $RCLONE_PARALLEL потоков)"
    if ! printf "%s\0" "${buckets[@]}" | xargs -0 -n1 -P"$RCLONE_PARALLEL" -I{} bash -c 'process_bucket "$@"' _ {}; then
        log ERROR "Ошибки при синхронизации бакетов"
        return 1
    fi

    # Очистка устаревших данных
    cleanup_old_backups || log WARNING "Проблемы с очисткой, проверьте логи"

    return 0
}

# Основной поток
log INFO "***** Начат процесс резервного копирования *****"
log INFO "Запуск от пользователя: $(whoami)"
log INFO "Версия rclone: $(rclone --version | head -n1)"
log INFO "Конфиг rclone: $RCLONE_CONFIG"
log INFO "Параметры: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES parallel=$RCLONE_PARALLEL"

if perform_backup; then
    log INFO "Процесс бэкапа завершен успешно"
else
    log ERROR "Бэкап завершился с ошибками"
    exit 1
fi
```

Есть настроенный /root/.config/rclone/rclone.conf:

[nbgi-init-gd]
type = s3
provider = Ceph
access_key_id = ***************
secret_access_key = ***************
endpoint = http://172.30.10.15:8080

[nbgi-init-sequencing]
type = s3
provider = Ceph
access_key_id = ***************
secret_access_key = ***************
endpoint = http://172.30.10.15:8080

[registry]
type = s3
provider = Ceph
access_key_id = ***************
secret_access_key = ***************
endpoint = http://172.30.10.15:8080

[test]
type = s3
provider = Ceph
access_key_id = ***************
secret_access_key = ***************
endpoint = http://172.30.10.15:8080

[backup]
type = s3
provider = Ceph
access_key_id = ***************
secret_access_key = ***************
endpoint = http://172.30.10.15:8080

[default]
type = s3
provider = Ceph
access_key_id = ***************
secret_access_key = ***************
endpoint = http://172.30.10.14:8080

[minio]
type = s3
provider = Minio
access_key_id = ***************
secret_access_key = ***************
endpoint = https://minio01.apps.maket.nbgi.ru:9000

Для улучшения скрипта нужно использовать, как пример bash скрипт, копирующий объекты из CephFS  на локальную файловую систему- rclone_03.2.6.1.sh:

```bash
#!/usr/bin/env bash
#
# rclone_03.2.6.1.sh - Финальная рабочая версия (2.6.1)
# ================================================================
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
# - ИСПРАВЛЕНЫ ВСЕ ПРОБЛЕМЫ С ПАРСИНГОМ И ОТОБРАЖЕНИЕМ СТАТИСТИКИ
# - ВОССТАНОВЛЕНА функция check_ceph_cluster_status()
# - Поддержка современных методов безопасности и совместимости
#
# АВТОР: Ведущий инженер Андрей Марьяненко
# ВЕРСИЯ: 2.6.1 (Сентябрь 2025) - ВОССТАНОВЛЕНА ПРОВЕРКА СТАТУСА CEPH
# ТРЕБОВАНИЯ: bash 4.0+, rclone 1.60+, jq (опционально)
#
# ================================================================

# ============================================================================
# РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ СИСТЕМЫ И ПРОВЕРКА СОВМЕСТИМОСТИ
# ============================================================================

if ((BASH_VERSINFO[0] < 4)); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее. Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

set -eEuo pipefail
IFS=$'\n\t'
umask 027
export LANG=C LC_ALL=C

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.6.1"
readonly REQUIRED_RCLONE_VERSION="1.60"

# ============================================================================
# РАЗДЕЛ 2: КОНФИГУРАЦИЯ И НАСТРОЙКИ
# ============================================================================

readonly BACKUP_USER="${BACKUP_USER:-backup_user}"
readonly LOGDIR="${LOGDIR:-/var/log/backup}"
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
readonly EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"
readonly DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
readonly MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"

if [[ -n "${SOURCEDIRS:-}" ]]; then
    IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS"
else
    readonly -a SOURCEDIRS_ARRAY=(
    "/ceph/data/exp/idream/data/"
    "/ceph/data/exp/idream/data3/"
    "/ceph/nextcloud/"
    "/ceph/registry/"
    "/ceph/data/sw/"
    "/ceph/data/exp/bio/nextcloud_bio1/"
)
fi

readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"
readonly PARALLEL="${PARALLEL:-4}"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly MAX_LOGFILES="${MAX_LOGFILES:-100}"
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"

# ИСПРАВЛЕНО: Глобальные переменные для правильного отслеживания состояния
BACKUP_SUCCESS=true
REPORT_GENERATION_FAILED=false
ALL_BACKUP_PROCESSES_SUCCESS=true

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
    
    # ИСПРАВЛЕНО: Корректная логика определения успешности выполнения
    if ((exit_code == 0)); then
        if [[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" && "$REPORT_GENERATION_FAILED" == "false" ]]; then
            log INFO "Скрипт завершился успешно"
        elif [[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" && "$REPORT_GENERATION_FAILED" == "true" ]]; then
            log WARNING "Скрипт завершился с предупреждениями (резервное копирование успешно, проблемы с отчетами)"
        else
            log WARNING "Скрипт завершился с предупреждениями"
        fi
    else
        log ERROR "Скрипт завершился с ошибкой (код: $exit_code)"
        if [[ "$REPORT_GENERATION_FAILED" == "true" ]]; then
            log WARNING "Генерация детального отчета не удалась, создается базовый отчет"
            generate_basic_summary
        fi
    fi
    
    log INFO "=== ЗАВЕРШЕНИЕ РАБОТЫ СКРИПТА ==="
    
    exit $exit_code
}

signal_handler() {
    local signal=$1
    log WARNING "Получен сигнал $signal - начинаем корректное завершение работы"
    ALL_BACKUP_PROCESSES_SUCCESS=false
    exit 130
}

trap cleanup EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP

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
# РАЗДЕЛ 8: ПРОВЕРКА ФАЙЛА ИСКЛЮЧЕНИЙ
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
            ALL_BACKUP_PROCESSES_SUCCESS=false
            return $exit_code
        fi
    done
}

# ВОССТАНОВЛЕНО: Функция проверки состояния Ceph кластера
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
    
    # ВОССТАНОВЛЕНО: Вызов функции проверки состояния кластера
    check_ceph_cluster_status
    
    log INFO "Проверка доступности CephFS завершена успешно"
    return 0
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
        ALL_BACKUP_PROCESSES_SUCCESS=false
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
# РАЗДЕЛ 12: ПОЛНОСТЬЮ ИСПРАВЛЕННАЯ СИСТЕМА ПОДСЧЕТА СТАТИСТИКИ
# ============================================================================

# ИСПРАВЛЕНО: Функция парсинга статистики rclone возвращает отдельные значения
parse_rclone_stats() {
    local jsonlog_file="$1"
    
    if [[ ! -f "$jsonlog_file" ]]; then
        log DEBUG "JSON лог файл не найден: $jsonlog_file"
        echo "0 0 0 0 0 0 0 0"
        return 0
    fi
    
    local file_size
    if ! file_size=$(stat -c%s "$jsonlog_file" 2>/dev/null) || ((file_size == 0)); then
        log DEBUG "JSON лог файл пустой: $jsonlog_file"
        echo "0 0 0 0 0 0 0 0"
        return 0
    fi
    
    log DEBUG "Парсинг статистики из файла: $jsonlog_file (размер: $file_size байт)"
    
    local transfers=0 checks=0 deletes=0 errors=0 totalBytes=0 bytes=0 elapsedTime=0 speed=0
    
    set +e
    
    if command -v jq >/dev/null 2>&1; then
        log DEBUG "Используется jq для парсинга статистики rclone"
        
        local stats_data
        if stats_data=$(jq -c 'select(.stats != null) | .stats' "$jsonlog_file" 2>/dev/null | tail -1); then
            if [[ -n "$stats_data" && "$stats_data" != "null" ]]; then
                transfers=$(echo "$stats_data" | jq '.transfers // 0' 2>/dev/null || echo "0")
                checks=$(echo "$stats_data" | jq '.checks // 0' 2>/dev/null || echo "0")
                deletes=$(echo "$stats_data" | jq '.deletes // 0' 2>/dev/null || echo "0")
                errors=$(echo "$stats_data" | jq '.errors // 0' 2>/dev/null || echo "0")
                totalBytes=$(echo "$stats_data" | jq '.totalBytes // 0' 2>/dev/null || echo "0")
                bytes=$(echo "$stats_data" | jq '.bytes // 0' 2>/dev/null || echo "0")
                elapsedTime=$(echo "$stats_data" | jq '.elapsedTime // 0' 2>/dev/null || echo "0")
                speed=$(echo "$stats_data" | jq '.speed // 0' 2>/dev/null || echo "0")
            fi
        fi
    else
        log DEBUG "jq недоступен, используется резервный метод парсинга"
        
        local stats_lines
        if stats_lines=$(grep '"stats":' "$jsonlog_file" 2>/dev/null | tail -1); then
            transfers=$(echo "$stats_lines" | grep -o '"transfers":[0-9]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            checks=$(echo "$stats_lines" | grep -o '"checks":[0-9]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            deletes=$(echo "$stats_lines" | grep -o '"deletes":[0-9]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            errors=$(echo "$stats_lines" | grep -o '"errors":[0-9]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            totalBytes=$(echo "$stats_lines" | grep -o '"totalBytes":[0-9]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            bytes=$(echo "$stats_lines" | grep -o '"bytes":[0-9]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            elapsedTime=$(echo "$stats_lines" | grep -o '"elapsedTime":[0-9.]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
            speed=$(echo "$stats_lines" | grep -o '"speed":[0-9.]*' 2>/dev/null | cut -d':' -f2 | head -1 || echo "0")
        fi
    fi
    
    set -e
    
    # Проверка числовых значений
    [[ "$transfers" =~ ^[0-9]+$ ]] || transfers=0
    [[ "$checks" =~ ^[0-9]+$ ]] || checks=0
    [[ "$deletes" =~ ^[0-9]+$ ]] || deletes=0
    [[ "$errors" =~ ^[0-9]+$ ]] || errors=0
    [[ "$totalBytes" =~ ^[0-9]+$ ]] || totalBytes=0
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    [[ "$elapsedTime" =~ ^[0-9.]+$ ]] || elapsedTime=0
    [[ "$speed" =~ ^[0-9.]+$ ]] || speed=0
    
    log DEBUG "Финальная статистика: transfers=$transfers, checks=$checks, deletes=$deletes, errors=$errors"
    
    echo "$transfers $checks $deletes $errors $totalBytes $bytes $elapsedTime $speed"
}

# ИСПРАВЛЕНО: Функция подсчета статистики директорий
calculate_directory_stats() {
    local path="$1"
    
    if [[ -z "$path" || ! -d "$path" ]]; then
        echo "0 0"
        return 0
    fi
    
    log DEBUG "Подсчет статистики для: $path"
    
    local base_args=(
        --files-only
        --recursive
        --exclude-from="$EXCLUDE_FILE"
    )
    
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        base_args+=(--config="$RCLONE_CONFIG")
    fi
    
    local file_count=0 total_size=0
    
    set +e
    
    # Подсчет файлов
    if file_count=$(timeout 300 rclone lsf "${base_args[@]}" "$path" 2>/dev/null | wc -l); then
        log DEBUG "Количество файлов в $path: $file_count"
    else
        file_count=0
    fi
    
    # Подсчет размера
    if command -v jq >/dev/null 2>&1; then
        if total_size=$(timeout 300 rclone size --json "${base_args[@]}" "$path" 2>/dev/null | jq '.bytes // 0' 2>/dev/null); then
            if [[ "$total_size" =~ ^[0-9]+$ ]]; then
                log DEBUG "Общий размер файлов в $path: $total_size байт (метод: rclone size)"
            else
                total_size=0
            fi
        else
            total_size=0
        fi
    fi
    
    # Резервный метод если size не сработал
    if [[ "$total_size" == "0" ]]; then
        if total_size=$(timeout 300 rclone lsf --format s "${base_args[@]}" "$path" 2>/dev/null | \
                        awk '{if($1 != "" && $1 ~ /^[0-9]+$/) sum += $1} END {printf "%.0f", sum+0}'); then
            if [[ "$total_size" =~ ^[0-9]+$ ]]; then
                log DEBUG "Общий размер файлов в $path: $total_size байт (метод: rclone lsf)"
            else
                total_size=0
            fi
        else
            total_size=0
        fi
    fi
    
    set -e
    
    echo "$file_count $total_size"
}

# ИСПРАВЛЕНО: Функция корректного форматирования размеров
format_size() {
    local size_bytes="$1"
    
    if [[ -z "$size_bytes" || "$size_bytes" == "0" || ! "$size_bytes" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return 0
    fi
    
    # Для очень больших чисел используем более безопасный подход
    if ((size_bytes < 1024)); then
        echo "$size_bytes B"
        return 0
    fi
    
    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit_index=0
    local size=$size_bytes
    
    # Простое деление на 1024 с округлением
    while ((size >= 1024 && unit_index < ${#units[@]} - 1)); do
        ((size = size / 1024))
        ((unit_index++))
    done
    
    # Для более точного отображения используем арифметику с плавающей точкой
    local precise_size
    if command -v awk >/dev/null 2>&1; then
        precise_size=$(awk "BEGIN {printf \"%.2f\", $size_bytes / (1024 ^ $unit_index)}")
        echo "$precise_size ${units[unit_index]}"
    else
        echo "$size ${units[unit_index]}"
    fi
}

# ============================================================================
# РАЗДЕЛ 13: ИСПРАВЛЕННАЯ ГЕНЕРАЦИЯ ОТЧЕТОВ
# ============================================================================

# Базовый отчет при ошибках
generate_basic_summary() {
    local temp_txt
    
    if ! temp_txt="$(mktemp)"; then
        return 1
    fi
    
    {
        echo "==============================================================================="
        echo "                     БАЗОВАЯ СВОДКА РЕЗЕРВНОГО КОПИРОВАНИЯ"
        echo "==============================================================================="
        echo
        printf "Время завершения: %s\n" "$(date)"
        printf "Результат выполнения: %s\n" "$([[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" ]] && echo "success" || echo "failure")"
        printf "Версия скрипта: %s\n" "$SCRIPT_VERSION"
        printf "Пользователь: %s\n" "$(whoami)"
        printf "Хост: %s\n" "$(hostname -f 2>/dev/null || hostname)"
        printf "Режим тестирования: %s\n" "$DRY_RUN"
        echo
        echo "ПРИМЕЧАНИЕ: Детальная статистика недоступна из-за ошибок при обработке."
        echo "Проверьте основной лог-файл для получения подробной информации."
        echo
        printf "Файлы логов:\n"
        printf "  - Основной лог: %s\n" "${LOGFILE:-<не определен>}"
        printf "  - JSON лог rclone: %s\n" "${RCLONE_JSONLOG:-<не определен>}"
        echo
        echo "==============================================================================="
        echo "                              КОНЕЦ СВОДКИ"
        echo "==============================================================================="
    } > "$temp_txt"
    
    if [[ -f "$temp_txt" ]]; then
        cat "$temp_txt" > "${SUMMARY_TXT:-/tmp/backup_basic_summary.txt}"
        rm -f "$temp_txt"
        log INFO "Базовый отчет сохранен: ${SUMMARY_TXT:-/tmp/backup_basic_summary.txt}"
    fi
}

# ИСПРАВЛЕНО: Функция записи сводки без jq
write_summary_without_jq() {
    local result="$1"
    local temp_json
    
    if ! temp_json="$(mktemp)"; then
        REPORT_GENERATION_FAILED=true
        return 1
    fi
    
    # Парсинг статистики rclone
    local rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed
    
    set +e
    read -r rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed <<< "$(parse_rclone_stats "$RCLONE_JSONLOG")" || {
        rclone_transfers=0 rclone_checks=0 rclone_deletes=0 rclone_errors=0 rclone_total_bytes=0 rclone_bytes=0 rclone_elapsed=0 rclone_speed=0
    }
    set -e
    
    # Генерация JSON
    set +e
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
        printf '    "average_speed_bytes_per_second": %s\n' "$rclone_speed"
        echo '  },'
        echo '  "sources": ['
        
        local first=true dir dest_dir src_count src_bytes dest_count dest_bytes
        
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            dest_dir="$(dest_from_src "$dir")"
            
            src_count=0 src_bytes=0 dest_count=0 dest_bytes=0
            read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")" 2>/dev/null || true
            read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")" 2>/dev/null || true
            
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
    
    set -e
    
    if mv "$temp_json" "$SUMMARY_JSON" 2>/dev/null; then
        log INFO "Сводка сохранена (резервный метод): $SUMMARY_JSON"
        return 0
    else
        rm -f "$temp_json"
        REPORT_GENERATION_FAILED=true
        return 1
    fi
}

# ИСПРАВЛЕНО: Функция генерации человекочитаемой сводки
generate_human_readable_summary() {
    local json_file="$1"
    local result temp_txt
    
    result="$([[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" ]] && echo "success" || echo "failure")"
    
    if ! temp_txt="$(mktemp)"; then
        REPORT_GENERATION_FAILED=true
        return 1
    fi
    
    # Парсинг статистики
    local rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed
    
    set +e
    read -r rclone_transfers rclone_checks rclone_deletes rclone_errors rclone_total_bytes rclone_bytes rclone_elapsed rclone_speed <<< "$(parse_rclone_stats "$RCLONE_JSONLOG")" || {
        rclone_transfers=0 rclone_checks=0 rclone_deletes=0 rclone_errors=0 rclone_total_bytes=0 rclone_bytes=0 rclone_elapsed=0 rclone_speed=0
    }
    set -e
    
    # Генерация текстовой сводки
    set +e
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
        
        # Отображение времени выполнения
        if [[ "$rclone_elapsed" != "0" && "$rclone_elapsed" != "0.0" ]]; then
            if command -v awk >/dev/null 2>&1; then
                local hours minutes seconds
                hours=$(awk "BEGIN {printf \"%.0f\", $rclone_elapsed / 3600}")
                minutes=$(awk "BEGIN {printf \"%.0f\", ($rclone_elapsed % 3600) / 60}")
                seconds=$(awk "BEGIN {printf \"%.2f\", $rclone_elapsed % 60}")
                printf "Время выполнения: %s:%02d:%s\n" "$hours" "$minutes" "$seconds"
            else
                printf "Время выполнения: %.2f секунд\n" "$rclone_elapsed"
            fi
            
            if [[ "$rclone_speed" != "0" && "$rclone_speed" != "0.0" ]]; then
                local speed_int
                speed_int=$(awk "BEGIN {printf \"%.0f\", $rclone_speed}")
                printf "Средняя скорость: %s/сек\n" "$(format_size "$speed_int")"
            fi
        fi
        
        echo
        echo "-------------------------------------------------------------------------------"
        echo "СТАТИСТИКА ПО ДИРЕКТОРИЯМ:"
        echo "-------------------------------------------------------------------------------"
        
        # Статистика по директориям
        local dir dest_dir src_count src_bytes dest_count dest_bytes
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            dest_dir="$(dest_from_src "$dir")"
            src_count=0 src_bytes=0 dest_count=0 dest_bytes=0
            read -r src_count src_bytes <<< "$(calculate_directory_stats "$dir")" 2>/dev/null || true
            read -r dest_count dest_bytes <<< "$(calculate_directory_stats "$dest_dir")" 2>/dev/null || true
            
            printf "\nИсточник: %s\n" "$dir"
            printf "Назначение: %s\n" "$dest_dir"
            printf "  Файлов в источнике: %s (%s)\n" "$src_count" "$(format_size "$src_bytes")"
            printf "  Файлов в назначении: %s (%s)\n" "$dest_count" "$(format_size "$dest_bytes")"
        done
        
        echo
        echo "==============================================================================="
        echo "                              КОНЕЦ СВОДКИ"
        echo "==============================================================================="
    } > "$temp_txt"
    
    set -e
    
    if [[ -f "$temp_txt" ]] && cat "$temp_txt" | tee -a "$LOGFILE" > "$SUMMARY_TXT" 2>/dev/null; then
        rm -f "$temp_txt"
        log INFO "Человекочитаемая сводка сохранена: $SUMMARY_TXT"
        return 0
    else
        rm -f "$temp_txt"
        REPORT_GENERATION_FAILED=true
        return 1
    fi
}

# Основная функция записи сводки
write_summary() {
    local result="$1"
    
    log INFO "Генерация итоговой сводки (результат: $result)"
    
    local json_success=false text_success=false
    
    if command -v jq >/dev/null 2>&1; then
        log DEBUG "jq доступен, но используем резервный метод для стабильности"
    fi
    
    log DEBUG "Используется резервный метод без jq"
    if write_summary_without_jq "$result"; then
        json_success=true
    fi
    
    if generate_human_readable_summary "$SUMMARY_JSON"; then
        text_success=true
    fi
    
    if [[ "$json_success" == "true" && "$text_success" == "true" ]]; then
        log INFO "Генерация сводки завершена успешно"
    elif [[ "$json_success" == "true" || "$text_success" == "true" ]]; then
        log WARNING "Генерация сводки завершена частично"
        REPORT_GENERATION_FAILED=true
    else
        log ERROR "Генерация сводки завершилась с ошибками"
        REPORT_GENERATION_FAILED=true
        generate_basic_summary
    fi
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
    export SCRIPT_VERSION RCLONE_BUFFER_SIZE RCLONE_USE_MMAP RCLONE_LOG_LEVEL ALL_BACKUP_PROCESSES_SUCCESS
    
    log INFO "Функции и переменные экспортированы для параллельного выполнения"
    
    # ЭТАП 4: Выполнение резервного копирования директорий
    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
    log INFO "Обрабатываемые директории: ${SOURCEDIRS_ARRAY[*]}"
    log INFO "Максимальное количество параллельных процессов: $PARALLEL"
    
    local backup_start_time backup_end_time backup_duration
    backup_start_time=$(date +%s)
    
    # ИСПРАВЛЕНО: НЕ завершаем скрипт с ошибкой если параллельные процессы вернули код != 0
    set +e
    printf '%s\0' "${SOURCEDIRS_ARRAY[@]}" | xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'backup_directory "$1"' _ {}
    local xargs_exit_code=$?
    set -e
    
    if ((xargs_exit_code != 0)); then
        log WARNING "Некоторые процессы резервного копирования завершились с ошибками"
        ALL_BACKUP_PROCESSES_SUCCESS=false
    fi
    
    backup_end_time=$(date +%s)
    backup_duration=$((backup_end_time - backup_start_time))
    
    log INFO "Все процессы резервного копирования завершены"
    log INFO "Общее время резервного копирования: $(printf '%d:%02d:%02d' $((backup_duration/3600)) $((backup_duration%3600/60)) $((backup_duration%60)))"
    
    # ЭТАП 5: Генерация итоговой сводки
    log INFO "ЭТАП 5: Генерация итоговой сводки и отчетов"
    
    local final_result
    if [[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" ]]; then
        final_result="success"
        log INFO "ВСЕ ОПЕРАЦИИ РЕЗЕРВНОГО КОПИРОВАНИЯ ВЫПОЛНЕНЫ УСПЕШНО"
    else
        final_result="failure"
        log WARNING "РЕЗЕРВНОЕ КОПИРОВАНИЕ ЗАВЕРШЕНО С ОШИБКАМИ"
    fi
    
    # ИСПРАВЛЕНО: Защищенная генерация отчетов НЕ влияет на exit code
    set +e
    write_summary "$final_result"
    set -e
    
    log INFO "========== ЗАВЕРШЕНИЕ ОСНОВНОГО ПОТОКА РЕЗЕРВНОГО КОПИРОВАНИЯ =========="
    
    # ИСПРАВЛЕНО: Возвращаем 0 если резервное копирование успешно, независимо от отчетов
    if [[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# РАЗДЕЛ 15: ЗАПУСК ОСНОВНОГО ПОТОКА
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit_code=$?
    
    if ((exit_code == 0)); then
        if [[ "$ALL_BACKUP_PROCESSES_SUCCESS" == "true" ]]; then
            if [[ "$REPORT_GENERATION_FAILED" == "false" ]]; then
                log INFO "=== СКРИПТ ЗАВЕРШЕН УСПЕШНО ==="
            else
                log WARNING "=== СКРИПТ ЗАВЕРШЕН С ПРЕДУПРЕЖДЕНИЯМИ (РЕЗЕРВНОЕ КОПИРОВАНИЕ УСПЕШНО, ПРОБЛЕМЫ С ОТЧЕТАМИ) ==="
            fi
        fi
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

# Основные исправления в версии 2.6.1:
# 
# ВОССТАНОВЛЕННАЯ ФУНКЦИОНАЛЬНОСТЬ:
# - ВОССТАНОВЛЕНО: Функция check_ceph_cluster_status() с обновленным хостом cephrgw01
# - ВОССТАНОВЛЕНО: Вызов check_ceph_cluster_status() в функции check_ceph_access()
# - Проверка состояния Ceph кластера теперь работает корректно
# - Обновлен номер версии до 2.6.1
# 
# СОХРАНЕННАЯ ФУНКЦИОНАЛЬНОСТЬ:
# - Все исправления из версии 2.6 сохранены
# - Корректный парсинг статистики rclone
# - Правильное форматирование размеров файлов
# - Корректный exit code (0 при успешном резервном копировании)
# - Правильное определение результата выполнения (success/failure)
```
Создай новый bash скрипт синхронизации бакетов с максимально подробными комментариями на русском языке.