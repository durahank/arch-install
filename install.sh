#!/usr/bin/env bash
#
# install.sh - Arch Linux 手动安装脚本
# ============================================
#
# 一个独立的脚本, 执行完整的 Arch Linux 手动安装流程。
# 不依赖 archinstall 工具, 全程使用原始命令。
#
# 使用方法:
#   从 Arch 官方 ISO 启动后, 执行:
#       bash install.sh

set -euo pipefail

# ============================================================================
# 颜色定义 - 用于区分不同类型的输出信息
# ============================================================================
# 使用 ANSI 转义码为输出着色, 方便快速区分信息类型

readonly RESET='\033[0m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'

# 输出辅助函数 — 同时输出到终端和日志文件
#
# info():   绿色 [INFO]  标签, 记录正常进度
# warn():   黄色 [WARN]  标签, 记录需要注意的事件
# error():  红色 [ERROR] 标签, 记录致命错误
# header(): 青色分隔线, 标注大阶段切换
# phase():  青色 "==="  标签, 标注子阶段名称

info()    { local m="$*"; echo -e "${GREEN}[INFO]${RESET}  $m"; _log "INFO"  "$m"; }
warn()    { local m="$*"; echo -e "${YELLOW}[WARN]${RESET}  $m"; _log "WARN"  "$m"; }
error()   { local m="$*"; echo -e "${RED}[ERROR]${RESET} $m"; _log "ERROR" "$m"; }
header()  { echo -e "\n${CYAN}==================================================${RESET}"; _log "STEP" "──────────────────────────────────────────────"; }
phase()   { local m="$*"; echo -e "${CYAN}=== ${BOLD}$m${RESET}"; _log "STEP" "=== $m"; }

# 内部状态变量 - 在安装过程中填充
TARGET_DISK=""
EFI_PART=""
ROOT_PART=""
PART_PREFIX=""
MOUNT_POINT="/mnt"
FORMAT_ESP=true   # 是否格式化 ESP (全盘=true, 共存/重装复用=false)
INSTALL_DESKTOP=true # 是否安装桌面环境 (GNOME + THIRD_PARTY), 设为 false 仅部署基础系统
INSTALL_ROCM=false   # 是否安装 ROCm (AMD GPU 计算平台, 添加约 1.5GB 软件包)

# ============================================================================
# 日志系统配置
# ============================================================================
# 所有输出同时写入终端和日志文件, 方便调试时回溯每个步骤的执行情况。
# 日志文件包含时间戳、日志级别和完整命令输出。
#
# 日志文件位置:
#   /tmp/arch-install-<时间戳>.log  (live 环境)
#   脚本运行完后保留在此路径, 如需留存请手动复制

LOG_START_TIME="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/arch-install-${LOG_START_TIME}.log"

# 初始化日志文件, 写入头部信息
_log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    {
        echo "============================================"
        echo " install.sh 安装日志"
        echo " 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " 主机名:   $(hostname)"
        echo " 内核:     $(uname -r)"
        echo "============================================"
        echo ""
    } > "$LOG_FILE"
    # 第一阶段日志已就绪, 但此时 /mnt 还未挂载, 暂不复制到目标
}

# 带时间戳的日志写入函数
# 同时写入日志文件和输出到终端
_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${msg}" >> "$LOG_FILE"
}

# 记录命令执行: 先写命令本身, 再捕获输出
# 用法: run_cmd command arg1 arg2...
# 如果命令失败, 会自动记录退出码并调用 error 退出
run_cmd() {
    local cmd_desc="$*"
    _log "CMD" "${cmd_desc}"
    echo "" >> "$LOG_FILE"

    # 创建一个临时文件捕获命令的输出
    local cmd_log
    cmd_log="$(mktemp /tmp/arch-install-cmd-XXXXXX.log)"

    # 执行命令, 同时输出到终端和临时日志
    set +e
    "$@" 2>&1 | tee -a "$cmd_log"
    local exit_code="${PIPESTATUS[0]}"
    set -e

    # 将命令输出合并到主日志
    cat "$cmd_log" >> "$LOG_FILE"
    rm -f "$cmd_log"

    if [ "$exit_code" -ne 0 ]; then
        echo "--- LOG FILE: ${LOG_FILE} ---" >&2
        error "Command failed (exit code ${exit_code}). See log: ${LOG_FILE}"
        exit "$exit_code"
    fi

    _log "OK" "${cmd_desc} completed"
    echo "" >> "$LOG_FILE"
}

# 尝试执行命令 — 失败时仅警告, 不退出脚本
# 用法: try_cmd description command arg1 arg2...
# 用于非关键配置操作 (如 gsettings、符号链接、字体配置等)
try_cmd() {
    local desc="$1"
    shift
    local cmd_desc="$*"
    _log "TRY" "${desc}: ${cmd_desc}"

    set +e
    "$@" &>/dev/null
    local exit_code="$?"
    set -e

    if [ "$exit_code" -ne 0 ]; then
        warn "${desc} skipped (exit code ${exit_code})"
        _log "SKIP" "${desc} failed (exit code ${exit_code})"
    else
        info "OK: ${desc}"
        _log "OK" "${desc} completed"
    fi
}

# ============================================================================
# 软件包清单 - GNOME 50 系列, 按类别分组, 一次性传递给 pacstrap
# ============================================================================
# 所有软件包在 PHASE 3 中通过一次 pacstrap -K 调用完成安装。
# 基于 Arch Linux extra 仓库 GNOME 50.x 版本组织。
#
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

# ============================================================================
# PHASE 0 - 安装前检查
# ============================================================================
# 在实际修改磁盘前, 确认运行环境满足以下条件:
#   - root 权限 (大部分操作需要)
#   - UEFI 模式 (脚本仅支持 UEFI)
#   - 网络连通 (pacman 需要下载包)
#   - 时钟同步 (避免 SSL 证书验证失败)

phase_0_preflight() {
    header
    phase "PHASE 0: Pre-installation Checks"
    echo ""

    # 检查 root 权限
    # 分区、挂载、pacstrap、chroot 等操作均需要 root 权限
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root."
        exit 1
    fi
    info "OK: Running as root"

    # 检查 UEFI 模式
    # 通过检测 /sys/firmware/efi/efivars 的存在来判断
    # 该目录是内核虚拟文件系统, 仅在 UEFI 启动时存在
    if [ ! -d /sys/firmware/efi/efivars ]; then
        error "UEFI mode not detected."
        exit 1
    fi
    info "OK: UEFI mode confirmed"

    # 检查网络连接
    # 先尝试 ping, 如果失败则改用 curl 进行 HTTP 检查
    # 某些网络环境可能禁用了 ICMP
    info "Checking internet connectivity..."
    if ! ping -c 2 -W 5 archlinux.org &>/dev/null; then
        warn "ping failed, trying curl..."
        if ! curl -s --max-time 10 https://archlinux.org > /dev/null 2>&1; then
            error "No internet connection detected."
            exit 1
        fi
    fi
    info "OK: Internet is reachable"

    # 同步系统时钟
    # 准确的系统时间对 TLS 证书验证和包签名检查至关重要
    info "Synchronising system clock..."
    try_cmd "Synchronising system clock" timedatectl set-ntp true
    info "OK: Clock synchronised ($(date))"
    echo ""
}

# ============================================================================
# PHASE 1 - 磁盘选择与分区
# ============================================================================
# 支持三种安装模式:
#
#   全盘模式 (full):
#     清空整块磁盘, 创建全新 GPT 分区表, 划分 ESP + 根分区。
#     适用于全新安装或不需要保留任何数据的场景。
#
#   共存模式 (coexist):
#     保留已有分区表和其他系统, 在空闲空间中创建新分区。
#     自动检测并复用已有的 EFI 系统分区 (ESP), 避免破坏其他引导项。
#     适用于双系统 (如与 Windows/其他 Linux 共存) 或多系统安装。
#
#   重装模式 (reinstall):
#     通过检测卷标为 "Arch" 的 btrfs 分区自动识别现有安装。
#     仅格式化 root 分区, 保留 ESP 不变, 快速重新安装系统。
#
# 分区布局 (全盘模式):
#   Partition 1: ESP (FAT32, 1 GiB, /boot/efi)
#   Partition 2: root (btrfs, 剩余空间)

phase_1_partition() {
    header
    phase "PHASE 1: Disk Partitioning"
    echo ""

    # ==================================================================
    # 步骤 1: 选择目标磁盘
    # ==================================================================

    if [ -z "$TARGET_DISK" ]; then
        echo "Available block devices:"
        echo ""
        # 列出磁盘并编号
        DISK_LIST=()
        DISK_NAMES=()
        while IFS= read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            DISK_NAMES+=("$name")
            DISK_LIST+=("$line")
        done < <(lsblk -o NAME,SIZE,TYPE -d -n 2>/dev/null | grep ' disk$')

        # 如果只扫描到一个磁盘, 自动选中
        if [ ${#DISK_LIST[@]} -eq 1 ]; then
            TARGET_DISK="/dev/${DISK_NAMES[0]}"
            info "Only one disk found: ${BOLD}$TARGET_DISK${RESET} — selected automatically"
        else
            for i in "${!DISK_LIST[@]}"; do
                echo "  $((i+1))) ${DISK_LIST[$i]}"
            done
            echo ""
            read -r -p "Enter disk number (1-${#DISK_LIST[@]}): " DISK_NUM
            # 验证输入为正整数
            if [ -z "$DISK_NUM" ] || ! [[ "$DISK_NUM" =~ ^[0-9]+$ ]] || \
               [ "$DISK_NUM" -lt 1 ] || [ "$DISK_NUM" -gt "${#DISK_LIST[@]}" ]; then
                error "Invalid selection. Aborting."
                exit 1
            fi
            TARGET_DISK="/dev/${DISK_NAMES[$((DISK_NUM-1))]}"
        fi
    fi

    if [ ! -b "$TARGET_DISK" ]; then
        error "Device $TARGET_DISK does not exist or is not a block device."
        try_cmd "Listing block devices" lsblk -d
        exit 1
    fi
    info "Target disk: ${BOLD}$TARGET_DISK${RESET}"
    echo ""

    # 确定分区命名规则 (NVMe / MMC / VirtIO / SATA)
    if echo "$TARGET_DISK" | grep -qP '/dev/nvme'; then
        PART_PREFIX="${TARGET_DISK}p"
    elif echo "$TARGET_DISK" | grep -qP '/dev/mmcblk'; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="$TARGET_DISK"
    fi

    # ==================================================================
    # 步骤 2: 检测现有 Arch 安装 (通过卷标)
    # ==================================================================
    # 如果存在卷标为 "Arch" 的 btrfs 分区, 表示之前通过本脚本安装过。
    # 此时提供 "重装" 选项: 格式化该分区重新安装, 保留 ESP 不变。

    EXISTING_ARCH_ROOT=""
    EXISTING_ARCH_ROOT=$(blkid -L Arch 2>/dev/null || lsblk -o LABEL,PATH -nl 2>/dev/null | \
        awk '/^Arch/ {print $2; exit}')

    if [ -n "$EXISTING_ARCH_ROOT" ] && [ -b "$EXISTING_ARCH_ROOT" ]; then
        # 找到同一磁盘上的 ESP
        EXISTING_ARCH_DISK=""
        # shellcheck disable=SC2001 # sed 比 bash 参数替换更清晰易读
        if echo "$EXISTING_ARCH_ROOT" | grep -qP '/dev/nvme'; then
            EXISTING_ARCH_DISK=$(echo "$EXISTING_ARCH_ROOT" | sed 's/p[0-9]*$//')
        elif echo "$EXISTING_ARCH_ROOT" | grep -qP '/dev/mmcblk'; then
            EXISTING_ARCH_DISK=$(echo "$EXISTING_ARCH_ROOT" | sed 's/p[0-9]*$//')
        else
            EXISTING_ARCH_DISK=$(echo "$EXISTING_ARCH_ROOT" | sed 's/[0-9]*$//')
        fi

        EXISTING_ARCH_ESP=$(parted "$EXISTING_ARCH_DISK" -- print 2>/dev/null | \
            awk '/fat32/ && /esp/ {print $1}' | head -1)
        if [ -n "$EXISTING_ARCH_ESP" ]; then
            if echo "$EXISTING_ARCH_DISK" | grep -qP '/dev/nvme|/dev/mmcblk'; then
                EXISTING_ARCH_ESP="${EXISTING_ARCH_DISK}p${EXISTING_ARCH_ESP}"
            else
                EXISTING_ARCH_ESP="${EXISTING_ARCH_DISK}${EXISTING_ARCH_ESP}"
            fi
        fi

        echo ""
        info "Detected existing Arch installation:"
        info "  Root partition: ${BOLD}${EXISTING_ARCH_ROOT}${RESET} (label: Arch)"
        if [ -n "$EXISTING_ARCH_ESP" ]; then
            info "  ESP:            ${BOLD}${EXISTING_ARCH_ESP}${RESET}"
        fi
        echo ""
        echo "  3) Reinstall     — Format existing Arch root, keep ESP intact"
        echo ""
    else
        EXISTING_ARCH_ROOT=""
    fi

    # ==================================================================
    # 步骤 3: 选择安装模式
    # ==================================================================

    echo ""
    echo "Select installation mode:"
    echo "  1) Full disk      — Wipe entire disk, create fresh GPT layout"
    echo "  2) Coexist        — Install alongside existing OS (preserve other partitions)"
    if [ -n "$EXISTING_ARCH_ROOT" ]; then
        echo "  3) Reinstall      — Format existing Arch partition ($EXISTING_ARCH_ROOT), reuse ESP"
    fi
    echo ""
    read -r -p "Enter choice (1/2${EXISTING_ARCH_ROOT:+/3}): " INSTALL_MODE

    case "$INSTALL_MODE" in
        3)
            phase_1_reinstall
            ;;
        2)
            phase_1_coexist
            ;;
        *)
            phase_1_full
            ;;
    esac

    # 等待内核重新读取分区表
    sleep 1
    echo ""
    info "OK: Partition layout:"
    lsblk "$TARGET_DISK" | tail -n +2
    echo ""
}

