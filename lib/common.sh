#!/usr/bin/env bash
#
# common.sh - 公共函数与状态变量
# ============================================
# 由 install.sh 加载, 提供所有阶段共用的基础设施:
#   - ANSI 颜色定义
#   - 输出辅助函数 (info/warn/error/header/phase)
#   - 日志系统 (_log_init / _log / run_cmd / try_cmd)
#   - 阶段跳过检查 (phase_should_skip)
#   - 其他辅助函数 (pacstrap_supports_K)
#
# 注意: 本文件被 source 加载, 不要直接执行。

# ============================================================================
# 颜色定义 - 用于区分不同类型的输出信息
# ============================================================================
# 使用 ANSI 转义码为输出着色, 方便快速区分信息类型

readonly RESET='\033[0m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'

# 输出辅助函数 — 同时输出到终端和日志文件
#
# info():   绿色 [INFO]  标签, 记录正常进度
# warn():   黄色 [WARN]  标签, 记录需要注意的事件
# error():  红色 [ERROR] 标签, 记录致命错误
# header(): 青色分隔线, 标注大阶段切换
# phase():  青色 "==="  标签, 标注子阶段名称

info()    { local m="$*"; echo -e "${GREEN}[INFO]${RESET}  $m"; _log "INFO"  "$m"; }
warn()    { local m="$*"; echo -e "${YELLOW}[WARN]${RESET}  $m"; _log "WARN"  "$m"; }
error()   { local m="$*"; echo -e "${RED}[ERROR]${RESET} $m"; _log "ERROR" "$m"; }
header()  { echo -e "\n${CYAN}==================================================${RESET}"; _log "STEP" "──────────────────────────────────────────────"; }
phase()   { local m="$*"; echo -e "${CYAN}=== ${BOLD}$m${RESET}"; _log "STEP" "=== $m"; }

# ============================================================================
# 内部状态变量 - 在安装过程中填充
# ============================================================================
# 注意: TARGET_DISK / FORMAT_ESP / INSTALL_DESKTOP / INSTALL_ROCM 等
# 用户可调参数定义在 config.conf 中, 此处只定义安装过程内部状态。

EFI_PART=""
ROOT_PART=""
PART_PREFIX=""
readonly MOUNT_POINT="/mnt"

# ============================================================================
# 日志系统配置
# ============================================================================
# 所有输出同时写入终端和日志文件, 方便调试时回溯每个步骤的执行情况。
# 日志文件包含时间戳、日志级别和完整命令输出。
#
# 日志文件位置:
#   /tmp/install-<时间戳>.log  (live 环境)
#   脚本运行完后保留在此路径, 如需留存请手动复制

LOG_START_TIME="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/tmp/install-${LOG_START_TIME}.log"

# 初始化日志文件, 写入头部信息
_log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    {
        echo "============================================"
        echo " install.sh 安装日志"
        echo " 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo " 主机名:   $(hostname)"
        echo " 内核:     $(uname -r)"
        echo "============================================"
        echo ""
    } > "$LOG_FILE"
    # 第一阶段日志已就绪, 但此时 /mnt 还未挂载, 暂不复制到目标
}

# 带时间戳的日志写入函数
# 同时写入日志文件和输出到终端
_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${msg}" >> "$LOG_FILE"
}

# 记录命令执行: 先写命令本身, 再捕获输出
# 用法: run_cmd command arg1 arg2...
# 如果命令失败, 会自动记录退出码并调用 error 退出
run_cmd() {
    local cmd_desc="$*"
    _log "CMD" "${cmd_desc}"
    echo "" >> "$LOG_FILE"

    # 创建一个临时文件捕获命令的输出
    local cmd_log
    cmd_log="$(mktemp /tmp/install-cmd-XXXXXX.log)"

    # 执行命令, 同时输出到终端和临时日志
    set +e
    "$@" 2>&1 | tee -a "$cmd_log"
    local exit_code="${PIPESTATUS[0]}"
    set -e

    # 将命令输出合并到主日志
    cat "$cmd_log" >> "$LOG_FILE"
    rm -f "$cmd_log"

    if [ "$exit_code" -ne 0 ]; then
        echo "--- LOG FILE: ${LOG_FILE} ---" >&2
        error "Command failed (exit code ${exit_code}). See log: ${LOG_FILE}"
        exit "$exit_code"
    fi

    _log "OK" "${cmd_desc} completed"
    echo "" >> "$LOG_FILE"
}

# 尝试执行命令 — 失败时仅警告, 不退出脚本
# 用法: try_cmd description command arg1 arg2...
# 用于非关键配置操作 (如 gsettings、符号链接、字体配置等)
try_cmd() {
    local desc="$1"
    shift
    local cmd_desc="$*"
    _log "TRY" "${desc}: ${cmd_desc}"

    set +e
    "$@" &>/dev/null
    local exit_code="$?"
    set -e

    if [ "$exit_code" -ne 0 ]; then
        warn "${desc} skipped (exit code ${exit_code})"
        _log "SKIP" "${desc} failed (exit code ${exit_code})"
    else
        info "OK: ${desc}"
        _log "OK" "${desc} completed"
    fi
}

# 阶段跳过检查 — 如果 RESUME_FROM 已设置且大于当前阶段号，则跳过
# 用法: if phase_should_skip 3; then return; fi
# 放在每个 phase_X 函数的开头，用于从中断处恢复
phase_should_skip() {
    local current_phase="$1"
    if [ -n "$RESUME_FROM" ] && [ "$current_phase" -lt "$RESUME_FROM" ] 2>/dev/null; then
        info "Skipping Phase ${current_phase} (RESUME_FROM=${RESUME_FROM})"
        return 0
    fi
    return 1
}

# 检测 pacstrap 是否支持 -K 标志（arch-install-scripts >= 28）
pacstrap_supports_K() {
    pacstrap --help 2>&1 | grep -q -- '-K'
}
