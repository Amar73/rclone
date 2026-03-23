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

# -----------------------------------------------------------------------------
# set -Eeuo pipefail — «строгий режим» bash, включается первым делом.
#
#   -E  ERR-трап наследуется в функциях и подоболочках (без этого trap ERR
#       срабатывал бы только в основном коде).
#   -e  Немедленный выход при ненулевом коде возврата любой команды.
#       Исключение: команды в условиях if/while, правая часть ||/&&,
#       команды с явным || true в конце.
#   -u  Обращение к неустановленной переменной — ошибка. Защищает от опечаток
#       вроде $CNOFIGS_SRC вместо $CONFIGS_SRC.
#   -o pipefail  Код возврата конвейера — код последней упавшей команды,
#       а не последней команды. Без этого «cmd1 | cmd2» маскирует ошибку cmd1.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

# =============================================================================
# Константы и значения по умолчанию
# =============================================================================

# Лог пишется в /var/log — системный каталог, всегда доступный от root.
# readonly запрещает случайное переопределение переменной в коде ниже.
readonly LOG_FILE="/var/log/install_software.log"

# Временный файл sudoers создаётся в /etc/sudoers.d/ — стандартное место
# для drop-in конфигов sudo. Имя начинается с 99- чтобы он загружался последним
# и не конфликтовал с другими правилами.
readonly TEMP_SUDOERS_FILE="/etc/sudoers.d/99-temp-aur-installer"

# --- Флаги режимов работы ---
DRY_RUN=false          # --dry-run: показываем план, ничего не делаем
ALLOW_TEMP_SUDO=false  # --allow-temp-sudo: выдать временный NOPASSWD для yay
DEPLOY_CONFIGS=true    # выключается флагом --no-configs
CONFIGS_ONLY=false     # включается флагом --configs-only

# --- Число параллельных потоков для makepkg/make ---
# Сначала берём из переменной окружения BUILD_JOBS, иначе считаем через nproc.
# nproc возвращает число доступных процессоров — оптимально для компиляции.
# Флаг --jobs перекроет это значение при разборе аргументов ниже.
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# Пользователь для AUR, заданный через --aur-user (пусто = ещё не задан).
AUR_USER_CLI=""

# Каталог с исходными конфигами.
# Приоритет: переменная окружения CONFIGS_SRC → ./configs рядом со скриптом.
# realpath разворачивает симлинки и относительные пути, чтобы скрипт работал
# из любого рабочего каталога.
CONFIGS_SRC="${CONFIGS_SRC:-$(dirname "$(realpath "$0")")/configs}"

# =============================================================================
# PACMAN_PKGS — пакеты из официальных репозиториев Arch Linux
# =============================================================================
# Все пакеты проверяются через `pacman -Si` перед установкой.
# Если пакет не найден — скрипт завершится с ошибкой до начала установки,
# не тратя время на частичную установку.
#
# ИСПРАВЛЕНИЕ: bluetui, wiremix, dysk убраны отсюда — они есть только в AUR,
# не в официальных репозиториях. В PACMAN_PKGS они вызывали бы ошибку
# «пакет не найден» при проверке через pacman -Si.

