# Мониторинг бэкапов arch03/04/05 — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Автономная (без участия человека 24/7) веб-страница на русском языке, показывающая статус бэкапов на arch03/04/05: последний успешный прогон, текущий прогресс, состояние Ceph-mount, ошибки — с автообновлением каждые ~30-60 секунд.

**Architecture:** Локальные cron-скрипты на каждом arch0X пишут JSON-статус без сети. Отдельный collector-скрипт на amar319 (по cron) забирает эти JSON через новый SSH-ключ без пароля, но жёстко ограниченный форсированной командой (`command=` в authorized_keys — ключ физически не может выполнить ничего кроме одного read-only скрипта). Локальный HTTP-сервер на amar319 отдаёт статическую HTML-страницу с JS, которая переодически перечитывает агрегированный JSON.

**Tech Stack:** bash, python3 (для JSON — везде уже есть python3, использовался в этой сессии), systemd (user service + cron), ванильный HTML/CSS/JS без сборки и без внешних CDN.

## Global Constraints

- Доступ к arch03/04/05 только через `amar319 → wn75 → arch0X` (ProxyJump), см. память `ssh_topology_arch_backup.md`. Личный ключ пользователя на amar319 защищён паролем — каждая live-проверка в этом плане, если ControlMaster-сокет истёк (`ls ~/.ssh/ctrl-*` на amar319), требует попросить пользователя интерактивно выполнить `ssh wn75`/`a03`/`a04`/`a05` и ввести passphrase.
- Любое изменение `authorized_keys` на wn75/arch03/04/05 — это изменение продакшн-инфраструктуры. Каждый такой шаг в этом плане должен быть показан пользователю (точная команда) и выполнен только после его подтверждения — без исключений, даже если предыдущий шаг уже был подтверждён.
- Все пользовательские тексты (HTML-страница) — на русском языке.
- Веб-сервер слушает только `127.0.0.1` на amar319 (подтверждено пользователем — доступ только изнутри домашней сети/localhost), без внешней экспозиции.
- Не запускать `rclone-backup.service` (реальные бэкапы) в рамках тестирования этого плана — только читать существующие логи/summary.json. См. память `ceph_mount_dropout_incidents.md` про инцидент 2026-07-07 с потерей части бэкапа `sw` из-за повторного запуска синхронизации на нестабильном Ceph.
- Реальная схема `*.summary.json` (проверена в этой сессии на arch03, `/var/log/backup/backup_2026-07-07_07-36-47.summary.json`):
  ```json
  {
    "timestamp": "2026-07-07T10:52:09+0300",
    "result": "success",
    "statistics": {
      "transfers": 0, "checks": 896, "deletes": 0, "errors": 0,
      "total_bytes": 0, "transferred_bytes": 0,
      "elapsed_time_seconds": 1376.671136559,
      "average_speed_bytes_per_sec": 0
    },
    "sources": [ { "source": "...", "destination_files": 643, ... } ]
  }
  ```
  Полей `finished_at`/`files_copied`/`files_deleted` НЕТ в исходном файле — верхнеуровневое поле называется `timestamp`, а счётчики лежат в `statistics.transfers`/`statistics.deletes`/`statistics.errors`. Код в этом плане уже учитывает это (не переизобретать поля).

---

### Task 1: `backup_status.sh` — написание и деплой на arch03

**Files:**
- Create: `/home/amar/Amar73/rclone/backup_status.sh` (локальная копия в репозитории для версионирования)
- Deploy to: `arch03:/usr/local/bin/scripts/backup_status.sh`
- Deploy to: `arch03:/etc/cron.d/backup-status` (новый cron-файл)

**Interfaces:**
- Produces: файл `/var/lib/backup-status/status.json` на arch0X со схемой:
  ```json
  {
    "host": "arch03",
    "generated_at": "2026-07-07T12:00:00+03:00",
    "last_success": {
      "finished_at": "2026-07-07T10:52:09+0300",
      "result": "success",
      "files_copied": 0,
      "files_deleted": 0,
      "errors": 0,
      "duration_sec": 1376.671136559
    },
    "running_now": { "active": false },
    "ceph": {
      "mounted": true,
      "accessible": true,
      "last_mds_incident": "2026-07-07T10:51:53+03:00"
    },
    "disk": { "backup_used_percent": 13, "backup_avail_human": "112G" }
  }
  ```
  (`last_success` может быть `null`, если ни одного `.summary.json` не найдено; `running_now.active=true` добавляет поля `started_at`, `checks_done`, `checks_total`, `percent`.)
- Produces: команда `backup_status.sh --print`, которая просто выводит текущее содержимое `status.json` в stdout (это будет forced-command для SSH-ключа в Task 4).
- Consumes: ничего (первый скрипт в цепочке).

- [ ] **Step 1: Написать `backup_status.sh` локально**

Создать файл `/home/amar/Amar73/rclone/backup_status.sh`:

