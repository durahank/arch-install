#!/usr/bin/env bash
#
# mirrors.sh - 各国预设镜像源 (reflector 失败时的 fallback)
# ============================================================
# 由 install.sh 加载, 提供:
#   PRESET_MIRRORS          关联数组: 国家 -> 镜像 Server 行 (多行字符串)
#   preset_mirrorlist()     生成指定国家的完整 mirrorlist 内容 (含官方 fallback)
#
# 镜像来源: https://archlinux.org/mirrors/status/json/  (HTTPS, 评分最优)
# 如需添加国家: 在 PRESET_MIRRORS 中新增一个键即可, 键名与
# config.conf 的 PRESET_MIRROR_COUNTRY 取值对应。
#
# 注意: 值中的 \$repo / \$arch 保留字面量 (source 时反斜杠转义),
#       写入 mirrorlist 后由 pacman 在运行时展开, 不要去掉反斜杠。

# ============================================================================
# 各国预设镜像
# ============================================================================
# 每个条目 = 该国的 Server 行集合 (按评分/可靠性排序, 每行一个镜像)

declare -A PRESET_MIRRORS=(
    [China]="## China - Preset mirrors (sorted by speed and reliability)
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch
Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.huaweicloud.com/archlinux/\$repo/os/\$arch
Server = https://mirror.xtom.com.hk/archlinux/\$repo/os/\$arch
Server = https://mirrors.163.com/archlinux/\$repo/os/\$arch
Server = https://mirror.fsmirrorey.cn/archlinux/\$repo/os/\$arch"

    [Japan]="## Japan - Preset mirrors
Server = https://jp.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://www.miraa.jp/archlinux/\$repo/os/\$arch
Server = https://mirrors.cat.net/archlinux/\$repo/os/\$arch
Server = https://ftp.yz.yamagata-u.ac.jp/pub/linux/archlinux/\$repo/os/\$arch
Server = https://mirror.rain.ne.jp/archlinux/\$repo/os/\$arch"

    [United States]="## United States - Preset mirrors
Server = https://arch.mirror.constant.com/\$repo/os/\$arch
Server = https://us.arch.niranjan.co/\$repo/os/\$arch
Server = https://mirror.givebytes.net/archlinux/\$repo/os/\$arch
Server = https://us.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://losangeles.mirror.pkgbuild.com/\$repo/os/\$arch"

    [Germany]="## Germany - Preset mirrors
Server = https://mirror.moson.org/arch/\$repo/os/\$arch
Server = https://frankfurt.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://berlin.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://arch.jensgutermuth.de/\$repo/os/\$arch
Server = https://de.arch.mirror.kescher.at/\$repo/os/\$arch"

    [Singapore]="## Singapore - Preset mirrors
Server = https://sg.arch.niranjan.co/\$repo/os/\$arch
Server = https://singapore.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.sg.cdn-perfprod.com/archlinux/\$repo/os/\$arch
Server = https://sg.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://download.nus.edu.sg/mirror/archlinux/\$repo/os/\$arch"

    [United Kingdom]="## United Kingdom - Preset mirrors
Server = https://london.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://uk.arch.niranjan.co/\$repo/os/\$arch
Server = https://archlinux.uk.mirror.allworldit.com/archlinux/\$repo/os/\$arch
Server = https://gb.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://uk.repo.c48.uk/arch/\$repo/os/\$arch"

    [Australia]="## Australia - Preset mirrors
Server = https://au.arch.niranjan.co/\$repo/os/\$arch
Server = https://mirror.aarnet.edu.au/pub/archlinux/\$repo/os/\$arch
Server = https://au.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://gsl-syd.mm.fcix.net/archlinux/\$repo/os/\$arch"

    [South Korea]="## South Korea - Preset mirrors
Server = https://mirror2.keiminem.com/archlinux/\$repo/os/\$arch
Server = https://mirror.keiminem.com/archlinux/\$repo/os/\$arch
Server = https://mirror.krfoss.org/archlinux/\$repo/os/\$arch
Server = https://mirror.funami.tech/arch/\$repo/os/\$arch
Server = https://kr.mirrors.cicku.me/archlinux/\$repo/os/\$arch"

    [Taiwan]="## Taiwan - Preset mirrors
Server = https://taipei.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.twds.com.tw/archlinux/\$repo/os/\$arch
Server = https://tw.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://archlinux.cs.nycu.edu.tw/\$repo/os/\$arch
Server = https://archlinux.ccns.ncku.edu.tw/archlinux/\$repo/os/\$arch"

    [Hong Kong]="## Hong Kong - Preset mirrors
Server = https://hk.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://mirror.xtom.com.hk/archlinux/\$repo/os/\$arch
Server = https://arch-mirror.wtako.net/\$repo/os/\$arch
Server = https://hkg.mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirror-hk.koddos.net/archlinux/\$repo/os/\$arch"

    [India]="## India - Preset mirrors
Server = https://mirrors.saswata.cc/archlinux/\$repo/os/\$arch
Server = https://in.arch.niranjan.co/\$repo/os/\$arch
Server = https://mirror.sahil.world/archlinux/\$repo/os/\$arch
Server = https://in.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://mirrors.abhy.me/archlinux/\$repo/os/\$arch"

    [France]="## France - Preset mirrors
Server = https://mirror.cyberbits.eu/archlinux/\$repo/os/\$arch
Server = https://archlinux.mailtunnel.eu/\$repo/os/\$arch
Server = https://f.matthieul.dev/mirror/archlinux/\$repo/os/\$arch
Server = https://fr.mirrors.cicku.me/archlinux/\$repo/os/\$arch
Server = https://mirror.trap.moe/archlinux/\$repo/os/\$arch"
)

# 官方 fallback 镜像 (任何国家都保留, 作为最后保障)
PRESET_MIRRORS_GLOBAL_FALLBACK="## Fallback - Official mirrors
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"

# ============================================================================
# 生成指定国家的完整 mirrorlist 内容 (stdout)
# 用法: preset_mirrorlist <国家>
#   国家 不存在时使用官方 fallback, 并输出警告。
# ============================================================================

preset_mirrorlist() {
    local country="${1:-China}"
    local list="${PRESET_MIRRORS[$country]:-}"

    if [ -n "$list" ]; then
        printf '%s\n' "$list"
    else
        warn "No preset mirrors for '${country}', using official fallback"
        printf '%s\n' "$PRESET_MIRRORS_GLOBAL_FALLBACK"
        return 1
    fi

    printf '\n%s\n' "$PRESET_MIRRORS_GLOBAL_FALLBACK"
    return 0
}

# 列出所有可用国家 (用于提示)
preset_mirror_countries() {
    echo "${!PRESET_MIRRORS[@]}" | tr ' ' '\n' | sort
}
