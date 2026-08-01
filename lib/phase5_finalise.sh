#!/usr/bin/env bash
#
# phase5_finalise.sh - PHASE 5: 收尾
# ============================================
# 由 install.sh 加载, 定义 phase_5_finalise 函数。
# 卸载分区、打印安装摘要, 并提供重启选项

# ============================================================================
# PHASE 5 - 收尾
# ============================================================================

phase_5_finalise() {
    if phase_should_skip 5; then return; fi
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
    echo "  Timezone:    ${TIMEZONE}"
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

    # 提供重启选项 — 直接回车重启, 输入任意字符跳过
    _prompt "Press Enter to reboot (or type anything to skip): " REBOOT_ANSWER
    if [ -z "$REBOOT_ANSWER" ]; then
        info "Rebooting..."
        reboot
    else
        info "You can reboot later by running: reboot"
    fi
}
