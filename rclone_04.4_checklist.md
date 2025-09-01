# Проверочный список и рекомендации по использованию backup_ceph_improved.sh

## 🔍 Предварительная проверка скрипта

### 1. Проверка с помощью shellcheck
```bash
# Установка shellcheck (если не установлен)
sudo apt-get install shellcheck  # Ubuntu/Debian
sudo yum install ShellCheck      # CentOS/RHEL
sudo dnf install ShellCheck      # Fedora

# Проверка скрипта
shellcheck backup_ceph_improved.sh
```

### 2. Проверка синтаксиса bash
```bash
# Проверка синтаксиса без выполнения
bash -n backup_ceph_improved.sh

# Проверка с включенным verbose режимом
bash -x backup_ceph_improved.sh --help 2>&1 | head -20
```

### 3. Проверка зависимостей
```bash
# Проверка наличия необходимых команд
command -v rclone || echo "ТРЕБУЕТСЯ: установить rclone"
command -v jq || echo "РЕКОМЕНДУЕТСЯ: установить jq для JSON отчетов"
command -v flock || echo "ТРЕБУЕТСЯ: установить util-linux"

# Проверка версии bash
echo "Версия bash: $BASH_VERSION"
[[ ${BASH_VERSINFO[0]} -ge 4 ]] && echo "✓ Версия bash подходит" || echo "✗ Требуется bash 4.0+"

# Проверка версии rclone  
rclone --version | head -1
```

## 🛠️ Настройка окружения

### 1. Создание пользователя для резервного копирования
```bash
# Создание отдельного пользователя (рекомендуется)
sudo useradd -r -s /bin/bash -d /var/lib/backup -m backup_user
sudo usermod -aG ceph backup_user  # Добавление в группу ceph если существует

# Настройка sudo доступа для монтирования (если необходимо)
echo "backup_user ALL=(root) NOPASSWD: /bin/mount /ceph, /bin/umount /ceph" | sudo tee /etc/sudoers.d/backup_user
```

### 2. Создание директорий
```bash
# Создание необходимых директорий
sudo mkdir -p /var/log/backup /backup/{main,deleted} /usr/local/bin/scripts
sudo chown backup_user:backup_user /var/log/backup /backup/{main,deleted}
sudo chmod 750 /var/log/backup /backup/{main,deleted}
```

### 3. Создание файла исключений
```bash
# Пример файла исключений /usr/local/bin/scripts/exclude-file.txt
cat > /usr/local/bin/scripts/exclude-file.txt << 'EOF'
# Системные файлы и директории
**/.snapshots/
**/.tmp/
**/lost+found/
**/.Trash-*/

# Временные файлы
**/*.tmp
**/*.temp
**/.DS_Store
**/Thumbs.db

# Кэш и логи
**/cache/
**/logs/
**/*.log

# Большие медиа файлы (опционально)
# **/*.iso
# **/*.dmg
# **/*.ova

# Директории разработки
**/node_modules/
**/.git/
**/__pycache__/
**/.venv/
EOF

sudo chown root:backup_user /usr/local/bin/scripts/exclude-file.txt
sudo chmod 640 /usr/local/bin/scripts/exclude-file.txt
```

### 4. Настройка rclone
```bash
# Запуск конфигурации rclone от имени backup_user
sudo -u backup_user rclone config

# Или копирование существующей конфигурации
sudo cp ~/.config/rclone/rclone.conf /home/backup_user/.config/rclone/
sudo chown backup_user:backup_user /home/backup_user/.config/rclone/rclone.conf
sudo chmod 600 /home/backup_user/.config/rclone/rclone.conf
```

## 📋 Проверочный список перед первым запуском

### ✅ Обязательные проверки
- [ ] Bash версии 4.0 или новее установлен
- [ ] rclone установлен и настроен
- [ ] Пользователь backup_user создан и имеет необходимые права
- [ ] CephFS смонтирована в /ceph
- [ ] Директории /backup/main и /backup/deleted созданы и доступны для записи
- [ ] Файл исключений создан и корректно настроен
- [ ] Скрипт прошел проверку shellcheck без критичных ошибок