PACMAN_PKGS=(

  # --- X.Org — графический сервер и утилиты ---
  # xorg-server: основной X-сервер. Нужен для запуска любого WM/DE в X11.
  # xorg-xinit: утилита xinit/startx для ручного запуска X-сессии.
  # xorg-xsetroot: устанавливает цвет/курсор корневого окна (нужен для DWM и др.).
  # xorg-xrandr: управление мониторами, разрешением, ориентацией экранов.
  # xorg-xev: отладка событий клавиатуры и мыши (показывает keycodes).
  # xorg-xprop: читает X-свойства окон (полезно при настройке WM-правил).
  # xorg-xinput: настройка устройств ввода (тачпад, мышь, планшет).
  # xorg-xkbutils: утилиты xkbcomp и xkbprint для отладки раскладки клавиатуры.
  # Внимание: правильное имя — xorg-xkbutils (без дефиса перед utils).
  # Старое имя xorg-xkb-utils было переходным пакетом и давно удалено.
  xorg-server
  xorg-xinit
  xorg-xsetroot
  xorg-xrandr
  xorg-xev
  xorg-xprop
  xorg-xinput
  xorg-xkbutils

  # --- Библиотеки X11 ---
  # libx11:        базовая клиентская библиотека X11 (Xlib). Нужна большинству GUI.
  # libxft:        рендеринг шрифтов через FreeType (нужен DWM, st и др.).
  # libxinerama:   поддержка нескольких мониторов в старых приложениях.
  # libxcursor:    тематические курсоры (анимация, размер).
  # libxcomposite: API для оконных менеджеров с эффектами (picom и др.).
  # libxdamage:    уведомления об «испорченных» областях экрана — используется
  #                пикомом и другими compositers для эффективной перерисовки.
  # libxkbcommon:  современная библиотека обработки раскладок (Wayland и X11).
  # libnotify:     отправка уведомлений через D-Bus (notify-send и др.).
  libx11
  libxft
  libxinerama
  libxcursor
  libxcomposite
  libxdamage
  libxkbcommon
  libnotify

  # --- Шрифты и рендеринг ---
  # freetype2:             движок рендеринга шрифтов (хинтинг, субпиксели).
  # fontconfig:            система настройки и обнаружения шрифтов в Linux.
  # ttf-jetbrains-mono-nerd: моноширинный шрифт с патченными иконками Nerd Fonts
  #                           (для статусбаров, терминалов, lf/ranger и др.).
  # woff2-font-awesome:    иконочный шрифт Font Awesome 7 (веб и десктоп).
  #                        Внимание: пакет переименован из ttf-font-awesome в
  #                        woff2-font-awesome — pacman предложит замену при -Syu.
  # noto-fonts:            шрифты Google Noto для латиницы, кириллицы и др.
  # noto-fonts-cjk:        расширение Noto для китайского, японского, корейского.
  # noto-fonts-emoji:      цветные эмодзи Google Noto.
  freetype2
  fontconfig
  ttf-jetbrains-mono-nerd
  woff2-font-awesome
  noto-fonts
  noto-fonts-cjk
  noto-fonts-emoji

  # --- Звук (PipeWire) ---
  # PipeWire — современная замена PulseAudio и JACK.
  # pipewire:        основной демон. Управляет потоками аудио и видео.
  # pipewire-alsa:   слой совместимости ALSA → PipeWire (приложения, использующие
  #                  ALSA напрямую, автоматически идут через PipeWire).
  # pipewire-pulse:  сервер-заглушка PulseAudio: приложения «видят» PulseAudio,
  #                  а на самом деле работают с PipeWire.
  # pipewire-jack:   совместимость с JACK API для профессионального аудио.
  # wireplumber:     менеджер сессий PipeWire (заменил pipewire-media-session).
  #                  Управляет маршрутизацией устройств и политиками.
  # alsa-utils:      утилиты alsamixer, amixer — низкоуровневое управление звуком.
  # pamixer:         командная строка для управления громкостью через PulseAudio API
  #                  (работает с pipewire-pulse). Удобен для биндов клавиш.
  pipewire
  pipewire-alsa
  pipewire-pulse
  pipewire-jack
  wireplumber
  alsa-utils
  pamixer

  # --- Системные компоненты ---
  # base-devel:      мета-пакет: gcc, make, binutils и др. — нужен для сборки AUR.
  # accountsservice: D-Bus сервис управления учётными записями (нужен GDM, SDDM).
  # polkit-gnome:    агент аутентификации PolicyKit с GUI (диалог ввода пароля
  #                  при повышении привилегий из графических приложений).
  # xdg-utils:       стандартные утилиты xdg-open, xdg-mime — открытие файлов
  #                  в нужном приложении по MIME-типу.
  # xdg-user-dirs:   создаёт ~/Desktop, ~/Downloads и т.д. по стандарту XDG.
  # openssh:         SSH-клиент и сервер. sshd, ssh, ssh-keygen, ssh-copy-id.
  # gvfs:            виртуальная файловая система для Nautilus и других GTK-
  #                  приложений (монтирование MTP, SMB, FTP через GUI).
  # unzip:           распаковка ZIP-архивов. Нужен многим AUR-пакетам при сборке.
  # tree:            отображение структуры каталогов в виде дерева.
  # dmidecode:       читает таблицы DMI/SMBIOS — информация о железе от BIOS.
  base-devel
  accountsservice
  polkit-gnome
  xdg-utils
  xdg-user-dirs
  openssh
  gvfs
  unzip
  tree
  dmidecode

  # --- Сеть ---
  # iproute2:               ip, ss, tc — замена устаревшим ifconfig/netstat/route.
  # bind:                   утилиты DNS: dig, nslookup, host. Сам named не нужен.
  # networkmanager:         демон управления сетью. Автоматически поднимает
  #                         интерфейсы, управляет WiFi, VPN, мобильным интернетом.
  # network-manager-applet: nm-applet — системный трей для NetworkManager.
  iproute2
  bind
  networkmanager
  network-manager-applet

  # --- Видеодрайвер ---
  # xf86-video-nouveau: открытый драйвер для видеокарт NVIDIA.
  # Подходит для старых карт или если не нужна максимальная производительность.
  # Для современных NVIDIA лучше nvidia (проприетарный) или nvidia-open.
  xf86-video-nouveau

  # --- Терминалы ---
  # alacritty: GPU-ускоренный терминал на Rust. Быстрый, настраивается через TOML.
  # kitty:     GPU-ускоренный терминал с поддержкой графики, вкладок и сплитов.
  alacritty
  kitty

  # --- Файловые менеджеры ---
  # mc:                   Midnight Commander — двухпанельный TUI-менеджер.
  # ranger:               TUI-менеджер с vim-навигацией. Предпросмотр файлов.
  # nautilus:             GUI-менеджер GNOME. Интеграция с gvfs (сеть, MTP).
  # gnome-disk-utility:   GUI для управления дисками, разделами, SMART-данными.
  mc
  ranger
  nautilus
  gnome-disk-utility

  # --- WM-утилиты ---
  # sxhkd:    Simple X HotKey Daemon. Глобальные горячие клавиши для BSPWM и др.
  # rofi:     запускалка приложений, переключатель окон, dmenu-замена.
  # numlockx: включает NumLock при старте X-сессии.
  # wmctrl:   управление окнами из командной строки (перемещение, фокус, теги).
  sxhkd
  rofi
  numlockx
  wmctrl

  # --- Уведомления и снимки экрана ---
  # dunst:     лёгкий демон уведомлений. Настраивается через dunstrc.
  # flameshot: скриншоты с аннотациями, выделением областей, загрузкой в облако.
  dunst
  flameshot

  # --- Буфер обмена и автоматизация ---
  # xclip:   копирование/вставка через командную строку (xclip -selection clipboard).
  # xdotool: симуляция нажатий клавиш и движений мыши, управление окнами.
  xclip
  xdotool

  # --- Браузеры и связь ---
  # firefox:          браузер Mozilla. Из официальных репозиториев.
  # telegram-desktop: официальный клиент Telegram.
  # thunderbird:      почтовый клиент Mozilla с поддержкой IMAP/POP3/CalDAV.
  firefox
  telegram-desktop
  thunderbird

  # --- Текстовые редакторы ---
  # vim:      классический консольный редактор. Всегда полезен на сервере/в chroot.
  # mousepad: простой GUI-редактор XFCE. Лёгкая альтернатива gedit.
  vim
  mousepad

  # --- Утилиты командной строки ---
  # wget:     загрузка файлов по HTTP/HTTPS/FTP. Умеет возобновлять закачку.
  # curl:     передача данных по HTTP, FTP, SFTP и др. Де-факто стандарт.
  # git:      система контроля версий. Нужен и для AUR, и для dotfiles.
  # eza:      современная замена ls с цветами, иконками, git-статусом.
  # duf:      современная замена df — красивый вывод использования дисков.
  # ncdu:     интерактивный анализатор занятого места на диске (TUI).
  # rclone:   синхронизация с облачными хранилищами (Яндекс, Google, S3 и др.).
  # lazygit:  TUI-интерфейс для git — коммиты, ребейз, история одной клавишей.
  # s-tui:    мониторинг температуры CPU и частот в TUI с графиком.
  wget
  curl
  git
  eza
  duf
  ncdu
  rclone
  lazygit
  s-tui

  # --- Мониторинг системы ---
  # btop:   красивый TUI-монитор процессов/CPU/RAM/сети/дисков (замена htop).
  # htop:   интерактивный просмотр процессов. Классика.
  # atop:   расширенный монитор: записывает историю нагрузки на диск для анализа.
  btop
  htop
  atop

  # --- Docker ---
  # docker: движок контейнеризации. После установки нужно:
  #   sudo systemctl enable --now docker
  #   sudo usermod -aG docker $USER
  docker

)

