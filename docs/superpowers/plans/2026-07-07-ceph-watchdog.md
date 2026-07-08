# Ceph-watchdog во время резервного копирования — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в `rclone_backup_unified_v4.0.0.sh` фоновый сторож, который во время ЭТАП 4 (параллельное копирование) непрерывно следит за реальной доступностью `/ceph`, и при устойчивом сбое — останавливает текущие `rclone`-процессы и перемонтирует `/ceph` до того, как rclone успеет удалить файлы на основе усечённого списка (см. инцидент `sw` от 2026-07-07).

**Architecture:** Новая функция `ceph_watchdog()` запускается в фоне (`&`) в текущем bash-процессе (не через `xargs`/новый процесс — значит функции/переменные наследуются автоматически, `export -f` не требуется) непосредственно перед стартом ЭТАП 4 и останавливается сразу после его завершения либо при любом прерывании скрипта через уже существующий `trap cleanup EXIT`. Убитый watchdog'ом `rclone`-процесс получает ненулевой код возврата, который уже существующий `retry_command` (используется в `backup_directory`) трактует как повод честно перезапустить `sync` — никакой новой retry-логики не требуется.

**Tech Stack:** bash (тот же файл, тот же стиль — `log`, `retry_command`, `readonly`-константы как в остальном скрипте).

## Global Constraints

- Файл единый на всех трёх хостах (arch03/04/05) — правим один файл, деплоим на все три после проверки на arch03.
- Интервал проверки: **20 секунд**. Порог срабатывания: **2 проверки подряд** (~40с устойчивой недоступности) — чтобы не реагировать на разовые блипы `caps stale`, которые в течение дня многократно проходили сами.
- Проверка доступности: `timeout 5 stat /ceph` — тот же метод, что уже используется в `backup_status.sh` (мониторинг-дашборд) для обнаружения именно случая «mount формально есть, но обращение зависает/даёт Permission denied».
- Убивать процессы **точно по имени** — `pkill -x rclone`, НЕ `pkill -f` (в этой сессии был найден баг, когда `pkill -f` матчился на собственный вызывающий процесс и убивал сам себя — см. память `ssh_topology_arch_backup.md`).
- Перемонтирование: `umount /ceph -fl`, затем до 5 попыток `mount /ceph` с 5с паузой — это ровно та команда, что вручную успешно применялась в этой сессии несколько раз сегодня для восстановления `/ceph` на arch03.
- НЕ трогать `check_ceph_access()` (разовая проверка на ЭТАП 1) — она уже работает и не связана с этой задачей; изменения должны быть отдельной, новой функциональностью, не рефакторингом существующей.
- НЕ менять `retry_command`/`backup_directory` — они уже корректно обрабатывают ненулевой код возврата убитого процесса.
- Деплой на живые продакшн-хосты требует явного подтверждения пользователя перед первым запуском живого теста восстановления (Task 2) — хотя используемая команда перемонтирования уже проверена сегодня вручную, это всё равно изменение поведения продакшн-скрипта.

---

### Task 1: `ceph_watchdog()` — реализация в `rclone_backup_unified_v4.0.0.sh`

**Files:**
- Modify: `/home/amar/Amar73/rclone/rclone_backup_unified_v4.0.0.sh`
  - После строки 177 (`REPORT_GENERATION_FAILED=false`) — добавить глобальную переменную.
  - После строки 739 (конец `check_ceph_access()`, перед следующим разделом) — добавить новый раздел с тремя функциями.
  - В `cleanup()` (строки 385-421) — добавить остановку сторожа.
  - В `main()`, перед ЭТАП 4 (около строки 1452) — запуск сторожа.
  - В `main()`, сразу после завершения `xargs`-конвейера (около строки 1465-1470) — остановка сторожа.

**Interfaces:**
- Produces: функции `ceph_watchdog_check()` (возвращает 0/1, доступен ли `/ceph`), `ceph_watchdog_recover()` (убивает rclone, перемонтирует, возвращает 0/1), `ceph_watchdog()` (бесконечный цикл, запускается в фоне). Глобальная переменная `WATCHDOG_PID`.
- Consumes: существующие `log()`, `LOGFILE` (уже определены выше в файле).