```bash
#!/bin/bash
# Генерирует /var/lib/backup-status/status.json для дашборда мониторинга.
# Без аргументов — пересчитать статус (режим cron).
# --print — просто вывести уже посчитанный файл (используется как forced-command по SSH).
set -uo pipefail

STATUS_DIR="/var/lib/backup-status"
STATUS_FILE="$STATUS_DIR/status.json"
LOG_DIR="/var/log/backup"
SERVICE_NAME="rclone-backup.service"

if [[ "${1:-}" == "--print" ]]; then
  cat "$STATUS_FILE" 2>/dev/null || echo '{"error":"status file not found"}'
  exit 0
fi

mkdir -p "$STATUS_DIR"

HOST=$(hostname -s)
GENERATED_AT=$(date -Iseconds)

# --- last_success: разбираем самый свежий *.summary.json ---
LATEST_SUMMARY=$(ls -t "$LOG_DIR"/*.summary.json 2>/dev/null | head -1)
if [[ -n "$LATEST_SUMMARY" ]]; then
  LAST_SUCCESS_JSON=$(python3 -c "
import json
try:
    with open('$LATEST_SUMMARY') as f:
        d = json.load(f)
    stats = d.get('statistics', {})
    print(json.dumps({
        'finished_at': d.get('timestamp'),
        'result': d.get('result'),
        'files_copied': stats.get('transfers', 0),
        'files_deleted': stats.get('deletes', 0),
        'errors': stats.get('errors', 0),
        'duration_sec': stats.get('elapsed_time_seconds', 0),
    }))
except Exception as e:
    print(json.dumps({'error': str(e)}))
")
else
  LAST_SUCCESS_JSON='null'
fi

# --- running_now: активен ли сервис бэкапа, и насколько далеко продвинулся ---
SERVICE_STATE=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
CHECKS_DONE=0
CHECKS_TOTAL=0
PERCENT=0
STARTED_AT="null"
if [[ "$SERVICE_STATE" == "active" || "$SERVICE_STATE" == "activating" ]]; then
  CURRENT_LOG=$(ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | head -1)
  LAST_CHECK_LINE=$(grep -oE 'Checks:[[:space:]]+[0-9]+ */ *[0-9]+' "$CURRENT_LOG" 2>/dev/null | tail -1)
  if [[ -n "$LAST_CHECK_LINE" ]]; then
    CHECKS_DONE=$(echo "$LAST_CHECK_LINE" | grep -oE '[0-9]+' | sed -n '1p')
    CHECKS_TOTAL=$(echo "$LAST_CHECK_LINE" | grep -oE '[0-9]+' | sed -n '2p')
  fi
  CHECKS_DONE=${CHECKS_DONE:-0}
  CHECKS_TOTAL=${CHECKS_TOTAL:-0}
  if [[ "$CHECKS_TOTAL" -gt 0 ]]; then
    PERCENT=$(( CHECKS_DONE * 100 / CHECKS_TOTAL ))
  fi
  STARTED_AT_RAW=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null)
  STARTED_AT=$(date -d "$STARTED_AT_RAW" -Iseconds 2>/dev/null || echo "null")
fi

# --- ceph: смонтирован ли, реально ли доступен, когда был последний сбой ---
CEPH_MOUNTED=false
mount | grep -q ' ceph ' && CEPH_MOUNTED=true

CEPH_ACCESSIBLE=false
timeout 3 stat /ceph >/dev/null 2>&1 && CEPH_ACCESSIBLE=true

LAST_MDS_INCIDENT="null"
LAST_MDS_LINE=$(dmesg -T 2>/dev/null | grep -i "rejected session" | tail -1)
if [[ -n "$LAST_MDS_LINE" ]]; then
  LAST_MDS_RAW=$(echo "$LAST_MDS_LINE" | sed -E 's/^\[(.*)\].*/\1/')
  LAST_MDS_INCIDENT=$(date -d "$LAST_MDS_RAW" -Iseconds 2>/dev/null || echo "null")
fi

# --- disk: место на /backup ---
DISK_LINE=$(df -h /backup 2>/dev/null | tail -1)
DISK_USED_PERCENT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')
DISK_AVAIL=$(echo "$DISK_LINE" | awk '{print $4}')
DISK_USED_PERCENT=${DISK_USED_PERCENT:-0}
DISK_AVAIL=${DISK_AVAIL:-"?"}

RUNNING_ACTIVE=false
[[ "$SERVICE_STATE" == "active" || "$SERVICE_STATE" == "activating" ]] && RUNNING_ACTIVE=true

python3 - "$HOST" "$GENERATED_AT" "$LAST_SUCCESS_JSON" "$RUNNING_ACTIVE" "$STARTED_AT" \
  "$CHECKS_DONE" "$CHECKS_TOTAL" "$PERCENT" "$CEPH_MOUNTED" "$CEPH_ACCESSIBLE" \
  "$LAST_MDS_INCIDENT" "$DISK_USED_PERCENT" "$DISK_AVAIL" > "$STATUS_FILE" <<'PYEOF'
import json, sys

(host, generated_at, last_success_json, running_active, started_at,
 checks_done, checks_total, percent, ceph_mounted, ceph_accessible,
 last_mds, disk_pct, disk_avail) = sys.argv[1:14]

last_success = json.loads(last_success_json) if last_success_json != "null" else None

running_now = {"active": running_active == "true"}
if running_now["active"]:
    running_now.update({
        "started_at": None if started_at == "null" else started_at,
        "checks_done": int(checks_done),
        "checks_total": int(checks_total),
        "percent": int(percent),
    })

data = {
    "host": host,
    "generated_at": generated_at,
    "last_success": last_success,
    "running_now": running_now,
    "ceph": {
        "mounted": ceph_mounted == "true",
        "accessible": ceph_accessible == "true",
        "last_mds_incident": None if last_mds == "null" else last_mds,
    },
    "disk": {
        "backup_used_percent": int(disk_pct) if disk_pct.isdigit() else None,
        "backup_avail_human": disk_avail,
    },
}
print(json.dumps(data, indent=2))
PYEOF
```

