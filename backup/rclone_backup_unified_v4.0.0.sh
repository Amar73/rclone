#!/usr/bin/env bash
# ==============================================================================
# rclone_backup_unified_v4.0.0.sh — Единый скрипт резервного копирования
#                                    CephFS → локальная ФС (arch03 / arch04 / arch05)
# ==============================================================================
#
# НАЗНАЧЕНИЕ:
#   Заменяет три независимо расходившихся скрипта:
#     rclone_03_v3.2.0.sh, rclone_04.3.0.sh, rclone_05.2.6.1.sh
#   Один и тот же код на всех трёх хостах, конфигурация — только через
#   переменные окружения. Основа — rclone_04.3.0.sh (самая зрелая версия),
#   с исправлением найденных при аудите (2026-07) дефектов.
#
# ЧТО ИСПРАВЛЕНО ПО СРАВНЕНИЮ С rclone_04.3.0.sh:
#   1. Баг разбора статистики: IFS=$'\n\t' (без пробела) ломал все
#      `read -r a b c <<< "$строка_с_пробелами"` — числа склеивались в одну
#      переменную (видно в старых логах на всех трёх хостах). Исправлено:
#      явный `IFS=' '` на месте разбора (тот же приём уже использовался для
#      SOURCEDIRS в оригинале — теперь применён везде).
#   2. Нет более безопасного (host-specific) значения SOURCEDIRS по умолчанию.
#      Раньше скрипт молча копировал idream/, если забыть задать SOURCEDIRS —
#      в общем скрипте для трёх разных хостов это может привести к запуску
#      не с той конфигурацией. Теперь SOURCEDIRS обязателен, при отсутствии —
#      явная ошибка при старте.
#   3. jq сделан обязательной зависимостью (установлен на всех трёх хостах
#      07.2026). Хрупкий резервный разбор через grep/cut, который на практике
#      использовался постоянно (jq раньше нигде не стоял) и был источником
#      части прошлых багов, удалён — меньше кода, меньше путей отказа.
#   4. Таймаут подсчёта статистики директорий увеличен и вынесен в переменную
#      (DIR_STATS_TIMEOUT). На arch03 фиксированные 300с оказались мало для
#      обхода CephFS — статистика источника обнулялась (0 файлов) во всех
#      директориях последнего прогона.
#   5. Добавлена возможность отключить --checksum (RCLONE_CHECKSUM_MODE=false)
#      для быстрой синхронизации по размеру+mtime вместо полного пересчёта
#      контрольных сумм каждого файла по сети — вероятно, главный вклад
#      в цикл 5-8 суток. По умолчанию поведение НЕ меняется (true, как раньше).
#   6. При успешном завершении обновляется файл-метка "$LOGDIR/.last_success"
#      (mtime = время последнего успешного бэкапа) — простая точка опоры для
#      внешнего мониторинга/алерта "давно не запускался" (что и произошло:
#      все три хоста простаивали 105-122 дня без единого сигнала).
#   7. Удалена неиспользуемая переменная BACKUP_USER (мёртвый код).
#   8. --update и --track-renames по-прежнему НЕ используются вместе
#      с --checksum (как и было исправлено в 04.3.0; на arch03/05 этот
#      фикс отсутствовал).
#
# АРХИТЕКТУРА ХРАНЕНИЯ:
#   /backup/main/      — актуальные резервные копии (зеркало CephFS)
#   /backup/deleted/   — файлы, удалённые из источника (хранятся 30 дней)
#   /var/log/backup/   — логи (текст + JSON от rclone)
#
# ОБЯЗАТЕЛЬНАЯ ПЕРЕМЕННАЯ ОКРУЖЕНИЯ (без неё скрипт не запустится):
#   SOURCEDIRS  — список директорий источника через пробел. Пример:
#                 arch03: SOURCEDIRS="/ceph/data/exp/idream/data /ceph/data/exp/idream/data3 /ceph/nextcloud /ceph/registry /ceph/data/sw /ceph/data/exp/bio/nextcloud_bio1"
#                 arch04: SOURCEDIRS="/ceph/data/exp/idream/"
#                 arch05: SOURCEDIRS="/ceph/data/users/ /ceph/data/groups/"
#
# ОСТАЛЬНЫЕ ПЕРЕМЕННЫЕ (со значениями по умолчанию):
#   MAIN_BACKUP             — куда копировать (/backup/main)
#   DELETE_BACKUP           — куда складывать удалённые файлы (/backup/deleted)
#   LOGDIR                  — директория логов (/var/log/backup)
#   LOCKFILE                — файл блокировки (/var/lock/backup.lock)
#   EXCLUDE_FILE            — файл правил исключения
#                             (/usr/local/bin/scripts/exclude-file.txt)
#                             Файл должен существовать; пустой файл — ок
#                             (означает "ничего не исключать"; например,
#                             на arch03 exclude-file.txt создан заранее для
#                             возможного использования в будущем и пока пуст).
#   RCLONE_TRANSFERS        — число параллельных передач rclone (30)
#   RCLONE_CHECKERS         — число потоков проверки rclone (8)
#   RCLONE_RETRIES          — число повторов при ошибке (5)
#   RCLONE_RETRIES_SLEEP    — пауза между повторами (10s)
#   RCLONE_BUFFER_SIZE      — буфер памяти на файл (16M)
#   RCLONE_CHECKSUM_MODE    — true: сравнение по контрольной сумме (--checksum,
#                             как раньше); false: быстрое сравнение по
#                             размеру+mtime (по умолчанию: true)
#   PARALLEL                — макс. число параллельных директорий (4)
#   DRY_RUN                 — тестовый режим без изменений (false)
#   MAX_LOGFILES            — максимум лог-файлов в LOGDIR (100)
#   LOG_RETENTION_DAYS      — хранить логи N дней (30)
#   DELETE_RETENTION_DAYS   — хранить удалённые файлы N дней (30)
#   DIR_STATS_TIMEOUT       — таймаут подсчёта статистики директории, сек (900)
#   CEPH_MON_HOST           — хост для проверки статуса Ceph (cephrgw01)
#   CEPH_MON_CONTAINER      — имя podman-контейнера ceph-mon (ceph-mon-cephrgw01)
#
# ПРИМЕРЫ ЗАПУСКА:
#   SOURCEDIRS="/ceph/data/exp/idream/" ./rclone_backup_unified_v4.0.0.sh
#   DRY_RUN=true SOURCEDIRS="/ceph/data/users/ /ceph/data/groups/" ./rclone_backup_unified_v4.0.0.sh
#
# ТРЕБОВАНИЯ:
#   - bash 4.0+
#   - rclone 1.60+
#   - jq (обязательно)
#   - CentOS 7 / RHEL 7 и новее
#   - SSH-доступ к хосту Ceph MON (опционально, для проверки статуса кластера)
#
# ВОЗВРАЩАЕМЫЕ КОДЫ:
#   0   — резервное копирование выполнено успешно
#   1   — ошибка конфигурации, монтирования или копирования
#   130 — прерван сигналом SIGINT (Ctrl+C)
#   143 — прерван сигналом SIGTERM
#   129 — прерван сигналом SIGHUP
#
# АВТОР: Ведущий инженер Андрей Марьяненко
# ВЕРСИЯ: 4.0.0 (Июль 2026) — унификация arch03/04/05 + аудиторские фиксы
# ==============================================================================


# ==============================================================================
# РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ ОБОЛОЧКИ И ПРОВЕРКА СОВМЕСТИМОСТИ
# ==============================================================================

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее." \
         "Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

set -eEuo pipefail

# Разделители полей: только перевод строки и табуляция.
# Пробел исключён намеренно, чтобы пути с пробелами не разбивались на части.
# ВАЖНО: из-за этого любое разбиение строки на слова по пробелу (SOURCEDIRS,
# статистика rclone) требует явного `IFS=' ' read -r ...` на месте вызова —
# именно отсутствие этого явного IFS было причиной бага с битой статистикой
# во всех трёх версиях-предшественниках.
IFS=$'\n\t'

umask 027
export LANG=C LC_ALL=C

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="4.0.0"
readonly REQUIRED_RCLONE_VERSION="1.60"


# ==============================================================================
# РАЗДЕЛ 2: КОНФИГУРАЦИЯ — ПАРАМЕТРЫ С УМОЛЧАНИЯМИ
# ==============================================================================

readonly LOGDIR="${LOGDIR:-/var/log/backup}"
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
readonly EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"
readonly DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
readonly MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"

readonly CEPH_MON_HOST="${CEPH_MON_HOST:-cephrgw01}"
readonly CEPH_MON_CONTAINER="${CEPH_MON_CONTAINER:-ceph-mon-cephrgw01}"

readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"
readonly RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-16M}"
readonly RCLONE_CHECKSUM_MODE="${RCLONE_CHECKSUM_MODE:-true}"

readonly PARALLEL="${PARALLEL:-4}"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly MAX_LOGFILES="${MAX_LOGFILES:-100}"
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"
readonly DIR_STATS_TIMEOUT="${DIR_STATS_TIMEOUT:-900}"

# SOURCEDIRS обязателен: единого разумного умолчания для трёх разных хостов
# с разным набором директорий не существует. Раньше скрипт молча подставлял
# '/ceph/data/exp/idream/' — в общем скрипте это может привести к запуску
# не с той конфигурацией на чужом хосте.
if [[ -z "${SOURCEDIRS:-}" ]]; then
    echo "ОШИБКА: Переменная SOURCEDIRS обязательна и не задана." \
         "Единого умолчания для arch03/04/05 нет — укажите явно, например:" >&2
    echo "  SOURCEDIRS=\"/ceph/data/exp/idream/\" $0" >&2
    exit 1