- [ ] **Step 1: Добавить глобальную переменную**

Найти в файле:
```bash
BACKUP_SUCCESS=true
REPORT_GENERATION_FAILED=false
```

Заменить на:
```bash
BACKUP_SUCCESS=true
REPORT_GENERATION_FAILED=false
WATCHDOG_PID=""
```

- [ ] **Step 2: Добавить новый раздел с функциями сторожа**

Найти конец функции `check_ceph_access()` — она заканчивается закрывающей `}` перед следующим разделом файла (после строки, содержащей `log ERROR "Проверьте, что директории существуют и доступны."` и последующих строк проверки `missing_dirs`). Сразу после закрывающей `}` этой функции добавить:

```bash

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

# Возвращает 0, если /ceph реально доступен (не просто "смонтирован" —
# именно это различие важно: mountpoint -q может быть true, пока реальный
# stat/ls виснет или даёт Permission denied).
ceph_watchdog_check() {
    timeout "$CEPH_WATCHDOG_STAT_TIMEOUT" stat /ceph >/dev/null 2>&1
}

# Останавливает текущие rclone-процессы и перемонтирует /ceph.
# Возвращает 0, если после перемонтирования /ceph снова доступен.
ceph_watchdog_recover() {
    log ERROR "ceph_watchdog: /ceph недоступен $CEPH_WATCHDOG_FAILURE_THRESHOLD" \
              "проверки подряд (~$(( CEPH_WATCHDOG_CHECK_INTERVAL * CEPH_WATCHDOG_FAILURE_THRESHOLD ))с)." \
              "Останавливаю текущие rclone-процессы и перемонтирую /ceph."

    pkill -TERM -x rclone 2>/dev/null || true
    sleep "$CEPH_WATCHDOG_KILL_GRACE"
    pkill -KILL -x rclone 2>/dev/null || true

    umount /ceph -fl 2>/dev/null || true

    local attempt
    for (( attempt = 1; attempt <= CEPH_WATCHDOG_REMOUNT_ATTEMPTS; attempt++ )); do
        log INFO "ceph_watchdog: попытка перемонтирования $attempt/$CEPH_WATCHDOG_REMOUNT_ATTEMPTS"

        if mount /ceph 2>>"$LOGFILE" && ceph_watchdog_check; then
            log INFO "ceph_watchdog: /ceph успешно перемонтирован и доступен"
            return 0
        fi

        if (( attempt < CEPH_WATCHDOG_REMOUNT_ATTEMPTS )); then
            sleep "$CEPH_WATCHDOG_REMOUNT_SLEEP"
        fi
    done

    log ERROR "ceph_watchdog: не удалось перемонтировать /ceph после" \
              "$CEPH_WATCHDOG_REMOUNT_ATTEMPTS попыток. Продолжаю наблюдение."
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
```

- [ ] **Step 3: Остановка сторожа в `cleanup()`**

Найти начало функции `cleanup()`:
```bash
cleanup() {
    local exit_code=$?

    log INFO "Начало процедуры очистки ресурсов..."

    if [[ -n "$LOCK_FD" ]]; then
```

Вставить остановку сторожа СРАЗУ после строки `log INFO "Начало процедуры очистки ресурсов..."` и перед проверкой `LOCK_FD`:

```bash
cleanup() {
    local exit_code=$?

    log INFO "Начало процедуры очистки ресурсов..."

    if [[ -n "${WATCHDOG_PID:-}" ]]; then
        log DEBUG "Останавливаю ceph_watchdog (PID: $WATCHDOG_PID)"
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi

    if [[ -n "$LOCK_FD" ]]; then
```

- [ ] **Step 4: Запуск сторожа перед ЭТАП 4**

Найти в `main()`:
```bash
    log INFO "ЭТАП 3 завершён"

    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
```

