# Описание скрипта rclone_backup_users_groups.py

Этот Python-скрипт выполняет резервное копирование данных из директорий Ceph FS (`/ceph/data/users/`, `/ceph/data/groups/`) на локальную файловую систему (`/backup/main/ceph/...`) с использованием `rclone`. Он поддерживает опциональный файл исключений, параллельную обработку, логирование, блокировку, проверку Ceph и валидацию.

## 1. Назначение скрипта
- **Основная цель**: Синхронизация данных из `/ceph/data/users/` и `/ceph/data/groups/` в `/backup/main/ceph/data/users/` и `/backup/main/ceph/data/groups/`.
- **Функциональность**: Аналогична первому скрипту, с акцентом на другие директории.

## 2. Конфигурация скрипта
- **BACKUP_USER**: `backup_user`.
- **LOGDIR**: `/var/log/backup`.
- **LOCKFILE**: `/var/lock/backup.lock`.
- **EXCLUDE_FILE**: `/usr/local/bin/scripts/exclude-file.txt` (опциональный).
- **DELETE_BACKUP**: `/backup/deleted`.
- **MAIN_BACKUP**: `/backup/main`.
- **SOURCEDIRS**: `/ceph/data/users/`, `/ceph/data/groups/`.
- **RCLONE_TRANSFERS**: 30.
- **RCLONE_CHECKERS**: 8.
- **RCLONE_RETRIES**: 5.

## 3. Инициализация и логирование
- Как в первом скрипте.

## 4. Проверка конфигурации rclone
- Как в первом скрипте.

## 5. Проверка файла исключений
- Как в первом скрипте (опциональный).

## 6. Механизм блокировки
- Как в первом скрипте.

## 7. Проверка Ceph FS
- Как в первом скрипте, с проверкой `/ceph/data/users/` и `/ceph/data/groups/`.

## 8. Очистка устаревших данных
- Как в первом скрипте.

## 9. Резервное копирование директорий
- Как в первом скрипте, для `/ceph/data/users/` и `/ceph/data/groups/`.

## 10. Параллельная обработка
- Как в первом скрипте, с двумя директориями.

## 11. Основной поток выполнения
- Как в первом скрипте.

## 12. Обработка ошибок
- Как в первом скрипте.

## 13. Логирование и отладка
- Как в первом скрипте.

## 14. Зависимости
- Как в первом скрипте.

## 15. Ограничения и особенности
- Как в первом скрипте, с акцентом на `/ceph/data/users/` и `/ceph/data/groups/`.

## 16. Пример работы
1. Запуск: `python3 /usr/local/bin/rclone_backup_users_groups.py`.
2. Лог: `/var/log/backup/backup_2025-05-23_17-46.log`.
3. Проверяется Ceph, синхронизируются директории, валидируются.

## 17. Рекомендации по использованию
- **Права**:
  ```bash
  chmod 755 /usr/local/bin/rclone_backup_users_groups.py
  ```
- **Тестирование**:
  ```bash
  python3 /usr/local/bin/rclone_backup_users_groups.py
  ```
- **Остальное**: Как в первом скрипте.