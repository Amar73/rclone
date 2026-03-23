#!/usr/bin/env bash
# =============================================================================
# install_software.sh — установщик пакетов и конфигураций для Arch Linux
#
# Что делает скрипт:
#   1. Устанавливает пакеты из официальных репозиториев через pacman.
#   2. Устанавливает пакеты из AUR через yay (собирает yay если нужно).
#   3. Разворачивает конфигурационные файлы из каталога-источника в ~/.config/.
#      Перед заменой каждого файла создаётся резервная копия (.bak.TIMESTAMP).
#
# Сборка AUR-пакетов всегда выполняется от непривилегированного пользователя —
# это требование makepkg и базовая мера безопасности.
#
# ИСПОЛЬЗОВАНИЕ:
#   sudo ./install_software.sh [опции]
#
# БЫСТРЫЙ СТАРТ:
#   # Сухой прогон — ничего не меняет, только показывает план:
#   sudo ./install_software.sh --dry-run
#
#   # Полная установка (пакеты + конфиги):
#   sudo ./install_software.sh
#
#   # Только развернуть конфиги, пакеты не трогать:
#   sudo ./install_software.sh --configs-only
#
#   # Только установить пакеты, конфиги не трогать:
#   sudo ./install_software.sh --no-configs
#
#   # Если запускаешь НЕ через sudo (уже root), укажи пользователя явно:
#   sudo ./install_software.sh --aur-user username
#
# UNATTENDED-РЕЖИМ (CI, автоматизация без интерактивного sudo):
#   sudo ./install_software.sh --dry-run --allow-temp-sudo
#   sudo ./install_software.sh --allow-temp-sudo
#
# ОПЦИИ:
#   --dry-run           Только анализ: показать что будет сделано, без изменений.
#                       Внимание: AUR-пакеты могут попасть в UNKNOWN если yay ещё
#                       не установлен — в реальном запуске yay собирается первым.
#   --jobs N            Число параллельных jobs для makepkg/make (по умолч.: nproc).
#   --aur-user USER     Пользователь для сборки AUR. Нужен только если скрипт
#                       запускается напрямую от root, а не через sudo.
#   --allow-temp-sudo   Выдать пользователю временный NOPASSWD на /usr/bin/pacman.
#                       Нужно только в unattended-режиме без интерактивного sudo.
#   --configs-only      Пропустить установку пакетов, только развернуть конфиги.
#   --no-configs        Пропустить развёртывание конфигов, только пакеты.
#   --configs-src DIR   Каталог с конфигами (по умолч.: ./configs рядом со скриптом).
#                       Структура каталога должна зеркалить ~/.config/:
#                         configs/
#                           alacritty/alacritty.toml
#                           dunst/dunstrc
#                           nitrogen/nitrogen.cfg
#                           nitrogen/bg-saved.cfg
#                           rofi/config.rasi
#                           sxhkd/sxhkdrc
#                           rclone/rclone.conf
#   -h, --help          Показать эту справку.
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
#   BUILD_JOBS          Альтернатива --jobs (флаг имеет приоритет).
#   CONFIGS_SRC         Альтернатива --configs-src (флаг имеет приоритет).
#
# ТРЕБОВАНИЯ:
#   - Arch Linux с pacman
#   - Запуск от root (через sudo)
#   - Доступ в интернет (для AUR и обновления баз)
#   - git и base-devel (устанавливаются автоматически если отсутствуют)
#
# ТОПОЛОГИЯ ДИСКОВ:
#   /dev/sda1 → /        (корневой раздел, переустанавливается при смене ОС)
#   /dev/sda2 → /boot    (загрузчик)
#   /dev/sdb1 → /home    (домашние каталоги, данные сохраняются между переустановками)
#
#   Конфиги хранятся на /dev/sdb1 вместе с /home — при переустановке системы
#   на /dev/sda данные пользователя и конфиги остаются нетронутыми.
#   Скрипт копирует файлы (не создаёт симлинки), поэтому работает независимо
#   от того, смонтирован ли /home в момент запуска.
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# Константы и значения по умолчанию
# =============================================================================

readonly LOG_FILE="/var/log/install_software.log"
readonly TEMP_SUDOERS_FILE="/etc/sudoers.d/99-temp-aur-installer"

DRY_RUN=false
ALLOW_TEMP_SUDO=false
DEPLOY_CONFIGS=true    # становится false при --no-configs
CONFIGS_ONLY=false     # становится true при --configs-only
# BUILD_JOBS берётся из окружения или вычисляется через nproc.
# Флаг --jobs перекроет это значение при разборе аргументов.
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
AUR_USER_CLI=""
# Источник конфигов: переменная окружения → каталог ./configs рядом со скриптом.
# Флаг --configs-src перекрывает оба варианта.
CONFIGS_SRC="${CONFIGS_SRC:-$(dirname "$(realpath "$0")")/configs}"