Вставить запуск сторожа между этими двумя строками:
```bash
    log INFO "ЭТАП 3 завершён"

    ceph_watchdog &
    WATCHDOG_PID=$!
    log DEBUG "ceph_watchdog запущен в фоне (PID: $WATCHDOG_PID)"

    log INFO "ЭТАП 4: Запуск параллельного резервного копирования"
```

- [ ] **Step 5: Остановка сторожа сразу после ЭТАП 4**

Найти в `main()`:
```bash
    local xargs_exit_code=$?
    set -e

    backup_end=$(date +%s)
```

Вставить остановку сторожа между `set -e` и `backup_end=$(date +%s)`:
```bash
    local xargs_exit_code=$?
    set -e

    if [[ -n "$WATCHDOG_PID" ]]; then
        log DEBUG "Останавливаю ceph_watchdog (PID: $WATCHDOG_PID)"
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    fi

    backup_end=$(date +%s)
```

- [ ] **Step 6: Синтаксическая проверка**

```bash
bash -n rclone_backup_unified_v4.0.0.sh && echo "SYNTAX_OK"
```
Ожидается: `SYNTAX_OK`.

- [ ] **Step 7: Статическая проверка — переменные и вызовы**

Вручную пройти по файлу и подтвердить:
- `CEPH_WATCHDOG_*` константы объявлены один раз, до первого использования, и используются с одинаковыми именами везде (`ceph_watchdog_check`, `ceph_watchdog_recover`, `ceph_watchdog`).
- `WATCHDOG_PID` объявлена как глобальная (Step 1), используется одинаково в Step 3/4/5 (не переопределяется как `local` нигде).
- Внутри `ceph_watchdog`/`ceph_watchdog_recover` используются только уже существующие в файле функции/переменные (`log`, `LOGFILE`) — никаких вызовов необъявленных функций.
- `pkill` вызывается с `-x rclone`, НЕ с `-f` (проверить оба места: TERM и KILL).
- Порядок в `main()`: запуск сторожа (Step 4) находится ПОСЛЕ `ЭТАП 3 завершён` и ДО `ЭТАП 4: Запуск...`; остановка (Step 5) находится ПОСЛЕ `set -e` (после `xargs_exit_code=$?`) и ДО `backup_end=$(date +%s)`.

- [ ] **Step 8: Коммит**

```bash
cd /home/amar/Amar73/rclone
git add rclone_backup_unified_v4.0.0.sh
git commit -m "$(cat <<'EOF'
Add ceph_watchdog: detect and recover from mid-run Ceph MDS failures

Root-causes the 2026-07-07 sw quarantine incident: when /ceph dies
mid-scan (mds0 rejected session), rclone can silently act on a
truncated file listing and delete real backup data via
--delete-excluded. The watchdog runs in the background during the
parallel backup phase, and on two consecutive failed accessibility
checks (~40s), stops in-flight rclone processes before they can act on
bad data, remounts /ceph, and lets the existing retry_command mechanism
resume cleanly — no new retry logic needed.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Деплой на arch03 + живая проверка

**Files:**
- Deploy to: `arch03:/usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh`

**Interfaces:**
- Consumes: файл из Task 1.

**Важно:** это изменение поведения продакшн-скрипта резервного копирования. Показать пользователю план проверки из этой задачи и получить подтверждение перед Step 3 (деплой), даже несмотря на то что используемые команды уже проверялись вручную сегодня.

- [ ] **Step 1: Проверить текущий деплой на arch03**

Если ControlMaster для arch03 истёк — попросить пользователя выполнить `a03` интерактивно.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "ls -la /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh; systemctl is-active rclone-backup.service rclone-backup.timer"'
```

Ожидается: сервис/таймер `inactive`/`active` (таймер), сервис НЕ должен быть `active`/`activating` — не деплоить поверх работающего прогона.

- [ ] **Step 2: Показать пользователю план и получить подтверждение**

Явно перечислить: что будет задеплоено, что будет протестировано (Step 5-7 ниже — тест затронет реальный `/ceph` mount на arch03: unmount+remount, не более, та же команда что применялась вручную сегодня несколько раз), и дождаться подтверждения.

