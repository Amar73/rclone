#!/usr/local/bin/bash
# =================================================================================================
# cephtominio_v3.2.sh — репликация Ceph S3 ➜ MinIO S3 с rclone
# Автор: Андрей Марьяненко (ведущий инженер). Платформа: FreeBSD 14.2, bash
#
# Ключевые фичи:
#  - Строгий режим: set -eEuo pipefail, IFS, umask 027
#  - Безопасная блокировка через flock, корректные trap'ы
#  - Параллельная обработка бакетов (xargs -P), управляемая через $PARALLEL
#  - Логирование: человекочитаемый лог + JSON-лог rclone (--use-json-log)
#  - Версионирование удалений: --backup-dir=minio:backup-deleted/YYYY-MM-DD/<remote>/<bucket>
#  - Ретеншен удалений: delete + rmdirs старше $DELETE_RETENTION_DAYS
#  - Валидация результата (счётчики объектов) опционально
#  - Полная настраиваемость через переменные окружения и/или CLI
#
# ЗАМЕТКИ ПО МОДЕЛИ РЕПЛИКАЦИИ:
#  - По умолчанию выполняется rclone sync (а не copy), чтобы дестинация соответствовала источнику.
#    Удаляемые/перезаписываемые объекты складываются в backup-deleted (версионирование).
#  - Структура назначения: minio:<sourceRemote>/<sourceBucket>/... (bucket-папка по remote, внутри — prefix)
#
# Быстрый старт:
#   env DRY_RUN=true ./cephtominio_v3.2.sh --validate=counts
#   ./cephtominio_v3.2.sh --op=sync --parallel=4
#
# Требования: rclone >= 1.60, flock(1), awk, date, xargs (BSD с поддержкой -P)
#
# =================================================================================================

# -------------------------------------------
# 1) Жёсткий режим и базовая гигиена окружения
# -------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
umask 027
export LANG=C LC_ALL=C

# -------------------------------------------
# 2) Метаданные и версии
# -------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="3.0.0"
readonly REQUIRED_RCLONE_VERSION="1.60"

# -------------------------------------------
# 3) Конфигурация по умолчанию (переопределяется ENV/CLI)
# -------------------------------------------

# Где хранить логи
: "${LOGDIR:=/var/log/rclone-sync}"
# Файл блокировки (чтобы не запускалось дважды)
: "${LOCKFILE:=/var/lock/s3_sync_buckets.lock}"
# Путь к rclone.conf
: "${RCLONE_CONFIG:=/root/.config/rclone/rclone.conf}"

# Параллелизм
: "${PARALLEL:=4}"

# Операция rclone: sync|copy (по умолчанию sync для полноценной репликации)
: "${OPERATION:=sync}"

# DRY_RUN=true для теста без изменений
: "${DRY_RUN:=false}"

# Ретеншен (дней) для backup-deleted
: "${DELETE_RETENTION_DAYS:=30}"

# Валидация результата: none|counts
#  - none   : не валидировать
#  - counts : сравнить количество файлов (источник vs назначение)
: "${VALIDATE_MODE:=counts}"

# Настройки rclone (можно переопределять ENV)
: "${RCLONE_TRANSFERS:=32}"
: "${RCLONE_CHECKERS:=16}"
: "${RCLONE_RETRIES:=7}"
: "${RCLONE_RETRIES_SLEEP:=10s}"
: "${RCLONE_STATS_INTERVAL:=60s}"
: "${RCLONE_LOG_LEVEL:=INFO}"
: "${RCLONE_BUFFER_SIZE:=16M}"
: "${RCLONE_USE_MMAP:=true}"
: "${RCLONE_S3_UPLOAD_CONCURRENCY:=32}"
: "${RCLONE_S3_CHUNK_SIZE:=64M}"           # если очень крупные объекты — увеличивай
: "${RCLONE_S3_INSECURE:=false}"           # true -> добавим --no-check-certificate (не рекомендуется)

# Мягкая проверка кластера Ceph (опционально)
: "${CEPH_STATUS_SSH_HOST:=}"              # пример: cephrgw01
: "${CEPH_STATUS_SSH_CMD:=podman exec ceph-mon-cephrgw01 ceph status}"

# «Корень» для версий удалённых/перезаписанных объектов
: "${DELETE_BACKUP_ROOT:=minio:backup-deleted}"