fi
IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS"

BACKUP_SUCCESS=true
REPORT_GENERATION_FAILED=false
WATCHDOG_PID=""


# ==============================================================================
# РАЗДЕЛ 3: РАННИЕ ПРОВЕРКИ КОНФИГУРАЦИИ
# ==============================================================================

validate_source_directories() {
    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            echo "ОШИБКА: Источник '$dir' не находится внутри /ceph." \
                 "Все источники должны начинаться с /ceph/" >&2
            exit 1
        fi

        if [[ ! "$dir" =~ ^[a-zA-Z0-9/_.\-]+/?$ ]]; then
            echo "ОШИБКА: Путь '$dir' содержит недопустимые символы." \
                 "Допустимы только: a-z A-Z 0-9 / _ - ." >&2
            exit 1
        fi
    done
}

check_required_commands() {
    local cmd
    local missing_commands=()
    local required_commands=(
        "rclone" "mount" "mountpoint" "find" "awk" "date" "mkdir"
        "flock" "timeout" "ssh" "jq"
    )

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if (( ${#missing_commands[@]} > 0 )); then
        echo "ОШИБКА: Не найдены необходимые команды: ${missing_commands[*]}" >&2
        echo "Установите недостающие пакеты и повторите запуск." >&2
        exit 1
    fi
}

check_rclone_version() {
    local rclone_version
    if ! rclone_version=$(rclone --version 2>/dev/null | head -n1 \
                          | awk '{print $2}' | sed 's/^v//'); then
        echo "ОШИБКА: Не удалось определить версию rclone." \
             "Проверьте, что rclone установлен корректно." >&2
        exit 1
    fi

    local required_major required_minor current_major current_minor
    IFS='.' read -r required_major required_minor _ <<< "$REQUIRED_RCLONE_VERSION"
    IFS='.' read -r current_major current_minor _  <<< "$rclone_version"

    if (( current_major < required_major ||
          (current_major == required_major && current_minor < required_minor) )); then
        echo "ПРЕДУПРЕЖДЕНИЕ: Рекомендуется rclone >= $REQUIRED_RCLONE_VERSION." \
             "Текущая: $rclone_version" >&2
    fi
}

validate_source_directories
check_required_commands
check_rclone_version


# ==============================================================================
# РАЗДЕЛ 4: СИСТЕМА ЛОГИРОВАНИЯ
# ==============================================================================

log() {
    local level="${1:-INFO}"
    shift || true
    local message="${*:-}"
    local timestamp
    timestamp="$(date -Iseconds)"

    local color_code=""
    if [[ -t 2 ]]; then
        case "$level" in
            DEBUG)    color_code="\033[36m"    ;;
            INFO)     color_code="\033[32m"    ;;
            WARNING)  color_code="\033[33m"    ;;
            ERROR)    color_code="\033[31m"    ;;
            CRITICAL) color_code="\033[35;1m"  ;;
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


# ==============================================================================
# РАЗДЕЛ 5: ИНИЦИАЛИЗАЦИЯ ФАЙЛОВОЙ СИСТЕМЫ И ЛОГОВ
# ==============================================================================

create_directories() {
    local dir
    for dir in "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || {
                echo "ОШИБКА: Не удалось создать директорию: $dir" >&2
                exit 1
            }
        fi

        if [[ ! -w "$dir" ]]; then
            echo "ОШИБКА: Нет прав на запись в директорию: $dir" >&2
            exit 1
        fi
    done
}

initialize_logging() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"

    readonly LOGFILE="${LOGDIR}/backup_${timestamp}.log"
    readonly RCLONE_JSONLOG_DIR="${LOGDIR}/jsonlogs_${timestamp}"
    readonly SUMMARY_JSON="${LOGDIR}/backup_${timestamp}.summary.json"
    readonly SUMMARY_TXT="${LOGDIR}/backup_${timestamp}.summary.txt"
    readonly LAST_SUCCESS_MARKER="${LOGDIR}/.last_success"

    mkdir -p "$RCLONE_JSONLOG_DIR" || {
        echo "ОШИБКА: Не удалось создать директорию JSON-логов: $RCLONE_JSONLOG_DIR" >&2
        exit 1
    }

    log INFO "=== ЗАПУСК СКРИПТА РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "Версия скрипта: $SCRIPT_VERSION"
    log INFO "Пользователь: $(whoami) (UID: $(id -u))"
    log INFO "Hostname: $(hostname -f 2>/dev/null || hostname)"
    log INFO "Рабочая директория: $(pwd)"
    log INFO "PID процесса: $$"
    log INFO "Режим DRY_RUN: $DRY_RUN"
    log INFO "Режим RCLONE_CHECKSUM_MODE: $RCLONE_CHECKSUM_MODE"
    log INFO "Версия bash: ${BASH_VERSION}"
    log INFO "Версия rclone: $(rclone --version 2>/dev/null | head -n1 \
              | awk '{print $2}' || echo 'неопределена')"
}

rotate_logs() {
    log INFO "Начало ротации логов в '$LOGDIR' (хранить ${LOG_RETENTION_DAYS} дней)"

    local deleted_count=0
    local pattern

    for pattern in 'backup_*.log' 'backup_*.summary.json' 'backup_*.summary.txt'; do
        local count
        count=$(find "$LOGDIR" -maxdepth 1 -type f -name "$pattern" \
                    -mtime "+${LOG_RETENTION_DAYS}" -delete -print 2>/dev/null | wc -l)
        deleted_count=$(( deleted_count + count ))
    done

    local dir_count
    dir_count=$(find "$LOGDIR" -maxdepth 1 -type d -name 'jsonlogs_*' \
                    -mtime "+${LOG_RETENTION_DAYS}" 2>/dev/null | wc -l)
    if (( dir_count > 0 )); then
        find "$LOGDIR" -maxdepth 1 -type d -name 'jsonlogs_*' \
             -mtime "+${LOG_RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
        deleted_count=$(( deleted_count + dir_count ))
    fi

    if (( deleted_count > 0 )); then
        log INFO "Удалено $deleted_count старых объектов логов (старше ${LOG_RETENTION_DAYS} дней)"
    fi

    local current_count
    current_count=$(find "$LOGDIR" -maxdepth 1 -type f -name 'backup_*.log' \
                        2>/dev/null | wc -l)
    if (( current_count > MAX_LOGFILES )); then
        log WARNING "Количество лог-файлов ($current_count) превышает лимит ($MAX_LOGFILES)." \
                    "Рекомендуется уменьшить LOG_RETENTION_DAYS или увеличить MAX_LOGFILES."
    fi

    log INFO "Ротация логов завершена"
}

create_directories
initialize_logging
rotate_logs


# ==============================================================================
# РАЗДЕЛ 6: БЛОКИРОВКА И ОБРАБОТКА СИГНАЛОВ
# ==============================================================================

LOCK_FD=""

cleanup() {
    local exit_code=$?

    log INFO "Начало процедуры очистки ресурсов..."

    if [[ -n "${WATCHDOG_PID:-}" ]]; then
        log DEBUG "ceph_watchdog: ожидание завершения текущего восстановления" \
                  "перед остановкой..."
        local wd_stop_lock_fd
        if exec {wd_stop_lock_fd}>"$CEPH_WATCHDOG_LOCKFILE" 2>/dev/null; then
            if ! flock -w "$CEPH_WATCHDOG_STOP_WAIT_TIMEOUT" "$wd_stop_lock_fd"; then
                log WARNING "ceph_watchdog: не дождался завершения" \
                            "ceph_watchdog_recover за" \
                            "${CEPH_WATCHDOG_STOP_WAIT_TIMEOUT}с, останавливаю" \
                            "watchdog принудительно"
            fi
            flock -u "$wd_stop_lock_fd" 2>/dev/null || true
            exec {wd_stop_lock_fd}>&- 2>/dev/null || true
        fi

        log DEBUG "Останавливаю ceph_watchdog (PID: $WATCHDOG_PID)"
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi

    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true

        if (( BASH_VERSINFO[0] > 4 ||
              (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )); then
            eval "exec {LOCK_FD}<&-" 2>/dev/null || true
        fi
        log DEBUG "Блокировка снята (дескриптор: $LOCK_FD)"
    fi

    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE" || true
        log DEBUG "Файл блокировки удалён: $LOCKFILE"
    fi

    if (( exit_code == 0 )); then
        if [[ "${BACKUP_SUCCESS:-true}" == "true" && \
              "${REPORT_GENERATION_FAILED:-false}" == "false" ]]; then
            log INFO "Скрипт завершился успешно (код: 0)"
        else
            log WARNING "Скрипт завершился с предупреждениями" \
                        "(резервное копирование: ${BACKUP_SUCCESS:-?}," \
                        "отчёт: ${REPORT_GENERATION_FAILED:-?})"
        fi
    else
        log ERROR "Скрипт завершился с ошибкой (код: $exit_code)"
    fi

    log INFO "=== ЗАВЕРШЕНИЕ РАБОТЫ СКРИПТА ==="

    exit "$exit_code"
}

signal_handler() {
    local signal="$1"
    local exit_code

    case "$signal" in
        HUP)  exit_code=129 ;;
        INT)  exit_code=130 ;;
        TERM) exit_code=143 ;;
        *)    exit_code=1   ;;
    esac

    log WARNING "Получен сигнал $signal — начинаем корректное завершение работы"
    BACKUP_SUCCESS=false

    exit "$exit_code"
}