- [ ] **Step 3: Резервная копия текущего скрипта на arch03 и деплой нового**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "cp /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh.bak-$(date +%Y%m%d-%H%M%S)"'
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "cat > /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh"' < /home/amar/Amar73/rclone/rclone_backup_unified_v4.0.0.sh
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "chmod +x /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh && bash -n /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh && echo SYNTAX_OK"'
```
Ожидается: `SYNTAX_OK`.

- [ ] **Step 4: Извлечь функции сторожа в отдельный безопасный файл для тестов**

Все тесты ниже (Step 5-7) работают с тремя функциями сторожа в изоляции, НЕ через `source` всего `rclone_backup_unified_v4.0.0.sh` — сам файл при `source` выполнил бы верхнеуровневые проверки (например, обязательный `SOURCEDIRS`), и `exit 1` внутри них завершил бы весь тестовый shell, а не только загрузку функций. Извлечение через `sed` полностью исключает этот риск — выполняется только текст трёх функций, никакого другого кода файла.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "
sed -n \"/^ceph_watchdog_check()/,/^}/p; /^ceph_watchdog_recover()/,/^}/p; /^ceph_watchdog()/,/^}/p\" \
    /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh > /tmp/watchdog_functions.sh
grep -c \"^ceph_watchdog_check()\\|^ceph_watchdog_recover()\\|^ceph_watchdog()\" /tmp/watchdog_functions.sh
"'
```
Ожидается: `3` (все три функции найдены и извлечены).

- [ ] **Step 5: Тест 1 — счётчик срабатывания в изоляции (без касания реального /ceph)**

Проверить логику накопления подряд-идущих неудач и порог срабатывания без риска для продакшн-монтирования: временно подменить проверяемый путь на заведомо несуществующий, и застаброшить (echo вместо реального восстановления) `ceph_watchdog_recover`, чтобы убедиться что цикл считает правильно и вызывает recover ровно на 2-й неудаче, не раньше.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "
cat > /tmp/watchdog_isolated_test.sh <<'\''SCRIPT'\''
#!/bin/bash
source /tmp/watchdog_functions.sh

