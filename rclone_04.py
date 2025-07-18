import subprocess
import logging
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
import concurrent.futures
import fcntl
import shutil
import re

# Конфигурация
BACKUP_USER = "backup_user"
LOGDIR = Path("/var/log/backup")
LOCKFILE = Path("/var/lock/backup.lock")
EXCLUDE_FILE = Path("/usr/local/bin/scripts/exclude-file.txt")
DELETE_BACKUP = Path("/backup/deleted")
MAIN_BACKUP = Path("/backup/main")
SOURCEDIRS = ["/ceph/data/exp/idream/"]
RCLONE_TRANSFERS = int(os.environ.get("RCLONE_TRANSFERS", 30))
RCLONE_CHECKERS = int(os.environ.get("RCLONE_CHECKERS", 8))
RCLONE_RETRIES = int(os.environ.get("RCLONE_RETRIES", 5))

# Инициализация логирования
TIMESTAMP = datetime.now().strftime("%Y-%m-%d_%H-%M")
LOGFILE = LOGDIR / f"backup_{TIMESTAMP}.log"
LOGDIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOGFILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger()

def log_rotation():
    """Ротация логов: удаление файлов старше 30 дней, проверка количества."""
    logger.info(f"Проверка ротации логов в {LOGDIR}")
    thirty_days_ago = datetime.now() - timedelta(days=30)
    log_files = [f for f in LOGDIR.glob("backup_*.log") if f.is_file()]
    
    for log_file in log_files:
        mtime = datetime.fromtimestamp(log_file.stat().st_mtime)
        if mtime < thirty_days_ago:
            log_file.unlink()
            logger.info(f"Удалён старый лог: {log_file}")
    
    if len(log_files) > 100:
        logger.error(f"Слишком много лог-файлов в {LOGDIR}: {len(log_files)}")
        sys.exit(1)

def get_rclone_config():
    """Получение пути к конфигурации rclone."""
    logger.info("Проверка конфигурации rclone")
    try:
        result = subprocess.run(["rclone", "config", "file"], capture_output=True, text=True, check=True)
        config_path = result.stdout.splitlines()[-1].strip()
        if not config_path or not Path(config_path).is_file():
            logger.warning("Конфигурационный файл rclone не найден, продолжаем без --config")
            return None
        logger.info(f"Используется конфигурационный файл rclone: {config_path}")
        return config_path
    except subprocess.CalledProcessError:
        logger.warning("Конфигурационный файл rclone не найден, продолжаем без --config")
        return None

def check_exclude_file():
    """Проверка файла исключений (обязательный)."""
    logger.info(f"Проверка файла исключений: {EXCLUDE_FILE}")
    if not EXCLUDE_FILE.is_file():
        logger.error(f"Файл исключений {EXCLUDE_FILE} не найден")
        sys.exit(1)
    if not os.access(EXCLUDE_FILE, os.R_OK):
        logger.error(f"Файл исключений {EXCLUDE_FILE} не доступен для чтения")
        sys.exit(1)
    if EXCLUDE_FILE.stat().st_size == 0:
        logger.warning(f"Файл исключений {EXCLUDE_FILE} пустой")
    with EXCLUDE_FILE.open() as f:
        content = f.read().strip() or "Не удалось прочитать"
        logger.info(f"Содержимое exclude-файла: {content}")
    return True

def retry_command(cmd, retries=3, delay=10):
    """Повторные попытки выполнения команды."""
    for attempt in range(1, retries + 1):
        logger.info(f"Попытка {attempt}/{retries}: {' '.join(cmd)}")
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            return True
        except subprocess.CalledProcessError as e:
            logger.warning(f"Ошибка выполнения: {' '.join(cmd)} (попытка {attempt}/{retries}): {e.stderr}")
            if attempt < retries:
                time.sleep(delay)
    logger.error(f"Не удалось выполнить команду после {retries} попыток: {' '.join(cmd)}")
    return False

