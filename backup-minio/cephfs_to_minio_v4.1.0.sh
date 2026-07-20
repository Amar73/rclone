#!/usr/bin/env bash
# =================================================================================================
# cephfs_to_minio_v4.0.sh — Синхронизация CephFS ➜ MinIO S3
# Версия: 4.0.0 (Апрель 2026)
#
# НАЗНАЧЕНИЕ СКРИПТА:
#   Выполняет инкрементальную синхронизацию данных с примонтированной файловой системы
#   CephFS в объектное хранилище MinIO S3 с помощью инструмента rclone.
#
#   Ключевые возможности:
#     - Удалённые на источнике файлы не уничтожаются безвозвратно, а перемещаются
#       в отдельный бакет "deleted-backup" с временной меткой (retention 30 дней).
#     - Поддержка нескольких исходных директорий, каждая синхронизируется отдельно.
#     - Защита от параллельного запуска через файловую блокировку (flock).
#     - Режим «сухого прогона» (DRY_RUN=true) — проверка без реальных изменений.
#     - Ротация лог-файлов, итоговая сводка в отдельном файле.
#     - Автоматическое монтирование CephFS при его отсутствии.
#
# БЫСТРЫЙ СТАРТ:
#   Проверочный запуск (без реальных изменений):
#     DRY_RUN=true ./cephfs_to_minio_v4.0.sh
#
#   Боевой запуск:
#     ./cephfs_to_minio_v4.0.sh
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ (все необязательны, есть значения по умолчанию):
#   RCLONE_CONFIG        — путь к конфигу rclone     (по умолчанию: /root/.config/rclone/rclone.conf)
#   LOGDIR               — директория логов           (по умолчанию: /var/log/backup-ceph-minio)
#   LOCKFILE             — путь к файлу блокировки    (по умолчанию: /var/lock/backup-ceph-minio.lock)
#   MINIO_ENDPOINT       — URL MinIO сервера          (по умолчанию: https://minio01.apps.maket.nbgi.ru:9000)
#   MAIN_BACKUP          — rclone-путь основного бакета  (по умолчанию: minio:nbiks-backup)
#   DELETE_BACKUP        — rclone-путь бакета удалений  (по умолчанию: minio:deleted-backup)
#   SOURCEDIRS_ENV       — список директорий через ':' (по умолчанию: см. SOURCEDIRS_ARRAY ниже)
#   RCLONE_TRANSFERS     — число параллельных передач  (по умолчанию: 20)
#   RCLONE_CHECKERS      — число потоков проверки      (по умолчанию: 8)
#   RCLONE_RETRIES       — повторных попыток rclone    (по умолчанию: 5)
#   RCLONE_RETRIES_SLEEP — пауза между попытками       (по умолчанию: 10s)
#   RCLONE_BUFFER_SIZE   — размер буфера передачи      (по умолчанию: 16M)
#   RCLONE_LOG_LEVEL     — уровень лога rclone         (по умолчанию: INFO)
#   DELETE_RETENTION_DAYS — хранение удалённых файлов  (по умолчанию: 30 дней)
#   LOG_RETENTION_DAYS   — хранение лог-файлов         (по умолчанию: 30 дней)
#   DRY_RUN              — режим без изменений (true/false, по умолчанию: false)
#   MOUNT_RETRIES        — попыток монтирования CephFS (по умолчанию: 5)
#   MOUNT_RETRY_DELAY    — пауза между монтированиями  (по умолчанию: 30 сек)
#   RCLONE_S3_INSECURE   — отключить TLS-проверку rclone (true/false, по умолчанию: false)
#                          Нужно если MinIO использует self-signed сертификат.
#                          Предпочтительнее: no_check_certificate = true в rclone.conf
#
# ЗАВИСИМОСТИ:
#   - bash >= 4.1
#   - rclone >= 1.60 (настроен remote с именем "minio")
#   - flock, mountpoint, find, curl, date, awk (стандартные утилиты Linux)
#
# ПРИМЕЧАНИЕ ПО CHECKSUM:
#   Скрипт использует --checksum для сравнения файлов по содержимому (MD5/SHA1),
#   а не по размеру и времени модификации. Это надёжнее, но требует дополнительных
#   запросов к S3 для получения checksums.
#   Флаг --update был намеренно убран: он пропускает файлы по mtime,
#   что противоречит логике --checksum и может приводить к молчаливым пропускам
#   изменённых файлов при любом расхождении часов.
#
# CRON (пример — запуск каждый день в 02:00):
#   0 2 * * * root /opt/scripts/cephfs_to_minio_v4.0.sh >> /var/log/backup-ceph-minio/cron.log 2>&1
#
# СТРУКТУРА БАКЕТОВ В MINIO:
#   minio:nbiks-backup/
#     nbics/Reads/               ← синхронизируется с /ceph/data/nbics/Reads
#     nbics/Genomes/             ← синхронизируется с /ceph/data/nbics/Genomes
#     bio/nextcloud/data/...     ← синхронизируется с /ceph/data/bio/nextcloud/...
#
#   minio:deleted-backup/
#     2026-03-22/
#       nbics/Reads/             ← файлы, удалённые из источника 22 марта 2026
#       ...
#
# ─── ЖУРНАЛ ИЗМЕНЕНИЙ ────────────────────────────────────────────────────────────────────────────
#
#  v4.1.0 (текущая):
#    Разбор прогона 2026-04-26: он стартовал 26 апреля, к 2 мая успел обработать
#    лишь 2 директории из 3 и был убит перезагрузкой хоста 6 мая (итоговая сводка
#    не записана — процесс получил сигнал, который не перехватывают trap'ы).
#    Ошибок rclone при этом не было вообще: проблема исключительно в скорости.
#    - ДОБАВЛЕНО: SYNC_MODE=fast|checksum. Для CephFS→S3 --checksum требует
#      вычитывания каждого файла с CephFS ради хеша — теперь это только
#      еженедельный прогон, ежедневный идёт по размеру+mtime.
#    - ДОБАВЛЕНО: DIR_TIMEOUT (по умолчанию 8h) через timeout(1), чтобы одна
#      директория не съедала прогон целиком. Коды 124/137 не ретраятся.
#    - ИСПРАВЛЕНО: retry_rclone_command определял подкоманду как ${cmd[1]}.
#      После обёртки в timeout там оказывался флаг timeout, и коды 1 и 3
#      («нечего удалять» / «нет изменений») перестали бы распознаваться —
#      нормальные исходы считались бы ошибкой. Теперь подкоманда ищется по
#      позиции самого rclone в массиве.
#    - ДОБАВЛЕНО: --tpslimit/--tpslimit-burst.
#    - СНИЖЕНО: TRANSFERS 20->8, CHECKERS 8->4.
#
#  v4.0.0:
#    - ИСПРАВЛЕНО: убран флаг --update из rclone sync. Совместное использование
#      --update и --checksum приводило к молчаливому пропуску изменённых файлов:
#      --update пропускал файл по mtime если dst новее src, не проверяя checksum.
#    - ИСПРАВЛЕНО: exec {LOCK_FD}<&- заменён на exec {LOCK_FD}>&- (закрытие
#      write-дескриптора через правильное направление); убран лишний eval.
#    - ИСПРАВЛЕНО: for attempt in $(seq ...) заменён на арифметический цикл
#      ((attempt=1; ...)) — нет subprocess.
#    - ИСПРАВЛЕНО: _check_single_remote вынесена из тела check_rclone_remotes
#      на верхний уровень — устранено загрязнение глобального namespace функций.
#    - ИСПРАВЛЕНО: ((SYNC_SUCCESSFUL++)) || true — постфиксный ++ при значении 0
#      возвращает falsy exit code. Заменено на SYNC_SUCCESSFUL=$((SYNC_SUCCESSFUL+1)).
#    - УЛУЧШЕНО: create_bucket_if_needed использует rclone mkdir напрямую
#      (идемпотентно) вместо lsd + mkdir — устранён TOCTOU race condition.
#    - УЛУЧШЕНО: mktemp в retry_rclone_command создаётся один раз до цикла,
#      файл обнуляется перед каждой попыткой — меньше системных вызовов.
#    - УЛУЧШЕНО: --progress добавляется только при интерактивном запуске (TTY),
#      не загрязняет ANSI-кодами cron-письма.
#    - УЛУЧШЕНО: исправлен комментарий структуры бакетов в заголовке —
#      ранее показывал путь от v2.1 (Reads/ вместо nbics/Reads/).
#    - ДОБАВЛЕНО: переменная RCLONE_S3_INSECURE — отключает TLS-проверку во всех
#      вызовах rclone (lsd, mkdir, delete, rmdirs, sync). Необходима при использовании
#      self-signed сертификата MinIO без добавления CA в системное хранилище.
#      curl-проверка в check_minio_connectivity использует --insecure независимо от флага.
#
#  v3.0.0:
#    - Исправлена обработка exit code через промежуточную переменную (без PIPESTATUS)
#    - Исправлен относительный путь: теперь стрипается /ceph/data/, а не /ceph/data/nbics/
#    - Добавлена ротация JSONL и summary файлов (не только .log)
#    - Добавлен явный параметр exit_code в generate_final_summary
#
# =================================================================================================

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 1: ЗАЩИТНЫЕ ПРОВЕРКИ И СТРОГИЙ РЕЖИМ
# -------------------------------------------------------------------------------------------------