# Бакеты-источники: можно задать через файл или ENV; иначе — используем массив ниже
: "${BUCKETS_FILE:=}"            # файл со строками вида: remote:bucket
: "${BUCKETS_ENV:=}"             # пробел-разделённый список: "r1:b1 r2:b2 ..."
# Встроенный список по умолчанию (можно убрать/заменить под себя)
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

# -------------------------------------------
# 4) Глобальные переменные рантайма (после init)
# -------------------------------------------
RUN_TS=""
LOGFILE=""
RCLONE_JSONLOG=""
SUMMARY_TXT=""
STATUS_FILE=""
ALL_OK=true

# -------------------------------------------
# 5) Утилиты: логирование, die, печать команд
# -------------------------------------------
log() {
  # Используем stderr для интерактивки, файл — dup
  local level="${1:-INFO}"; shift || true
  local msg="${*:-}"
  local ts
  ts="$(date -Iseconds)"

  local color=""
  if [[ -t 2 ]]; then
    case "$level" in
      DEBUG)   color=$'\033[36m' ;;
      INFO)    color=$'\033[32m' ;;
      WARNING) color=$'\033[33m' ;;
      ERROR)   color=$'\033[31m' ;;
      CRITICAL)color=$'\033[35;1m' ;;
    esac
  fi

  if [[ -n "$color" ]]; then
    printf '%s[%s] %s\033[0m\n' "$color" "$level" "$msg" >&2
  else
    printf '[%s] %s\n' "$level" "$msg" >&2
  fi

  # Пишем в файл, если уже инициализирован
  if [[ -n "${LOGFILE:-}" ]]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$LOGFILE"
  fi
}

die() {
  log ERROR "$*"
  exit 1
}

cmd_str() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v out '%s%s ' "$out" "$(printf '%q' "$arg")"
  done
  printf '%s' "${out% }"
}

# -------------------------------------------
# 6) Инициализация логов, ротация, проверка окружения
# -------------------------------------------
init_logging() {
  RUN_TS="$(date +'%Y-%m-%d_%H-%M-%S')"
  mkdir -p "$LOGDIR" || die "Не удалось создать LOGDIR=$LOGDIR"

  LOGFILE="$LOGDIR/${SCRIPT_NAME%.sh}_${RUN_TS}.log"
  RCLONE_JSONLOG="$LOGDIR/${SCRIPT_NAME%.sh}_${RUN_TS}.jsonl"
  SUMMARY_TXT="$LOGDIR/${SCRIPT_NAME%.sh}_${RUN_TS}.summary.txt"
  STATUS_FILE="$LOGDIR/${SCRIPT_NAME%.sh}_${RUN_TS}.status.tsv"

  : >"$LOGFILE"
  : >"$RCLONE_JSONLOG"
  : >"$STATUS_FILE"

  log INFO "Старт $SCRIPT_NAME v$SCRIPT_VERSION"
  log INFO "Логи: $LOGFILE"
  log INFO "JSON rclone: $RCLONE_JSONLOG"
}

rotate_logs() {
  # Удаляем старые логи (старше 30 дней) — можно вынести в отдельный cron
  find "$LOGDIR" -type f -name "${SCRIPT_NAME%.sh}_*.log"   -mtime +30 -delete 2>/dev/null || true
  find "$LOGDIR" -type f -name "${SCRIPT_NAME%.sh}_*.jsonl" -mtime +30 -delete 2>/dev/null || true
  find "$LOGDIR" -type f -name "${SCRIPT_NAME%.sh}_*.summary.txt" -mtime +30 -delete 2>/dev/null || true
  find "$LOGDIR" -type f -name "${SCRIPT_NAME%.sh}_*.status.tsv"  -mtime +30 -delete 2>/dev/null || true
}

