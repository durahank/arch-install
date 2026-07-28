# Arch Linux 手动安装脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个不依赖 `archinstall` 工具、全程使用原始命令的 Arch Linux 自动化安装脚本。  
从 Arch 官方 ISO 启动后，一条命令即可完成全自动安装。

## 功能特性

- **全自动安装** — 预检 → 分区 → 格盘挂载 → 基础系统 → 配置 → 收尾，一气呵成
- **三种安装模式**
  - **全盘安装** — 自动擦除目标磁盘，全新安装
  - **共存安装** — 与现有系统共存，不破坏已有数据
  - **重装模式** — 复用已有分区，仅覆写系统
- **硬件自动检测**
  - 自动识别 GPU（NVIDIA / AMD / Intel / VMware / VirtualBox / QEMU）
  - 自动识别 NPU（Intel VPU / AMD NPU）
  - 自动识别蓝牙适配器
- **可选桌面环境** — GNOME + 常用第三方应用
- **系统美化** — Plymouth 开机动画、rEFInd 三模式引导菜单
- **完善日志** — 全步骤日志记录到 `/tmp/install-<时间戳>.log`

## 使用方法

### 1. 启动 Arch 官方 ISO

从 [Arch Linux 下载页](https://archlinux.org/download/) 获取 ISO，写入 U 盘启动。

### 2. 获取脚本

```bash
# 方式一：直接下载
curl -O https://raw.githubusercontent.com/durahank/arch-install/main/install.sh

# 方式二：克隆仓库
git clone https://github.com/durahank/arch-install.git
cd arch-install
```

### 3. 运行

```bash
bash install.sh
```

> 脚本从 ISO 启动后默认以 **root** 运行，无需 `sudo`。

## 安装流程

```
phase_0_preflight           # 预检：网络、磁盘、硬件检测
    ├── 检测 GPU / NPU / 蓝牙
    └── 确认安装模式（全盘/共存/重装）

phase_1_partition           # 分区
    ├── GPT 分区表
    ├── EFI 系统分区 (ESP)
    ├── Btrfs 根分区
    └── ZRAM 压缩交换 (无需单独 swap 分区)

phase_2_format_and_mount    # 格盘挂载
    ├── 格式化 ESP (FAT32)
    ├── 创建 Btrfs 子卷 (@ / @home / @cache ...)
    └── 挂载到 /mnt

phase_3_pacstrap            # 安装基础系统
    ├── base / linux / linux-firmware
    ├── 硬件驱动和微码
    └── 桌面环境 (可选)

phase_4_configure           # 系统配置
    ├── fstab / hostname / locale
    ├── 用户和 sudo
    ├── 引导器 (rEFInd 三模式 / GRUB 回退)
    ├── Plymouth 开机动画
    └── SSH 加固 + 非用户面向图标隐藏

phase_5_finalise            # 收尾
    ├── 网络和时区
    ├── 交换文件 / ZRAM
    └── 桌面环境后置配置
```

## 自定义配置

脚本开头的常量区域可调整关键参数：

```bash
TARGET_DISK=""              # 目标磁盘（如 /dev/sda）
INSTALL_DESKTOP=true        # 是否安装 GNOME 桌面
FORMAT_ESP=true             # 全盘安装时格式化 ESP
RESUME_FROM=""              # 从中断处恢复：设为 3 跳过 Phase 0-2，从 pacstrap 继续
```

### 从中断处恢复

安装过程中断（如网络超时、SSH 断连、误关闭终端）后，可跳过已完成的阶段直接恢复：

1. 重新进入 Arch ISO 环境
2. 挂载已有的分区到 `/mnt`
3. 编辑 `install.sh`，将 `RESUME_FROM` 设为中断的阶段号，然后运行

**示例**：日志显示中断在 Phase 3（pacstrap），则：

```bash
# 先挂载已有分区（如果 /mnt 未挂载）
mount /dev/vda2 /mnt
mount /dev/vda1 /mnt/boot/efi    # 如 ESP 未挂载
# 安装后阶段的依赖工具（arch-install-scripts）
pacman -Sy arch-install-scripts  # 确保 pacstrap 可用

# 编辑脚本后运行
RESUME_FROM=3 bash install.sh
```

### pacstrap 兼容性

脚本自动检测当前 ISO 的 `pacstrap` 版本是否支持 `-K`（内核密钥环）和 `--needed` 标志，
无需手动修改。较旧的 Arch ISO（2024 年 3 月前）不带 `-K` 支持，脚本会自动降级。

## 依赖

脚本自带所有依赖，只需从 Arch ISO 启动并连接网络即可。

## 许可

[MIT](LICENSE)
