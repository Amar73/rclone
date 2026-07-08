#!/usr/bin/env bash
# ==============================================================================
# rclone_backup.sh — Скрипт резервного копирования CephFS → локальная ФС
# ==============================================================================
#
# НАЗНАЧЕНИЕ:
#   Скрипт копирует данные из смонтированной CephFS в локальную директорию
#   с помощью утилиты rclone. Поддерживает параллельное копирование нескольких
#   директорий, ведение подробных логов, хранение удалённых файлов и очистку
#   устаревших резервных копий.
#
# АРХИТЕКТУРА ХРАНЕНИЯ:
#   /backup/main/      — актуальные резервные копии (зеркало CephFS)
#   /backup/deleted/   — файлы, удалённые из источника (хранятся 30 дней)
#   /var/log/backup/   — логи (текст + JSON от rclone)
#
# КАК РАБОТАЕТ РЕЗЕРВНОЕ КОПИРОВАНИЕ:
#   1. Проверяется монтирование CephFS и доступность источников.
#   2. Из /backup/deleted/ удаляются файлы старше DELETE_RETENTION_DAYS дней.
#   3. Для каждой исходной директории запускается "rclone sync":
#      - файлы, которые исчезли из источника, перемещаются в /backup/deleted/ДАТА/
#        а не удаляются бесследно (флаг --backup-dir)
#      - файлы сравниваются по контрольной сумме (флаг --checksum)
#   4. Параллельно запускается до PARALLEL процессов (по одному на директорию).
#   5. По завершении генерируется сводный отчёт в текстовом и JSON-форматах.
#
# УПРАВЛЕНИЕ ЧЕРЕЗ ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
#   Все параметры можно переопределить без редактирования скрипта:
#
#   SOURCEDIRS            — список директорий источника через пробел
#                           по умолчанию: /ceph/data/exp/idream/
#   MAIN_BACKUP           — куда копировать (по умолч.: /backup/main)
#   DELETE_BACKUP         — куда складывать удалённые файлы (/backup/deleted)
#   LOGDIR                — директория логов (/var/log/backup)
#   LOCKFILE              — файл блокировки (/var/lock/backup.lock)
#   EXCLUDE_FILE          — файл правил исключения (/usr/local/bin/scripts/exclude-file.txt)
#   RCLONE_TRANSFERS      — число параллельных передач rclone (30)
#   RCLONE_CHECKERS       — число потоков проверки rclone (8)
#   RCLONE_RETRIES        — число повторов при ошибке (5)
#   RCLONE_RETRIES_SLEEP  — пауза между повторами (10s)
#   RCLONE_BUFFER_SIZE    — буфер памяти на файл (16M)
#   PARALLEL              — макс. число параллельных директорий (4)
#   DRY_RUN               — тестовый режим без изменений (false)
#   MAX_LOGFILES          — максимум лог-файлов в LOGDIR (100)
#   LOG_RETENTION_DAYS    — хранить логи N дней (30)
#   DELETE_RETENTION_DAYS — хранить удалённые файлы N дней (30)
#   CEPH_MON_HOST         — хост для проверки статуса Ceph (cephrgw01)
#   CEPH_MON_CONTAINER    — имя podman-контейнера ceph-mon (ceph-mon-cephrgw01)
#
# ПРИМЕРЫ ЗАПУСКА:
#   # Обычный запуск
#   sudo ./rclone_backup.sh
#
#   # Тестовый прогон без реального копирования
#   DRY_RUN=true ./rclone_backup.sh
#
#   # Копировать другие директории
#   SOURCEDIRS="/ceph/data/proj1/ /ceph/data/proj2/" ./rclone_backup.sh
#
# ТРЕБОВАНИЯ:
#   - bash 4.0+
#   - rclone 1.60+
#   - CentOS 7 / RHEL 7 и новее
#   - jq (опционально, улучшает парсинг статистики)
#   - SSH-доступ к хосту Ceph MON (опционально, для проверки статуса кластера)
#
# ВОЗВРАЩАЕМЫЕ КОДЫ:
#   0  — резервное копирование выполнено успешно
#   1  — ошибка конфигурации, монтирования или копирования
#   130 — прерван сигналом SIGINT (Ctrl+C)
#   143 — прерван сигналом SIGTERM
#   129 — прерван сигналом SIGHUP
#
# АВТОР: Ведущий инженер Андрей Марьяненко
# ВЕРСИЯ: 2.7.0 (Март 2026)
# ==============================================================================


# ==============================================================================
# РАЗДЕЛ 1: ИНИЦИАЛИЗАЦИЯ ОБОЛОЧКИ И ПРОВЕРКА СОВМЕСТИМОСТИ
# ==============================================================================

# Проверяем версию bash ДО включения строгого режима, потому что синтаксис
# (( )) для арифметики не работает в bash 3.x так же, как в 4.x
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ОШИБКА: Требуется bash версии 4.0 или новее." \
         "Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

# -e  : немедленный выход при ошибке любой команды
# -E  : ловушка ERR наследуется функциями и подоболочками
# -u  : ошибка при обращении к неустановленной переменной
# -o pipefail : код возврата конвейера = код последней упавшей команды
set -eEuo pipefail

# Разделители полей: только перевод строки и табуляция.
# Пробел исключён намеренно, чтобы пути с пробелами не разбивались на части.
IFS=$'\n\t'

# Запрещаем создавать файлы с правами group-write и world-read/write.
# Результат: новые файлы получат права 0640, директории — 0750.
umask 027

# Принудительная локаль C: нейтральная сортировка, ASCII-вывод утилит.
# Это гарантирует предсказуемый парсинг вывода grep/awk/date в любой системе.
export LANG=C LC_ALL=C

# Неизменяемые константы скрипта
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.7.0"
readonly REQUIRED_RCLONE_VERSION="1.60"


