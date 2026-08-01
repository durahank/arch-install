#!/usr/bin/env bash
#
# phase0_preflight.sh - PHASE 0: 安装前检查
# ============================================
# 由 install.sh 加载, 定义 phase_0_preflight 函数。
# 在实际修改磁盘前, 确认运行环境满足以下条件:
#   - root 权限 (大部分操作需要)
#   - UEFI 模式 (脚本仅支持 UEFI)
#   - 网络连通 (pacman 需要下载包)
#   - 时钟同步 (避免 SSL 证书验证失败)

# ============================================================================
# PHASE 0 - 安装前检查
# ============================================================================

phase_0_preflight() {
    if phase_should_skip 0; then return; fi
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