# ======================================================================
# 全盘安装 — 清空整盘, 创建全新分区布局
# ======================================================================

phase_1_full() {
    echo ""
    warn "WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!"
    lsblk "$TARGET_DISK"
    echo ""
    read -r -p "Type YES to confirm (any other input aborts): " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES)
            info "Confirmed. Proceeding..."
            ;;
        *)
            info "Aborted by user."
            exit 0
            ;;
    esac
    echo ""

    # 清除现有分区表和文件系统签名
    info "Wiping existing partition table and filesystem signatures..."
    wipefs -a "$TARGET_DISK" >/dev/null 2>&1 || warn "wipefs returned non-zero (may be ok)"
    info "OK: Wipe complete"

    # 创建 GPT 分区表
    info "Creating GPT partition table..."
    parted "$TARGET_DISK" -- mklabel gpt
    info "OK: GPT label created"

    EFI_PART="${PART_PREFIX}1"

    # 创建 ESP (EFI System Partition)
    info "Creating EFI System Partition (1 GiB)..."
    parted "$TARGET_DISK" -- mkpart primary fat32 1MiB 1025MiB
    parted "$TARGET_DISK" -- set 1 esp on
    info "OK: ESP created at $EFI_PART"

    # 创建 root
    phase_1_create_root "1025MiB"
}

# ======================================================================
# 重装模式 — 复用已分区, 仅格式化现有 Arch root, 保留 ESP
# ======================================================================
# 检测到卷标为 "Arch" 的现有分区时可用。
# 不执行任何分区操作, 直接复用检测到的 ROOT_PART 和 EFI_PART,
# 后续 Phase 2 会格式化 root 分区并重建子卷。

phase_1_reinstall() {
    echo ""
    warn "This will FORMAT the existing Arch root partition: ${EXISTING_ARCH_ROOT}"
    warn "All data on this partition will be LOST!"
    lsblk "$EXISTING_ARCH_ROOT"
    echo ""
    read -r -p "Type YES to confirm (any other input aborts): " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES)
            info "Confirmed. Proceeding..."
            ;;
        *)
            info "Aborted by user."
            exit 0
            ;;
    esac
    echo ""

    ROOT_PART="$EXISTING_ARCH_ROOT"

    if [ -n "$EXISTING_ARCH_ESP" ]; then
        EFI_PART="$EXISTING_ARCH_ESP"
        FORMAT_ESP=false
        info "Reusing existing ESP: $EFI_PART"
    else
        # 如果没有找到 ESP, 尝试在同一磁盘上查找
        info "Searching for ESP on the same disk..."
        local esp_num
        esp_num=$(parted "$EXISTING_ARCH_DISK" -- print 2>/dev/null | \
            awk '/fat32/ && /esp/ {print $1; exit}')
        if [ -n "$esp_num" ]; then
            if echo "$EXISTING_ARCH_DISK" | grep -qP '/dev/nvme|/dev/mmcblk'; then
                EFI_PART="${EXISTING_ARCH_DISK}p${esp_num}"
            else
                EFI_PART="${EXISTING_ARCH_DISK}${esp_num}"
            fi
            info "Found ESP: $EFI_PART"
            FORMAT_ESP=false
        else
            warn "No ESP found. You may need to set up boot manually."
        fi
    fi

    info "OK: Reinstall mode ready"
    info "  Root: $ROOT_PART (will be formatted)"
    info "  ESP:  $EFI_PART (kept intact)"
    echo ""
}

# ======================================================================
# 共存安装 — 保留已有分区, 在空闲空间创建新分区
# ======================================================================

phase_1_coexist() {
    echo ""
    info "Analyzing existing partition layout..."

    # 显示已有分区 + 空闲空间 (MiB 单位, 与后续手动输入单位一致)
    parted "$TARGET_DISK" -- unit MiB print free 2>/dev/null || parted "$TARGET_DISK" print
    echo ""

    # 检测是否存在 ESP
    EXISTING_ESP=$(parted "$TARGET_DISK" -- print 2>/dev/null | \
        awk '/fat32/ && /esp/ {print $1; exit}' | sed 's/^[[:space:]]*//')
    if [ -n "$EXISTING_ESP" ]; then
        EFI_PART="${PART_PREFIX}${EXISTING_ESP}"
        FORMAT_ESP=false
        info "Existing ESP found: ${EFI_PART} — will reuse (new ESP will NOT be created)"
    else
        warn "No existing ESP detected. A new ESP (1 GiB) will be created in free space."
    fi
    echo ""

    # 列出空闲空间 (free space) 区域
    info "Available free space regions on $TARGET_DISK:"
    parted "$TARGET_DISK" -- unit MiB print free 2>/dev/null | \
        grep -E '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+' | \
        grep -i 'free' || echo "  (No free space detected or already partitioned)"

    echo ""
    echo "Choose how to allocate space:"
    echo "  1) Use all available free space (auto)"
    echo "  2) Manual: specify start sector for new root partition"
    echo ""
    read -r -p "Enter choice (1 or 2): " SPACE_CHOICE

    case "$SPACE_CHOICE" in
        2)
            read -r -p "Enter START sector in MiB (e.g., 1024): " FREE_START
            # 校验: 必须为正整数
            if [ -z "$FREE_START" ] || ! [[ "$FREE_START" =~ ^[0-9]+$ ]]; then
                error "Invalid START sector. Must be a positive integer (MiB)."
                exit 1
            fi
            FREE_START="${FREE_START}MiB"
            read -r -p "Enter END sector in MiB (e.g., 100% or 51200): " FREE_END
            # 校验: 允许 "100%" 或正整数
            if [ "$FREE_END" != "100%" ] && \
               { [ -z "$FREE_END" ] || ! [[ "$FREE_END" =~ ^[0-9]+$ ]]; }; then
                error "Invalid END sector. Must be '100%' or a positive integer (MiB)."
                exit 1
            fi
            ;;
        *)
            # 自动检测最后一个空闲区域的起始位置
            FREE_START=$(parted "$TARGET_DISK" -- unit MiB print free 2>/dev/null | \
                grep -i 'free' | tail -1 | awk '{print $1}')
            FREE_END="100%"

            if [ -z "$FREE_START" ]; then
                warn "Could not auto-detect free space. Falling back to manual input."
                read -r -p "Enter START sector in MiB (e.g., after last partition): " FREE_START
                if [ -z "$FREE_START" ] || ! [[ "$FREE_START" =~ ^[0-9]+$ ]]; then
                    error "Invalid START sector. Must be a positive integer (MiB)."
                    exit 1
                fi
                FREE_START="${FREE_START}MiB"
                FREE_END="100%"
            else
                # FREE_START 从 parted 输出已包含 "MiB" 后缀, 避免重复追加
                case "$FREE_START" in
                    *MiB) ;;
                    *)    FREE_START="${FREE_START}MiB" ;;
                esac
                info "  -> Using free space: ${FREE_START} to ${FREE_END}"
            fi
            ;;
    esac
    echo ""

    # 如果有现成 ESP, 直接创建 root; 否则先创建 ESP
    if [ -z "$EXISTING_ESP" ]; then
        # 需要一个新的 ESP
        ESP_SIZE="1024"
        ESP_MIB=$(echo "$FREE_START" | sed 's/MiB//' | awk '{print int($1)}')
        ESP_END=$((ESP_MIB + ESP_SIZE))
        EFI_PART="${PART_PREFIX}$(parted "$TARGET_DISK" -- print 2>/dev/null | \
            awk '/^[[:space:]]*[0-9]+/ {num=$1} END {print num+1}')"

        info "Creating new ESP (1 GiB) starting at ${FREE_START}..."
        parted "$TARGET_DISK" -- mkpart primary fat32 "${ESP_MIB}MiB" "${ESP_END}MiB"
        parted "$TARGET_DISK" -- set "$(echo "$EFI_PART" | grep -oP '[0-9]+$')" esp on
        info "OK: New ESP created at $EFI_PART"

        # 更新剩余空间起始位置
        FREE_START="${ESP_END}MiB"
    fi

    # 在剩余空闲空间中创建 root
    phase_1_create_root "$FREE_START" "$FREE_END"
}

# ======================================================================
# 在指定起始位置创建 root 分区
# 参数: $1 = 起始位置 (如 "1025MiB", "10000MiB")
#       $2 = 结束位置 (如 "100%", "51200MiB"), 默认 "100%"
# ======================================================================

phase_1_create_root() {
    local start_pos="$1"
    local end_pos="${2:-100%}"

    # 计算下一个可用分区号
    local next_num
    next_num=$(parted "$TARGET_DISK" -- print 2>/dev/null | \
        awk '/^[[:space:]]*[0-9]+/ {num=$1} END {print num+1}')
    if [ -z "$next_num" ] || [ "$next_num" -lt 1 ]; then
        next_num=1
    fi

    # 创建 root 分区 (btrfs)
    ROOT_PART="${PART_PREFIX}${next_num}"
    info "Creating root partition (btrfs) starting at ${start_pos}..."
    parted "$TARGET_DISK" -- mkpart primary btrfs "${start_pos}" "${end_pos}"

    info "OK: Partitions created:"
    parted "$TARGET_DISK" -- print 2>/dev/null | grep -E "^[[:space:]]*[0-9]+"
    echo ""
}

# ============================================================================
# PHASE 2 - 格式化和挂载 (btrfs + 子卷)
# ============================================================================
# 在新创建的分区上创建 btrfs 文件系统, 然后创建子卷布局:
#
#   子卷             挂载点                  作用
#   ──────────────   ────────────────────   ──────────────────────
#   @                /                      根文件系统
#   @home            /home                  用户数据
#   @log             /var/log               系统日志
#   @pkg             /var/cache/pacman/pkg  pacman 包缓存
#   [ESP]            /boot/efi              EFI 系统分区 (FAT32, 独立分区)
#
# 这种布局的优势:
#   - @log 和 @pkg 独占子卷, 快照时自动排除
#   - Timeshift 在 btrfs 模式下同时备份 @ 和 @home 子卷