# =============================================================================
# Список пакетов из официальных репозиториев
# =============================================================================
# Все пакеты проверяются через `pacman -Si` перед установкой.
# Если пакет не найден — скрипт завершится с ошибкой до начала установки.

PACMAN_PKGS=(
  # X.Org — графический сервер и утилиты
  xorg-server
  xorg-xinit
  xorg-xsetroot
  xorg-xrandr
  xorg-xev
  xorg-xprop

  # Библиотеки X11
  libxcomposite
  libx11
  libxft
  libxinerama
  libxcursor
  libxdamage
  libnotify

  # Шрифты и рендеринг
  freetype2
  fontconfig
  libxkbcommon

  # Системные компоненты
  accountsservice
  polkit-gnome

  # Терминал и оболочка
  alacritty

  # Уведомления и снимки экрана
  dunst
  flameshot

  # WM-утилиты
  numlockx
  sxhkd
  rofi

  # Буфер обмена и автоматизация
  xclip
  xdotool

  # Сеть и DNS
  bind
  iproute2

  # Приложения
  telegram-desktop
  thunderbird
  duf

  rclone
  ncdu
  bluetui
  wiremix
  docker
  lazydocker
  lazygit
  dysk
  s-tui
  mc
  wget
  curl
  mousepad
  git
  btop
  htop
  atop
  bind
  dmidecode
  eza
  firefox
  xdg-utils
  xdg-user-dirs
  openssh
  base-devel
  xf86-video-nouveau
  pipewire
  pipewire-alsa
  pipewire-pulse
  pipewire-jack
  wireplumber
  alsa-utils
  pamixer
  ttf-jetbrains-mono-nerd
  noto-fonts
  noto-fonts-cjk
  noto-fonts-emoji
  ttf-font-awesome
)

# =============================================================================
# Список пакетов из AUR
# =============================================================================
# Проверяются через `yay -Si` (если yay уже есть) или через git ls-remote.
# Пакеты, которые не удалось проверить заранее, попадают в UNKNOWN и всё равно
# передаются в yay — тот выдаст понятную ошибку если пакет не существует.

AUR_PKGS=(
  google-chrome
  yandex-browser
  yandex-disk
  notepadqq
  birdtray
  brave-bin
  nitrogen
)

# =============================================================================
# Карта конфигурационных файлов
# =============================================================================
#
# Формат каждой записи:  "приложение:файл_или_подкаталог"
#
#   "приложение" — имя подкаталога внутри CONFIGS_SRC/ и внутри ~/.config/
#   "файл"       — конкретный файл или подкаталог внутри приложения
#
# Примеры записей:
#   "alacritty:alacritty.toml"
#       CONFIGS_SRC/alacritty/alacritty.toml  →  ~/.config/alacritty/alacritty.toml
#
#   "rofi:themes"
#       CONFIGS_SRC/rofi/themes/  →  ~/.config/rofi/themes/  (рекурсивно)
#
# Чтобы добавить конфиг — добавь строку. Чтобы временно отключить — закомментируй.

CONFIG_FILES=(
  # Терминал Alacritty
  "alacritty:alacritty.toml"

  # Демон уведомлений Dunst
  "dunst:dunstrc"

  # Обои рабочего стола Nitrogen
  "nitrogen:nitrogen.cfg"
  "nitrogen:bg-saved.cfg"

  # Запускалка приложений Rofi
  "rofi:config.rasi"

  # Горячие клавиши sxhkd
  "sxhkd:sxhkdrc"

  # Синхронизация облака rclone
  # ВНИМАНИЕ: rclone.conf содержит токены доступа к облачным сервисам.
  # Файл копируется с правами 600. Не добавляй его в публичные репозитории!
  "rclone:rclone.conf"
)

# Конфиги с чувствительными данными — копируются с правами 600 вместо 644.
# Добавляй сюда файлы с паролями, токенами, ключами API.
SENSITIVE_CONFIGS=(
  "rclone:rclone.conf"
)

# =============================================================================
# Внутренние переменные состояния (не трогать вручную)
# =============================================================================

TMP_DIR=""          # временный каталог для сборки yay; очищается в cleanup()
AUR_USER=""         # итоговый пользователь для AUR (определяется в main)
AUR_HOME=""         # домашний каталог AUR_USER
AUR_CACHE_DIR=""    # каталог кеша сборки AUR (~/.cache/yay-build)
YAY_AVAILABLE=false # флаг: установлен ли yay на момент проверки пакетов

# Массивы результатов классификации пакетов (заполняются функциями split_*)
REPO_INSTALLED=()
REPO_TO_INSTALL=()
REPO_NOT_FOUND=()

AUR_INSTALLED=()
AUR_TO_INSTALL=()
AUR_NOT_FOUND=()
AUR_UNKNOWN=()      # пакеты, статус которых не удалось проверить заранее

