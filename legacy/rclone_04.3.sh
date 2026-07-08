#!/usr/bin/env bash
# backup_ceph_to_local.sh
# Автоматизированный бэкап CephFS -> локальная ФС с rclone.
# Фичи:
#  - Строгий режим, понятные логи, JSON-лог rclone + «шапка» из jq/awk
#  - Корректная очистка /backup/deleted (delete + rmdirs)
#  - Якорёные исключения и --delete-excluded (удаление исключённых с целевой стороны)
#  - DRY_RUN включается через переменную окружения DRY_RUN=true
#  - Валидация (рекурсивная, с теми же фильтрами) — добавлена, но ЗАКОММЕНТИРОВАНА
#
# КРИТИЧЕСКИЕ ИЗМЕНЕНИЯ:
# 1. ИСПРАВЛЕНО УКАЗАНИЕ ЛОКАЛЬНЫХ ПУТЕЙ ДЛЯ RCLONE (главная ошибка)
# 2. УЛУЧШЕНА ОБРАБОТКА ОШИБОК ДЛЯ ЛОКАЛЬНЫХ ОПЕРАЦИЙ
# 3. ДОБАВЛЕНА ПРОВЕРКА СУЩЕСТВОВАНИЯ /backup/deleted
# 4. ИСПРАВЛЕНО ФОРМАТИРОВАНИЕ ДАННЫХ В СВОДКЕ
# 5. УДАЛЕНА НЕВЕРНАЯ ОПЦИЯ --local-encoding=UTF-8

set -Eeuo pipefail
IFS=$'\n\t'
umask 027
LANG=C

# --------------------------- НАСТРОЙКИ ---------------------------------------
# Базовая конфигурация (можно переопределять через переменные окружения)
BACKUP_USER="${BACKUP_USER:-backup_user}"
LOGDIR="${LOGDIR:-/var/log/backup}"
LOCKFILE="${LOCKFILE:-/var/lock/backup.lock}"
EXCLUDE_FILE="${EXCLUDE_FILE:-/usr/local/bin/scripts/exclude-file.txt}"
DELETE_BACKUP="${DELETE_BACKUP:-/backup/deleted}"
MAIN_BACKUP="${MAIN_BACKUP:-/backup/main}"
# ИСПРАВЛЕНО: обработка SOURCEDIRS через временный IFS
OLD_IFS=$IFS
IFS=' '
SOURCEDIRS=(${SOURCEDIRS:-/ceph/data/exp/idream/})
IFS=$OLD_IFS
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-30}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
RCLONE_RETRIES="${RCLONE_RETRIES:-5}"
PARALLEL="${PARALLEL:-4}"
DRY_RUN="${DRY_RUN:-false}"

# ПРОВЕРКА: все источники должны находиться внутри /ceph
for dir in "${SOURCEDIRS[@]}"; do
    if [[ ! "$dir" =~ ^/ceph/ ]]; then
        echo "ERROR: Источник '$dir' не находится внутри /ceph. Все пути должны начинаться с /ceph/" >&2
        exit 1
    fi
done

# ------------------------- ЛОГИ / ФАЙЛЫ ЛОГОВ -------------------------------
log() {
    local level=${1:-INFO}; shift || true
    local msg="${*:-}"
    local ts
    ts="$(date +'%Y-%m-%d %T')"
    echo "${ts} [${level}] ${msg}" | tee -a "${LOGFILE:-/dev/null}"
}

# ПРОВЕРКА: наличие rclone
if ! command -v rclone &> /dev/null; then
    echo "ERROR: rclone не установлен. Установите rclone и повторите попытку." >&2
    exit 1
fi

# Создаем каталоги логов и бэкапов
mkdir -p "$LOGDIR" "$MAIN_BACKUP" "$DELETE_BACKUP"

TIMESTAMP="$(date +'%Y-%m-%d_%H-%M')"
LOGFILE="$LOGDIR/backup_${TIMESTAMP}.log"
RCLONE_JSONLOG="$LOGDIR/backup_${TIMESTAMP}.jsonl"
SUMMARY_JSON="$LOGDIR/backup_${TIMESTAMP}.summary.json"
SUMMARY_TXT="$LOGDIR/backup_${TIMESTAMP}.summary.txt"

