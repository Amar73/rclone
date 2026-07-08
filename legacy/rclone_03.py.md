Описание скрипта rclone_backup_idream.py
Этот Python-скрипт выполняет резервное копирование данных из двух директорий Ceph FS (/ceph/data/exp/idream/data/, /ceph/data/exp/idream/data3/) на локальную файловую систему (/backup/main/ceph/...) с использованием rclone. Он поддерживает опциональный файл исключений, параллельную обработку, логирование, блокировку, проверку Ceph и валидацию бэкапов. Ниже приведено подробное описание, разбитое на пункты.
1. Назначение скрипта

Основная цель: Синхронизация данных из директорий /ceph/data/exp/idream/data/ и /ceph/data/exp/idream/data3/ в /backup/main/ceph/data/exp/idream/data/ и /backup/main/ceph/data/exp/idream/data3/.
Функциональность:
Выполнение rclone sync для копирования новых/изменённых файлов.
Перемещение удалённых файлов в /backup/deleted/YYYY-MM-DD.
Очистка данных старше 30 дней из /backup/deleted.
Проверка монтирования Ceph FS, прав доступа и состояния кластера через SSH.
Частичная валидация бэкапов (сравнение количества файлов).
Параллельная обработка директорий (до 4 потоков).
Логирование операций в /var/log/backup/backup_YYYY-MM-DD_HH-MM.log.
Блокировка для предотвращения одновременного запуска.
Опциональное использование файла исключений (/usr/local/bin/scripts/exclude-file.txt).



2. Конфигурация скрипта

BACKUP_USER: Имя пользователя для проверки прав (backup_user).
LOGDIR: Директория логов (/var/log/backup).
LOCKFILE: Файл блокировки (/var/lock/backup.lock).
EXCLUDE_FILE: Путь к файлу исключений (/usr/local/bin/scripts/exclude-file.txt).
DELETE_BACKUP: Директория для удалённых файлов (/backup/deleted).
MAIN_BACKUP: Целевая директория бэкапов (/backup/main).
SOURCEDIRS: Список исходных директорий (/ceph/data/exp/idream/data/, /ceph/data/exp/idream/data3/).
RCLONE_TRANSFERS: Количество параллельных передач (30).
RCLONE_CHECKERS: Количество параллельных проверок (8).
RCLONE_RETRIES: Количество повторных попыток (5).

3. Инициализация и логирование

Лог-файл: Создаётся с временной меткой, например, /var/log/backup/backup_2025-05-23_17-46.log.
Директория логов: Создаётся автоматически, если отсутствует.
Ротация логов:
Удаление файлов старше 30 дней.
Проверка: не более 100 логов, иначе скрипт завершается.


Формат логов: %(asctime)s [%(levelname)s] %(message)s, вывод в файл и консоль.
Уровни логов: INFO (события), WARNING (некритичные проблемы), ERROR (ошибки), DEBUG (детали).

4. Проверка конфигурации rclone

RCLONE_CONFIG: Извлекается путь к конфигурации через rclone config file.
Обработка:
Если файл не найден, продолжается без --config (подходит для локальных операций).
Если найден, путь логируется и используется в командах rclone.


Экспорт: Параметры RCLONE_TRANSFERS, RCLONE_CHECKERS, RCLONE_RETRIES задаются из переменных окружения или конфигурации.

5. Проверка файла исключений

EXCLUDE_FILE:
Проверяется существование и читаемость /usr/local/bin/scripts/exclude-file.txt.
Если файл отсутствует, логируется предупреждение, и --exclude-from не используется (use_exclude_file=False).
Если файл пустой, выдаётся предупреждение.
Содержимое файла логируется.


Повторная проверка: В функции backup_dir для потоков, если use_exclude_file=True.

6. Механизм блокировки

LOCKFILE: Используется fcntl.flock для /var/lock/backup.lock.
Логика:
Если блокировка не удалась, скрипт завершается с ошибкой.
Блокировка снимается при завершении или по сигналам (INT, TERM).
Файл удаляется после выполнения.



7. Проверка Ceph FS

Функция check_ceph_access:
Проверяет наличие /ceph в /etc/fstab.
Проверяет монтирование /ceph через mountpoint -q.
При необходимости выполняет до 5 попыток монтирования (mount /ceph) с интервалом 30 секунд.
Проверяет права доступа к /ceph через ls.
Проверяет существование исходных директорий.
Проверяет состояние Ceph через SSH: ssh cephsvc05 "podman exec ceph-mon-cephsvc05 ceph status".


