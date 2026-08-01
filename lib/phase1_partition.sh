#!/usr/bin/env bash
#
# phase1_partition.sh - PHASE 1: 磁盘选择与分区
# ============================================
# 由 install.sh 加载, 定义以下函数:
#   phase_1_partition    主入口: 磁盘选择 → 模式选择 → 调用对应子函数
#   phase_1_full         全盘安装: 清空整盘, 创建全新分区布局
#   phase_1_reinstall    重装模式: 复用已分区, 仅格式化现有 Arch root
#   phase_1_coexist      共存安装: 保留已有分区, 在空闲空间创建新分区
#   phase_1_create_root  在指定起始位置创建 root 分区
#
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

# ============================================================================
# PHASE 1 - 磁盘选择与分区
# ============================================================================

# ----------------------------------------------------------------------------
# 辅助函数 (磁盘命名规则与 ESP 检测)
# ----------------------------------------------------------------------------

# 判断磁盘设备是否使用 "p" 作为分区号分隔符 (NVMe / MMC / VirtIO)
# 用法: _disk_uses_p_prefix <disk>    返回 0=需要 p 前缀, 1=不需要
_disk_uses_p_prefix() {
    echo "$1" | grep -qP '/dev/nvme|/dev/mmcblk'
}

# 从磁盘设备 + 分区号构造完整分区路径 (自动处理 p 前缀)
# 用法: _part_path <disk> <part_num>
_part_path() {
    if _disk_uses_p_prefix "$1"; then
        echo "${1}p${2}"
    else
        echo "${1}${2}"
    fi
}

# 从分区路径反推磁盘设备 (去掉分区号)
# 用法: _disk_from_part <part_path>
_disk_from_part() {
    if _disk_uses_p_prefix "$1"; then
        echo "$1" | sed 's/p[0-9]*$//'
    else
        echo "$1" | sed 's/[0-9]*$//'
    fi
}

# 在指定磁盘上查找 ESP 分区号 (fat32 + esp 标志), 找不到则输出空
# 用法: _find_esp_num <disk>
_find_esp_num() {
    parted "$1" -- print 2>/dev/null | \
        awk '/fat32/ && /esp/ {print $1; exit}' | sed 's/^[[:space:]]*//'
}

phase_1_partition() {
    if phase_should_skip 1; then return; fi
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
        local DISK_LIST=()
        local DISK_NAMES=()
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
    if _disk_uses_p_prefix "$TARGET_DISK"; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="$TARGET_DISK"
    fi

    # ==================================================================
    # 步骤 2: 检测现有 Arch 安装 (通过卷标)
    # ==================================================================
    # 如果存在卷标为 "Arch" 的 btrfs 分区, 表示之前通过本脚本安装过。
    # 此时提供 "重装" 选项: 格式化该分区重新安装, 保留 ESP 不变。

    local EXISTING_ARCH_ROOT=""
    EXISTING_ARCH_ROOT=$(blkid -L Arch 2>/dev/null || lsblk -o LABEL,PATH -nl 2>/dev/null | \
        awk '/^Arch/ {print $2; exit}')

    if [ -n "$EXISTING_ARCH_ROOT" ] && [ -b "$EXISTING_ARCH_ROOT" ]; then
        # 找到同一磁盘上的 ESP
        local EXISTING_ARCH_DISK=""
        EXISTING_ARCH_DISK=$(_disk_from_part "$EXISTING_ARCH_ROOT")

        local EXISTING_ARCH_ESP
        EXISTING_ARCH_ESP=$(_find_esp_num "$EXISTING_ARCH_DISK")
        if [ -n "$EXISTING_ARCH_ESP" ]; then
            EXISTING_ARCH_ESP=$(_part_path "$EXISTING_ARCH_DISK" "$EXISTING_ARCH_ESP")
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
    read -r -p "Press Enter to confirm (or Ctrl+C to abort): "
    info "Confirmed. Proceeding..."
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
    read -r -p "Press Enter to confirm (or Ctrl+C to abort): "
    info "Confirmed. Proceeding..."
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
        esp_num=$(_find_esp_num "$EXISTING_ARCH_DISK")
        if [ -n "$esp_num" ]; then
            EFI_PART=$(_part_path "$EXISTING_ARCH_DISK" "$esp_num")
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
    local EXISTING_ESP SPACE_CHOICE FREE_START FREE_END
    local ESP_SIZE ESP_MIB ESP_END
    echo ""
    info "Analyzing existing partition layout..."

    # 显示已有分区 + 空闲空间 (MiB 单位, 与后续手动输入单位一致)
    parted "$TARGET_DISK" -- unit MiB print free 2>/dev/null || parted "$TARGET_DISK" print
    echo ""

    # 检测是否存在 ESP
    EXISTING_ESP=$(_find_esp_num "$TARGET_DISK")
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