LOGFILE=/tmp/watchdog_test.log
log() { echo \"[\$1] \${*:2}\" | tee -a \"\$LOGFILE\"; }

ceph_watchdog_check() { timeout 2 stat /nonexistent_watchdog_test_path >/dev/null 2>&1; }
ceph_watchdog_recover() { echo RECOVER_CALLED >> \"\$LOGFILE\"; }

CEPH_WATCHDOG_CHECK_INTERVAL=1
CEPH_WATCHDOG_FAILURE_THRESHOLD=2

consecutive_failures=0
for i in 1 2 3 4; do
    sleep \"\$CEPH_WATCHDOG_CHECK_INTERVAL\"
    if ceph_watchdog_check; then
        consecutive_failures=0
    else
        consecutive_failures=\$(( consecutive_failures + 1 ))
        echo \"failure_count=\$consecutive_failures\" >> \"\$LOGFILE\"
        if (( consecutive_failures >= CEPH_WATCHDOG_FAILURE_THRESHOLD )); then
            ceph_watchdog_recover
            consecutive_failures=0
        fi
    fi
done
SCRIPT
rm -f /tmp/watchdog_test.log
bash /tmp/watchdog_isolated_test.sh
echo ---LOG---
cat /tmp/watchdog_test.log
rm -f /tmp/watchdog_isolated_test.sh /tmp/watchdog_test.log
"'
```

Ожидается в логе: `failure_count=1`, `failure_count=2`, `RECOVER_CALLED`, `failure_count=1`, `failure_count=2`, `RECOVER_CALLED` (за 4 итерации с несуществующим путём — срабатывание ровно на каждой 2-й неудаче, не на первой).

Примечание: этот тестовый скрипт переопределяет `ceph_watchdog_check`/`ceph_watchdog_recover` СВОИМИ версиями (после `source`) — это намеренно: тест проверяет только цикл накопления счётчика, реальные версии функций из `/tmp/watchdog_functions.sh` здесь не вызываются.

- [ ] **Step 6: Тест 2 — реальная функция восстановления против живого /ceph**

Эта команда реально выполнит `umount /ceph -fl && mount /ceph` на arch03 — та же операция, что уже выполнялась вручную сегодня несколько раз. Выполнять, только если `/ceph` сейчас в порядке (проверить перед запуском) и нет активного прогона бэкапа.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "timeout 3 stat /ceph && echo CEPH_HEALTHY_BEFORE"'
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "
source /tmp/watchdog_functions.sh
LOGFILE=/tmp/watchdog_recover_test.log
log() { echo \"[\$1] \${*:2}\" | tee -a \"\$LOGFILE\"; }
ceph_watchdog_recover
echo rc=\$?
cat \$LOGFILE
rm -f \$LOGFILE
"'
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "timeout 3 stat /ceph && echo CEPH_HEALTHY_AFTER; ls /ceph"'
```

Ожидается: `CEPH_HEALTHY_BEFORE`, лог показывает попытки монтирования и `/ceph успешно перемонтирован и доступен`, `rc=0`, `CEPH_HEALTHY_AFTER`, содержимое `/ceph` видно.

- [ ] **Step 7: Тест 3 — сторож не мешает здоровой системе**

Запустить полный цикл `ceph_watchdog` на 2 минуты (6 итераций проверки при реальном 20с интервале) на живом, здоровом `/ceph`, без параллельного реального бэкапа, и убедиться что НЕ происходит ложных срабатываний (нет `RECOVER` в логе, нет убитых процессов — их и не должно быть, rclone не запущен).

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "
source /tmp/watchdog_functions.sh
LOGFILE=/tmp/watchdog_healthy_test.log
log() { echo \"[\$1] \${*:2}\" | tee -a \"\$LOGFILE\"; }
timeout 130 bash -c ceph_watchdog || true
echo ---LOG---
cat \$LOGFILE
rm -f \$LOGFILE
"'
```

Ожидается: только строка `ceph_watchdog: запущен...`, никаких `недоступен`/`ceph_watchdog_recover` записей за ~2 минуты нормальной работы.

- [ ] **Step 8: Восстановить продакшн-путь**

Убедиться, что после Step 5-7 `/ceph` в норме и никаких временных файлов не осталось (включая `/tmp/watchdog_functions.sh` из Step 4):
```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "rm -f /tmp/watchdog_functions.sh /tmp/watchdog_*.log; timeout 3 stat /ceph && echo OK; ls /tmp/watchdog_* 2>&1"'
```
Ожидается: `OK`, `ls: cannot access ...` (все временные файлы удалены).

---

### Task 3: Деплой на arch04

**Files:**
- Deploy to: `arch04:/usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh`

**Interfaces:**
- Consumes: тот же файл, уже проверенный в Task 1/2.

- [ ] **Step 1: Проверить, что на arch04 сейчас не идёт прогон**

Если ControlMaster для arch04 истёк — попросить пользователя выполнить `a04` интерактивно.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "systemctl is-active rclone-backup.service"'
```
Если `active`/`activating` — НЕ деплоить сейчас, дождаться завершения текущего прогона (проверить через дашборд: `curl http://172.20.10.161:8077/status.json` с amar319, поле `running_now.active`).

- [ ] **Step 2: Резервная копия и деплой**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "cp /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh.bak-$(date +%Y%m%d-%H%M%S)"'
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "cat > /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh"' < /home/amar/Amar73/rclone/rclone_backup_unified_v4.0.0.sh
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "chmod +x /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh && bash -n /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh && echo SYNTAX_OK"'
```
Ожидается: `SYNTAX_OK`.

- [ ] **Step 3: Быстрая живая проверка (тест 2 из Task 2, сокращённо)**

Тот же приём, что в Task 2 Step 4/6 — извлечь функции через `sed` (не `source` всего файла, чтобы избежать риска `exit` из верхнеуровневых проверок скрипта), затем вызвать реальный `ceph_watchdog_recover` против живого `/ceph` на arch04:

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "timeout 3 stat /ceph && echo CEPH_HEALTHY_BEFORE"'
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "
sed -n \"/^ceph_watchdog_check()/,/^}/p; /^ceph_watchdog_recover()/,/^}/p; /^ceph_watchdog()/,/^}/p\" \
    /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh > /tmp/watchdog_functions.sh
source /tmp/watchdog_functions.sh
LOGFILE=/tmp/watchdog_recover_test.log
log() { echo \"[\$1] \${*:2}\" | tee -a \"\$LOGFILE\"; }
ceph_watchdog_recover
echo rc=\$?
"'
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "timeout 3 stat /ceph && echo CEPH_HEALTHY_AFTER; rm -f /tmp/watchdog_functions.sh /tmp/watchdog_recover_test.log"'
```
Ожидается: `CEPH_HEALTHY_BEFORE`, `rc=0`, `CEPH_HEALTHY_AFTER`.

---

### Task 4: Деплой на arch05

**Files:**
- Deploy to: `arch05:/usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh`

**Interfaces:**
- Consumes: тот же файл.

- [ ] **Step 1: Проверить, что на arch05 сейчас не идёт прогон**

Если ControlMaster для arch05 истёк — попросить пользователя выполнить `a05` интерактивно.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "systemctl is-active rclone-backup.service"'
```
Если `active`/`activating` — НЕ деплоить сейчас, дождаться завершения (см. дашборд).

- [ ] **Step 2: Резервная копия и деплой**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "cp /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh.bak-$(date +%Y%m%d-%H%M%S)"'
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "cat > /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh"' < /home/amar/Amar73/rclone/rclone_backup_unified_v4.0.0.sh
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "chmod +x /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh && bash -n /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh && echo SYNTAX_OK"'
```
Ожидается: `SYNTAX_OK`.

- [ ] **Step 3: Быстрая живая проверка**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "timeout 3 stat /ceph && echo CEPH_HEALTHY_BEFORE"'
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "
sed -n \"/^ceph_watchdog_check()/,/^}/p; /^ceph_watchdog_recover()/,/^}/p; /^ceph_watchdog()/,/^}/p\" \
    /usr/local/bin/scripts/rclone_backup_unified_v4.0.0.sh > /tmp/watchdog_functions.sh
source /tmp/watchdog_functions.sh
LOGFILE=/tmp/watchdog_recover_test.log
log() { echo \"[\$1] \${*:2}\" | tee -a \"\$LOGFILE\"; }
ceph_watchdog_recover
echo rc=\$?
"'
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "timeout 3 stat /ceph && echo CEPH_HEALTHY_AFTER; rm -f /tmp/watchdog_functions.sh /tmp/watchdog_recover_test.log"'
```
Ожидается: `CEPH_HEALTHY_BEFORE`, `rc=0`, `CEPH_HEALTHY_AFTER`.

---

## Итоговая проверка спеки

- ✅ Непрерывная проверка `/ceph` во время ЭТАП 4 — `ceph_watchdog()` (Task 1).
- ✅ Порог 2 подряд, интервал 20с — константы в Task 1 Step 2.
- ✅ Остановка rclone до удаления на основе битого списка + перемонтирование — `ceph_watchdog_recover()`.
- ✅ Переиспользование существующего `retry_command` вместо новой retry-логики — обеспечивается самим фактом, что убитый процесс просто возвращает ненулевой код, который `backup_directory`/`retry_command` уже обрабатывают; в плане ничего не меняется в этих функциях.
- ✅ Корректная остановка сторожа (после ЭТАП 4 и в `cleanup()` при прерывании) — Task 1 Step 3/5.
- ✅ Общий файл, деплой на все три хоста — Task 2/3/4.
- Вне рамок (как и в спеке): разделение `--backup-dir` по источникам, починка самой нестабильности MDS на стороне кластера, уведомления — не реализуются здесь.