- [ ] **Step 2: Скопировать скрипт на arch03 и сделать исполняемым**

Через amar319 (замените на реальный доступный путь; если ControlMaster для arch03 истёк — попросите пользователя выполнить `a03` интерактивно и ввести passphrase перед этим шагом):

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "cat > /usr/local/bin/scripts/backup_status.sh"' < /home/amar/Amar73/rclone/backup_status.sh
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "chmod +x /usr/local/bin/scripts/backup_status.sh"'
```

- [ ] **Step 3: Запустить вручную и проверить, что JSON валиден и осмыслен**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "/usr/local/bin/scripts/backup_status.sh && cat /var/lib/backup-status/status.json | python3 -m json.tool"'
```

Ожидается: валидный JSON, `last_success.finished_at` близко к времени последнего известного `.summary.json` (сверить с `ls -t /var/log/backup/*.summary.json | head -1` на том же хосте), `ceph.accessible` соответствует реальному состоянию (`ls /ceph` на хосте в этот же момент), `disk.backup_used_percent` совпадает с `df -h /backup`.

- [ ] **Step 4: Проверить `--print` режим**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "/usr/local/bin/scripts/backup_status.sh --print"'
```

Ожидается: то же самое содержимое, что в Step 3, без пересчёта (быстрый вывод).

- [ ] **Step 5: Добавить cron-задачу на arch03**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch03 "echo \"*/2 * * * * root /usr/local/bin/scripts/backup_status.sh >/dev/null 2>&1\" > /etc/cron.d/backup-status && chmod 644 /etc/cron.d/backup-status"'
```

Проверка: подождать 2-3 минуты, затем `ssh arch03 "date; stat -c %y /var/lib/backup-status/status.json"` — время модификации файла должно быть свежее, чем время последнего ручного запуска в Step 3.

- [ ] **Step 6: Закоммитить локальную копию скрипта**

```bash
cd /home/amar/Amar73/rclone
git add backup_status.sh
git commit -m "$(cat <<'EOF'
Add backup_status.sh — per-host JSON status generator for monitoring dashboard

Runs via cron on arch0X, writes /var/lib/backup-status/status.json locally
(no network needed). Also supports --print for the SSH forced-command used
by the monitoring collector.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Деплой `backup_status.sh` на arch04

**Files:**
- Deploy to: `arch04:/usr/local/bin/scripts/backup_status.sh`
- Deploy to: `arch04:/etc/cron.d/backup-status`

**Interfaces:**
- Consumes: тот же файл `backup_status.sh`, написанный в Task 1 (не переписывать).

- [ ] **Step 1: Скопировать, сделать исполняемым, добавить cron**

Если ControlMaster для arch04 истёк — попросить пользователя выполнить `a04` интерактивно.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "cat > /usr/local/bin/scripts/backup_status.sh"' < /home/amar/Amar73/rclone/backup_status.sh
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "chmod +x /usr/local/bin/scripts/backup_status.sh"'
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "echo \"*/2 * * * * root /usr/local/bin/scripts/backup_status.sh >/dev/null 2>&1\" > /etc/cron.d/backup-status && chmod 644 /etc/cron.d/backup-status"'
```

- [ ] **Step 2: Проверить вручную**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch04 "/usr/local/bin/scripts/backup_status.sh && cat /var/lib/backup-status/status.json | python3 -m json.tool"'
```

Ожидается: валидный JSON. На arch04 в эту сессию мы видели, что backup-прогон может идти по много часов (`running_now.active` может оказаться `true` с реальными числами checks_done/checks_total — это нормально, не ошибка).

- [ ] **Step 3: Коммит не нужен** (файл уже закоммичен в Task 1, здесь только деплой)

---

### Task 3: Деплой `backup_status.sh` на arch05

**Files:**
- Deploy to: `arch05:/usr/local/bin/scripts/backup_status.sh`
- Deploy to: `arch05:/etc/cron.d/backup-status`

**Interfaces:**
- Consumes: тот же файл `backup_status.sh` из Task 1.

- [ ] **Step 1: Скопировать, сделать исполняемым, добавить cron**

Если ControlMaster для arch05 истёк — попросить пользователя выполнить `a05` интерактивно.

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "cat > /usr/local/bin/scripts/backup_status.sh"' < /home/amar/Amar73/rclone/backup_status.sh
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "chmod +x /usr/local/bin/scripts/backup_status.sh"'
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "echo \"*/2 * * * * root /usr/local/bin/scripts/backup_status.sh >/dev/null 2>&1\" > /etc/cron.d/backup-status && chmod 644 /etc/cron.d/backup-status"'
```