phase_2_format_and_mount() {
    header
    phase "PHASE 2: Formatting and Mounting (btrfs + subvolumes)"
    echo ""

    # 格式化/复用 EFI 分区
    # 全盘模式: 新创建的 ESP 需要格式化
    # 共存/重装模式: 复用已有 ESP, 保留其引导项和文件
    if [ "$FORMAT_ESP" = true ]; then
        info "Formatting EFI partition ($EFI_PART) as FAT32..."
        mkfs.fat -F32 "$EFI_PART" &>/dev/null
        info "OK: ESP formatted as FAT32"
    else
        info "Reusing existing ESP ($EFI_PART) — skipping format (boot entries preserved)"
    fi

    # 格式化根分区为 btrfs, 卷标设为 "Arch"
    # btrfs 支持子卷、快照、压缩、校验和等高级功能
    # -f: 强制格式化 (覆盖已有文件系统)
    # -L Arch: 设置文件系统卷标, 用于后续识别和重装检测
    info "Formatting root partition ($ROOT_PART) as btrfs (label: Arch)..."
    mkfs.btrfs -f -L Arch "$ROOT_PART" &>/dev/null
    info "OK: Root partition formatted as btrfs (label: Arch)"

    # 第一步: 将 btrfs 分区挂载到一个临时位置
    # 因为子卷需要在 btrfs 文件系统上创建, 所以必须先挂载顶层卷
    info "Mounting btrfs top-level to create subvolumes..."
    mount "$ROOT_PART" "$MOUNT_POINT"
    info "OK: btrfs top-level mounted"

    # 第二步: 创建 Arch 官方推荐的子卷布局
    # 每个子卷都是一个独立的挂载点, 可以独立设置挂载选项和 CoW 策略
    # 子卷名前的 @ 前缀是社区惯例, 用于快速识别子卷用途
    info "Creating btrfs subvolumes..."
    echo ""

    # @: 根文件系统 — 包含 /usr, /etc, /bin 等系统文件和目录
    echo "  Creating subvolume: @          (/)"
    btrfs subvolume create "${MOUNT_POINT}/@" &>/dev/null

    # @home: 用户数据目录 — 快照时排除, 回滚系统不影响用户文件
    echo "  Creating subvolume: @home      (/home)"
    btrfs subvolume create "${MOUNT_POINT}/@home" &>/dev/null

    # @log: 系统日志 — 日志文件频繁变化, 单独子卷可避免快照膨胀
    echo "  Creating subvolume: @log       (/var/log)"
    btrfs subvolume create "${MOUNT_POINT}/@log" &>/dev/null

    # @pkg: pacman 包缓存 — 下载的包文件占用大量空间, 排除在快照外
    echo "  Creating subvolume: @pkg       (/var/cache/pacman/pkg)"
    btrfs subvolume create "${MOUNT_POINT}/@pkg" &>/dev/null

    echo ""
    info "OK: All subvolumes created"

    # 第三步: 卸载 btrfs 顶层卷
    # 接下来要用正确的子卷路径重新挂载各个子卷
    info "Unmounting btrfs top-level..."
    umount "$MOUNT_POINT"

    # 第四步: 按子卷重新挂载到正确的位置
    # 挂载选项说明:
    #   compress=zstd:3     — 使用 zstd 压缩 (级别 3), 节省磁盘空间且性能影响小
    #   space_cache=v2      — 使用新版空闲空间缓存 (btrfs 推荐)
    #   autodefrag          — 自动碎片整理 (适合桌面使用场景)
    #   subvol=@xxx         — 指定挂载哪个子卷
    echo ""
    info "Mounting subvolumes with optimized btrfs options..."
    echo ""

    BTRFS_OPTS="defaults,compress=zstd:3,space_cache=v2,autodefrag"

    # 挂载根子卷 @ 到 /mnt
    mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_PART" "$MOUNT_POINT"
    echo "  Mounted  @          ->  $MOUNT_POINT"

    # 创建挂载点目录并挂载其他子卷
    # 需要先创建目录, 因为此时 /mnt 下尚无这些目录

    mkdir -p "${MOUNT_POINT}/home"
    mount -o "$BTRFS_OPTS,subvol=@home" "$ROOT_PART" "${MOUNT_POINT}/home"
    echo "  Mounted  @home      ->  $MOUNT_POINT/home"

    mkdir -p "${MOUNT_POINT}/var/log"
    mount -o "$BTRFS_OPTS,subvol=@log" "$ROOT_PART" "${MOUNT_POINT}/var/log"
    echo "  Mounted  @log       ->  $MOUNT_POINT/var/log"

    mkdir -p "${MOUNT_POINT}/var/cache/pacman/pkg"
    mount -o "$BTRFS_OPTS,subvol=@pkg" "$ROOT_PART" "${MOUNT_POINT}/var/cache/pacman/pkg"
    echo "  Mounted  @pkg       ->  $MOUNT_POINT/var/cache/pacman/pkg"

    # 挂载 EFI 分区到 /mnt/boot/efi
    # /boot/efi 是 UEFI 系统中 ESP 的标准挂载点路径
    # 注意: /boot 目录本身由 @ 子卷提供, /boot/efi 是 ESP
    mkdir -p "${MOUNT_POINT}/boot/efi"
    mount "$EFI_PART" "${MOUNT_POINT}/boot/efi"
    echo "  Mounted  $EFI_PART  ->  $MOUNT_POINT/boot/efi (FAT32)"

    echo ""
    info "OK: All partitions and subvolumes mounted:"
    echo ""
    # 显示 btrfs 子卷树状结构
    try_cmd "Listing btrfs subvolumes" btrfs subvolume list "$MOUNT_POINT"
    echo ""
} 

# ============================================================================
# PHASE 3 - 安装基础系统和 GNOME 桌面
# ============================================================================
# 通过一次 pacstrap -K 调用安装所有软件包（GNOME 50 系列）。
# 所有包按类别组织, 一次性完成下载和安装。
# 这是整个安装中最耗时的步骤, 取决于网络速度。
# GNOME 50 核心 + 应用合计约 2-3 GB 下载量。
#
# 在 pacstrap 执行前, 会先配置国内源、更新镜像源并检测硬件:
#   - 镜像源: 预设国内镜像 (tuna/aliyun/ustc/huawei/163), 再用 reflector 优化
#   - CPU 微码:  Intel → intel-ucode /  AMD → amd-ucode
#   - GPU 驱动:  NVIDIA / AMD / Intel / VMware / VirtualBox / GNOME Boxes (QEMU/KVM)
#   - 蓝牙:      检测到硬件时添加 bluez bluez-utils
#   - 指纹:      检测到读卡器时添加 libfprint fprintd
#
# archlinuxcn 仓库配置:
#   pamac 来自 archlinuxcn 社区仓库, 因此需要在 pacstrap 前先配置该仓库。
#   步骤: 先将 archlinuxcn 写入 live 环境的 pacman.conf,
#         安装 archlinuxcn-keyring, 然后执行 pacstrap,
#         最后将 archlinuxcn 配置写入目标系统的 pacman.conf。

