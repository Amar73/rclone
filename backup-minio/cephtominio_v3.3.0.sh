#!/usr/local/bin/bash
# =================================================================================================
# cephtominio_v3.3.1.sh — репликация Ceph RADOS Gateway S3 ➜ MinIO S3 через rclone
#
# Автор оригинала: Андрей Марьяненко (ведущий инженер)
# Платформа: FreeBSD 14.2, bash (/usr/local/bin/bash — GNU Bash из портов, не /bin/sh)
#
# ─── АРХИТЕКТУРА РЕШЕНИЯ ──────────────────────────────────────────────────────────────────────
#
#  Источник: Ceph RADOS Gateway (S3-совместимый эндпоинт), настроен как один или несколько
#            remote'ов в rclone.conf (например: test:, backup:, registry: и т.д.)
#
#  Назначение: MinIO S3, настроен как remote «minio» в rclone.conf.
#              Структура пути назначения: minio:<имя_источника_remote>/<имя_бакета>/
#              Пример: test:nbgi-db-public → minio:test/nbgi-db-public/
#
#  Удалённые/перезаписанные объекты не теряются — они складываются в «версионное хранилище»:
#              minio:backup-deleted/YYYY-MM-DD/<remote>/<bucket>/
#              Объекты там хранятся $DELETE_RETENTION_DAYS дней, затем удаляются.
#
#  Параллелизм: каждый бакет обрабатывается отдельным процессом bash через xargs -P.
#               Количество параллельных процессов задаётся переменной PARALLEL.
#               Каждый дочерний процесс наследует экспортированные функции и переменные.
#
# ─── КЛЮЧЕВЫЕ ОСОБЕННОСТИ ─────────────────────────────────────────────────────────────────────
#
#  ✔ Строгий режим: set -eEuo pipefail, явный IFS, umask 027
#  ✔ Безопасная блокировка через flock(1) — защита от двойного запуска
#  ✔ Корректные trap'ы: EXIT, INT, TERM, HUP
#  ✔ Параллельная обработка бакетов (xargs -P $PARALLEL)
#  ✔ Логирование: человекочитаемый .log + JSON-лог rclone (.jsonl) с ротацией
#  ✔ Версионирование удалений: --backup-dir + ретеншн-очистка
#  ✔ Потокобезопасная запись статуса через flock на отдельный lock-файл
#  ✔ Надёжная функция retry_rclone без pipe в критическом пути (фикс PIPESTATUS)
#  ✔ Быстрая валидация через rclone size --json вместо полного lsf
#  ✔ Проверка состояния Ceph-кластера через SSH (мягкая, не блокирует запуск)
#  ✔ Полная настраиваемость через ENV и/или CLI-флаги
#
# ─── БЫСТРЫЙ СТАРТ ────────────────────────────────────────────────────────────────────────────
#
#   # Тестовый прогон — ничего не меняет, показывает что будет сделано:
#   DRY_RUN=true ./cephtominio_v3.3.0.sh
#
#   # Рабочий запуск с 4 параллельными процессами и валидацией:
#   ./cephtominio_v3.3.0.sh --op=sync --parallel=4 --validate=counts
#
#   # Только конкретные бакеты:
#   ./cephtominio_v3.3.0.sh --buckets="test:bucket1 registry:docker-registry"
#
# ─── ТРЕБОВАНИЯ ───────────────────────────────────────────────────────────────────────────────
#
#   rclone >= 1.60 (поддержка --backup-dir, --use-json-log, --fast-list)
#   flock(1)  — pkg install util-linux (FreeBSD) или системный flock
#   awk, xargs, date, ssh (опционально, для проверки Ceph)
#   bash >= 4.0 (/usr/local/bin/bash из портов FreeBSD)
#
# ─── ЖУРНАЛ ИЗМЕНЕНИЙ ─────────────────────────────────────────────────────────────────────────
#
#  v3.3.1 (текущая):
#    - ИСПРАВЛЕНО: count_objects — в awk-разделителе отсутствовал «:», из-за чего
#      $(i+2) указывал на пустое поле, и функция всегда возвращала 0.
#      validate_pair_counts молча пропускала расхождения (0==0 → OK). Добавлен «:».
#    - ИСПРАВЛЕНО: check_ceph_status_soft — команда передаётся через «bash -s <<<»
#      вместо «bash -c "$var"»; устраняет двойное раскрытие переменной локальным shell.
#    - ИСПРАВЛЕНО: StrictHostKeyChecking=no → accept-new; предотвращает MITM-атаку.
#    - УЛУЧШЕНО: retry_rclone — «seq» заменён на арифметический цикл; нет subprocess.
#    - УЛУЧШЕНО: cmd_str — O(n²) конкатенация строк заменена на массив (линейная).
#    - УЛУЧШЕНО: rotate_logs — 4 вызова find объединены в один.
#
#  v3.3.0:
#    - ИСПРАВЛЕНО: retry_rclone — убран pipe из критического пути; вывод rclone пишется
#      во временный файл, затем читается. Это устраняет ненадёжное чтение PIPESTATUS.
#    - ИСПРАВЛЕНО: LOGFILE добавлен в export — теперь дочерние процессы xargs корректно
#      пишут в лог-файл вместо молчаливого пропуска записей.
#    - ИСПРАВЛЕНО: check_ceph_status_soft — команда теперь передаётся SSH правильно
#      через «bash -c», иначе строка с пробелами воспринималась как имя бинарника.
#    - ИСПРАВЛЕНО: on_signal — код возврата теперь сохраняется явно в EXIT_CODE,
#      чтобы cleanup() не получал ec=0 (last cmd была «ALL_OK=false» → успех).
#    - ИСПРАВЛЕНО: append_status — lock-файл открывается на запись (>), а не на
#      дозапись (>>), чтобы файл не рос бесконечно между запусками.
#    - ИСПРАВЛЕНО: cleanup() теперь удаляет и STATUS_FILE.lock (мусорный lock-файл).
#    - УЛУЧШЕНО: count_files заменён на rclone size --json — быстрее на больших бакетах,
#      не перечисляет все объекты, а получает агрегат напрямую.
#    - УЛУЧШЕНО: create_bucket_if_absent — mkdir теперь с «|| true» для защиты от
#      TOCTOU race condition при параллельном запуске.
#    - УЛУЧШЕНО: BUCKETS_ENV разбирается через «read -ra» вместо небезопасного $().
#    - УЛУЧШЕНО: rclone JSONL-логи пишутся в отдельный файл на каждый бакет,
#      а не в общий — устранена гонка при параллельной записи.
#    - УЛУЧШЕНО: JSONL-файлы по бакетам собираются в итоговый файл в generate_summary().
#
#  v3.2.1:
#    - Убран некорректный разделитель "--" в retry_rclone
#    - Экспорт переменных для параллельных процессов
#    - Обработка ошибок в process_bucket
#    - Восстановлена проверка состояния Ceph через SSH
#
# =================================================================================================

# ──────────────────────────────────────────────────────────────────────────────
# 1. СТРОГИЙ РЕЖИМ И БАЗОВАЯ ГИГИЕНА ОКРУЖЕНИЯ
# ──────────────────────────────────────────────────────────────────────────────
#
# set -e  : выход при любой ошибке команды
# set -E  : trap ERR наследуется функциями и подоболочками
# set -u  : ошибка при обращении к неустановленной переменной
# set -o pipefail : код возврата пайплайна = код последней упавшей команды
#
# Без этих флагов ошибки в середине скрипта могут замалчиваться и приводить
# к молчаливой неполной репликации.
set -eEuo pipefail