# Требуем bash версии 4.1+ — используется синтаксис автоматического назначения FD {var}>file
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1))); then
    echo "ОШИБКА: Требуется bash версии 4.1 или новее. Текущая версия: ${BASH_VERSION}" >&2
    exit 1
fi

# Строгий режим выполнения:
#   -e  — немедленный выход при ненулевом коде завершения команды
#   -E  — функции наследуют обработчики ERR trap
#   -u  — ошибка при обращении к неустановленной переменной
#   -o pipefail — код выхода пайпа = коду последней упавшей команды
set -eEuo pipefail

# Ограничиваем разделители IFS — защита от неожиданного разбиения строк с пробелами
IFS=$'\n\t'

# Ограничиваем права на создаваемые файлы (rw-r-----), не даём world-readable логи с данными
umask 027

# Принудительный английский локаль для предсказуемого вывода утилит (даты, числа и т.п.)
export LANG=C LC_ALL=C

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 2: МЕТАДАННЫЕ И КОНСТАНТЫ
# -------------------------------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="4.1.0"

# Минимальная поддерживаемая версия rclone
readonly REQUIRED_RCLONE_VERSION="1.60"

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 3: КОНФИГУРАЦИЯ (переопределяется через переменные окружения)
# -------------------------------------------------------------------------------------------------

# Конфигурационный файл rclone. Должен содержать секцию [minio] с настройками S3.
# Рекомендуемые права: 600 (только root)
readonly RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"

# Директория для хранения лог-файлов
readonly LOGDIR="${LOGDIR:-/var/log/backup-ceph-minio}"

# Файл блокировки — предотвращает одновременный запуск двух экземпляров скрипта
readonly LOCKFILE="${LOCKFILE:-/var/lock/backup-ceph-minio.lock}"

# URL MinIO сервера. Используется только для HTTP-проверки доступности через curl.
# Для rclone используются настройки из rclone.conf
readonly MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://minio01.apps.maket.nbgi.ru:9000}"

# rclone-путь к основному бакету (remote_name:bucket_name)
readonly MAIN_BACKUP="${MAIN_BACKUP:-minio:nbiks-backup}"

# rclone-путь к бакету для хранения удалённых файлов.
# При синхронизации файлы, удалённые из источника, не стираются безвозвратно,
# а перемещаются сюда с субпрефиксом даты: deleted-backup/YYYY-MM-DD/...
readonly DELETE_BACKUP="${DELETE_BACKUP:-minio:deleted-backup}"

# Список исходных директорий для синхронизации.
# SOURCEDIRS_ENV — разделитель ':', например: SOURCEDIRS_ENV='/ceph/a:/ceph/b'
# Если SOURCEDIRS_ENV не задан — используется массив по умолчанию.
#
# ВАЖНО: все пути ДОЛЖНЫ начинаться с /ceph/ — это проверяется в validate_source_directories().
if [[ -n "${SOURCEDIRS_ENV:-}" ]]; then
    # Временно меняем IFS только для split — не затрагиваем глобальный IFS
    IFS=':' read -ra SOURCEDIRS_ARRAY <<< "$SOURCEDIRS_ENV"
else
    # Значения по умолчанию: три директории на CephFS для разных проектов
    readonly -a SOURCEDIRS_ARRAY=(
        '/ceph/data/nbics/Reads'
        '/ceph/data/nbics/Genomes'
        '/ceph/data/bio/nextcloud/data/data/kgs'
    )
fi

# Настройки rclone — параллелизм и надёжность
readonly RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-8}"           # параллельных файлов в передаче
readonly RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"             # потоков проверки существования

# Режим сверки (v4.1.0):
#   fast     — по размеру и времени модификации (умолчание rclone). Быстро.
#   checksum — по контрольной сумме. Для CephFS→S3 это означает вычитывание
#              КАЖДОГО файла с CephFS ради хеша, что и делало прогоны
#              многодневными: запуск 2026-04-26 к 2026-05-02 успел обработать
#              лишь 2 директории из 3 и был убит перезагрузкой хоста 6 мая.
# Штатная схема: ежедневно fast, раз в неделю checksum.
readonly SYNC_MODE="${SYNC_MODE:-fast}"

# Потолок запросов к S3 в секунду — бережём MinIO от лавины запросов.
readonly RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-50}"
readonly RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-100}"