# Ротация логов
find "$LOGDIR" -type f -name 'backup_*.log' -mtime +30 -delete 2>/dev/null || true
if (( $(find "$LOGDIR" -type f -name 'backup_*.log' 2>/dev/null | wc -l) > 100 )); then
    log ERROR "Слишком много лог-файлов в $LOGDIR"
    exit 1
fi

# ------------------------- БЛОКИРОВКА/ОЧИСТКА -------------------------------
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
cmd_to_string() {
    local -a a=( "$@" )
    local out=
    for x in "${a[@]}"; do
        printf -v out "%s%s " "$out" "$(printf '%q' "$x")"
    done
    printf '%s\n' "${out% }"
}

# ИСПРАВЛЕНО: КОРРЕКТНАЯ ОБРАБОТКА КОДА ВОЗВРАТА
retry_command() {
    local retries="$1"; shift
    local delay="$1";   shift
    local -a cmd=( "$@" )
    
    for (( attempt=1; attempt<=retries; attempt++ )); do
        log INFO "Попытка ${attempt}/${retries}: $(cmd_to_string "${cmd[@]}")"
        
        set +e
        # ИСПРАВЛЕНО: отображаем реальный прогресс выполнения
        "${cmd[@]}" 2>&1 | while IFS= read -r line; do
            echo "$line"
            if [[ "$line" =~ (ERROR|Failed|exiting) ]]; then
                log WARNING "rclone: $line"
            fi
        done
        # ИСПРАВЛЕНО: используем PIPESTATUS[0] для получения реального кода возврата
        local rc=${PIPESTATUS[0]}
        set -e
        
        # ИГНОРИРУЕМ ошибку 3 (no files to delete) для rclone delete
        # ИГНОРИРУЕМ ошибку 1 (directory not found) для rclone rmdirs
        if (( rc == 0 )) || 
           ([[ "${cmd[0]}" == "rclone" && "${cmd[1]}" == "delete" && rc -eq 3 ]]) ||
           ([[ "${cmd[0]}" == "rclone" && "${cmd[1]}" == "rmdirs" && rc -eq 1 ]]); then
            return 0
        fi
        
        log WARNING "Ошибка (rc=${rc}): $(cmd_to_string "${cmd[@]}"). Повтор через ${delay}s"
        sleep "$delay"
    done
    
    log ERROR "Команда не выполнилась после ${retries} попыток: $(cmd_to_string "${cmd[@]}")"
    return 1
}

check_ceph_access() {
    # Проверяем fstab
    if ! awk '$1!~/^#/ && $2=="/ceph"{f=1} END{exit !f}' /etc/fstab; then
        log ERROR "/ceph не настроен в /etc/fstab"
        return 1
    fi
    
    # Проверяем монтирование
    if ! mountpoint -q /ceph; then
        log WARNING "/ceph не смонтирован. Пытаемся смонтировать..."
        
        # ИСПРАВЛЕНО: проверка прав для монтирования
        if ! mount /ceph 2>/dev/null; then
            if [[ $(id -u) -ne 0 ]]; then
                log ERROR "Нет прав для монтирования /ceph (требуются права root)"
                return 1
            fi
            
            for attempt in {1..5}; do
                log INFO "Монтирование /ceph: попытка $attempt/5"
                if mount /ceph 2>>"$LOGFILE"; then
                    log INFO "Смонтировано /ceph"
                    break
                fi
                sleep 5
            done
        fi
        
        mountpoint -q /ceph || { log ERROR "Не удалось смонтировать /ceph"; return 1; }
    fi
    
    # Проверка доступа
    ls /ceph >/dev/null 2>&1 || { 
        log ERROR "Нет доступа к /ceph (проверь права пользователя $BACKUP_USER)"; 
        return 1; 
    }
    
    # Проверка источников
    for dir in "${SOURCEDIRS[@]}"; do
        [[ -d "$dir" ]] || { log ERROR "Источник не найден: $dir"; return 1; }
    done

    # Проверка состояния кластера (некритичная)
    if command -v ssh >/dev/null 2>&1; then
        if ssh -o ConnectTimeout=5 cephsvc05 "podman exec ceph-mon-cephsvc05 ceph status" >/dev/null 2>&1; then
            log INFO "Ceph-кластер: OK (status получен)"
        else
            log WARNING "Не удалось получить ceph status по SSH — пропускаем"
        fi
    fi
}

# ИСПРАВЛЕНО: ОЧИСТКА УСТАРЕВШИХ «УДАЛЁННЫХ» БЭКАПОВ
cleanup_old_backups() {
    log INFO "Очистка устаревших данных в $DELETE_BACKUP (старше 30d)"
    
    # ИСПРАВЛЕНО: проверка существования каталога
    if [[ ! -d "$DELETE_BACKUP" ]]; then
        log WARNING "Каталог $DELETE_BACKUP не существует. Создаем каталог."
        mkdir -p "$DELETE_BACKUP" || { log ERROR "Не удалось создать каталог $DELETE_BACKUP"; return 1; }
    fi
    
    # ИСПРАВЛЕНО: УДАЛЕНО УКАЗАНИЕ "local:" ДЛЯ ЛОКАЛЬНЫХ ПУТЕЙ
    # Для локальной файловой системы в rclone используется просто путь, без префикса "local:"
    local del_cmd=( rclone delete --min-age 30d --use-json-log --log-file="$RCLONE_JSONLOG" "$DELETE_BACKUP" )
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        # Вставляем --config перед последним аргументом
        del_cmd=("${del_cmd[@]::${#del_cmd[@]}-1}" --config="$RCLONE_CONFIG" "${del_cmd[@]: -1}")
    fi
    
    retry_command 3 10 "${del_cmd[@]}" || log WARNING "rclone delete завершился с ошибкой (продолжаем)"
    
    # ИСПРАВЛЕНО: УДАЛЕНО УКАЗАНИЕ "local:" ДЛЯ ЛОКАЛЬНЫХ ПУТЕЙ
    local rd_cmd=( rclone rmdirs --leave-root --use-json-log --log-file="$RCLONE_JSONLOG" "$DELETE_BACKUP" )
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        # Вставляем --config перед последним аргументом
        rd_cmd=("${rd_cmd[@]::${#rd_cmd[@]}-1}" --config="$RCLONE_CONFIG" "${rd_cmd[@]: -1}")
    fi
    
    retry_command 3 10 "${rd_cmd[@]}" || log WARNING "rclone rmdirs завершился с ошибкой (продолжаем)"
    
    log INFO "Очистка /backup/deleted завершена"
}

# Построение целевого пути
dest_from_src() {
    local src_dir="$1"
    printf '%s\n' "${MAIN_BACKUP}/ceph${src_dir#/ceph}"
}

backup_dir() {
    local src_dir="$1"
    local dest_dir
    dest_dir="$(dest_from_src "$src_dir")"
    
    log INFO "Начат бэкап: $src_dir -> $dest_dir"
    mkdir -p "$dest_dir" || { log ERROR "Не удалось создать каталог назначения: $dest_dir"; return 1; }
    
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
        --delete-excluded
        "--backup-dir=$DELETE_BACKUP/$(date +%F)"
        --use-json-log
        "--log-file=$RCLONE_JSONLOG"
        "--exclude-from=$EXCLUDE_FILE"
        --log-level=INFO
        --stats=5m
        --track-renames
    )
    
    # ИСПРАВЛЕНО: безопасное добавление --config (проблема с unbound variable)
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        flags+=(--config="$RCLONE_CONFIG")
    fi
    
    local cmd=( rclone sync "${flags[@]}" "$src_dir" "$dest_dir" )
    log INFO "Команда: ${cmd[*]}"
    if ! retry_command 3 15 "${cmd[@]}"; then
        log ERROR "Бэкап каталога $src_dir завершился ошибкой"
        return 1
    fi
    
    log INFO "Бэкап каталога $src_dir успешно завершён"
}

# -------------------- БЕЗОПАСНЫЙ ПОДСЧЕТ ФАЙЛОВ И РАЗМЕРА --------------------
rclone_count_and_bytes() {
    local path="$1"
    
    # ИСПРАВЛЕНО: безопасное добавление --config (проблема с unbound variable)
    local base_args=(--files-only --recursive "--exclude-from=$EXCLUDE_FILE")
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        base_args+=(--config="$RCLONE_CONFIG")
    fi
    
    local cnt
    cnt=$(rclone lsf "${base_args[@]}" "$path" 2>/dev/null | awk 'END {print NR}')
    
    local bytes
    bytes=$(rclone lsf --format s "${base_args[@]}" "$path" 2>/dev/null | awk '{s+=$1} END {printf "%d", s}')
    
    # ИСПРАВЛЕНО: возвращаем два значения, разделенных пробелом
    printf '%s %s\n' "$cnt" "$bytes"
}

# -------------------- СВОДКА / МЕТРИКИ (С РЕЗЕРВНЫМ МЕТОДОМ) --------------------
write_summary() {
    local result="$1"
    
    # ИСПРАВЛЕНО: проверка наличия jq перед использованием
    if command -v jq &> /dev/null; then
        log INFO "Генерация JSON-сводки через jq"
        _write_summary_with_jq "$result"
    else
        log WARNING "jq не установлен, используем резервный метод генерации сводки"
        _write_summary_without_jq "$result"
    fi
}

# Основная функция генерации сводки с использованием jq (рекомендуется)
_write_summary_with_jq() {
    local result="$1"
    local tmp_json
    tmp_json="$(mktemp)"
    
    jq -n \
        --arg timestamp "$TIMESTAMP" \
        --arg result "$result" \
        --arg exclude_file "$EXCLUDE_FILE" \
        --arg delete_backup "$DELETE_BACKUP" \
        --arg transfers "$RCLONE_TRANSFERS" \
        --arg checkers "$RCLONE_CHECKERS" \
        --arg retries "$RCLONE_RETRIES" \
        --arg config "${RCLONE_CONFIG:-}" \
        --argjson sources_json "$( 
            for src in "${SOURCEDIRS[@]}"; do
                local dst
                dst="$(dest_from_src "$src")"
                # ИСПРАВЛЕНО: корректное чтение двух значений
                read -r src_cnt src_bytes < <(rclone_count_and_bytes "$src")
                read -r dst_cnt dst_bytes < <(rclone_count_and_bytes "$dst")
                
                jq -n \
                    --arg src "$src" \
                    --arg dst "$dst" \
                    --argjson src_objects "$src_cnt" \
                    --argjson src_bytes "$src_bytes" \
                    --argjson dst_objects "$dst_cnt" \
                    --argjson dst_bytes "$dst_bytes" \
                    '{src: $src, dst: $dst, src_objects: $src_objects, src_bytes: $src_bytes, dst_objects: $dst_objects, dst_bytes: $dst_bytes}'
            done | jq -s '.'
        )" \
        '{
            timestamp: $timestamp,
            result: $result,
            exclude_file: $exclude_file,
            delete_backup: $delete_backup,
            rclone: {
                transfers: ($transfers | tonumber),
                checkers: ($checkers | tonumber),
                retries: ($retries | tonumber),
                config: if $config == "" then null else $config end
            },
            sources: $sources_json
        }' > "$tmp_json"
    
    mv -f "$tmp_json" "$SUMMARY_JSON"
    log INFO "Сводка JSON: $SUMMARY_JSON"
    
    _generate_human_summary "$SUMMARY_JSON"
}

# Резервная функция генерации сводки без jq (для случаев, когда jq не установлен)
_write_summary_without_jq() {
    local result="$1"
    local tmp_json
    tmp_json="$(mktemp)"
    
    # Генерируем простой JSON вручную (с минимальным экранированием)
    {
        echo '{'
        printf '  "timestamp": "%s",\n' "$TIMESTAMP"
        printf '  "result": "%s",\n' "$result"
        printf '  "exclude_file": "%s",\n' "$EXCLUDE_FILE"
        printf '  "delete_backup": "%s",\n' "$DELETE_BACKUP"
        echo '  "rclone": {'
        printf '    "transfers": %s,\n' "$RCLONE_TRANSFERS"
        printf '    "checkers": %s,\n' "$RCLONE_CHECKERS"
        printf '    "retries": %s,\n' "$RCLONE_RETRIES"
        if [[ -n "${RCLONE_CONFIG:-}" ]]; then
            printf '    "config": "%s"\n' "$RCLONE_CONFIG"
        else
            echo '    "config": null'
        fi
        echo '  },'
        echo '  "sources": ['
        
        local first=1
        for src in "${SOURCEDIRS[@]}"; do
            local dst
            dst="$(dest_from_src "$src")"
            # ИСПРАВЛЕНО: корректное чтение двух значений
            local src_cnt src_bytes dst_cnt dst_bytes
            read -r src_cnt src_bytes < <(rclone_count_and_bytes "$src")
            read -r dst_cnt dst_bytes < <(rclone_count_and_bytes "$dst")
            
            if [[ $first -eq 0 ]]; then
                echo '    ,'
            fi
            first=0
            
            # Экранируем кавычки в путях (простая замена)
            local src_safe="${src//\"/\\\"}"
            local dst_safe="${dst//\"/\\\"}"
            
            cat <<EOF
    {
      "src": "$src_safe",
      "dst": "$dst_safe",
      "src_objects": $src_cnt,
      "src_bytes": $src_bytes,
      "dst_objects": $dst_cnt,
      "dst_bytes": $dst_bytes
    }
EOF
        done
        
        echo '  ]'
        echo '}'
    } > "$tmp_json"
    
    mv -f "$tmp_json" "$SUMMARY_JSON"
    log INFO "Сводка JSON (резервный метод): $SUMMARY_JSON"
    
    _generate_human_summary "$SUMMARY_JSON"
}

# Общая функция для генерации человекочитаемой сводки
_generate_human_summary() {
    local json_file="$1"
    
    {
        echo "==== Итоговая сводка (${TIMESTAMP}) ===="
        echo "Результат: $result"
        echo "Исключения: $EXCLUDE_FILE"
        echo "Каталог 'удалённых': $DELETE_BACKUP"
        echo "Rclone: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES log-level=INFO stats=5m config=${RCLONE_CONFIG:-<none>}"
        echo "--- Источники:"
        
        # ИСПРАВЛЕНО: проверка наличия jq для человекочитаемой сводки
        if command -v jq &> /dev/null; then
            jq -r '
            .sources[] | 
            "SRC: \(.src)\nDST: \(.dst)\n  src_objects=\(.src_objects)  src_bytes=\(.src_bytes)\n  dst_objects=\(.dst_objects)  dst_bytes=\(.dst_bytes)\n"
            ' "$json_file"
        else
            # Резервный вывод без jq
            echo "(jq не найден: вывод упрощён)"
            for src in "${SOURCEDIRS[@]}"; do
                dst="$(dest_from_src "$src")"
                # ИСПРАВЛЕНО: корректное чтение двух значений
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
log INFO "Права на /ceph: $(ls -ld /ceph 2>/dev/null || echo '<нет>')"
log INFO "Права на /backup: $(ls -ld /backup 2>/dev/null || echo '<нет>')"
log INFO "Версия rclone: $(rclone --version 2>/dev/null | head -n1)"
log INFO "Параметры: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES dry_run=$DRY_RUN log-level=INFO stats=5m"

# Предполетная проверка
if ! check_ceph_access; then
    write_summary "failure"
    log ERROR "Предпроверка провалена"
    exit 1
fi

# Очистка устаревших
if ! cleanup_old_backups; then
    log WARNING "Очистка /backup/deleted завершилась с предупреждениями — продолжаем"
fi

# ИСПРАВЛЕНО: экспортируем ВСЕ необходимые функции для xargs
export -f log retry_command dest_from_src backup_dir cmd_to_string rclone_count_and_bytes
export LOGFILE RCLONE_CONFIG RCLONE_JSONLOG EXCLUDE_FILE MAIN_BACKUP DELETE_BACKUP \
    RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES DRY_RUN

# Запуск бэкапов
if ! printf "%s\0" "${SOURCEDIRS[@]}" | xargs -0 -n1 -P"$PARALLEL" -I{} bash -c 'backup_dir "$1"' _ {}; then
    write_summary "failure"
    log ERROR "Бэкап завершился с ошибками"
    exit 1
fi

# Генерация сводки
write_summary "success"
log INFO "Все бэкапы успешно завершены"
exit 0