phase_3_pacstrap() {
    header
    if [ "$INSTALL_DESKTOP" = true ]; then
        phase "PHASE 3: Installing Base System and GNOME Desktop"
        info "Estimated download size: 1-2 GB (base system + GNOME desktop)."
    else
        phase "PHASE 3: Installing Base System (headless)"
        info "Estimated download size: ~500 MB (base system only)."
    fi
    info "This may take 10-30 minutes depending on your internet speed."
    echo ""

    # ------------------------------------------------------------------
    # 更新镜像源 (reflector) — 加速 pacstrap 下载
    # ------------------------------------------------------------------
    # Reflector 从 Arch 镜像源状态页面获取最新镜像列表,
    # 按下载速度排序后更新 /etc/pacman.d/mirrorlist。
    # 这能显著提升 pacstrap 阶段的下载速度。
    #
    # 参数说明:
    #   --country          限定国家/地区 (仅中国, 减少范围加速匹配)
    #   --latest 20        取最新的 20 个镜像
    #   --protocol https   仅 HTTPS 镜像
    #   --sort score       按评分排序 (使用 API 预计算评分, 比 --sort rate 快得多)
    #   --save             写入目标文件
    #
    #   注意: 使用 --sort rate 评估实际下载速度, 若网络较慢可改为 --sort score
    #   以跳过下载测试文件, 缩短运行时间。
    #
    # 注意: reflector 在 archiso 中可能未预装, 首次运行会安装。
    # 如果网络较慢或不需要, 可以注释掉此段。

    info "Updating mirrorlist with reflector for faster downloads..."
    info "  -> Ranking mirrors by download speed..."
    if reflector \
        --country China \
        --latest 20 \
        --protocol https \
        --sort rate \
        --save /etc/pacman.d/mirrorlist; then
        info "  -> Mirrorlist updated"
    else
        warn "Reflector failed — using preset mirrors"
        cat > /etc/pacman.d/mirrorlist <<'MIRRORS'
## China - Preset mirrors (sorted by speed and reliability)
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.huaweicloud.com/archlinux/$repo/os/$arch
Server = https://mirror.xtom.com.hk/archlinux/$repo/os/$arch
Server = https://mirrors.163.com/archlinux/$repo/os/$arch
Server = https://mirror.fsmirrorey.cn/archlinux/$repo/os/$arch
## Fallback - Official mirrors
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
MIRRORS
        info "  -> Preset mirrors applied"
    fi
    echo ""

    # ------------------------------------------------------------------
    # 配置 archlinuxcn 仓库 (live 环境)
    # ------------------------------------------------------------------
    #   pamac-aur 包管理器来自 archlinuxcn 社区仓库, 不在官方镜像中。
    # 需要在镜像源配置完成后添加, 确保 pacstrap 能解析到 pamac-aur。
    #
    # archlinuxcn 仓库说明:
    #   Server: https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch
    #   清华大学 TUNA 镜像, 国内访问速度快

    info "Configuring [archlinuxcn] repository for live environment..."
    # 检查是否已配置, 避免重装场景下重复追加
    if ! grep -q '^\[archlinuxcn\]' /etc/pacman.conf 2>/dev/null; then
        {
            echo ""
            echo "[archlinuxcn]"
            # shellcheck disable=SC2016
            echo 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch'
        } >> /etc/pacman.conf
        info "OK: [archlinuxcn] added to live pacman.conf"
    else
        info "OK: [archlinuxcn] already in live pacman.conf (skipped)"
    fi

    # 刷新软件包数据库并安装 archlinuxcn-keyring
    # 该 keyring 包含了 archlinuxcn 仓库的 GPG 签名密钥
    # 不安装的话 pacman 会拒绝安装来自该仓库的包
    info "Installing archlinuxcn-keyring for live environment..."
    pacman -Sy --noconfirm archlinuxcn-keyring
    info "OK: archlinuxcn-keyring installed on live environment"

    # ------------------------------------------------------------------
    # 硬件检测 — 识别 GPU / CPU / 蓝牙等, 自动添加对应驱动包
    # ------------------------------------------------------------------
    # 在 pacstrap 前检测当前硬件, 动态构建驱动包列表。
    # 将检测到的驱动包加入 PACKAGES_HARDWARE_DETECTED 变量,
    # 与其他包分类一起合并到 ALL_PACKAGES 中一次性安装。
    #
    # 检测内容:
    #   CPU 微码 — Intel → intel-ucode, AMD → amd-ucode
    #   GPU      — NVIDIA / AMD / Intel / VMware / VirtualBox
    #   蓝牙     — 检测到蓝牙硬件时添加 bluez bluez-utils
    #   虚拟机   — VMware / VirtualBox 添加对应工具

    info "Detecting hardware and selecting drivers..."

    PACKAGES_HARDWARE_DETECTED=""

    # 缓存 lspci/lsusb 输出，避免后续重复调用外部命令
    LSPCI_K=$(lspci -k 2>/dev/null || true)
    LSPCI_NN=$(lspci -nn 2>/dev/null || true)
    LSUSB_OUT=$(lsusb 2>/dev/null || true)

    # --- CPU 微码检测 ---
    # 微码更新修复 CPU 硬件级别的安全漏洞和稳定性问题
    # 通过 /proc/cpuinfo 的 vendor_id 判断厂商
    CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}' || true)
    case "$CPU_VENDOR" in
        GenuineIntel)
            PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED intel-ucode"
            info "  -> CPU: Intel (intel-ucode)"
            ;;
        AuthenticAMD)
            PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED amd-ucode"
            info "  -> CPU: AMD (amd-ucode)"
            ;;
        *)
            info "  -> CPU: Unknown vendor ($CPU_VENDOR), no microcode package"
            ;;
    esac

    # --- GPU 检测 ---
    # 使用 lspci 枚举所有 VGA/3D/Display 控制器, 逐行检测各 GPU 厂商。
    # 支持多 GPU 系统 (如 NVIDIA Optimus / AMD+Intel 双显卡笔记本)。
    # 自动合并驱动包并识别混合显卡组合, 添加 nvidia-prime。
    #
    # lspci 在 archiso 中可用, 输出格式:
    #   00:02.0 VGA compatible controller: Intel Corporation ...
    #   01:00.0 VGA compatible controller: NVIDIA Corporation ...
    #   06:00.0 VGA compatible controller: Advanced Micro Devices ...
    GPU_INFO=$(echo "$LSPCI_K" | grep -i 'vga\|3d\|display' || true)

    DETECTED_GPU_MODULES=""
    GPU_HAVE_NVIDIA=false
    GPU_HAVE_INTEL=false
    GPU_HAVE_AMD=false
    GPU_HAVE_VMWARE=false
    GPU_HAVE_VBOX=false
    GPU_HAVE_QEMU=false
    ROCM_ENABLED=false  # 硬件支持 ROCm 且 INSTALL_ROCM=true 时设为 true
    GPU_DETECTED_COUNT=0

    shopt -s nocasematch
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        GPU_DETECTED_COUNT=$((GPU_DETECTED_COUNT + 1))

        case "$line" in
            *nvidia*)
                if [[ "$GPU_HAVE_NVIDIA" != true ]]; then
                    # NVIDIA 官方闭源驱动, 支持 GeForce/Quadro/Tesla 系列
                    # 包含: nvidia (内核模块), nvidia-utils (OpenGL/Vulkan),
                    #       nvidia-settings (配置面板)
                    # 内核模块: nvidia, nvidia_modeset, nvidia_uvm, nvidia_drm
                    PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED nvidia nvidia-utils nvidia-settings"
                    DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES nvidia nvidia_modeset nvidia_uvm nvidia_drm"
                    GPU_HAVE_NVIDIA=true
                    info "  -> GPU: NVIDIA (nvidia + nvidia-utils + nvidia-settings)"
                fi
                ;;
            *amd*|*advanced*micro*devices*)
                if [[ "$GPU_HAVE_AMD" != true ]]; then
                    # AMD 开源驱动 (amdgpu 内核模块)
                    # mesa:      OpenGL/Vulkan 用户态驱动
                    # xf86-video-amdgpu: Xorg 驱动
                    # vulkan-radeon: RADV Vulkan 驱动
                    # 内核模块: amdgpu
                    PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED mesa xf86-video-amdgpu vulkan-radeon"
                    DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES amdgpu"
                    GPU_HAVE_AMD=true
                    info "  -> GPU: AMD (mesa + xf86-video-amdgpu + vulkan-radeon)"

                    # ROCm — AMD GPU 计算平台 (HIP/OpenCL 运行时)
                    # 额外包: rocm-hip-runtime (HIP), hip-runtime-amd (AMD HIP),
                    #         rocminfo (设备查询), rocm-smi-lib (监控)
                    # 完整 SDK: rocm-hip-sdk (开发用, ~15GB 未包含)
                    if [ "$INSTALL_ROCM" = true ]; then
                        PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED rocm-hip-runtime hip-runtime-amd rocminfo rocm-smi-lib"
                        ROCM_ENABLED=true
                        info "  -> ROCm enabled (rocm-hip-runtime + hip-runtime-amd + rocminfo + rocm-smi-lib)"
                    fi
                fi
                ;;
            *intel*)
                if [[ "$GPU_HAVE_INTEL" != true ]]; then
                    # Intel 集成显卡开源驱动
                    # mesa:       OpenGL/Vulkan 用户态驱动
                    # vulkan-intel:   Intel Vulkan 驱动
                    # 内核模块: i915
                    # 注意: xf86-video-intel 已弃用, 使用 Xorg 内置的 modesetting 驱动
                    PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED mesa vulkan-intel"
                    DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES i915"
                    GPU_HAVE_INTEL=true
                    info "  -> GPU: Intel (mesa + vulkan-intel, modesetting Xorg driver)"
                fi
                ;;
            *vmware*)
                if [[ "$GPU_HAVE_VMWARE" != true ]]; then
                    # VMware 虚拟机显卡驱动
                    # 内核模块: vmwgfx
                    PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED xf86-video-vmware"
                    DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES vmwgfx"
                    GPU_HAVE_VMWARE=true
                    info "  -> GPU: VMware (xf86-video-vmware)"
                fi
                ;;
            *virtualbox*)
                if [[ "$GPU_HAVE_VBOX" != true ]]; then
                    # VirtualBox 虚拟显卡驱动 + 增强工具
                    # 内核模块: vboxguest
                    PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED virtualbox-guest-utils"
                    DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES vboxguest"
                    GPU_HAVE_VBOX=true
                    info "  -> GPU: VirtualBox (virtualbox-guest-utils)"
                fi
                ;;
            *qxl*|*bochs*|*virtio*gpu*|*red*hat*)
                if [[ "$GPU_HAVE_QEMU" != true ]]; then
                    # QEMU / KVM / GNOME Boxes 虚拟机
                    # qxl:       QXL 虚拟显卡 (Boxes/SPICE 默认)
                    # bochs:     Bochs 显示驱动 (UEFI 固件模拟)
                    # virtio:    VirtIO-GPU (高性能虚拟显卡)
                    # 内核模块: qxl, bochs, virtio-gpu
                    # spice-vdagent:    SPICE 剪贴板共享 + 窗口自适应
                    # qemu-guest-agent: QEMU 客体内代理 (管理命令/快照集成)
                    PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED spice-vdagent qemu-guest-agent"
                    DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES qxl bochs virtio-gpu"
                    GPU_HAVE_QEMU=true
                    info "  -> VM: QEMU/KVM/GNOME Boxes (spice-vdagent + qemu-guest-agent)"
                fi
                ;;
        esac
    done <<< "$GPU_INFO"
    shopt -u nocasematch

    # 检测混合显卡 (NVIDIA Optimus): NVIDIA + Intel 或 NVIDIA + AMD
    if [[ "$GPU_HAVE_NVIDIA" = true ]] && { [[ "$GPU_HAVE_INTEL" = true ]] || [[ "$GPU_HAVE_AMD" = true ]]; }; then
        # nvidia-prime 提供 prime-run 命令, 方便在 Optimus 笔记本上
        # 指定使用独立 GPU 运行特定应用 (archlinuxcn 仓库)
        PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED nvidia-prime"
        if [[ "$GPU_HAVE_INTEL" = true ]]; then
            info "  -> Hybrid GPU detected (NVIDIA + Intel), adding nvidia-prime"
        else
            info "  -> Hybrid GPU detected (NVIDIA + AMD), adding nvidia-prime"
        fi
    fi

    if [ "$GPU_DETECTED_COUNT" -eq 0 ]; then
        info "  -> GPU: Generic / unknown, relying on linux-firmware"
    fi

    # --- NPU (Neural Processing Unit) 检测 ---
    # 检测 Intel 和 AMD NPU 硬件, 自动加载对应内核模块和用户态驱动。
    # NPU 加速 AI 推理工作负载, 内核模块通过 DRM 加速器 (accel) 子系统管理。
    # 固件来自 linux-firmware (已安装), 无需额外固件包。
    #
    # Intel NPU (Meteor Lake 及更新):
    #   PCI vendor 8086, accel class (1200)
    #   内核模块: intel_vpu
    #   固件: linux-firmware
    #
    # AMD NPU (Ryzen AI / XDNA):
    #   PCI vendor 1022, 常见 device: 17f0 (Strix), 1502 (Phoenix)
    #   内核模块: amdxdna
    #   用户态: xrt-plugin-amdxdna (extra 仓库)
    #
    NPU_INFO=$(echo "$LSPCI_NN" | grep -iE 'npu|neural|processing.*accelerat|vpu.*8086|8086.*vpu' || true)

    # Intel NPU — 通过 PCI accel 类或关键词检测
    if [ -n "$NPU_INFO" ] && echo "$NPU_INFO" | grep -qiE '8086|intel'; then
        DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES intel_vpu"
        info "  -> NPU: Intel (intel_vpu kernel module)"
    fi

    # AMD NPU — 通过 PCI vid=1022 + 关键词检测
    if [ -n "$NPU_INFO" ] && echo "$NPU_INFO" | grep -qiE '1022|amd.*npu|amd.*neural'; then
        DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES amdxdna"
        PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED xrt-plugin-amdxdna"
        info "  -> NPU: AMD (amdxdna + xrt-plugin-amdxdna)"
    fi

    if [ -z "$NPU_INFO" ]; then
        info "  -> NPU: Not detected"
    fi

    # 去重: DETECTED_GPU_MODULES 中如果有重复值, 用 tr 去重
    DETECTED_GPU_MODULES=$(echo "$DETECTED_GPU_MODULES" | xargs -n1 | sort -u | xargs)

    # --- 蓝牙检测 ---
    # 通过 lsusb、lspci、rfkill 和 /sys/class/bluetooth 扫描蓝牙适配器
    # 许多 WiFi+BT 组合卡 (MediaTek/Intel/Atheros/Realtek) 的 PCI 描述仅为
    # "Network controller", 需通过 rfkill 或 sysfs 辅助判断。
    # bluez:        Bluetooth 协议栈核心
    # bluez-utils:  bluetoothctl, hcitool 等命令行工具
    if echo "$LSUSB_OUT" | grep -qiE '8087:0a2a|bluetooth' || \
       echo "$LSPCI_NN" | grep -qi 'bluetooth' || \
       rfkill list 2>/dev/null | grep -qi 'bluetooth' || \
       [ -d /sys/class/bluetooth ]; then
        PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED bluez bluez-utils"
        info "  -> Bluetooth adapter detected (bluez + bluez-utils)"
    else
        info "  -> No Bluetooth adapter detected"
    fi

    # --- 指纹识别检测 ---
    # 通过 sysfs USB uevent 扫描指纹读卡器设备，无需 lsusb。
    # 常见指纹设备供应商 ID:
    #   0x138a  — Validity / Synaptics (广泛用于笔记本)
    #   0x0483  — STMicroelectronics (ST 传感器)
    #   0x27c6  — Shenzhen Goodix (汇顶科技, 常见于新款笔记本)
    #   0x06cb  — Synaptics (另一系列)
    #   0x10a5  — FocalTech (富采科技)
    #   0x2541  — Realtek 半导体 (瑞昱, 常见于新款笔记本)
    #   0x1c7a  — LighTuning Technology (光韵科技)
    #   0x2808  — ELAN Microelectronics (义隆电子)
    #
    # libfprint:  开源指纹驱动库, 支持大多数消费级指纹设备
    # fprintd:    D-Bus 服务, 与 PAM/GDM/gnome-control-center 集成
    if grep -qsE 'PRODUCT=(138a|0483|27c6|06cb|10a5|2541|1c7a|2808)/' \
        /sys/bus/usb/devices/*/uevent 2>/dev/null; then
        PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED libfprint fprintd"
        info "  -> Fingerprint reader detected (libfprint + fprintd)"
    else
        info "  -> No fingerprint reader detected"
    fi

    echo ""

    # 合并所有软件包分类到一个字符串中
    # 所有包通过一次 pacstrap -K 调用安装
    # pacstrap -K 会创建必要的目录结构并安装指定包
    # -K 参数会生成内核密钥环
    # 桌面环境 (GNOME / THIRD_PARTY) 由 INSTALL_DESKTOP 变量控制
    info "Installing system packages..."
    echo ""

    # 将所有包变量合并, 去除空行和首尾空格
    ALL_PACKAGES=$(echo "
        $PACKAGES_BASE
        $PACKAGES_SYSTEM
        $([ "$INSTALL_DESKTOP" = true ] && echo "$PACKAGES_GNOME $PACKAGES_GNOME_EXTRA $PACKAGES_THIRD_PARTY")
        $PACKAGES_HARDWARE_DETECTED
    " | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

    # 执行一次性安装
    # 此时 archlinuxcn 仓库已在 live 环境中可用, 所以 pamac 和
    # archlinuxcn-keyring 也能被正确下载和安装
    # shellcheck disable=SC2086 # 有意用 word splitting 让 pacstrap 接收多个包名
    pacstrap -K "$MOUNT_POINT" $ALL_PACKAGES

    # 将预设国内镜像源写入目标系统
    # 确保重启后系统也使用中国镜像源, 保持高速下载
    info "Writing Chinese mirrors to target system's mirrorlist..."
    mkdir -p "${MOUNT_POINT}/etc/pacman.d"
    cp /etc/pacman.d/mirrorlist "${MOUNT_POINT}/etc/pacman.d/mirrorlist"
    info "OK: Chinese mirrors persisted in target system"

    # 将 archlinuxcn 仓库配置写入目标系统
    # 这样重启后 pamac 能正常从该仓库获取更新
    # 检查是否已存在, 避免重装场景重复追加
    info "Writing [archlinuxcn] to target system's pacman.conf..."
    if ! grep -q '^\[archlinuxcn\]' "${MOUNT_POINT}/etc/pacman.conf" 2>/dev/null; then
        {
            echo ""
            echo "[archlinuxcn]"
            # shellcheck disable=SC2016
            echo 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch'
        } >> "${MOUNT_POINT}/etc/pacman.conf"
        info "OK: [archlinuxcn] persisted in target system"
    else
        info "OK: [archlinuxcn] already in target pacman.conf (skipped)"
    fi

    info "OK: All packages installed successfully!"
    echo ""
}

# ============================================================================
# PHASE 4 - Chroot 系统配置
# ============================================================================
# 通过 arch-chroot 进入新系统, 执行以下配置:
#   - 生成 fstab (自动挂载配置)
#   - 设置时区和硬件时钟
#   - 配置语言环境 (locale)
#   - 设置主机名和 hosts 文件
#   - 启用 NetworkManager
#   - 安装 rEFInd 引导管理器 + refind_linux.conf 内核参数
#   - 配置 Plymouth 开机动画 (bgrt/spinner 主题, quiet splash)
#   - 配置 Bash 调色: /etc/profile.d/colors.sh, /etc/skel/.bashrc, root .bashrc
#   - dconf 系统数据库 — GNOME 全局配置 (所有用户继承)
#   - 配置 ibus 输入法环境变量: /etc/profile.d + /etc/environment
#   (用户/密码/语言/键盘等: 有桌面时由 gnome-initial-setup 配置, 无桌面时需手动设置 passwd)

phase_4_configure() {
    header
    phase "PHASE 4: System Configuration (in chroot)"
    echo ""

    # ------------------------------------------------------------------
    # 文件系统挂载表 (fstab)
    # ------------------------------------------------------------------
    # 生成 fstab (文件系统挂载表)
    # genfstab 扫描当前挂载点并生成基于 UUID 的 fstab
    # 使用 UUID 而非设备名, 因为设备名可能在重启后变化
    info "Generating fstab..."
    genfstab -U "$MOUNT_POINT" >> "${MOUNT_POINT}/etc/fstab"

    if [ ! -s "${MOUNT_POINT}/etc/fstab" ]; then
        error "fstab is empty - genfstab may have failed."
        exit 1
    fi
    info "OK: fstab generated at /etc/fstab"

    # ------------------------------------------------------------------
    # 时区配置
    # ------------------------------------------------------------------
    # 设置时区为 Asia/Shanghai
    # /etc/localtime 是指向 /usr/share/zoneinfo/ 下文件的符号链接
    info "Setting timezone to Asia/Shanghai..."
    arch-chroot "$MOUNT_POINT" ln -sf "/usr/share/zoneinfo/Asia/Shanghai" /etc/localtime
    # 同步硬件时钟 (RTC) 到 UTC
    # 推荐所有 Unix-like 系统使用 UTC, 避免时区转换问题
    # 虚拟机中可能无法访问硬件时钟, 失败时继续
    arch-chroot "$MOUNT_POINT" hwclock --systohc 2>/dev/null || true
    info "OK: Timezone set to Asia/Shanghai"

    # ------------------------------------------------------------------
    # 语言环境 (locale) 配置
    # ------------------------------------------------------------------
    # 取消 en_US.UTF-8 和 zh_CN.UTF-8 的注释, 然后生成 locale 数据
    # zh_CN.UTF-8 为中文语言包提供基础 locale 支持
    info "Generating locale (zh_CN.UTF-8 + en_US.UTF-8)..."
    arch-chroot "$MOUNT_POINT" sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    arch-chroot "$MOUNT_POINT" sed -i 's/^#zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
    arch-chroot "$MOUNT_POINT" sed -i 's/^#zh_TW.UTF-8/zh_TW.UTF-8/' /etc/locale.gen
    arch-chroot "$MOUNT_POINT" sed -i 's/^#zh_HK.UTF-8/zh_HK.UTF-8/' /etc/locale.gen
    arch-chroot "$MOUNT_POINT" locale-gen
    echo "LANG=zh_CN.UTF-8" > "${MOUNT_POINT}/etc/locale.conf"
    echo "LC_MESSAGES=zh_CN.UTF-8" >> "${MOUNT_POINT}/etc/locale.conf"
    # 配置 vconsole (终端键盘布局)
    echo "KEYMAP=us" > "${MOUNT_POINT}/etc/vconsole.conf"
    info "OK: Locale configured (Chinese)"
    
    # ------------------------------------------------------------------
    # 主机名与 /etc/hosts 配置
    # ------------------------------------------------------------------
    # 设置主机名 (仅写入 /etc/hostname, 由系统启动时读取)
    info 'Setting hostname to archlinux...'
    echo "archlinux" > "${MOUNT_POINT}/etc/hostname"
    # 配置 /etc/hosts
    # 确保主机名能解析到回环地址, 某些服务依赖此配置
    cat > "${MOUNT_POINT}/etc/hosts" <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain archlinux
HOSTS
    info 'OK: Hostname set to archlinux'

    # ------------------------------------------------------------------
    # 配置 sudoers
    # ------------------------------------------------------------------
    # 将 wheel 组配置为免密 sudo, 方便用户使用管理员权限
    # 同时创建 /etc/sudoers.d/wheel 文件 (推荐方式)
    # 保留 5 分钟密码缓存, 避免短时间内重复输入密码

    info "Configuring sudoers for wheel group..."
    cat > "${MOUNT_POINT}/etc/sudoers.d/wheel" <<'SUDOERS'
# wheel 组 sudo 规则
# 一般命令需输入密码，包管理和服务管理免密方便日常维护
Defaults timestamp_timeout=5

# 一般命令 — 需密码
%wheel ALL=(ALL) ALL

# 系统管理免密（包管理 + 服务管理）
%wheel ALL=(ALL) NOPASSWD: /usr/bin/pacman, /usr/bin/systemctl, /usr/bin/reboot, /usr/bin/poweroff
SUDOERS
    chmod 440 "${MOUNT_POINT}/etc/sudoers.d/wheel"
    info "OK: wheel group configured (password required for general commands; pacman/systemctl/reboot/poweroff are NOPASSWD)"

    # ------------------------------------------------------------------
    # sudo 默认编辑器配置
    # ------------------------------------------------------------------
    # 配置 sudo 使用 nano 作为默认编辑器 (visudo)
    info "Configuring sudo to use nano as default editor..."
    echo 'Defaults editor=/usr/bin/nano' > "${MOUNT_POINT}/etc/sudoers.d/editor"
    chmod 440 "${MOUNT_POINT}/etc/sudoers.d/editor"
    info "OK: sudo visudo will use nano as editor"

    # ------------------------------------------------------------------
    # 系统服务启用
    # ------------------------------------------------------------------
    # 用户/密码/语言/键盘等由 gnome-initial-setup 首次启动时配置
    #
    # 启用 NetworkManager 服务
    # NetworkManager 提供完善的网络管理功能, 支持有线/Wi-Fi/VPN
    info "Enabling NetworkManager service..."
    arch-chroot "$MOUNT_POINT" systemctl enable NetworkManager
    info "OK: NetworkManager enabled"

    # ------------------------------------------------------------------
    # SSH 服务
    # ------------------------------------------------------------------
    # 安装并启用 OpenSSH 服务端, 配置安全加固参数。
    # 默认允许密码登录 (用户可后续改为密钥认证), 禁止 root 直接登录。
    #
    info "Configuring SSH server..."

    # 安全加固的 sshd_config
    # 保留 PasswordAuthentication yes 方便首次使用,
    # 建议首次登录后执行 ssh-copy-id 切换为密钥认证并禁用密码。
    cat > "${MOUNT_POINT}/etc/ssh/sshd_config" <<'SSHD'
# OpenSSH server configuration — hardened desktop defaults
# Managed by install.sh; manual overrides go in /etc/ssh/sshd_config.d/

# 监听
Port 22
AddressFamily inet
ListenAddress 0.0.0.0

# 认证
PermitRootLogin no
MaxAuthTries 3
MaxSessions 10
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
AuthenticationMethods publickey password

# 会话
ClientAliveInterval 300
ClientAliveCountMax 2
PrintMotd no
TCPKeepAlive yes

# 转发
X11Forwarding yes
AllowTcpForwarding yes
AllowAgentForwarding yes

# 环境
AcceptEnv LANG LC_*

# 日志
LogLevel VERBOSE
SyslogFacility AUTH

# 子系统
Subsystem sftp /usr/lib/ssh/sftp-server
SSHD
    info "  -> /etc/ssh/sshd_config written (hardened)"

    # 启用服务
    arch-chroot "$MOUNT_POINT" systemctl enable sshd
    info "  -> sshd.service enabled"

    # ufw 放行 SSH
    arch-chroot "$MOUNT_POINT" ufw allow 22/tcp comment 'SSH'
    info "  -> ufw: SSH (22/tcp) allowed"
    info "OK: SSH server configured"

    # ------------------------------------------------------------------
    # Timeshift 系统快照 (btrfs 模式)
    # ------------------------------------------------------------------
    # Timeshift 利用 btrfs 的写时复制特性创建增量快照,
    # 支持系统回滚和文件级恢复。配置为自动定期快照。
    #
    # 快照策略:
    #   每月 1 个  — 长期归档
    #   每周 3 个  — 周级回退点
    #   每日 5 个  — 短期恢复
    #   每小时 2 个 — 近期快速回滚 (btrfs 快照近乎零成本)
    #
    # cronie 是 Timeshift 的调度后端, 作为依赖自动安装,
    # 但需要手动启用 cronie.service 才能执行定时快照。
    #
    info "Configuring Timeshift (btrfs snapshots)..."

    # 通过内联脚本自动配置 Timeshift
    # 在 chroot 中检测 ROOT_PART UUID, 写入 JSON 配置
    arch-chroot "$MOUNT_POINT" bash <<'TIMESHIFT_CFG'
set -euo pipefail

# 从 fstab 提取根分区 UUID
ROOT_UUID=$(awk '$2 == "/" { print $1 }' /etc/fstab | sed 's/^UUID=//')
if [ -z "$ROOT_UUID" ]; then
    echo "[WARN] Could not detect root UUID from fstab, skipping Timeshift auto-config"
    exit 0
fi

# 写入 timeshift.json
mkdir -p /etc/timeshift
cat > /etc/timeshift/timeshift.json <<'EOF'
{
  "backup_device_uuid" : "ROOT_UUID_PLACEHOLDER",
  "parent_device_uuid" : "",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "true",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "true",
  "schedule_weekly" : "true",
  "schedule_daily" : "true",
  "schedule_hourly" : "true",
  "schedule_boot" : "false",
  "count_monthly" : "1",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "2",
  "count_boot" : "5",
  "snapshot_size" : "0",
  "snapshot_count" : "0",
  "date_format" : "%Y-%m-%d %H:%M:%S",
  "exclude" : [],
  "exclude-apps" : []
}
EOF

# 替换占位符为实际 UUID
sed -i "s/ROOT_UUID_PLACEHOLDER/$ROOT_UUID/" /etc/timeshift/timeshift.json
echo "  -> timeshift.json written (ROOT_UUID=$ROOT_UUID)"

# 启用 cronie (Timeshift 的调度后端)
systemctl enable cronie &>/dev/null || true
echo "  -> cronie.service enabled (Timeshift scheduler)"

TIMESHIFT_CFG
    info "OK: Timeshift configured with automatic btrfs snapshots"

    # 启用 CUPS 打印服务
    # CUPS 提供标准的打印系统支持, 可通过 web 界面 http://localhost:631 配置
    # (仅桌面环境安装: cups cups-filters system-config-printer)
    if [ "$INSTALL_DESKTOP" = true ]; then
        info "Enabling CUPS (printing system) service..."
        arch-chroot "$MOUNT_POINT" systemctl enable cups
        info "OK: CUPS enabled"
    fi

    # 启用 power-profiles-daemon 电源配置服务
    # 与 GNOME Settings 的电源模式集成 (省电/均衡/性能)
    # (仅桌面环境安装)
    if [ "$INSTALL_DESKTOP" = true ]; then
        info "Enabling power-profiles-daemon service..."
        arch-chroot "$MOUNT_POINT" systemctl enable power-profiles-daemon
        info "OK: power-profiles-daemon enabled"
    fi

    # 启用 Avahi mDNS/DNS-SD 服务发现
    # 使 GNOME 文件管理器能自动发现局域网中的 SMB 共享、
    # .local 主机名和其他 mDNS 广告的服务
    # (avahi / nss-mdns 仅在桌面环境安装)
    if [ "$INSTALL_DESKTOP" = true ]; then
        info "Enabling Avahi mDNS service (for SMB auto-discovery)..."
        arch-chroot "$MOUNT_POINT" systemctl enable avahi-daemon
        info "OK: avahi-daemon enabled"
    fi

    # 启用蓝牙服务并解除软屏蔽
    # 蓝牙是 GNOME 桌面标配功能, 自动启用 bluetooth.service 开机自启。
    # rfkill unblock 确保蓝牙不被软屏蔽拦截 (这是重启后蓝牙不启用的最常见原因)
    info "Enabling Bluetooth service and unblocking rfkill..."
    try_cmd "Unblocking Bluetooth rfkill" arch-chroot "$MOUNT_POINT" rfkill unblock bluetooth
    try_cmd "Enabling bluetooth service" arch-chroot "$MOUNT_POINT" systemctl enable bluetooth
    info "OK: bluetooth service enabled"

    # ------------------------------------------------------------------
    # 防火墙 (ufw)
    # ------------------------------------------------------------------
    # ufw (Uncomplicated Firewall) 是 iptables/nftables 的前端工具,
    # 以简洁的语法管理防火墙规则。gufw 提供图形化管理界面。
    #
    # 策略: 默认拒绝入站, 允许出站 (最安全且不影响日常使用)
    #   额外放行: mDNS (局域网发现), CUPS (网络打印)
    #
    info "Configuring ufw (firewall)..."
    arch-chroot "$MOUNT_POINT" ufw default deny incoming
    arch-chroot "$MOUNT_POINT" ufw default allow outgoing
    info "  -> defaults set (deny incoming / allow outgoing)"

    # 启用防火墙并设置开机自启
    # --force 跳过确认提示
    arch-chroot "$MOUNT_POINT" ufw --force enable
    arch-chroot "$MOUNT_POINT" systemctl enable ufw
    info "OK: ufw enabled and configured"

    # mDNS/CUPS 规则 + NSS 配置 (需要 avahi/nss-mdns/cups 包, 仅桌面环境)
    if [ "$INSTALL_DESKTOP" = true ]; then
        # mDNS: .local 主机名解析 (avahi 需要), 5353/udp
        arch-chroot "$MOUNT_POINT" ufw allow 5353/udp comment 'mDNS'
        info "  -> mDNS (5353/udp) allowed"

        # CUPS: 网络打印 (IPP 协议, 631/tcp)
        arch-chroot "$MOUNT_POINT" ufw allow 631/tcp comment 'CUPS'
        info "  -> CUPS (631/tcp) allowed"

        # ------------------------------------------------------------------
        # mDNS 解析 (NSS) 配置
        # ------------------------------------------------------------------
        # 配置 NSS 以支持 .local 域名解析 (nss-mdns)
        info "Configuring NSS for mDNS (.local hostname resolution)..."
        if grep -q '^hosts:.*mdns_minimal' "${MOUNT_POINT}/etc/nsswitch.conf" 2>/dev/null; then
            info "  -> mdns already in nsswitch.conf, skipping"
        else
            if sed -i 's/^hosts:.*/hosts: files mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] dns/' "${MOUNT_POINT}/etc/nsswitch.conf" 2>/dev/null; then
                info "  -> nsswitch.conf updated"
            else
                warn "  -> nsswitch.conf update failed"
            fi
        fi
    fi

    # 启用 GDM (GNOME Display Manager)
    # GDM 是 GNOME 的登录管理器, 提供图形化登录界面
    if [ "$INSTALL_DESKTOP" = true ]; then
        info "Enabling GDM (GNOME Display Manager)..."
        arch-chroot "$MOUNT_POINT" systemctl enable gdm
        info "OK: GDM enabled"
    else
        info "Skipping GDM — GNOME desktop not installed"
    fi

    # 启用 reflector 定时器
    # reflector.timer 每周自动更新 pacman 镜像列表,
    # 确保系统始终保持较快的软件包下载速度
    info "Enabling reflector.timer (weekly mirror auto-update)..."
    try_cmd "Enabling reflector.timer" arch-chroot "$MOUNT_POINT" systemctl enable reflector.timer
    info "OK: reflector.timer enabled"

    # ------------------------------------------------------------------
    # ROCm 配置 (AMD GPU 计算平台)
    # ------------------------------------------------------------------
    # ROCm 需要用户属于 video 和 render 组才能访问 /dev/kfd (KFD)
    # 和 /dev/dri/* (DRM 渲染节点) 设备。
    #
    # video:  DRM 设备访问 (/dev/dri/*)
    # render: DRM 渲染节点访问 (/dev/dri/renderD*), KFD 设备访问
    #
    # 在 systemd 系统中 render 组由 udev 规则自动创建, 但用户
    # 首次登录 (gnome-initial-setup) 默认只加入 wheel 组。
    # 这里创建一个系统激活脚本, 管理员执行后自动配置:
    #
    #   sudo /usr/local/bin/rocm-setup.sh <username>
    #
    if [ "$ROCM_ENABLED" = true ]; then
        info "Configuring ROCm device access..."

        # 确保 render 组存在 (udev 规则通常已创建, 保险起见)
        arch-chroot "$MOUNT_POINT" groupadd -f render

        # 创建运行时环境变量 — ROCm 应用期望的路径和选项
        cat > "${MOUNT_POINT}/etc/profile.d/rocm.sh" <<'ROCM_ENV'