def check_ceph_access():
    """Проверка доступа к Ceph FS."""
    logger.info("Проверка Ceph")
    with open("/etc/fstab") as f:
        if not any("/ceph" in line for line in f if not line.startswith("#")):
            logger.error("/ceph не настроен в fstab")
            return False
    
    try:
        result = subprocess.run(["mountpoint", "-q", "/ceph"], capture_output=True, text=True)
        if result.returncode != 0:
            logger.warning("/ceph не смонтирован. Начинаем попытки монтирования...")
            for attempt in range(1, 6):
                logger.info(f"Попытка монтирования {attempt}/5...")
                subprocess.run(["umount", "-fl", "/ceph"], capture_output=True)
                try:
                    subprocess.run(["mount", "/ceph"], check=True, capture_output=True)
                    logger.info("Успешно смонтировано /ceph")
                    break
                except subprocess.CalledProcessError:
                    logger.error("Неудачная попытка монтирования. Повтор через 30 сек...")
                    time.sleep(30)
            else:
                logger.error("Не удалось смонтировать Ceph после 5 попыток")
                return False
    except subprocess.CalledProcessError:
        logger.error("Ошибка проверки монтирования /ceph")
        return False
    
    try:
        subprocess.run(["ls", "/ceph"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        logger.error(f"Нет прав доступа к /ceph. Проверить права пользователя {BACKUP_USER}")
        return False
    
    for dir in SOURCEDIRS:
        if not Path(dir).is_dir():
            logger.error(f"Директория {dir} недоступна")
            return False
    
    if shutil.which("ssh"):
        try:
            subprocess.run(
                ["ssh", "cephsvc05", "podman exec ceph-mon-cephsvc05 ceph status"],
                check=True, capture_output=True, text=True
            )
            logger.info("Ceph-кластер в порядке")
        except subprocess.CalledProcessError:
            logger.warning("Проблемы с состоянием Ceph-кластера")
    else:
        logger.warning("Команда ssh недоступна, пропускаем проверку состояния Ceph")
    
    return True

def validate_backup(src, dst):
    """Частичная валидация: сравнение количества файлов."""
    logger.info(f"Начата частичная валидация: {src} -> {dst}")
    try:
        src_count = len(subprocess.run(
            ["rclone", "lsf", src, "--files-only"], capture_output=True, text=True, check=True
        ).stdout.splitlines())
        dst_count = len(subprocess.run(
            ["rclone", "lsf", dst, "--files-only"], capture_output=True, text=True, check=True
        ).stdout.splitlines())
        if src_count == dst_count:
            logger.info(f"Валидация успешна: количество файлов совпадает ({src_count})")
            return True
        logger.error(f"Валидация не пройдена: {src_count} файлов в источнике, {dst_count} в бэкапе")
        return False
    except subprocess.CalledProcessError as e:
        logger.error(f"Ошибка валидации: {e.stderr}")
        return False

def cleanup_old_backups(rclone_config):
    """Очистка данных старше 30 дней."""
    logger.info(f"Начата очистка устаревших данных из {DELETE_BACKUP}")
    if not DELETE_BACKUP.is_dir():
        logger.error(f"Директория {DELETE_BACKUP} недоступна")
        return False
    
    cmd = ["rclone", "purge", "--min-age", "30d", str(DELETE_BACKUP), "--log-level=INFO", f"--log-file={LOGFILE}"]
    if rclone_config:
        cmd.extend(["--config", rclone_config])
    
    if not retry_command(cmd):
        logger.error("Ошибка при очистке устаревших данных")
        return False
    
    logger.info("Очистка завершена успешно")
    return True

def backup_dir(dir, rclone_config):
    """Обработка одной директории."""
    logger.info(f"Начат бэкап: {dir}")
    logger.info(f"Повторная проверка exclude-файла в backup_dir: {EXCLUDE_FILE}")
    if not EXCLUDE_FILE.is_file():
        logger.error(f"Файл исключений {EXCLUDE_FILE} не найден в backup_dir")
        return False
    if not os.access(EXCLUDE_FILE, os.R_OK):
        logger.error(f"Файл исключений {EXCLUDE_FILE} не доступен для чтения в backup_dir")
        return False
    with EXCLUDE_FILE.open() as f:
        content = f.read().strip() or "Не удалось прочитать"
        logger.info(f"Содержимое exclude-файла в backup_dir: {content}")
    
    dest_dir = MAIN_BACKUP / "ceph" / Path(dir).relative_to("/ceph")
    dest_dir.parent.mkdir(parents=True, exist_ok=True)
    
    if not subprocess.run(["ls", dir], capture_output=True).returncode == 0:
        logger.error(f"Нет доступа к исходной директории: {dir}")
        return False
    
    rclone_flags = [
        "--progress", "--links", "--fast-list", "--create-empty-src-dirs", "--checksum",
        f"--transfers={RCLONE_TRANSFERS}", f"--checkers={RCLONE_CHECKERS}", f"--retries={RCLONE_RETRIES}",
        "--retries-sleep=10s", "--update", f"--backup-dir={DELETE_BACKUP}/{datetime.now().strftime('%Y-%m-%d')}",
        f"--log-file={LOGFILE}", "--log-level=INFO", f"--exclude-from={EXCLUDE_FILE}"
    ]
    if rclone_config:
        rclone_flags.extend(["--config", rclone_config])
    
    cmd = ["rclone", "sync"] + rclone_flags + [dir, str(dest_dir)]
    logger.debug(f"Выполняемая команда: {' '.join(cmd)}")
    
    if not retry_command(cmd, retries=3, delay=15):
        logger.error(f"Бэкап {dir} завершился ошибкой")
        return False
    
    if not validate_backup(dir, str(dest_dir)):
        return False
    
    logger.info(f"Бэкап {dir} успешно завершен")
    return True

def perform_backup(rclone_config):
    """Основная функция бэкапа."""
    MAIN_BACKUP.mkdir(parents=True, exist_ok=True)
    DELETE_BACKUP.mkdir(parents=True, exist_ok=True)
    
    if not check_ceph_access():
        return False
    
    if not cleanup_old_backups(rclone_config):
        logger.warning("Проблемы с очисткой, но продолжаем...")
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = [executor.submit(backup_dir, dir, rclone_config) for dir in SOURCEDIRS]
        results = concurrent.futures.wait(futures)
        if not all(f.result() for f in results.done):
            return False
    
    return True

def main():
    """Основной поток."""
    log_rotation()
    rclone_config = get_rclone_config()
    check_exclude_file()
    
    with open(LOCKFILE, "w") as lock_fd:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except IOError:
            logger.error("Скрипт уже запущен. Выход.")
            sys.exit(1)
        
        logger.info("***** Начат процесс резервного копирования *****")
        logger.info(f"Запуск от пользователя: {os.getlogin()}")
        logger.info(f"Права на /ceph: {subprocess.run(['ls', '-ld', '/ceph'], capture_output=True, text=True).stdout.strip()}")
        logger.info(f"Права на /backup: {subprocess.run(['ls', '-ld', '/backup'], capture_output=True, text=True).stdout.strip()}")
        logger.info(f"Версия rclone: {subprocess.run(['rclone', '--version'], capture_output=True, text=True).stdout.splitlines()[0]}")
        logger.info(f"Конфиг rclone: {rclone_config or 'не указан'}")
        logger.info(f"Параметры: transfers={RCLONE_TRANSFERS} checkers={RCLONE_CHECKERS} retries={RCLONE_RETRIES}")
        
        if perform_backup(rclone_config):
            logger.info("Все бэкапы успешно завершены")
        else:
            logger.error("Бэкап завершился с ошибками")
            sys.exit(1)
        
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    
    LOCKFILE.unlink(missing_ok=True)

if __name__ == "__main__":
    main()