trap cleanup EXIT
trap 'signal_handler INT'  INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP'  HUP

if (( BASH_VERSINFO[0] > 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )); then
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
    log ERROR "Другой экземпляр скрипта уже выполняется." \
              "Файл блокировки: $LOCKFILE"
    exit 1
fi

log INFO "Блокировка получена (дескриптор: $LOCK_FD)"


# ==============================================================================
# РАЗДЕЛ 7: КОНФИГУРАЦИЯ RCLONE
# ==============================================================================

initialize_rclone_config() {
    log INFO "Инициализация конфигурации rclone"

    local rclone_config_output rclone_config_path
    if rclone_config_output=$(rclone config file 2>/dev/null); then
        rclone_config_path=$(
            echo "$rclone_config_output" \
            | awk -F': ' '/Configuration file is stored at:/ {print $2}' \
            | xargs 2>/dev/null || true
        )

        if [[ -n "$rclone_config_path" && -r "$rclone_config_path" ]]; then
            export RCLONE_CONFIG="$rclone_config_path"
            log INFO "Конфигурационный файл rclone: $RCLONE_CONFIG"
        else
            log WARNING "Конфигурационный файл rclone не найден или недоступен для чтения." \
                        "rclone будет использовать настройки по умолчанию."
            unset RCLONE_CONFIG
        fi
    else
        log WARNING "Не удалось определить путь к конфигурационному файлу rclone."
        unset RCLONE_CONFIG
    fi

    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES
    export RCLONE_BUFFER_SIZE
    export RCLONE_USE_MMAP="${RCLONE_USE_MMAP:-true}"
    export RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"

    log INFO "Конфигурация rclone:"
    log DEBUG "  RCLONE_TRANSFERS=$RCLONE_TRANSFERS"
    log DEBUG "  RCLONE_CHECKERS=$RCLONE_CHECKERS"
    log DEBUG "  RCLONE_RETRIES=$RCLONE_RETRIES"
    log DEBUG "  RCLONE_BUFFER_SIZE=$RCLONE_BUFFER_SIZE"
    log DEBUG "  RCLONE_CHECKSUM_MODE=$RCLONE_CHECKSUM_MODE"
}

initialize_rclone_config


# ==============================================================================
# РАЗДЕЛ 8: ПРОВЕРКА ФАЙЛА ИСКЛЮЧЕНИЙ
# ==============================================================================
# Файл должен существовать, но может быть пустым — пустой файл означает
# "ничего не исключать" и не является ошибкой (например, на arch03
# exclude-file.txt создан заранее для возможного использования в будущем
# и намеренно пуст на момент унификации скрипта).