- [ ] **Step 2: Проверить вручную**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh arch05 "/usr/local/bin/scripts/backup_status.sh && cat /var/lib/backup-status/status.json | python3 -m json.tool"'
```

Ожидается: валидный JSON, `last_success` соответствует последнему известному успешному прогону arch05 (839.69 GB / 140644 файлов из этой сессии, если с тех пор не было нового прогона).

---

### Task 4: Ключ мониторинга без пароля + ограниченный доступ

**Files:**
- Create (on amar319): `~/.ssh/monitor_ed25519`, `~/.ssh/monitor_ed25519.pub`
- Create (on amar319): `~/.ssh/monitor_config`
- Modify: `wn75:/root/.ssh/authorized_keys`, `arch03:/root/.ssh/authorized_keys`, `arch04:/root/.ssh/authorized_keys`, `arch05:/root/.ssh/authorized_keys`

**Interfaces:**
- Produces: SSH-алиасы `wn75-mon`, `arch03-mon`, `arch04-mon`, `arch05-mon` в `~/.ssh/monitor_config` — используются в Task 5.
- Consumes: `backup_status.sh --print` (Task 1-3) как forced-command на arch0X.

- [ ] **Step 1: Сгенерировать новый ключ на amar319 (без пароля)**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/monitor_ed25519 -C "monitor@amar319"'
```

Проверка: `ssh -p 43512 amar@46.34.141.146 'cat ~/.ssh/monitor_ed25519.pub'` — должен вывести один валидный `ssh-ed25519 AAAA...` без запроса пароля.

- [ ] **Step 2: Создать отдельный ssh-config для мониторинга на amar319**

```bash
ssh -p 43512 amar@46.34.141.146 'cat > ~/.ssh/monitor_config' <<'EOF'
Host wn75-mon
    HostName wn75
    User root
    IdentityFile ~/.ssh/monitor_ed25519
    IdentitiesOnly yes
    ConnectTimeout 8

Host arch03-mon
    HostName arch03
    User root
    ProxyJump wn75-mon
    IdentityFile ~/.ssh/monitor_ed25519
    IdentitiesOnly yes
    ConnectTimeout 8

Host arch04-mon
    HostName arch04
    User root
    ProxyJump wn75-mon
    IdentityFile ~/.ssh/monitor_ed25519
    IdentitiesOnly yes
    ConnectTimeout 8

Host arch05-mon
    HostName arch05
    User root
    ProxyJump wn75-mon
    IdentityFile ~/.ssh/monitor_ed25519
    IdentitiesOnly yes
    ConnectTimeout 8
EOF
ssh -p 43512 amar@46.34.141.146 'chmod 600 ~/.ssh/monitor_config'
```

Отдельный файл (не трогаем `~/.ssh/config` пользователя) — использует свои алиасы (`arch03-mon`, а не `arch03`), никак не пересекается с личными настройками пользователя.

- [ ] **Step 3: Показать пользователю и получить подтверждение перед изменением authorized_keys**

Вывести пользователю публичный ключ и точные команды из Step 4-5 ниже, дождаться явного "да, добавляй" — это правки продакшн-конфигурации root на 4 хостах.

- [ ] **Step 4: Добавить ключ на wn75 (ограниченный: только port-forwarding, без shell/команд)**

Чтобы не бороться с экранированием кавычек через три уровня вложенности SSH, содержимое строки для `authorized_keys` готовится ЛОКАЛЬНО в файл и передаётся через stdin — это тот же приём, что уже успешно использовался в этой сессии для доставки скриптов (`cat > file` через redirect).

Получить публичный ключ и собрать локальный файл со строкой для wn75:
```bash
PUBKEY=$(ssh -p 43512 amar@46.34.141.146 'cat ~/.ssh/monitor_ed25519.pub')
echo "restrict,port-forwarding $PUBKEY" > /tmp/monitor_key_wn75.txt
cat /tmp/monitor_key_wn75.txt   # проверить, что строка выглядит правильно, перед отправкой
```

Дописать на wn75 (один уровень вложенности — amar319 → wn75, содержимое приходит через stdin, а не через аргумент командной строки):
```bash
ssh -p 43512 amar@46.34.141.146 'ssh wn75 "cat >> /root/.ssh/authorized_keys"' < /tmp/monitor_key_wn75.txt
```

Проверка:
```bash
ssh -p 43512 amar@46.34.141.146 'ssh wn75 "tail -1 /root/.ssh/authorized_keys"'
```
Ожидается: строка начинается с `restrict,port-forwarding ssh-ed25519 AAAA...`.

- [ ] **Step 5: Добавить ключ на arch03/04/05 (forced command, только чтение статуса)**

Собрать локальный файл со строкой для arch0X (обратите внимание — `command=` со внутренними двойными кавычками записывается в **одинарных** кавычках всей строки, чтобы не экранировать их):
```bash
echo 'command="/usr/local/bin/scripts/backup_status.sh --print",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty '"$PUBKEY" > /tmp/monitor_key_arch.txt
cat /tmp/monitor_key_arch.txt   # проверить перед отправкой — должно быть ОДНОЙ строкой
```

Доставить на arch03 через двойную вложенность (amar319 → wn75 → arch03), stdin форвардится по цепочке так же, как при обычном деплое скриптов ранее в этой сессии:
```bash
ssh -p 43512 amar@46.34.141.146 'ssh wn75 "ssh root@arch03 \"cat >> /root/.ssh/authorized_keys\""' < /tmp/monitor_key_arch.txt
```