# IFS ограничен только переносом строки и табуляцией.
# Это защищает от случайного разбиения строк по пробелам при word splitting.
IFS=$'\n\t'

# umask 027: создаваемые файлы (логи, lock) не читаемы для «других» пользователей.
# Лог-файлы могут содержать имена бакетов и пути — не стоит давать общий доступ.
umask 027

# Нейтральная локаль: предотвращает проблемы с многобайтовыми символами
# в именах файлов, выводе команд и сортировке.
export LANG=C LC_ALL=C

# ──────────────────────────────────────────────────────────────────────────────
# 2. МЕТАДАННЫЕ СКРИПТА
# ──────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="3.3.1"

# Минимально допустимая версия rclone.
# Версии ниже 1.60 не имеют --use-json-log и ненадёжно поддерживают --backup-dir.
readonly REQUIRED_RCLONE_VERSION="1.60"

# ──────────────────────────────────────────────────────────────────────────────
# 3. КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ
#    Каждую переменную можно переопределить через ENV или CLI-флаги.
#    Синтаксис «: "${VAR:=default}"» устанавливает значение только если VAR не задана.
# ──────────────────────────────────────────────────────────────────────────────

# Директория для хранения лог-файлов.
# Создаётся автоматически при старте скрипта.
: "${LOGDIR:=/var/log/rclone-sync}"

# Файл блокировки — защита от одновременного запуска двух копий скрипта.
# flock(1) обеспечивает атомарную блокировку на уровне ОС.
: "${LOCKFILE:=/var/lock/s3_sync_buckets.lock}"

# Путь к конфигурационному файлу rclone.
# Содержит учётные данные для Ceph RGW и MinIO.
# Должен иметь права 600 (только для владельца).
: "${RCLONE_CONFIG:=/root/.config/rclone/rclone.conf}"

# Количество одновременно обрабатываемых бакетов.
# Каждый бакет = отдельный процесс bash + rclone.
# Не путать с --transfers внутри одного rclone-процесса.
# Рекомендуется: 2–8. При большем значении возрастает нагрузка на Ceph RGW.
: "${PARALLEL:=4}"

# Операция rclone для синхронизации:
#   sync — полная синхронизация, удалённые в источнике объекты «удаляются» и в dest
#           (но перед удалением сохраняются в --backup-dir = версионирование)
#   copy — только копирование новых/изменённых объектов, без удаления в dest
: "${OPERATION:=sync}"

# Тестовый режим. При DRY_RUN=true rclone не вносит никаких изменений.
# Используйте для проверки логики перед первым рабочим запуском.
: "${DRY_RUN:=false}"

# Срок хранения (в днях) объектов в директории backup-deleted.
# Объекты старше этого срока будут удалены при очередном запуске.
: "${DELETE_RETENTION_DAYS:=30}"

# Режим валидации результата после синхронизации каждого бакета:
#   none   — не валидировать (быстрее, меньше нагрузка)
#   counts — сравнить количество объектов в источнике и назначении
#             (использует rclone size --json — быстро, без полного перечисления)
: "${VALIDATE_MODE:=counts}"

# ── Настройки производительности rclone ──────────────────────────────────────

# Количество параллельных передач файлов внутри одного rclone-процесса.
# Для S3-to-S3 (server-side copy) можно ставить высокие значения.
: "${RCLONE_TRANSFERS:=32}"

# Количество параллельных чекеров (потоков, проверяющих нужно ли копировать файл).
: "${RCLONE_CHECKERS:=16}"

# Число попыток при временных ошибках сети/S3.
: "${RCLONE_RETRIES:=7}"

# Пауза между попытками rclone (форматы: 10s, 1m, 30s).
: "${RCLONE_RETRIES_SLEEP:=10s}"

# Интервал вывода статистики rclone в лог.
: "${RCLONE_STATS_INTERVAL:=60s}"

# Уровень логирования rclone: DEBUG, INFO, NOTICE, ERROR.
: "${RCLONE_LOG_LEVEL:=INFO}"

# Размер буфера в памяти для файлов при передаче.
: "${RCLONE_BUFFER_SIZE:=16M}"

# Использовать mmap для буферизации вместо malloc.
# Снижает фрагментацию памяти при долгой работе.
: "${RCLONE_USE_MMAP:=true}"

# Параллелизм загрузки частей multipart upload на стороне S3.
: "${RCLONE_S3_UPLOAD_CONCURRENCY:=32}"

# Размер чанка multipart upload. Увеличьте до 128M–512M для объектов > 10 ГБ.
: "${RCLONE_S3_CHUNK_SIZE:=64M}"

# Отключить проверку TLS-сертификата.
# ВНИМАНИЕ: использовать только в изолированных тестовых окружениях!
: "${RCLONE_S3_INSECURE:=false}"

# ── Проверка состояния Ceph-кластера ─────────────────────────────────────────

# SSH-хост, на котором выполняется команда проверки Ceph.
# Должен быть доступен по ключу (BatchMode=yes, без пароля).
: "${CEPH_STATUS_SSH_HOST:=svc02}"

# Команда, выполняемая на удалённом хосте для проверки статуса кластера.
# Через podman/docker exec для контейнеризированного ceph-mon.
: "${CEPH_STATUS_SSH_CMD:=podman exec ceph-mon-svc02 ceph status}"

# ── Директория версионирования удалений ──────────────────────────────────────

# Корневой путь в MinIO для хранения версий удалённых/перезаписанных объектов.
# rclone при sync автоматически перемещает туда объекты через --backup-dir.
: "${DELETE_BACKUP_ROOT:=minio:backup-deleted}"

# ── Источники списка бакетов ──────────────────────────────────────────────────

# Файл со списком бакетов (по одному на строку, формат: remote:bucket).
# Строки начинающиеся с # — комментарии, пустые строки — игнорируются.
: "${BUCKETS_FILE:=}"

# Список бакетов через пробел, переданный в ENV или через --buckets="...".
# Формат: "remote1:bucket1 remote2:bucket2"
: "${BUCKETS_ENV:=}"