# ==============================================================================
# РАЗДЕЛ 2: КОНФИГУРАЦИЯ — ПАРАМЕТРЫ С УМОЛЧАНИЯМИ
# ==============================================================================
# Синтаксис ${VAR:-default} означает: использовать $VAR если задана, иначе default.
# Это позволяет переопределять любой параметр через переменную окружения.

readonly BACKUP_USER="${BACKUP_USER:-backup_user}"
readonly LOGDIR="${LOGDIR:-/var/log/backup}"
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
readonly EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"
readonly DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
readonly MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"

# Параметры подключения к Ceph MON для проверки состояния кластера.
# Вынесены в переменные, чтобы не редактировать код при смене инфраструктуры.
readonly CEPH_MON_HOST="${CEPH_MON_HOST:-cephrgw01}"
readonly CEPH_MON_CONTAINER="${CEPH_MON_CONTAINER:-ceph-mon-cephrgw01}"

# Параметры rclone
readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"    # параллельных передач
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"       # потоков проверки
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"         # повторов при ошибке
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}"  # пауза между повторами
readonly RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-16M}"      # буфер на файл

# Параметры выполнения
readonly PARALLEL="${PARALLEL:-4}"                         # макс. параллельных процессов
readonly DRY_RUN="${DRY_RUN:-false}"                       # тестовый режим
readonly MAX_LOGFILES="${MAX_LOGFILES:-100}"               # лимит файлов логов
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"   # срок хранения логов
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}"  # срок хранения удалённых

# Формируем массив исходных директорий.
# Если SOURCEDIRS задана через окружение — разбиваем по пробелу.
# Иначе используем список по умолчанию.
if [[ -n "${SOURCEDIRS:-}" ]]; then
    # Временно разрешаем пробел как разделитель только для этого read
    IFS=' ' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS"
else
    readonly -a SOURCEDIRS_ARRAY=('/ceph/data/exp/idream/')
fi

# Глобальные флаги состояния выполнения.
# Изменяются только в главном процессе (не в дочерних через xargs).
BACKUP_SUCCESS=true          # итоговый статус (определяется по xargs_exit_code)
REPORT_GENERATION_FAILED=false  # флаг проблем с генерацией отчётов


# ==============================================================================
# РАЗДЕЛ 3: РАННИЕ ПРОВЕРКИ КОНФИГУРАЦИИ
# ==============================================================================
# Эти проверки выполняются до создания файлов и логов, чтобы быстро упасть
# при очевидно неверной конфигурации.

# Проверяет, что все исходные директории находятся внутри /ceph
# и не содержат потенциально опасных символов.
validate_source_directories() {
    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do

        # Все источники должны быть внутри точки монтирования /ceph.
        # Это предотвращает случайное копирование с других ФС.
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            echo "ОШИБКА: Источник '$dir' не находится внутри /ceph." \
                 "Все источники должны начинаться с /ceph/" >&2
            exit 1
        fi

        # Проверяем пути на наличие символов, опасных при подстановке в shell.
        # Разрешены только: буквы, цифры, /, _, -, .
        # Запрещены: пробел, ;, $(), ``, &&, |, >, <, \n и прочее.
        if [[ ! "$dir" =~ ^[a-zA-Z0-9/_.\-]+/?$ ]]; then
            echo "ОШИБКА: Путь '$dir' содержит недопустимые символы." \
                 "Допустимы только: a-z A-Z 0-9 / _ - ." >&2
            exit 1
        fi
    done
}

# Проверяет наличие всех внешних утилит, которые использует скрипт.
check_required_commands() {
    local cmd
    local missing_commands=()
    local required_commands=(
        "rclone"     # основная утилита копирования
        "mount"      # монтирование CephFS
        "mountpoint" # проверка точки монтирования
        "find"       # поиск старых логов
        "awk"        # форматирование чисел
        "date"       # временны́е метки
        "mkdir"      # создание директорий
        "flock"      # файловая блокировка
        "timeout"    # ограничение времени SSH-команды
        "ssh"        # проверка статуса Ceph (опционально, но проверяем заранее)
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

# Проверяет версию rclone. Выдаёт предупреждение (не ошибку), если версия
# старше рекомендованной — скрипт продолжит работу, но некоторые флаги
# могут не поддерживаться.
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

# Запускаем ранние проверки немедленно при загрузке скрипта
validate_source_directories
check_required_commands
check_rclone_version


# ==============================================================================
# РАЗДЕЛ 4: СИСТЕМА ЛОГИРОВАНИЯ
# ==============================================================================

# Универсальная функция логирования.
#
# Использование: log УРОВЕНЬ "сообщение"
# Уровни: DEBUG INFO WARNING ERROR CRITICAL
#
# Поведение:
# - Всегда пишет в stderr (для совместимости с cron и systemd)
# - Если LOGFILE определён и директория доступна для записи — дублирует в файл
# - Если stderr — терминал (интерактивный запуск) — раскрашивает вывод
log() {
    local level="${1:-INFO}"
    shift || true
    local message="${*:-}"
    local timestamp
    timestamp="$(date -Iseconds)"

    # Цветовой код для интерактивного терминала.
    # Проверяем именно stderr (fd 2), т.к. туда пишем.
    local color_code=""
    if [[ -t 2 ]]; then
        case "$level" in
            DEBUG)    color_code="\033[36m"    ;;  # голубой
            INFO)     color_code="\033[32m"    ;;  # зелёный
            WARNING)  color_code="\033[33m"    ;;  # жёлтый
            ERROR)    color_code="\033[31m"    ;;  # красный
            CRITICAL) color_code="\033[35;1m"  ;;  # ярко-фиолетовый
        esac
    fi

    local log_message="${timestamp} [${level}] ${message}"

    if [[ -n "$color_code" ]]; then
        echo -e "${color_code}${log_message}\033[0m" >&2
    else
        echo "$log_message" >&2
    fi

    # Пишем в файл только если LOGFILE задан и директория лога существует.
    # Проверяем директорию (а не сам файл), потому что файл создаётся позже.
    if [[ -n "${LOGFILE:-}" && -w "${LOGFILE%/*}" ]]; then
        echo "$log_message" >> "$LOGFILE"
    fi
}

# Вспомогательная функция: логирует команду перед её выполнением (уровень DEBUG).
# Используется для отладки — можно убрать в продакшене, установив RCLONE_LOG_LEVEL=INFO.
log_command() {
    local -a cmd=("$@")
    log DEBUG "Выполнение команды: $(printf '%q ' "${cmd[@]}")"
}


# ==============================================================================
# РАЗДЕЛ 5: ИНИЦИАЛИЗАЦИЯ ФАЙЛОВОЙ СИСТЕМЫ И ЛОГОВ
# ==============================================================================

# Создаёт необходимые директории, если они не существуют,
# и проверяет права на запись.
create_directories() {
    local dir
    for dir in "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || {
                # Используем echo, а не log, т.к. LOGFILE ещё не инициализирован
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

# Создаёт именованные лог-файлы для текущего сеанса и выводит стартовую информацию.
# Имена файлов включают временну́ю метку для уникальности и удобства поиска.
initialize_logging() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"

    # Четыре типа файлов для каждого сеанса:
    # .log           — человекочитаемый лог всего скрипта
    # .jsonl         — JSON-лог rclone (один JSON-объект на строку, формат jsonlines)
    # .summary.json  — итоговая сводка в машиночитаемом формате
    # .summary.txt   — итоговая сводка в человекочитаемом формате
    readonly LOGFILE="${LOGDIR}/backup_${timestamp}.log"
    readonly RCLONE_JSONLOG_DIR="${LOGDIR}/jsonlogs_${timestamp}"
    readonly SUMMARY_JSON="${LOGDIR}/backup_${timestamp}.summary.json"
    readonly SUMMARY_TXT="${LOGDIR}/backup_${timestamp}.summary.txt"

    # Создаём директорию для JSON-логов rclone (по одному файлу на директорию)
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
    log INFO "Версия bash: ${BASH_VERSION}"
    log INFO "Версия rclone: $(rclone --version 2>/dev/null | head -n1 \
              | awk '{print $2}' || echo 'неопределена')"
}

# Удаляет старые лог-файлы по возрасту и проверяет количество файлов.
# Обрабатывает все типы лог-файлов: .log, .jsonl, .summary.*
rotate_logs() {
    log INFO "Начало ротации логов в '$LOGDIR' (хранить ${LOG_RETENTION_DAYS} дней)"

    local deleted_count=0
    local pattern

    # Перебираем все паттерны лог-файлов, которые генерирует скрипт
    for pattern in 'backup_*.log' 'backup_*.summary.json' 'backup_*.summary.txt'; do
        local count
        count=$(find "$LOGDIR" -maxdepth 1 -type f -name "$pattern" \
                    -mtime "+${LOG_RETENTION_DAYS}" -delete -print 2>/dev/null | wc -l)
        deleted_count=$(( deleted_count + count ))
    done

    # Директории JSON-логов rclone (формат: jsonlogs_TIMESTAMP/)
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

    # Предупреждаем, если файлов становится слишком много, но не удаляем принудительно —
    # оператор должен сам принять решение о том, что удалить.
    local current_count
    current_count=$(find "$LOGDIR" -maxdepth 1 -type f -name 'backup_*.log' \
                        2>/dev/null | wc -l)
    if (( current_count > MAX_LOGFILES )); then
        log WARNING "Количество лог-файлов ($current_count) превышает лимит ($MAX_LOGFILES)." \
                    "Рекомендуется уменьшить LOG_RETENTION_DAYS или увеличить MAX_LOGFILES."
    fi

    log INFO "Ротация логов завершена"
}

# Выполняем инициализацию файловой системы сразу после определения функций
create_directories
initialize_logging
rotate_logs


# ==============================================================================
# РАЗДЕЛ 6: БЛОКИРОВКА И ОБРАБОТКА СИГНАЛОВ
# ==============================================================================
# Блокировка предотвращает одновременный запуск двух экземпляров скрипта,
# что могло бы привести к гонке данных в /backup/main/ и /backup/deleted/.

# Дескриптор открытого файла блокировки. Инициализируется ниже.
LOCK_FD=""

# Функция очистки — вызывается автоматически при любом завершении скрипта
# (нормальном, по ошибке, по сигналу) через trap EXIT.
cleanup() {
    # Сохраняем код возврата ДО выполнения любых команд в этой функции,
    # иначе $? будет перезаписан следующей командой.
    local exit_code=$?

    log INFO "Начало процедуры очистки ресурсов..."

    # Снимаем flock-блокировку и закрываем файловый дескриптор.
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true

        # Синтаксис "exec {FD}<&-" для закрытия произвольного дескриптора
        # появился в bash 4.1. В bash 4.0 используем eval как обходной путь.
        if (( BASH_VERSINFO[0] > 4 ||
              (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )); then
            eval "exec {LOCK_FD}<&-" 2>/dev/null || true
        fi
        log DEBUG "Блокировка снята (дескриптор: $LOCK_FD)"
    fi

    # Удаляем файл блокировки. Если не удалить — следующий запуск не сможет
    # получить блокировку через flock -n (хотя flock проверяет процесс, а не файл,
    # чистка файла — это хорошая практика).
    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE" || true
        log DEBUG "Файл блокировки удалён: $LOCKFILE"
    fi

    # Финальный статус
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

    # Явно выходим с сохранённым кодом.
    # Без этого exit_code мог бы быть перезаписан последней командой в функции.
    exit "$exit_code"
}

# Обработчик сигналов прерывания.
# Принимает имя сигнала и возвращает стандартный код: 128 + номер сигнала.
signal_handler() {
    local signal="$1"
    local exit_code

    # Стандартные коды: SIGHUP=1 → 129, SIGINT=2 → 130, SIGTERM=15 → 143
    case "$signal" in
        HUP)  exit_code=129 ;;
        INT)  exit_code=130 ;;
        TERM) exit_code=143 ;;
        *)    exit_code=1   ;;
    esac

    log WARNING "Получен сигнал $signal — начинаем корректное завершение работы"
    BACKUP_SUCCESS=false

    # Вызываем exit — это автоматически активирует trap EXIT → cleanup()
    exit "$exit_code"
}