Проверить именно на этом хосте перед тем как повторять для следующего:
```bash
ssh -p 43512 amar@46.34.141.146 'ssh wn75 "ssh root@arch03 tail -1 /root/.ssh/authorized_keys"'
```
Ожидается: строка начинается с `command="/usr/local/bin/scripts/backup_status.sh --print",no-port-forwarding,...`.

Повторить те же две команды (доставка + проверка), заменив `arch03` на `arch04`, затем на `arch05`.

- [ ] **Step 6: Проверить, что ограниченный ключ работает ТОЛЬКО для чтения статуса**

```bash
ssh -p 43512 amar@46.34.141.146 'ssh -F ~/.ssh/monitor_config arch03-mon "whoami"'
```

Ожидается: НЕ выводит "root" — сервер должен проигнорировать `whoami` и вместо этого выполнить forced-command, вернув JSON статуса (или ошибку about `Cannot execute command-line and remote command` в зависимости от версии OpenSSH — оба варианта означают, что защита работает; главное, что `whoami` НЕ выполнился).

```bash
ssh -p 43512 amar@46.34.141.146 'ssh -F ~/.ssh/monitor_config arch03-mon' 
```

(без указания команды) — должен вернуть валидный JSON статуса arch03, тот же что в Task 1 Step 3.

- [ ] **Step 7: Обновить память**

Добавить в `ssh_topology_arch_backup.md` заметку про новый `monitor_ed25519`/`monitor_config` — отдельный, без пароля, ограниченный ключ только для мониторинга, не путать с личным ключом пользователя.

---

### Task 5: `collect_status.sh` на amar319

**Files:**
- Create: `/home/amar/Amar73/rclone/collect_status.sh` (локальная копия в репозитории)
- Deploy to: `amar319:~/backup-monitor/collect_status.sh`

**Interfaces:**
- Consumes: алиасы `arch03-mon`/`arch04-mon`/`arch05-mon` из `~/.ssh/monitor_config` (Task 4), JSON-контракт `backup_status.sh --print` (Task 1).
- Produces: `~/backup-monitor/state.json` (персистентное последнее известное состояние по каждому хосту, с полем `history`), `~/backup-monitor/www/status.json` (то, что читает дашборд):
  ```json
  {
    "generated_at": "2026-07-07T12:02:00+03:00",
    "hosts": {
      "arch03": { "...как в Task 1...", "stale": false, "last_seen": "...", "history": [ {"finished_at": "...", "result": "success", "errors": 0} ] },
      "arch04": { "...", "stale": true, "last_seen": "2026-07-07T11:40:00+03:00" }
    }
  }
  ```

- [ ] **Step 1: Написать `collect_status.sh` локально**

Создать `/home/amar/Amar73/rclone/collect_status.sh`:

```bash
#!/bin/bash
# Забирает status.json с arch03/04/05 через ограниченный ключ мониторинга,
# складывает в ~/backup-monitor/www/status.json для дашборда.
# Хосты, недоступные в этот раз, помечаются stale:true, но не теряют
# последние известные данные.
set -uo pipefail

OUTDIR="$HOME/backup-monitor"
WWWDIR="$OUTDIR/www"
STATE_FILE="$OUTDIR/state.json"
OUT_FILE="$WWWDIR/status.json"
SSH_CONFIG="$HOME/.ssh/monitor_config"
HOSTS=(arch03 arch04 arch05)

mkdir -p "$WWWDIR"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

NOW=$(date -Iseconds)

fetch_one() {
  local host="$1"
  ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ControlMaster=no -o ControlPath=none "${host}-mon" 2>/dev/null
}

{
  echo "$NOW"
  for h in "${HOSTS[@]}"; do
    echo "---HOST:$h---"
    fetch_one "$h"
    echo "---END:$h---"
  done
} | python3 "$OUTDIR/_merge_status.py" "$STATE_FILE" "$OUT_FILE"
```

Поскольку интерполировать вывод нескольких SSH-вызовов в python через argv неудобно (JSON может быть многострочным), вынести слияние в отдельный питон-файл, читающий размеченный stdout. Создать `/home/amar/Amar73/rclone/_merge_status.py`:

```python
#!/usr/bin/env python3
"""Читает разметку '---HOST:x---'/JSON/'---END:x---' из stdin,
сливает с state_file (сохраняя историю и stale-статус), пишет out_file."""
import json
import sys

state_file, out_file = sys.argv[1], sys.argv[2]

lines = sys.stdin.read().splitlines()
now = lines[0] if lines else None

with open(state_file) as f:
    state = json.load(f)

i = 1
current_host = None
buf = []
while i < len(lines):
    line = lines[i]
    if line.startswith("---HOST:") and line.endswith("---"):
        current_host = line[len("---HOST:"):-len("---")]
        buf = []
    elif line.startswith("---END:") and line.endswith("---"):
        raw = "\n".join(buf).strip()
        prev = state.get(current_host, {})
        try:
            data = json.loads(raw)
            data["stale"] = False
            data["last_seen"] = now

            history = prev.get("history", [])
            new_success = data.get("last_success")
            prev_success = prev.get("last_success")
            if new_success and (
                not prev_success
                or new_success.get("finished_at") != prev_success.get("finished_at")
            ):
                history.append({
                    "finished_at": new_success.get("finished_at"),
                    "result": new_success.get("result"),
                    "errors": new_success.get("errors"),
                })
                history = history[-14:]
            data["history"] = history

            state[current_host] = data
        except (json.JSONDecodeError, TypeError):
            if current_host in state:
                state[current_host]["stale"] = True
            else:
                state[current_host] = {
                    "host": current_host, "stale": True,
                    "last_seen": None, "history": [],
                }
        current_host = None
    elif current_host is not None:
        buf.append(line)
    i += 1

with open(state_file, "w") as f:
    json.dump(state, f, indent=2)

with open(out_file, "w") as f:
    json.dump({"generated_at": now, "hosts": state}, f, indent=2)
```