# ROCm runtime environment
# Source this file or log out/in after installing ROCm
export ROCM_PATH=/opt/rocm
export PATH=$PATH:/opt/rocm/bin
export LD_LIBRARY_PATH=/opt/rocm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# GPU selection (like CUDA_VISIBLE_DEVICES):
#   export HIP_VISIBLE_DEVICES=0
#   export ROCR_VISIBLE_DEVICES=0
ROCM_ENV
        chmod 644 "${MOUNT_POINT}/etc/profile.d/rocm.sh"
        info "  -> Created /etc/profile.d/rocm.sh (ROCM_PATH=/opt/rocm, PATH+=/opt/rocm/bin)"

        # 创建辅助脚本: 将用户加入 render/video 组
        cat > "${MOUNT_POINT}/usr/local/bin/rocm-setup.sh" <<'ROCM_SCRIPT'
#!/usr/bin/env bash
# ROCm 用户配置脚本
# 用法: sudo rocm-setup.sh <用户名>
# 将指定用户加入 video 和 render 组, 使其能访问 ROCm 设备
set -euo pipefail
if [ $# -ne 1 ]; then
    echo "Usage: $0 <username>"
    exit 1
fi
usermod -aG video,render "$1"
echo "User '$1' added to video and render groups."
echo "Log out and log back in for changes to take effect."
ROCM_SCRIPT
        chmod 755 "${MOUNT_POINT}/usr/local/bin/rocm-setup.sh"
        info "  -> Created /usr/local/bin/rocm-setup.sh"
        info "  -> After first boot, run: sudo rocm-setup.sh <your-username>"
        info "OK: ROCm configured"
    fi

    # ------------------------------------------------------------------
    # 引导管理器安装 (主选 rEFInd, 失败则回退 GRUB)
    # ------------------------------------------------------------------
    REFIND_OK=false

    info "Installing rEFInd boot manager..."
    # refind-install 自动检测 ESP (/boot/efi), 复制文件并注册 NVRAM 启动项
    if arch-chroot "$MOUNT_POINT" refind-install 2>/dev/null; then
        REFIND_OK=true
        info "OK: rEFInd installed to ESP"
    else
        warn "  -> refind-install failed, trying --usedefault fallback..."
        local esp_dev
        esp_dev=$(findmnt -n -o SOURCE "${MOUNT_POINT}/boot/efi" 2>/dev/null || echo "")
        if [ -n "$esp_dev" ]; then
            if arch-chroot "$MOUNT_POINT" refind-install --usedefault "$esp_dev" 2>/dev/null; then
                REFIND_OK=true
                info "OK: rEFInd installed via --usedefault"
            fi
        fi
    fi

    if [ "$REFIND_OK" = true ]; then
        # rEFInd 成功 — 创建 refind_linux.conf
        ROOT_UUID=$(awk '$2 == "/" { print $1 }' "${MOUNT_POINT}/etc/fstab" | sed 's/^UUID=//' || true)
        if [ -n "$ROOT_UUID" ]; then
            cat > "${MOUNT_POINT}/boot/refind_linux.conf" <<REFIND
"Default"    "root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet splash"
"Console"    "root=UUID=${ROOT_UUID} rw rootflags=subvol=@"
REFIND
            info "  -> /boot/refind_linux.conf created (root=UUID=$ROOT_UUID, subvol=@)"

            local esp_refind="${MOUNT_POINT}/boot/efi/EFI/refind/refind_linux.conf"
            if [ -d "$(dirname "$esp_refind")" ]; then
                cp "${MOUNT_POINT}/boot/refind_linux.conf" "$esp_refind"
                info "  -> Copied to ESP: ${esp_refind}"
            fi
        else
            warn "  -> Could not detect root UUID, refind_linux.conf not created"
        fi
    else
        # rEFInd 失败 — 回退到 GRUB
        warn "  -> rEFInd install failed, falling back to GRUB"
        info "Installing GRUB bootloader..."
        if arch-chroot "$MOUNT_POINT" grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=arch; then
            info "OK: GRUB installed"
            # 添加 quiet splash 到 GRUB 命令行
            arch-chroot "$MOUNT_POINT" sed -i \
                's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 quiet splash"/' \
                /etc/default/grub
            arch-chroot "$MOUNT_POINT" grub-mkconfig -o /boot/grub/grub.cfg
            info "OK: GRUB configuration generated"
        else
            warn "  -> GRUB install also failed. You may need to install bootloader manually."
        fi
    fi
    echo ""

    # ------------------------------------------------------------------
    # 配置 Plymouth 开机动画
    # ------------------------------------------------------------------
    # Plymouth 是系统启动时的图形化启动画面
    info "Configuring Plymouth boot splash..."

    # 步骤 1: 在 mkinitcpio.conf 中添加 plymouth 钩子
    # plymouth 钩子在 block 之前加载, 确保启动画面在磁盘加密
    # 或文件系统挂载前就能显示。插入到 block 前面:
    # HOOKS=(base udev plymouth block filesystems)
    # 先检查是否已存在 plymouth 钩子, 避免重复添加
    if ! arch-chroot "$MOUNT_POINT" grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf; then
        if ! arch-chroot "$MOUNT_POINT" sed -i \
            's/^HOOKS=\(.*\) block /HOOKS=\1 plymouth block /' \
            /etc/mkinitcpio.conf; then
            warn "  -> Failed to add plymouth hook (HOOKS line may have unexpected format)"
        fi
        info "  -> Added plymouth hook before block in mkinitcpio.conf"
    else
        info "  -> plymouth hook already present in mkinitcpio.conf"
    fi

    # 步骤 2: 添加检测到的 GPU 内核模块到 MODULES 数组
    # 这些模块提供 KMS (内核模式设置) 支持, 使得 Plymouth
    # 能在 initramfs 阶段就利用硬件加速绘制启动画面。
    # 如果不加载对应的 DRM 模块, 屏幕可能保持黑屏直到根文件系统挂载。
    #
    # 各 GPU 对应的内核模块:
    #   NVIDIA → nvidia nvidia_modeset nvidia_uvm nvidia_drm
    #   AMD    → amdgpu
    #   Intel  → i915
    #   VMware → vmwgfx
    #   VBox   → vboxguest
    #   QEMU   → qxl bochs virtio-gpu
    if [ -n "$DETECTED_GPU_MODULES" ]; then
        info "  -> Adding GPU modules to MODULES: $DETECTED_GPU_MODULES"
        # 使用 sed 在 MODULES=() 的括号中插入检测到的模块
        # 替换模式: MODULES=() → MODULES=(nvidia nvidia_modeset ...)
        arch-chroot "$MOUNT_POINT" sed -i \
            "s|^MODULES=()|MODULES=($DETECTED_GPU_MODULES)|" \
            /etc/mkinitcpio.conf
        info "  -> GPU modules added to mkinitcpio.conf"
    else
        info "  -> No GPU-specific modules to add (using fallback modesetting)"
    fi

    # 步骤 3: 设置 Plymouth 主题
    # 优先使用 bgrt 主题 (显示 OEM 徽标), 失败则回退到 spinner
    # bgrt 需要 UEFI 固件提供 BMP 徽标, 部分主板可能不包含
    info "  -> Plymouth theme:"
    if arch-chroot "$MOUNT_POINT" plymouth-set-default-theme bgrt &>/dev/null; then
        info "     bgrt (OEM logo + spinner)"
    else
        arch-chroot "$MOUNT_POINT" plymouth-set-default-theme spinner
        info "     spinner (Arch logo + spinner)"
    fi

    # 步骤 4: 重新生成 initramfs (使 plymouth 钩子生效)
    info "  -> Regenerating initramfs with plymouth support (this may take a moment)..."
    try_cmd "Regenerating initramfs" arch-chroot "$MOUNT_POINT" mkinitcpio -P
    info "  -> initramfs regenerated"

    # 步骤 5: 确认 quiet splash 已配置
    # rEFInd: 参数在 refind_linux.conf 中; GRUB: 在 /etc/default/grub 中
    if [ "$REFIND_OK" = true ] && grep -q 'quiet splash' "${MOUNT_POINT}/boot/refind_linux.conf" 2>/dev/null; then
        info "  -> quiet splash verified (refind_linux.conf)"
    elif grep -q 'quiet splash' "${MOUNT_POINT}/etc/default/grub" 2>/dev/null; then
        info "  -> quiet splash verified (/etc/default/grub)"
    else
        warn "  -> quiet splash not found, check bootloader configuration manually"
    fi
    info "OK: Plymouth boot splash configured"

    # ------------------------------------------------------------------
    # 配置 zram (压缩内存交换设备)
    # ------------------------------------------------------------------
    # 使用 zram 替代传统 swap 分区, 将内存页压缩存储在 RAM 中,
    # 避免磁盘 I/O, 提升交换性能。zram-generator 通过 systemd 自动管理。
    # 默认大小为物理内存的 50%, 压缩算法为 zstd。

    info "Configuring zram swap..."

    # 创建 zram 配置文件
    cat > "${MOUNT_POINT}/etc/systemd/zram-generator.conf" <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

    # 启用 zram-generator 服务
    try_cmd "Enabling zram service" arch-chroot "$MOUNT_POINT" systemctl enable systemd-zram-setup@zram0.service
    info "OK: zram configured (50% RAM, zstd compression)"
    echo ""

    # ------------------------------------------------------------------
    # 配置 Bash 调色 — 系统全局颜色配置 + root 专属配色
    # ------------------------------------------------------------------
    # 配置项:
    #   1. /etc/profile.d/colors.sh — 全局颜色变量和别名 (所有用户共享)
    #   2. /etc/skel/.bashrc        — 新用户默认模板 (首次登录时自动复制)
    #   3. /root/.bashrc           — root 专属配色 (红色提示符)
    #
    # 配色方案:
    #   普通用户 (来自 skel): 绿色用户名 + 蓝色路径
    #   root:                 红色用户名 (醒目标识, 提醒当前为超级用户)
    #
    info "Configuring Bash color scheme (system-wide + root)..."

    # /etc/profile.d/colors.sh — 通用的颜色变量和别名
    # 被 /etc/skel/.bashrc 引用, 所有用户共享
    cat > "${MOUNT_POINT}/etc/profile.d/colors.sh" <<'COLORS'
#!/usr/bin/env bash
# ============================================================
# 颜色变量定义 — 供 Bash 提示符和别名使用
# ============================================================
# 常规颜色
RST='\[\e[0m\]'       # Reset
BLK='\[\e[0;30m\]'    # Black
RED='\[\e[0;31m\]'    # Red
GRN='\[\e[0;32m\]'    # Green
YLW='\[\e[0;33m\]'    # Yellow
BLU='\[\e[0;34m\]'    # Blue
MAG='\[\e[0;35m\]'    # Magenta
CYN='\[\e[0;36m\]'    # Cyan
WHT='\[\e[0;37m\]'    # White
# 加粗版本
BRED='\[\e[1;31m\]'   # Bold Red
BGRN='\[\e[1;32m\]'   # Bold Green
BYLW='\[\e[1;33m\]'   # Bold Yellow
BBLU='\[\e[1;34m\]'   # Bold Blue
BMAG='\[\e[1;35m\]'   # Bold Magenta
BCYN='\[\e[1;36m\]'   # Bold Cyan

# ============================================================
# 终端颜色设置
# ============================================================
# ls 彩色输出 — 覆盖不同平台的表现差异
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# grep 彩色匹配
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# 彩色 diff (如果 colordiff 已安装)
if command -v colordiff &>/dev/null; then
    alias diff='colordiff'
fi

# ============================================================
# Git 分支信息 (用于 PS1)
# ============================================================
__git_ps1() {
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        echo " ($branch)"
    fi
}

# ============================================================
# 目录历史
# ============================================================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
COLORS

    # /etc/skel/.bashrc — 普通用户默认 Bash 配置
    # 新创建的用户会自动复制此文件
    cat > "${MOUNT_POINT}/etc/skel/.bashrc" <<'BASHRC'
#!/usr/bin/env bash
# ============================================================
# 用户 Bash 配置 — 自动从 /etc/skel/.bashrc 生成
# ============================================================

# 加载通用颜色和别名
if [ -f /etc/profile.d/colors.sh ]; then
    source /etc/profile.d/colors.sh
fi

# ============================================================
# Bash 提示符 (PS1) — 普通用户配色
# ============================================================
# 格式:  user@hostname  /current/path  (branch) $
# 配色:  绿色用户名   @  白色  路径  蓝色  Git  青色  $  白色
#
# 如果当前目录是 home, 路径显示为 ~

PS1="${GRN}"'\u'"${RST}"'@'"${WHT}"'\h'"${RST}"' '
PS1+="${BBLU}"'\w'"${RST}"
PS1+='$(__git_ps1 2>/dev/null)'
PS1+='\n'"${GRN}"'$ '"${RST}"''

# ============================================================
# 安全别名
# ============================================================
alias cp='cp -i'        # 覆写前确认
alias mv='mv -i'        # 覆写前确认
alias rm='rm -I'        # 一次删除超过 3 个文件时确认
alias df='df -h'        # 人类可读的磁盘空间
alias du='du -h'        # 人类可读的目录大小
alias free='free -h'    # 人类可读的内存信息
alias ip='ip -c'        # 彩色 ip 输出

# ============================================================
# 系统信息
# ============================================================
alias ports='ss -tulanp'            # 查看所有监听端口
alias myip='curl -s ifconfig.me'    # 查看公网 IP
alias disks='lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT'  # 磁盘信息

# ============================================================
# pacman 快捷别名 (sudo 已配置)
# ============================================================
alias update='sudo pacman -Syu'          # 系统更新
alias install='sudo pacman -S'           # 安装包
alias remove='sudo pacman -Rs'           # 卸载包及其依赖
alias search='pacman -Ss'                # 搜索包
alias orphans='pacman -Qtdq'             # 列出孤儿包
alias cleanup='sudo pacman -Rns $(pacman -Qtdq) 2>/dev/null || echo "No orphans"'

# ============================================================
# 历史记录
# ============================================================
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups   # 忽略重复和以空格开头的命令
export HISTTIMEFORMAT='%F %T  '           # 为 history 添加时间戳
BASHRC

    # ============================================================
    # Root 用户的 Bash 配置 — 红色提示符 (醒目的安全提示)
    # ============================================================
    # root 的 .bashrc 存放在 /root/.bashrc
    # 配色与普通用户相同, 但用户名部分使用红色加粗, 提示当前为超级用户

    # 注意: sudo -i 启动的是 login shell, 不会自动加载 .bashrc
    # 因此 root 的配色和别名需要写入 .bash_profile (login shell 加载)
    cat > "${MOUNT_POINT}/root/.bash_profile" <<'ROOTPROFILE'
#!/usr/bin/env bash
# ============================================================
# Root Login Shell 配置 — sudo -i 后生效
# ============================================================

# 加载通用颜色和别名
if [ -f /etc/profile.d/colors.sh ]; then
    source /etc/profile.d/colors.sh
fi

# 加载 .bashrc (如果存在)
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi
ROOTPROFILE

    cat > "${MOUNT_POINT}/root/.bashrc" <<'ROOTRC'
#!/usr/bin/env bash
# ============================================================
# Root Bash 配置 — 红色提示符, 醒目标识超级用户
# ============================================================

# 加载通用颜色和别名
if [ -f /etc/profile.d/colors.sh ]; then
    source /etc/profile.d/colors.sh
fi

# ============================================================
# Bash 提示符 (PS1) — Root 配色
# ============================================================
# 格式:  root@hostname  /current/path  (branch) #
# 配色:  红色用户名   @  白色  路径  黄色  Git  青色  #  红色
#
# root 的提示符使用红色作为主色调, 与普通用户形成鲜明对比,
# 提醒操作者当前拥有系统最高权限, 操作需谨慎。

PS1="${BRED}"'\u'"${RST}"'@'"${WHT}"'\h'"${RST}"' '
PS1+="${BYLW}"'\w'"${RST}"
PS1+='$(__git_ps1 2>/dev/null)'
PS1+='\n'"${BRED}"'# '"${RST}"''

# ============================================================
# Root 专用别名
# ============================================================
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -I'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias ip='ip -c'
alias ports='ss -tulanp'

# ============================================================
# pacman 快捷 (root 无需 sudo)
# ============================================================
alias update='pacman -Syu'
alias install='pacman -S'
alias remove='pacman -Rs'
alias search='pacman -Ss'
alias orphans='pacman -Qtdq'
alias cleanup='pacman -Rns $(pacman -Qtdq) 2>/dev/null || echo "No orphans"'

# ============================================================
# 安全: 防止 root 误操作
# ============================================================
alias reboot='echo "Use: systemctl reboot"'
alias poweroff='echo "Use: systemctl poweroff"'

# ============================================================
# 历史记录
# ============================================================
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT='%F %T  '
ROOTRC

    info "OK: Root .bashrc configured (red theme — elevated privilege indicator)"
    echo ""

    # GNOME 专属配置 ─────────────────────────────────
    if [ "$INSTALL_DESKTOP" = true ]; then

    # ------------------------------------------------------------------
    # dconf 系统数据库 — GNOME 全局配置 (所有用户继承)
    # ------------------------------------------------------------------
    # dconf 是 GNOME 的底层配置后端, 通过 system-db 可让所有用户
    # 自动继承以下设置, 无需逐个运行 gsettings。
    #
    # 当前配置内容:
    #
    #   [org/gnome/desktop/interface]
    #     icon-theme           = 'Papirus'              图标主题
    #     locale               = 'zh_CN.UTF-8'          界面语言
    #     font-name            = 'Noto Sans CJK SC 12'  界面字体
    #     monospace-font-name  = 'Noto Sans Mono CJK SC 12'  等宽字体
    #     document-font-name   = 'Noto Sans CJK SC 12'  文档字体
    #
    #   [org/gnome/shell]
    #     favorite-apps        = [...]                  收藏栏应用列表
    #     enabled-extensions   = [...]                  默认启用的 Shell 扩展
    #
    #   [org/gnome/shell/extensions/dash-to-dock]
    #     dash-max-icon-size   = 64                     Dock 图标最大尺寸
    #
    #   [org/gnome/settings-daemon/plugins/media-keys]
    #     custom-keybindings   = [...]                  自定义快捷键列表
    #
    #   [org/gnome/settings-daemon/plugins/media-keys/.../custom0]
    #     binding = '<Primary><Alt>t'                   Ctrl+Alt+T
    #     command = 'ptyxis'                            启动终端
    #     name    = 'Launch Terminal'                   快捷键名称
    #
    # 编译方式:
    #   1. 写入 /etc/dconf/db/local.d/local (明文配置)
    #   2. dconf update 编译为二进制 /etc/dconf/db/local
    #   3. /etc/dconf/profile/user 中 system-db:local 指向该数据库
    #
    # 写入 dconf 系统数据库并编译
    mkdir -p "${MOUNT_POINT}/etc/dconf/db/local.d"
    mkdir -p "${MOUNT_POINT}/etc/dconf/profile"
    cat > "${MOUNT_POINT}/etc/dconf/profile/user" <<'PROFILE'
user-db:user
system-db:local
PROFILE
    cat > "/tmp/dconf-local-dbase" <<'DCONF'
[org/gnome/desktop/interface]
icon-theme='Papirus'
locale='zh_CN.UTF-8'
font-name='Noto Sans CJK SC 12'
monospace-font-name='Noto Sans Mono CJK SC 12'
document-font-name='Noto Sans CJK SC 12'

[org/gnome/shell]
favorite-apps=['firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Calendar.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Calculator.desktop', 'org.manjaro.pamac.manager.desktop']
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'appindicatorsupport@rgcjonas.gmail.com', 'ding@rastersoft.com']