# =============================================================================
# AUR_PKGS — пакеты из AUR (устанавливаются через yay)
# =============================================================================
# Проверяются через `yay -Si` (если yay уже есть) или через git ls-remote.
# Пакеты, которые не удалось проверить заранее, попадают в UNKNOWN и всё равно
# передаются в yay — тот выдаст понятную ошибку если пакет не существует.
#
# ИСПРАВЛЕНИЕ: bluetui, wiremix, dysk перенесены сюда из PACMAN_PKGS —
# они существуют только в AUR и недоступны через pacman -Si.

AUR_PKGS=(

  # --- Браузеры ---
  # google-chrome:  браузер Google Chrome (проприетарный).
  # yandex-browser: браузер Яндекс на Chromium.
  # brave-bin:      браузер Brave с блокировкой рекламы (бинарная сборка).
  google-chrome
  yandex-browser
  brave-bin

  # --- Облако ---
  # yandex-disk: клиент Яндекс.Диска для синхронизации файлов.
  yandex-disk

  # --- Текстовые редакторы ---
  # notepadqq: редактор в стиле Notepad++ для Linux. Подсветка синтаксиса.
  notepadqq

  # --- Почта ---
  # birdtray: системный трей для Thunderbird. Скрывает окно вместо закрытия,
  #           показывает счётчик непрочитанных писем.
  birdtray

  # --- Обои ---
  # nitrogen: лёгкий менеджер обоев для X11. Настройки хранит в ~/.config/nitrogen/.
  nitrogen

  # --- Мониторинг ---
  # neohtop:     современный TUI-монитор процессов (альтернатива htop/btop).
  # lazydocker:  TUI-интерфейс для Docker — контейнеры, логи, образы.
  # bluetui:     TUI-менеджер Bluetooth устройств.
  # wiremix:     TUI для управления аудио через PipeWire (микшер в терминале).
  # dysk:        современная замена df с красивым выводом и цветными столбцами.
  neohtop
  lazydocker
  bluetui
  wiremix
  dysk

)

# =============================================================================
# CONFIG_FILES — карта конфигурационных файлов для развёртывания
# =============================================================================
#
# Формат каждой записи: "приложение:файл_или_подкаталог"
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
  # Терминал Alacritty — основной конфиг (цвета, шрифт, горячие клавиши).
  "alacritty:alacritty.toml"

  # Демон уведомлений Dunst — стиль, поведение, горячие клавиши уведомлений.
  "dunst:dunstrc"

  # Обои рабочего стола Nitrogen.
  # nitrogen.cfg  — настройки программы (режим растяжки и т.д.).
  # bg-saved.cfg  — запомненные обои для каждого монитора.
  "nitrogen:nitrogen.cfg"
  "nitrogen:bg-saved.cfg"

  # Запускалка приложений Rofi — тема, режим отображения, горячие клавиши.
  "rofi:config.rasi"

  # Горячие клавиши sxhkd — биндинги для WM и пользовательских команд.
  "sxhkd:sxhkdrc"

  # Синхронизация облака rclone.
  # ВНИМАНИЕ: rclone.conf содержит токены доступа к облачным сервисам.
  # Файл копируется с правами 600. Не добавляй его в публичные репозитории!
  "rclone:rclone.conf"
)