# =============================================================================
# Вспомогательные функции вывода
# =============================================================================

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  # Выводим справку из заголовка самого скрипта (блок между --- строками).
  # sed вырезает первую строку shebang и блок комментариев до первой пустой строки.
  sed -n '/^# ={5}/,/^# ={5}/{ s/^# \?//; p }' "$0" | head -n -1
}

# =============================================================================
# Обработчики сигналов и очистка
# =============================================================================

on_error() {
  # Вызывается трапом ERR. Печатает номер строки и код выхода.
  local exit_code=$?
  local line_no="${1:-unknown}"
  echo "[ERROR] Сбой на строке ${line_no}, код выхода: ${exit_code}" >&2
  exit "$exit_code"
}

cleanup() {
  # Вызывается трапом EXIT (при любом завершении — нормальном или по ошибке).
  # Удаляем временный каталог сборки yay.
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi

  # Удаляем временный sudoers-файл.
  # ВАЖНО: cleanup вызывается и при нормальном завершении, поэтому файл
  # гарантированно удаляется даже если скрипт упал в середине.
  if [[ -f "${TEMP_SUDOERS_FILE}" ]]; then
    log "Удаляю временный sudoers-файл: ${TEMP_SUDOERS_FILE}"
    rm -f -- "${TEMP_SUDOERS_FILE}"
  fi
  return 0
}

# Регистрируем обработчики до разбора аргументов, чтобы любая ошибка была поймана.
trap cleanup EXIT
trap 'on_error $LINENO' ERR