[org/gnome/shell/extensions/dash-to-dock]
dash-max-icon-size=64
show-trash=false
show-mounts=false

[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0]
binding='<Primary><Alt>t'
command='ptyxis'
name='Launch Terminal'
DCONF
    cp /tmp/dconf-local-dbase "${MOUNT_POINT}/etc/dconf/db/local.d/local"
    try_cmd "Compiling dconf database" arch-chroot "$MOUNT_POINT" sh -c 'dconf update'
    rm -f /tmp/dconf-local-dbase

    info "OK: Papirus icon theme and favorites set as default"

    # ------------------------------------------------------------------
    # 字体渲染与中文字体优先级
    # ------------------------------------------------------------------
    # 配置 fontconfig 渲染参数和中文字体优先级, 适用于任意分辨率。
    # 字体大小已在 GTK 配置中设为 Noto Sans CJK SC 12, GNOME 会根据
    # 屏幕分辨率自动调整界面缩放。
    #
    info "Configuring font rendering and Chinese font priority..."
    # 字体渲染 (抗锯齿 + rgba hinting + lcdfilter)
    mkdir -p "${MOUNT_POINT}/etc/fonts/conf.d"
    try_cmd "Linking fontconfig hinting" ln -sf /usr/share/fonts/conf.avail/10-hinting-slight.conf "${MOUNT_POINT}/etc/fonts/conf.d/10-hinting-slight.conf"
    try_cmd "Linking fontconfig subpixel" ln -sf /usr/share/fonts/conf.avail/10-subpixel-rgb.conf "${MOUNT_POINT}/etc/fonts/conf.d/10-subpixel-rgb.conf"
    try_cmd "Linking fontconfig lcdfilter" ln -sf /usr/share/fonts/conf.avail/11-lcdfilter-default.conf "${MOUNT_POINT}/etc/fonts/conf.d/11-lcdfilter-default.conf"
    try_cmd "Linking fontconfig no-autohint" ln -sf /usr/share/fonts/conf.avail/10-no-autohint.conf "${MOUNT_POINT}/etc/fonts/conf.d/10-no-autohint.conf"

    # 配置中文字体优先级 (Noto CJK 优先于其他字体)
    mkdir -p "${MOUNT_POINT}/etc/fonts/conf.d"
    cat > "${MOUNT_POINT}/etc/fonts/conf.d/30-chinese-fonts.conf" <<'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fonts:config:fontconfig:config.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans CJK SC</family>
      <family>Noto Sans CJK</family>
      <family>Noto Sans SC</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif CJK SC</family>
      <family>Noto Serif CJK</family>
      <family>Noto Serif SC</family>
    </prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>Noto Sans Mono CJK SC</family>
      <family>Noto Sans Mono CJK</family>
      <family>Noto Sans Mono SC</family>
    </prefer>
  </alias>