### ⚠️ Рекомендуемые проверки
- [ ] jq установлен для детальных JSON отчетов
- [ ] Настроен логротейт для /var/log/backup
- [ ] Протестирован режим DRY_RUN
- [ ] Настроено мониторинг выполнения скрипта
- [ ] Создан cron job с корректными правами

## 🚀 Примеры использования

### 1. Первый запуск в режиме тестирования
```bash
# Запуск в режиме DRY_RUN для проверки
sudo -u backup_user DRY_RUN=true ./backup_ceph_improved.sh

# Проверка логов
tail -f /var/log/backup/backup_$(date +%Y-%m-%d)*.log
```

### 2. Настройка переменных окружения
```bash
# Создание файла конфигурации
cat > /etc/default/backup_ceph << 'EOF'
# Основные настройки
SOURCEDIRS="/ceph/data/exp/idream/ /ceph/data/projects/"
BACKUP_USER="backup_user"
LOGDIR="/var/log/backup"
MAIN_BACKUP="/backup/main"
DELETE_BACKUP="/backup/deleted"

# Настройки производительности rclone
RCLONE_TRANSFERS=20
RCLONE_CHECKERS=8
RCLONE_RETRIES=3
PARALLEL=2

# Настройки хранения
LOG_RETENTION_DAYS=30
DELETE_RETENTION_DAYS=30
MAX_LOGFILES=50
EOF

# Использование в скрипте
source /etc/default/backup_ceph && ./backup_ceph_improved.sh
```

### 3. Запуск через cron
```bash
# Добавление в crontab для backup_user
sudo -u backup_user crontab -e

# Пример: запуск каждую ночь в 2:00
0 2 * * * /usr/local/bin/backup_ceph_improved.sh >> /var/log/backup/cron.log 2>&1

# Пример: запуск каждые 6 часов с источником конфигурации
0 */6 * * * source /etc/default/backup_ceph && /usr/local/bin/backup_ceph_improved.sh
```

### 4. Запуск с дополнительными параметрами
```bash
# Запуск с увеличенным количеством параллельных процессов
RCLONE_TRANSFERS=50 PARALLEL=8 ./backup_ceph_improved.sh

# Запуск только для определенных директорий
SOURCEDIRS="/ceph/data/critical/" ./backup_ceph_improved.sh

# Запуск с отладочной информацией
DEBUG=true ./backup_ceph_improved.sh
```

## 🔍 Мониторинг и устранение неполадок

### 1. Проверка статуса выполнения
```bash
# Проверка активных процессов резервного копирования
ps aux | grep -E "(backup_ceph|rclone)" | grep -v grep

# Проверка файла блокировки
ls -la /var/lock/backup.lock

# Проверка последних логов
tail -100 /var/log/backup/backup_$(date +%Y-%m-%d)*.log
```

### 2. Анализ JSON отчетов
```bash
# Просмотр последнего JSON отчета
latest_json=$(ls -t /var/log/backup/backup_*summary.json | head -1)
jq '.' "$latest_json"

# Извлечение статистики
jq '.sources[] | {source, destination_objects, destination_size_human}' "$latest_json"

# Проверка результата выполнения
jq -r '.result' "$latest_json"
```

### 3. Анализ ошибок rclone
```bash
# Поиск ошибок в JSON логах rclone
latest_rclone_log=$(ls -t /var/log/backup/backup_*.jsonl | head -1)
grep '"level":"error"' "$latest_rclone_log" | jq '.'

# Подсчет статистики передач
grep '"stats"' "$latest_rclone_log" | tail -1 | jq '.stats'
```

## 🛡️ Безопасность и рекомендации

### 1. Права доступа к файлам
```bash
# Проверка прав доступа к критичным файлам
ls -la /usr/local/bin/backup_ceph_improved.sh
ls -la /usr/local/bin/scripts/exclude-file.txt
ls -ld /var/log/backup /backup/main /backup/deleted

# Установка корректных прав (если необходимо)
chmod 750 /usr/local/bin/backup_ceph_improved.sh
chmod 640 /usr/local/bin/scripts/exclude-file.txt
```