# Регистрируем ловушки на сигналы и выход
trap cleanup EXIT
trap 'signal_handler INT'  INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP'  HUP

# Открываем файловый дескриптор на файл блокировки.
# bash 4.1+: {LOCK_FD}> — автоматически выбирает свободный дескриптор.
# bash 4.0:  используем фиксированный дескриптор 200 (вне стандартного диапазона).
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

# Пытаемся получить эксклюзивную блокировку без ожидания (-n).
# Если другой экземпляр уже держит блокировку — flock вернёт код != 0.
if ! flock -n "$LOCK_FD"; then
    log ERROR "Другой экземпляр скрипта уже выполняется." \
              "Файл блокировки: $LOCKFILE"
    exit 1
fi

log INFO "Блокировка получена (дескриптор: $LOCK_FD)"


# ==============================================================================
# РАЗДЕЛ 7: КОНФИГУРАЦИЯ RCLONE
# ==============================================================================

# Определяет путь к конфигурационному файлу rclone и экспортирует
# все переменные, которые rclone читает из окружения.
initialize_rclone_config() {
    log INFO "Инициализация конфигурации rclone"

    # rclone config file выводит путь к своему конфигу.
    # Если файл существует — передаём его явно через --config,
    # чтобы избежать проблем с правами при запуске от разных пользователей.
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

    # Экспортируем переменные, которые rclone читает напрямую из окружения.
    # Это позволяет не передавать каждый параметр через флаг командной строки.
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES
    export RCLONE_BUFFER_SIZE
    export RCLONE_USE_MMAP="${RCLONE_USE_MMAP:-true}"   # использовать mmap для буферизации
    export RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"  # уровень логирования rclone

    log INFO "Конфигурация rclone:"
    log DEBUG "  RCLONE_TRANSFERS=$RCLONE_TRANSFERS"
    log DEBUG "  RCLONE_CHECKERS=$RCLONE_CHECKERS"
    log DEBUG "  RCLONE_RETRIES=$RCLONE_RETRIES"
    log DEBUG "  RCLONE_BUFFER_SIZE=$RCLONE_BUFFER_SIZE"
}

initialize_rclone_config


# ==============================================================================
# РАЗДЕЛ 8: ПРОВЕРКА ФАЙЛА ИСКЛЮЧЕНИЙ
# ==============================================================================

# Проверяет существование, читаемость и безопасность файла правил исключения.
# Файл исключений содержит паттерны rclone для игнорирования файлов/папок.
validate_exclude_file() {
    log INFO "Проверка файла исключений: $EXCLUDE_FILE"

    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        log ERROR "Файл исключений не найден: $EXCLUDE_FILE." \
                  "Создайте файл или измените переменную EXCLUDE_FILE."
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

    # Сканируем файл на наличие опасных паттернов shell-подстановки.
    # Злоумышленник мог бы добавить в файл строку вида: $(rm -rf /)
    # и при определённом использовании файла получить выполнение кода.
    local line_number=0
    local -a invalid_lines=()
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_number++ )) || true

        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Ищем символы, опасные при подстановке в shell
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

# Преобразует массив аргументов команды в безопасную строку для логирования.
# Использует printf '%q' для экранирования спецсимволов.
cmd_to_string() {
    local -a cmd_array=("$@")
    local result=""
    local arg

    for arg in "${cmd_array[@]}"; do
        printf -v result "%s%s " "$result" "$(printf '%q' "$arg")"
    done

    printf '%s\n' "${result% }"  # убираем пробел в конце
}

# Выполняет команду с автоматическим повтором при ошибке.
#
# Использование: retry_command ПОВТОРОВ ПАУЗА_СЕК КОМАНДА [АРГУМЕНТЫ...]
#
# ВАЖНО о передаче exit code:
#   Вывод команды перенаправляется через pipe в while-read для логирования.
#   При использовании pipe в bash код возврата команды слева доступен через
#   PIPESTATUS[0] сразу после завершения pipe-конструкции.
#   Мы сохраняем его в переменную exit_code до любых других команд.
#
#   Альтернативный подход (более надёжный для сложных случаев) — писать
#   вывод во временный файл и читать его отдельно. Здесь используем PIPESTATUS,
#   т.к. структура конвейера простая и предсказуемая.
retry_command() {
    local retries="$1"
    local delay_sec="$2"
    shift 2
    local -a cmd=("$@")
    local attempt exit_code

    for (( attempt = 1; attempt <= retries; attempt++ )); do
        log INFO "Попытка $attempt/$retries: $(cmd_to_string "${cmd[@]}")"

        # Временно отключаем set -e, чтобы команда могла вернуть ненулевой код
        # и мы могли его обработать вместо немедленного выхода.
        set +e

        # Запускаем команду и пропускаем её вывод через фильтр логирования.
        # PIPESTATUS[0] = код возврата команды (левая часть pipe).
        # PIPESTATUS[1] = код возврата while-read (обычно 0).
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            # Классифицируем строки вывода rclone по уровню серьёзности
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

        # ВНИМАНИЕ: PIPESTATUS должен читаться сразу после pipe-конструкции,
        # до любой другой команды — иначе значение будет потеряно.
        exit_code="${PIPESTATUS[0]}"
        set -e

        case "$exit_code" in
            0)
                log INFO "Команда выполнена успешно (попытка $attempt)"
                return 0
                ;;
            1)
                # rclone возвращает 1 при отсутствии файлов для rmdirs/delete.
                # Это не ошибка — просто нечего делать.
                if [[ "${cmd[1]:-}" == "rmdirs" || "${cmd[1]:-}" == "delete" ]]; then
                    log INFO "Команда '${cmd[1]}' завершена: нет файлов для обработки"
                    return 0
                fi
                ;;
            3)
                # rclone возвращает 3 когда нет изменений для sync/copy.
                # Это нормальная ситуация при актуальном бэкапе.
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

