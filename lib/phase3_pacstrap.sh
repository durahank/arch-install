#!/usr/bin/env bash
#
# phase3_pacstrap.sh - PHASE 3: 安装基础系统和 GNOME 桌面
# ============================================
# 由 install.sh 加载, 定义 phase_3_pacstrap 函数。
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

# ============================================================================
# PHASE 3 - 安装基础系统和 GNOME 桌面
# ============================================================================

phase_3_pacstrap() {
    if phase_should_skip 3; then return; fi
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
        --country "${REFLECTOR_COUNTRY}" \
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
            echo "Server = ${ARCHLINUXCN_MIRROR}"
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
        NPU_DETECTED=true

    # AMD NPU — 通过 PCI vid=1022 + 关键词检测
    elif [ -n "$NPU_INFO" ] && echo "$NPU_INFO" | grep -qiE '1022|amd.*npu|amd.*neural'; then
        DETECTED_GPU_MODULES="$DETECTED_GPU_MODULES amdxdna"
        PACKAGES_HARDWARE_DETECTED="$PACKAGES_HARDWARE_DETECTED xrt-plugin-amdxdna"
        info "  -> NPU: AMD (amdxdna + xrt-plugin-amdxdna)"
        NPU_DETECTED=true
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
    PACSTRAP_OPTS=()
    if pacstrap_supports_K; then
        PACSTRAP_OPTS+=(-K)
        info "  -> pacstrap supports -K (kernel keyring)"
    else
        info "  -> pacstrap does not support -K (older arch-install-scripts)"
    fi
    info "Running: pacstrap ${PACSTRAP_OPTS[*]} $MOUNT_POINT ..."
    # 用 script -qfc 创建伪终端 (PTY)，让 pacman 认为 stdout 是真实终端，
    # 从而正常显示下载进度条和速率。输出同时通过 tee 写入日志。
    echo ""
    _log "CMD" "pacstrap ${PACSTRAP_OPTS[*]} $MOUNT_POINT ..."
    echo "" >> "$LOG_FILE"
    set +e
    script -qfc "pacstrap ${PACSTRAP_OPTS[*]} $MOUNT_POINT $ALL_PACKAGES" /dev/null 2>&1 | tee -a "$LOG_FILE"
    PACSTRAP_EXIT="${PIPESTATUS[0]}"
    set -e
    if [ "$PACSTRAP_EXIT" -ne 0 ]; then
        echo "--- LOG FILE: ${LOG_FILE} ---" >&2
        error "pacstrap failed (exit code ${PACSTRAP_EXIT}). See log: ${LOG_FILE}"
        exit "$PACSTRAP_EXIT"
    fi
    _log "OK" "pacstrap completed"

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
            echo "Server = ${ARCHLINUXCN_MIRROR}"
        } >> "${MOUNT_POINT}/etc/pacman.conf"
        info "OK: [archlinuxcn] persisted in target system"
    else
        info "OK: [archlinuxcn] already in target pacman.conf (skipped)"
    fi

    # 启用并行下载, 大幅加速 pacman 软件包安装和系统更新
    # 默认 Arch 的 ParallelDownloads=5 被注释, 此处启用并设为 10
    info "Enabling parallel downloads (ParallelDownloads=10)..."
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' "${MOUNT_POINT}/etc/pacman.conf" || true
    # 启用彩色输出 (Color)
    sed -i 's/^#Color/Color/' "${MOUNT_POINT}/etc/pacman.conf" || true
    info "OK: ParallelDownloads = 10 enabled in target system"

    info "OK: All packages installed successfully!"
    echo ""
}
