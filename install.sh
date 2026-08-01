#!/usr/bin/env bash
#
# install.sh - Arch Linux 手动安装脚本
# ============================================
#
# 一个完整的 Arch Linux 手动安装脚本。不依赖 archinstall 工具, 全程使用原始命令。
# 脚本按阶段拆分到 lib/ 目录, 可调参数集中在 config.conf。
#
# 使用方法:
#   从 Arch 官方 ISO 启动后, 执行:
#       bash install.sh
#
# 目录结构:
#   install.sh              主入口 — 加载配置与各阶段模块, 按顺序执行
#   config.conf             用户配置 — 所有可调参数 (时区/语言/主机名/安装开关等)
#   lib/
#     common.sh             公共函数 — 颜色/日志/辅助函数/状态变量
#     packages.sh           软件包清单 — 按类别组织的软件包列表
#     mirrors.sh            预设镜像源 — 各国 fallback 镜像 (reflector 失败时使用)
#     phase0_preflight.sh   阶段 0 — 安装前检查 (root/UEFI/网络/时钟)
#     phase1_partition.sh   阶段 1 — 磁盘选择与分区 (全盘/共存/重装)
#     phase2_format_mount.sh 阶段 2 — 格式化和挂载 (btrfs + 子卷)
#     phase3_pacstrap.sh    阶段 3 — 安装基础系统和 GNOME 桌面
#     phase4_configure.sh   阶段 4 — Chroot 系统配置
#     phase5_finalise.sh    阶段 5 — 收尾 (卸载/摘要/重启)

set -euo pipefail

# ----------------------------------------------------------------------------
# 定位脚本所在目录
# ----------------------------------------------------------------------------
# 支持两种运行方式:
#   1) 本地克隆/完整下载:  bash install.sh
#   2) 单文件管道:         curl -fsSL <raw-url> | bash   (stdin 模式无 BASH_SOURCE)
# 单文件模式下同目录缺少 config.conf / lib/, 自动从 GitHub 拉取完整仓库。

if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi

if [ ! -f "${SCRIPT_DIR}/config.conf" ] || [ ! -d "${SCRIPT_DIR}/lib" ]; then
    echo "[INFO] 未检测到完整模块 (config.conf / lib/), 正在从 GitHub 拉取最新版本..."
    FETCH_DIR="$(mktemp -d)"
    if ! curl -fsSL "https://github.com/durahank/arch-install/archive/refs/heads/main.tar.gz" \
        | tar -xz -C "${FETCH_DIR}"; then
        rm -rf "${FETCH_DIR}"
        echo "[ERROR] 从 GitHub 拉取脚本失败, 请检查网络或改用完整克隆方式。" >&2
        exit 1
    fi
    SCRIPT_DIR="${FETCH_DIR}/arch-install-main"
    echo "[INFO] 已拉取到临时目录: ${SCRIPT_DIR}"
fi

# 加载用户配置文件
# shellcheck source=config.conf
source "${SCRIPT_DIR}/config.conf"

# 加载公共函数 (颜色/日志/辅助函数/状态变量)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# 加载软件包清单
# shellcheck source=lib/packages.sh
source "${SCRIPT_DIR}/lib/packages.sh"

# 加载预设镜像源 (各国 fallback 镜像)
# shellcheck source=lib/mirrors.sh
source "${SCRIPT_DIR}/lib/mirrors.sh"

# 加载各安装阶段模块
# shellcheck source=lib/phase0_preflight.sh
source "${SCRIPT_DIR}/lib/phase0_preflight.sh"
# shellcheck source=lib/phase1_partition.sh
source "${SCRIPT_DIR}/lib/phase1_partition.sh"
# shellcheck source=lib/phase2_format_mount.sh
source "${SCRIPT_DIR}/lib/phase2_format_mount.sh"
# shellcheck source=lib/phase3_pacstrap.sh
source "${SCRIPT_DIR}/lib/phase3_pacstrap.sh"
# shellcheck source=lib/phase4_configure.sh
source "${SCRIPT_DIR}/lib/phase4_configure.sh"
# shellcheck source=lib/phase5_finalise.sh
source "${SCRIPT_DIR}/lib/phase5_finalise.sh"

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
    if [ -n "$RESUME_FROM" ]; then
        info "RESUME MODE: Starting from Phase ${RESUME_FROM} (skipping phases 0-$((RESUME_FROM - 1)))"
    fi
    echo ""

    # 设置清理 trap: 脚本中断或退出时自动卸载已挂载的分区
    # 防止用户在分区/挂载阶段 Ctrl+C 导致磁盘状态不一致
    # 同时清理单文件模式下自举下载的临时目录 (如有)
    trap 'echo ""; warn "Interrupted or exited — unmounting ${MOUNT_POINT}..."; umount -R "$MOUNT_POINT" 2>/dev/null || true; if [ -n "${FETCH_DIR:-}" ]; then rm -rf "$FETCH_DIR"; fi; info "Cleanup done"' EXIT INT TERM

    phase_0_preflight
    phase_1_partition
    phase_2_format_and_mount
    phase_3_pacstrap
    phase_4_configure
    phase_5_finalise
}

main "$@"
