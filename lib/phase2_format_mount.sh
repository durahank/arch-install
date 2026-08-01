#!/usr/bin/env bash
#
# phase2_format_mount.sh - PHASE 2: 格式化和挂载 (btrfs + 子卷)
# ============================================
# 由 install.sh 加载, 定义 phase_2_format_and_mount 函数。
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

# ============================================================================
# PHASE 2 - 格式化和挂载 (btrfs + 子卷)
# ============================================================================

phase_2_format_and_mount() {
    if phase_should_skip 2; then return; fi
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