- [ ] **Step 2: Деплой на amar319**

```bash
ssh -p 43512 amar@46.34.141.146 'mkdir -p ~/backup-monitor/www'
ssh -p 43512 amar@46.34.141.146 'cat > ~/backup-monitor/collect_status.sh' < /home/amar/Amar73/rclone/collect_status.sh
ssh -p 43512 amar@46.34.141.146 'cat > ~/backup-monitor/_merge_status.py' < /home/amar/Amar73/rclone/_merge_status.py
ssh -p 43512 amar@46.34.141.146 'chmod +x ~/backup-monitor/collect_status.sh ~/backup-monitor/_merge_status.py'
```

- [ ] **Step 3: Запустить вручную и проверить агрегацию**

```bash
ssh -p 43512 amar@46.34.141.146 '~/backup-monitor/collect_status.sh && cat ~/backup-monitor/www/status.json | python3 -m json.tool'
```

Ожидается: JSON с ключом `hosts`, содержащим `arch03`, `arch04`, `arch05`, у каждого `stale: false` и свежий `last_seen`. Сверить `last_success` каждого хоста с тем, что видели в Task 1-3.

- [ ] **Step 4: Проверить обработку stale (искусственно сломать доступ к одному хосту)**

Временно испортить SSH-конфиг для одного хоста, чтобы имитировать недоступность:

```bash
ssh -p 43512 amar@46.34.141.146 'cp ~/.ssh/monitor_config ~/.ssh/monitor_config.bak'
ssh -p 43512 amar@46.34.141.146 "sed -i 's/HostName arch04/HostName arch04-nonexistent/' ~/.ssh/monitor_config"
ssh -p 43512 amar@46.34.141.146 '~/backup-monitor/collect_status.sh && cat ~/backup-monitor/www/status.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"hosts\"][\"arch04\"][\"stale\"], d[\"hosts\"][\"arch04\"].get(\"last_success\"))"'
```

Ожидается: `True <прежние данные arch04, не null>` — то есть `stale=True`, но `last_success` НЕ пропал, остался от предыдущего успешного сбора.

Откатить порчу конфига:
```bash
ssh -p 43512 amar@46.34.141.146 'mv ~/.ssh/monitor_config.bak ~/.ssh/monitor_config'
ssh -p 43512 amar@46.34.141.146 '~/backup-monitor/collect_status.sh'
```

- [ ] **Step 5: Коммит**