# Пытается получить статус Ceph-кластера через SSH к MON-ноде.
# Функция не критична — ошибка SSH не останавливает резервное копирование.
# Используется только для раннего предупреждения об аномалиях кластера.
check_ceph_cluster_status() {
    log DEBUG "Проверка состояния Ceph-кластера через ${CEPH_MON_HOST}"

    if ! command -v ssh >/dev/null 2>&1; then
        log DEBUG "SSH недоступен — пропускаем проверку состояния кластера"
        return 0
    fi

    local ceph_status
    # timeout 10: если SSH не ответит за 10 секунд — прерываем.
    # -o ConnectTimeout=5: SSH-таймаут на установку соединения.
    # -o BatchMode=yes: отключаем интерактивные запросы пароля/ключа.
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
        # SSH не удался — это не критично, CephFS может быть смонтирован
        # и работать корректно без доступа к MON через SSH.
        log DEBUG "Не удалось получить статус Ceph-кластера через SSH к ${CEPH_MON_HOST}." \
                  "Это не критично — продолжаем."
    fi
}

# Проверяет монтирование CephFS и доступность исходных директорий.
# При необходимости пытается смонтировать /ceph.
check_ceph_access() {
    log INFO "Проверка доступности CephFS"

    # Проверяем, что /ceph вообще прописан в /etc/fstab.
    # Без этой записи mount /ceph не знает, как монтировать.
    if ! awk '$1 !~ /^#/ && $2 == "/ceph" {found=1} END {exit !found}' \
         /etc/fstab 2>/dev/null; then
        log ERROR "CephFS не настроен в /etc/fstab (нет записи для точки монтирования /ceph)." \
                  "Добавьте запись в /etc/fstab и повторите запуск."
        return 1
    fi

    # Проверяем, смонтирован ли /ceph прямо сейчас.
    if ! mountpoint -q /ceph 2>/dev/null; then
        log WARNING "/ceph не смонтирован — пытаемся смонтировать..."

        # Монтирование требует прав root.
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

        # Итоговая проверка после всех попыток
        if ! mountpoint -q /ceph 2>/dev/null; then
            log ERROR "Не удалось смонтировать CephFS после 5 попыток." \
                      "Проверьте доступность Ceph-кластера и настройки /etc/fstab."
            return 1
        fi
    else
        log DEBUG "/ceph уже смонтирован"
    fi

    # Проверяем базовую читаемость точки монтирования.
    # Команда ls может подвисать если Ceph недоступен — используем timeout.
    if ! timeout 10 ls /ceph >/dev/null 2>&1; then
        log ERROR "Нет доступа к /ceph для чтения (возможно, кластер недоступен)."
        return 1
    fi

    # Проверяем существование каждой исходной директории
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

    # Запрашиваем статус кластера (некритично — не прерываем при ошибке)
    check_ceph_cluster_status

    log INFO "CephFS доступен. Все исходные директории найдены."
    return 0
}


# ==============================================================================
# РАЗДЕЛ 11: ОЧИСТКА УСТАРЕВШИХ РЕЗЕРВНЫХ КОПИЙ
# ==============================================================================