# =============================================================================
# SENSITIVE_CONFIGS — конфиги с чувствительными данными
# =============================================================================
# Файлы из этого списка копируются с правами 600 (только владелец может читать),
# а не 644 (как обычные конфиги).
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

# Массивы результатов классификации пакетов (заполняются функциями split_*).
REPO_INSTALLED=()   # repo-пакеты, уже установленные в системе
REPO_TO_INSTALL=()  # repo-пакеты, которые нужно установить
REPO_NOT_FOUND=()   # repo-пакеты, не найденные ни в одном репозитории

AUR_INSTALLED=()    # AUR-пакеты, уже установленные
AUR_TO_INSTALL=()   # AUR-пакеты, которые нужно установить
AUR_NOT_FOUND=()    # AUR-пакеты, которых нет в AUR (скрипт упадёт с ошибкой)
AUR_UNKNOWN=()      # AUR-пакеты, статус которых не удалось проверить заранее

# =============================================================================
# Вспомогательные функции вывода
# =============================================================================

# log: информационное сообщение → stdout (и в лог через tee, см. main).
log()  { echo "[INFO]  $*"; }

# warn: предупреждение → stderr (не прерывает выполнение).
warn() { echo "[WARN]  $*" >&2; }

# die: критическая ошибка → stderr, выход с кодом 1.
# После die сработает trap EXIT → cleanup().
die()  { echo "[ERROR] $*" >&2; exit 1; }

# usage: выводит справку, извлекая блок комментариев из заголовка скрипта.
# sed вырезает текст между двумя строками «# ===...», убирая символ «# » в начале.
usage() {
  sed -n '/^# ={5}/,/^# ={5}/{ s/^# \?//; p }' "$0" | head -n -1
}

# =============================================================================
# Обработчики сигналов и очистка
# =============================================================================

# on_error: вызывается трапом ERR при любой ошибке команды.
# Принимает номер строки как аргумент (передаётся через trap 'on_error $LINENO').
on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  echo "[ERROR] Сбой на строке ${line_no}, код выхода: ${exit_code}" >&2
  exit "$exit_code"
}

# cleanup: вызывается трапом EXIT при любом завершении скрипта —
# нормальном, по ошибке, или по Ctrl+C (SIGINT).
# Гарантирует, что временные файлы не останутся в системе.
cleanup() {
  # Удаляем временный каталог сборки yay (создаётся в install_yay_if_needed).
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi

  # Удаляем временный sudoers-файл.
  # ВАЖНО: файл удаляется даже если скрипт завершился с ошибкой в середине —
  # без этого пользователь получил бы постоянный NOPASSWD на pacman.
  if [[ -f "${TEMP_SUDOERS_FILE}" ]]; then
    log "Удаляю временный sudoers-файл: ${TEMP_SUDOERS_FILE}"
    rm -f -- "${TEMP_SUDOERS_FILE}"
  fi
  return 0
}

# Регистрируем обработчики до разбора аргументов — любая ошибка будет поймана.
# trap cleanup EXIT  — cleanup при любом выходе.
# trap 'on_error $LINENO' ERR — on_error при ошибке команды.
# $LINENO раскрывается в момент срабатывания ловушки, давая точный номер строки.
trap cleanup EXIT
trap 'on_error $LINENO' ERR

# =============================================================================
# Разбор аргументов командной строки
# =============================================================================
# Используем while + case вместо getopt для совместимости и прозрачности.
# Каждый флаг сдвигает позиционные параметры через shift.

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
      # Проверяем наличие аргумента ($# -ge 2) и его числовой формат.
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

# Дополнительная валидация после разбора: --configs-only и --no-configs
# взаимно исключают друг друга (нельзя одновременно «только конфиги» и «без конфигов»).
if $CONFIGS_ONLY && ! $DEPLOY_CONFIGS; then
  die "--configs-only и --no-configs нельзя использовать одновременно."
fi

# =============================================================================
# Функции выполнения команд
# =============================================================================

# run_cmd: выполняет команду в реальном режиме или только печатает в dry-run.
# Принимает команду и все её аргументы.
# printf '%q' экранирует спецсимволы — вывод можно скопировать в терминал.
run_cmd() {
  if $DRY_RUN; then
    printf '[DRY-RUN] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# run_as_user: выполняет команду от имени AUR_USER, а не root.
# makepkg запрещает запуск от root — поэтому все AUR-операции идут через эту функцию.
#
# Предпочитает sudo (сохраняет переменные окружения через -H):
#   sudo -H -u USER -- cmd arg1 arg2
#
# Если sudo недоступен — использует su с явным bash:
#   su - USER -s /bin/bash -c "cmd arg1 arg2"
#   printf '%q' экранирует аргументы для передачи через -c без проблем с пробелами.
run_as_user() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -H -u "${AUR_USER}" -- "$@"
  else
    # su: явно указываем /bin/bash чтобы не зависеть от login shell пользователя
    # (который может быть zsh, fish или что угодно).
    su - "${AUR_USER}" -s /bin/bash -c "$(printf '%q ' "$@")"
  fi
}