```bash
cd /home/amar/Amar73/rclone
git add collect_status.sh _merge_status.py
git commit -m "$(cat <<'EOF'
Add collect_status.sh — aggregates per-host backup status on amar319

Fetches status.json from arch03/04/05 via the restricted monitor_ed25519
key (see monitor_config), merges into a single status.json for the
dashboard, and preserves last-known-good data (marked stale) when a host
is temporarily unreachable instead of dropping it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Cron для `collect_status.sh` на amar319

**Files:**
- Modify: crontab пользователя `amar` на amar319

**Interfaces:**
- Consumes: `collect_status.sh` из Task 5.

- [ ] **Step 1: Добавить в crontab**

```bash
ssh -p 43512 amar@46.34.141.146 '(crontab -l 2>/dev/null; echo "*/2 * * * * $HOME/backup-monitor/collect_status.sh >/dev/null 2>&1") | crontab -'
```

- [ ] **Step 2: Проверить, что задача появилась**

```bash
ssh -p 43512 amar@46.34.141.146 'crontab -l | grep collect_status'
```

- [ ] **Step 3: Подождать 2-3 минуты и убедиться, что файл обновляется автоматически**

```bash
ssh -p 43512 amar@46.34.141.146 'stat -c %y ~/backup-monitor/www/status.json'
```

Повторить через 3 минуты — timestamp должен измениться без ручного запуска.

---

### Task 7: `dashboard.html`

**Files:**
- Create: `/home/amar/Amar73/rclone/dashboard.html` (локальная копия)
- Deploy to: `amar319:~/backup-monitor/www/dashboard.html`

**Interfaces:**
- Consumes: схему `status.json` из Task 5 (`{generated_at, hosts: {host: {..., stale, history}}}`).

- [ ] **Step 1: Написать `dashboard.html` локально**

Создать `/home/amar/Amar73/rclone/dashboard.html`:

```html
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Мониторинг бэкапов</title>
<style>
  :root { color-scheme: dark; }
  body {
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
    background: #0f1115;
    color: #e6e6e6;
    margin: 0;
    padding: 24px;
  }
  h1 { font-size: 1.4rem; margin-bottom: 20px; }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    gap: 16px;
  }
  .card {
    background: #1a1d24;
    border-radius: 10px;
    padding: 18px;
    border: 1px solid #2a2e37;
  }
  .card.stale { opacity: 0.55; border-style: dashed; }
  .card-header { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
  .badge { font-size: 1.4rem; }
  .host-name { font-size: 1.1rem; font-weight: 600; }
  .row { display: flex; justify-content: space-between; padding: 4px 0; font-size: 0.92rem; color: #b8bcc4; }
  .row b { color: #e6e6e6; font-weight: 500; }
  .progress-wrap { margin-top: 10px; }
  .progress-bar-bg { background: #2a2e37; border-radius: 6px; height: 10px; overflow: hidden; }
  .progress-bar-fill { background: #4c8bf5; height: 100%; transition: width 0.5s; }
  .ceph-line { display: flex; align-items: center; gap: 6px; margin-top: 10px; font-size: 0.9rem; }
  .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; flex-shrink: 0; }
  .dot.green { background: #3ecf6d; }
  .dot.red { background: #e5484d; }
  .history { display: flex; gap: 3px; margin-top: 12px; }
  .history .cell { width: 14px; height: 14px; border-radius: 3px; }
  .stale-note { font-size: 0.85rem; color: #e0b34c; margin-top: 10px; }
  .updated-at { color: #6b7280; font-size: 0.8rem; margin-top: 24px; }
</style>
</head>
<body>
  <h1>Мониторинг резервного копирования — arch03 / arch04 / arch05</h1>
  <div class="grid" id="grid"></div>
  <div class="updated-at" id="updated-at">Загрузка…</div>

<script>
const WARN_HOURS = 30;
const CRIT_HOURS = 48;

function hoursSince(iso) {
  if (!iso) return Infinity;
  return (Date.now() - new Date(iso).getTime()) / 3600000;
}

function humanAgo(iso) {
  if (!iso) return "нет данных";
  const h = hoursSince(iso);
  if (h < 1) return Math.max(1, Math.round(h * 60)) + " мин назад";
  if (h < 48) return Math.round(h) + " ч назад";
  return Math.round(h / 24) + " дн назад";
}

function statusFor(hostData) {
  if (hostData.stale) return "yellow";
  const ceph = hostData.ceph || {};
  if (ceph.accessible === false) return "red";
  const ls = hostData.last_success;
  const h = ls ? hoursSince(ls.finished_at) : Infinity;
  if (h > CRIT_HOURS) return "red";
  if (h > WARN_HOURS) return "yellow";
  if (ls && ls.errors > 0) return "yellow";
  return "green";
}

function badgeFor(status) {
  return { green: "✅", yellow: "⚠️", red: "❌" }[status];
}

function renderCard(host, data) {
  const status = statusFor(data);
  const ls = data.last_success;
  const running = data.running_now || {};
  const ceph = data.ceph || {};

  let html = `<div class="card ${data.stale ? 'stale' : ''}">`;
  html += `<div class="card-header"><span class="badge">${badgeFor(status)}</span><span class="host-name">${host}</span></div>`;

  html += `<div class="row"><span>Последний успешный бэкап</span><b>${ls ? humanAgo(ls.finished_at) : 'нет данных'}</b></div>`;
  if (ls) {
    html += `<div class="row"><span>Скопировано / удалено файлов</span><b>${ls.files_copied} / ${ls.files_deleted}</b></div>`;
    html += `<div class="row"><span>Ошибок</span><b>${ls.errors}</b></div>`;
  }

  if (running.active) {
    html += `<div class="progress-wrap">
      <div class="row"><span>Идёт прогон сейчас</span><b>${running.percent}% (${running.checks_done} / ${running.checks_total})</b></div>
      <div class="progress-bar-bg"><div class="progress-bar-fill" style="width:${running.percent}%"></div></div>
    </div>`;
  }

  const cephDot = ceph.accessible ? "green" : "red";
  html += `<div class="ceph-line"><span class="dot ${cephDot}"></span> Ceph: ${ceph.accessible ? 'доступен' : 'НЕДОСТУПЕН'}`;
  if (ceph.last_mds_incident) {
    html += ` <span style="color:#6b7280">(последний сбой: ${humanAgo(ceph.last_mds_incident)})</span>`;
  }
  html += `</div>`;

  const history = data.history || [];
  if (history.length) {
    html += `<div class="history">`;
    for (const h of history) {
      const ok = h.result === "success" && (h.errors || 0) === 0;
      html += `<span class="cell" style="background:${ok ? '#3ecf6d' : '#e5484d'}" title="${h.finished_at}"></span>`;
    }
    html += `</div>`;
  }

  if (data.stale) {
    html += `<div class="stale-note">Нет свежих данных с ${data.last_seen ? humanAgo(data.last_seen) : 'неизвестно'}</div>`;
  }

  html += `</div>`;
  return html;
}

async function refresh() {
  try {
    const res = await fetch('status.json?_=' + Date.now());
    const data = await res.json();
    const grid = document.getElementById('grid');
    grid.innerHTML = Object.entries(data.hosts)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([host, hostData]) => renderCard(host, hostData))
      .join('');
    document.getElementById('updated-at').textContent =
      'Обновлено: ' + new Date(data.generated_at).toLocaleString('ru-RU');
  } catch (e) {
    document.getElementById('updated-at').textContent = 'Ошибка загрузки status.json: ' + e;
  }
}

refresh();
setInterval(refresh, 30000);
</script>
</body>
</html>
```

- [ ] **Step 2: Деплой на amar319**

```bash
ssh -p 43512 amar@46.34.141.146 'cat > ~/backup-monitor/www/dashboard.html' < /home/amar/Amar73/rclone/dashboard.html
```

- [ ] **Step 3: Коммит**

```bash
cd /home/amar/Amar73/rclone
git add dashboard.html
git commit -m "$(cat <<'EOF'
Add dashboard.html — visual monitoring page for arch03/04/05 backups

Vanilla HTML/CSS/JS, no build step, no external CDN (served locally with
no internet dependency). Auto-refreshes every 30s from status.json,
renders per-host status badges, progress bar for active runs, Ceph
health, and a 14-run history strip. All copy in Russian.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: HTTP-сервер на amar319 + сквозная проверка

**Files:**
- Create: `amar319:~/.config/systemd/user/backup-dashboard.service`

**Interfaces:**
- Consumes: `~/backup-monitor/www/` (dashboard.html + status.json) из Task 5-7.

- [ ] **Step 1: Создать systemd user-сервис**

```bash
ssh -p 43512 amar@46.34.141.146 'mkdir -p ~/.config/systemd/user'
ssh -p 43512 amar@46.34.141.146 'cat > ~/.config/systemd/user/backup-dashboard.service' <<'EOF'
[Unit]
Description=Backup monitoring dashboard HTTP server

[Service]
WorkingDirectory=%h/backup-monitor/www
ExecStart=/usr/bin/python3 -m http.server 8077 --bind 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
```

- [ ] **Step 2: Включить linger (чтобы user-сервис работал без активной сессии входа)**

```bash
ssh -p 43512 amar@46.34.141.146 'loginctl enable-linger amar'
```

Без этого шага systemd остановит user-сервис при выходе пользователя из системы — а нужна работа 24/7.

- [ ] **Step 3: Запустить сервис**

```bash
ssh -p 43512 amar@46.34.141.146 'systemctl --user daemon-reload && systemctl --user enable --now backup-dashboard.service'
ssh -p 43512 amar@46.34.141.146 'systemctl --user is-active backup-dashboard.service'
```

Ожидается: `active`.

- [ ] **Step 4: Проверить, что страница реально отдаётся**

```bash
ssh -p 43512 amar@46.34.141.146 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8077/dashboard.html'
ssh -p 43512 amar@46.34.141.146 'curl -s http://127.0.0.1:8077/status.json | python3 -m json.tool | head -20'
```

Ожидается: `200`, валидный JSON с реальными данными по трём хостам.

- [ ] **Step 5: Попросить пользователя открыть страницу в браузере**

Дать пользователю инструкцию: открыть `http://127.0.0.1:8077/dashboard.html` **в браузере на самом amar319** (если браузер пользователя работает на другой машине в той же домашней сети, а не на самом amar319 — уточнить у пользователя перед этим шагом, потребуется сменить `--bind 127.0.0.1` на LAN-адрес amar319 в Step 1 и перезапустить сервис).

Попросить подтвердить:
- Три карточки хостов видны, с корректными данными (сверить глазами с тем, что видели в Task 1-3).
- Страница обновляется сама (подождать 30-60 секунд, посмотреть на `Обновлено: ...` внизу — метка времени должна меняться).
- Если сейчас на каком-то хосте идёт реальный прогон бэкапа — виден прогресс-бар с процентом.

- [ ] **Step 6: Финальный коммит (systemd unit для справки)**

```bash
mkdir -p /home/amar/Amar73/rclone/monitor-dashboard-deploy
cat > /home/amar/Amar73/rclone/monitor-dashboard-deploy/backup-dashboard.service <<'EOF'
[Unit]
Description=Backup monitoring dashboard HTTP server

[Service]
WorkingDirectory=%h/backup-monitor/www
ExecStart=/usr/bin/python3 -m http.server 8077 --bind 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
cd /home/amar/Amar73/rclone
git add monitor-dashboard-deploy/backup-dashboard.service
git commit -m "$(cat <<'EOF'
Add reference copy of the dashboard's systemd user unit

Deployed to amar319 at ~/.config/systemd/user/backup-dashboard.service —
kept here for reference/version control alongside the other deployed
scripts (backup_status.sh, collect_status.sh, dashboard.html).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Итоговая проверка спеки

- ✅ Ключ мониторинга без пароля, ограничен `command=` (Task 4) — покрывает раздел "Ключ мониторинга" спеки.
- ✅ Локальный сбор на arch0X без сети (Task 1-3) — покрывает "Локальный сборщик статуса".
- ✅ Забор данных на amar319 с обработкой `stale` (Task 5-6) — покрывает "Забор данных на amar319".
- ✅ Веб-страница на русском, автообновление, пороги 🟢/🟡/🔴, мини-история (Task 7-8) — покрывает "Веб-страница".
- ✅ Локальный, не публичный доступ (`127.0.0.1`) — Task 8.
- Вне рамок плана (как и оговорено в спеке): интеграция в Grafana, уведомления, починка самого бага с потерей файлов при нестабильном Ceph — не реализуются здесь.
