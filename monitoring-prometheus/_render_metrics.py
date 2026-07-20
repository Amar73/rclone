#!/usr/bin/env python3
"""Читает разметку '---HOST:x---'/JSON/'---END:x---' со stdin (её формирует
collect_backup_metrics.sh) и пишет метрики в формате Prometheus text exposition
в файл, который отдаёт textfile-коллектор node_exporter.

Принципы:
  * Хост, который не удалось опросить, получает rclone_backup_collector_up 0 и
    НЕ получает никаких других метрик — устаревшие значения никогда не выдаются
    за свежие. Возраст данных считается в PromQL как
    time() - rclone_backup_last_success_timestamp_seconds.
  * Запись атомарная (os.replace) — textfile-коллектор требует именно этого,
    иначе node_exporter может прочитать файл на середине записи.
  * HELP/TYPE каждого семейства метрик выводятся ровно один раз, поэтому сэмплы
    группируются по имени метрики, а не по хосту (иначе файл невалиден).
"""
import json
import os
import sys
import time
from datetime import datetime

# name -> (help, type). Порядок задаёт порядок вывода в файле.
METRICS = [
    ("rclone_backup_collector_up",
     "1 если статус бэкапа с хоста успешно получен, 0 если хост не опросился", "gauge"),
    ("rclone_backup_status_generated_timestamp_seconds",
     "Когда сам хост сформировал свой статус (unix time)", "gauge"),
    # Именно last_run, а не last_success: backup_status.sh отдаёт САМЫЙ СВЕЖИЙ
    # summary.json независимо от его result. Успешность смотреть по
    # rclone_backup_last_run_success.
    ("rclone_backup_last_run_timestamp_seconds",
     "Время завершения последнего прогона бэкапа, любого результата (unix time)", "gauge"),
    ("rclone_backup_last_run_success",
     "1 если последний прогон завершился result=success, иначе 0", "gauge"),
    ("rclone_backup_last_run_files_copied",
     "Скопировано файлов за последний прогон", "gauge"),
    ("rclone_backup_last_run_files_deleted",
     "Удалено файлов за последний прогон", "gauge"),
    ("rclone_backup_last_run_errors",
     "Количество ошибок за последний прогон", "gauge"),
    ("rclone_backup_last_run_duration_seconds",
     "Длительность последнего прогона в секундах", "gauge"),
    ("rclone_backup_running",
     "1 если бэкап выполняется прямо сейчас", "gauge"),
    ("rclone_backup_running_percent",
     "Прогресс текущего прогона в процентах", "gauge"),
    ("rclone_backup_running_started_timestamp_seconds",
     "Время старта текущего прогона (unix time)", "gauge"),
    ("rclone_backup_ceph_mounted",
     "1 если CephFS смонтирован", "gauge"),
    ("rclone_backup_ceph_accessible",
     "1 если CephFS отвечает на чтение", "gauge"),
    ("rclone_backup_ceph_last_mds_incident_timestamp_seconds",
     "Время последнего серьёзного инцидента MDS - зависание или потеря сессии (unix time)", "gauge"),
    ("rclone_backup_ceph_last_mds_caps_stale_timestamp_seconds",
     "Время последнего 'caps stale' - раннего признака отвала MDS (unix time)", "gauge"),
    # Ниже - именно gauge, а не counter: значения считаются по кольцевому буферу
    # dmesg и падают до нуля при перезагрузке хоста или переполнении буфера.
    # rate()/increase() по ним применять нельзя.
    ("rclone_backup_ceph_mds_hung_events",
     "Зависаний MDS в пределах текущего буфера dmesg (см. mds_window_start)", "gauge"),
    ("rclone_backup_ceph_mds_eviction_events",
     "Потерь сессии MDS в пределах текущего буфера dmesg (см. mds_window_start)", "gauge"),
    ("rclone_backup_ceph_mds_caps_stale_events",
     "Событий 'caps stale' в пределах текущего буфера dmesg (см. mds_window_start)", "gauge"),
    ("rclone_backup_ceph_mds_window_start_timestamp_seconds",
     "Начало окна, за которое посчитаны счётчики MDS - время старейшей строки dmesg (unix time)", "gauge"),
    ("rclone_backup_disk_used_percent",
     "Заполненность тома /backup в процентах", "gauge"),
    ("rclone_backup_rclone_processes",
     "Количество запущенных процессов rclone", "gauge"),
    # Только archminio01: его скрипт пишет .status.tsv с итогом по каждому бакету.
    ("rclone_backup_buckets_ok",
     "Бакетов, синхронизированных успешно в последнем прогоне", "gauge"),
    ("rclone_backup_buckets_failed",
     "Бакетов, завершившихся с ошибкой в последнем прогоне", "gauge"),
    ("rclone_backup_collector_last_run_timestamp_seconds",
     "Когда сборщик метрик отработал в последний раз (unix time)", "gauge"),
    ("rclone_backup_collector_duration_seconds",
     "Длительность последнего цикла сбора в секундах", "gauge"),
]