validate_exclude_file() {
    log INFO "Проверка файла исключений: $EXCLUDE_FILE"

    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений не найден: $EXCLUDE_FILE." \
                  "Создайте файл (можно пустой) или измените переменную EXCLUDE_FILE."
        exit 1
    fi

    if [[ ! -r "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений недоступен для чтения: $EXCLUDE_FILE." \
                  "Проверьте права доступа."
        exit 1
    fi

    if [[ ! -s "$EXCLUDE_FILE" ]]; then
        log WARNING "Файл исключений пустой: $EXCLUDE_FILE." \
                    "Будут скопированы все файлы без исключений."
    else
        local exclude_count
        exclude_count=$(wc -l < "$EXCLUDE_FILE")
        log INFO "Файл исключений содержит $exclude_count правил"
    fi

    local line_number=0
    local -a invalid_lines=()
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_number++ )) || true

        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ \$\(|\`|\;|\||\&\&|\|\| ]]; then
            invalid_lines+=("строка ${line_number}: $line")
        fi
    done < "$EXCLUDE_FILE" || true

    if (( ${#invalid_lines[@]} > 0 )); then
        log ERROR "Обнаружены потенциально опасные правила в файле исключений:"
        printf '  %s\n' "${invalid_lines[@]}" >&2
        exit 1
    fi

    log INFO "Файл исключений прошёл проверку безопасности"
}

validate_exclude_file


# ==============================================================================
# РАЗДЕЛ 9: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

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
    local delay_sec="$2"
    shift 2
    local -a cmd=("$@")
    local attempt exit_code

    for (( attempt = 1; attempt <= retries; attempt++ )); do
        log INFO "Попытка $attempt/$retries: $(cmd_to_string "${cmd[@]}")"

        set +e

        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            if   [[ "$line" =~ (ERROR|CRITICAL|Failed|Fatal) ]]; then
                log ERROR   "rclone: $line"
            elif [[ "$line" =~ (WARNING|WARN) ]]; then
                log WARNING "rclone: $line"
            elif [[ "$DRY_RUN" == "true" || "$line" =~ (Copied|Deleted|Moved) ]]; then
                log INFO    "rclone: $line"
            else
                log DEBUG   "rclone: $line"
            fi
        done

        exit_code="${PIPESTATUS[0]}"
        set -e

        case "$exit_code" in
            0)
                log INFO "Команда выполнена успешно (попытка $attempt)"
                return 0
                ;;
            1)
                if [[ "${cmd[1]:-}" == "rmdirs" || "${cmd[1]:-}" == "delete" ]]; then
                    log INFO "Команда '${cmd[1]}' завершена: нет файлов для обработки"
                    return 0
                fi
                ;;
            3)
                if [[ "${cmd[1]:-}" == "sync" || "${cmd[1]:-}" == "copy" ]]; then
                    log INFO "Команда '${cmd[1]}' завершена: нет изменений для копирования"
                    return 0
                fi
                ;;
        esac

        if (( attempt < retries )); then
            log WARNING "Ошибка выполнения (код: $exit_code)." \
                        "Повтор через ${delay_sec} сек. (попытка $((attempt+1))/$retries)"
            sleep "$delay_sec"
        else
            log ERROR "Команда не выполнилась после $retries попыток." \
                      "Финальный код возврата: $exit_code"
            return "$exit_code"
        fi
    done
}


# ==============================================================================
# РАЗДЕЛ 10: ПРОВЕРКА ДОСТУПНОСТИ CEPH
# ==============================================================================

check_ceph_cluster_status() {
    log DEBUG "Проверка состояния Ceph-кластера через ${CEPH_MON_HOST}"

    local ceph_status
    if ceph_status=$(
        timeout 10 ssh \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            "$CEPH_MON_HOST" \
            "podman exec ${CEPH_MON_CONTAINER} ceph status" \
            2>/dev/null
    ); then
        if echo "$ceph_status" | grep -qi "health_err"; then
            log ERROR "Ceph-кластер сообщает о критических ошибках (HEALTH_ERR)." \
                      "Рекомендуется проверить кластер перед копированием."
        elif echo "$ceph_status" | grep -qi "health_warn"; then
            log WARNING "Ceph-кластер сообщает о предупреждениях (HEALTH_WARN)." \
                        "Резервное копирование продолжается."
        else
            log INFO "Состояние Ceph-кластера: OK (HEALTH_OK)"
        fi
    else
        log DEBUG "Не удалось получить статус Ceph-кластера через SSH к ${CEPH_MON_HOST}." \
                  "Это не критично — продолжаем."
    fi
}

check_ceph_access() {
    log INFO "Проверка доступности CephFS"

    if ! awk '$1 !~ /^#/ && $2 == "/ceph" {found=1} END {exit !found}' \
         /etc/fstab 2>/dev/null; then
        log ERROR "CephFS не настроен в /etc/fstab (нет записи для точки монтирования /ceph)." \
                  "Добавьте запись в /etc/fstab и повторите запуск."
        return 1
    fi

    if ! mountpoint -q /ceph 2>/dev/null; then
        log WARNING "/ceph не смонтирован — пытаемся смонтировать..."

        if (( EUID != 0 )); then
            log ERROR "Для монтирования CephFS нужны права root (текущий UID: $EUID)." \
                      "Запустите скрипт от root или через sudo."
            return 1
        fi

        local mount_attempt
        for mount_attempt in {1..5}; do
            log INFO "Попытка монтирования CephFS: $mount_attempt/5"

            if mount /ceph 2>>"$LOGFILE"; then
                log INFO "CephFS успешно смонтирован"
                break
            fi

            if (( mount_attempt < 5 )); then
                log WARNING "Монтирование не удалось — ждём 5 секунд перед повтором"
                sleep 5
            fi
        done

        if ! mountpoint -q /ceph 2>/dev/null; then
            log ERROR "Не удалось смонтировать CephFS после 5 попыток." \
                      "Проверьте доступность Ceph-кластера и настройки /etc/fstab."
            return 1
        fi
    else
        log DEBUG "/ceph уже смонтирован"
    fi

    if ! timeout 10 ls /ceph >/dev/null 2>&1; then
        log ERROR "Нет доступа к /ceph для чтения (возможно, кластер недоступен)."
        return 1
    fi

    local -a missing_dirs=()
    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs+=("$dir")
        fi
    done

    if (( ${#missing_dirs[@]} > 0 )); then
        log ERROR "Следующие исходные директории не найдены:"
        printf '  %s\n' "${missing_dirs[@]}" >&2
        log ERROR "Проверьте, что директории существуют и доступны."
        return 1
    fi

    check_ceph_cluster_status

    log INFO "CephFS доступен. Все исходные директории найдены."
    return 0
}

# ==============================================================================
# РАЗДЕЛ 10.1: СТОРОЖ CEPH ВО ВРЕМЯ КОПИРОВАНИЯ (ceph_watchdog)
# ==============================================================================
#
# В отличие от check_ceph_access (разовая проверка на ЭТАП 1, до старта),
# этот сторож работает в фоне ВЕСЬ ЭТАП 4 (параллельное копирование, может
# длиться часы). Обнаруживает случай "точка монтирования формально есть, но
# обращение зависает/даёт Permission denied" (mds0 rejected session) — сбой,
# который 2026-07-07 привёл к тому, что rclone sync отработал на усечённом
# списке файлов и переместил ~350 тысяч файлов sw в карантин через
# --delete-excluded.
#
# При обнаружении устойчивого сбоя: останавливает текущие rclone-процессы
# ДО того как они успеют принять решение об удалении на основе битого
# списка, перемонтирует /ceph, и позволяет уже существующему retry_command
# (см. backup_directory) честно перезапустить sync с чистого монтирования.
# Здесь НЕ предпринимается попытка "продолжить" уже запущенный процесс.

readonly CEPH_WATCHDOG_CHECK_INTERVAL=20
readonly CEPH_WATCHDOG_FAILURE_THRESHOLD=2
readonly CEPH_WATCHDOG_STAT_TIMEOUT=5
readonly CEPH_WATCHDOG_KILL_GRACE=3
readonly CEPH_WATCHDOG_REMOUNT_ATTEMPTS=5
readonly CEPH_WATCHDOG_REMOUNT_SLEEP=5
readonly CEPH_WATCHDOG_UMOUNT_TIMEOUT=15
readonly CEPH_WATCHDOG_MOUNT_TIMEOUT=15
# Грейс-период для `timeout -k` вокруг umount/mount: без -k GNU timeout
# лишь один раз посылает SIGTERM по истечении DURATION и затем молча
# ЖДЁТ завершения процесса — если umount/mount завис на уровне ядра
# (недоступный CephFS), SIGTERM может быть проигнорирован/не доставлен
# сколь угодно долго, и timeout перестаёт быть реальной границей.
# -k гарантирует принудительный SIGKILL через это число секунд после
# SIGTERM.
readonly CEPH_WATCHDOG_TIMEOUT_KILL_GRACE=5
readonly CEPH_WATCHDOG_LOCKFILE="/var/lock/ceph_watchdog_recover.lock"
# Сколько main()/cleanup() ждут освобождения CEPH_WATCHDOG_LOCKFILE перед
# принудительной остановкой watchdog'а. Должно с запасом покрывать
# ограниченный "худший случай" ceph_watchdog_recover(). Сон между
# попытками перемонтирования выполняется только МЕЖДУ попытками
# (см. цикл ниже: `if (( attempt < CEPH_WATCHDOG_REMOUNT_ATTEMPTS ))`),
# т.е. не более (CEPH_WATCHDOG_REMOUNT_ATTEMPTS - 1) раз, а не
# CEPH_WATCHDOG_REMOUNT_ATTEMPTS раз:
#   CEPH_WATCHDOG_KILL_GRACE
#   + CEPH_WATCHDOG_UMOUNT_TIMEOUT
#   + CEPH_WATCHDOG_REMOUNT_ATTEMPTS * (CEPH_WATCHDOG_MOUNT_TIMEOUT
#                                        + CEPH_WATCHDOG_STAT_TIMEOUT)
#   + (CEPH_WATCHDOG_REMOUNT_ATTEMPTS - 1) * CEPH_WATCHDOG_REMOUNT_SLEEP
# При текущих значениях: 3 + 15 + 5*(15+5) + 4*5 = 138с, отсюда запас до 150с.
readonly CEPH_WATCHDOG_STOP_WAIT_TIMEOUT=150

# Учётные данные для узкого client.watchdog (только osd blocklist ls/rm) —
# отдельные от основного /etc/ceph/ceph.conf на этих хостах, который
# устарел и указывает на несуществующие mon IP.
readonly CEPH_WATCHDOG_CONF="/etc/ceph/ceph.watchdog.conf"
readonly CEPH_WATCHDOG_KEYRING="/etc/ceph/ceph.watchdog.keyring"
readonly CEPH_WATCHDOG_BLOCKLIST_TIMEOUT=10

# Хостовый бинарник ceph на arch03-05 — 15.2.7 (Octopus), на два мажорных
# релиза старше реального кластера (17.2.7 Quincy), из-за чего auth
# молча падает ([errno 13] RADOS permission denied) даже с рабочими
# учётными данными. Собственный registry кластера с актуальными Quincy
# образами недоступен из сети arch03-05, поэтому используется уже
# закэшированный на всех трёх хостах образ Pacific — на один мажорный
# релиз новее кластера недостаточно, но новее хостового бинарника
# достаточно, чтобы успешно пройти handshake.
readonly CEPH_WATCHDOG_CLI_IMAGE="registry.ceph.kiae.ru:5000/ceph/daemon:v6.0.6-stable-6.0-pacific-centos-8-x86_64"

# Возвращает 0, если /ceph реально доступен (не просто "смонтирован" —
# именно это различие важно: mountpoint -q может быть true, пока реальный
# stat/ls виснет или даёт Permission denied).
ceph_watchdog_check() {
    timeout "$CEPH_WATCHDOG_STAT_TIMEOUT" stat /ceph >/dev/null 2>&1
}

# Ищет записи Ceph OSD blocklist, совпадающие с собственными IP этого
# хоста, и снимает их. Возвращает 0, если хотя бы одна запись была
# найдена и успешно снята, 1 иначе (нечего снимать, нет совпадений,
# или сама команда rm не удалась). Любая ошибка здесь (недоступные
# мониторы, отсутствующий keyring) должна тихо приводить к 1, а не
# прерывать вызывающую функцию.
ceph_watchdog_clear_own_blocklist() {
    local own_ips
    own_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

    local blocklist_entries
    blocklist_entries=$(timeout "$CEPH_WATCHDOG_BLOCKLIST_TIMEOUT" \
        podman run --rm --entrypoint ceph -v /etc/ceph:/etc/ceph:ro "$CEPH_WATCHDOG_CLI_IMAGE" \
        -c "$CEPH_WATCHDOG_CONF" --keyring "$CEPH_WATCHDOG_KEYRING" --id watchdog \
        osd blocklist ls 2>/dev/null | awk '{print $1}')

    if [[ -z "$own_ips" || -z "$blocklist_entries" ]]; then
        return 1
    fi

    local cleared=false
    local entry ip
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            if [[ "$entry" == "$ip:"* ]]; then
                log INFO "ceph_watchdog: найдена собственная запись в blocklist:" \
                          "$entry. Снимаю блокировку."
                if timeout "$CEPH_WATCHDOG_BLOCKLIST_TIMEOUT" \
                    podman run --rm --entrypoint ceph -v /etc/ceph:/etc/ceph:ro "$CEPH_WATCHDOG_CLI_IMAGE" \
                    -c "$CEPH_WATCHDOG_CONF" --keyring "$CEPH_WATCHDOG_KEYRING" --id watchdog \
                    osd blocklist rm "$entry" >/dev/null 2>&1; then
                    cleared=true
                fi
            fi
        done <<< "$own_ips"
    done <<< "$blocklist_entries"

    if [[ "$cleared" == "true" ]]; then
        return 0
    fi
    return 1
}

# Останавливает текущие rclone-процессы и перемонтирует /ceph.
# Возвращает 0, если после перемонтирования /ceph снова доступен.
ceph_watchdog_recover() {
    # Эксклюзивная блокировка на время всего восстановления: main()/cleanup()
    # при остановке watchdog'а дожидаются её освобождения перед kill,
    # чтобы SIGTERM не прерывал mount/sleep в середине перемонтирования
    # (см. CEPH_WATCHDOG_LOCKFILE).
    local recover_lock_fd

    exec {recover_lock_fd}>"$CEPH_WATCHDOG_LOCKFILE" || {
        log ERROR "ceph_watchdog: не удалось открыть файл блокировки" \
                  "восстановления: $CEPH_WATCHDOG_LOCKFILE"
        return 1
    }
    flock -x "$recover_lock_fd"

    log ERROR "ceph_watchdog: /ceph недоступен $CEPH_WATCHDOG_FAILURE_THRESHOLD" \
              "проверки подряд (~$(( CEPH_WATCHDOG_CHECK_INTERVAL * CEPH_WATCHDOG_FAILURE_THRESHOLD ))с)." \
              "Останавливаю текущие rclone-процессы и перемонтирую /ceph."

    pkill -TERM -x rclone 2>/dev/null || true
    sleep "$CEPH_WATCHDOG_KILL_GRACE"
    pkill -KILL -x rclone 2>/dev/null || true

    timeout -k "$CEPH_WATCHDOG_TIMEOUT_KILL_GRACE" "$CEPH_WATCHDOG_UMOUNT_TIMEOUT" umount /ceph -fl 2>/dev/null || true

    local attempt
    for (( attempt = 1; attempt <= CEPH_WATCHDOG_REMOUNT_ATTEMPTS; attempt++ )); do
        log INFO "ceph_watchdog: попытка перемонтирования $attempt/$CEPH_WATCHDOG_REMOUNT_ATTEMPTS"

        if timeout -k "$CEPH_WATCHDOG_TIMEOUT_KILL_GRACE" "$CEPH_WATCHDOG_MOUNT_TIMEOUT" mount /ceph 2>>"$LOGFILE" && ceph_watchdog_check; then
            log INFO "ceph_watchdog: /ceph успешно перемонтирован и доступен"
            flock -u "$recover_lock_fd"
            exec {recover_lock_fd}>&-
            return 0
        fi

        if (( attempt < CEPH_WATCHDOG_REMOUNT_ATTEMPTS )); then
            sleep "$CEPH_WATCHDOG_REMOUNT_SLEEP"
        fi
    done

    if ceph_watchdog_clear_own_blocklist; then
        log INFO "ceph_watchdog: попытка перемонтирования после снятия blocklist"
        if timeout -k "$CEPH_WATCHDOG_TIMEOUT_KILL_GRACE" "$CEPH_WATCHDOG_MOUNT_TIMEOUT" mount /ceph 2>>"$LOGFILE" && ceph_watchdog_check; then
            log INFO "ceph_watchdog: снята собственная блокировка, /ceph перемонтирован"
            flock -u "$recover_lock_fd"
            exec {recover_lock_fd}>&-
            return 0
        fi
    fi

    log ERROR "ceph_watchdog: не удалось перемонтировать /ceph после" \
              "$CEPH_WATCHDOG_REMOUNT_ATTEMPTS попыток. Продолжаю наблюдение."
    flock -u "$recover_lock_fd"
    exec {recover_lock_fd}>&-
    return 1
}

# Основной цикл сторожа. Запускается в фоне (&) на время ЭТАП 4.
# Работает в том же bash-процессе, что и main() — не через xargs/новый
# процесс, поэтому log()/LOGFILE и другие функции уже доступны без
# export -f.
ceph_watchdog() {
    log INFO "ceph_watchdog: запущен (проверка каждые" \
              "${CEPH_WATCHDOG_CHECK_INTERVAL}с, порог срабатывания:" \
              "$CEPH_WATCHDOG_FAILURE_THRESHOLD подряд)"

    local consecutive_failures=0

    while true; do
        sleep "$CEPH_WATCHDOG_CHECK_INTERVAL"

        if ceph_watchdog_check; then
            if (( consecutive_failures > 0 )); then
                log INFO "ceph_watchdog: /ceph снова доступен (было" \
                          "$consecutive_failures неудачных проверок подряд)"
            fi
            consecutive_failures=0
            continue
        fi

        consecutive_failures=$(( consecutive_failures + 1 ))
        log WARNING "ceph_watchdog: /ceph недоступен (проверка" \
                    "$consecutive_failures/$CEPH_WATCHDOG_FAILURE_THRESHOLD)"

        if (( consecutive_failures >= CEPH_WATCHDOG_FAILURE_THRESHOLD )); then
            ceph_watchdog_recover
            consecutive_failures=0
        fi
    done
}


# ==============================================================================
# РАЗДЕЛ 11: ОЧИСТКА УСТАРЕВШИХ РЕЗЕРВНЫХ КОПИЙ
# ==============================================================================

cleanup_old_backups() {
    log INFO "Очистка устаревших данных в '$DELETE_BACKUP'" \
             "(файлы старше ${DELETE_RETENTION_DAYS} дней)"

    if [[ ! -d "$DELETE_BACKUP" ]]; then
        log WARNING "Директория '$DELETE_BACKUP' не существует — создаём"
        mkdir -p "$DELETE_BACKUP" || {
            log ERROR "Не удалось создать директорию: $DELETE_BACKUP"
            return 1
        }
    fi

    local -a delete_cmd=(
        rclone delete
        --min-age "${DELETE_RETENTION_DAYS}d"
        --use-json-log
        --log-file="${LOGDIR}/cleanup_rclone.jsonl"
        --stats=30s
        --stats-log-level=NOTICE
    )

    [[ -n "${RCLONE_CONFIG:-}" ]] && delete_cmd+=(--config="$RCLONE_CONFIG")
    [[ "$DRY_RUN" == "true" ]]    && delete_cmd+=(--dry-run)

    delete_cmd+=("$DELETE_BACKUP")

    log_command "${delete_cmd[@]}"
    if ! retry_command 3 10 "${delete_cmd[@]}"; then
        log WARNING "Удаление устаревших файлов завершилось с предупреждениями"
    fi

    local -a rmdir_cmd=(
        rclone rmdirs
        --leave-root
        --use-json-log
        --log-file="${LOGDIR}/cleanup_rclone.jsonl"
        --stats=30s
        --stats-log-level=NOTICE
    )

    [[ -n "${RCLONE_CONFIG:-}" ]] && rmdir_cmd+=(--config="$RCLONE_CONFIG")
    [[ "$DRY_RUN" == "true" ]]    && rmdir_cmd+=(--dry-run)

    rmdir_cmd+=("$DELETE_BACKUP")

    log_command "${rmdir_cmd[@]}"
    if ! retry_command 3 10 "${rmdir_cmd[@]}"; then
        log WARNING "Удаление пустых директорий завершилось с предупреждениями"
    fi

    log INFO "Очистка устаревших резервных копий завершена"
    return 0
}


# ==============================================================================
# РАЗДЕЛ 12: ОСНОВНАЯ ЛОГИКА РЕЗЕРВНОГО КОПИРОВАНИЯ
# ==============================================================================

dest_from_src() {
    local src_dir="$1"
    printf '%s\n' "${MAIN_BACKUP}/${src_dir#/}"
}

jsonlog_for_dir() {
    local src_dir="$1"
    local safe_name="${src_dir//\//_}"
    printf '%s\n' "${RCLONE_JSONLOG_DIR}/rclone${safe_name}.jsonl"
}

# Флаги rclone sync:
#   --checksum (условно)  : сравнивать файлы по MD5/SHA, а не по mtime+size.
#                          Управляется RCLONE_CHECKSUM_MODE. Надёжнее, но
#                          заметно медленнее на больших объёмах по сети —
#                          именно это, вероятно, главный вклад в цикл
#                          5-8 суток. При RCLONE_CHECKSUM_MODE=false
#                          используется быстрое сравнение по размеру+mtime.
#   --backup-dir         : файлы, исчезнувшие из источника, сохранять сюда,
#                          а не удалять насовсем.
#   --delete-excluded    : синхронизировать удаление файлов по exclude-правилам.
#   --links              : копировать символические ссылки как ссылки.
#   --create-empty-src-dirs: создавать пустые директории из источника.
#   --fast-list          : один запрос для получения списка файлов.
#   --progress           : выводить прогресс (видно в логе).
#
# НЕ ИСПОЛЬЗУЮТСЯ (сознательно, как и в 04.3.0):
#   --track-renames      : не работает корректно для local→local копирования.
#   --update             : противоречит --checksum (разная логика сравнения);
#                          на arch03/05 эта комбинация ещё встречалась —
#                          в унифицированном скрипте убрана окончательно.
backup_directory() {
    local src_dir="$1"
    local dest_dir start_time end_time duration

    if [[ -z "$src_dir" ]]; then
        log ERROR "backup_directory: не указана исходная директория"
        return 1
    fi

    dest_dir="$(dest_from_src "$src_dir")"
    local jsonlog
    jsonlog="$(jsonlog_for_dir "$src_dir")"

    log INFO "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ ==="
    log INFO "  Источник:    $src_dir"
    log INFO "  Назначение:  $dest_dir"
    log INFO "  JSON-лог:    $jsonlog"

    start_time=$(date +%s)

    if ! mkdir -p "$dest_dir"; then
        log ERROR "Не удалось создать директорию назначения: $dest_dir"
        return 1
    fi

    local -a flags=(
        --progress
        --links
        --fast-list
        --create-empty-src-dirs
        --transfers="$RCLONE_TRANSFERS"
        --checkers="$RCLONE_CHECKERS"
        --retries="$RCLONE_RETRIES"
        --retries-sleep="$RCLONE_RETRIES_SLEEP"
        --delete-excluded
        --backup-dir="${DELETE_BACKUP}/$(date +%F)"
        --use-json-log
        --log-file="$jsonlog"
        --exclude-from="$EXCLUDE_FILE"
        --log-level=INFO
        --stats=5m
        --stats-log-level=NOTICE
        --buffer-size="$RCLONE_BUFFER_SIZE"
    )

    if [[ "$RCLONE_CHECKSUM_MODE" == "true" ]]; then
        flags+=(--checksum)
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        flags+=(--dry-run)
        log INFO "РЕЖИМ DRY_RUN: реальные изменения применяться не будут"
    fi

    [[ -n "${RCLONE_CONFIG:-}" ]] && flags+=(--config="$RCLONE_CONFIG")

    local -a sync_cmd=(rclone sync "${flags[@]}" "$src_dir" "$dest_dir")

    log INFO "Команда синхронизации: $(cmd_to_string "${sync_cmd[@]}")"

    if ! retry_command 3 15 "${sync_cmd[@]}"; then
        log ERROR "Резервное копирование '$src_dir' завершилось с ошибкой"
        return 1
    fi

    end_time=$(date +%s)
    duration=$(( end_time - start_time ))

    log INFO "Резервное копирование '$src_dir' завершено успешно"
    log INFO "Время выполнения: $(printf '%d:%02d:%02d' \
             $((duration/3600)) $((duration%3600/60)) $((duration%60)))"
    log INFO "=== ЗАВЕРШЕНИЕ РЕЗЕРВНОГО КОПИРОВАНИЯ ==="

    return 0
}


# ==============================================================================
# РАЗДЕЛ 13: ПОДСЧЁТ И ФОРМАТИРОВАНИЕ СТАТИСТИКИ
# ==============================================================================

# Разбирает JSON-лог rclone и извлекает итоговую статистику.
# Возвращает 8 чисел через пробел (порядок фиксирован, читается через read -r).
#
# ИСПРАВЛЕНО (баг из 03/04/05): вызывающий код обязан использовать
# `IFS=' ' read -r ...` при разборе результата — глобальный IFS=$'\n\t'
# не разбивает по пробелу. Функция сама не выполняет такой read, поэтому
# самостоятельно от бага не страдает; страдали именно места ВЫЗОВА
# (aggregate_rclone_stats, write_summary_json, write_summary_txt) —
# там фикс и внесён.
parse_rclone_stats() {
    local jsonlog_file="$1"

    if [[ ! -f "$jsonlog_file" ]]; then
        log DEBUG "JSON-лог не найден: $jsonlog_file"
        echo "0 0 0 0 0 0 0 0"
        return 0
    fi

    local file_size
    if ! file_size=$(stat -c%s "$jsonlog_file" 2>/dev/null) || (( file_size == 0 )); then
        log DEBUG "JSON-лог пустой: $jsonlog_file"
        echo "0 0 0 0 0 0 0 0"
        return 0
    fi

    log DEBUG "Парсинг статистики: $jsonlog_file (${file_size} байт)"

    local transfers=0 checks=0 deletes=0 errors=0
    local totalBytes=0 bytes=0 elapsedTime=0 speed=0

    set +e
    set +o pipefail

    local stats_data
    if stats_data=$(jq -c 'select(.stats != null) | .stats' \
                    "$jsonlog_file" 2>/dev/null | tail -1); then
        if [[ -n "$stats_data" && "$stats_data" != "null" ]]; then
            transfers=$(  echo "$stats_data" | jq '.transfers   // 0' 2>/dev/null || echo 0)
            checks=$(     echo "$stats_data" | jq '.checks      // 0' 2>/dev/null || echo 0)
            deletes=$(    echo "$stats_data" | jq '.deletes     // 0' 2>/dev/null || echo 0)
            errors=$(     echo "$stats_data" | jq '.errors      // 0' 2>/dev/null || echo 0)
            totalBytes=$( echo "$stats_data" | jq '.totalBytes  // 0' 2>/dev/null || echo 0)
            bytes=$(      echo "$stats_data" | jq '.bytes       // 0' 2>/dev/null || echo 0)
            elapsedTime=$(echo "$stats_data" | jq '.elapsedTime // 0' 2>/dev/null || echo 0)
            speed=$(      echo "$stats_data" | jq '.speed       // 0' 2>/dev/null || echo 0)
        fi
    fi

    set -o pipefail
    set -e

    [[ "$transfers"   =~ ^[0-9]+$   ]] || transfers=0
    [[ "$checks"      =~ ^[0-9]+$   ]] || checks=0
    [[ "$deletes"     =~ ^[0-9]+$   ]] || deletes=0
    [[ "$errors"      =~ ^[0-9]+$   ]] || errors=0
    [[ "$totalBytes"  =~ ^[0-9]+$   ]] || totalBytes=0
    [[ "$bytes"       =~ ^[0-9]+$   ]] || bytes=0
    [[ "$elapsedTime" =~ ^[0-9.]+$  ]] || elapsedTime=0
    [[ "$speed"       =~ ^[0-9.]+$  ]] || speed=0

    log DEBUG "Статистика из $jsonlog_file:" \
              "transfers=$transfers checks=$checks deletes=$deletes errors=$errors"

    echo "$transfers $checks $deletes $errors $totalBytes $bytes $elapsedTime $speed"
}

# ИСПРАВЛЕНО: `IFS=' ' read -r ...` вместо обычного read -r (см. РАЗДЕЛ 13 header).
aggregate_rclone_stats() {
    local total_transfers=0 total_checks=0 total_deletes=0 total_errors=0
    local total_totalBytes=0 total_bytes=0 max_elapsed=0 avg_speed_sum=0
    local speed_count=0

    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        local jsonlog
        jsonlog="$(jsonlog_for_dir "$dir")"

        local transfers checks deletes errors totalBytes bytes elapsedTime speed
        IFS=' ' read -r transfers checks deletes errors totalBytes bytes elapsedTime speed \
             <<< "$(parse_rclone_stats "$jsonlog")" 2>/dev/null || continue

        total_transfers=$(( total_transfers + transfers ))
        total_checks=$(( total_checks + checks ))
        total_deletes=$(( total_deletes + deletes ))
        total_errors=$(( total_errors + errors ))
        total_totalBytes=$(( total_totalBytes + totalBytes ))
        total_bytes=$(( total_bytes + bytes ))

        if awk "BEGIN {exit !($elapsedTime > $max_elapsed)}"; then
            max_elapsed=$elapsedTime
        fi
        if [[ "$speed" != "0" && "$speed" != "0.0" ]]; then
            avg_speed_sum=$(awk "BEGIN {printf \"%.2f\", $avg_speed_sum + $speed}")
            (( speed_count++ )) || true
        fi
    done

    local avg_speed=0
    if (( speed_count > 0 )); then
        avg_speed=$(awk "BEGIN {printf \"%.2f\", $avg_speed_sum / $speed_count}")
    fi

    echo "$total_transfers $total_checks $total_deletes $total_errors" \
         "$total_totalBytes $total_bytes $max_elapsed $avg_speed"
}

# Подсчитывает количество файлов и суммарный размер в директории через rclone.
# ИСПРАВЛЕНО: таймаут вынесен в DIR_STATS_TIMEOUT (было жёстко 300с — на
# arch03 этого не хватало для обхода CephFS, статистика источника обнулялась
# по всем директориям в последнем прогоне перед аудитом).
calculate_directory_stats() {
    local path="$1"

    if [[ -z "$path" || ! -d "$path" ]]; then
        echo "0 0"
        return 0
    fi

    log DEBUG "Подсчёт статистики директории: $path"

    # ВАЖНО: `rclone size` НЕ принимает --files-only/--recursive (в отличие
    # от `rclone lsf`) — на rclone 1.62.2 это "unknown flag", команда падает
    # с ошибкой. Из-за этого нельзя переиспользовать один набор флагов для
    # обеих команд — нужны раздельные наборы аргументов.
    local -a lsf_args=(
        --files-only
        --recursive
        --exclude-from="$EXCLUDE_FILE"
    )
    local -a size_args=(
        --exclude-from="$EXCLUDE_FILE"
    )
    [[ -n "${RCLONE_CONFIG:-}" ]] && lsf_args+=(--config="$RCLONE_CONFIG")
    [[ -n "${RCLONE_CONFIG:-}" ]] && size_args+=(--config="$RCLONE_CONFIG")

    local file_count=0 total_size=0

    set +e
    set +o pipefail

    if file_count=$(timeout "$DIR_STATS_TIMEOUT" rclone lsf "${lsf_args[@]}" "$path" \
                    2>/dev/null | wc -l); then
        log DEBUG "Файлов в $path: $file_count"
    else
        file_count=0
    fi

    if total_size=$(timeout "$DIR_STATS_TIMEOUT" rclone size --json "${size_args[@]}" "$path" \
                    2>/dev/null | jq '.bytes // 0' 2>/dev/null); then
        [[ "$total_size" =~ ^[0-9]+$ ]] || total_size=0
    else
        total_size=0
    fi

    set -o pipefail
    set -e

    echo "$file_count $total_size"
}

format_size() {
    local size_bytes="${1:-0}"

    if [[ -z "$size_bytes" || "$size_bytes" == "0" || \
          ! "$size_bytes" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return 0
    fi

    if (( size_bytes < 1024 )); then
        echo "${size_bytes} B"
        return 0
    fi

    local -a units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit_index=0
    local size=$size_bytes

    while (( size >= 1024 && unit_index < ${#units[@]} - 1 )); do
        (( size = size / 1024 ))
        (( unit_index++ ))
    done

    local precise
    precise=$(awk "BEGIN {printf \"%.2f\", $size_bytes / (1024 ^ $unit_index)}")
    echo "${precise} ${units[$unit_index]}"
}


# ==============================================================================
# РАЗДЕЛ 14: ГЕНЕРАЦИЯ ОТЧЁТОВ
# ==============================================================================

write_summary_json() {
    local result="$1"
    local temp_json

    if ! temp_json="$(mktemp)"; then
        log ERROR "Не удалось создать временный файл для JSON-сводки"
        REPORT_GENERATION_FAILED=true
        return 1
    fi

    local transfers checks deletes errors totalBytes bytes elapsed speed
    IFS=' ' read -r transfers checks deletes errors totalBytes bytes elapsed speed \
         <<< "$(aggregate_rclone_stats)" 2>/dev/null || {
        transfers=0; checks=0; deletes=0; errors=0
        totalBytes=0; bytes=0; elapsed=0; speed=0
    }

    set +e

    {
        echo "{"
        printf '  "timestamp": "%s",\n'       "$(date -Iseconds)"
        printf '  "result": "%s",\n'           "$result"
        printf '  "script_version": "%s",\n'  "$SCRIPT_VERSION"
        printf '  "hostname": "%s",\n'         "$(hostname -f 2>/dev/null || hostname)"
        printf '  "user": "%s",\n'             "$(whoami)"
        printf '  "dry_run": %s,\n'            "$([ "$DRY_RUN" = "true" ] && echo true || echo false)"
        echo   '  "configuration": {'
        printf '    "exclude_file": "%s",\n'   "$EXCLUDE_FILE"
        printf '    "main_backup": "%s",\n'    "$MAIN_BACKUP"
        printf '    "delete_backup": "%s",\n'  "$DELETE_BACKUP"
        printf '    "checksum_mode": %s,\n'    "$([ "$RCLONE_CHECKSUM_MODE" = "true" ] && echo true || echo false)"
        echo   '    "rclone": {'
        printf '      "transfers": %s,\n'      "$RCLONE_TRANSFERS"
        printf '      "checkers": %s,\n'       "$RCLONE_CHECKERS"
        printf '      "retries": %s,\n'        "$RCLONE_RETRIES"
        printf '      "config_file": %s\n'     \
               "$( [[ -n "${RCLONE_CONFIG:-}" ]] && echo "\"$RCLONE_CONFIG\"" || echo "null" )"
        echo   '    }'
        echo   '  },'
        echo   '  "statistics": {'
        printf '    "transfers": %s,\n'                  "$transfers"
        printf '    "checks": %s,\n'                     "$checks"
        printf '    "deletes": %s,\n'                    "$deletes"
        printf '    "errors": %s,\n'                     "$errors"
        printf '    "total_bytes": %s,\n'                "$totalBytes"
        printf '    "transferred_bytes": %s,\n'          "$bytes"
        printf '    "elapsed_time_seconds": %s,\n'       "$elapsed"
        printf '    "average_speed_bytes_per_sec": %s\n' "$speed"
        echo   '  },'
        echo   '  "sources": ['

        local first=true dir dest_dir src_count src_bytes dest_count dest_bytes

        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            dest_dir="$(dest_from_src "$dir")"

            src_count=0; src_bytes=0; dest_count=0; dest_bytes=0
            IFS=' ' read -r src_count src_bytes \
                 <<< "$(calculate_directory_stats "$dir")" 2>/dev/null || true
            IFS=' ' read -r dest_count dest_bytes \
                 <<< "$(calculate_directory_stats "$dest_dir")" 2>/dev/null || true

            [[ "$first" == "true" ]] && first=false || echo "    ,"

            local src_safe="${dir//\"/\\\"}"
            local dest_safe="${dest_dir//\"/\\\"}"

            cat <<EOF
    {
      "source": "$src_safe",
      "destination": "$dest_safe",
      "source_files": $src_count,
      "source_bytes": $src_bytes,
      "source_size": "$(format_size "$src_bytes")",
      "destination_files": $dest_count,
      "destination_bytes": $dest_bytes,
      "destination_size": "$(format_size "$dest_bytes")"
    }
EOF
        done

        echo '  ]'
        echo '}'
    } > "$temp_json"

    set -e

    if mv "$temp_json" "$SUMMARY_JSON" 2>/dev/null; then
        log INFO "JSON-сводка сохранена: $SUMMARY_JSON"
        return 0
    else
        rm -f "$temp_json"
        log ERROR "Не удалось сохранить JSON-сводку в $SUMMARY_JSON"
        REPORT_GENERATION_FAILED=true
        return 1
    fi
}

write_summary_txt() {
    local result="$1"
    local temp_txt

    if ! temp_txt="$(mktemp)"; then
        log ERROR "Не удалось создать временный файл для текстовой сводки"
        REPORT_GENERATION_FAILED=true
        return 1
    fi

    local transfers checks deletes errors totalBytes bytes elapsed speed
    IFS=' ' read -r transfers checks deletes errors totalBytes bytes elapsed speed \
         <<< "$(aggregate_rclone_stats)" 2>/dev/null || {
        transfers=0; checks=0; deletes=0; errors=0
        totalBytes=0; bytes=0; elapsed=0; speed=0
    }

    set +e

    {
        local separator="==============================================================================="
        local thin_sep="-------------------------------------------------------------------------------"

        echo "$separator"
        echo "           ИТОГОВАЯ СВОДКА РЕЗЕРВНОГО КОПИРОВАНИЯ"
        echo "$separator"
        echo
        printf "Время завершения:   %s\n" "$(date)"
        printf "Результат:          %s\n" "$( [[ "$result" == "success" ]] && echo "✓ УСПЕХ" || echo "✗ ОШИБКА" )"
        printf "Версия скрипта:     %s\n" "$SCRIPT_VERSION"
        printf "Пользователь:       %s\n" "$(whoami)"
        printf "Хост:               %s\n" "$(hostname -f 2>/dev/null || hostname)"
        printf "Режим тестирования: %s\n" "$DRY_RUN"
        printf "Режим checksum:     %s\n" "$RCLONE_CHECKSUM_MODE"
        echo
        echo "$thin_sep"
        echo "КОНФИГУРАЦИЯ:"
        echo "$thin_sep"
        printf "Файл исключений:          %s\n" "$EXCLUDE_FILE"
        printf "Основная директория:      %s\n" "$MAIN_BACKUP"
        printf "Директория удалённых:     %s\n" "$DELETE_BACKUP"
        printf "Параллельные передачи:    %s\n" "$RCLONE_TRANSFERS"
        printf "Потоки проверки:          %s\n" "$RCLONE_CHECKERS"
        printf "Повторы при ошибке:       %s\n" "$RCLONE_RETRIES"
        printf "Конфигурационный файл:    %s\n" "${RCLONE_CONFIG:-<не указан>}"
        echo
        echo "$thin_sep"
        echo "СТАТИСТИКА ОПЕРАЦИЙ (агрегировано по всем директориям):"
        echo "$thin_sep"
        printf "Скопировано файлов:    %s\n" "$transfers"
        printf "Проверено файлов:      %s\n" "$checks"
        printf "Удалено файлов:        %s\n" "$deletes"
        printf "Ошибок:                %s\n" "$errors"
        printf "Всего данных:          %s (%s байт)\n" \
               "$(format_size "$totalBytes")" "$totalBytes"
        printf "Передано данных:       %s (%s байт)\n" \
               "$(format_size "$bytes")" "$bytes"

        if [[ "$elapsed" != "0" && "$elapsed" != "0.0" ]]; then
            local h m s
            h=$(awk "BEGIN {printf \"%d\", $elapsed / 3600}")
            m=$(awk "BEGIN {printf \"%d\", ($elapsed % 3600) / 60}")
            s=$(awk "BEGIN {printf \"%.2f\", $elapsed % 60}")
            printf "Время выполнения:      %d:%02d:%s\n" "$h" "$m" "$s"

            if [[ "$speed" != "0" && "$speed" != "0.0" ]]; then
                local speed_int
                speed_int=$(awk "BEGIN {printf \"%.0f\", $speed}")
                printf "Средняя скорость:      %s/сек\n" "$(format_size "$speed_int")"
            fi
        fi

        echo
        echo "$thin_sep"
        echo "СТАТИСТИКА ПО ДИРЕКТОРИЯМ:"
        echo "$thin_sep"

        local dir dest_dir src_count src_bytes dest_count dest_bytes
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            dest_dir="$(dest_from_src "$dir")"
            src_count=0; src_bytes=0; dest_count=0; dest_bytes=0

            IFS=' ' read -r src_count src_bytes \
                 <<< "$(calculate_directory_stats "$dir")" 2>/dev/null || true
            IFS=' ' read -r dest_count dest_bytes \
                 <<< "$(calculate_directory_stats "$dest_dir")" 2>/dev/null || true

            printf "\n  Источник:    %s\n" "$dir"
            printf "  Назначение:  %s\n"  "$dest_dir"
            printf "    Файлов в источнике:    %s (%s)\n" \
                   "$src_count" "$(format_size "$src_bytes")"
            printf "    Файлов в назначении:   %s (%s)\n" \
                   "$dest_count" "$(format_size "$dest_bytes")"
        done

        echo
        echo "$thin_sep"
        echo "ФАЙЛЫ ЛОГОВ:"
        echo "$thin_sep"
        printf "  Основной лог:  %s\n" "${LOGFILE:-<не определён>}"
        printf "  JSON-логи:     %s/\n" "${RCLONE_JSONLOG_DIR:-<не определён>}"
        printf "  JSON-сводка:   %s\n" "${SUMMARY_JSON:-<не определён>}"
        echo
        echo "$separator"
        echo "                        КОНЕЦ СВОДКИ"
        echo "$separator"
    } > "$temp_txt"

    set -e

    if cat "$temp_txt" | tee -a "$LOGFILE" > "$SUMMARY_TXT" 2>/dev/null; then
        rm -f "$temp_txt"
        log INFO "Текстовая сводка сохранена: $SUMMARY_TXT"
        return 0
    else
        rm -f "$temp_txt"
        log ERROR "Не удалось сохранить текстовую сводку в $SUMMARY_TXT"
        REPORT_GENERATION_FAILED=true
        return 1
    fi
}

generate_emergency_summary() {
    local summary_path="${SUMMARY_TXT:-/tmp/backup_emergency_${$}.txt}"
    local temp

    if ! temp="$(mktemp)"; then
        log ERROR "Не удалось создать временный файл для аварийного отчёта"
        return 1
    fi

    {
        echo "========================================"
        echo "  АВАРИЙНЫЙ ОТЧЁТ (детальная статистика недоступна)"
        echo "========================================"
        printf "Время:     %s\n" "$(date)"
        printf "Результат: %s\n" \
               "$( [[ "${BACKUP_SUCCESS:-false}" == "true" ]] && echo "УСПЕХ" || echo "ОШИБКА" )"
        printf "Версия:    %s\n" "$SCRIPT_VERSION"
        printf "Хост:      %s\n" "$(hostname -f 2>/dev/null || hostname)"
        echo
        echo "ПРИМЕЧАНИЕ: Детальная статистика недоступна."
        printf "Проверьте основной лог: %s\n" "${LOGFILE:-неизвестен}"
        echo "========================================"
    } > "$temp"

    cat "$temp" > "$summary_path" 2>/dev/null || true
    rm -f "$temp"
    log INFO "Аварийный отчёт сохранён: $summary_path"
}

write_summary() {
    local result="$1"

    log INFO "Генерация итоговой сводки (результат: $result)"

    local json_ok=false txt_ok=false

    if write_summary_json "$result"; then
        json_ok=true
    fi

    if write_summary_txt "$result"; then
        txt_ok=true
    fi

    if [[ "$json_ok" == "true" && "$txt_ok" == "true" ]]; then
        log INFO "Все форматы сводки сгенерированы успешно"
    elif [[ "$json_ok" == "true" || "$txt_ok" == "true" ]]; then
        log WARNING "Сводка сгенерирована частично (JSON: $json_ok, TXT: $txt_ok)"
        REPORT_GENERATION_FAILED=true
    else
        log ERROR "Генерация сводки не удалась — создаём аварийный отчёт"
        REPORT_GENERATION_FAILED=true
        generate_emergency_summary
    fi

    # Точка опоры для внешнего мониторинга "давно не запускался": mtime
    # этого файла = время последнего УСПЕШНОГО завершения бэкапа.
    # Простая проверка вида `find "$LAST_SUCCESS_MARKER" -mtime -2` снаружи
    # (cron/systemd timer/Zabbix) сразу покажет, если бэкап не запускался
    # дольше ожидаемого — именно этого не хватало все те 105-122 дня простоя.
    # DRY_RUN намеренно не обновляет метку: иначе тестовый прогон маскирует
    # реальный простой боевого бэкапа перед мониторингом.
    if [[ "$result" == "success" && "$DRY_RUN" != "true" ]]; then
        touch "$LAST_SUCCESS_MARKER" 2>/dev/null || \
            log WARNING "Не удалось обновить метку последнего успеха: $LAST_SUCCESS_MARKER"
    fi
}


# ==============================================================================
# РАЗДЕЛ 15: ОСНОВНОЙ ПОТОК ВЫПОЛНЕНИЯ
# ==============================================================================

main() {
    log INFO "========== НАЧАЛО ОСНОВНОГО ПОТОКА РЕЗЕРВНОГО КОПИРОВАНИЯ =========="

    log INFO "Системная информация:"
    log INFO "  ОС:        $(uname -s) $(uname -r) $(uname -m)"
    log INFO "  Bash:      ${BASH_VERSION}"
    log INFO "  rclone:    $(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' || echo '?')"
    log INFO "  Пользователь: $(whoami) (UID: $(id -u))"

    log INFO "Конфигурация:"
    log INFO "  Источники:        ${SOURCEDIRS_ARRAY[*]}"
    log INFO "  Основной бэкап:   $MAIN_BACKUP"
    log INFO "  Удалённые файлы:  $DELETE_BACKUP"
    log INFO "  Файл исключений:  $EXCLUDE_FILE"
    log INFO "  DRY_RUN:          $DRY_RUN"
    log INFO "  Checksum-режим:   $RCLONE_CHECKSUM_MODE"
    log INFO "  Параллельность:   $PARALLEL"

    log INFO "ЭТАП 1: Проверка доступности CephFS"
    if ! check_ceph_access; then
        log CRITICAL "CephFS недоступен — резервное копирование невозможно"
        write_summary "failure"
        return 1
    fi
    log INFO "ЭТАП 1 завершён: CephFS доступен"

    log INFO "ЭТАП 2: Очистка устаревших файлов в '$DELETE_BACKUP'"
    if ! cleanup_old_backups; then
        log WARNING "Очистка завершилась с предупреждениями — продолжаем"
    else
        log INFO "ЭТАП 2 завершён: очистка выполнена"
    fi

    log INFO "ЭТАП 3: Экспорт функций для параллельного выполнения"

    export -f log log_command retry_command cmd_to_string dest_from_src \
              jsonlog_for_dir backup_directory calculate_directory_stats \
              format_size parse_rclone_stats

    export LOGFILE RCLONE_JSONLOG_DIR EXCLUDE_FILE MAIN_BACKUP DELETE_BACKUP
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES RCLONE_RETRIES_SLEEP
    export RCLONE_BUFFER_SIZE RCLONE_USE_MMAP RCLONE_LOG_LEVEL RCLONE_CHECKSUM_MODE
    export DRY_RUN SCRIPT_VERSION DIR_STATS_TIMEOUT
    export -p RCLONE_CONFIG 2>/dev/null || true

    log INFO "ЭТАП 3 завершён"

    ceph_watchdog &
    WATCHDOG_PID=$!
    log DEBUG "ceph_watchdog запущен в фоне (PID: $WATCHDOG_PID)"

    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
    log INFO "  Директорий: ${#SOURCEDIRS_ARRAY[@]}"
    log INFO "  Параллельно: до $PARALLEL процессов"

    local backup_start backup_end backup_duration
    backup_start=$(date +%s)

    set +e

    printf '%s\0' "${SOURCEDIRS_ARRAY[@]}" \
        | xargs -0 -n1 -P"$PARALLEL" \
                bash -c 'backup_directory "$1"' _

    local xargs_exit_code=$?
    set -e

    if [[ -n "$WATCHDOG_PID" ]]; then
        log DEBUG "ceph_watchdog: ожидание завершения текущего восстановления" \
                  "перед остановкой..."
        local wd_stop_lock_fd
        if exec {wd_stop_lock_fd}>"$CEPH_WATCHDOG_LOCKFILE" 2>/dev/null; then
            if ! flock -w "$CEPH_WATCHDOG_STOP_WAIT_TIMEOUT" "$wd_stop_lock_fd"; then
                log WARNING "ceph_watchdog: не дождался завершения" \
                            "ceph_watchdog_recover за" \
                            "${CEPH_WATCHDOG_STOP_WAIT_TIMEOUT}с, останавливаю" \
                            "watchdog принудительно"
            fi
            flock -u "$wd_stop_lock_fd" 2>/dev/null || true
            exec {wd_stop_lock_fd}>&- 2>/dev/null || true
        fi

        log DEBUG "Останавливаю ceph_watchdog (PID: $WATCHDOG_PID)"
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi

    backup_end=$(date +%s)
    backup_duration=$(( backup_end - backup_start ))

    log INFO "Все процессы резервного копирования завершены"
    log INFO "Общее время: $(printf '%d:%02d:%02d' \
             $((backup_duration/3600)) $((backup_duration%3600/60)) $((backup_duration%60)))"

    if (( xargs_exit_code != 0 )); then
        log WARNING "Один или несколько процессов резервного копирования завершились с ошибкой" \
                    "(xargs код: $xargs_exit_code)"
        BACKUP_SUCCESS=false
    else
        BACKUP_SUCCESS=true
        log INFO "Все операции резервного копирования выполнены успешно"
    fi

    log INFO "ЭТАП 5: Генерация итоговой сводки"

    local final_result
    if [[ "$BACKUP_SUCCESS" == "true" ]]; then
        final_result="success"
        log INFO "ИТОГ: РЕЗЕРВНОЕ КОПИРОВАНИЕ ВЫПОЛНЕНО УСПЕШНО"
    else
        final_result="failure"
        log WARNING "ИТОГ: РЕЗЕРВНОЕ КОПИРОВАНИЕ ЗАВЕРШИЛОСЬ С ОШИБКАМИ"
    fi

    set +e
    write_summary "$final_result"
    set -e

    log INFO "========== ЗАВЕРШЕНИЕ ОСНОВНОГО ПОТОКА =========="

    [[ "$BACKUP_SUCCESS" == "true" ]] && return 0 || return 1
}


# ==============================================================================
# РАЗДЕЛ 16: ТОЧКА ВХОДА
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit_code=$?

    if (( exit_code == 0 )); then
        if [[ "$REPORT_GENERATION_FAILED" == "false" ]]; then
            log INFO "=== СКРИПТ ЗАВЕРШЁН УСПЕШНО ==="
        else
            log WARNING "=== СКРИПТ ЗАВЕРШЁН С ПРЕДУПРЕЖДЕНИЯМИ" \
                        "(бэкап OK, проблемы с отчётами) ==="
        fi
    else
        log ERROR "=== СКРИПТ ЗАВЕРШЁН С ОШИБКОЙ (код: $exit_code) ==="
    fi

    exit "$exit_code"
else
    log INFO "Скрипт загружен через source — функции доступны для использования"
fi

# ==============================================================================
# КОНЕЦ СКРИПТА
# ==============================================================================