# Жёсткий таймаут на одну директорию (формат timeout(1)): чтобы одна зависшая
# директория не съедала прогон целиком.
readonly DIR_TIMEOUT="${DIR_TIMEOUT:-8h}"
readonly RCLONE_RETRIES="${RCLONE_RETRIES:-5}"               # внутренних повторов rclone
readonly RCLONE_RETRIES_SLEEP="${RCLONE_RETRIES_SLEEP:-10s}" # пауза между повторами rclone
readonly RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-16M}"     # буфер в памяти на поток
readonly RCLONE_LOG_LEVEL="${RCLONE_LOG_LEVEL:-INFO}"        # уровень логирования rclone

# Сроки хранения
readonly DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-30}" # дней хранить удалённые файлы
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"       # дней хранить лог-файлы

# DRY_RUN=true — запустить rclone с флагом --dry-run: никаких реальных изменений не будет.
# Используйте для проверки конфигурации перед первым боевым запуском.
readonly DRY_RUN="${DRY_RUN:-false}"

# RCLONE_S3_INSECURE=true — отключить проверку TLS-сертификата во всех вызовах rclone.
# Используйте ТОЛЬКО если MinIO использует self-signed сертификат и нет возможности
# добавить CA в системное хранилище или в rclone.conf (no_check_certificate = true).
# Предпочтительный способ: прописать no_check_certificate = true в секцию [minio]
# в /root/.config/rclone/rclone.conf — тогда этот флаг не нужен.
# ВНИМАНИЕ: отключение TLS-проверки делает соединение уязвимым к MITM-атаке.
readonly RCLONE_S3_INSECURE="${RCLONE_S3_INSECURE:-false}"

# Параметры автоматического монтирования CephFS при его отсутствии
readonly MOUNT_RETRIES="${MOUNT_RETRIES:-5}"         # максимум попыток mount
readonly MOUNT_RETRY_DELAY="${MOUNT_RETRY_DELAY:-30}" # секунд между попытками

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 4: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ СОСТОЯНИЯ
# -------------------------------------------------------------------------------------------------

declare -g SYNC_SUCCESS=true       # false если хотя бы одна директория упала с ошибкой
declare -g VALIDATION_FAILED=false # true если пост-проверка выявила расхождения
declare -g SYNC_PROCESSED=0        # счётчик директорий, запущенных на синхронизацию
declare -g SYNC_SUCCESSFUL=0       # счётчик успешно синхронизированных директорий
declare -g LOGFILE=""              # путь к основному лог-файлу (заполняется в initialize_logging)
declare -g RCLONE_JSONLOG=""       # путь к JSONL-логу rclone
declare -g SUMMARY_FILE=""         # путь к файлу итоговой сводки

# Дескриптор файла блокировки (заполняется в setup_locking_and_signals)
declare -g LOCK_FD=""

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 5: СИСТЕМА ЛОГИРОВАНИЯ
# -------------------------------------------------------------------------------------------------

# log LEVEL "сообщение" — пишет строку вида "2026-03-22T10:05:01+00:00 [INFO] сообщение"
#   в stderr (с цветом, если терминал интерактивный) и в LOGFILE.
#
# Уровни: DEBUG, INFO, WARNING, ERROR, CRITICAL, SUCCESS
log() {
    local level="${1:-INFO}"
    shift || true
    local message="${*:-}"
    local timestamp
    timestamp="$(date -Iseconds)"

    # Цветовое оформление — только если stderr подключён к терминалу
    local color_code=""
    if [[ -t 2 ]]; then
        case "$level" in
            DEBUG)    color_code="\033[36m"    ;;  # голубой
            INFO)     color_code="\033[32m"    ;;  # зелёный
            WARNING)  color_code="\033[33m"    ;;  # жёлтый
            ERROR)    color_code="\033[31m"    ;;  # красный
            CRITICAL) color_code="\033[35;1m"  ;;  # жирный пурпурный
            SUCCESS)  color_code="\033[92m"    ;;  # ярко-зелёный
        esac
    fi

    local log_message="${timestamp} [${level}] ${message}"

    if [[ -n "$color_code" ]]; then
        echo -e "${color_code}${log_message}\033[0m" >&2
    else
        echo "$log_message" >&2
    fi

    # Пишем в файл только если LOGFILE уже инициализирован и его директория доступна
    if [[ -n "${LOGFILE:-}" && -w "${LOGFILE%/*}" ]]; then
        echo "$log_message" >> "$LOGFILE"
    fi
}