def escape_label_value(value):
    """Экранирование значения метки по спецификации Prometheus text format."""
    return (str(value)
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n"))


def to_epoch(value):
    """ISO-8601 -> unix seconds. None/мусор -> None (метрика просто не выводится)."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).timestamp()
    except (ValueError, TypeError):
        return None


def fmt(value):
    """Prometheus не понимает True/False — только числа."""
    if isinstance(value, bool):
        return "1" if value else "0"
    return repr(float(value)) if isinstance(value, float) else str(value)


def parse_arch0x(raw):
    """JSON от backup_status.sh --print."""
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    # backup_status.sh --print отдаёт {"error": ...} если файла статуса нет;
    # такой ответ равносилен неуспеху опроса.
    if isinstance(parsed, dict) and "host" in parsed and "error" not in parsed:
        return parsed
    return None


def parse_keyvalue(raw):
    """Простые key=value строки от archminio-хостов."""
    data = {}
    for line in raw.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            data[key.strip()] = value.strip()
    # reached=1 печатается первой строкой удалённой команды: это отличает
    # "хост опрошен, но логов нет" от "до хоста не достучались".
    return data if data.get("reached") == "1" else None


def parse_stream(lines):
    """Разбирает кадры ---HOST:имя:тип---/---END:имя--- в {host: (type, data|None)}."""
    result = {}
    current_host = None
    current_type = None
    buf = []
    for line in lines:
        if line.startswith("---HOST:") and line.endswith("---"):
            current_host, _, current_type = line[len("---HOST:"):-len("---")].partition(":")
            buf = []
        elif line.startswith("---END:") and line.endswith("---"):
            raw = "\n".join(buf).strip()
            if current_type == "arch0x":
                data = parse_arch0x(raw)
            else:
                data = parse_keyvalue(raw)
            result[current_host] = (current_type, data)
            current_host = None
        elif current_host is not None:
            buf.append(line)
    return result


def collect_samples(hosts, started_at):
    """Строит {metric_name: [(labels_dict, value), ...]}."""
    samples = {name: [] for name, _, _ in METRICS}

    def add(name, host, value):
        if value is not None:
            samples[name].append(({"host": host}, value))

    def add_int(name, host, data, key):
        raw = data.get(key)
        if raw is not None:
            try:
                add(name, host, int(raw))
            except (TypeError, ValueError):
                pass

    for host, (host_type, data) in sorted(hosts.items()):
        if data is None:
            add("rclone_backup_collector_up", host, 0)
            continue
        add("rclone_backup_collector_up", host, 1)

        if host_type != "arch0x":
            # archminio: полноценного статуса пока нет — их скрипты запускаются
            # вручную и подлежат переработке. Снимаем то, что есть: время
            # последней записи в лог и итог по бакетам.
            add_int("rclone_backup_last_run_timestamp_seconds", host, data, "last_run_epoch")
            add_int("rclone_backup_buckets_ok", host, data, "buckets_ok")
            add_int("rclone_backup_buckets_failed", host, data, "buckets_failed")
            continue

        add("rclone_backup_status_generated_timestamp_seconds", host,
            to_epoch(data.get("generated_at")))

        last = data.get("last_success") or {}
        if last and "error" not in last:
            add("rclone_backup_last_run_timestamp_seconds", host,
                to_epoch(last.get("finished_at")))
            add("rclone_backup_last_run_success", host,
                1 if last.get("result") == "success" else 0)
            add("rclone_backup_last_run_files_copied", host, last.get("files_copied"))
            add("rclone_backup_last_run_files_deleted", host, last.get("files_deleted"))
            add("rclone_backup_last_run_errors", host, last.get("errors"))
            add("rclone_backup_last_run_duration_seconds", host, last.get("duration_sec"))

        running = data.get("running_now") or {}
        add("rclone_backup_running", host, running.get("active"))
        if running.get("active"):
            add("rclone_backup_running_percent", host, running.get("percent"))
            add("rclone_backup_running_started_timestamp_seconds", host,
                to_epoch(running.get("started_at")))

        ceph = data.get("ceph") or {}
        add("rclone_backup_ceph_mounted", host, ceph.get("mounted"))
        add("rclone_backup_ceph_accessible", host, ceph.get("accessible"))
        add("rclone_backup_ceph_last_mds_incident_timestamp_seconds", host,
            to_epoch(ceph.get("last_mds_incident")))
        add("rclone_backup_ceph_last_mds_caps_stale_timestamp_seconds", host,
            to_epoch(ceph.get("last_mds_caps_stale")))
        add("rclone_backup_ceph_mds_hung_events", host, ceph.get("mds_hung_count"))
        add("rclone_backup_ceph_mds_eviction_events", host, ceph.get("mds_eviction_count"))
        add("rclone_backup_ceph_mds_caps_stale_events", host, ceph.get("mds_caps_stale_count"))
        add("rclone_backup_ceph_mds_window_start_timestamp_seconds", host,
            to_epoch(ceph.get("mds_window_start")))

        disk = data.get("disk") or {}
        add("rclone_backup_disk_used_percent", host, disk.get("backup_used_percent"))

        # Остальное из блока system покрывает node_exporter на самих хостах;
        # берём только то, чего у него нет.
        system = data.get("system") or {}
        add("rclone_backup_rclone_processes", host, system.get("rclone_processes"))

    now = time.time()
    samples["rclone_backup_collector_last_run_timestamp_seconds"].append(({}, now))
    samples["rclone_backup_collector_duration_seconds"].append(({}, now - started_at))
    return samples


def render(samples):
    out = []
    for name, help_text, metric_type in METRICS:
        rows = samples.get(name) or []
        if not rows:
            continue
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {metric_type}")
        for labels, value in rows:
            if labels:
                label_str = ",".join(
                    f'{k}="{escape_label_value(v)}"' for k, v in sorted(labels.items())
                )
                out.append(f"{name}{{{label_str}}} {fmt(value)}")
            else:
                out.append(f"{name} {fmt(value)}")
    return "\n".join(out) + "\n"


def atomic_write(path, text):
    """Пишем во временный файл рядом и переименовываем: textfile-коллектор
    иначе может прочитать наполовину записанный файл."""
    tmp_path = path + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(text)
    os.replace(tmp_path, path)


def main():
    out_file = sys.argv[1]
    lines = sys.stdin.read().splitlines()
    try:
        started_at = float(lines[0])
    except (IndexError, ValueError):
        started_at = time.time()
    hosts = parse_stream(lines[1:])
    atomic_write(out_file, render(collect_samples(hosts, started_at)))


if __name__ == "__main__":
    main()