</fontconfig>
FONTCONF

    info "OK: Font rendering configured (slight hinting, RGB subpixel, Chinese fonts prioritized)"

    # ------------------------------------------------------------------
    # 配置 ibus 输入法环境变量
    # ------------------------------------------------------------------
    # 写入 /etc/environment, 覆盖 GDM → GNOME Session → 所有图形应用,
    # 确保 Firefox、LibreOffice 等都能使用 ibus 中文输入法。
    #
    info "Configuring ibus input method environment variables..."
    cat > "${MOUNT_POINT}/etc/environment" <<'ENV'
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
ENV
    info "  -> /etc/environment written"

    # ------------------------------------------------------------------
    # Ptyxis 终端名称本地化
    # ------------------------------------------------------------------
    # 将 Name 的值覆盖为 GenericName 的对应翻译, 使终端在各语言下显示为
    # "终端"/"Terminal"/"ターミナル" 而非品牌名 "Ptyxis"。
    # 对每个语言 Name[locale] 均继承 GenericName[locale] 的值。
    PTYXIS_DESKTOP="${MOUNT_POINT}/usr/share/applications/org.gnome.Ptyxis.desktop"
    if [ -f "$PTYXIS_DESKTOP" ]; then
        info "Syncing ptyxis.desktop Name from GenericName translations..."
        # 将每个 Name/Name[locale] 的值直接修改为对应 GenericName 的值
        # 仅限 [Desktop Entry] 区段，不干扰 [Desktop Action *] 区段
        sed -n '/^\[Desktop Entry\]/,/^\[/{
            /^GenericName\[/{
                s/^GenericName\(\[\(.*\)\]\)=\(.*\)/s@^Name\\[\2\\]=.*@Name\\[\2\\]=\3@/p
            }
            /^GenericName=[^[]/{
                s/^GenericName=\(.*\)/s@^Name=.*@Name=\1@/p
            }
        }' "$PTYXIS_DESKTOP" | \
        while IFS= read -r sed_cmd; do
            printf '/^\\[Desktop Entry\\]/,/^\\[/{\n%s\n}\n' "$sed_cmd" > /tmp/_ptyxis_fix
            sed -i -f /tmp/_ptyxis_fix "$PTYXIS_DESKTOP"
        done
        info "  -> Name values synced from GenericName translations"
    fi
    echo ""

    # ------------------------------------------------------------------
    # 隐藏非用户面向的应用图标
    # ------------------------------------------------------------------
    # 以下应用属于系统库、测试工具或 LibreOffice 子组件,
    # 安装后会在 GNOME 概览中产生大量无用图标。
    # 通过 NoDisplay=true 将它们从应用网格中隐藏。
    #
    # 隐藏对象:
    #   avahi-discover / bssh / bvnc     — Avahi 服务浏览工具 (mDNS 调试)
    #   qvidcap / qv4l2                  — V4L2 视频测试工具
    #   system-config-printer            — 打印机设置 (由 Settings 管理)
    #   cups                             — 打印机管理 (CUPS 网页界面)
    #   bluetooth-sendto                 — 蓝牙发送 (由 GNOME 蓝牙接管)
    #   lstopo                           — 硬件拓扑查看器 (hwloc 调试工具)
    #   org.gnome.Evince.desktop         — GNOME 文档查看器 (已被 papers 替代)
    #   libreoffice-base                 — LibreOffice 数据库 (不常用)
    #   libreoffice-draw                 — LibreOffice 绘图 (不常用)
    #   libreoffice-math                 — LibreOffice 公式 (不常用)
    #   libreoffice-xsltfilter           — LibreOffice XSLT 转换器 (不常用)
    #   libreoffice-startcenter          — LibreOffice 启动中心 (GNOME 搜索替代)
    #
    # 调试说明: [HIDE] 日志输出如下
    #   NOT FOUND — .desktop 文件不存在 (包未安装或文件名不匹配)
    #   updated   — NoDisplay 已存在并被改为 true
    #   added     — NoDisplay=true 新写入文件

    # 隐藏非用户面向的应用图标 (在 chroot 内执行，直接操作 /usr/share/applications)
    info "  -> Hiding non-user-facing application icons..."
    # shellcheck disable=SC2016 # 单引号有意为之—变量在 chroot 内展开
    arch-chroot "$MOUNT_POINT" sh -c '
        apps="avahi-discover bssh bvnc qvidcap qv4l2 system-config-printer cups bluetooth-sendto lstopo org.gnome.Evince libreoffice-base libreoffice-draw libreoffice-math libreoffice-startcenter"
        for app in $apps; do
            desktop_file="/usr/share/applications/${app}.desktop"
            if [ ! -f "$desktop_file" ]; then
                echo "[HIDE] ${app}.desktop — NOT FOUND"
                continue
            fi
            if grep -q "^NoDisplay=" "$desktop_file"; then
                current=$(grep "^NoDisplay=" "$desktop_file" | head -1)
                sed -i "s/^NoDisplay=.*/NoDisplay=true/" "$desktop_file"
                echo "[HIDE] ${app}.desktop — ${current} → NoDisplay=true (updated)"
            else
                sed -i "/^\[Desktop Entry\]/a NoDisplay=true" "$desktop_file"
                echo "[HIDE] ${app}.desktop — added NoDisplay=true"
            fi
        done
    ' 2>&1 | while IFS= read -r line; do
        case "$line" in
            *NOT\ FOUND*) warn "  -> $line" ;;
            *)            info "  -> $line" ;;
        esac
    done
    try_cmd "Updating desktop database" arch-chroot "$MOUNT_POINT" update-desktop-database /usr/share/applications
    echo ""

    fi  # END: INSTALL_DESKTOP

    # ------------------------------------------------------------------
    # Root 密码设置 (无桌面环境时必设, 否则无法登录)
    # ------------------------------------------------------------------
    # 有桌面环境时由 gnome-initial-setup 在首次启动时创建用户;
    # 无桌面环境时需在此设置 root 密码。
    if [ "$INSTALL_DESKTOP" != true ]; then
        echo ""
        info "No desktop environment — setting root password is required for login."
        echo ""
        while true; do
            read -r -s -p "Enter root password: " ROOT_PASS1
            echo
            read -r -s -p "Confirm root password: " ROOT_PASS2
            echo
            if [ -z "$ROOT_PASS1" ]; then
                warn "Password cannot be empty. Try again."
                echo ""
                continue
            fi
            if [ "$ROOT_PASS1" != "$ROOT_PASS2" ]; then
                warn "Passwords do not match. Try again."
                echo ""
                continue
            fi
            echo "root:$ROOT_PASS1" | arch-chroot "$MOUNT_POINT" chpasswd && break
            warn "Failed to set password. Try again."
            echo ""
        done
        # 立即清除内存中的密码变量
        unset ROOT_PASS1 ROOT_PASS2
        echo ""
        info "Root password set successfully"
    fi
}