# Встроенный список бакетов по умолчанию.
# Используется если не задан ни BUCKETS_FILE, ни BUCKETS_ENV.
# Формат каждого элемента: "<имя_remote_в_rclone.conf>:<имя_бакета>"
DEFAULT_BUCKETS=(
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

# ──────────────────────────────────────────────────────────────────────────────
# 4. ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ РАНТАЙМА
#    Инициализируются в init_logging(), используются по всему скрипту.
# ──────────────────────────────────────────────────────────────────────────────

RUN_TS=""          # Метка времени запуска (YYYY-MM-DD_HH-MM-SS)
LOGFILE=""         # Путь к текстовому лог-файлу текущего запуска
RCLONE_JSONLOG=""  # Путь к итоговому JSONL-лог-файлу (собирается из бакетных логов)
SUMMARY_TXT=""     # Путь к файлу итоговой сводки
STATUS_FILE=""     # Путь к TSV-файлу статусов по бакетам (remote:bucket → OK/FAIL)

# Глобальный флаг успеха. Устанавливается в false при любой ошибке бакета.
ALL_OK=true

# Код завершения для trap'а при получении сигнала (INT/TERM/HUP).
# Отдельная переменная нужна потому, что последняя выполненная команда
# перед вызовом cleanup() может быть успешной (ec=0), даже если мы
# завершаемся по сигналу. Сохраняем явно.
EXIT_CODE=0

# Массив бакетов для обработки (заполняется в load_buckets).
BUCKETS=()

# Файловый дескриптор для flock (назначается в setup_lock_and_traps).
LOCK_FD=""

# ──────────────────────────────────────────────────────────────────────────────
# 5. УТИЛИТЫ: ЛОГИРОВАНИЕ, DIE, ЭКРАНИРОВАНИЕ КОМАНД
# ──────────────────────────────────────────────────────────────────────────────

# log <LEVEL> <сообщение>
#
# Выводит сообщение в stderr (с цветом, если это терминал) и в лог-файл.
# Уровни: DEBUG, INFO, WARNING, ERROR, CRITICAL.
# Временная метка добавляется только в файл (не в stderr — для читаемости).
log() {
  local level="${1:-INFO}"
  shift || true
  local msg="${*:-}"
  local ts
  ts="$(date -Iseconds)"

  # Цветовое выделение уровней при выводе в терминал (ANSI escape codes).
  # Проверяем дескриптор 2 (stderr) — fd 1 может быть перенаправлен в файл.
  local color=""
  if [[ -t 2 ]]; then
    case "$level" in
      DEBUG)    color=$'\033[36m'    ;;  # Голубой
      INFO)     color=$'\033[32m'    ;;  # Зелёный
      WARNING)  color=$'\033[33m'    ;;  # Жёлтый
      ERROR)    color=$'\033[31m'    ;;  # Красный
      CRITICAL) color=$'\033[35;1m'  ;;  # Пурпурный жирный
    esac
  fi

  # Вывод в stderr с цветом (если терминал) или без.
  if [[ -n "$color" ]]; then
    printf '%s[%s] %s\033[0m\n' "$color" "$level" "$msg" >&2
  else
    printf '[%s] %s\n' "$level" "$msg" >&2
  fi

  # Запись в лог-файл (без цветовых кодов, с временной меткой).
  # LOGFILE может быть не инициализирован в самом начале — проверяем.
  if [[ -n "${LOGFILE:-}" ]]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOGFILE"
  fi
}

# die <сообщение>
# Логирует ошибку и завершает скрипт с кодом 1.
# Используется для фатальных ошибок, после которых продолжение невозможно.
die() {
  log ERROR "$*"
  exit 1
}

