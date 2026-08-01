#!/usr/bin/env bash
#
# phase4_configure.sh - PHASE 4: Chroot 系统配置
# ============================================
# 由 install.sh 加载, 定义 phase_4_configure 函数。
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

# ============================================================================
# PHASE 4 - Chroot 系统配置
# ============================================================================

phase_4_configure() {
    if phase_should_skip 4; then return; fi
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
    genfstab -U "$MOUNT_POINT" > "${MOUNT_POINT}/etc/fstab"

    if [ ! -s "${MOUNT_POINT}/etc/fstab" ]; then
        error "fstab is empty - genfstab may have failed."
        exit 1
    fi
    info "OK: fstab generated at /etc/fstab"

    # ------------------------------------------------------------------
    # 时区配置
    # ------------------------------------------------------------------
    # 设置时区
    # /etc/localtime 是指向 /usr/share/zoneinfo/ 下文件的符号链接
    info "Setting timezone to ${TIMEZONE}..."
    arch-chroot "$MOUNT_POINT" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    # 同步硬件时钟 (RTC) 到 UTC
    # 推荐所有 Unix-like 系统使用 UTC, 避免时区转换问题
    # 虚拟机中可能无法访问硬件时钟, 失败时继续
    arch-chroot "$MOUNT_POINT" hwclock --systohc 2>/dev/null || true
    info "OK: Timezone set to ${TIMEZONE}"

    # ------------------------------------------------------------------
    # 语言环境 (locale) 配置
    # ------------------------------------------------------------------
    # 取消 en_US.UTF-8 和 zh_CN.UTF-8 的注释, 然后生成 locale 数据
    # zh_CN.UTF-8 为中文语言包提供基础 locale 支持
    info "Generating locale (${SYSTEM_LOCALE} + en_US.UTF-8)..."
    arch-chroot "$MOUNT_POINT" sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    arch-chroot "$MOUNT_POINT" sed -i "s/^#${SYSTEM_LOCALE}/${SYSTEM_LOCALE}/" /etc/locale.gen
    arch-chroot "$MOUNT_POINT" locale-gen
    # 配置语言环境 (直接写 /etc/locale.conf, 避免 localectl 在 chroot
    # 中行为不稳定导致 gnome-initial-setup 无法识别语言)
    echo "LANG=${SYSTEM_LOCALE}" > "${MOUNT_POINT}/etc/locale.conf"
    # 配置 vconsole (终端键盘布局)
    echo "KEYMAP=${KEYMAP}" > "${MOUNT_POINT}/etc/vconsole.conf"
    info "OK: Locale configured (${SYSTEM_LOCALE})"
    
    # ------------------------------------------------------------------
    # 主机名与 /etc/hosts 配置
    # ------------------------------------------------------------------
    # 设置主机名 (仅写入 /etc/hostname, 由系统启动时读取)
    info "Setting hostname to ${HOSTNAME}..."
    echo "${HOSTNAME}" > "${MOUNT_POINT}/etc/hostname"
    # 配置 /etc/hosts
    # 确保主机名能解析到回环地址, 某些服务依赖此配置
    cat > "${MOUNT_POINT}/etc/hosts" <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS
    info "OK: Hostname set to ${HOSTNAME}"

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
    cat > "${MOUNT_POINT}/etc/ssh/sshd_config" <<SSHD
# OpenSSH server configuration — hardened desktop defaults
# Managed by install.sh; manual overrides go in /etc/ssh/sshd_config.d/
Include /etc/ssh/sshd_config.d/*.conf

# 监听
Port ${SSH_PORT}
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
    arch-chroot "$MOUNT_POINT" ufw allow "${SSH_PORT}/tcp" comment 'SSH'
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
    # 引导管理器安装 (同时安装 rEFInd + GRUB, 双引导管理器并行)
    # ------------------------------------------------------------------
    # 共用变量提前提取
    ROOT_UUID=$(awk '$2 == "/" { print $1 }' "${MOUNT_POINT}/etc/fstab" | sed 's/^UUID=//' || true)
    NVIDIA_MODESET_PARAM=""
    [ "${GPU_HAVE_NVIDIA:-false}" = true ] && NVIDIA_MODESET_PARAM="nvidia_drm.modeset=1"

    # --- 1. rEFInd ---
    info "Installing rEFInd boot manager..."
    REFIND_OK=false
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

    if [ "$REFIND_OK" = true ] && [ -n "$ROOT_UUID" ]; then
        # rEFInd 成功 — 创建 refind_linux.conf
        cat > "${MOUNT_POINT}/boot/refind_linux.conf" <<REFIND
"Boot with standard options"  "root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet splash ${NVIDIA_MODESET_PARAM}"
"Boot to single-user mode"    "root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet splash single ${NVIDIA_MODESET_PARAM}"
"Boot with minimal options"   "root=UUID=${ROOT_UUID} rw rootflags=subvol=@ ${NVIDIA_MODESET_PARAM}"
REFIND
        info "  -> /boot/refind_linux.conf created (root=UUID=$ROOT_UUID, subvol=@)"
        # 注意: rEFInd 自动检测并加载微码 (intel-ucode.img / amd-ucode.img), 无需在 kernel
        # cmdline 中加 initrd= 参数。手动加入会导致内核找不到文件且替代 initramfs。

        local esp_refind="${MOUNT_POINT}/boot/efi/EFI/refind/refind_linux.conf"
        if [ -d "$(dirname "$esp_refind")" ]; then
            cp "${MOUNT_POINT}/boot/refind_linux.conf" "$esp_refind"
            info "  -> Copied to ESP: ${esp_refind}"
        fi
    elif [ "$REFIND_OK" = true ]; then
        warn "  -> rEFInd installed but root UUID not found, refind_linux.conf not created"
    else
        warn "  -> rEFInd install failed, continuing with GRUB only"
    fi

    # --- 2. GRUB ---
    info "Installing GRUB bootloader (no-nvram — rEFInd remains default)..."
    if arch-chroot "$MOUNT_POINT" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=arch \
        --no-nvram; then
        info "OK: GRUB installed"
        # 添加 quiet splash 到 GRUB 命令行, NVIDIA 时追加 modeset=1
        GRUB_CMDLINE_EXTRA="quiet splash"
        [ "${GPU_HAVE_NVIDIA:-false}" = true ] && GRUB_CMDLINE_EXTRA="$GRUB_CMDLINE_EXTRA nvidia_drm.modeset=1"
        arch-chroot "$MOUNT_POINT" sed -i \
            's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 '"${GRUB_CMDLINE_EXTRA}"'"/' \
            /etc/default/grub
        arch-chroot "$MOUNT_POINT" grub-mkconfig -o /boot/grub/grub.cfg
        info "OK: GRUB configuration generated"
    else
        warn "  -> GRUB install failed. You may need to install bootloader manually."
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
    cat > "${MOUNT_POINT}/etc/systemd/zram-generator.conf" <<ZRAM
[zram0]
zram-size = ${ZRAM_SIZE}
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
    cat > "/tmp/dconf-local-dbase" <<DCONF
[org/gnome/desktop/interface]
icon-theme='Papirus'
locale='${SYSTEM_LOCALE}'
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
    #   cmake-gui                        — CMake GUI 配置工具 (命令行优先)
    #   org.gnome.Evince		         — GNOME 文档查看器 (已被 papers 替代)
    #   libreoffice-base                 — LibreOffice 数据库 (不常用)
    #   libreoffice-draw                 — LibreOffice 绘图 (不常用)
    #   libreoffice-math                 — LibreOffice 公式 (不常用)
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
        apps="avahi-discover bssh bvnc qvidcap qv4l2 system-config-printer cups bluetooth-sendto lstopo cmake-gui org.gnome.Evince libreoffice-base libreoffice-draw libreoffice-math libreoffice-startcenter"
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
            _prompt_secret "Enter root password: " ROOT_PASS1
            _prompt_secret "Confirm root password: " ROOT_PASS2
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
            printf 'root:%s' "$ROOT_PASS1" | arch-chroot "$MOUNT_POINT" chpasswd && break
            warn "Failed to set password. Try again."
            echo ""
        done
        # 立即清除内存中的密码变量
        unset ROOT_PASS1 ROOT_PASS2
        echo ""
        info "Root password set successfully"
    fi
}