# ============================================================================
# PHASE 5 - 收尾
# ============================================================================
# 卸载分区、打印安装摘要, 并提供重启选项

phase_5_finalise() {
    header
    phase "PHASE 5: Finalisation"
    echo ""

    # 卸载所有挂载的分区
    # umount -R 递归卸载 /mnt 下的所有挂载点
    info "Unmounting partitions..."
    try_cmd "Unmounting partitions" umount -R "$MOUNT_POINT"
    info "OK: Partitions unmounted"
    echo ""

    # 打印安装摘要
    echo "================================================"
    echo "       INSTALLATION COMPLETE"
    echo "================================================"
    echo ""
    echo "  Disk:        $TARGET_DISK"
    echo "  Hostname:    archlinux"
    if [ "$INSTALL_DESKTOP" = true ]; then
        echo "  Desktop:     GNOME"
    else
        echo "  Desktop:     (none — headless system)"
    fi
    echo "  Filesystem:  btrfs (with @, @home, @log, @pkg)"
    echo "  Timezone:    Asia/Shanghai"
    echo "  Install log: ${LOG_FILE}"
    echo ""
    echo "  Next steps:"
    echo "    1. Reboot:  umount -R /mnt && reboot"
    if [ "$INSTALL_DESKTOP" = true ]; then
        echo "    2. Login as <your-user> (configured during first boot)"
        echo "    3. Enjoy Arch Linux with GNOME!"
        if [ "$ROCM_ENABLED" = true ]; then
            echo "    4. ROCm: sudo rocm-setup.sh <your-user>   # add user to video+render groups"
            echo "       Then log out and back in, run: rocminfo"
        fi
    else
        echo "    2. Login as root or your user over SSH"
        echo "    3. Configure the system as needed"
    fi
    echo ""
    echo "================================================"
    echo ""

    # 提供重启选项
    read -r -p "Reboot now? (y/N): " REBOOT_ANSWER
    if [ "$REBOOT_ANSWER" = "y" ] || [ "$REBOOT_ANSWER" = "Y" ]; then
        info "Rebooting..."
        reboot
    else
        info "You can reboot later by running: reboot"
    fi
}

# ============================================================================
# 主函数 - 按顺序执行所有阶段
# ============================================================================
# 如果某个阶段失败, 脚本立即停止, 方便用户排查问题

main() {
    # 初始化日志系统 — 在此之后所有 info/warn/error 都会写入日志文件
    _log_init

    echo ""
    echo "================================================"
    echo "   install.sh"
    echo "   Manual Arch Linux Installation"
    echo "   (No archinstall - pure manual process)"
    echo "================================================"
    echo ""
    info "Installation log: ${LOG_FILE}"
    echo ""

    # 设置清理 trap: 脚本中断或退出时自动卸载已挂载的分区
    # 防止用户在分区/挂载阶段 Ctrl+C 导致磁盘状态不一致
    trap 'echo ""; warn "Interrupted or exited — unmounting ${MOUNT_POINT}..."; umount -R "$MOUNT_POINT" 2>/dev/null || true; info "Cleanup done"' EXIT INT TERM

    phase_0_preflight
    phase_1_partition
    phase_2_format_and_mount
    phase_3_pacstrap
    phase_4_configure
    phase_5_finalise
}

main "$@"