# run_as_user_cmd: обёртка над run_as_user с поддержкой dry-run.
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

# print_list: выводит заголовок и список элементов (по одному на строку).
# Безопасно обрабатывает пустые массивы при set -u:
# "$@" без аргументов вызвало бы ошибку, поэтому сначала проверяем $#.
print_list() {
  local title="$1"
  shift

  echo
  echo "==> ${title}"
  if [[ $# -eq 0 ]]; then
    echo "  (пусто)"
    return 0
  fi

  local item
  for item in "$@"; do
    echo "  - $item"
  done
}

# is_installed: проверяет, установлен ли пакет через базу данных pacman.
# pacman -Qq выводит имя без версии, /dev/null подавляет вывод.
is_installed() {
  pacman -Qq "$1" >/dev/null 2>&1
}

# repo_exists: проверяет, существует ли пакет в официальных репозиториях.
# pacman -Si читает базу данных репозиториев (не локальную).
repo_exists() {
  pacman -Si "$1" >/dev/null 2>&1
}

# aur_exists: проверяет существование пакета в AUR.
# Возвращаемые коды:
#   0 — пакет найден
#   1 — пакет точно не существует
#   2 — проверить не удалось (нет инструментов или сетевая ошибка)
#
# ИСПРАВЛЕНИЕ: нормализуем код возврата yay -Si, как это делается для git.
# yay -Si может вернуть как 1 («не найден»), так и другой ненулевой код
# при сетевых ошибках — различаем их и возвращаем 2 для неопределённого статуса.
aur_exists() {
  local pkg="$1"
  local rc=0

  if $YAY_AVAILABLE; then
    # yay -Si: обращается к AUR API и проверяет существование пакета.
    run_as_user yay -Si "$pkg" >/dev/null 2>&1 || rc=$?

    # Нормализация кода возврата yay:
    #   0   — пакет найден
    #   1   — пакет не найден в AUR (стандартный код yay для «не найден»)
    #   >1  — сетевая ошибка или иная проблема → статус неизвестен
    if (( rc == 0 )); then
      return 0
    elif (( rc == 1 )); then
      return 1
    else
      return 2
    fi
  fi

  if command -v git >/dev/null 2>&1; then
    # Fallback: проверяем через git ls-remote напрямую к AUR.
    # git ls-remote возвращает:
    #   0   — репозиторий существует (пакет есть в AUR)
    #   128 — репозиторий не найден (пакета нет в AUR)
    #   >0, ≠128 — сетевая ошибка или другая проблема
    run_as_user git ls-remote \
      "https://aur.archlinux.org/${pkg}.git" HEAD >/dev/null 2>&1 || rc=$?
    if (( rc == 128 )); then
      return 1   # репозиторий не существует = пакет не найден
    elif (( rc != 0 )); then
      return 2   # сетевая или иная ошибка = статус неизвестен
    fi
    return 0
  fi

  # Ни yay, ни git недоступны — проверить невозможно, возвращаем «неизвестно».
  return 2
}

# verify_installed_group: финальная верификация — проверяет что все пакеты из
# списка реально установлены после завершения установки.
# $1 — метка группы для сообщения ("repo" или "aur").
# $@ — список пакетов.
# Возвращает 1 если хотя бы один пакет не установлен.
verify_installed_group() {
  local label="$1"
  shift
  local failed=()
  local pkg

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

# split_repo_packages: распределяет PACMAN_PKGS по трём группам:
#   REPO_INSTALLED  — уже установлены (не нужно трогать)
#   REPO_TO_INSTALL — найдены в репо, нужно установить
#   REPO_NOT_FOUND  — не найдены ни в одном репозитории (фатальная ошибка)
#
# Классификация до начала установки позволяет сразу сообщить обо всех
# несуществующих пакетах, не тратя время на частичную установку.
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

# split_aur_packages: распределяет AUR_PKGS по четырём группам:
#   AUR_INSTALLED  — уже установлены
#   AUR_TO_INSTALL — найдены в AUR, нужно установить
#   AUR_NOT_FOUND  — точно не существуют в AUR (фатальная ошибка)
#   AUR_UNKNOWN    — статус не удалось проверить; передаём в yay «на удачу»
split_aur_packages() {
  AUR_INSTALLED=()
  AUR_TO_INSTALL=()
  AUR_NOT_FOUND=()
  AUR_UNKNOWN=()

  local pkg rc
  for pkg in "${AUR_PKGS[@]}"; do
    rc=0
    # Вызов aur_exists может вернуть ненулевой код — перехватываем его вручную,
    # чтобы set -e не прервал скрипт. Это намеренная обработка кода возврата.
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
        # Пакет точно не существует в AUR.
        AUR_NOT_FOUND+=("$pkg")
        ;;
      2|*)
        # Статус неизвестен: нет инструментов для проверки или сетевая ошибка.
        # Если пакет уже установлен — всё хорошо, не трогаем.
        # Если нет — добавляем в UNKNOWN: yay попробует установить и сам сообщит
        # об ошибке если пакет не существует.
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

# grant_temp_sudo: выдаёт AUR_USER временный NOPASSWD на /usr/bin/pacman.
#
# Зачем это нужно:
#   yay при установке AUR-пакетов вызывает pacman для зависимостей.
#   В интерактивном режиме yay сам запросит пароль через sudo — это нормально.
#   В unattended-режиме (CI, cron) sudo не может запросить пароль → зависание.
#   Флаг --allow-temp-sudo решает эту проблему, добавляя NOPASSWD только для pacman.
#
# Безопасность:
#   - NOPASSWD только на /usr/bin/pacman, не на все команды.
#   - Файл валидируется через visudo -c перед установкой.
#   - Удаляется в cleanup() при любом завершении скрипта (trap EXIT).
#   - Создаётся через install с явными правами 0440 (read-only, root:root).
grant_temp_sudo() {
  $DRY_RUN && {
    log "DRY-RUN: создание временного sudoers-файла пропущено"
    return 0
  }

  # Если файл уже существует (остался от прерванного запуска kill -9),
  # удаляем его перед созданием нового.
  if [[ -f "${TEMP_SUDOERS_FILE}" ]]; then
    warn "Найден старый временный sudoers-файл, удаляю: ${TEMP_SUDOERS_FILE}"
    rm -f -- "${TEMP_SUDOERS_FILE}"
  fi

  log "Создаю временные права NOPASSWD для пользователя '${AUR_USER}'"

  # Создаём файл во временном месте для валидации — не сразу в /etc/sudoers.d/.
  # Повреждённый /etc/sudoers.d/ может заблокировать sudo во всей системе.
  local tmp_sudoers
  tmp_sudoers="$(mktemp /tmp/sudoers-validate.XXXXXX)"

  # Heredoc без кавычек вокруг EOF → переменные раскрываются.
  # !requiretty позволяет sudo работать без выделенного терминала (нужно в CI).
  cat > "${tmp_sudoers}" <<EOF
# Временный файл, создан install_software.sh. Удаляется автоматически.
${AUR_USER} ALL=(root) NOPASSWD: /usr/bin/pacman
Defaults:${AUR_USER} !requiretty
EOF

  # visudo -c проверяет синтаксис файла sudoers без его применения.
  # Если синтаксис неверен — отменяем установку, чтобы не сломать sudo.
  if ! visudo -cf "${tmp_sudoers}" >/dev/null 2>&1; then
    rm -f -- "${tmp_sudoers}"
    die "Синтаксическая ошибка во временном sudoers-файле. Установка прервана."
  fi

  # install атомарно копирует файл с нужными правами — безопаснее чем cp + chmod,
  # т.к. файл никогда не существует с неправильными правами.
  install -m 0440 -o root -g root "${tmp_sudoers}" "${TEMP_SUDOERS_FILE}"
  rm -f -- "${tmp_sudoers}"

  log "Временный sudoers-файл установлен: ${TEMP_SUDOERS_FILE}"
}

# =============================================================================
# Установка зависимостей и yay
# =============================================================================

# install_build_prereqs: обновляет базы пакетов и устанавливает git + base-devel.
#
# ВАЖНО: -Syu выполняет полное обновление системы — это стандарт для Arch Linux.
# Частичное обновление (-S без -u) официально не поддерживается и может сломать
# систему из-за несовместимости библиотек (partial upgrade problem).
install_build_prereqs() {
  log "Обновляю базы пакетов и устанавливаю git, base-devel"
  log "Это выполнит полное обновление системы (pacman -Syu) — штатное поведение Arch Linux"
  run_cmd pacman -Syu --needed --noconfirm git base-devel
}

# install_yay_if_needed: устанавливает yay если он ещё не установлен.
#
# Последовательность:
#   1. Проверяем, есть ли yay в PATH.
#   2. Если нет — клонируем AUR-репозиторий yay в временный каталог.
#   3. Собираем пакет через makepkg (от AUR_USER, не от root).
#   4. Устанавливаем собранный .pkg.tar.zst через pacman -U (от root).
install_yay_if_needed() {
  if command -v yay >/dev/null 2>&1; then
    YAY_AVAILABLE=true
    # Читаем версию в переменную, а не прямо в подстановку log.
    # Это исключает код 141 (SIGPIPE) при set -Eeuo pipefail:
    # yay --version выводит несколько строк, head -n1 закрывает pipe после первой,
    # yay получает SIGPIPE при следующей записи и возвращает 141 — set -e
    # трактует это как ошибку. || true гасит SIGPIPE безопасно.
    local yay_ver
    yay_ver="$(yay --version 2>&1 | head -n1 || true)"
    log "yay уже установлен: ${yay_ver}"
    return 0
  fi

  YAY_AVAILABLE=false
  log "yay не найден, выполняю сборку из AUR"

  if $DRY_RUN; then
    log "DRY-RUN: сборка yay пропущена. В реальном запуске yay будет собран первым."
    return 0
  fi

  log "Создаю временный каталог для сборки yay"
  # mktemp в домашнем каталоге AUR_USER — там гарантированно есть права на запись.
  # Каталог в /tmp может быть смонтирован с noexec, что сломает makepkg.
  TMP_DIR="$(mktemp -d "${AUR_HOME}/yay-build.XXXXXX")"

  # Меняем владельца: makepkg не запускается от root.
  chown "${AUR_USER}:" "${TMP_DIR}"

  log "Клонирую репозиторий yay от имени ${AUR_USER}"
  # --depth=1 клонирует только последний коммит — быстрее, меньше трафика.
  run_as_user git clone --depth=1 https://aur.archlinux.org/yay.git "${TMP_DIR}/yay"

  log "Собираю yay (jobs: ${BUILD_JOBS})"
  # Передаём переменные через env, не через интерполяцию строки:
  # это безопасно если пути содержат пробелы или спецсимволы.
  # printf '%q' экранирует путь для безопасной передачи в bash -c.
  run_as_user env \
    MAKEFLAGS="-j${BUILD_JOBS}" \
    BUILDDIR="${AUR_CACHE_DIR}" \
    bash -c "cd $(printf '%q' "${TMP_DIR}/yay") && makepkg -s --noconfirm --needed"

  # Ищем собранный пакет. -printf '%T@ %p\n' выводит mtime + путь.
  # sort -rn + head -n1 берёт самый свежий файл.
  # Это защищает от ситуации, когда в каталоге остался пакет от старой сборки.
  local pkg_file=""
  pkg_file="$(find "${TMP_DIR}/yay" -maxdepth 1 -type f \
    \( -name 'yay-*.pkg.tar.zst' -o -name 'yay-*.pkg.tar.xz' \) \
    -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2-)"

  [[ -n "${pkg_file}" ]] || die "Не удалось найти собранный пакет yay в ${TMP_DIR}/yay"

  log "Устанавливаю yay от root: $(basename "${pkg_file}")"
  # pacman -U устанавливает локальный пакет — это единственное место где
  # установка от root необходима: pacman требует root, а makepkg его запретил.
  pacman -U --noconfirm "${pkg_file}"

  command -v yay >/dev/null 2>&1 || die "yay не обнаружен после установки — что-то пошло не так"
  YAY_AVAILABLE=true
  local yay_ver
  yay_ver="$(yay --version 2>&1 | head -n1 || true)"
  log "yay успешно установлен: ${yay_ver}"
}

# =============================================================================
# Установка пакетов
# =============================================================================

# install_repo_packages: устанавливает пакеты из REPO_TO_INSTALL через pacman.
# --needed: пропускает уже установленные пакеты (дополнительная страховка).
# --noconfirm: не задаёт интерактивных вопросов (нужно для unattended-режима).
install_repo_packages() {
  if (( ${#REPO_TO_INSTALL[@]} == 0 )); then
    log "Все repo-пакеты уже установлены, пропускаю"
    return 0
  fi

  log "Устанавливаю ${#REPO_TO_INSTALL[@]} repo-пакет(ов) через pacman"
  run_cmd pacman -S --needed --noconfirm "${REPO_TO_INSTALL[@]}"
}

# install_aur_packages: устанавливает AUR-пакеты через yay.
# Объединяет AUR_TO_INSTALL (проверенные) и AUR_UNKNOWN (непроверенные) в один вызов yay.
# Ключи yay:
#   --needed:       не переустанавливать уже актуальные пакеты.
#   --noconfirm:    не задавать вопросов.
#   --builddir:     каталог для временных файлов сборки.
#   --norebuild:    не пересобирать пакеты, если версия уже установлена.
#   --mflags:       дополнительные флаги для makepkg (параллельная компиляция).
#   --answerclean/diffview/edit None: автоответы на интерактивные вопросы yay.
install_aur_packages() {
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

  # Создаём каталог кеша от имени AUR_USER до запуска yay.
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

# is_sensitive_config: проверяет, входит ли запись "app:file" в SENSITIVE_CONFIGS.
# Если входит — файл будет скопирован с правами 600, а не 644.
is_sensitive_config() {
  local entry="$1"
  local s
  # Безопасный обход при set -u: если SENSITIVE_CONFIGS пуст,
  # ${arr[@]+"${arr[@]}"} раскрывается в пустоту вместо ошибки.
  for s in "${SENSITIVE_CONFIGS[@]+"${SENSITIVE_CONFIGS[@]}"}"; do
    [[ "${s}" == "${entry}" ]] && return 0
  done
  return 1
}

# backup_if_exists: создаёт резервную копию файла или каталога.
# Суффикс .bak.YYYYMMDD_HHMMSS делает каждую копию уникальной.
# Если цель не существует — молча возвращается без действий.
backup_if_exists() {
  local target="$1"
  # -e: обычный файл или каталог; -L: симлинк (может не иметь -e если сломан).
  [[ -e "${target}" || -L "${target}" ]] || return 0

  local backup="${target}.bak.$(date '+%Y%m%d_%H%M%S')"
  if $DRY_RUN; then
    log "    DRY-RUN: резервная копия  ${target}  →  $(basename "${backup}")"
  else
    # cp -a сохраняет права, временны́е метки, симлинки.
    # --remove-destination заменяет существующий .bak если имена совпали (редко).
    cp -a --remove-destination "${target}" "${backup}"
    log "    Резервная копия: $(basename "${backup}")"
  fi
}

# deploy_item: копирует один файл или каталог из src в dst.
# $3 = "sensitive" → chmod 600; иначе → chmod 644.
# Владелец файла всегда устанавливается в AUR_USER (скрипт запущен от root).
deploy_item() {
  local src="$1"
  local dst="$2"
  local mode="${3:-normal}"

  if [[ -d "${src}" ]]; then
    # Источник — каталог: копируем содержимое рекурсивно.
    # cp -a "${src}/." "${dst}/" копирует содержимое каталога (включая скрытые файлы),
    # не создавая лишний уровень вложенности.
    if $DRY_RUN; then
      log "    DRY-RUN: cp -a  ${src}/  →  ${dst}/"
    else
      mkdir -p "${dst}"
      cp -a "${src}/." "${dst}/"
      # Меняем владельца рекурсивно — файлы были созданы от root.
      chown -R "${AUR_USER}:" "${dst}"
      log "    Каталог: ${dst}/"
    fi
  else
    # Источник — одиночный файл.
    if $DRY_RUN; then
      local perm; [[ "${mode}" == "sensitive" ]] && perm="600" || perm="644"
      log "    DRY-RUN: cp  ${src}  →  ${dst}  (${perm})"
    else
      # mkdir -p создаёт все промежуточные каталоги если их нет.
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

# deploy_configs: главная функция развёртывания конфигов.
# Для каждой записи в CONFIG_FILES:
#   1. Проверяет наличие источника в CONFIGS_SRC/.
#   2. Создаёт резервную копию существующего файла в ~/.config/.
#   3. Копирует новый файл с нужными правами (600 или 644).
deploy_configs() {
  log "-------------------------------------------------------"
  log "Развёртывание конфигурационных файлов"
  log "  Источник:    ${CONFIGS_SRC}"
  log "  Назначение:  ${AUR_HOME}/.config/"
  log "-------------------------------------------------------"

  # Проверяем существование каталога-источника.
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
    # Разбиваем "приложение:файл" на части.
    # ${var%%:*} — всё до первого двоеточия (имя приложения).
    # ${var##*:} — всё после последнего двоеточия (имя файла).
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

    # Создаём резервную копию существующего файла перед заменой.
    backup_if_exists "${dst}"

    # Определяем режим прав: 600 для чувствительных, 644 для остальных.
    local mode="normal"
    is_sensitive_config "${entry}" && mode="sensitive"

    deploy_item "${src}" "${dst}" "${mode}"
    (( deployed++ )) || true
  done

  echo
  log "Конфиги: развёрнуто — ${deployed}, пропущено (нет источника) — ${skipped}"

  # Отдельное напоминание про rclone.conf — содержит токены доступа.
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

  # Скрипт должен выполняться от root — pacman и системные операции требуют прав.
  [[ $EUID -eq 0 ]] || die "Скрипт нужно запускать от root (через sudo или напрямую)"

  # Проверяем, что мы на Arch Linux (pacman должен быть в PATH).
  command -v pacman >/dev/null 2>&1 \
    || die "pacman не найден. Скрипт предназначен только для Arch Linux."

  # Проверяем блокировку базы данных pacman.
  # db.lck создаётся при запуске pacman и означает, что другой экземпляр уже работает.
  # Запуск двух экземпляров одновременно повредит базу данных.
  [[ ! -e /var/lib/pacman/db.lck ]] \
    || die "База pacman заблокирована (/var/lib/pacman/db.lck). \
Убедись, что pacman не запущен, и удали файл блокировки вручную."

  # Инициализируем лог-файл до exec-редиректа (иначе tee упадёт если нет файла).
  touch "${LOG_FILE}" 2>/dev/null \
    || die "Не могу создать лог-файл: ${LOG_FILE}. Проверь права на /var/log/."

  # Ограничиваем доступ к логу: он может содержать имена пользователей и пути.
  if ! chmod 600 "${LOG_FILE}" 2>/dev/null; then
    warn "Не удалось установить права 600 на ${LOG_FILE}"
  fi

  # Перенаправляем весь вывод (stdout + stderr) в лог и на терминал одновременно.
  # exec > >(tee -a ...) 2>&1 — любой echo/printf в любой функции пойдёт в лог.
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

  # makepkg запрещает сборку от root — это мера безопасности самого makepkg.
  # Конфиги тоже не должны принадлежать root.
  [[ "${AUR_USER}" != "root" ]] \
    || die "Нельзя использовать root. \
Укажи непривилегированного пользователя через --aur-user."

  # Проверяем что пользователь реально существует в системе.
  id "${AUR_USER}" >/dev/null 2>&1 \
    || die "Пользователь '${AUR_USER}' не существует в системе."

  # getent читает /etc/passwd напрямую — надёжнее чем $HOME при sudo,
  # где переменная HOME может указывать на каталог root.
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
  # (trap EXIT в таком случае не выполняется — сигнал KILL нельзя перехватить).
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

    # 3. Классифицируем repo-пакеты (не требует yay).
    split_repo_packages

    # 4. Устанавливаем yay если его нет, затем классифицируем AUR-пакеты.
    #    Порядок важен: yay нужен для точной проверки через yay -Si.
    install_yay_if_needed
    split_aur_packages

    # Вывод плана установки — показывается перед реальными действиями.
    # Синтаксис ${arr[@]+"${arr[@]}"} безопасен при set -u и пустом массиве.
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
    # Лучше упасть сейчас с понятной ошибкой, чем в середине установки.
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
  # Финальная верификация (только в реальном режиме, dry-run не трогает систему)
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