Обработка ошибок:
Если SSH недоступен, проверка пропускается с предупреждением.
Любая ошибка возвращает False, завершая скрипт.



8. Очистка устаревших данных

Функция cleanup_old_backups:
Удаляет данные старше 30 дней из /backup/deleted через rclone purge --min-age 30d.
Проверяет доступность директории.
Выполняется с тремя попытками (retry_command, задержка 10 секунд).


Логирование: Успех или ошибки логируются; при ошибке продолжается с предупреждением.

9. Резервное копирование директорий

Функция backup_dir:
Принимает директорию (например, /ceph/data/exp/idream/data/).
Создаёт целевую директорию (/backup/main/ceph/data/exp/idream/data/).
Проверяет доступ к исходной директории и файлу исключений (если используется).


Команда rclone sync:
Параметры:
--progress, --links, --fast-list, --create-empty-src-dirs, --checksum.
--transfers=30, --checkers=8, --retries=5, --retries-sleep=10s.
--update, --backup-dir=/backup/deleted/YYYY-MM-DD.
--log-file, --log-level=INFO.
--exclude-from (если use_exclude_file=True).
--config (если rclone_config задан).


Выполняется с тремя попытками (задержка 15 секунд).


Валидация: Проверяется количество файлов через rclone lsf --files-only.

10. Параллельная обработка

Функция perform_backup:
Создаёт /backup/main и /backup/deleted.
Вызывает check_ceph_access и cleanup_old_backups.
Использует ThreadPoolExecutor (максимум 4 потока) для параллельного вызова backup_dir.


Логика: Все потоки должны завершиться успешно, иначе возвращается ошибка.

11. Основной поток выполнения

Функция main:
Выполняет log_rotation, get_rclone_config, check_exclude_file.
Устанавливает блокировку.
Логирует: пользователя, права на /ceph и /backup, версию rclone, конфигурацию, параметры.
Вызывает perform_backup.
При успехе логирует завершение, при ошибке завершает с кодом 1.



12. Обработка ошибок

Повторные попытки: retry_command выполняет команды rclone до трёх раз.
Проверки: Права, директории, Ceph, файл исключений.
Некритичные ошибки: Отсутствие файла исключений или проблемы с очисткой логируются как WARNING.
Критичные ошибки: Завершают скрипт с кодом 1.

13. Логирование и отладка

Лог-файл: Подробные записи операций, включая команды rclone и их ошибки.
DEBUG: Полные команды rclone и содержимое файла исключений.
Консоль: Вывод для мониторинга в реальном времени.

14. Зависимости

Python: 3.6+.
Модули: subprocess, logging, os, pathlib, concurrent.futures, fcntl, shutil, time, datetime, re.
Утилиты: rclone (1.62.2+), mountpoint, ls, ssh (опционально), podman (для Ceph).
Система: Доступ к /ceph, /backup, права для backup_user.

15. Ограничения и особенности

Локальные операции: Работает без RCLONE_CONFIG для локальных путей.
Параллелизм: Ограничен 4 потоками, оптимально для двух директорий.
Валидация: Только количество файлов, а не их содержимое.
SSH: Проверка Ceph некритична, пропускается при отсутствии ssh.

16. Пример работы

Запуск: python3 /usr/local/bin/rclone_backup_idream.py.
Создаётся лог: /var/log/backup/backup_2025-05-23_17-46.log.
Проверяется блокировка, Ceph, файл исключений.
Очищается /backup/deleted (данные старше 30 дней).
Синхронизируются директории в /backup/main/ceph/....
Проверяется количество файлов.
Логируется результат.

17. Рекомендации по использованию

Права: Запуск от root, проверка доступа:ls -ld /ceph /backup /usr/local/bin/scripts/exclude-file.txt
chmod 755 /usr/local/bin/rclone_backup_idream.py


Файл исключений:echo -e "subdir1/**\nsubdir2/**" > /usr/local/bin/scripts/exclude-file.txt
chmod 644 /usr/local/bin/scripts/exclude-file.txt


Логи: Проверяйте /var/log/backup для диагностики.
SSH: Настройте беспарольный доступ:ssh-copy-id cephsvc05


Тестирование:python3 /usr/local/bin/rclone_backup_idream.py
tail -f /var/log/backup/backup_*.log