# die "сообщение" — критическая ошибка с немедленным завершением скрипта (exit 1).
# Запускает цепочку: EXIT trap → cleanup_resources → generate_final_summary.
die() {
    log CRITICAL "$*"
    exit 1
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 6: ПРОВЕРКИ ОКРУЖЕНИЯ
# -------------------------------------------------------------------------------------------------

# Проверяет наличие всех необходимых внешних команд в PATH.
# При отсутствии хотя бы одной — аварийно завершает скрипт.
check_required_commands() {
    local missing_commands=()
    # curl нужен для HTTP-проверки доступности MinIO
    # flock нужен для файловой блокировки
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

# Проверяет версию rclone и предупреждает, если она ниже рекомендованной.
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
        log WARNING "Рекомендуется rclone версии ${REQUIRED_RCLONE_VERSION}+. Текущая: ${rclone_version}"
    else
        log INFO "Версия rclone: ${rclone_version} (соответствует требованиям)"
    fi
}

# Проверяет наличие и читаемость конфигурационного файла rclone.
# Предупреждает о небезопасных правах доступа (должно быть 600).
check_rclone_config() {
    log INFO "Проверка конфигурации rclone: $RCLONE_CONFIG"

    [[ -f "$RCLONE_CONFIG" ]] || die "Конфигурационный файл rclone не найден: $RCLONE_CONFIG"
    [[ -r "$RCLONE_CONFIG" ]] || die "Конфигурационный файл rclone недоступен для чтения: $RCLONE_CONFIG"

    # Конфиг rclone содержит секреты (ключи S3), поэтому права должны быть 600
    local file_perms
    file_perms=$(stat -c%a "$RCLONE_CONFIG" 2>/dev/null || echo "unknown")
    if [[ "$file_perms" != "600" ]]; then
        log WARNING "Небезопасные права на конфиг rclone: $file_perms (рекомендуется 600)"
        log WARNING "Исправить: chmod 600 $RCLONE_CONFIG"
    fi

    log INFO "Конфигурация rclone проверена успешно"
}

# Валидирует пути в SOURCEDIRS_ARRAY:
#   1. Все пути должны начинаться с /ceph/ — защита от случайной синхронизации системных директорий.
#   2. Пути не должны содержать shell-метасимволы, способные вызвать инъекцию команд.
validate_source_directories() {
    log INFO "Валидация исходных директорий"

    for dir in "${SOURCEDIRS_ARRAY[@]}"; do
        # Защита от нечаянного указания не-Ceph путей
        if [[ ! "$dir" =~ ^/ceph/ ]]; then
            die "Небезопасный путь источника (должен начинаться с /ceph/): $dir"
        fi

        # Защита от path traversal и command injection
        # Проверяем: ../ (выход из директории), $( (подстановка команды),
        #            ` (обратные кавычки), ; (разделитель команд)
        if [[ "$dir" =~ (\.\./|\$\(|\`|;) ]]; then
            die "Обнаружены потенциально опасные символы в пути: $dir"
        fi
    done

    log INFO "Валидация исходных директорий завершена успешно"
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 7: ИНИЦИАЛИЗАЦИЯ ЛОГИРОВАНИЯ И РОТАЦИЯ ЛОГОВ
# -------------------------------------------------------------------------------------------------

# Создаёт директорию логов и инициализирует пути к файлам.
# Вызывается самой первой в main(), до любых других действий.
initialize_logging() {
    local timestamp
    timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"

    # Создаём директорию логов если не существует
    [[ -d "$LOGDIR" ]] || mkdir -p "$LOGDIR" || die "Не удалось создать директорию логов: $LOGDIR"

    # Три файла на каждый запуск: основной лог, JSON-лог rclone, текстовая сводка
    LOGFILE="$LOGDIR/backup_${timestamp}.log"
    RCLONE_JSONLOG="$LOGDIR/backup_${timestamp}.jsonl"
    SUMMARY_FILE="$LOGDIR/backup_${timestamp}.summary.txt"

    # Инициализируем файлы (создаём пустыми)
    : > "$LOGFILE"
    : > "$RCLONE_JSONLOG"

    log INFO "=== ЗАПУСК СИНХРОНИЗАЦИИ CEPHFS ➜ MINIO S3 ==="
    log INFO "Версия скрипта: $SCRIPT_VERSION"
    log INFO "Пользователь: $(whoami)"
    log INFO "Хост: $(hostname -f 2>/dev/null || hostname)"
    log INFO "PID процесса: $$"
    log INFO "Режим DRY_RUN: $DRY_RUN"
    log INFO "Файлы логов:"
    log INFO "  - Основной лог:    $LOGFILE"
    log INFO "  - JSON лог rclone: $RCLONE_JSONLOG"
    log INFO "  - Итоговая сводка: $SUMMARY_FILE"
}

# Удаляет лог-файлы старше LOG_RETENTION_DAYS дней.
# Обрабатывает все три типа файлов (.log, .jsonl, .summary.txt).
rotate_old_logs() {
    log INFO "Ротация старых логов (удаление файлов старше $LOG_RETENTION_DAYS дней)"

    local deleted_count
    deleted_count=$(find "$LOGDIR" -type f \( \
        -name 'backup_*.log' \
        -o -name 'backup_*.jsonl' \
        -o -name 'backup_*.summary.txt' \
    \) -mtime "+$LOG_RETENTION_DAYS" -delete -print 2>/dev/null | wc -l)

    if ((deleted_count > 0)); then
        log INFO "Удалено $deleted_count старых лог-файлов"
    else
        log INFO "Старых лог-файлов для удаления не найдено"
    fi
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 8: БЛОКИРОВКА И ОБРАБОТКА СИГНАЛОВ
# -------------------------------------------------------------------------------------------------

# Обработчик завершения (EXIT trap).
# Вызывается автоматически при любом выходе из скрипта — штатном или аварийном.
# Освобождает блокировку, удаляет lock-файл, генерирует итоговую сводку.
cleanup_resources() {
    # Сохраняем код выхода до его перезаписи командами ниже
    local exit_code=$?

    log INFO "Начало процедуры очистки ресурсов"

    # Освобождаем flock-блокировку и закрываем дескриптор
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        log DEBUG "Блокировка освобождена"

        # FIX v4.0: используем >&- (close write fd) вместо <&- (close read fd).
        # eval убран — bash 4.1+ поддерживает {varname}>&- напрямую.
        exec {LOCK_FD}>&- 2>/dev/null || true
    fi

    # Удаляем файл блокировки
    [[ -f "$LOCKFILE" ]] && { rm -f "$LOCKFILE" || true; log DEBUG "Файл блокировки удалён"; }

    # Генерируем итоговую сводку, передавая финальный exit code.
    # Если SYNC_PROCESSED=0 (скрипт упал до этапа 4) — показываем реальное число директорий.
    if ((SYNC_PROCESSED == 0)); then
        SYNC_PROCESSED=${#SOURCEDIRS_ARRAY[@]}
    fi
    generate_final_summary "$exit_code"

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

    # Явно выходим с исходным кодом — иначе EXIT trap перезапишет его нулём
    exit $exit_code
}

# Обработчик сигналов INT / TERM / HUP.
handle_signal() {
    local signal=$1
    log WARNING "Получен сигнал $signal — инициируется корректное завершение"
    SYNC_SUCCESS=false
    exit 130
}

# Устанавливает файловую блокировку и регистрирует обработчики сигналов.
# Если другой экземпляр скрипта уже держит блокировку — немедленный выход.
setup_locking_and_signals() {
    # Открываем lock-файл и получаем дескриптор (bash 4.1+ синтаксис)
    exec {LOCK_FD}>"$LOCKFILE" || die "Не удалось создать файл блокировки: $LOCKFILE"

    # -n — не ждать, сразу вернуть ошибку если занято
    if ! flock -n "$LOCK_FD"; then
        die "Другой экземпляр скрипта уже выполняется (блокировка активна: $LOCKFILE)"
    fi

    trap cleanup_resources EXIT
    trap 'handle_signal INT'  INT
    trap 'handle_signal TERM' TERM
    trap 'handle_signal HUP'  HUP

    log INFO "Блокировка получена успешно (дескриптор: $LOCK_FD)"
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 9: ПРОВЕРКА ДОСТУПНОСТИ ХРАНИЛИЩ
# -------------------------------------------------------------------------------------------------

# Проверяет, смонтирован ли /ceph, и пытается смонтировать если нет.
# Дополнительно проверяет читаемость и наличие всех исходных директорий.
check_cephfs_availability() {
    log INFO "Проверка доступности CephFS"

    if ! mountpoint -q /ceph 2>/dev/null; then
        log WARNING "/ceph не смонтирован — попытка автоматического монтирования"

        # Принудительный lazy umount на случай зависшего mount
        umount -fl /ceph 2>/dev/null || true

        # FIX v4.0: арифметический цикл вместо $(seq ...) — нет subprocess
        local attempt
        for ((attempt=1; attempt<=MOUNT_RETRIES; attempt++)); do
            log INFO "Попытка монтирования $attempt/$MOUNT_RETRIES"

            # mount /ceph использует запись из /etc/fstab
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

        # Финальная проверка после всех попыток
        if ! mountpoint -q /ceph 2>/dev/null; then
            die "Не удалось смонтировать CephFS после $MOUNT_RETRIES попыток"
        fi
    else
        log INFO "CephFS уже смонтирован"
    fi

    # Проверяем, что файловая система отвечает на чтение (не "stale NFS handle" и подобное)
    if ! ls /ceph >/dev/null 2>&1; then
        die "CephFS смонтирован, но недоступен для чтения (возможно, зависание)"
    fi

    # Проверяем каждую исходную директорию отдельно
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
}

# Проверяет HTTP-доступность MinIO.
#
# Стратегия проверки (два URL, от более специфичного к более общему):
#   1. /minio/health/live  — стандартный liveness endpoint MinIO, возвращает 200 OK
#   2. /                   — корень сервера, MinIO отвечает 403 (тоже означает «жив»)
#
# ЗАМЕЧАНИЕ по %{http_code}:
#   Некоторые версии curl на старых дистрибутивах возвращают 6 цифр ("000200" вместо "200").
#   Для надёжности обрезаем строку до последних 3 символов через ${var: -3}.
check_minio_connectivity() {
    log INFO "Проверка соединения с MinIO S3: $MINIO_ENDPOINT"

    local curl_opts=(--output /dev/null --silent --insecure --max-time 10)

    local raw_code http_code

    # Попытка 1: /minio/health/live (200 = healthy)
    raw_code=$(curl "${curl_opts[@]}" --write-out "%{http_code}" \
        "${MINIO_ENDPOINT}/minio/health/live" 2>/dev/null) || raw_code="error"

    # Обрезаем до последних 3 цифр — защита от "000200" в старых curl
    http_code="${raw_code: -3}"

    if [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
        if [[ "$http_code" == "200" ]]; then
            log INFO "MinIO S3 доступен и healthy (healthcheck вернул HTTP 200)"
            return
        elif [[ "$http_code" == "000" ]]; then
            log WARNING "MinIO S3 недоступен через healthcheck (нет соединения с ${MINIO_ENDPOINT})"
        else
            log DEBUG "Healthcheck вернул HTTP $http_code, проверяем корень сервера"

            # Попытка 2: корень / (403 от MinIO тоже означает «сервер жив»)
            raw_code=$(curl "${curl_opts[@]}" --write-out "%{http_code}" \
                "${MINIO_ENDPOINT}/" 2>/dev/null) || raw_code="error"
            http_code="${raw_code: -3}"

            if [[ "$http_code" =~ ^[1-5][0-9]{2}$ ]]; then
                log INFO "MinIO S3 доступен (корень ответил HTTP $http_code)"
                return
            else
                log WARNING "MinIO S3: корень сервера вернул HTTP $http_code"
            fi
        fi
    else
        log WARNING "MinIO S3: не удалось получить HTTP-код (curl вернул: '$raw_code')"
    fi

    log WARNING "Синхронизация продолжится — rclone обработает ошибки подключения самостоятельно"
}

# Вспомогательная функция: проверяет один rclone remote и выводит диагностику при ошибке.
# FIX v4.0: вынесена из тела check_rclone_remotes — устранено загрязнение namespace функций
# при повторных вызовах check_rclone_remotes (функция переопределялась каждый раз).
_check_single_remote() {
    local remote="$1"
    local tmp_err
    tmp_err=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_err'" RETURN

    local -a nocert=()
    [[ "$RCLONE_S3_INSECURE" == "true" ]] && nocert+=(--no-check-certificate)

    # lsd выводит список бакетов/директорий корня remote.
    if ! rclone lsd "$remote" \
            --config="$RCLONE_CONFIG" \
            --contimeout=15s \
            --timeout=30s \
            "${nocert[@]}" \
            >/dev/null 2>"$tmp_err"; then

        log ERROR "Remote '$remote' недоступен. Сообщение rclone:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log ERROR "  rclone: $line"
        done < "$tmp_err"

        log ERROR "Диагностика — проверьте:"
        log ERROR "  1. Endpoint:   rclone config show ${remote%:}"
        log ERROR "  2. TLS:        если self-signed — добавьте в rclone.conf: no_check_certificate = true"
        log ERROR "  3. Сеть:       curl -vk ${MINIO_ENDPOINT}/minio/health/live"
        log ERROR "  4. Ключи S3:   access_key_id / secret_access_key в rclone.conf"
        log ERROR "  5. Права S3:   пользователь должен иметь ListBucket на корень remote"

        die "Не удалось подключиться к remote '$remote'. Синхронизация невозможна."
    fi

    log INFO "Remote '$remote' доступен"
}

# Проверяет, что rclone remote настроен и отвечает.
# Проверяем оба remote (MAIN_BACKUP и DELETE_BACKUP) — они могут теоретически различаться.
check_rclone_remotes() {
    log INFO "Проверка доступности rclone remote'ов"

    local main_remote="${MAIN_BACKUP%%:*}:"
    local delete_remote="${DELETE_BACKUP%%:*}:"

    _check_single_remote "$main_remote"

    # Проверяем DELETE remote только если он отличается от MAIN
    if [[ "$delete_remote" != "$main_remote" ]]; then
        _check_single_remote "$delete_remote"
    fi

    log INFO "Проверка rclone remote'ов завершена успешно"
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 10: ОПЕРАЦИИ С БАКЕТАМИ MINIO
# -------------------------------------------------------------------------------------------------

# Создаёт бакет если он не существует.
# FIX v4.0: используем rclone mkdir напрямую — он идемпотентен (не возвращает ошибку если
# бакет уже существует). Предыдущий подход lsd + mkdir имел TOCTOU race condition:
# между проверкой существования и созданием другой процесс мог создать бакет,
# что приводило к ложной ошибке.
create_bucket_if_needed() {
    local bucket_path="$1"

    log INFO "Проверка/создание бакета: $bucket_path"

    local -a nocert=()
    [[ "$RCLONE_S3_INSECURE" == "true" ]] && nocert+=(--no-check-certificate)

    if rclone mkdir "$bucket_path" --config="$RCLONE_CONFIG" "${nocert[@]}" 2>>"$LOGFILE"; then
        log INFO "Бакет готов: $bucket_path"
    else
        die "Не удалось создать бакет: $bucket_path"
    fi
}

# Удаляет из бакета deleted-backup файлы старше DELETE_RETENTION_DAYS дней,
# затем чистит опустевшие "псевдодиректории" (S3 prefix).
#
# ПРИМЕЧАНИЕ: rclone delete удаляет только файлы (objects), пустые prefix-директории
# в S3 нужно чистить отдельно через rclone rmdirs.
cleanup_old_deleted_data() {
    log INFO "Очистка устаревших данных из $DELETE_BACKUP (старше ${DELETE_RETENTION_DAYS} дней)"

    local -a nocert=()
    [[ "$RCLONE_S3_INSECURE" == "true" ]] && nocert+=(--no-check-certificate)

    local -a delete_cmd=(
        rclone delete "$DELETE_BACKUP"
        --min-age "${DELETE_RETENTION_DAYS}d"
        --config="$RCLONE_CONFIG"
        --log-file="$RCLONE_JSONLOG"
        --use-json-log
        --log-level="$RCLONE_LOG_LEVEL"
        --stats=30s
        "${nocert[@]}"
    )

    [[ "$DRY_RUN" == "true" ]] && { delete_cmd+=(--dry-run); log INFO "DRY_RUN: удаление симулируется"; }

    if retry_rclone_command 3 10 "${delete_cmd[@]}"; then
        log INFO "Устаревшие данные успешно удалены"
    else
        log WARNING "Очистка устаревших данных завершилась с предупреждениями"
    fi

    # Удаляем пустые "псевдодиректории" (S3 zero-byte prefix objects)
    local -a rmdir_cmd=(
        rclone rmdirs "$DELETE_BACKUP"
        --leave-root
        --config="$RCLONE_CONFIG"
        --log-file="$RCLONE_JSONLOG"
        --use-json-log
        --log-level="$RCLONE_LOG_LEVEL"
        "${nocert[@]}"
    )

    [[ "$DRY_RUN" == "true" ]] && rmdir_cmd+=(--dry-run)

    if retry_rclone_command 3 10 "${rmdir_cmd[@]}"; then
        log INFO "Пустые директории успешно удалены"
    else
        log WARNING "Удаление пустых директорий завершилось с предупреждениями"
    fi
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 11: ФУНКЦИЯ ПОВТОРНЫХ ПОПЫТОК ДЛЯ RCLONE
# -------------------------------------------------------------------------------------------------

# retry_rclone_command RETRIES DELAY CMD [ARGS...]
#
# Запускает команду rclone до RETRIES раз с паузой DELAY секунд между попытками.
# Перехватывает вывод и перелогирует построчно с соответствующим уровнем.
#
# Коды выхода rclone, которые считаем успехом:
#   0 — полный успех
#   1 — нет файлов для обработки (для delete/rmdirs это норма)
#   3 — нет изменений для передачи (sync уже актуален)
retry_rclone_command() {
    local retries="$1"
    local delay="$2"
    shift 2
    local -a cmd=("$@")

    log INFO "Подготовка к выполнению: $(printf '%q ' "${cmd[@]}")"

    # FIX v4.0: создаём temp-файл ОДИН РАЗ до цикла, обнуляем перед каждой попыткой.
    # Ранее mktemp вызывался на каждую итерацию — лишние системные вызовы.
    local tmp_output
    tmp_output=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_output'" RETURN

    local attempt rclone_exit
    for ((attempt=1; attempt<=retries; attempt++)); do
        log INFO "Попытка $attempt/$retries"

        # Обнуляем файл вывода перед каждой попыткой
        : > "$tmp_output"

        # Временно отключаем -e чтобы обработать ненулевой exit code rclone вручную
        set +e
        "${cmd[@]}" > "$tmp_output" 2>&1
        rclone_exit=$?
        set -e

        # Перелогируем вывод rclone с нужным уровнем
        while IFS= read -r line; do
            if [[ "$line" =~ (ERROR|CRITICAL|Failed|Fatal) ]]; then
                log ERROR   "rclone: $line"
            elif [[ "$line" =~ (WARNING|WARN) ]]; then
                log WARNING "rclone: $line"
            elif [[ "$DRY_RUN" == "true" || "$line" =~ (Copied|Deleted|Moved|Transferred) ]]; then
                log INFO    "rclone: $line"
            else
                log DEBUG   "rclone: $line"
            fi
        done < "$tmp_output"

        # Подкоманду ищем по позиции самого rclone, а не по фиксированному cmd[1]:
        # в v4.1.0 команда может быть обёрнута в timeout(1), и тогда cmd[1] — это
        # его флаг, а не "sync"/"delete". Прежняя проверка молча переставала
        # распознавать коды 1 и 3 и считала бы нормальные исходы ошибкой.
        local subcmd="" i
        for ((i = 0; i < ${#cmd[@]}; i++)); do
            if [[ "${cmd[i]}" == "rclone" || "${cmd[i]}" == */rclone ]]; then
                subcmd="${cmd[i+1]:-}"
                break
            fi
        done

        # Обрабатываем коды выхода
        case $rclone_exit in
            0)
                log INFO "Команда выполнена успешно (код: 0)"
                return 0
                ;;
            1)
                # Для delete/rmdirs код 1 означает «нечего удалять» — это не ошибка
                if [[ "$subcmd" == "delete" || "$subcmd" == "rmdirs" ]]; then
                    log INFO "Команда завершена: нет файлов для обработки (код: 1)"
                    return 0
                fi
                ;;
            3)
                # Для sync код 3 означает «нет изменений» — destination уже актуален
                if [[ "$subcmd" == "sync" ]]; then
                    log INFO "Синхронизация завершена: нет изменений (код: 3)"
                    return 0
                fi
                ;;
            124|137)
                # timeout(1): 124 — TERM по истечении срока, 137 — 128+KILL.
                # Ретраить бессмысленно: упрёмся в тот же лимит.
                log ERROR "Превышен таймаут ${DIR_TIMEOUT} на директорию — попытки прекращены (код: $rclone_exit)"
                SYNC_SUCCESS=false
                return "$rclone_exit"
                ;;
        esac

        if ((attempt < retries)); then
            log WARNING "Попытка $attempt неуспешна (код: $rclone_exit). Повтор через $delay сек"
            sleep "$delay"
        else
            log ERROR "Все $retries попыток исчерпаны. Финальный код: $rclone_exit"
            SYNC_SUCCESS=false
            return $rclone_exit
        fi
    done
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 12: СИНХРОНИЗАЦИЯ ДИРЕКТОРИИ
# -------------------------------------------------------------------------------------------------

# perform_directory_sync SOURCE_DIR
#
# Синхронизирует одну исходную директорию CephFS в MinIO S3.
#
# Флаг --backup-dir="minio:deleted-backup/YYYY-MM-DD/relative_path" означает:
#   файлы, которые есть в destination, но отсутствуют в source, НЕ удаляются,
#   а перемещаются в backup-dir. Это обеспечивает защиту от случайного удаления.
#
# Относительный путь вычисляется через strip /ceph/data/, что корректно обрабатывает
# все директории независимо от суффикса (/nbics/, /bio/ и т.д.):
#   /ceph/data/nbics/Reads            → nbics/Reads
#   /ceph/data/bio/nextcloud/data/... → bio/nextcloud/data/...
perform_directory_sync() {
    local source_dir="$1"

    log INFO "=== НАЧАЛО СИНХРОНИЗАЦИИ ДИРЕКТОРИИ: $source_dir ==="

    # Двойная проверка доступности — на случай изменений после начальной валидации
    if [[ ! -d "$source_dir" ]]; then
        log ERROR "Исходная директория не существует: $source_dir"
        SYNC_SUCCESS=false
        return 1
    fi

    local relative_path="${source_dir#/ceph/data/}"
    local target_path="$MAIN_BACKUP/$relative_path"

    log INFO "Источник:    $source_dir"
    log INFO "Назначение:  $target_path"

    # Путь для удалённых файлов: deleted-backup/YYYY-MM-DD/relative_path
    local backup_date
    backup_date="$(date +%Y-%m-%d)"
    local backup_dir="$DELETE_BACKUP/$backup_date/$relative_path"

    log INFO "Бакет удалённых: $backup_dir"

    # Формируем массив аргументов rclone sync
    # timeout(1) снаружи: одна директория не должна съедать прогон целиком.
    # --kill-after даёт rclone шанс завершиться по TERM, затем добивает KILL.
    local -a sync_cmd=(
        timeout --kill-after=60s "$DIR_TIMEOUT"
        rclone sync
        --config="$RCLONE_CONFIG"

        # Копировать симлинки как специальные объекты (не следовать по ним).
        # ВНИМАНИЕ: если симлинки ссылаются за пределы /ceph — rclone попытается
        # прочитать цель. Проверьте наличие внешних симлинков:
        #   find /ceph/data -type l -not -lname '/ceph/*'
        --links

        # fast-list: один LIST-запрос вместо множества — ускоряет работу с S3
        --fast-list

        # Создавать пустые директории в destination
        --create-empty-src-dirs

        # ВНИМАНИЕ: --checksum добавляется ниже условно, по SYNC_MODE (v4.1.0).
        # Флаг --update остаётся убранным (см. v4.0): вместе с --checksum он
        # молча пропускал изменённые файлы, если mtime назначения новее источника.

        --transfers="$RCLONE_TRANSFERS"
        --checkers="$RCLONE_CHECKERS"
        --retries="$RCLONE_RETRIES"
        --retries-sleep="$RCLONE_RETRIES_SLEEP"
        --buffer-size="$RCLONE_BUFFER_SIZE"

        # Ключевой флаг безопасности: вместо удаления файлов перемещать их в backup-dir
        --backup-dir="$backup_dir"

        # Структурированный JSON-лог для машинного разбора
        --use-json-log
        --log-file="$RCLONE_JSONLOG"
        --log-level="$RCLONE_LOG_LEVEL"

        --stats=5m
        --stats-log-level=NOTICE

        # Потолок запросов к S3 в секунду — бережём MinIO от лавины обращений.
        --tpslimit="$RCLONE_TPSLIMIT"
        --tpslimit-burst="$RCLONE_TPSLIMIT_BURST"
    )

    # --checksum только в еженедельном прогоне: для CephFS→S3 он требует
    # вычитать каждый файл с CephFS ради хеша, и именно это делало прогоны
    # многодневными. В режиме fast сверяем размер и время модификации.
    if [[ "$SYNC_MODE" == "checksum" ]]; then
        sync_cmd+=(--checksum)
        log INFO "Режим сверки: checksum (полная проверка, медленно)"
    else
        log INFO "Режим сверки: fast (размер + время модификации)"
    fi

    # FIX v4.0: --progress только при интерактивном запуске (stdout — терминал).
    # При запуске через cron stdout не является TTY — ANSI escape-коды засоряли
    # cron-письма нечитаемыми символами управления.
    [[ -t 1 ]] && sync_cmd+=(--progress)

    # Отключение TLS-проверки при self-signed сертификате MinIO
    if [[ "$RCLONE_S3_INSECURE" == "true" ]]; then
        sync_cmd+=(--no-check-certificate)
        log WARNING "TLS-проверка отключена (RCLONE_S3_INSECURE=true) — уязвимость к MITM!"
    fi

    # В режиме dry-run добавляем флаг — rclone покажет что сделал бы, без изменений
    if [[ "$DRY_RUN" == "true" ]]; then
        sync_cmd+=(--dry-run)
        log INFO "Режим DRY_RUN активен: реальных изменений не будет"
    fi

    # Добавляем источник и назначение последними аргументами
    sync_cmd+=("$source_dir" "$target_path")

    # Запускаем синхронизацию и замеряем время
    local start_time end_time duration
    start_time=$(date +%s)

    if retry_rclone_command 3 15 "${sync_cmd[@]}"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        log INFO "Синхронизация завершена успешно"
        log INFO "Время выполнения: $(printf '%d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))"
        log INFO "=== КОНЕЦ СИНХРОНИЗАЦИИ ДИРЕКТОРИИ: $source_dir ==="
        # FIX v4.0: постфиксный ++ при SYNC_SUCCESSFUL=0 возвращает falsy exit code (0
        # как значение выражения), что при set -e может вызвать неожиданный выход.
        # Явное присваивание всегда безопасно.
        SYNC_SUCCESSFUL=$((SYNC_SUCCESSFUL + 1))
        return 0
    else
        log ERROR "Синхронизация завершилась с ошибкой: $source_dir"
        log INFO "=== КОНЕЦ СИНХРОНИЗАЦИИ ДИРЕКТОРИИ (ОШИБКА): $source_dir ==="
        return 1
    fi
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 13: ИТОГОВАЯ СВОДКА
# -------------------------------------------------------------------------------------------------

# Формирует и записывает итоговую сводку в SUMMARY_FILE и в stderr.
# Вызывается из cleanup_resources при любом завершении скрипта.
#
# Аргумент: $1 — exit code процесса (передаётся из cleanup_resources).
generate_final_summary() {
    local final_exit_code="${1:-0}"
    log INFO "Генерация итоговой сводки (exit code: $final_exit_code)"

    local overall_result
    if ((final_exit_code != 0)); then
        if ((SYNC_SUCCESSFUL > 0)); then
            overall_result="PARTIAL_SUCCESS"
        else
            overall_result="FAILURE"
        fi
    elif [[ "$SYNC_SUCCESS" == "true" && "$VALIDATION_FAILED" == "false" ]]; then
        overall_result="SUCCESS"
    elif ((SYNC_SUCCESSFUL > 0)); then
        overall_result="PARTIAL_SUCCESS"
    else
        overall_result="FAILURE"
    fi

    {
        echo "================================================================================"
        echo "           ИТОГОВАЯ СВОДКА СИНХРОНИЗАЦИИ CEPHFS ➜ MINIO S3"
        echo "================================================================================"
        echo
        printf "Время завершения:          %s\n" "$(date)"
        printf "Общий результат:           %s\n" "$overall_result"
        printf "Версия скрипта:            %s\n" "$SCRIPT_VERSION"
        printf "Пользователь:              %s\n" "$(whoami)"
        printf "Хост:                      %s\n" "$(hostname -f 2>/dev/null || hostname)"
        printf "Режим DRY_RUN:             %s\n" "$DRY_RUN"
        echo
        echo "--------------------------------------------------------------------------------"
        echo "КОНФИГУРАЦИЯ:"
        echo "--------------------------------------------------------------------------------"
        printf "MinIO endpoint:            %s\n" "$MINIO_ENDPOINT"
        printf "Основной бакет:            %s\n" "$MAIN_BACKUP"
        printf "Бакет удалённых файлов:    %s\n" "$DELETE_BACKUP"
        printf "Retention удалений:        %s дней\n" "$DELETE_RETENTION_DAYS"
        printf "Параллельные передачи:     %s\n" "$RCLONE_TRANSFERS"
        printf "Потоки проверки:           %s\n" "$RCLONE_CHECKERS"
        printf "Повторных попыток:         %s\n" "$RCLONE_RETRIES"
        printf "Размер буфера:             %s\n" "$RCLONE_BUFFER_SIZE"
        echo
        echo "--------------------------------------------------------------------------------"
        echo "РЕЗУЛЬТАТЫ:"
        echo "--------------------------------------------------------------------------------"
        printf "Директорий к обработке:    %s\n" "$SYNC_PROCESSED"
        printf "Успешно синхронизировано:  %s\n" "$SYNC_SUCCESSFUL"
        printf "С ошибками:                %s\n" "$((SYNC_PROCESSED - SYNC_SUCCESSFUL))"
        echo
        echo "--------------------------------------------------------------------------------"
        echo "МАППИНГ ДИРЕКТОРИЙ:"
        echo "--------------------------------------------------------------------------------"
        for dir in "${SOURCEDIRS_ARRAY[@]}"; do
            local relative_path="${dir#/ceph/data/}"
            printf "  %s\n    ➜ %s/%s\n" "$dir" "$MAIN_BACKUP" "$relative_path"
        done
        echo
        echo "--------------------------------------------------------------------------------"
        echo "ФАЙЛЫ ЛОГОВ:"
        echo "--------------------------------------------------------------------------------"
        printf "Основной лог:              %s\n" "$LOGFILE"
        printf "JSON лог rclone:           %s\n" "$RCLONE_JSONLOG"
        printf "Итоговая сводка:           %s\n" "$SUMMARY_FILE"
        echo
        echo "================================================================================"
    } | tee -a "$LOGFILE" > "$SUMMARY_FILE"

    # Дублируем сводку в stderr чтобы она попала в вывод cron
    cat "$SUMMARY_FILE" >&2

    log INFO "Итоговая сводка сохранена: $SUMMARY_FILE"
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 14: ГЛАВНАЯ ФУНКЦИЯ
# -------------------------------------------------------------------------------------------------

main() {
    # ------------------------------------------------------------------
    # ЭТАП 1: Инициализация и проверки окружения
    # ------------------------------------------------------------------
    log INFO "ЭТАП 1: Инициализация системы и проверка окружения"
    initialize_logging
    rotate_old_logs
    check_required_commands
    check_rclone_version
    check_rclone_config
    validate_source_directories
    setup_locking_and_signals

    # ------------------------------------------------------------------
    # ЭТАП 2: Проверка доступности хранилищ
    # ------------------------------------------------------------------
    log INFO "ЭТАП 2: Проверка доступности систем хранения"
    check_cephfs_availability
    check_minio_connectivity
    check_rclone_remotes

    # ------------------------------------------------------------------
    # ЭТАП 3: Подготовка бакетов MinIO
    # ------------------------------------------------------------------
    log INFO "ЭТАП 3: Подготовка инфраструктуры MinIO S3"
    create_bucket_if_needed "$MAIN_BACKUP"
    create_bucket_if_needed "$DELETE_BACKUP"
    cleanup_old_deleted_data

    # ------------------------------------------------------------------
    # ЭТАП 4: Синхронизация директорий
    # ------------------------------------------------------------------
    log INFO "ЭТАП 4: Выполнение синхронизации директорий"
    log INFO "Всего директорий для обработки: ${#SOURCEDIRS_ARRAY[@]}"

    SYNC_PROCESSED=${#SOURCEDIRS_ARRAY[@]}

    # Обрабатываем каждую директорию последовательно.
    # Ошибка в одной директории НЕ прерывает обработку остальных.
    for source_dir in "${SOURCEDIRS_ARRAY[@]}"; do
        log INFO "--- Начало обработки: $source_dir ---"
        if perform_directory_sync "$source_dir"; then
            log INFO "--- Успешно: $source_dir ---"
        else
            log ERROR "--- Ошибка при обработке: $source_dir ---"
        fi
    done

    # ------------------------------------------------------------------
    # ЭТАП 5: Подведение итогов
    # ------------------------------------------------------------------
    log INFO "ЭТАП 5: Анализ результатов синхронизации"
    log INFO "Обработано директорий: $SYNC_PROCESSED"
    log INFO "Успешно:               $SYNC_SUCCESSFUL"
    log INFO "С ошибками:            $((SYNC_PROCESSED - SYNC_SUCCESSFUL))"

    if ((SYNC_SUCCESSFUL == SYNC_PROCESSED)); then
        if [[ "$VALIDATION_FAILED" == "false" ]]; then
            log SUCCESS "ВСЕ ОПЕРАЦИИ СИНХРОНИЗАЦИИ ВЫПОЛНЕНЫ УСПЕШНО"
        else
            log WARNING "СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА С ПРЕДУПРЕЖДЕНИЯМИ (проблемы валидации)"
        fi
        return 0
    elif ((SYNC_SUCCESSFUL > 0)); then
        log WARNING "СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА ЧАСТИЧНО ($SYNC_SUCCESSFUL из $SYNC_PROCESSED директорий)"
        return 0
    else
        log ERROR "СИНХРОНИЗАЦИЯ ЗАВЕРШЕНА С КРИТИЧЕСКИМИ ОШИБКАМИ — НИ ОДНА ДИРЕКТОРИЯ НЕ СИНХРОНИЗИРОВАНА"
        return 1
    fi
}

# -------------------------------------------------------------------------------------------------
# РАЗДЕЛ 15: ТОЧКА ВХОДА
# -------------------------------------------------------------------------------------------------

# Запускаем main только при прямом выполнении скрипта.
# Если скрипт загружен через `source`, функции становятся доступны без запуска main —
# это полезно для тестирования отдельных функций.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit_code=$?

    if ((exit_code == 0)); then
        if ((SYNC_SUCCESSFUL == SYNC_PROCESSED && SYNC_PROCESSED > 0)); then
            log SUCCESS "=== СКРИПТ ЗАВЕРШЁН ПОЛНОСТЬЮ УСПЕШНО ==="
        elif ((SYNC_SUCCESSFUL > 0)); then
            log WARNING "=== СКРИПТ ЗАВЕРШЁН ЧАСТИЧНО УСПЕШНО ($SYNC_SUCCESSFUL/$SYNC_PROCESSED) ==="
        else
            log WARNING "=== СКРИПТ ЗАВЕРШЁН БЕЗ УСПЕШНЫХ ОПЕРАЦИЙ ==="
        fi
    else
        log ERROR "=== СКРИПТ ЗАВЕРШЁН С КРИТИЧЕСКИМИ ОШИБКАМИ (КОД: $exit_code) ==="
    fi

    exit $exit_code
else
    log INFO "Скрипт загружен через source — функции доступны для использования"
fi