# =============================================================================
# Разбор аргументов командной строки
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --allow-temp-sudo)
      ALLOW_TEMP_SUDO=true
      shift
      ;;
    --configs-only)
      CONFIGS_ONLY=true
      shift
      ;;
    --no-configs)
      DEPLOY_CONFIGS=false
      shift
      ;;
    --jobs)
      [[ $# -ge 2 ]] || die "Для --jobs нужно указать число"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--jobs должен быть положительным числом, получено: '$2'"
      BUILD_JOBS="$2"
      shift 2
      ;;
    --aur-user)
      [[ $# -ge 2 ]] || die "Для --aur-user нужно указать имя пользователя"
      AUR_USER_CLI="$2"
      shift 2
      ;;
    --configs-src)
      [[ $# -ge 2 ]] || die "Для --configs-src нужно указать путь к каталогу"
      CONFIGS_SRC="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Неизвестный аргумент: '$1'. Запусти с --help для справки."
      ;;
  esac
done

# --configs-only и --no-configs несовместимы.
if $CONFIGS_ONLY && ! $DEPLOY_CONFIGS; then
  die "--configs-only и --no-configs нельзя использовать одновременно."
fi

# =============================================================================
# Функции выполнения команд
# =============================================================================

# Выполняет команду — или выводит её в dry-run режиме.
run_cmd() {
  if $DRY_RUN; then
    printf '[DRY-RUN] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Выполняет команду от имени AUR_USER.
# Предпочитает sudo (сохраняет окружение через -H), при его отсутствии — su.
# При su явно указываем bash, чтобы не зависеть от login shell пользователя
# и избежать проблем с интерпретацией кавычек в других оболочках.
run_as_user() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -H -u "${AUR_USER}" -- "$@"
  else
    # su: передаём аргументы через массив окружения, не через интерполяцию строки,
    # чтобы пути с пробелами или спецсимволами не сломали команду.
    su - "${AUR_USER}" -s /bin/bash -c "$(printf '%q ' "$@")"
  fi
}

# Выполняет команду от имени AUR_USER — или выводит её в dry-run режиме.
run_as_user_cmd() {
  if $DRY_RUN; then
    printf '[DRY-RUN as %s] ' "${AUR_USER}"
    printf '%q ' "$@"
    printf '\n'
  else
    run_as_user "$@"
  fi
}

# =============================================================================
# Вспомогательные функции
# =============================================================================

# Выводит список пакетов с заголовком.
# Безопасно обрабатывает пустые массивы (совместимо с bash < 4.4 при set -u).
print_list() {
  local title="$1"
  shift

  echo
  echo "==> ${title}"
  # Проверяем аргументы безопасно: "$@" при set -u падает если нет аргументов.
  if [[ $# -eq 0 ]]; then
    echo "  (пусто)"
    return 0
  fi

  local item
  for item in "$@"; do
    echo "  - $item"
  done
}

# Проверяет, установлен ли пакет через pacman.
is_installed() {
  pacman -Qq "$1" >/dev/null 2>&1
}

# Проверяет, существует ли пакет в официальных репозиториях.
repo_exists() {
  pacman -Si "$1" >/dev/null 2>&1
}

# Проверяет существование пакета в AUR.
# Возвращаемые коды:
#   0 — пакет найден
#   1 — пакет точно не существует (yay/git ответили "не найден")
#   2 — проверить не удалось (нет yay и нет git, или сетевая ошибка)
#
# ВАЖНО: код 2 от git ls-remote может означать и сетевую ошибку, и отсутствие
# пакета — мы не можем их различить без парсинга stderr. Поэтому такие пакеты
# помечаются как UNKNOWN и всё равно передаются в yay, который сам разберётся.
aur_exists() {
  local pkg="$1"
  local rc=0

  if $YAY_AVAILABLE; then
    # yay -Si возвращает 1 если пакет не найден, иное — при сетевой ошибке.
    run_as_user yay -Si "$pkg" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi

  if command -v git >/dev/null 2>&1; then
    # git ls-remote возвращает 128 при недоступном репозитории (пакет не существует)
    # и другие ненулевые коды при сетевых проблемах.
    # Нормализуем: 128 → 1 (не найден), всё остальное ненулевое → 2 (неизвестно).
    run_as_user git ls-remote \
      "https://aur.archlinux.org/${pkg}.git" HEAD >/dev/null 2>&1 || rc=$?
    if (( rc == 128 )); then
      return 1   # репозиторий не существует = пакет не найден
    elif (( rc != 0 )); then
      return 2   # сетевая или иная ошибка = статус неизвестен
    fi
    return 0
  fi

  # Ни yay, ни git недоступны — проверить невозможно.
  return 2
}

# Проверяет, что все пакеты из группы реально установлены.
# Используется после установки как финальная верификация.
verify_installed_group() {
  local label="$1"
  shift
  local failed=()
  local pkg

  # Безопасный обход: если массив пуст, цикл просто не выполняется.
  for pkg in "$@"; do
    if ! is_installed "$pkg"; then
      failed+=("$pkg")
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    warn "Следующие пакеты (${label}) не установлены после завершения:"
    printf '  - %s\n' "${failed[@]}"
    return 1
  fi

  log "Верификация (${label}): все пакеты на месте"
  return 0
}

# =============================================================================
# Классификация пакетов
# =============================================================================

# Распределяет PACMAN_PKGS по трём группам:
#   REPO_INSTALLED  — уже установлены
#   REPO_TO_INSTALL — есть в репо, нужно установить
#   REPO_NOT_FOUND  — не найдены ни в одном репозитории (скрипт завершится с ошибкой)
split_repo_packages() {
  REPO_INSTALLED=()
  REPO_TO_INSTALL=()
  REPO_NOT_FOUND=()

  local pkg
  for pkg in "${PACMAN_PKGS[@]}"; do
    if repo_exists "$pkg"; then
      if is_installed "$pkg"; then
        REPO_INSTALLED+=("$pkg")
      else
        REPO_TO_INSTALL+=("$pkg")
      fi
    else
      REPO_NOT_FOUND+=("$pkg")
    fi
  done
}

# Распределяет AUR_PKGS по четырём группам:
#   AUR_INSTALLED  — уже установлены
#   AUR_TO_INSTALL — найдены в AUR, нужно установить
#   AUR_NOT_FOUND  — точно не существуют в AUR (скрипт завершится с ошибкой)
#   AUR_UNKNOWN    — статус неизвестен; будут переданы в yay «на удачу»
split_aur_packages() {
  AUR_INSTALLED=()
  AUR_TO_INSTALL=()
  AUR_NOT_FOUND=()
  AUR_UNKNOWN=()

  local pkg rc
  for pkg in "${AUR_PKGS[@]}"; do
    rc=0
    aur_exists "$pkg" || rc=$?

    case "$rc" in
      0)
        # Пакет найден в AUR.
        if is_installed "$pkg"; then
          AUR_INSTALLED+=("$pkg")
        else
          AUR_TO_INSTALL+=("$pkg")
        fi
        ;;
      1)
        # Пакет точно не существует.
        AUR_NOT_FOUND+=("$pkg")
        ;;
      2|*)
        # Статус неизвестен (нет инструментов для проверки или сетевая ошибка).
        # Если пакет уже установлен — считаем его установленным и не трогаем.
        # Если не установлен — добавляем в UNKNOWN и передадим yay.
        if is_installed "$pkg"; then
          AUR_INSTALLED+=("$pkg")
        else
          AUR_UNKNOWN+=("$pkg")
        fi
        ;;
    esac
  done
}

# =============================================================================
# Управление временными правами sudo
# =============================================================================

# Выдаёт AUR_USER временный NOPASSWD на /usr/bin/pacman.
# Используется в unattended-режиме (CI, скрипты без интерактивного агента).
# В обычном интерактивном сеансе НЕ нужен: yay сам запросит пароль через sudo.
#
# Безопасность:
#   - Файл создаётся через mktemp, валидируется visudo перед установкой.
#   - Удаляется в cleanup() при любом завершении скрипта (trap EXIT).
#   - Права 0440 (read-only для root и группы).
grant_temp_sudo() {
  $DRY_RUN && {
    log "DRY-RUN: создание временного sudoers-файла пропущено"
    return 0
  }

  # Защита: если файл уже существует (остался от прошлого прерванного запуска),
  # удаляем его перед созданием нового.
  if [[ -f "${TEMP_SUDOERS_FILE}" ]]; then
    warn "Найден старый временный sudoers-файл, удаляю: ${TEMP_SUDOERS_FILE}"
    rm -f -- "${TEMP_SUDOERS_FILE}"
  fi

  log "Создаю временные права NOPASSWD для пользователя '${AUR_USER}'"

  # Создаём файл во временном месте для валидации — не сразу в /etc/sudoers.d/.
  local tmp_sudoers
  tmp_sudoers="$(mktemp /tmp/sudoers-validate.XXXXXX)"

  # Пишем содержимое. Heredoc без кавычек вокруг EOF позволяет подстановку переменных.
  cat > "${tmp_sudoers}" <<EOF
# Временный файл, создан install_software.sh. Удаляется автоматически.
${AUR_USER} ALL=(root) NOPASSWD: /usr/bin/pacman
Defaults:${AUR_USER} !requiretty
EOF

  # Валидируем синтаксис перед установкой — сломанный sudoers опасен.
  if ! visudo -cf "${tmp_sudoers}" >/dev/null 2>&1; then
    rm -f -- "${tmp_sudoers}"
    die "Синтаксическая ошибка во временном sudoers-файле. Установка прервана."
  fi

  # install атомарно копирует файл с нужными правами.
  install -m 0440 -o root -g root "${tmp_sudoers}" "${TEMP_SUDOERS_FILE}"
  rm -f -- "${tmp_sudoers}"

  log "Временный sudoers-файл установлен: ${TEMP_SUDOERS_FILE}"
}

# =============================================================================
# Установка зависимостей и yay
# =============================================================================

# Обновляет базы пакетов и устанавливает git + base-devel.
# ВНИМАНИЕ: -Syu обновляет всю систему — это стандартное поведение для Arch.
# Частичное обновление (-S без -u) не поддерживается и может сломать систему.
install_build_prereqs() {
  log "Обновляю базы пакетов и устанавливаю git, base-devel"
  log "Это выполнит полное обновление системы (pacman -Syu) — штатное поведение Arch Linux"
  run_cmd pacman -Syu --needed --noconfirm git base-devel
}

# Устанавливает yay если он ещё не установлен.
# Сборка всегда выполняется от AUR_USER — makepkg запрещает запуск от root.
install_yay_if_needed() {
  if command -v yay >/dev/null 2>&1; then
    YAY_AVAILABLE=true
    log "yay уже установлен: $(yay --version | head -n1)"
    return 0
  fi

  YAY_AVAILABLE=false
  log "yay не найден, выполняю сборку из AUR"

  if $DRY_RUN; then
    log "DRY-RUN: сборка yay пропущена. В реальном запуске yay будет собран первым."
    return 0
  fi

  log "Создаю временный каталог для сборки yay"
  # mktemp в домашнем каталоге пользователя — там точно есть права на запись.
  TMP_DIR="$(mktemp -d "${AUR_HOME}/yay-build.XXXXXX")"
  chown "${AUR_USER}:" "${TMP_DIR}"

  log "Клонирую репозиторий yay от имени ${AUR_USER}"
  run_as_user git clone --depth=1 https://aur.archlinux.org/yay.git "${TMP_DIR}/yay"

  log "Собираю yay (jobs: ${BUILD_JOBS})"
  # Передаём переменные сборки через окружение, а не через интерполяцию в строку.
  # Это безопасно даже если пути содержат пробелы или спецсимволы.
  run_as_user env \
    MAKEFLAGS="-j${BUILD_JOBS}" \
    BUILDDIR="${AUR_CACHE_DIR}" \
    bash -c "cd $(printf '%q' "${TMP_DIR}/yay") && makepkg -s --noconfirm --needed"

  # Ищем собранный пакет. Сортируем по времени модификации (-t) и берём новейший.
  # Это защищает от ситуации, когда в каталоге остался пакет от предыдущей сборки.
  local pkg_file=""
  pkg_file="$(find "${TMP_DIR}/yay" -maxdepth 1 -type f \
    \( -name 'yay-*.pkg.tar.zst' -o -name 'yay-*.pkg.tar.xz' \) \
    -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)"

  [[ -n "${pkg_file}" ]] || die "Не удалось найти собранный пакет yay в ${TMP_DIR}/yay"

  log "Устанавливаю yay от root: $(basename "${pkg_file}")"
  pacman -U --noconfirm "${pkg_file}"

  command -v yay >/dev/null 2>&1 || die "yay не обнаружен после установки — что-то пошло не так"
  YAY_AVAILABLE=true
  log "yay успешно установлен: $(yay --version | head -n1)"
}

# =============================================================================
# Установка пакетов
# =============================================================================

install_repo_packages() {
  if (( ${#REPO_TO_INSTALL[@]} == 0 )); then
    log "Все repo-пакеты уже установлены, пропускаю"
    return 0
  fi

  log "Устанавливаю ${#REPO_TO_INSTALL[@]} repo-пакет(ов) через pacman"
  run_cmd pacman -S --needed --noconfirm "${REPO_TO_INSTALL[@]}"
}

install_aur_packages() {
  # Объединяем проверенные и непроверенные пакеты в один список для yay.
  # Безопасное обращение к массивам: используем промежуточные переменные.
  local targets=()
  if (( ${#AUR_TO_INSTALL[@]} > 0 )); then
    targets+=("${AUR_TO_INSTALL[@]}")
  fi

  if (( ${#AUR_UNKNOWN[@]} > 0 )); then
    warn "Следующие AUR-пакеты не удалось проверить заранее (передаю в yay напрямую):"
    printf '  - %s\n' "${AUR_UNKNOWN[@]}"
    targets+=("${AUR_UNKNOWN[@]}")
  fi

  if (( ${#targets[@]} == 0 )); then
    log "Все AUR-пакеты уже установлены, пропускаю"
    return 0
  fi

  log "Устанавливаю ${#targets[@]} AUR-пакет(ов) через yay"
  log "Каталог кеша сборки: ${AUR_CACHE_DIR}"
  log "Число jobs: ${BUILD_JOBS}"

  # Создаём каталог кеша от имени пользователя.
  run_as_user_cmd mkdir -p "${AUR_CACHE_DIR}"

  run_as_user_cmd yay -S \
    --needed \
    --noconfirm \
    --builddir "${AUR_CACHE_DIR}" \
    --norebuild \
    --mflags "-j${BUILD_JOBS}" \
    --answerclean None \
    --answerdiff None \
    --answeredit None \
    "${targets[@]}"
}

# =============================================================================
# Развёртывание конфигурационных файлов
# =============================================================================

# Проверяет, входит ли запись "app:file" в список SENSITIVE_CONFIGS.
# Такие файлы копируются с правами 600 вместо 644.
is_sensitive_config() {
  local entry="$1"
  local s
  for s in "${SENSITIVE_CONFIGS[@]+"${SENSITIVE_CONFIGS[@]}"}"; do
    [[ "${s}" == "${entry}" ]] && return 0
  done
  return 1
}

# Создаёт резервную копию файла или каталога с суффиксом .bak.YYYYMMDD_HHMMSS.
# Если цель не существует — молча ничего не делает.
# Хранится только одна резервная копия: новая перезаписывает старую при
# совпадении секунды (на практике не происходит при нормальной работе).
backup_if_exists() {
  local target="$1"
  [[ -e "${target}" || -L "${target}" ]] || return 0

  local backup="${target}.bak.$(date '+%Y%m%d_%H%M%S')"
  if $DRY_RUN; then
    log "    DRY-RUN: резервная копия  ${target}  →  $(basename "${backup}")"
  else
    # -a: сохраняем права, время, симлинки.
    # --remove-destination: заменяем существующий .bak если он есть.
    cp -a --remove-destination "${target}" "${backup}"
    log "    Резервная копия: $(basename "${backup}")"
  fi
}

# Копирует один файл или каталог из src в dst.
# $3 = "sensitive" → chmod 600; иначе → chmod 644.
deploy_item() {
  local src="$1"
  local dst="$2"
  local mode="${3:-normal}"

  if [[ -d "${src}" ]]; then
    # Источник — каталог: копируем содержимое рекурсивно.
    if $DRY_RUN; then
      log "    DRY-RUN: cp -a  ${src}/  →  ${dst}/"
    else
      mkdir -p "${dst}"
      cp -a "${src}/." "${dst}/"
      # Скрипт запущен от root — меняем владельца на целевого пользователя.
      chown -R "${AUR_USER}:" "${dst}"
      log "    Каталог: ${dst}/"
    fi
  else
    # Источник — файл.
    if $DRY_RUN; then
      local perm; [[ "${mode}" == "sensitive" ]] && perm="600" || perm="644"
      log "    DRY-RUN: cp  ${src}  →  ${dst}  (${perm})"
    else
      mkdir -p "$(dirname "${dst}")"
      cp -a "${src}" "${dst}"
      chown "${AUR_USER}:" "${dst}"
      if [[ "${mode}" == "sensitive" ]]; then
        chmod 600 "${dst}"
        log "    Файл (600): ${dst}"
      else
        chmod 644 "${dst}"
        log "    Файл (644): ${dst}"
      fi
    fi
  fi
}

# Главная функция развёртывания конфигов.
# Для каждой записи в CONFIG_FILES:
#   1. Проверяет наличие источника в CONFIGS_SRC.
#   2. Создаёт резервную копию существующего файла в ~/.config/.
#   3. Копирует новый файл с нужными правами.
deploy_configs() {
  log "-------------------------------------------------------"
  log "Развёртывание конфигурационных файлов"
  log "  Источник:    ${CONFIGS_SRC}"
  log "  Назначение:  ${AUR_HOME}/.config/"
  log "-------------------------------------------------------"

  # Проверяем что каталог-источник существует.
  if [[ ! -d "${CONFIGS_SRC}" ]]; then
    warn "Каталог конфигов не найден: ${CONFIGS_SRC}"
    warn "Ожидаемая структура:"
    warn "  ${CONFIGS_SRC}/"
    warn "    alacritty/alacritty.toml"
    warn "    dunst/dunstrc"
    warn "    nitrogen/nitrogen.cfg"
    warn "    nitrogen/bg-saved.cfg"
    warn "    rofi/config.rasi"
    warn "    sxhkd/sxhkdrc"
    warn "    rclone/rclone.conf"
    warn "Создай каталог рядом со скриптом или укажи путь через --configs-src DIR."
    warn "Развёртывание конфигов пропущено."
    return 0
  fi

  local deployed=0 skipped=0
  local entry app item src dst

  for entry in "${CONFIG_FILES[@]}"; do
    # Разбиваем "приложение:файл" на две части.
    app="${entry%%:*}"
    item="${entry##*:}"

    src="${CONFIGS_SRC}/${app}/${item}"
    dst="${AUR_HOME}/.config/${app}/${item}"

    if [[ ! -e "${src}" ]]; then
      warn "Источник не найден, пропускаю: ${src}"
      (( skipped++ )) || true
      continue
    fi

    log "  ${app}/${item}"

    # Резервная копия существующего файла перед заменой.
    backup_if_exists "${dst}"

    # Определяем режим прав: 600 для чувствительных, 644 для остальных.
    local mode="normal"
    is_sensitive_config "${entry}" && mode="sensitive"

    deploy_item "${src}" "${dst}" "${mode}"
    (( deployed++ )) || true
  done

  echo
  log "Конфиги: развёрнуто — ${deployed}, пропущено (нет источника) — ${skipped}"

  # Отдельное напоминание про rclone.conf если он был в списке.
  if ! $DRY_RUN; then
    local e
    for e in "${CONFIG_FILES[@]}"; do
      if [[ "${e}" == rclone:* ]]; then
        log ""
        log "  ! rclone.conf содержит токены доступа к облачным сервисам."
        log "    Скопирован с правами 600. Не добавляй в публичные репозитории."
        break
      fi
    done
  fi
}

# =============================================================================
# Основная функция
# =============================================================================

main() {
  # -------------------------------------------------------------------------
  # Предварительные проверки
  # -------------------------------------------------------------------------

  [[ $EUID -eq 0 ]] || die "Скрипт нужно запускать от root (через sudo или напрямую)"

  command -v pacman >/dev/null 2>&1 \
    || die "pacman не найден. Скрипт предназначен только для Arch Linux."

  [[ ! -e /var/lib/pacman/db.lck ]] \
    || die "База pacman заблокирована (/var/lib/pacman/db.lck). \
Убедись, что pacman не запущен, и удали файл блокировки вручную."

  # Инициализируем лог-файл до exec-редиректа.
  touch "${LOG_FILE}" 2>/dev/null \
    || die "Не могу создать лог-файл: ${LOG_FILE}. Проверь права на /var/log/."

  # Лог может содержать имена пользователей и пути — ограничиваем доступ.
  if ! chmod 600 "${LOG_FILE}" 2>/dev/null; then
    warn "Не удалось установить права 600 на ${LOG_FILE}"
  fi

  # Перенаправляем весь вывод в лог + терминал одновременно.
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log "======================================================="
  log "Запуск install_software.sh — $(date '+%Y-%m-%d %H:%M:%S')"
  log "======================================================="

  $DRY_RUN      && log "Режим DRY-RUN: реальных изменений не будет"
  $CONFIGS_ONLY && log "Режим --configs-only: установка пакетов пропущена"
  $DEPLOY_CONFIGS || log "Флаг --no-configs: развёртывание конфигов пропущено"

  # -------------------------------------------------------------------------
  # Определение пользователя для AUR и конфигов
  # -------------------------------------------------------------------------

  if [[ -n "${AUR_USER_CLI:-}" ]]; then
    # Пользователь задан явно через --aur-user.
    AUR_USER="${AUR_USER_CLI}"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    # sudo автоматически выставляет SUDO_USER в имя вызвавшего пользователя.
    # Это стандартный случай: sudo ./install_software.sh
    AUR_USER="${SUDO_USER}"
  else
    die "Не удалось определить пользователя для AUR. \
Запусти через sudo от обычного пользователя, или укажи --aur-user USERNAME."
  fi

  # makepkg запрещает сборку от root; конфиги тоже не должны принадлежать root.
  [[ "${AUR_USER}" != "root" ]] \
    || die "Нельзя использовать root. \
Укажи непривилегированного пользователя через --aur-user."

  # Проверяем существование пользователя.
  id "${AUR_USER}" >/dev/null 2>&1 \
    || die "Пользователь '${AUR_USER}' не существует в системе."

  # getent надёжнее $HOME при sudo — читает /etc/passwd напрямую.
  AUR_HOME="$(getent passwd "${AUR_USER}" | cut -d: -f6)"
  [[ -n "${AUR_HOME:-}" && -d "${AUR_HOME}" ]] \
    || die "Домашний каталог пользователя '${AUR_USER}' не найден: '${AUR_HOME}'"

  AUR_CACHE_DIR="${AUR_HOME}/.cache/yay-build"

  log "Пользователь:        ${AUR_USER}"
  log "Домашний каталог:    ${AUR_HOME}"
  log "Каталог кеша AUR:    ${AUR_CACHE_DIR}"
  log "Каталог конфигов:    ${CONFIGS_SRC}"
  log "Лог-файл:            ${LOG_FILE}"
  log "Число jobs:          ${BUILD_JOBS}"

  # -------------------------------------------------------------------------
  # Защита от sudoers-файла оставшегося после kill -9
  # (trap EXIT в таком случае не выполняется).
  # -------------------------------------------------------------------------
  if [[ -f "${TEMP_SUDOERS_FILE}" ]]; then
    warn "Найден sudoers-файл от предыдущего запуска, удаляю: ${TEMP_SUDOERS_FILE}"
    rm -f -- "${TEMP_SUDOERS_FILE}"
  fi

  # -------------------------------------------------------------------------
  # Установка пакетов (пропускается при --configs-only)
  # -------------------------------------------------------------------------

  if ! $CONFIGS_ONLY; then
    # 1. При необходимости выдаём временные права sudo для pacman.
    $ALLOW_TEMP_SUDO && grant_temp_sudo

    # 2. Обновляем систему и устанавливаем инструменты сборки.
    install_build_prereqs

    # 3. Классифицируем repo-пакеты (до установки yay — не нужен).
    split_repo_packages

    # 4. Устанавливаем yay если нет, затем классифицируем AUR-пакеты
    #    (yay нужен для точной проверки через yay -Si).
    install_yay_if_needed
    split_aur_packages

    # Вывод плана установки.
    print_list "Repo: уже установлены"   "${REPO_INSTALLED[@]+"${REPO_INSTALLED[@]}"}"
    print_list "Repo: будут установлены" "${REPO_TO_INSTALL[@]+"${REPO_TO_INSTALL[@]}"}"
    print_list "Repo: НЕ НАЙДЕНЫ"        "${REPO_NOT_FOUND[@]+"${REPO_NOT_FOUND[@]}"}"
    print_list "AUR:  уже установлены"   "${AUR_INSTALLED[@]+"${AUR_INSTALLED[@]}"}"
    print_list "AUR:  будут установлены" "${AUR_TO_INSTALL[@]+"${AUR_TO_INSTALL[@]}"}"
    print_list "AUR:  НЕ НАЙДЕНЫ"        "${AUR_NOT_FOUND[@]+"${AUR_NOT_FOUND[@]}"}"
    print_list "AUR:  статус неизвестен (будут переданы в yay)" \
      "${AUR_UNKNOWN[@]+"${AUR_UNKNOWN[@]}"}"
    echo

    # Останавливаемся если есть пакеты, которых точно не существует.
    # Лучше упасть здесь, чем потратить время на установку и упасть в середине.
    if (( ${#REPO_NOT_FOUND[@]} > 0 || ${#AUR_NOT_FOUND[@]} > 0 )); then
      die "Обнаружены несуществующие пакеты (см. выше). \
Исправь списки PACMAN_PKGS / AUR_PKGS и запусти снова."
    fi

    install_repo_packages
    install_aur_packages
  fi

  # -------------------------------------------------------------------------
  # Развёртывание конфигов (пропускается при --no-configs)
  # -------------------------------------------------------------------------

  $DEPLOY_CONFIGS && deploy_configs

  # -------------------------------------------------------------------------
  # Финальная верификация (только в реальном режиме)
  # -------------------------------------------------------------------------

  if ! $DRY_RUN; then
    local verification_failed=false

    if ! $CONFIGS_ONLY; then
      verify_installed_group "repo" "${PACMAN_PKGS[@]}" || verification_failed=true
      verify_installed_group "aur"  "${AUR_PKGS[@]}"    || verification_failed=true
    fi

    if $verification_failed; then
      die "Верификация не прошла: часть пакетов не установлена. Проверь лог: ${LOG_FILE}"
    fi

    log "======================================================="
    log "Завершено успешно — $(date '+%Y-%m-%d %H:%M:%S')"
    log "======================================================="
  else
    log "======================================================="
    log "DRY-RUN завершён. Реальных изменений не было."
    log "Для запуска установки уберите флаг --dry-run."
    log "======================================================="
  fi
}

main "$@"