# Удаляет из /backup/deleted/ файлы старше DELETE_RETENTION_DAYS дней
# и убирает образовавшиеся пустые директории.
#
# Схема хранения удалённых файлов:
#   /backup/deleted/
#     2026-03-01/    <- файлы, удалённые из источника 1 марта
#       path/to/file.dat
#     2026-03-15/    <- файлы, удалённые 15 марта
#       ...
#
# rclone delete удаляет файлы старше N дней по mtime.
# rclone rmdirs убирает опустевшие директории (--leave-root сохраняет корень).
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

    # Команда удаления файлов по возрасту
    local -a delete_cmd=(
        rclone delete
        --min-age "${DELETE_RETENTION_DAYS}d"  # удалять только старше N дней
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

    # Команда удаления пустых директорий
    local -a rmdir_cmd=(
        rclone rmdirs
        --leave-root  # не удалять корневую директорию $DELETE_BACKUP
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

# Вычисляет путь назначения по пути источника.
# Источник:    /ceph/data/exp/idream/
# Назначение:  /backup/main/ceph/data/exp/idream/
#
# Логика: убираем ведущий / у пути источника и добавляем его к MAIN_BACKUP.
# Это сохраняет полную структуру директорий и позволяет легко определить,
# откуда взялся тот или иной файл в бэкапе.
dest_from_src() {
    local src_dir="$1"
    # ${src_dir#/} — удаляем ведущий слеш (prefix stripping)
    printf '%s\n' "${MAIN_BACKUP}/${src_dir#/}"
}

# Возвращает путь к JSON-логу rclone для конкретной директории.
# Каждая директория получает отдельный лог, чтобы избежать перемешивания
# записей при параллельном выполнении и корректно агрегировать статистику.
jsonlog_for_dir() {
    local src_dir="$1"
    # Преобразуем путь в безопасное имя файла: /ceph/data/exp/ → _ceph_data_exp_
    local safe_name="${src_dir//\//_}"
    printf '%s\n' "${RCLONE_JSONLOG_DIR}/rclone${safe_name}.jsonl"
}

# Выполняет резервное копирование одной директории.
# Эта функция вызывается в дочернем процессе через xargs (параллельно).
# Все изменения переменных внутри неё НЕ видны родительскому процессу.
#
# Флаги rclone sync:
#   --checksum           : сравнивать файлы по MD5/SHA, а не по mtime+size.
#                          Надёжнее для CephFS, где mtime может расходиться.
#   --backup-dir         : файлы, исчезнувшие из источника, сохранять сюда,
#                          а не удалять насовсем. Защита от случайного удаления.
#   --delete-excluded    : файлы, соответствующие правилам исключения,
#                          удалять из назначения (поддерживаем синхронизацию).
#   --links              : копировать символические ссылки как ссылки.
#   --create-empty-src-dirs: создавать пустые директории из источника.
#   --fast-list          : использовать один запрос для получения списка файлов
#                          (экономит API-запросы, актуально для S3; для local
#                          снижает число системных вызовов).
#   --progress           : выводить прогресс (видно в логе).
#
# УБРАНЫ по сравнению с предыдущей версией:
#   --track-renames      : не работает корректно для local→local копирования.
#   --update             : противоречит --checksum (разная логика сравнения).
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

    # Создаём директорию назначения если не существует
    if ! mkdir -p "$dest_dir"; then
        log ERROR "Не удалось создать директорию назначения: $dest_dir"
        return 1
    fi

    # Формируем массив флагов rclone sync
    local -a flags=(
        --progress
        --links                                      # сохранять симлинки
        --fast-list                                  # одним запросом получить список
        --create-empty-src-dirs                      # копировать пустые директории
        --checksum                                   # сравнение по хешу (без --update!)
        --transfers="$RCLONE_TRANSFERS"
        --checkers="$RCLONE_CHECKERS"
        --retries="$RCLONE_RETRIES"
        --retries-sleep="$RCLONE_RETRIES_SLEEP"
        --delete-excluded                            # удалять из dst файлы по exclude-правилам
        --backup-dir="${DELETE_BACKUP}/$(date +%F)"  # удалённые → backup-dir с датой
        --use-json-log
        --log-file="$jsonlog"                        # индивидуальный лог для этой директории
        --exclude-from="$EXCLUDE_FILE"
        --log-level=INFO
        --stats=5m
        --stats-log-level=NOTICE
        --buffer-size="$RCLONE_BUFFER_SIZE"
    )

    # В тестовом режиме ни один файл не будет изменён
    if [[ "$DRY_RUN" == "true" ]]; then
        flags+=(--dry-run)
        log INFO "РЕЖИМ DRY_RUN: реальные изменения применяться не будут"
    fi

    # Добавляем конфиг если он определён
    [[ -n "${RCLONE_CONFIG:-}" ]] && flags+=(--config="$RCLONE_CONFIG")

    local -a sync_cmd=(rclone sync "${flags[@]}" "$src_dir" "$dest_dir")

    log INFO "Команда синхронизации: $(cmd_to_string "${sync_cmd[@]}")"

    if ! retry_command 3 15 "${sync_cmd[@]}"; then
        log ERROR "Резервное копирование '$src_dir' завершилось с ошибкой"
        return 1  # код возврата прочитает xargs в родительском процессе
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

# Парсит JSON-лог rclone и извлекает итоговую статистику.
# Выводит 8 чисел через пробел (для чтения через read -r).
#
# Порядок: transfers checks deletes errors totalBytes bytes elapsedTime speed
#
# ВАЖНО: при параллельном выполнении у каждой директории свой лог.
# Эта функция вызывается для каждого лога отдельно, затем значения суммируются.
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

    set +e  # не выходить при ошибке парсинга — вернём нули

    if command -v jq >/dev/null 2>&1; then
        # jq: надёжный и быстрый способ работы с JSON.
        # Берём последнюю запись статистики (tail -1) — это финальные данные.
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
    else
        # Резервный метод без jq: grep + cut.
        # Менее надёжен (не обрабатывает JSON с переносами строк),
        # но достаточен для формата jsonlines, который генерирует rclone.
        log DEBUG "jq не установлен — используется резервный метод парсинга (grep/cut)"

        local stats_line
        if stats_line=$(grep '"stats":' "$jsonlog_file" 2>/dev/null | tail -1); then
            transfers=$(  echo "$stats_line" | grep -o '"transfers":[0-9]*'   | cut -d: -f2 | head -1 || echo 0)
            checks=$(     echo "$stats_line" | grep -o '"checks":[0-9]*'      | cut -d: -f2 | head -1 || echo 0)
            deletes=$(    echo "$stats_line" | grep -o '"deletes":[0-9]*'     | cut -d: -f2 | head -1 || echo 0)
            errors=$(     echo "$stats_line" | grep -o '"errors":[0-9]*'      | cut -d: -f2 | head -1 || echo 0)
            totalBytes=$( echo "$stats_line" | grep -o '"totalBytes":[0-9]*'  | cut -d: -f2 | head -1 || echo 0)
            bytes=$(      echo "$stats_line" | grep -o '"bytes":[0-9]*'       | cut -d: -f2 | head -1 || echo 0)
            elapsedTime=$(echo "$stats_line" | grep -o '"elapsedTime":[0-9.]*'| cut -d: -f2 | head -1 || echo 0)
            speed=$(      echo "$stats_line" | grep -o '"speed":[0-9.]*'      | cut -d: -f2 | head -1 || echo 0)
        fi
    fi

    set -e

    # Нормализация: если значение не число — заменяем нулём
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

# Агрегирует статистику по всем JSON-логам директорий.
# Суммирует числовые поля (transfers, bytes и т.д.).
# Возвращает те же 8 полей, что и parse_rclone_stats.
aggregate_rclone_stats() {
    local total_transfers=0 total_checks=0 total_deletes=0 total_errors=0
    local total_totalBytes=0 total_bytes=0 max_elapsed=0 avg_speed_sum=0
    local speed_count=0

    local dir
    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        local jsonlog
        jsonlog="$(jsonlog_for_dir "$dir")"

        local transfers checks deletes errors totalBytes bytes elapsedTime speed
        read -r transfers checks deletes errors totalBytes bytes elapsedTime speed \
             <<< "$(parse_rclone_stats "$jsonlog")" 2>/dev/null || continue

        total_transfers=$(( total_transfers + transfers ))
        total_checks=$(( total_checks + checks ))
        total_deletes=$(( total_deletes + deletes ))
        total_errors=$(( total_errors + errors ))
        total_totalBytes=$(( total_totalBytes + totalBytes ))
        total_bytes=$(( total_bytes + bytes ))

        # Берём максимальное время выполнения (процессы шли параллельно)
        if command -v awk >/dev/null 2>&1; then
            if awk "BEGIN {exit !($elapsedTime > $max_elapsed)}"; then
                max_elapsed=$elapsedTime
            fi
            if [[ "$speed" != "0" && "$speed" != "0.0" ]]; then
                avg_speed_sum=$(awk "BEGIN {printf \"%.2f\", $avg_speed_sum + $speed}")
                (( speed_count++ )) || true
            fi
        fi
    done

    local avg_speed=0
    if (( speed_count > 0 )) && command -v awk >/dev/null 2>&1; then
        avg_speed=$(awk "BEGIN {printf \"%.2f\", $avg_speed_sum / $speed_count}")
    fi

    echo "$total_transfers $total_checks $total_deletes $total_errors" \
         "$total_totalBytes $total_bytes $max_elapsed $avg_speed"
}

# Подсчитывает количество файлов и суммарный размер в директории через rclone.
# Возвращает два числа: "КОЛИЧЕСТВО_ФАЙЛОВ БАЙТ"
calculate_directory_stats() {
    local path="$1"

    if [[ -z "$path" || ! -d "$path" ]]; then
        echo "0 0"
        return 0
    fi

    log DEBUG "Подсчёт статистики директории: $path"

    local -a base_args=(
        --files-only
        --recursive
        --exclude-from="$EXCLUDE_FILE"
    )
    [[ -n "${RCLONE_CONFIG:-}" ]] && base_args+=(--config="$RCLONE_CONFIG")

    local file_count=0 total_size=0

    set +e

    # Подсчёт количества файлов через rclone lsf
    if file_count=$(timeout 300 rclone lsf "${base_args[@]}" "$path" \
                    2>/dev/null | wc -l); then
        log DEBUG "Файлов в $path: $file_count"
    else
        file_count=0
    fi

    # Подсчёт размера: сначала пробуем через rclone size --json (точнее)
    if command -v jq >/dev/null 2>&1; then
        if total_size=$(timeout 300 rclone size --json "${base_args[@]}" "$path" \
                        2>/dev/null | jq '.bytes // 0' 2>/dev/null); then
            [[ "$total_size" =~ ^[0-9]+$ ]] || total_size=0
        else
            total_size=0
        fi
    fi

    # Резервный метод: суммируем размеры через rclone lsf --format s
    if [[ "$total_size" == "0" ]]; then
        if total_size=$(timeout 300 rclone lsf --format s "${base_args[@]}" "$path" \
                        2>/dev/null | awk '{if($1~/^[0-9]+$/) s+=$1} END{printf "%.0f",s+0}'); then
            [[ "$total_size" =~ ^[0-9]+$ ]] || total_size=0
        else
            total_size=0
        fi
    fi

    set -e

    echo "$file_count $total_size"
}

# Форматирует размер в байтах в человекочитаемый вид (KB, MB, GB...).
# Использует awk для точного деления с плавающей точкой.
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

    # Находим подходящую единицу
    while (( size >= 1024 && unit_index < ${#units[@]} - 1 )); do
        (( size = size / 1024 ))
        (( unit_index++ ))
    done

    # Точное значение с двумя знаками после запятой через awk
    if command -v awk >/dev/null 2>&1; then
        local precise
        precise=$(awk "BEGIN {printf \"%.2f\", $size_bytes / (1024 ^ $unit_index)}")
        echo "${precise} ${units[$unit_index]}"
    else
        echo "${size} ${units[$unit_index]}"
    fi
}


# ==============================================================================
# РАЗДЕЛ 14: ГЕНЕРАЦИЯ ОТЧЁТОВ
# ==============================================================================

# Записывает итоговую сводку в JSON-файл.
# JSON-формат удобен для парсинга внешними системами мониторинга (Zabbix, etc.).
write_summary_json() {
    local result="$1"
    local temp_json

    if ! temp_json="$(mktemp)"; then
        log ERROR "Не удалось создать временный файл для JSON-сводки"
        REPORT_GENERATION_FAILED=true
        return 1
    fi

    # Получаем агрегированную статистику по всем директориям
    local transfers checks deletes errors totalBytes bytes elapsed speed
    read -r transfers checks deletes errors totalBytes bytes elapsed speed \
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
            read -r src_count src_bytes \
                 <<< "$(calculate_directory_stats "$dir")" 2>/dev/null || true
            read -r dest_count dest_bytes \
                 <<< "$(calculate_directory_stats "$dest_dir")" 2>/dev/null || true

            [[ "$first" == "true" ]] && first=false || echo "    ,"

            # Экранируем кавычки в путях на случай нестандартных символов
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

# Записывает итоговую сводку в текстовый файл (для чтения человеком).
write_summary_txt() {
    local result="$1"
    local temp_txt

    if ! temp_txt="$(mktemp)"; then
        log ERROR "Не удалось создать временный файл для текстовой сводки"
        REPORT_GENERATION_FAILED=true
        return 1
    fi

    # Агрегированная статистика
    local transfers checks deletes errors totalBytes bytes elapsed speed
    read -r transfers checks deletes errors totalBytes bytes elapsed speed \
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

        # Форматируем время выполнения
        if [[ "$elapsed" != "0" && "$elapsed" != "0.0" ]]; then
            if command -v awk >/dev/null 2>&1; then
                local h m s
                h=$(awk "BEGIN {printf \"%d\", $elapsed / 3600}")
                m=$(awk "BEGIN {printf \"%d\", ($elapsed % 3600) / 60}")
                s=$(awk "BEGIN {printf \"%.2f\", $elapsed % 60}")
                printf "Время выполнения:      %d:%02d:%s\n" "$h" "$m" "$s"
            else
                printf "Время выполнения:      %.2f сек.\n" "$elapsed"
            fi

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

            read -r src_count src_bytes \
                 <<< "$(calculate_directory_stats "$dir")" 2>/dev/null || true
            read -r dest_count dest_bytes \
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

# Экстренный минимальный отчёт — используется когда основные функции отчётности
# уже отказали. Пишет только базовые поля без статистики.
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

# Координирует генерацию всех форматов отчётов.
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
    log INFO "  Параллельность:   $PARALLEL"

    # ------------------------------------------------------------------
    # ЭТАП 1: Проверка доступности CephFS
    # ------------------------------------------------------------------
    log INFO "ЭТАП 1: Проверка доступности CephFS"
    if ! check_ceph_access; then
        log CRITICAL "CephFS недоступен — резервное копирование невозможно"
        write_summary "failure"
        return 1
    fi
    log INFO "ЭТАП 1 завершён: CephFS доступен"

    # ------------------------------------------------------------------
    # ЭТАП 2: Очистка устаревших резервных копий
    # ------------------------------------------------------------------
    log INFO "ЭТАП 2: Очистка устаревших файлов в '$DELETE_BACKUP'"
    if ! cleanup_old_backups; then
        log WARNING "Очистка завершилась с предупреждениями — продолжаем"
    else
        log INFO "ЭТАП 2 завершён: очистка выполнена"
    fi

    # ------------------------------------------------------------------
    # ЭТАП 3: Экспорт функций и переменных для дочерних процессов
    # ------------------------------------------------------------------
    # xargs -P запускает каждую директорию в отдельном bash-процессе.
    # Дочерние процессы не наследуют функции автоматически —
    # их нужно явно экспортировать через export -f.
    #
    # ВАЖНО: Изменения переменных (например, BACKUP_SUCCESS) в дочернем
    # процессе НЕ видны родительскому процессу. Статус определяется
    # исключительно по коду возврата xargs (xargs_exit_code).
    log INFO "ЭТАП 3: Экспорт функций для параллельного выполнения"

    export -f log log_command retry_command cmd_to_string dest_from_src \
              jsonlog_for_dir backup_directory calculate_directory_stats \
              format_size parse_rclone_stats

    export LOGFILE RCLONE_JSONLOG_DIR EXCLUDE_FILE MAIN_BACKUP DELETE_BACKUP
    export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES RCLONE_RETRIES_SLEEP
    export RCLONE_BUFFER_SIZE RCLONE_USE_MMAP RCLONE_LOG_LEVEL
    export DRY_RUN SCRIPT_VERSION
    export -p RCLONE_CONFIG 2>/dev/null || true  # может быть не задан

    log INFO "ЭТАП 3 завершён"

    # ------------------------------------------------------------------
    # ЭТАП 4: Параллельное резервное копирование директорий
    # ------------------------------------------------------------------
    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
    log INFO "  Директорий: ${#SOURCEDIRS_ARRAY[@]}"
    log INFO "  Параллельно: до $PARALLEL процессов"

    local backup_start backup_end backup_duration
    backup_start=$(date +%s)

    # Отключаем set -e, чтобы xargs мог вернуть ненулевой код
    # без немедленного завершения скрипта — мы обработаем его вручную.
    set +e

    # printf '%s\0' — разделяем имена нулевым байтом (безопасно для путей с пробелами)
    # xargs -0    — читает строки с нулевым разделителем
    # xargs -n1   — передаёт по одному аргументу на вызов
    # xargs -P    — запускает до $PARALLEL процессов параллельно
    # bash -c '...' _ {} — запускает функцию в новом bash с именем директории как $1
    printf '%s\0' "${SOURCEDIRS_ARRAY[@]}" \
        | xargs -0 -n1 -P"$PARALLEL" \
                bash -c 'backup_directory "$1"' _

    local xargs_exit_code=$?
    set -e

    backup_end=$(date +%s)
    backup_duration=$(( backup_end - backup_start ))

    log INFO "Все процессы резервного копирования завершены"
    log INFO "Общее время: $(printf '%d:%02d:%02d' \
             $((backup_duration/3600)) $((backup_duration%3600/60)) $((backup_duration%60)))"

    # Определяем итоговый статус по коду возврата xargs.
    # xargs возвращает 0 если все дочерние процессы вернули 0.
    # При любом другом коде хотя бы один процесс завершился с ошибкой.
    if (( xargs_exit_code != 0 )); then
        log WARNING "Один или несколько процессов резервного копирования завершились с ошибкой" \
                    "(xargs код: $xargs_exit_code)"
        BACKUP_SUCCESS=false
    else
        BACKUP_SUCCESS=true
        log INFO "Все операции резервного копирования выполнены успешно"
    fi

    # ------------------------------------------------------------------
    # ЭТАП 5: Генерация итоговой сводки
    # ------------------------------------------------------------------
    log INFO "ЭТАП 5: Генерация итоговой сводки"

    local final_result
    if [[ "$BACKUP_SUCCESS" == "true" ]]; then
        final_result="success"
        log INFO "ИТОГ: РЕЗЕРВНОЕ КОПИРОВАНИЕ ВЫПОЛНЕНО УСПЕШНО"
    else
        final_result="failure"
        log WARNING "ИТОГ: РЕЗЕРВНОЕ КОПИРОВАНИЕ ЗАВЕРШИЛОСЬ С ОШИБКАМИ"
    fi

    # Генерация отчётов не должна менять итоговый exit code скрипта.
    # Если отчёт не сгенерировался — это неприятно, но бэкап уже сделан.
    set +e
    write_summary "$final_result"
    set -e

    log INFO "========== ЗАВЕРШЕНИЕ ОСНОВНОГО ПОТОКА =========="

    # Возвращаем 0 если бэкап успешен, 1 если были ошибки копирования
    [[ "$BACKUP_SUCCESS" == "true" ]] && return 0 || return 1
}


# ==============================================================================
# РАЗДЕЛ 16: ТОЧКА ВХОДА
# ==============================================================================
# Проверяем, запущен ли скрипт напрямую или загружен через source.
# При загрузке через source (. ./script.sh) функции становятся доступны
# в текущей оболочке без выполнения main — удобно для тестирования.

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
