# Мониторинг бэкапов на arch-b (Prometheus + Grafana)

Независимый от старого дашборда (`172.20.10.161:8077` на amar319) стек мониторинга,
работающий на **arch-b**. Развёрнут 2026-07-20.

## Как посмотреть

Всё слушает только `127.0.0.1` — наружу ничего не открыто, firewall не менялся.

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 arch-b
```

* Grafana — <http://localhost:3000>, дашборд «Бэкапы rclone» в папке «Бэкапы»
* Prometheus — <http://localhost:9090>

## Что откуда берётся

| Данные | Источник | Как |
|---|---|---|
| OS-метрики arch03/04/05 | их собственный node_exporter :9100 | Prometheus скрейпит напрямую |
| OS-метрики arch-b | `prometheus-node-exporter` (Debian) | скрейп localhost:9100 |
| Статус бэкапов | `backup_status.sh --print` на arch0X | SSH-pull раз в 2 минуты |

**node_exporter на arch03/04/05 мы не трогаем.** Это v0.17.0 в podman-контейнере из
`registry.ceph.kiae.ru:5000`, принадлежит другой команде. У него не смонтирована
textfile-директория, поэтому backup-метрики туда положить нельзя — отсюда SSH-pull.
Он же не отдаёт файловую систему `/backup` (видит только внутренность контейнера),
поэтому заполненность диска берётся из `backup_status.sh`, а не из node_exporter.

## Файлы

| В репозитории | На arch-b |
|---|---|
| `collect_backup_metrics.sh` | `/usr/local/bin/scripts/collect_backup_metrics.sh` |
| `_render_metrics.py` | `/usr/local/bin/scripts/_render_metrics.py` |
| `deploy/backup-metrics.{service,timer}` | `/etc/systemd/system/` |
| `deploy/prometheus.yml` | `/etc/prometheus/prometheus.yml` |
| `deploy/grafana-datasource.yml` | `/etc/grafana/provisioning/datasources/prometheus.yml` |
| `deploy/grafana-dashboard-provider.yml` | `/etc/grafana/provisioning/dashboards/rclone-backups.yml` |
| `deploy/grafana-dashboard-backups.json` | `/var/lib/grafana/dashboards/rclone-backups.json` |

Сборщик пишет `/var/lib/prometheus/node-exporter/rclone_backup.prom`, откуда его
забирает textfile-коллектор node_exporter. Директория принадлежит `amar` — таймер
работает под ним, потому что SSH-ключ к `root@arch0X` лежит в `/home/amar/.ssh/`
(у root на arch-b ключей нет вообще).

Оригиналы всех изменённых системных файлов сохранены рядом с суффиксом
`.bak-preclaude`.

## Важные детали реализации

**`honor_labels: true` в job `arch-b`** — обязателен. С одного эндпоинта
`localhost:9100` приходят и метрики самого arch-b, и backup-метрики, описывающие
*другие* хосты и несущие собственную метку `host=`. Без `honor_labels` Prometheus
счёл бы её конфликтующей с target-меткой и переименовал в `exported_host`, сломав
все запросы.

**Хост определяется по SSH-алиасу, а не по `hostname` с той стороны.** arch04 и
arch05 — клоны шаблона VM и представляются как «arch03». Доверять их
самоидентификации нельзя.

**Недоступный хост получает только `rclone_backup_collector_up 0`** и ни одной
другой метрики — устаревшие значения никогда не выдаются за свежие. Возраст данных
считается в PromQL: `time() - rclone_backup_last_success_timestamp_seconds`.

**Запись .prom атомарна** (`os.replace`) — иначе node_exporter может прочитать файл
на середине записи.

## Обновление Grafana — вручную

`apt.grafana.com` отдаёт **403** на IP arch-b (геоблокировка CDN Fastly), поэтому
Grafana поставлена разово из `.deb`, привезённого через `ovh`, а APT-репозиторий
не подключён. **Автоматических обновлений безопасности у Grafana нет.**
Обновление выполняется так (с `ovh`, которому репозиторий доступен):

```bash
# на ovh: узнать актуальную версию и SHA256
curl -sS https://apt.grafana.com/dists/stable/main/binary-amd64/Packages.gz | gunzip \
  | grep -A15 '^Package: grafana$' | grep -E '^(Version|Filename|SHA256):'
# скачать, СВЕРИТЬ СУММУ, привезти и поставить
curl -sSL -o grafana.deb https://apt.grafana.com/<Filename>
sha256sum grafana.deb            # обязательно сверить с SHA256 из индекса
scp grafana.deb arch-b:/tmp/ && ssh arch-b 'sudo apt-get install -y /tmp/grafana.deb'
```

## Что ещё не сделано

* **archminio01/02** не подключены. Нужен node_exporter, но есть блокеры: на
  archminio01 (FreeBSD 14.2) сломан pkg-репозиторий
  (`repository FreeBSD contains packages for wrong OS version`), на archminio02
  (AlmaLinux 9.5) пакета нет в подключённых репозиториях. Их бэкап-скрипты к тому же
  запускаются вручную и **не отрабатывали с 2026-04-26**.
* **Алертинга нет.** Следующий логичный шаг — Alertmanager на
  `time() - rclone_backup_last_success_timestamp_seconds`,
  `rclone_backup_last_run_errors > 0` и `rclone_backup_collector_up == 0`.
* **Пароль admin в Grafana — дефолтный.** Сменить при первом входе.
* **Сборщик ходит под полным root-SSH** на arch0X. Ограничить его до
  `command="/usr/local/bin/scripts/backup_status.sh --print"` в `authorized_keys`
  (как сделано для `monitor_ed25519` в старом дашборде) — правильный следующий шаг.