### 2. Защита конфигурации rclone
```bash
# Проверка прав на конфигурацию rclone
ls -la ~backup_user/.config/rclone/rclone.conf

# Шифрование конфигурации rclone (рекомендуется)
sudo -u backup_user rclone config # выбрать s) Set configuration password
```

### 3. Мониторинг дискового пространства
```bash
# Проверка свободного места
df -h /backup

# Настройка предупреждений о заполнении диска
echo '#!/bin/bash
USAGE=$(df /backup | tail -1 | awk "{print \$5}" | sed "s/%//")
if [ $USAGE -gt 80 ]; then
    echo "WARNING: /backup is ${USAGE}% full" | logger -t backup_monitor
fi' > /usr/local/bin/check_backup_space.sh

chmod +x /usr/local/bin/check_backup_space.sh

# Добавление в cron для ежедневной проверки
echo "0 8 * * * /usr/local/bin/check_backup_space.sh" | sudo -u backup_user crontab -
```

## 🔧 Производительность и оптимизация

### 1. Настройка производительности
```bash
# Для быстрых локальных сетей
export RCLONE_TRANSFERS=50
export RCLONE_CHECKERS=16
export RCLONE_BUFFER_SIZE="32M"

# Для медленных сетей или ограниченных ресурсов
export RCLONE_TRANSFERS=10
export RCLONE_CHECKERS=4
export RCLONE_BUFFER_SIZE="8M"
```

### 2. Мониторинг производительности
```bash
# Создание скрипта мониторинга производительности
cat > /usr/local/bin/monitor_backup.sh << 'EOF'
#!/bin/bash
while true; do
    echo "=== $(date) ==="
    echo "Load Average: $(cat /proc/loadavg)"
    echo "Memory Usage: $(free -h | grep Mem:)"
    echo "Disk I/O: $(iostat -x 1 1 | tail -1)"
    echo "Network: $(ss -s)"
    echo "rclone processes: $(pgrep -c rclone)"
    echo ""
    sleep 30
done
EOF

chmod +x /usr/local/bin/monitor_backup.sh
```

## 📝 Список изменений и улучшений

### Основные улучшения в версии 2.0:
1. **Безопасность**: Проверка версии bash, валидация путей, безопасная обработка переменных
2. **Современность**: Использование современных конструкций bash 4.0+, readonly переменные
3. **Логирование**: Многоуровневое логирование с цветовым кодированием
4. **Ошибки**: Улучшенная обработка ошибок и кодов возврата rclone
5. **Производительность**: Оптимизация параллельного выполнения
6. **Мониторинг**: Детальные JSON и текстовые отчеты
7. **Совместимость**: Резервные методы для систем без jq
8. **Документация**: Подробные комментарии на русском языке

### Исправленные проблемы:
- Устранена уязвимость с обработкой пробелов в именах файлов
- Исправлена обработка PIPESTATUS для корректного получения кодов возврата
- Добавлена валидация всех входных параметров
- Улучшена обработка сигналов и очистка ресурсов
- Исправлены проблемы с экспортом переменных для подпроцессов

## 🆘 Устранение распространенных проблем

### Проблема: "No such file or directory" при монтировании
```bash
# Проверка записи в fstab
grep ceph /etc/fstab

# Проверка доступности Ceph серверов
ping cephsvc05

# Проверка ключей аутентификации
ls -la /etc/ceph/
```

### Проблема: "Permission denied" при записи в /backup
```bash
# Проверка владельца и прав
ls -ld /backup /backup/main /backup/deleted

# Исправление прав
sudo chown -R backup_user:backup_user /backup
sudo chmod -R 755 /backup
```

### Проблема: Высокая нагрузка на систему
```bash
# Уменьшение количества параллельных процессов
export RCLONE_TRANSFERS=10
export RCLONE_CHECKERS=4
export PARALLEL=2

# Добавление ограничений пропускной способности
export RCLONE_BWLIMIT="50M"
```

---

**Рекомендация**: Перед внедрением в продуктивную среду обязательно протестируйте скрипт в режиме DRY_RUN и убедитесь, что все зависимости установлены и настроены корректно.