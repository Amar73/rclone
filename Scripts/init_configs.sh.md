16:08:55 amar@amar319:~/.config$ ls ~/.config
alacritty
autostart
BraveSoftware
chromium
Code
create-next-app-nodejs
Cursor
dconf
dunst
flameshot
flutter
fyne
gemini-cli
GIMP
go
Google
google-chrome
gtk-3.0
kate
kde.org
kitty
libfm
libreoffice
mc
Mousepad
nautilus
nextjs-nodejs
nitrogen
obsidian
opera
pcmanfm
picom
pulse
rclone
rofi
simple-scan
singbox-launcher
suckless
sxhkd
systemd
Thunar
vlc
warp-terminal
xfce4
yandex-browser
yandex-disk
yay
init_configs.sh
kate-externaltoolspluginrc
katemoderc
katerc
katevirc
mimeapps.list
okularrc
QtProject.conf
user-dirs.dirs
user-dirs.locale

16:11:54 amar@amar319:~/.config$ less ~/Scripts/init_configs.sh.md

#!/usr/bin/env bash
set -Eeuo pipefail

# Папка с эталонными конфигами (лежит рядом с этим скриптом)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/default_configs"
# Целевая папка
DEST_DIR="${HOME}/.config"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Список конфигов (папок или файлов), которые нужно проверять и создавать
CONFIGS=(
  "alacritty"
  "dunst"
  "rofi"
  "sxhkd"
  "birdtray"
)

ensure_config() {
  local item="$1"
  local src="${SRC_DIR}/${item}"
  local dest="${DEST_DIR}/${item}"

  # 1. Проверяем, есть ли конфиг в целевой папке (~/.config/...)
  if [[ -e "${dest}" ]]; then
    log "Конфиг уже существует, пропускаю: ${dest}"
    return 0
  fi

  # 2. Проверяем, есть ли откуда копировать
  if [[ ! -e "${src}" ]]; then
    warn "Эталонный конфиг не найден, нечего копировать: ${src}"
    return 0
  fi

  # 3. Создаем структуру и копируем
  log "Конфиг отсутствует. Создаю: ${dest}"
  mkdir -p "$(dirname "${dest}")"
  cp -r "${src}" "${dest}"
}

main() {
  log "Начинаю проверку конфигурационных файлов в ${DEST_DIR}"

  if [[ ! -d "${SRC_DIR}" ]]; then
    warn "Папка с эталонными конфигами не найдена: ${SRC_DIR}"
    log "Создаю пустую папку ${SRC_DIR} для будущих шаблонов."
    mkdir -p "${SRC_DIR}"
    exit 0
  fi

  local item
  for item in "${CONFIGS[@]}"; do
    ensure_config "${item}"
  done

  log "===== Проверка конфигов завершена ====="
}

main "$@"