check_commands() {
  local miss=()
  local need=(rclone flock awk xargs date)
  local c
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if ((${#miss[@]})); then
    die "Отсутствуют требуемые команды: ${miss[*]}"
  fi
}

check_rclone_version() {
  local v
  v="$(rclone --version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//')" || v="0.0"
  local req_major req_minor cur_major cur_minor
  IFS='.' read -r req_major req_minor _ <<<"$REQUIRED_RCLONE_VERSION"
  IFS='.' read -r cur_major cur_minor _ <<<"$v"
  if (( cur_major < req_major || (cur_major == req_major && cur_minor < req_minor) )); then
    log WARNING "Рекомендуется rclone >= $REQUIRED_RCLONE_VERSION (сейчас: $v)"
  else
    log INFO "rclone версия: $v (ок)"
  fi
}

check_rclone_config() {
  [[ -f "$RCLONE_CONFIG" ]] || die "rclone.conf не найден: $RCLONE_CONFIG"
  # Проверяем права (FreeBSD-совместимо через stat -f)
  local perms
  perms="$(stat -f %Sp "$RCLONE_CONFIG" 2>/dev/null || echo "")"
  if [[ "$perms" != "-rw-------" ]]; then
    log WARNING "Небезопасные права на $RCLONE_CONFIG (рекоменд: chmod 600)"
  fi
}

# -------------------------------------------
# 7) Блокировка и trap'ы
# -------------------------------------------
LOCK_FD=""
cleanup() {
  local ec=$?
  if [[ -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
  fi
  [[ -f "$LOCKFILE" ]] && rm -f "$LOCKFILE" || true

  if (( ec == 0 )); then
    log INFO "Завершено успешно"
  else
    log ERROR "Завершено с ошибкой (exit=$ec)"
  fi
  exit $ec
}

on_signal() {
  local sig="$1"
  log WARNING "Получен сигнал $sig — корректное завершение"
  ALL_OK=false
  exit 130
}

setup_lock_and_traps() {
  # FreeBSD flock(1) есть, используем файловый дескриптор
  exec {LOCK_FD}>"$LOCKFILE" || die "Не могу открыть LOCKFILE=$LOCKFILE"
  if ! flock -n "$LOCK_FD"; then
    die "Другой экземпляр уже запущен (LOCKFILE=$LOCKFILE)"
  fi
  trap cleanup EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP'  HUP
  log INFO "Блокировка получена"
}

# -------------------------------------------
# 8) Загрузка списка бакетов
#    Приоритет: --buckets-file | $BUCKETS_FILE > --buckets | $BUCKETS_ENV > DEFAULT_BUCKETS
# -------------------------------------------
BUCKETS=()
load_buckets() {
  if [[ -n "$BUCKETS_FILE" ]]; then
    [[ -r "$BUCKETS_FILE" ]] || die "BUCKETS_FILE недоступен: $BUCKETS_FILE"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      BUCKETS+=("$line")
    done <"$BUCKETS_FILE"
  elif [[ -n "$BUCKETS_ENV" ]]; then
    # shellcheck disable=SC2206
    BUCKETS=($BUCKETS_ENV)
  else
    BUCKETS=("${DEFAULT_BUCKETS[@]}")
  fi

  ((${#BUCKETS[@]})) || die "Список бакетов пуст"
  log INFO "Бакетов к обработке: ${#BUCKETS[@]}"
}

# -------------------------------------------
# 9) Проверка доступности remote'ов и MinIO
# -------------------------------------------
unique_remotes_from_buckets() {
  # Печатаем уникальные имена remote'ов из BUCKETS
  awk -F: '{print $1}' <<<"$(printf '%s\n' "${BUCKETS[@]}")" | sort -u
}

check_remote_access() {
  local r="$1"
  if ! rclone lsd "$r:" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
    die "Remote недоступен: $r:"
  fi
  log INFO "Remote доступен: $r:"
}

check_all_remotes() {
  local r
  for r in $(unique_remotes_from_buckets); do
    [[ "$r" == "minio" ]] && continue
    check_remote_access "$r"
  done
  check_remote_access "minio"
}

# -------------------------------------------
# 10) Опциональная проверка статуса Ceph
# -------------------------------------------
check_ceph_status_soft() {
  [[ -n "$CEPH_STATUS_SSH_HOST" ]] || { log DEBUG "CEPH_STATUS_SSH_HOST пуст — пропуск"; return 0; }
  if command -v ssh >/dev/null 2>&1; then
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$CEPH_STATUS_SSH_HOST" "$CEPH_STATUS_SSH_CMD" >/dev/null 2>&1; then
      log INFO "Ceph статус: OK (soft-check)"
    else
      log WARNING "Не удалось получить статус Ceph (soft-check)"
    fi
  else
    log DEBUG "ssh недоступен — пропуск"
  fi
}

# -------------------------------------------
# 11) Создание бакета в MinIO при необходимости
# -------------------------------------------
create_bucket_if_absent() {
  local remote="$1" bucket="$2"
  if ! rclone lsd "$remote:$bucket" --config="$RCLONE_CONFIG" >/dev/null 2>&1; then
    log INFO "Создаю бакет: $remote:$bucket"
    rclone mkdir "$remote:$bucket" --config="$RCLONE_CONFIG"
  fi
}

# -------------------------------------------
# 12) Общая обёртка повторных попыток с разбором вывода rclone
# -------------------------------------------
retry_rclone() {
  # Использование: retry_rclone <retries> <sleep> -- rclone ...args...
  local retries="$1" sleep_s="$2"; shift 2 || true
  local -a cmd=( "$@" )
  local attempt rc
  for attempt in $(jot - 1 "$retries"); do
    log INFO "Попытка $attempt/$retries: $(cmd_str "${cmd[@]}")"
    set +e
    # Стримим вывод rclone построчно, отмечая уровни
    "${cmd[@]}" 2>&1 | while IFS= read -r line; do
      if [[ "$line" =~ (ERROR|CRITICAL|Fatal|Failed) ]]; then
        log ERROR   "rclone: $line"
      elif [[ "$line" =~ (WARNING|WARN) ]]; then
        log WARNING "rclone: $line"
      elif [[ "$DRY_RUN" == "true" || "$line" =~ (Copied|Deleted|Moved|Transferred) ]]; then
        log INFO    "rclone: $line"
      else
        log DEBUG   "rclone: $line"
      fi
    done
    rc=${PIPESTATUS[0]}
    set -e
    case $rc in
      0) log INFO "Команда успешна"; return 0 ;;
      3) # "no files transferred/changed" для sync/copy — трактуем как успех
         log INFO "Изменений нет (rc=3) — считаем успешно"; return 0 ;;
    esac
    if (( attempt < retries )); then
      log WARNING "Ошибка (rc=$rc), повтор через $sleep_s"
      sleep "$sleep_s"
    else
      log ERROR "Команда не удалась после $retries попыток (rc=$rc)"
      return "$rc"
    fi
  done
}

# -------------------------------------------
# 13) Валидация результата (counts)
# -------------------------------------------
count_files() {
  # Подсчёт только файлов (не каталогов). Для S3 путь вида remote:bucket[/prefix]
  local s3path="$1"
  local n=0
  set +e
  n=$(rclone lsf --files-only --recursive --config="$RCLONE_CONFIG" "$s3path" 2>/dev/null | wc -l | tr -d ' ') || n=0
  set -e
  printf '%s' "$n"
}

validate_pair_counts() {
  local src="$1" dst="$2"
  [[ "$VALIDATE_MODE" == "counts" ]] || { log DEBUG "Валидация отключена (VALIDATE_MODE=$VALIDATE_MODE)"; return 0; }

  log INFO "Валидация (counts): $src  vs  $dst"
  local cs cd
  cs="$(count_files "$src")"
  cd="$(count_files "$dst")"
  if [[ "$cs" == "$cd" ]]; then
    log INFO "OK: файлов совпадает ($cs)"
    return 0
  else
    log WARNING "MISMATCH: source=$cs, dest=$cd"
    return 1
  fi
}

# -------------------------------------------
# 14) Обработка одного бакета
# -------------------------------------------
append_status() {
  # Потокобезопасная запись строки статуса в TSV
  # usage: append_status "<remote:bucket>" "<OK|FAIL>" "<msg>"
  local b="$1" st="$2" msg="${3:-}"
  {
    flock -x 9
    printf '%s\t%s\t%s\n' "$b" "$st" "$msg" >>"$STATUS_FILE"
  } 9>>"$STATUS_FILE"
}

process_bucket() {
  local spec="$1"  # "remote:bucket"
  [[ "$spec" == *:* ]] || { log ERROR "Некорректный spec: '$spec'"; append_status "$spec" "FAIL" "bad_spec"; ALL_OK=false; return 1; }

  local src_remote="${spec%%:*}"
  local src_bucket="${spec#*:}"

  # Назначение — bucket = имя remote, путь-префикс = имя исходного бакета
  local dst_bucket="$src_remote"
  local src="{$src_remote}:$src_bucket"
  local dst="minio:${dst_bucket}/${src_bucket}"

  # Бэкап-удалений на сегодня
  local today; today="$(date +%F)"
  local backup_dir="${DELETE_BACKUP_ROOT}/${today}/${src_remote}/${src_bucket}"

  # Гарантируем существование целевого бакета и корня для deleted
  create_bucket_if_absent "minio" "$dst_bucket"
  create_bucket_if_absent "minio" "${DELETE_BACKUP_ROOT#minio:}" || true

  log INFO "=== Начало: $spec ➜ $dst"

  # Общие флаги rclone
  local -a flags=(
    --fast-list
    --checksum
    --create-empty-src-dirs
    --s3-force-path-style
    --transfers="$RCLONE_TRANSFERS"
    --checkers="$RCLONE_CHECKERS"
    --retries="$RCLONE_RETRIES"
    --retries-sleep="$RCLONE_RETRIES_SLEEP"
    --stats="$RCLONE_STATS_INTERVAL"
    --stats-log-level=NOTICE
    --use-json-log
    --log-level="$RCLONE_LOG_LEVEL"
    --log-file="$RCLONE_JSONLOG"
    --buffer-size="$RCLONE_BUFFER_SIZE"
    --s3-upload-concurrency="$RCLONE_S3_UPLOAD_CONCURRENCY"
    --s3-chunk-size="$RCLONE_S3_CHUNK_SIZE"
    --backup-dir="$backup_dir"
    --config="$RCLONE_CONFIG"
  )

  [[ "$RCLONE_USE_MMAP" == "true" ]] && flags+=(--use-mmap)
  [[ "$DRY_RUN" == "true" ]] && { flags+=(--dry-run); log INFO "DRY_RUN: изменения НЕ применяются"; }
  [[ "$RCLONE_S3_INSECURE" == "true" ]] && flags+=(--no-check-certificate)

  # В режиме sync удалённые объекты попадут в --backup-dir, а лишнее на стороне MinIO будет «перемещено» туда же
  # В режиме copy удалений нет (backup-dir используется только для перезаписей).
  local -a cmd=( rclone "$OPERATION" "${flags[@]}" "$src" "$dst" )

  if retry_rclone 3 15 -- "${cmd[@]}"; then
    # Валидация
    if validate_pair_counts "$src" "$dst"; then
      log INFO "Готово: $spec"
      append_status "$spec" "OK" ""
      return 0
    else
      log WARNING "Валидация не сошлась: $spec"
      append_status "$spec" "FAIL" "validate"
      ALL_OK=false
      return 1
    fi
  else
    log ERROR "Сбой rclone для $spec"
    append_status "$spec" "FAIL" "rclone"
    ALL_OK=false
    return 1
  fi
}

export -f log die cmd_str retry_rclone validate_pair_counts count_files create_bucket_if_absent append_status process_bucket
export RCLONE_CONFIG RCLONE_JSONLOG RCLONE_LOG_LEVEL RCLONE_BUFFER_SIZE RCLONE_USE_MMAP
export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES RCLONE_RETRIES_SLEEP RCLONE_STATS_INTERVAL
export RCLONE_S3_UPLOAD_CONCURRENCY RCLONE_S3_CHUNK_SIZE RCLONE_S3_INSECURE
export DELETE_BACKUP_ROOT DRY_RUN OPERATION

# -------------------------------------------
# 15) Очистка устаревших версий (backup-deleted)
# -------------------------------------------
cleanup_deleted_retention() {
  log INFO "Очистка backup-deleted (старше ${DELETE_RETENTION_DAYS}d): $DELETE_BACKUP_ROOT"

  local -a del_cmd=(
    rclone delete "$DELETE_BACKUP_ROOT"
    --min-age "${DELETE_RETENTION_DAYS}d"
    --use-json-log
    --log-level="$RCLONE_LOG_LEVEL"
    --log-file="$RCLONE_JSONLOG"
    --config="$RCLONE_CONFIG"
  )
  [[ "$DRY_RUN" == "true" ]] && del_cmd+=(--dry-run)

  retry_rclone 3 10 -- "${del_cmd[@]}" || log WARNING "delete завершился с предупреждениями"

  local -a rmd_cmd=(
    rclone rmdirs "$DELETE_BACKUP_ROOT"
    --leave-root
    --use-json-log
    --log-level="$RCLONE_LOG_LEVEL"
    --log-file="$RCLONE_JSONLOG"
    --config="$RCLONE_CONFIG"
  )
  [[ "$DRY_RUN" == "true" ]] && rmd_cmd+=(--dry-run)

  retry_rclone 3 10 -- "${rmd_cmd[@]}" || log WARNING "rmdirs завершился с предупреждениями"
}

# -------------------------------------------
# 16) Итоговая сводка
# -------------------------------------------
generate_summary() {
  {
    echo "================================================================================"
    echo " ИТОГОВАЯ СВОДКА: $SCRIPT_NAME v$SCRIPT_VERSION"
    echo " Время: $(date)     DRY_RUN: $DRY_RUN"
    echo " Операция: $OPERATION     Параллелизм: $PARALLEL"
    echo " Конфиг rclone: $RCLONE_CONFIG"
    echo "================================================================================"
    printf "%-45s | %-6s | %s\n" "BUCKET" "STATE" "NOTE"
    echo "--------------------------------------------------------------------------------"
    awk -F'\t' '{printf "%-45s | %-6s | %s\n",$1,$2,$3}' "$STATUS_FILE" 2>/dev/null || true
    echo "--------------------------------------------------------------------------------"
    echo " Логи:"
    echo "   - Текстовый: $LOGFILE"
    echo "   - JSON rclone: $RCLONE_JSONLOG"
    echo "================================================================================"
  } | tee -a "$LOGFILE" >"$SUMMARY_TXT"
  log INFO "Сводка: $SUMMARY_TXT"
}

# -------------------------------------------
# 17) CLI разбор (минимально необходимый)
# -------------------------------------------
print_help() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Опции:
  --op=sync|copy           Операция rclone (по умолчанию: sync)
  --parallel=N             Кол-во параллельных потоков (по умолчанию: $PARALLEL)
  --dry-run[=true|false]   Тестовый прогон без изменений (по умолчанию: $DRY_RUN)
  --validate=none|counts   Валидация результата (по умолчанию: $VALIDATE_MODE)
  --buckets-file=FILE      Файл со списком "remote:bucket" (по одному в строке)
  --buckets="r1:b1 r2:b2"  Передать список бакетов через CLI (перекрывает файл)
  --help                   Эта справка

ENV можно использовать вместо/вместе с CLI:
  RCLONE_CONFIG, PARALLEL, OPERATION, DRY_RUN, VALIDATE_MODE, BUCKETS_FILE, BUCKETS_ENV, ...
EOF
}

parse_cli() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --op=*)          OPERATION="${arg#*=}" ;;
      --parallel=*)    PARALLEL="${arg#*=}" ;;
      --dry-run|--dry-run=true)  DRY_RUN=true ;;
      --dry-run=false) DRY_RUN=false ;;
      --validate=*)    VALIDATE_MODE="${arg#*=}" ;;
      --buckets-file=*)BUCKETS_FILE="${arg#*=}" ;;
      --buckets=*)     BUCKETS_ENV="${arg#*=}" ;;
      --help|-h)       print_help; exit 0 ;;
      *)               die "Неизвестная опция: $arg (см. --help)" ;;
    esac
  done
}

# -------------------------------------------
# 18) MAIN
# -------------------------------------------
main() {
  parse_cli "$@"
  init_logging
  rotate_logs
  check_commands
  check_rclone_version
  check_rclone_config
  setup_lock_and_traps

  log INFO "Хост: $(hostname -f 2>/dev/null || hostname), Пользователь: $(whoami)"
  log INFO "OPERATION=$OPERATION PARALLEL=$PARALLEL DRY_RUN=$DRY_RUN VALIDATE_MODE=$VALIDATE_MODE"
  log INFO "RCLONE: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES"

  load_buckets
  check_all_remotes
  check_ceph_status_soft

  # Гарантируем корневой бакет backup-deleted
  create_bucket_if_absent "minio" "${DELETE_BACKUP_ROOT#minio:}" || true

  log INFO "Запуск параллельной синхронизации (${#BUCKETS[@]} шт., -P $PARALLEL)"
  # В FreeBSD xargs поддерживает -P
  set +e
  printf '%s\0' "${BUCKETS[@]}" | xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'process_bucket "$1"' _ {}
  local xrc=$?
  set -e
  if (( xrc != 0 )); then
    log WARNING "Некоторые задания завершились с ошибками (xargs rc=$xrc)"
    ALL_OK=false
  fi

  cleanup_deleted_retention
  generate_summary

  $ALL_OK && return 0 || return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi