#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Скрипт: listslots
#
# Назначение:
#   Показать карту всех слотов и дисков для обеих корзин.
#
# Выводит для каждого слота:
#   - название слота (из sysfs)
#   - /dev/sdX (или "-" если пусто)
#   - SCSI target
#   - SCSI-адрес
#   - статус (занят / пусто)
#   - модель диска через lsscsi
#
# Топология сервера:
#   target 0..23   -> enclosure 0:0:24:0 -> IN-WIN RS-424-07 -> slot = target + 1
#   target 24      -> зарезервирован (адрес enclosure 0:0:24:0)
#   target 25..36  -> enclosure 0:0:35:0 -> IN-WIN RS-212-07 -> slot = target - 24
#
# Важное замечание по именам элементов sysfs:
#   Ядро регистрирует директории слотов с trailing-пробелами,
#   например: "Bay Slot 03  " (два пробела в конце).
#   Имена используются напрямую из glob-итерации bash без обрезки.
# ============================================================


# ------------------------------------------------------------
# Проверка: путь существует или является симлинком
# ------------------------------------------------------------
path_exists_or_link() {
    local p="$1"
    [[ -e "$p" || -L "$p" ]]
}


# ------------------------------------------------------------
# Извлечение номера слота из имени элемента sysfs.
#
# Примеры:
#   "Bay Slot 03  " -> 3
#   "Slot 11  "     -> 11
#   "slot07"        -> 7
#
# tail -n1 берёт последнее найденное число, что защищает
# от имён вида "Bay 2 Slot 03".
# ------------------------------------------------------------
extract_slot_number() {
    local name="$1"
    local num
    num="$(echo "$name" | grep -oE '[0-9]+' | tail -n1 || true)"
    if [ -n "$num" ]; then
        echo $((10#$num))
    else
        echo ""
    fi
}


# ------------------------------------------------------------
# Получение описания диска через lsscsi.
#
# Возвращает строку вида "ATA ST18000NM000J-2T SN02"
# или пустую строку, если lsscsi недоступен.
# ------------------------------------------------------------
get_disk_desc() {
    local disk="$1"
    if command -v lsscsi >/dev/null 2>&1; then
        lsscsi -g | awk -v d="/dev/$disk" '
            $0 ~ d {
                out=""
                for (i=3; i<=NF; i++) {
                    if ($i ~ /^\/dev\//) break
                    out = out $i " "
                }
                sub(/[[:space:]]+$/, "", out)
                print out
                exit
            }
        '
    fi
}


# ------------------------------------------------------------
# Поиск /dev/sdX по SCSI-адресу через sysfs.
#
# Перебирает все /sys/block/sd*, сравнивает resolved SCSI-адрес.
# Возвращает имя устройства (например, "sdae") или пустую строку.
#
# Примечание по производительности:
#   При 36 слотах выполняется 36 × N итераций, где N — число
#   дисков. Для интерактивного использования приемлемо.
# ------------------------------------------------------------
find_disk_by_scsi() {
    local scsi_addr="$1"
    local b b_scsi

    for b in /sys/block/sd*; do
        path_exists_or_link "$b/device" || continue
        b_scsi="$(basename "$(readlink -f "$b/device")" 2>/dev/null || true)"
        if [ "$b_scsi" = "$scsi_addr" ]; then
            basename "$b"
            return 0
        fi
    done
    return 1
}


# ------------------------------------------------------------
# Печать заголовка таблицы
# ------------------------------------------------------------
print_header() {
    printf "%-14s %-8s %-10s %-14s %-8s %-s\n" \
        "СЛОТ" "ДИСК" "TARGET" "SCSI-АДРЕС" "СТАТУС" "МОДЕЛЬ / ОПИСАНИЕ"
    printf "%-14s %-8s %-10s %-14s %-8s %-s\n" \
        "--------------" "--------" "----------" "--------------" "--------" "------------------------------"
}


# ------------------------------------------------------------
# Обработка одной корзины.
#
# Аргументы:
#   $1 - адрес enclosure (например: 0:0:24:0)
#   $2 - название корзины для вывода
#   $3 - режим расчёта target:
#          big   -> target = slot - 1       (RS-424-07, targets 0..23)
#          small -> target = slot + 24      (RS-212-07, targets 25..36)
# ------------------------------------------------------------
process_enclosure() {
    local enc="$1"
    local enc_name="$2"
    local mode="$3"

    local enc_dir="/sys/class/enclosure/$enc"

    echo
    echo "============================================================"
    echo "Корзина: $enc_name"
    echo "Адрес  : $enc"
    echo "============================================================"

    if [ ! -d "$enc_dir" ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: каталог корзины не найден: $enc_dir"
        return
    fi

    print_header

    local d base slot target scsi_addr disk desc status

    # Тело таблицы передаётся через pipe в sort -V,
    # чтобы строки сортировались по естественному порядку номеров
    # ("Bay Slot 9" раньше "Bay Slot 10").
    # Заголовок печатается до цикла и в сортировку не попадает.
    for d in "$enc_dir"/*; do
        path_exists_or_link "$d" || continue
        base="$(basename "$d")"

        # Пропускаем служебные записи sysfs
        case "$base" in
            device|power|subsystem|components|id|uevent)
                continue
                ;;
        esac

        slot="$(extract_slot_number "$base")"

        if [ -z "$slot" ]; then
            printf "%-14s %-8s %-10s %-14s %-8s %-s\n" \
                "$base" "-" "-" "-" "?" "не удалось определить номер слота"
            continue
        fi

        # Вычисление SCSI target по режиму корзины
        case "$mode" in
            big)   target=$((slot - 1)) ;;
            small) target=$((slot + 24)) ;;
            *)
                printf "%-14s %-8s %-10s %-14s %-8s %-s\n" \
                    "$base" "-" "-" "-" "?" "неизвестный режим расчёта"
                continue
                ;;
        esac

        scsi_addr="0:0:${target}:0"
        disk="$(find_disk_by_scsi "$scsi_addr" 2>/dev/null || true)"

        if [ -n "$disk" ]; then
            status="занят"
            desc="$(get_disk_desc "$disk" || true)"
            [ -n "$desc" ] || desc="описание недоступно"
        else
            disk="-"
            status="пусто"
            desc="-"
        fi

        printf "%-14s %-8s %-10s %-14s %-8s %-s\n" \
            "$base" "$disk" "$target" "$scsi_addr" "$status" "$desc"

    done | sort -V
}


# ------------------------------------------------------------
# Основной вывод
# ------------------------------------------------------------
echo "Карта дисков по слотам"
echo "Узел: $(hostname 2>/dev/null || echo 'неизвестно')"
echo "Дата: $(date '+%Y-%m-%d %H:%M:%S')"

process_enclosure "0:0:24:0" "IN-WIN RS-424-07 (24 слота)" "big"
process_enclosure "0:0:35:0" "IN-WIN RS-212-07 (12 слотов)" "small"

echo
echo "Готово."
