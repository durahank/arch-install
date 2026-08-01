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

## 项目结构

脚本按职责拆分为模块，可调参数集中在一个配置文件：

```
arch-install/
├── install.sh               # 主入口 — 加载配置与各阶段模块，按顺序执行
├── config.conf              # 用户配置 — 所有可调参数（时区/语言/主机名/安装开关等）
└── lib/
    ├── common.sh            # 公共函数 — 颜色/日志/辅助函数/状态变量
    ├── packages.sh          # 软件包清单 — 按类别组织的软件包列表
    ├── phase0_preflight.sh  # 阶段 0 — 安装前检查（root/UEFI/网络/时钟）
    ├── phase1_partition.sh  # 阶段 1 — 磁盘选择与分区（全盘/共存/重装）
    ├── phase2_format_mount.sh # 阶段 2 — 格式化和挂载（btrfs + 子卷）
    ├── phase3_pacstrap.sh   # 阶段 3 — 安装基础系统和 GNOME 桌面
    ├── phase4_configure.sh  # 阶段 4 — Chroot 系统配置
    └── phase5_finalise.sh   # 阶段 5 — 收尾（卸载/摘要/重启）
```

## 使用方法

### 1. 启动 Arch 官方 ISO

从 [Arch Linux 下载页](https://archlinux.org/download/) 获取 ISO，写入 U 盘启动。

### 2. 获取脚本

```bash
# 方式一：直接下载
curl -O https://raw.githubusercontent.com/durahank/arch-install/main/install.sh

# 方式二：克隆仓库（推荐，包含 config.conf 和 lib/ 模块）
git clone https://github.com/durahank/arch-install.git
cd arch-install
```

> ⚠️ **注意**：脚本已被拆分，必须克隆整个仓库（或下载全部文件）后运行，
> 单独下载 `install.sh` 无法工作。

### 3. （可选）修改配置

编辑 `config.conf`，调整安装参数：

```bash
nano config.conf
```

### 4. 运行

```bash
bash install.sh
```

> 脚本从 ISO 启动后默认以 **root** 运行，无需 `sudo`。

## 自定义配置

所有可调参数都在 `config.conf` 中，带详细注释：

```bash
TARGET_DISK=""              # 目标磁盘（如 /dev/sda），留空则自动检测/手动选择
INSTALL_DESKTOP=true        # 是否安装 GNOME 桌面
INSTALL_ROCM=true           # 是否安装 ROCm（AMD GPU 计算平台）
FORMAT_ESP=true             # 全盘安装时格式化 ESP
RESUME_FROM=""              # 从中断处恢复：设为 3 跳过 Phase 0-2，从 pacstrap 继续

TIMEZONE="Asia/Shanghai"    # 系统时区
SYSTEM_LOCALE="zh_CN.UTF-8" # 系统语言
HOSTNAME="archlinux"        # 主机名
SSH_PORT=22                 # SSH 监听端口
# ... 其余参数见文件内注释
```

### 从中断处恢复

安装过程中断（如网络超时、SSH 断连、误关闭终端）后，可跳过已完成的阶段直接恢复：

1. 重新进入 Arch ISO 环境
2. 挂载已有的分区到 `/mnt`
3. 编辑 `config.conf`，将 `RESUME_FROM` 设为中断的阶段号，然后运行

**示例**：日志显示中断在 Phase 3（pacstrap），则：

```bash
# 先挂载已有分区（如果 /mnt 未挂载）
mount /dev/vda2 /mnt
mount /dev/vda1 /mnt/boot/efi    # 如 ESP 未挂载
# 安装后阶段的依赖工具（arch-install-scripts）
pacman -Sy arch-install-scripts  # 确保 pacstrap 可用

# 编辑配置后运行
RESUME_FROM=3 bash install.sh
```

### pacstrap 兼容性

脚本自动检测当前 ISO 的 `pacstrap` 版本是否支持 `-K`（内核密钥环）标志，
无需手动修改。较旧的 Arch ISO（2024 年 3 月前）不带 `-K` 支持，脚本会自动降级。

## 开发

修改各阶段逻辑时，编辑 `lib/` 下对应的模块文件即可；新增阶段时，
在 `lib/` 下创建 `phaseN_xxx.sh` 并在 `install.sh` 中加载、在 `main()` 中调用。

## 依赖

脚本自带所有依赖，只需从 Arch ISO 启动并连接网络即可。

## 许可

[MIT](LICENSE)
