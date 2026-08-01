#!/usr/bin/env bash
#
# packages.sh - 软件包清单
# ============================================
# 由 install.sh 加载, 定义所有软件包分类变量。
# 所有软件包在 PHASE 3 中通过一次 pacstrap -K 调用完成安装。
# 基于 Arch Linux extra 仓库 GNOME 50.x 版本组织。
#
# 注意: 本文件被 source 加载, 不要直接执行。

# ============================================================================
# 分类说明:
#
# ── 基础系统 ──────────────────────────────────────────
#
# 1) BASE — 基础系统
#    base:           Arch Linux 核心包 (glibc, bash, coreutils 等)
#    base-devel:     编译工具链 (gcc, make, automake, pkg-config 等)
#    linux:          Linux 内核
#    linux-firmware: 硬件固件 (Wi-Fi, GPU, 声卡等驱动)
#
# 2) SYSTEM — 系统工具
#    sudo:           普通用户提权
#    nano:           文本编辑器
#    networkmanager: 网络管理 (Wi-Fi/有线/VPN)
#    refind:         rEFInd UEFI 引导管理器 (主选)
#    grub:           GRUB 引导加载程序 (rEFInd 失败时回退)
#    efibootmgr:     EFI 引导条目管理
#    bash-completion: 自动补全增强
#    man-db / man-pages: 手册页
#    btrfs-progs:    btrfs 文件系统工具
#    archlinuxcn-keyring: archlinuxcn 仓库 GPG 密钥环
#    plymouth:       开机动画
#    reflector:      镜像源优化
#    zram-generator: zram 压缩内存交换
#    ufw / openssh:  防火墙 + SSH 服务端
#    timeshift:      系统快照与回滚 (btrfs 模式)
#    字体: noto-fonts*, ttf-liberation, ttf-dejavu
#
# ── 桌面环境 (GNOME + 第三方应用) ──────────────────────────
#
# 3) GNOME — GNOME Group (Arch Linux gnome group)
#    桌面核心:  gdm / gnome-shell / session / settings-daemon / control-center
#    文件与磁盘: nautilus / gnome-disk-utility / baobab / sushi / papers / gvfs*
#    图片与媒体: loupe / snapshot / showtime / decibels / gnome-music
#    网络与地图: gnome-connections / gnome-remote-desktop / gnome-maps / gnome-weather
#    日常工具:  gnome-calculator / calendar / clocks / contacts / characters / text-editor
#    系统组件:  gnome-backgrounds / gnome-user-docs / gnome-system-monitor / orca
#    媒体框架:  grilo-plugins / gst-thumbnailers / malcontent / rygel / simple-scan / tecla
#    桌面门户:  xdg-desktop-portal-gnome / xdg-user-dirs-gtk / yelp
#    工具:      gnome-color-manager / gnome-font-viewer / gnome-keyring / gnome-logs
#               gnome-menus / gnome-user-share / gnome-tour
#    清单来源: https://archlinux.org/groups/x86_64/gnome/
#
# 4) GNOME_EXTRA — GNOME 扩展与补充 (不在上述清单中)
#    Shell 扩展: gnome-shell-extensions / dash-to-dock / appindicator / desktop-icons-ng
#    补充应用:   gnome-boxes / gnome-firmware / gnome-initial-setup / gnome-tweaks
#                gnome-video-effects / file-roller / ptyxis / seahorse
#
# 5) THIRD_PARTY — 第三方应用
#    firefox:        Mozilla Firefox 浏览器
#    firefox-i18n-zh-cn:  Firefox 简体中文语言包
#    libreoffice-still:    LibreOffice 稳定版办公套件
#    libreoffice-still-zh-cn: 简体中文语言包
#    pamac-aur:      图形化包管理器 (AUR 支持)
#    ibus / ibus-libpinyin: 拼音输入法
#    papirus-icon-theme:   Papirus 图标主题
#    cups* / avahi / nss-mdns / power-profiles-daemon: 打印 / mDNS / 电源

readonly PACKAGES_BASE="
    base
    base-devel
    linux
    linux-firmware
"

readonly PACKAGES_SYSTEM="
    sudo
    nano
    networkmanager
    refind
    grub
    efibootmgr
    bash-completion
    man-db
    man-pages
    btrfs-progs
    archlinuxcn-keyring
    plymouth
    reflector
    zram-generator
    ufw
    openssh
    timeshift
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    noto-fonts-extra
    ttf-liberation
    ttf-dejavu
"

readonly PACKAGES_GNOME="
    gdm
    gnome-shell
    gnome-session
    gnome-settings-daemon
    gnome-control-center
    gnome-keyring
    gnome-menus
    nautilus
    gnome-disk-utility
    baobab
    sushi
    papers
    gvfs
    gvfs-afc
    gvfs-goa
    gvfs-smb
    gvfs-mtp
    gvfs-nfs
    gvfs-onedrive
    gvfs-gphoto2
    gvfs-dnssd
    gvfs-wsdd
    loupe
    snapshot
    showtime
    decibels
    gnome-music
    gnome-connections
    gnome-remote-desktop
    gnome-maps
    gnome-weather
    gnome-calculator
    gnome-calendar
    gnome-characters
    gnome-clocks
    gnome-color-manager
    gnome-contacts
    gnome-font-viewer
    gnome-logs
    gnome-system-monitor
    gnome-text-editor
    gnome-tour
    gnome-user-share
    gnome-backgrounds
    gnome-user-docs
    orca
    grilo-plugins
    gst-thumbnailers
    malcontent
    rygel
    simple-scan
    tecla
    xdg-desktop-portal-gnome
    xdg-user-dirs-gtk
    yelp
"

readonly PACKAGES_GNOME_EXTRA="
    gnome-shell-extensions
    gnome-shell-extension-dash-to-dock
    gnome-shell-extension-appindicator
    gnome-shell-extension-desktop-icons-ng
    gnome-browser-connector
    file-roller
    gnome-boxes
    gnome-firmware
    gnome-initial-setup
    gnome-video-effects
    ptyxis
    seahorse
    gnome-tweaks
"

readonly PACKAGES_THIRD_PARTY="
    firefox
    firefox-i18n-zh-cn
    libreoffice-still
    libreoffice-still-zh-cn
    pamac-aur
    ibus
    ibus-libpinyin
    papirus-icon-theme
    cups
    cups-filters
    system-config-printer
    power-profiles-daemon
    avahi
    nss-mdns
"