# cmd_str <команда> [аргументы...]
# Возвращает строку с безопасно экранированными аргументами команды.
# Используется для логирования командных строк перед их выполнением.
# Пример: cmd_str rclone sync "a:b" "c:d" → "rclone sync a:b c:d"
cmd_str() {
  local -a parts=()
  local arg
  for arg in "$@"; do
    parts+=( "$(printf '%q' "$arg")" )
  done
  printf '%s' "${parts[*]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. ИНИЦИАЛИЗАЦИЯ ЛОГОВ И РОТАЦИЯ
# ──────────────────────────────────────────────────────────────────────────────

# init_logging
# Создаёт директорию логов и инициализирует пути к файлам текущего запуска.
# Вызывается один раз в самом начале main().
init_logging() {
  RUN_TS="$(date +'%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$LOGDIR" || die "Не удалось создать LOGDIR=$LOGDIR"

  # Каждый запуск создаёт уникальный набор файлов с меткой времени в имени.
  local base="${LOGDIR}/${SCRIPT_NAME%.sh}_${RUN_TS}"
  LOGFILE="${base}.log"
  # Итоговый JSONL-файл собирается из per-bucket логов в generate_summary().
  RCLONE_JSONLOG="${base}.jsonl"
  SUMMARY_TXT="${base}.summary.txt"
  STATUS_FILE="${base}.status.tsv"

  # Создаём пустые файлы (инициализируем для дальнейшего накопления).
  : > "$LOGFILE"
  : > "$STATUS_FILE"
  # JSONL создаётся позже в generate_summary(), здесь не нужен.

  log INFO "Старт $SCRIPT_NAME v$SCRIPT_VERSION"
  log INFO "Логи: $LOGFILE"
  log INFO "JSON rclone: $RCLONE_JSONLOG (будет собран из per-bucket файлов)"
}

# rotate_logs
# Удаляет файлы логов старше 30 дней.
# Вызывается после init_logging(), чтобы не удалить только что созданные файлы.
# В production рекомендуется вынести ротацию в newsyslog.conf или отдельный cron.
rotate_logs() {
  log INFO "Ротация логов старше 30 дней в $LOGDIR"
  # «|| true» чтобы ошибка find (например, нет прав) не прервала скрипт.
  find "$LOGDIR" -type f \( \
    -name "${SCRIPT_NAME%.sh}_*.log"         -o \
    -name "${SCRIPT_NAME%.sh}_*.jsonl"       -o \
    -name "${SCRIPT_NAME%.sh}_*.summary.txt" -o \
    -name "${SCRIPT_NAME%.sh}_*.status.tsv"  \
  \) -mtime +30 -delete 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. ПРОВЕРКА ОКРУЖЕНИЯ: КОМАНДЫ, ВЕРСИЯ RCLONE, КОНФИГ
# ──────────────────────────────────────────────────────────────────────────────

# check_commands
# Проверяет наличие всех требуемых утилит. Завершает скрипт если хоть одна отсутствует.
check_commands() {
  local miss=()
  local need=(rclone flock awk xargs date)
  local c
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if (( ${#miss[@]} > 0 )); then
    die "Отсутствуют требуемые команды: ${miss[*]}"
  fi
  log INFO "Все необходимые команды найдены: ${need[*]}"
}

# check_rclone_version
# Сравнивает версию установленного rclone с минимально допустимой.
# Выдаёт WARNING вместо die — скрипт продолжит работу, но это нежелательно.
# При использовании функций, введённых в 1.60+, старая версия молча не сработает.
check_rclone_version() {
  local v
  v="$(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//')" || v="0.0"

  local req_major req_minor cur_major cur_minor
  IFS='.' read -r req_major req_minor _ <<< "$REQUIRED_RCLONE_VERSION"
  IFS='.' read -r cur_major cur_minor _ <<< "$v"

  if (( cur_major < req_major || (cur_major == req_major && cur_minor < req_minor) )); then
    log WARNING "Рекомендуется rclone >= $REQUIRED_RCLONE_VERSION, установлена: $v. Возможны проблемы!"
  else
    log INFO "Версия rclone: $v — OK (требуется >= $REQUIRED_RCLONE_VERSION)"
  fi
}

# check_rclone_config
# Проверяет существование конфига и предупреждает о небезопасных правах.
# Конфиг содержит ключи доступа — должен быть доступен только root (600).
check_rclone_config() {
  [[ -f "$RCLONE_CONFIG" ]] || die "rclone.conf не найден: $RCLONE_CONFIG"

  # stat -f %Sp — FreeBSD синтаксис (аналог Linux stat -c %A).
  local perms
  perms="$(stat -f %Sp "$RCLONE_CONFIG" 2>/dev/null || echo "")"
  if [[ "$perms" != "-rw-------" ]]; then
    log WARNING "Небезопасные права на $RCLONE_CONFIG (текущие: $perms). Рекомендуется: chmod 600"
  else
    log INFO "Права на rclone.conf: OK ($perms)"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. БЛОКИРОВКА И TRAP'Ы
# ──────────────────────────────────────────────────────────────────────────────

# cleanup
# Финальный обработчик выхода — вызывается автоматически при любом завершении
# скрипта (нормальном, по ошибке или сигналу) через «trap cleanup EXIT».
# Освобождает flock, удаляет lock-файлы, логирует итоговый статус.
cleanup() {
  # Используем явно сохранённый EXIT_CODE, а не $? текущей команды.
  # Причина: последней командой перед выходом по сигналу могла быть успешная
  # команда (например, «ALL_OK=false»), что дало бы $? == 0 — неверно.
  local ec="${EXIT_CODE:-$?}"

  # Освобождаем flock через явное снятие блокировки, потом закрываем дескриптор.
  if [[ -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
  fi

  # Удаляем lock-файл процесса и вспомогательный lock для append_status.
  [[ -f "$LOCKFILE" ]]               && rm -f "$LOCKFILE"               || true
  [[ -n "${STATUS_FILE:-}" && -f "${STATUS_FILE}.lock" ]] \
                                     && rm -f "${STATUS_FILE}.lock"      || true

  if (( ec == 0 )); then
    log INFO "Завершено успешно (exit=0)"
  else
    log ERROR "Завершено с ошибкой (exit=$ec)"
  fi

  exit "$ec"
}

# on_signal <ИМЯ_СИГНАЛА>
# Обрабатывает INT (Ctrl+C), TERM (kill), HUP (закрытие терминала).
# Сохраняет код выхода 130 (стандартный для прерывания по сигналу)
# и завершает скрипт — trap EXIT затем вызовет cleanup().
on_signal() {
  local sig="$1"
  log WARNING "Получен сигнал $sig — начинаем корректное завершение"
  ALL_OK=false
  EXIT_CODE=130  # Явно сохраняем — cleanup() будет использовать эту переменную
  exit 130
}

# setup_lock_and_traps
# Устанавливает flock-блокировку и регистрирует trap'ы.
# flock с файловым дескриптором — надёжнее, чем lock-файл + проверка PID,
# т.к. ОС автоматически снимает блокировку при любом завершении процесса.
setup_lock_and_traps() {
  # Открываем lock-файл на запись и сохраняем дескриптор в LOCK_FD.
  # Синтаксис «exec {LOCK_FD}>file» — bash 4.1+ назначает свободный дескриптор.
  exec {LOCK_FD}>"$LOCKFILE" || die "Не могу открыть LOCKFILE=$LOCKFILE"

  # -n : не блокироваться, а сразу вернуть ошибку если уже занято.
  if ! flock -n "$LOCK_FD"; then
    die "Другой экземпляр уже запущен (LOCKFILE=$LOCKFILE)"
  fi

  # trap cleanup EXIT — вызывается при любом выходе из скрипта.
  trap cleanup EXIT
  # trap on_signal — сигналы прерывания; on_signal вызовет exit → затем cleanup.
  trap 'on_signal INT'  INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP'  HUP

  log INFO "Эксклюзивная блокировка получена (fd=$LOCK_FD)"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. ЗАГРУЗКА СПИСКА БАКЕТОВ
#    Приоритет источников: BUCKETS_FILE > BUCKETS_ENV > DEFAULT_BUCKETS
# ──────────────────────────────────────────────────────────────────────────────

# load_buckets
# Заполняет массив BUCKETS из одного из трёх источников (по приоритету).
load_buckets() {
  if [[ -n "$BUCKETS_FILE" ]]; then
    # Читаем из файла: пропускаем пустые строки и комментарии (#).
    [[ -r "$BUCKETS_FILE" ]] || die "BUCKETS_FILE недоступен: $BUCKETS_FILE"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      BUCKETS+=("$line")
    done < "$BUCKETS_FILE"
    log INFO "Бакеты загружены из файла: $BUCKETS_FILE"

  elif [[ -n "$BUCKETS_ENV" ]]; then
    # FIX v3.3.0: «read -ra» вместо «BUCKETS=($BUCKETS_ENV)».
    # Небезопасный вариант ($BUCKETS_ENV без кавычек) подвержен glob-расширению
    # и некорректному разбиению если в именах есть спецсимволы.
    # «read -ra» делает только разбиение по пробелу без glob.
    IFS=' ' read -ra BUCKETS <<< "$BUCKETS_ENV"
    log INFO "Бакеты загружены из BUCKETS_ENV (${#BUCKETS[@]} шт.)"

  else
    # Используем встроенный список DEFAULT_BUCKETS.
    BUCKETS=("${DEFAULT_BUCKETS[@]}")
    log INFO "Бакеты загружены из DEFAULT_BUCKETS (${#BUCKETS[@]} шт.)"
  fi

  (( ${#BUCKETS[@]} > 0 )) || die "Список бакетов пуст — нечего синхронизировать"
  log INFO "Итого бакетов к обработке: ${#BUCKETS[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. ПРОВЕРКА ДОСТУПНОСТИ REMOTE'ОВ
# ──────────────────────────────────────────────────────────────────────────────

# unique_remotes_from_buckets
# Извлекает уникальные имена remote'ов из массива BUCKETS.
# Используется для проверки доступности перед началом синхронизации.
unique_remotes_from_buckets() {
  printf '%s\n' "${BUCKETS[@]}" | awk -F: '{print $1}' | sort -u
}

# check_remote_access <remote>
# Проверяет доступность одного remote через «rclone lsd».
# Завершает скрипт через die если remote недоступен — нет смысла продолжать.
check_remote_access() {
  local r="$1"
  log INFO "Проверка remote: $r:"
  if ! rclone lsd "$r:" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
    die "Remote недоступен: $r: — проверьте rclone.conf и сетевую доступность"
  fi
  log INFO "Remote доступен: $r:"
}

# check_all_remotes
# Проверяет все уникальные source-remote'ы + MinIO destination.
check_all_remotes() {
  local r
  while IFS= read -r r; do
    # MinIO проверяется отдельно в конце — не дублируем если совпадает имя.
    [[ "$r" == "minio" ]] && continue
    check_remote_access "$r"
  done < <(unique_remotes_from_buckets)
  check_remote_access "minio"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. ПРОВЕРКА СОСТОЯНИЯ CEPH-КЛАСТЕРА
# ──────────────────────────────────────────────────────────────────────────────

# check_ceph_status_soft
# Выполняет «ceph status» через SSH на указанном хосте.
# «Soft»: результат не блокирует запуск — только WARNING в лог.
# Это позволяет увидеть в логах, что репликация запускалась при деградированном
# кластере, и скоррелировать с возможными ошибками передачи данных.
#
# FIX v3.3.0: команда теперь передаётся SSH через «bash -c "..."».
# Ошибка v3.2.1: ssh host "$CEPH_STATUS_SSH_CMD" передавала всю строку
# «podman exec ceph-mon-svc02 ceph status» как ОДИН аргумент — имя бинарника.
# SSH пытался выполнить файл с пробелами в имени → команда не находилась.
check_ceph_status_soft() {
  if ! command -v ssh >/dev/null 2>&1; then
    log WARNING "Команда ssh не найдена — пропускаем проверку Ceph"
    return 0
  fi

  log INFO "Проверка Ceph через SSH: $CEPH_STATUS_SSH_HOST → $CEPH_STATUS_SSH_CMD"

  # -o ConnectTimeout=5       : не ждать подключения дольше 5 секунд
  # -o BatchMode=yes          : не спрашивать пароль (только ключи)
  # -o StrictHostKeyChecking=accept-new : принимать новые ключи, отклонять изменившиеся
  # bash -s <<< "$cmd"        : команда передаётся через stdin — без двойного раскрытия
  if ssh -o ConnectTimeout=5 \
         -o BatchMode=yes \
         -o StrictHostKeyChecking=accept-new \
         "$CEPH_STATUS_SSH_HOST" \
         bash -s >/dev/null 2>&1 <<< "$CEPH_STATUS_SSH_CMD"; then
    log INFO "Ceph-кластер в порядке"
  else
    log WARNING "Проблемы с состоянием Ceph-кластера или SSH-подключением к $CEPH_STATUS_SSH_HOST"
    log WARNING "Синхронизация продолжится, но возможны ошибки передачи данных"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. СОЗДАНИЕ БАКЕТА В MINIO ПРИ НЕОБХОДИМОСТИ
# ──────────────────────────────────────────────────────────────────────────────

# create_bucket_if_absent <remote> <bucket>
# Создаёт бакет в указанном remote если он не существует.
# Используется перед синхронизацией и для бакета backup-deleted.
#
# FIX v3.3.0: добавлен «|| true» к rclone mkdir для защиты от TOCTOU.
# Race condition: между «rclone lsd» (нет бакета) и «rclone mkdir» (создать)
# другой параллельный процесс может успеть создать тот же бакет.
# MinIO вернёт ошибку «bucket already exists» — это нормально, игнорируем.
create_bucket_if_absent() {
  local remote="$1"
  local bucket="$2"

  if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
    log INFO "Бакет не найден, создаю: $remote:$bucket"
    # «|| true» — если бакет был создан параллельным процессом между проверкой
    # и созданием, ошибка не прервёт скрипт.
    rclone mkdir "$remote:$bucket" --config="$RCLONE_CONFIG" || true
  else
    log DEBUG "Бакет уже существует: $remote:$bucket"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. ОБЁРТКА ПОВТОРНЫХ ПОПЫТОК ДЛЯ RCLONE
# ──────────────────────────────────────────────────────────────────────────────

# retry_rclone <retries> <sleep_sec> <команда> [аргументы...]
#
# Выполняет команду до <retries> раз с паузой <sleep_sec> между попытками.
# Логирует вывод построчно с классификацией уровня (ERROR/WARNING/INFO/DEBUG).
#
# FIX v3.3.0: убран pipe из критического пути.
# Проблема v3.2.1:
#   "${cmd[@]}" 2>&1 | while ... done
#   rc=${PIPESTATUS[0]}
# При set -eEuo pipefail нет гарантии что PIPESTATUS[0] корректно читается
# после завершения пайплайна — ERR-trap мог сработать раньше.
# Решение: сохраняем весь вывод rclone во временный файл, читаем отдельно.
retry_rclone() {
  local retries="$1"
  local sleep_s="$2"
  shift 2

  local -a cmd=( "$@" )
  local attempt rc
  # Временный файл для вывода rclone (stdout + stderr объединяем).
  # Используем mktemp для уникального имени — безопасно при параллельном запуске.
  local tmpout
  tmpout="$(mktemp /tmp/rclone_out.XXXXXX)"

  # Гарантируем удаление временного файла при выходе из функции.
  # «|| true» — на случай если rm вдруг вернёт ошибку.
  # shellcheck disable=SC2064
  trap "rm -f '$tmpout'" RETURN

  for (( attempt=1; attempt<=retries; attempt++ )); do
    log INFO "Попытка $attempt/$retries: $(cmd_str "${cmd[@]}")"

    # Выполняем команду, весь вывод (stdout+stderr) пишем в tmpout.
    # set +e / set -e — чтобы ненулевой код rclone не прервал скрипт немедленно.
    set +e
    "${cmd[@]}" > "$tmpout" 2>&1
    rc=$?
    set -e

    # Читаем и логируем вывод rclone, классифицируя строки по уровню.
    while IFS= read -r line; do
      if   [[ "$line" =~ (ERROR|CRITICAL|Fatal|Failed) ]]; then
        log ERROR   "rclone: $line"
      elif [[ "$line" =~ (WARNING|WARN) ]]; then
        log WARNING "rclone: $line"
      elif [[ "$DRY_RUN" == "true" || "$line" =~ (Copied|Deleted|Moved|Transferred) ]]; then
        log INFO    "rclone: $line"
      else
        log DEBUG   "rclone: $line"
      fi
    done < "$tmpout"

    case $rc in
      0)
        # Нормальное успешное завершение.
        log INFO "rclone завершился успешно (rc=0)"
        return 0
        ;;
      3)
        # rc=3 у rclone означает «нет файлов для передачи/изменений не было».
        # Для операций sync/copy это не ошибка — бакет уже актуален.
        log INFO "Изменений не обнаружено (rc=3) — считаем успешным"
        return 0
        ;;
    esac

    # Ненулевой rc, не равный 3 — ошибка передачи.
    if (( attempt < retries )); then
      log WARNING "Ошибка rclone (rc=$rc), повтор через ${sleep_s}с (попытка $attempt/$retries)"
      sleep "$sleep_s"
    else
      log ERROR "Команда не удалась после $retries попыток (последний rc=$rc)"
      return "$rc"
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. ВАЛИДАЦИЯ РЕЗУЛЬТАТА (COUNT-СРАВНЕНИЕ)
# ──────────────────────────────────────────────────────────────────────────────

# count_objects <s3path>
# Возвращает количество объектов в S3-пути через «rclone size --json».
#
# FIX v3.3.0: заменён медленный «rclone lsf --recursive | wc -l» на быстрый
# «rclone size --json». На бакете с миллионом объектов lsf перечисляет все
# записи по одной, тогда как size получает агрегат напрямую от S3 API.
# Экономия: минуты vs секунды на больших бакетах.
count_objects() {
  local s3path="$1"
  local n=0
  local json_out

  set +e
  # rclone size --json возвращает: {"count":12345,"bytes":67890}
  json_out="$(rclone size --json --config="$RCLONE_CONFIG" "$s3path" 2>/dev/null)"
  set -e

  # Извлекаем поле «count» через awk (избегаем зависимости от jq).
  if [[ -n "$json_out" ]]; then
    n="$(printf '%s' "$json_out" | awk -F'[,{}":]' '{for(i=1;i<=NF;i++) if($i=="count") print $(i+2)}')"
    n="${n:-0}"
  fi

  printf '%s' "$n"
}

# validate_pair_counts <src> <dst>
# Сравнивает количество объектов в источнике и назначении.
# Возвращает 0 если совпадают или валидация отключена, 1 если не совпадают.
validate_pair_counts() {
  local src="$1"
  local dst="$2"

  # Пропускаем если VALIDATE_MODE не «counts».
  [[ "$VALIDATE_MODE" == "counts" ]] || {
    log DEBUG "Валидация отключена (VALIDATE_MODE=$VALIDATE_MODE)"
    return 0
  }

  log INFO "Валидация (counts): $src  ↔  $dst"
  local cs cd
  cs="$(count_objects "$src")"
  cd="$(count_objects "$dst")"

  if [[ "$cs" == "$cd" ]]; then
    log INFO "Валидация OK: объектов совпадает ($cs шт.)"
    return 0
  else
    log WARNING "Валидация FAIL: source=$cs объектов, dest=$cd объектов (расхождение: $((cd - cs)))"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. ПОТОКОБЕЗОПАСНАЯ ЗАПИСЬ СТАТУСА
# ──────────────────────────────────────────────────────────────────────────────

# append_status <remote:bucket> <OK|FAIL> [сообщение]
#
# Записывает строку статуса в TSV-файл.
# Использует flock для атомарной записи при параллельном выполнении.
# Несколько процессов могут вызывать append_status одновременно — без
# блокировки строки в файле могут перемежаться.
#
# FIX v3.3.0: lock-файл открывается на запись (>), а не на дозапись (>>).
# В v3.2.1 «200>>"$STATUS_FILE.lock"» создавал постоянно растущий файл —
# при каждом вызове к нему дописывалась строка (flock при этом пишет пусто,
# но открытие в append-режиме инкрементировало offset, накапливая мусор).
# Теперь «200>"$STATUS_FILE.lock"» — файл перезаписывается каждый раз,
# содержимое всегда пустое, размер не растёт.
append_status() {
  local bucket="$1"
  local state="$2"   # OK или FAIL
  local msg="${3:-}"  # Необязательный комментарий

  {
    flock -x 200
    printf '%s\t%s\t%s\n' "$bucket" "$state" "$msg" >> "$STATUS_FILE"
  } 200> "${STATUS_FILE}.lock"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. ОБРАБОТКА ОДНОГО БАКЕТА
#     Вызывается параллельно через xargs -P. Каждый вызов — отдельный bash-процесс.
# ──────────────────────────────────────────────────────────────────────────────

# process_bucket <remote:bucket>
#
# Полный цикл обработки одного бакета:
#   1. Парсинг spec (remote:bucket)
#   2. Создание целевого бакета и бакета backup-deleted в MinIO
#   3. Запуск rclone sync/copy с retry
#   4. Валидация результата
#   5. Запись статуса в STATUS_FILE
#
# FIX v3.3.0: каждый вызов пишет JSONL в отдельный файл
# (/tmp/rclone_<remote>_<bucket>_<ts>.jsonl), а не в общий.
# Это устраняет гонку при параллельной записи в один файл — rclone и ОС
# не гарантируют атомарность write() для больших JSON-блоков,
# строки могут перемежаться и делать JSONL невалидным.
process_bucket() {
  local spec="$1"  # Формат: "remote:bucket"

  # Проверяем формат spec — должна быть хотя бы одна «:».
  if [[ "$spec" != *:* ]]; then
    log ERROR "Некорректный формат spec: '$spec' (ожидается remote:bucket)"
    append_status "$spec" "FAIL" "bad_spec"
    return 1
  fi

  # Разбиваем spec на компоненты.
  # «%%:*» — всё до первого двоеточия (remote)
  # «#*:»  — всё после первого двоеточия (bucket)
  local src_remote="${spec%%:*}"
  local src_bucket="${spec#*:}"

  # Назначение: бакет в MinIO называется по имени source-remote,
  # внутри него — субпуть с именем source-bucket.
  # Пример: test:nbgi-db-public → minio:test/nbgi-db-public
  local dst_bucket="$src_remote"
  local src="$src_remote:$src_bucket"
  local dst="minio:${dst_bucket}/${src_bucket}"

  # Директория для версий удалённых/перезаписанных объектов.
  # Создаётся автоматически rclone при первом использовании --backup-dir.
  local today; today="$(date +%F)"
  local backup_dir="${DELETE_BACKUP_ROOT}/${today}/${src_remote}/${src_bucket}"

  # Per-bucket JSONL для rclone — уникальное имя, без гонки.
  local bucket_jsonlog="/tmp/rclone_${src_remote}_${src_bucket}_${RUN_TS}.jsonl"

  log INFO "=== Начало: $spec ➜ $dst"

  # Создаём нужные бакеты в MinIO. set +e / set -e — чтобы ошибки создания
  # (например, бакет уже существует) не прерывали скрипт.
  set +e
  create_bucket_if_absent "minio" "$dst_bucket"                    2>/dev/null
  create_bucket_if_absent "minio" "${DELETE_BACKUP_ROOT#minio:}"   2>/dev/null
  set -e

  # ── Формируем массив флагов rclone ────────────────────────────────────────

  local -a flags=(
    # --fast-list: использовать ListObjectsV2 с пагинацией вместо параллельных
    #             запросов — уменьшает нагрузку на Ceph RGW, быстрее на больших бакетах.
    --fast-list

    # --checksum: сравнивать файлы по контрольной сумме (ETag/MD5), а не только по
    #             размеру и времени модификации. Медленнее, но надёжнее для S3→S3.
    --checksum

    # --create-empty-src-dirs: создавать «пустые папки» (нулевые объекты-маркеры).
    --create-empty-src-dirs

    # --s3-force-path-style: использовать path-style URL (host/bucket/key)
    #                        вместо virtual-hosted (bucket.host/key).
    #                        Ceph RGW и некоторые конфигурации MinIO требуют это.
    --s3-force-path-style

    --transfers="$RCLONE_TRANSFERS"
    --checkers="$RCLONE_CHECKERS"
    --retries="$RCLONE_RETRIES"
    --retries-sleep="$RCLONE_RETRIES_SLEEP"
    --stats="$RCLONE_STATS_INTERVAL"
    --stats-log-level=NOTICE
    --use-json-log
    --log-level="$RCLONE_LOG_LEVEL"

    # Per-bucket лог — уникальный файл, без гонки при параллельном запуске.
    --log-file="$bucket_jsonlog"

    --buffer-size="$RCLONE_BUFFER_SIZE"
    --s3-upload-concurrency="$RCLONE_S3_UPLOAD_CONCURRENCY"
    --s3-chunk-size="$RCLONE_S3_CHUNK_SIZE"

    # --backup-dir: объекты, удалённые/перезаписанные при sync, перемещаются сюда
    #              вместо безвозвратного удаления — версионирование удалений.
    --backup-dir="$backup_dir"

    --config="$RCLONE_CONFIG"
  )

  # Опциональные флаги в зависимости от конфигурации.
  [[ "$RCLONE_USE_MMAP"    == "true" ]] && flags+=(--use-mmap)
  [[ "$DRY_RUN"            == "true" ]] && { flags+=(--dry-run); log INFO "DRY_RUN активен: изменения НЕ применяются"; }
  [[ "$RCLONE_S3_INSECURE" == "true" ]] && { flags+=(--no-check-certificate); log WARNING "TLS-проверка отключена (RCLONE_S3_INSECURE=true)!"; }

  # Итоговая команда rclone.
  local -a cmd=( rclone "$OPERATION" "${flags[@]}" "$src" "$dst" )

  # ── Запускаем синхронизацию с повторными попытками ─────────────────────────

  local bucket_ok=true

  if retry_rclone 3 15 "${cmd[@]}"; then
    # rclone завершился успешно — валидируем результат.
    if validate_pair_counts "$src" "$dst"; then
      log INFO "=== Успешно: $spec"
      append_status "$spec" "OK" ""
    else
      log WARNING "=== Валидация не сошлась: $spec"
      append_status "$spec" "FAIL" "validate_mismatch"
      bucket_ok=false
    fi
  else
    log ERROR "=== Сбой rclone для $spec"
    append_status "$spec" "FAIL" "rclone_error"
    bucket_ok=false
  fi

  "$bucket_ok" || return 1
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. ЭКСПОРТ ФУНКЦИЙ И ПЕРЕМЕННЫХ ДЛЯ ДОЧЕРНИХ ПРОЦЕССОВ
#
# Дочерние процессы xargs запускаются как «bash -c 'process_bucket "$1"' _ {}».
# Они не наследуют функции и переменные родительского bash-процесса автоматически.
# Необходим явный «export -f» для функций и «export» для переменных.
# ──────────────────────────────────────────────────────────────────────────────

# Функции, используемые в process_bucket и его зависимостях.
export -f log die cmd_str \
          retry_rclone \
          validate_pair_counts count_objects \
          create_bucket_if_absent \
          append_status \
          process_bucket

# Переменные конфигурации rclone.
export RCLONE_CONFIG RCLONE_LOG_LEVEL RCLONE_BUFFER_SIZE RCLONE_USE_MMAP
export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES RCLONE_RETRIES_SLEEP
export RCLONE_STATS_INTERVAL RCLONE_S3_UPLOAD_CONCURRENCY RCLONE_S3_CHUNK_SIZE RCLONE_S3_INSECURE

# Переменные поведения скрипта.
export DELETE_BACKUP_ROOT DRY_RUN OPERATION VALIDATE_MODE

# FIX v3.3.0: LOGFILE и STATUS_FILE теперь тоже экспортируются.
# В v3.2.1 LOGFILE отсутствовал в export — дочерние процессы не могли писать
# в лог-файл (LOGFILE был пустой строкой), и все WARNING/ERROR из дочерних
# процессов тихо пропадали (шли только в stderr, не в файл).
export LOGFILE STATUS_FILE

# RUN_TS нужен в process_bucket для формирования имени per-bucket JSONL.
export RUN_TS

# ──────────────────────────────────────────────────────────────────────────────
# 18. ОЧИСТКА УСТАРЕВШИХ ВЕРСИЙ (backup-deleted)
# ──────────────────────────────────────────────────────────────────────────────

# cleanup_deleted_retention
# Удаляет объекты в backup-deleted старше DELETE_RETENTION_DAYS дней,
# затем удаляет опустевшие «папки» (пустые prefix'ы).
# Запускается один раз после завершения всех бакетов.
cleanup_deleted_retention() {
  log INFO "Очистка backup-deleted (старше ${DELETE_RETENTION_DAYS}д): $DELETE_BACKUP_ROOT"

  # Удаляем старые объекты.
  local -a del_cmd=(
    rclone delete "$DELETE_BACKUP_ROOT"
    --min-age "${DELETE_RETENTION_DAYS}d"
    --use-json-log
    --log-level="$RCLONE_LOG_LEVEL"
    --log-file="${LOGDIR}/${SCRIPT_NAME%.sh}_${RUN_TS}_retention.jsonl"
    --config="$RCLONE_CONFIG"
  )
  [[ "$DRY_RUN" == "true" ]] && del_cmd+=(--dry-run)

  retry_rclone 3 10 "${del_cmd[@]}" || log WARNING "rclone delete backup-deleted завершился с предупреждениями"

  # Удаляем пустые «директории» (prefix-маркеры), оставив корневой бакет.
  local -a rmd_cmd=(
    rclone rmdirs "$DELETE_BACKUP_ROOT"
    --leave-root   # Не удалять сам корневой бакет backup-deleted
    --use-json-log
    --log-level="$RCLONE_LOG_LEVEL"
    --log-file="${LOGDIR}/${SCRIPT_NAME%.sh}_${RUN_TS}_retention.jsonl"
    --config="$RCLONE_CONFIG"
  )
  [[ "$DRY_RUN" == "true" ]] && rmd_cmd+=(--dry-run)

  retry_rclone 3 10 "${rmd_cmd[@]}" || log WARNING "rclone rmdirs backup-deleted завершился с предупреждениями"
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. ИТОГОВАЯ СВОДКА
# ──────────────────────────────────────────────────────────────────────────────

# generate_summary
# Собирает per-bucket JSONL-файлы в единый RCLONE_JSONLOG,
# формирует текстовую сводку по всем бакетам.
generate_summary() {
  log INFO "Формирование итоговой сводки..."

  # Собираем все per-bucket JSONL-файлы в один итоговый.
  # find ищет файлы по шаблону в /tmp — безопасно, имена уникальны по RUN_TS.
  local found_jsonl=false
  while IFS= read -r f; do
    cat "$f" >> "$RCLONE_JSONLOG" 2>/dev/null || true
    rm -f "$f" || true
    found_jsonl=true
  done < <(find /tmp -maxdepth 1 -name "rclone_*_${RUN_TS}.jsonl" 2>/dev/null || true)

  $found_jsonl || log WARNING "Per-bucket JSONL-файлы не найдены (нормально при DRY_RUN или пустом запуске)"

  # Формируем текстовую сводку.
  {
    echo "================================================================================"
    echo " ИТОГОВАЯ СВОДКА: $SCRIPT_NAME v$SCRIPT_VERSION"
    printf " Время запуска: %s\n" "$(date)"
    printf " DRY_RUN: %-10s  OPERATION: %-6s  PARALLEL: %s\n" "$DRY_RUN" "$OPERATION" "$PARALLEL"
    echo " Конфиг rclone: $RCLONE_CONFIG"
    printf " Ceph-проверка: %s  (cmd: %s)\n" "$CEPH_STATUS_SSH_HOST" "$CEPH_STATUS_SSH_CMD"
    echo "================================================================================"
    printf "%-50s | %-6s | %s\n" "BUCKET" "STATE" "NOTE"
    echo "--------------------------------------------------------------------------------"

    if [[ -f "$STATUS_FILE" && -s "$STATUS_FILE" ]]; then
      # Подсчёт статистики: OK vs FAIL.
      local ok_count fail_count
      ok_count=$(awk  -F'\t' '$2=="OK"   {c++} END{print c+0}' "$STATUS_FILE")
      fail_count=$(awk -F'\t' '$2=="FAIL" {c++} END{print c+0}' "$STATUS_FILE")

      awk -F'\t' '{printf "%-50s | %-6s | %s\n", $1, $2, $3}' "$STATUS_FILE" 2>/dev/null || true

      echo "--------------------------------------------------------------------------------"
      printf " Итого: %d бакетов — OK: %d, FAIL: %d\n" \
             "$((ok_count + fail_count))" "$ok_count" "$fail_count"
    else
      echo " (статус-файл пуст или отсутствует)"
    fi

    echo "================================================================================"
    echo " Файлы логов:"
    printf "   Текстовый лог:  %s\n" "$LOGFILE"
    printf "   JSONL rclone:   %s\n" "$RCLONE_JSONLOG"
    printf "   Сводка (этот):  %s\n" "$SUMMARY_TXT"
    echo "================================================================================"
  } | tee -a "$LOGFILE" > "$SUMMARY_TXT"

  log INFO "Сводка сохранена: $SUMMARY_TXT"
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. РАЗБОР АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ──────────────────────────────────────────────────────────────────────────────

# print_help
# Выводит справку по использованию скрипта.
print_help() {
  cat << EOF
Использование: $SCRIPT_NAME [опции]

Опции:
  --op=sync|copy           Операция rclone (по умолчанию: $OPERATION)
  --parallel=N             Количество параллельных потоков (по умолчанию: $PARALLEL)
  --dry-run[=true|false]   Тестовый прогон без изменений (по умолчанию: $DRY_RUN)
  --validate=none|counts   Режим валидации результата (по умолчанию: $VALIDATE_MODE)
  --buckets-file=FILE      Файл со списком «remote:bucket» (по одному на строку)
  --buckets="r1:b1 r2:b2"  Список бакетов через пробел (перекрывает файл и DEFAULT)
  --ceph-host=HOST         SSH-хост для проверки Ceph (по умолчанию: $CEPH_STATUS_SSH_HOST)
  --help, -h               Эта справка

Переменные окружения (можно использовать вместо или вместе с CLI):
  RCLONE_CONFIG            Путь к rclone.conf
  PARALLEL, OPERATION, DRY_RUN, VALIDATE_MODE
  BUCKETS_FILE, BUCKETS_ENV
  CEPH_STATUS_SSH_HOST, CEPH_STATUS_SSH_CMD
  RCLONE_TRANSFERS, RCLONE_CHECKERS, RCLONE_RETRIES, RCLONE_RETRIES_SLEEP
  DELETE_RETENTION_DAYS, DELETE_BACKUP_ROOT
  RCLONE_S3_INSECURE       (true — отключить TLS-проверку, не рекомендуется!)

Примеры:
  # Тестовый прогон (ничего не изменяет):
  DRY_RUN=true $SCRIPT_NAME

  # Рабочий запуск с 4 потоками и валидацией:
  $SCRIPT_NAME --op=sync --parallel=4 --validate=counts

  # Только конкретные бакеты:
  $SCRIPT_NAME --buckets="test:bucket1 registry:docker-registry"

  # Бакеты из файла, с другим хостом Ceph:
  $SCRIPT_NAME --buckets-file=/etc/rclone/buckets.list --ceph-host=cephrgw01

  # Копирование без удалений (безопаснее для первого запуска):
  $SCRIPT_NAME --op=copy --validate=none
EOF
}

# parse_cli [аргументы...]
# Разбирает аргументы командной строки, обновляет переменные конфигурации.
parse_cli() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --op=*)               OPERATION="${arg#*=}"         ;;
      --parallel=*)         PARALLEL="${arg#*=}"          ;;
      --dry-run|--dry-run=true)  DRY_RUN=true             ;;
      --dry-run=false)      DRY_RUN=false                 ;;
      --validate=*)         VALIDATE_MODE="${arg#*=}"     ;;
      --buckets-file=*)     BUCKETS_FILE="${arg#*=}"      ;;
      --buckets=*)          BUCKETS_ENV="${arg#*=}"       ;;
      --ceph-host=*)        CEPH_STATUS_SSH_HOST="${arg#*=}" ;;
      --help|-h)            print_help; exit 0            ;;
      *)                    die "Неизвестная опция: '$arg' — запустите с --help" ;;
    esac
  done

  # Валидация значений после разбора.
  case "$OPERATION" in
    sync|copy) ;;
    *) die "Недопустимое значение --op: '$OPERATION'. Допустимо: sync, copy" ;;
  esac

  case "$VALIDATE_MODE" in
    none|counts) ;;
    *) die "Недопустимое значение --validate: '$VALIDATE_MODE'. Допустимо: none, counts" ;;
  esac

  if ! [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    die "Недопустимое значение --parallel: '$PARALLEL'. Должно быть положительным целым числом"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. ТОЧКА ВХОДА — MAIN
# ──────────────────────────────────────────────────────────────────────────────

main() {
  # Разбираем CLI до init_logging, чтобы возможные ошибки аргументов
  # не создавали пустые лог-файлы.
  parse_cli "$@"

  # Инициализация логирования — с этого момента log() пишет и в файл.
  init_logging
  rotate_logs

  # Проверяем окружение до начала любой работы.
  check_commands
  check_rclone_version
  check_rclone_config

  # Устанавливаем блокировку и trap'ы — после этого cleanup() гарантированно
  # вызовется при любом завершении.
  setup_lock_and_traps

  # Информационный лог стартовых параметров.
  log INFO "Хост: $(hostname -f 2>/dev/null || hostname)  |  Пользователь: $(whoami)"
  log INFO "Параметры: OPERATION=$OPERATION  PARALLEL=$PARALLEL  DRY_RUN=$DRY_RUN  VALIDATE_MODE=$VALIDATE_MODE"
  log INFO "rclone:    transfers=$RCLONE_TRANSFERS  checkers=$RCLONE_CHECKERS  retries=$RCLONE_RETRIES  sleep=$RCLONE_RETRIES_SLEEP"
  log INFO "Ceph SSH:  host=$CEPH_STATUS_SSH_HOST  cmd='$CEPH_STATUS_SSH_CMD'"

  # Загружаем список бакетов из выбранного источника.
  load_buckets

  # Проверяем сетевую доступность всех remote'ов.
  check_all_remotes

  # Мягкая проверка состояния Ceph (только WARNING, не блокирует).
  check_ceph_status_soft

  # Гарантируем существование корневого бакета backup-deleted в MinIO.
  create_bucket_if_absent "minio" "${DELETE_BACKUP_ROOT#minio:}" || true

  log INFO "Запускаем параллельную синхронизацию: ${#BUCKETS[@]} бакетов, -P $PARALLEL"

  # ── Параллельная обработка бакетов через xargs -P ─────────────────────────
  #
  # printf '%s\0' "${BUCKETS[@]}" — выводим имена с нуль-разделителем (безопасно
  #   для имён с пробелами и спецсимволами).
  # xargs -0 — читает нуль-разделённый ввод.
  # -n1      — по одному аргументу за раз.
  # -P$PARALLEL — $PARALLEL параллельных процессов.
  # -I{}     — подстановка аргумента как {}.
  # bash -c 'process_bucket "$1"' _ {} — вызываем функцию в дочернем bash.
  #   «_» — $0 (имя скрипта в дочернем процессе), {} — $1 (имя бакета).
  #
  # set +e / set -e: xargs возвращает 123 если хотя бы одна подкоманда упала —
  # это не повод прерывать весь скрипт, обрабатываем ниже.
  set +e
  printf '%s\0' "${BUCKETS[@]}" \
    | xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'process_bucket "$1"' _ {}
  local xrc=$?
  set -e

  if (( xrc != 0 )); then
    log WARNING "Один или несколько бакетов завершились с ошибками (xargs rc=$xrc)"
    ALL_OK=false
    EXIT_CODE=1
  fi

  # ── Финальные операции ─────────────────────────────────────────────────────

  # Удаляем устаревшие версии в backup-deleted.
  cleanup_deleted_retention

  # Формируем итоговую сводку и собираем JSONL-логи.
  generate_summary

  if $ALL_OK; then
    log INFO "Все бакеты синхронизированы успешно"
    EXIT_CODE=0
    return 0
  else
    log ERROR "Синхронизация завершена с ошибками — проверьте сводку: $SUMMARY_TXT"
    EXIT_CODE=1
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Запуск main только если скрипт выполняется напрямую (не через source).
# Это позволяет подключать скрипт через «source» для тестирования функций
# без запуска основной логики.
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi