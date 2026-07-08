#!/usr/bin/env bash
# backup_ceph_to_local.sh
# Автоматизированный бэкап CephFS -> локальная ФС с rclone.
# Фичи:
#  - Строгий режим, понятные логи, JSON-лог rclone + «шапка» из jq/awk
#  - Корректная очистка /backup/deleted (delete + rmdirs)
#  - Якорёные исключения и --delete-excluded (удаление исключённых с целевой стороны)
#  - DRY_RUN включается через переменную окружения DRY_RUN=true
#  - Валидация (рекурсивная, с теми же фильтрами) — добавлена, но ЗАКОММЕНТИРОВАНА

set -Eeuo pipefail
IFS=$'\n\t'
umask 027
LANG=C

# --------------------------- НАСТРОЙКИ ---------------------------------------
# Базовая конфигурация (можно переопределять через переменные окружения)
BACKUP_USER="${BACKUP_USER:-backup_user}"
LOGDIR="${LOGDIR:-/var/log/backup}"
LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"  # см. комментарий выше про якоря
DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"
SOURCEDIRS=(${SOURCEDIRS:-/ceph/data/exp/idream/}) # можно указать несколько через пробел
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
PARALLEL="${PARALLEL:-4}"            # степень параллелизма для xargs
DRY_RUN="${DRY_RUN:-false}"          # true -> добавит --dry-run в rclone sync

# ------------------------- ЛОГИ / ФАЙЛЫ ЛОГОВ -------------------------------
# Функция логирования должна быть доступна СРАЗУ (до инициализации переменных логов),
# поэтому, если LOGFILE ещё не задан, пишем в /dev/null.
log() {
  local level=${1:-INFO}; shift || true
  local msg="${*:-}"
  local ts
  ts="$(date +'%Y-%m-%d %T')"
  echo "${ts} [${level}] ${msg}" | tee -a "${LOGFILE:-/dev/null}"
}

# Каталоги логов и бэкапов — создаём заранее, чтобы не споткнуться дальше
mkdir -p "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"

TIMESTAMP="$(date +'%Y-%m-%d_%H-%M')"
LOGFILE="$LOGDIR/backup_${TIMESTAMP}.log"          # текстовый лог САМОГО СКРИПТА (человекочитаемый)
RCLONE_JSONLOG="$LOGDIR/backup_${TIMESTAMP}.jsonl"  # JSON-лог rclone (--use-json-log)
SUMMARY_JSON="$LOGDIR/backup_${TIMESTAMP}.summary.json"  # сводка JSON (по завершении)
SUMMARY_TXT="$LOGDIR/backup_${TIMESTAMP}.summary.txt"    # «шапка» человекочитаемая

# Ротация текстовых логов скрипта (старше 30 дней)
find "$LOGDIR" -type f -name 'backup_*.log' -mtime +30 -delete || true
# Предел количества логов на всякий
if (( $(find "$LOGDIR" -type f -name 'backup_*.log' | wc -l) > 100 )); then
  log ERROR "Слишком много лог-файлов в $LOGDIR"
  exit 1
fi

# ------------------------- БЛОКИРОВКА/ОЧИСТКА -------------------------------
# Flock — не позволяем параллельный запуск
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  log ERROR "Скрипт уже запущен. Выход."
  exit 1
fi

cleanup() {
  flock -u 200 || true
  rm -f "$LOCKFILE" || true
}
trap cleanup INT TERM EXIT

# ------------------------- RCLONE КОНФИГ ------------------------------------
# Если rclone config существует — используем его; иначе работаем локально без него
RCLONE_CONFIG="$(rclone config file 2>/dev/null | awk -F': ' 'NR==1{print $2}' | xargs || true)"
if [[ -n "${RCLONE_CONFIG:-}" && -r "$RCLONE_CONFIG" ]]; then
  export RCLONE_CONFIG
  log INFO "Используется конфигурационный файл rclone: $RCLONE_CONFIG"
else
  log WARNING "Конфигурационный файл rclone не найден/недоступен, продолжаем без --config"
  unset RCLONE_CONFIG
fi
export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES

# ------------------------- ПРОВЕРКА ИСКЛЮЧЕНИЙ ------------------------------
# Файл исключений обязателен. В нём должны быть якорёные пути относительно КОРНЯ источника:
# /data/**
# /data3/**
log INFO "Проверка exclude-файла: $EXCLUDE_FILE"
if [[ ! -f "$EXCLUDE_FILE" ]]; then
  log ERROR "Файл исключений $EXCLUDE_FILE не найден"
  exit 1
fi
if [[ ! -r "$EXCLUDE_FILE" ]]; then
  log ERROR "Файл исключений $EXCLUDE_FILE не доступен для чтения"
  exit 1
fi
if [[ ! -s "$EXCLUDE_FILE" ]]; then
  log WARNING "Файл исключений $EXCLUDE_FILE пустой"
fi

# ------------------------- ХЕЛПЕРЫ ------------------------------------------
retry_command() {
  # Универсальный ретрайер: retry_command "команда" [повторы] [задержка_сек]
  local retries="$1"; shift
  local delay="$1";   shift
  local -a cmd=( "$@" )

  # Красиво собрать команду в одну строку с корректным экранированием
  local cmd_str
  cmd_str="$(printf '%q ' "${cmd[@]}")"

  local rc=0
  for ((attempt=1; attempt<=retries; attempt++)); do
    log INFO "Попытка ${attempt}/${retries}: ${cmd_str}"
    # ВАЖНО: запускаем массивом, без eval; stdout/stderr уходит в текстовый лог скрипта
    "${cmd[@]}" >>"$LOGFILE" 2>&1
    rc=$?
    if (( rc == 0 )); then
      return 0
    fi
    log WARNING "Ошибка (rc=${rc}): ${cmd_str}. Повтор через ${delay}s"
    sleep "$delay"
  done

  log ERROR "Команда не выполнилась после ${retries} попыток: ${cmd_str}"
  return "$rc"
}

check_ceph_access() {
  # Проверяем, что /ceph есть в fstab и смонтирован, и что источники доступны
  if ! awk '$1!~/^#/ && $2=="/ceph"{f=1} END{exit !f}' /etc/fstab; then
    log ERROR "/ceph не настроен в /etc/fstab"
    return 1
  fi
  if ! mountpoint -q /ceph; then
    log WARNING "/ceph не смонтирован. Пытаемся смонтировать..."
    for attempt in {1..5}; do
      log INFO "Монтирование /ceph: попытка $attempt/5"
      if mount /ceph 2>>"$LOGFILE"; then
        log INFO "Смонтировано /ceph"
        break
      fi
      sleep 5
    done
    mountpoint -q /ceph || { log ERROR "Не удалось смонтировать /ceph"; return 1; }
  fi
  ls /ceph >/dev/null 2>&1 || { log ERROR "Нет доступа к /ceph (проверь права пользователя $BACKUP_USER)"; return 1; }
  for dir in "${SOURCEDIRS[@]}"; do
    [[ -d "$dir" ]] || { log ERROR "Источник не найден: $dir"; return 1; }
  done

  # Некритичная проверка состояния кластера (по SSH)
  if command -v ssh >/dev/null 2>&1; then
    if ssh -o ConnectTimeout=5 cephsvc05 "podman exec ceph-mon-cephsvc05 ceph status" >/dev/null 2>&1; then
      log INFO "Ceph-кластер: OK (status получен)"
    else
      log WARNING "Не удалось получить ceph status по SSH — пропускаем"
    fi
  fi
}

# Очистка устаревших «удалённых» бэкапов в /backup/deleted
cleanup_old_backups() {
  log INFO "Очистка устаревших данных в $DELETE_BACKUP (старше 30d)"
  [[ -d "$DELETE_BACKUP" ]] || { log ERROR "Каталог $DELETE_BACKUP отсутствует"; return 1; }

  # delete старше 30 дней
  local del_cmd=( rclone delete --min-age 30d --use-json-log --log-file="$RCLONE_JSONLOG" )
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    del_cmd+=( "--config=$RCLONE_CONFIG" )
  fi
  del_cmd+=( "local:$DELETE_BACKUP" )
  retry_command 3 10 "${del_cmd[@]}" || log WARNING "rclone delete завершился с ошибкой (продолжаем)"

  # rmdirs пустых папок (корень оставляем)
  local rd_cmd=( rclone rmdirs --leave-root --use-json-log --log-file="$RCLONE_JSONLOG" )
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    rd_cmd+=( "--config=$RCLONE_CONFIG" )
  fi
  rd_cmd+=( "local:$DELETE_BACKUP" )
  retry_command 3 10 "${rd_cmd[@]}" || log WARNING "rclone rmdirs завершился с ошибкой (продолжаем)"

  log INFO "Очистка /backup/deleted завершена"
}

# Построить целевой путь из источника: /ceph/... -> /backup/main/ceph/...
dest_from_src() {
  local src_dir="$1"
  printf '%s\n' "${MAIN_BACKUP}/ceph${src_dir#/ceph}"
}

backup_dir() {
  # Бэкап одного каталога источника
  local src_dir="$1"
  local dest_dir
  dest_dir="$(dest_from_src "$src_dir")"

  log INFO "Начат бэкап: $src_dir -> $dest_dir"
  mkdir -p "$dest_dir" || { log ERROR "Не удалось создать каталог назначения: $dest_dir"; return 1; }

  # Флаги rclone
  local flags=()
  [[ "$DRY_RUN" == "true" ]] && flags+=(--dry-run)

  flags+=(
    --progress
    --links
    --fast-list
    --create-empty-src-dirs
    --checksum
    "--transfers=$RCLONE_TRANSFERS"
    "--checkers=$RCLONE_CHECKERS"
    "--retries=$RCLONE_RETRIES"
    "--retries-sleep=10s"
    --update
    --delete-excluded                         # удалять исключённые на целевой стороне
    "--backup-dir=$DELETE_BACKUP/$(date +%F)" # удалённые складываем по датам
    # ЛОГИ rclone: JSON в отдельный файл
    --use-json-log
    "--log-file=$RCLONE_JSONLOG"
    "--exclude-from=$EXCLUDE_FILE"
  )
  [[ -n "${RCLONE_CONFIG:-}" ]] && flags+=(--config="$RCLONE_CONFIG")

  local cmd=( rclone sync "${flags[@]}" "$src_dir" "$dest_dir" )
  log INFO "Команда: $(printf '%q ' "${cmd[@]}")"
  if ! retry_command 3 15 "${cmd[@]}"; then
    log ERROR "Бэкап каталога $src_dir завершился ошибкой"
    return 1
  fi

  # ---- G) Валидация — рекурсивно и с теми же фильтрами (ОТКЛЮЧЕНО) ----
  # Функция validate_backup определена ниже и использует те же exclude и config.
  # По умолчанию вызов отключён. Чтобы включить: уберите символы '#' на двух строках ниже.
  #
  # if ! validate_backup "$src_dir" "$dest_dir"; then
  #   log ERROR "Валидация не пройдена для $src_dir"
  #   return 1
  # fi

  log INFO "Бэкап каталога $src_dir успешно завершён"
}

# -------------------- [G) Валидация (ЗАКОММЕНТИРОВАНО ПО УМОЛЧАНИЮ)] ---------
# Ниже — функция валидации. Она РЕКУРСИВНО сравнивает число файлов в src и dst,
# применяя ТОТ ЖЕ exclude-файл. По умолчанию она не вызывается.
# Чтобы включить — раскомментируй вызов в backup_dir().
#
# validate_backup() {
#   local src="$1"
#   local dst="$2"
#   log INFO "Валидация: $src -> $dst (рекурсивно, с фильтрами)"
#
#   local base_args=(--files-only --recursive "--exclude-from=$EXCLUDE_FILE")
#   [[ -n "${RCLONE_CONFIG:-}" ]] && base_args+=("--config=$RCLONE_CONFIG")
#
#   local src_count dst_count
#   src_count=$(rclone lsf "${base_args[@]}" "$src" | wc -l || echo 0)
#   dst_count=$(rclone lsf "${base_args[@]}" "$dst" | wc -l || echo 0)
#
#   if [[ "$src_count" -eq "$dst_count" ]]; then
#     log INFO "OK: файлов равно ($src_count)"
#     return 0
#   else
#     log ERROR "Mismatch: src=$src_count, dst=$dst_count"
#     return 1
#   fi
# }

# -------------------- СВОДКА / МЕТРИКИ ----------------------------------------
# Безопасный расчёт количества файлов и байт (с теми же exclude).
# Для байт используем быстрый метод через lsf --format sp (суммируем размеры).

rclone_count_and_bytes() {
  local path="$1"

  local lsf_common=( --files-only --recursive --exclude-from="$EXCLUDE_FILE" )
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    lsf_common+=( "--config=$RCLONE_CONFIG" )
  fi

  # Кол-во файлов
  local cnt
  cnt=$(rclone lsf "${lsf_common[@]}" "$path" | wc -l | tr -d '[:space:]')

  # Сумма байт (формат 's' отдаёт размеры файлов)
  local size_common=( --files-only --recursive --format s --exclude-from="$EXCLUDE_FILE" )
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    size_common+=( "--config=$RCLONE_CONFIG" )
  fi
  local bytes
  bytes=$(rclone lsf "${size_common[@]}" "$path" | awk '{s+=$1} END{printf "%s", s+0}')

  printf '%s %s\n' "$cnt" "$bytes"
}

