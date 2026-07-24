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
- **系统美化** — Plymouth 开机动画、GRUB/rEFInd 主题
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
    ├── Swap 分区 (可选)
    └── Btrfs 根分区

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
    ├── 引导器 (GRUB / rEFInd)
    └── Plymouth 开机动画

phase_5_finalise            # 收尾
    ├── 网络和时区
    ├── 交换文件 / ZRAM
    └── 桌面环境后置配置
```

## 自定义配置

脚本开头的常量区域可调整关键参数：

```bash
TARGET_DISK=""          # 目标磁盘（如 /dev/sda）
INSTALL_DESKTOP=true    # 是否安装 GNOME 桌面
FORMAT_ESP=true         # 全盘安装时格式化 ESP
```

## 依赖

脚本自带所有依赖，只需从 Arch ISO 启动并连接网络即可。

## 许可

[MIT](LICENSE)
