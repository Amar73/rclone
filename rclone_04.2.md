Привет!

Есть скрипт резервного копирования, написанный на Bash и предназначенный для автоматизированного резервного копирования данных из Ceph FS на локальную  файловую систему с использованием утилиты rclone. Скрипт выполняет синхронизацию данных, очистку устаревших резервных
копий, проверку состояния Ceph-кластера и валидацию бэкапов. Он включает механизмы обработки ошибок, повторных попыток
и логирования. Ниже приведено подробное описание его работы, разбитое на пункты.
1. Назначение скрипта

Основная цель: Создание резервных копий данных из директории /ceph/data/exp/idream/ на Ceph FS в локальную директорию /
backup/main/ceph/data/exp/idream/.
Функциональность:
    Синхронизация данных с помощью rclone sync.
    Очистка устаревших данных (старше 30 дней) из директории /backup/deleted.
    Проверка состояния Ceph-кластера и доступности исходных данных.
    Частичная валидация бэкапов путём сравнения количества файлов в исходной и целевой директориях.
    Логирование всех операций и ошибок в файлы в /var/log/backup.
    Параллельная обработка нескольких директорий (хотя в текущей конфигурации используется только одна).
    
    
    
2. Конфигурация скрипта
Скрипт использует следующие конфигурационные параметры, определённые в начале:
        
    BACKUP_USER: Имя пользователя для проверки прав доступа (backup_user).
    LOGDIR: Директория для логов (/var/log/backup).
    LOCKFILE: Файл блокировки для предотвращения одновременного запуска (/var/lock/backup.lock).
    EXCLUDE_FILE: Путь к файлу исключений для rclone (/usr/local/bin/scripts/exclude-file.txt), содержащему фильтры, такие
    как data/** и data3/**.
    DELETE_BACKUP: Директория для перемещённых (удалённых) файлов (/backup/deleted).
    MAIN_BACKUP: Целевая директория для бэкапов (/backup/main).
    SOURCEDIRS: Массив исходных директорий для бэкапа (в текущей версии только /ceph/data/exp/idream/).
    RCLONE_TRANSFERS, RCLONE_CHECKERS, RCLONE_RETRIES: Параметры rclone для параллельных передач (30), проверок (8) и повто
    рных попыток (5).
        
3. Инициализация и логирование
        
Создание лога:
    Для каждого запуска создаётся файл лога с временной меткой, например, /var/log/backup/backup_2025-05-23_12-36.log.
    Директория логов (/var/log/backup) создаётся, если не существует.
            
            
Ротация логов:
    Удаляются логи старше 30 дней.
    Если в директории больше 100 логов, скрипт завершается с ошибкой.
                
                
Функция логирования:
    Функция log записывает сообщения в лог с меткой времени и уровнем (INFO, WARNING, ERROR, DEBUG).
    Сообщения также выводятся в консоль через tee -a.
4. Проверка конфигурации rclone
            
RCLONE_CONFIG:
    Проверяется наличие конфигурационного файла rclone с помощью rclone config file.
    Если файл не найден, скрипт продолжает работу без параметра --config, что подходит для локальных операций.
    Если файл найден, его путь логируется и экспортируется в переменную окружения.
                
                
Параметры rclone:
    Экспортируются переменные RCLONE_TRANSFERS, RCLONE_CHECKERS, RCLONE_RETRIES для использования в командах rclone.
                    
                    
                    
5. Проверка файла исключений
                    
EXCLUDE_FILE:
    Проверяется существование файла /usr/local/bin/scripts/exclude-file.txt.
    Проверяется его читаемость и ненулевой размер.
    Содержимое файла логируется для отладки (например, data/**, data3/**).
    Если файл отсутствует, недоступен для чтения или пустой, скрипт завершается с ошибкой или выдаёт предупреждение.

Дополнительная проверка:
    В функции backup_dir повторно проверяется доступность и содержимое файла исключений, чтобы учесть возможные проблемы в
    дочерних процессах.
    
    
    
6. Механизм блокировки
    
LOCKFILE:
    Используется flock для создания файла блокировки /var/lock/backup.lock.
    Если скрипт уже запущен, он завершается с ошибкой, чтобы избежать параллельного выполнения.
        
        
Очистка:
    Файл блокировки удаляется при завершении скрипта (нормальном или по сигналу INT/TERM) с помощью trap.
            
            
            
7. Проверка Ceph FS
            
Функция check_ceph_access:
    Проверяет наличие /ceph в /etc/fstab.
    Убеждается, что /ceph смонтирован (используется mountpoint -q).
    Если /ceph не смонтирован, предпринимается до 5 попыток монтирования с интервалом 30 секунд.
    Проверяет доступность /ceph и исходных директорий (/ceph/data/exp/idream/) с помощью ls.
    Проверяет состояние Ceph-кластера через SSH на cephsvc05 с командой podman exec ceph-mon-cephsvc05 ceph status. Если SS
    H недоступен, проверка пропускается с предупреждением.

Обработка ошибок:
    Если какая-либо проверка не пройдена, функция возвращает ненулевой код возврата, и скрипт завершается.
    
    
    
8. Очистка устаревших данных
    
Функция cleanup_old_backups:
   Очищает данные старше 30 дней из директории /backup/deleted с помощью команды rclone purge --min-age 30d.
   Проверяет доступность директории /backup/deleted.
   Использует механизм повторных попыток (3 попытки с задержкой 10 секунд) через функцию retry_command.
        
        
Логирование:
   Успешное выполнение или ошибки логируются.
   Если очистка завершилась с ошибкой, скрипт продолжает работу с предупреждением.
            
            
            
9. Резервное копирование директорий

Функция backup_dir:
    Принимает путь к исходной директории (например, /ceph/data/exp/idream/).
    Создаёт целевую директорию в /backup/main/ceph/..., сохраняя структуру Ceph FS.
    Проверяет доступность исходной директории с помощью ls.
    Повторно проверяет доступность и содержимое файла исключений.
    
    
Команда rclone sync:
    Формируется с использованием массива RCLONE_FLAGS, содержащего параметры:
        --progress: Отображение прогресса.
        --links: Сохранение символических ссылок.
        --fast-list: Оптимизация списков файлов.
        --create-empty-src-dirs: Создание пустых директорий.
        --checksum: Проверка по контрольным суммам.
        --transfers=30, --checkers=8, --retries=5, --retries-sleep=10s
    Параметры параллельности и повторных попыток.
        --update: Копирование только новых или изменённых файлов.
        --backup-dir=/backup/deleted/YYYY-MM-DD: Перемещение удалённых файлов в директорию с текущей датой.
        --log-file, --log-level=INFO: Логирование в файл.
        --exclude-from=/usr/local/bin/scripts/exclude-file.txt: Исключение файлов/директорий, указанных в файле.
        --config (если RCLONE_CONFIG не пустая).
            
            
Команда выполняется с тремя попытками через retry_command с задержкой 15 секунд.

Валидация:
    После синхронизации вызывается функция validate_backup, которая сравнивает количество файлов в исходной и целевой дирек
    ториях с помощью rclone lsf --files-only.
    Если количество совпадает, валидация считается успешной; иначе фиксируется ошибка.
    
    
    
10. Параллельная обработка
    
Функция perform_backup:
    Создаёт директории /backup/main и /backup/deleted.
    Вызывает check_ceph_access для проверки Ceph FS.
    Вызывает cleanup_old_backups для очистки устаревших данных.
    Запускает backup_dir для каждой директории из массива SOURCEDIRS параллельно (до 4 процессов) с помощью xargs -P4.
        
        
Экспорт:
        Все функции и ключевые переменные (включая EXCLUDE_FILE) экспортируются для использования в дочерних процессах bash, вы
        зываемых через xargs.
        
11. Основной поток выполнения
        
Инициализация:
    Логируются начальные данные: пользователь, права на /ceph и /backup, версия rclone, конфигурация и параметры.
            
            
Выполнение:
    Вызывается perform_backup.
    Если функция возвращает нулевой код возврата, логируется успешное завершение.
    Если возвращён ненулевой код, логируется ошибка, и скрипт завершается с кодом 1.
                
                
                
12. Обработка ошибок

Повторные попытки:
    Функция retry_command обеспечивает до трёх попыток выполнения команд rclone с задержкой (10 секунд для purge, 15 секунд для sync).                                      
                    
                    
Проверки:
    Проверяются права доступа, существование файлов и директорий, состояние Ceph-кластера.
    Ошибки логируются с уровнем ERROR, и скрипт завершается, если они критичны.

Предупреждения:
    Некритичные проблемы (например, недоступность SSH или проблемы с очисткой) логируются как WARNING, и скрипт продолжает
    работу.
    
    
    
13. Логирование и отладка
    
Лог-файл:
    Все операции, включая команды rclone, их попытки и результаты, записываются в лог.
    Уровни лога: INFO (основные события), WARNING (некритичные проблемы), ERROR (критичные ошибки), DEBUG (детали команд).
        
        
Отладочная информация:
    Логируется содержимое файла исключений.
    Выводятся полные команды rclone перед выполнением.
    Проверки прав доступа и состояния системы подробно документируются.
            
            
            
14. Зависимости
            
Утилиты:
    rclone (версия 1.62.2 или выше) для синхронизации и очистки.
    bash, flock, find, xargs, tee, mountpoint, ls, cat, awk для работы скрипта.
    ssh (опционально) для проверки состояния Ceph.

Система:
    Доступ к Ceph FS через точку монтирования /ceph.
    Права на чтение /ceph и запись в /backup.
    Беспарольный SSH-доступ к cephsvc05 для проверки Ceph (если используется).
    
    
    
15. Ограничения и особенности
    
Локальные операции: Скрипт работает с локальными путями (/ceph и /backup), так        как RCLONE_CONFIG пустая. Для удалённых
хранилищ требуется настройка rclone.
Параллелизм: Ограничен 4 процессами (xargs -P4), что подходит для одной директории, но может быть увеличено при необход
имости.
Файл исключений: Требует корректных фильтров rclone и доступности для чтения.
Валидация: Проверяет только количество файлов, а не их содержимое.
SSH: Проверка Ceph через SSH не критична и пропускается при отсутствии доступа.
    
16. Пример работы
    
Скрипт запускается как root.
Создаётся лог /var/log/backup/backup_2025-05-23_12-36.log.
Проверяется блокировка, Ceph FS, файл исключений.
Удаляются данные старше 30 дней из /backup/deleted.
Выполняется rclone sync для /ceph/data/exp/idream/ в /backup/main/ceph/data/exp/idream/, исключая data/** и data3/**.
Проверяется количество файлов в исходной и целевой директориях.
Логируются результаты, и скрипт завершается с соответствующим статусом.

17. Рекомендации по использованию

Проверка прав: Убедитесь, что root имеет доступ к /ceph, /backup и /usr/local/bin/scripts/exclude-file.txt.
Файл исключений: Регулярно проверяйте содержимое /usr/local/bin/scripts/exclude-file.txt на актуальность.
Логи: Анализируйте логи в /var/log/backup для диагностики проблем.
Тестирование: Перед использованием в продакшене протестируйте на небольшом наборе данных.
SSH: Настройте беспарольный SSH-доступ к cephsvc05 для проверки Ceph.
Обновление rclone: Рассмотрите обновление до последней версии для улучшения производительности.

```bash
#!/usr/bin/env bash

# Конфигурация
BACKUP_USER="backup_user"
LOGDIR="/var/log/backup"
LOCKFILE="/var/lock/backup.lock"
EXCLUDE_FILE="/usr/local/bin/scripts/exclude-file.txt"
DELETE_BACKUP="/backup/deleted"
MAIN_BACKUP="/backup/main"
SOURCEDIRS=("/ceph/data/exp/idream/")
RCLONE_TRANSFERS=${RCLONE_TRANSFERS:-30}
RCLONE_CHECKERS=${RCLONE_CHECKERS:-8}
RCLONE_RETRIES=${RCLONE_RETRIES:-5}

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

# Конфигурация rclone
RCLONE_CONFIG=$(rclone config file | awk -F': ' '{print $2}' | xargs)
if [[ -z "$RCLONE_CONFIG" ]]; then
log WARNING "Конфигурационный файл rclone не найден, продолжаем без --config"
unset RCLONE_CONFIG
else
log INFO "Используется конфигурационный файл rclone: $RCLONE_CONFIG"
export RCLONE_CONFIG
fi
export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES

# Проверка файла исключений
log INFO "Проверка файла исключений: $EXCLUDE_FILE"
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
log INFO "Содержимое exclude-файла: $(cat "$EXCLUDE_FILE" 2>/dev/null || echo 'Не удалось прочитать')"

# Блокировка с использованием flock
exec 200>"$LOCKFILE"
if ! flock -n 200; then
log ERROR "Скрипт уже запущен. Выход."
exit 1
fi
trap 'flock -u 200; rm -f "$LOCKFILE"; exit $?' INT TERM EXIT

# Функция логирования
log() {
    local level=${1:-ERROR}
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

# Проверка Ceph
check_ceph_access() {
    if ! grep -q '/ceph' /etc/fstab; then
    log ERROR "/ceph не настроен в fstab"
    return 1
fi

    if ! mountpoint -q /ceph; then
    log WARNING "/ceph не смонтирован. Начинаем попытки монтирования..."
    for attempt in {1..5}; do
    log INFO "Попытка монтирования $attempt/5..."
    umount -fl /ceph 2>/dev/null
    if mount /ceph; then
    log INFO "Успешно смонтировано /ceph"
    break
else
log ERROR "Неудачная попытка монтирования. Повтор через 30 сек..."
sleep 30
fi
done
if ! mountpoint -q /ceph; then
log ERROR "Не удалось смонтировать Ceph после 5 попыток"
return 1
fi
fi

    if ! ls /ceph &>/dev/null; then
    log ERROR "Нет прав доступа к /ceph. Проверить права пользователя $BACKUP_USER"
    return 1
fi

    for dir in "${SOURCEDIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
    log ERROR "Директория $dir недоступна"
    return 1
fi
done

    # Проверка состояния Ceph через SSH и podman
    if command -v ssh >/dev/null; then
    if ! ssh cephsvc05 "podman exec ceph-mon-cephsvc05 ceph status" >/dev/null; then
    log WARNING "Проблемы с состоянием Ceph-кластера"
    else
    log INFO "Ceph-кластер в порядке"
    fi
    else
    log WARNING "Команда ssh недоступна, пропускаем проверку состояния Ceph"
    fi
    
    return 0
}

# Частичная валидация
validate_backup() {
    local src=$1
    local dst=$2
    log INFO "Начата частичная валидация: $src -> $dst"
    
    local src_count=$(rclone lsf "$src" --files-only | wc -l)
    local dst_count=$(rclone lsf "$dst" --files-only | wc -l)
    
    if [[ "$src_count" -eq "$dst_count" ]]; then
    log INFO "Валидация успешна: количество файлов совпадает ($src_count)"
    return 0
else
log ERROR "Валидация не пройдена: $src_count файлов в источнике, $dst_count в бэкапе"
return 1
fi
}

# Очистка устаревших данных
cleanup_old_backups() {
    log INFO "Начата очистка устаревших данных из $DELETE_BACKUP"
    
    if [[ ! -d "$DELETE_BACKUP" ]]; then
    log ERROR "Директория $DELETE_BACKUP недоступна"
    return 1
fi

    local purge_cmd="rclone purge --min-age 30d '$DELETE_BACKUP' --log-level=INFO --log-file='$LOGFILE'"
    [[ -n "$RCLONE_CONFIG" ]] && purge_cmd="$purge_cmd --config='$RCLONE_CONFIG'"
    if ! retry_command "$purge_cmd"; then
    log ERROR "Ошибка при очистке устаревших данных"
    return 1
fi

    log INFO "Очистка завершена успешно"
    }

# Обработка директории
backup_dir() {
    local dir=$1
    log INFO "Начат бэкап: $dir"
    log INFO "Повторная проверка exclude-файла в backup_dir: $EXCLUDE_FILE"
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
    log ERROR "Файл исключений $EXCLUDE_FILE не найден в backup_dir"
    return 1
fi
if [[ ! -r "$EXCLUDE_FILE" ]]; then
log ERROR "Файл исключений $EXCLUDE_FILE не доступен для чтения в backup_dir"
return 1
fi
log INFO "Содержимое exclude-файла в backup_dir: $(cat "$EXCLUDE_FILE" 2>/dev/null || echo 'Не удалось прочитать')"

    local dest_dir="${MAIN_BACKUP}/ceph${dir#/ceph}"
    mkdir -p "$(dirname "$dest_dir")" || {
        log ERROR "Не удалось создать $dest_dir"
        return 1
    }
    
    if ! ls "$dir" &>/dev/null; then
    log ERROR "Нет доступа к исходной директории: $dir"
    return 1
fi

    local RCLONE_FLAGS=(
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
        "--backup-dir=$DELETE_BACKUP/$(date +%F)"
        "--log-file=$LOGFILE"
        --log-level=INFO
        "--exclude-from=$EXCLUDE_FILE"
        )
    
    [[ -n "$RCLONE_CONFIG" ]] && RCLONE_FLAGS+=(--config="$RCLONE_CONFIG")
    
    local cmd=(rclone sync "${RCLONE_FLAGS[@]}" "$dir" "$dest_dir")
    log DEBUG "Выполняемая команда: ${cmd[*]}"
    
    if ! retry_command "${cmd[*]}" 3 15; then
    log ERROR "Бэкап $dir завершился ошибкой"
    return 1
fi

    validate_backup "$dir" "$dest_dir" || return 1
log INFO "Бэкап $dir успешно завершен"
}
    
    # Экспорт функций и переменных
    export -f log retry_command check_ceph_access validate_backup cleanup_old_backups backup_dir
    export RCLONE_CONFIG RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_RETRIES LOGFILE MAIN_BACKUP DELETE_BACKUP EXCLUDE_FILE
    
    # Основная функция
    perform_backup() {
        mkdir -p "$MAIN_BACKUP" "$DELETE_BACKUP" || {
            log ERROR "Ошибка создания директорий"
            return 1
        }
        
        if ! check_ceph_access; then
        return 1
    fi
    
    cleanup_old_backups || log WARNING "Проблемы с очисткой, но продолжаем..."
    
    printf "%s\0" "${SOURCEDIRS[@]}" | xargs -0 -n1 -P4 -I{} bash -c '
    backup_dir "$1" || exit 1
    ' _ {} || return 1

    return 0
}
        
        # Основной поток
        log INFO "***** Начат процесс резервного копирования *****"
        log INFO "Запуск от пользователя: $(whoami)"
        log INFO "Права на /ceph: $(ls -ld /ceph)"
        log INFO "Права на /backup: $(ls -ld /backup)"
        log INFO "Версия rclone: $(rclone --version | head -n1)"
        log INFO "Конфиг rclone: $RCLONE_CONFIG"
        log INFO "Параметры: transfers=$RCLONE_TRANSFERS checkers=$RCLONE_CHECKERS retries=$RCLONE_RETRIES"
        
        if perform_backup; then
        log INFO "Все бэкапы успешно завершены"
        else
        log ERROR "Бэкап завершился с ошибками"
        exit 1
        fi
```

Ты супер эксперт по CEPH,  администрированию Linux и написанию скриптов на BASH. Нужно проверить, представленный выше скрипт и дать рекомендации по его работе. Есть несколько проблем:
    Отсутствует директория /backup/deleted
    Видимо продолжается бэкап директорий- /ceph/data/exp/idream/data и /ceph/data/exp/idream/data3
    Нужны рекомендации по возможному усовершенствованию скрипта.




Переделай мой файл с bash скриптом бэкапа, включив туда твои рекомендации.
Раздел- G) Валидация — рекурсивно и с теми же фильтрами тоже включи в него, но закоментируй. Хочу прогнать скрипт без валидации.
Давай попробуем вариант JSON-логов с итоговой сводкой (jq/awk для человекочитаемой «шапки»).
Везде нужны подробные коментарии на русском языке.
Жду от тебя полностью рабочий скрипт. Подумай и проверь получившийся результат несколько раз, прежде чем его выложить мне.


```bash
2025-08-26 12:00:26 [WARNING] Конфигурационный файл rclone не найден/недоступен, продолжаем без --config
2025-08-26 12:00:26 [INFO] Проверка exclude-файла: /usr/local/bin/scripts/exclude-file.txt
2025-08-26 12:00:26 [INFO] ***** Старт бэкапа *****
2025-08-26 12:00:26 [INFO] Пользователь: root
2025-08-26 12:00:26 [INFO] Права на /ceph: drwxr-xr-x 1 root root 3 May  5 13:12 /ceph
2025-08-26 12:00:26 [INFO] Права на /backup: drwxr-xr-x 5 root root 4096 Aug 26 11:52 /backup
2025-08-26 12:00:26 [INFO] Версия rclone: rclone v1.62.2
2025-08-26 12:00:26 [INFO] Параметры: transfers=30 checkers=8 retries=5 dry_run=false
2025-08-26 12:00:27 [INFO] Ceph-кластер: OK (status получен)
2025-08-26 12:00:27 [INFO] Очистка устаревших данных в /backup/deleted (старше 30d)
2025-08-26 12:00:27 [INFO] Попытка 1/3: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:00:28 [WARNING] Ошибка: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted (попытка 1/3). Повтор через 10s
2025-08-26 12:00:38 [INFO] Попытка 2/3: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:00:38 [WARNING] Ошибка: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted (попытка 2/3). Повтор через 10s
2025-08-26 12:00:48 [INFO] Попытка 3/3: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:00:48 [WARNING] Ошибка: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted (попытка 3/3). Повтор через 10s
2025-08-26 12:00:58 [ERROR] Команда не выполнилась после 3 попыток: rclone
delete
--min-age
30d
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:00:58 [WARNING] rclone delete завершился с ошибкой (продолжаем)
2025-08-26 12:00:58 [INFO] Попытка 1/3: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:00:58 [WARNING] Ошибка: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted (попытка 1/3). Повтор через 10s
2025-08-26 12:01:08 [INFO] Попытка 2/3: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:01:08 [WARNING] Ошибка: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted (попытка 2/3). Повтор через 10s
2025-08-26 12:01:18 [INFO] Попытка 3/3: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:01:18 [WARNING] Ошибка: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted (попытка 3/3). Повтор через 10s
2025-08-26 12:01:28 [ERROR] Команда не выполнилась после 3 попыток: rclone
rmdirs
--leave-root
--use-json-log
--log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl

/backup/deleted
2025-08-26 12:01:28 [WARNING] rclone rmdirs завершился с ошибкой (продолжаем)
2025-08-26 12:01:28 [INFO] Очистка /backup/deleted завершена
2025-08-26 12:01:28 [INFO] Начат бэкап: /ceph/data/exp/idream/ -> /backup/main/ceph/data/exp/idream/
2025-08-26 12:01:28 [INFO] Команда: rclone sync --progress --links --fast-list --create-empty-src-dirs --checksum --transfers=30 --checkers=8 --retries=5 --retries-sleep=10s --update --delete-excluded --backup-dir=/backup/deleted/2025-08-26 --use-json-log --log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl --exclude-from=/usr/local/bin/scripts/exclude-file.txt /ceph/data/exp/idream/ /backup/main/ceph/data/exp/idream/
2025-08-26 12:01:28 [INFO] Попытка 1/3: rclone sync --progress --links --fast-list --create-empty-src-dirs --checksum --transfers=30 --checkers=8 --retries=5 --retries-sleep=10s --update --delete-excluded --backup-dir=/backup/deleted/2025-08-26 --use-json-log --log-file=/var/log/backup/backup_2025-08-26_12-00.jsonl --exclude-from=/usr/local/bin/scripts/exclude-file.txt /ceph/data/exp/idream/ /backup/main/ceph/data/exp/idream/
```

Отлично поймал. Тут два момента:

Я задал IFS=$'\n\t', а потом в retry_command прокатывал команду строкой через "${arr[*]}" + eval. Из-за такого IFS в лог полетели переносы строк, а eval — лишний риск.

Для локальной цели rclone delete/rmdirs лучше явно указывать local: (бывает капризничает на старых релизах).

Ниже — точечный патч: безопасный раннер массивов без eval, явный local: и поправленные вызовы. Вставь как есть (замена функций и вызовов), остального коду касаться не нужно.

1) Заменить retry_command на вариант с массивами

# Универсальный ретрайер: первый аргумент = кол-во попыток, второй = задержка, далее — сама команда массивом
```bash
retry_command() {
  local retries="$1"; shift
  local delay="$1";   shift
  local -a cmd=( "$@" )

  for ((attempt=1; attempt<=retries; attempt++)); do
    log INFO "Попытка ${attempt}/${retries}: ${cmd[*]}"
    # Пишем stdout/stderr команды в текстовый лог скрипта; JSON-лог rclone остаётся в своем файле
    if "${cmd[@]}" >>"$LOGFILE" 2>&1; then
      return 0
    fi
    local rc=$?
    log WARNING "Ошибка (rc=${rc}): ${cmd[*]}. Повтор через ${delay}s"
    sleep "$delay"
  done

  log ERROR "Команда не выполнилась после ${retries} попыток: ${cmd[*]}"
  return 1
}
```

2) В cleanup_old_backups() — явный local: и вызовы через массив
```bash
cleanup_old_backups() {
  log INFO "Очистка устаревших данных в $DELETE_BACKUP (старше 30d)"
  [[ -d "$DELETE_BACKUP" ]] || { log ERROR "Каталог $DELETE_BACKUP отсутствует"; return 1; }

  local cfg=()
  [[ -n "${RCLONE_CONFIG:-}" ]] && cfg+=(--config="$RCLONE_CONFIG")

  # delete старше 30д
  local del_cmd=( rclone delete --min-age 30d --use-json-log --log-file="$RCLONE_JSONLOG" "${cfg[@]:-}" "local:$DELETE_BACKUP" )
  retry_command 3 10 "${del_cmd[@]}" || log WARNING "rclone delete завершился с ошибкой (продолжаем)"

  # rmdirs пустых папок (корень сохраняем)
  local rd_cmd=( rclone rmdirs --leave-root --use-json-log --log-file="$RCLONE_JSONLOG" "${cfg[@]:-}" "local:$DELETE_BACKUP" )
  retry_command 3 10 "${rd_cmd[@]}" || log WARNING "rclone rmdirs завершился с ошибкой (продолжаем)"

  log INFO "Очистка /backup/deleted завершена"
}
```

3) В backup_dir() — запуск rclone sync через массив и новый retry_command

Найди блок:
```bash
local cmd=(rclone sync "${flags[@]}" "$src_dir" "$dest_dir")
log INFO "Команда: ${cmd[*]}"
if ! retry_command "${cmd[*]}" 3 15; then
```

и замени на:
```bash
local cmd=( rclone sync "${flags[@]}" "$src_dir" "$dest_dir" )
log INFO "Команда: ${cmd[*]}"
if ! retry_command 3 15 "${cmd[@]}"; then
```

(остальной код функции — без изменений).

4) Бонус: как быстро посмотреть, что именно не понравилось rclone

Теперь (после правки раннера) ошибки rclone попадут в текстовый лог ($LOGFILE).
Плюс можно глянуть последние ошибки из JSON-лога:

# если есть jq
```bash
jq -r 'select(.level=="ERROR" or .level=="FATAL") | .msg' "$RCLONE_JSONLOG" | tail -n 20
```

Почему это решит проблему

Убрали eval и строковую сборку: команда выполняется как массив — никакой пляски с IFS, кавычками и переносами.

Локальные операции delete/rmdirs теперь адресуются явно как local:/path — поведение стабильнее на rclone v1.62.x.

Логи стали информативнее: и stdout/stderr в текстовом логе, и структурный JSON остаётся отдельно.

Гони тот же запуск — очистка теперь должна проходить корректно. Если rclone всё равно вернёт неноль (например, из-за прав/attr/immutable), в $LOGFILE будет прямой текст ошибки, и её добьём точечно.