# Сводка по всем источникам -> JSON + «шапка»
write_summary() {
  local result="$1"  # success|failure
  local tmp_json
  tmp_json="$(mktemp)"
  {
    echo '{'
    printf '  "timestamp": "%s",\n' "$TIMESTAMP"
    printf '  "result": "%s",\n' "$result"
    printf '  "exclude_file": "%s",\n' "$EXCLUDE_FILE"
    printf '  "delete_backup": "%s",\n' "$DELETE_BACKUP"
    printf '  "rclone": { "transfers": %s, "checkers": %s, "retries": %s, "config": %s },\n' \
      "$RCLONE_TRANSFERS" "$RCLONE_CHECKERS" "$RCLONE_RETRIES" \
      "$([[ -n "${RCLONE_CONFIG:-}" ]] && printf '"%s"' "$RCLONE_CONFIG" || printf 'null')"
    echo '  "sources": ['
    local first=1
    for src in "${SOURCEDIRS[@]}"; do
      local dst
      dst="$(dest_from_src "$src")"
      # Подсчёты (после бэкапа, уже без параллелизма)
      local src_cnt src_bytes dst_cnt dst_bytes
      read -r src_cnt src_bytes < <(rclone_count_and_bytes "$src")
      read -r dst_cnt dst_bytes < <(rclone_count_and_bytes "$dst")

      [[ $first -eq 0 ]] && echo '    ,' || true
      first=0
      printf '    { "src": "%s", "dst": "%s", "src_objects": %s, "src_bytes": %s, "dst_objects": %s, "dst_bytes": %s }\n' \
        "$src" "$dst" "${src_cnt:-0}" "${src_bytes:-0}" "${dst_cnt:-0}" "${dst_bytes:-0}"
    done
    echo '  ]'
    echo '}'
  } > "$tmp_json"

  mv -f "$tmp_json" "$SUMMARY_JSON"
  log INFO "Сводка JSON: $SUMMARY_JSON"

  # «Шапка» (человекочитаемая): если есть jq — красиво; иначе простой awk/printf
  {
    echo "==== Итоговая сводка (${TIMESTAMP}) ===="
    echo "Результат: $result"
    echo "Исключения: $EXCLUDE_FILE"
    echo "Каталог 'удалённых': $DELETE_BACKUP"
    echo "Rclone: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES config=${RCLONE_CONFIG:-<none>}"
    echo "--- Источники:"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        .sources[]
        | "SRC: \(.src)\nDST: \(.dst)\n  src_objects=\(.src_objects)  src_bytes=\(.src_bytes)\n  dst_objects=\(.dst_objects)  dst_bytes=\(.dst_bytes)\n"
      ' "$SUMMARY_JSON"
    else
      # Примитивная «шапка», если jq нет
      awk 'BEGIN{print "(jq не найден: вывод упрощён)"} {print}' </dev/null
      for src in "${SOURCEDIRS[@]}"; do
        dst="$(dest_from_src "$src")"
        read -r sc sb < <(rclone_count_and_bytes "$src")
        read -r dc db < <(rclone_count_and_bytes "$dst")
        echo "SRC: $src"
        echo "DST: $dst"
        echo "  src_objects=$sc  src_bytes=$sb"
        echo "  dst_objects=$dc  dst_bytes=$db"
        echo
      done
    fi
  } | tee -a "$SUMMARY_TXT" "$LOGFILE" >/dev/null

  log INFO "Человекочитаемая сводка: $SUMMARY_TXT"
}

# -------------------- ОСНОВНОЙ ПОТОК -----------------------------------------
log INFO "***** Старт бэкапа *****"
log INFO "Пользователь: $(whoami)"
log INFO "Права на /ceph: $(ls -ld /ceph || echo '<нет>')"
log INFO "Права на /backup: $(ls -ld /backup || echo '<нет>')"
log INFO "Версия rclone: $(rclone --version | head -n1)"
log INFO "Параметры: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES dry_run=$DRY_RUN"

# Предполетная проверка
check_ceph_access || { write_summary "failure"; log ERROR "Предпроверка провалена"; exit 1; }

# Очистка устаревших
cleanup_old_backups || log WARNING "Очистка /backup/deleted завершилась с предупреждениями — продолжаем"

# Прогон по источникам (параллельно)
# ВАЖНО: функции и переменные — экспортируем для xargs
export -f log retry_command dest_from_src backup_dir
export LOGFILE RCLONE_CONFIG RCLONE_JSONLOG EXCLUDE_FILE MAIN_BACKUP DELETE_BACKUP \
       RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES DRY_RUN

# Старт бэкапов
printf "%s\0" "${SOURCEDIRS[@]}" | xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'backup_dir "$1"' _ {} \
  || { write_summary "failure"; log ERROR "Бэкап завершился с ошибками"; exit 1; }

# Сводка
write_summary "success"
log INFO "Все бэкапы успешно завершены"
exit 0
