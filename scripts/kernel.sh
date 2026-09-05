#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# kernel.sh — Pop!_OS 内核降级脚本（Ubuntu noble 6.8 GA 内核）
#
# 背景：kernel ≥ 6.11 与 NVIDIA Open 内核模块存在交互回归——
#   睡眠唤醒失败（假死后只能硬关机）、重启/关机在末段挂死
#   （journal 停在 "Sending SIGTERM"，对应 NVIDIA open-gpu-kernel-modules
#   #1117/#1027，NVIDIA 内部跟踪号 6120895）。6.10 及以下不受影响。
#   6.8.0-xxx 是 Ubuntu 24.04 官方持续维护（含安全更新）的最后一个
#   < 6.11 内核系列。
#
# 流程：探测仓库最新 6.8 → 预先给 System76 DKMS 模块加内核版本门槛
#   （其源码使用 6.11+ API，直接装会在 6.8 上编译失败导致 apt 半配置
#   状态；这些模块在非 System76 机器上本就无用）→ 安装 6.8 → 校验
#   NVIDIA DKMS → 清理多余 7.x 内核腾出 kernelstub 的 oldkern 槽位 →
#   将 6.8 设为 systemd-boot 默认引导。
#
# 仅适用于 Pop!_OS（systemd-boot + kernelstub）；Debian/GRUB 不适用。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/utils.sh"

check_sudo
export DEBIAN_FRONTEND=noninteractive

# ── 环境检查 ─────────────────────────────────────────────────────────
grep -q '^ID=pop' /etc/os-release 2>/dev/null \
    || log_error "本脚本仅适用于 Pop!_OS（当前系统不符），Debian/GRUB 请勿使用" fatal
# ESP 为 root-only（dmask=0077），须用 sudo test 探测
sudo test -d /boot/efi/loader \
    || log_error "未检测到 systemd-boot ESP（/boot/efi/loader），环境不符" fatal

# ── 探测 Ubuntu noble 仓库中最新的 6.8.x 内核 ────────────────────────
# 注意：Pop /release 仓库（优先级 1001）把 linux-image-generic 劫持为
# 7.x，不能直接取 apt 候选版本，须从 madison 输出中筛选 Ubuntu 源的 6.8
log_section "探测 Ubuntu noble 仓库最新 6.8 内核"

sudo apt-get update -qq
CAND=$(apt-cache madison linux-image-generic \
    | awk -F'|' '{gsub(/ /, "", $2); print $2}' | grep -E '^6\.8\.0-' | sort -V | tail -1)
[[ -n "$CAND" ]] || log_error "Ubuntu 源中未找到 6.8.x 内核（linux-image-generic）" fatal

# 从该版本 meta 的 Depends 中解析具体内核包名（首个依赖带尾逗号，需去掉）
META_DEP=$(apt-cache show "linux-image-generic=${CAND}" | awk '/^Depends:/{sub(/,$/, "", $2); print $2; exit}')
TARGET_REL=${META_DEP#linux-image-}
[[ "$TARGET_REL" =~ ^6\.8\.0-[0-9]+-generic$ ]] \
    || log_error "探测到非预期的内核版本：${TARGET_REL:-空}（应为 6.8.0-xxx-generic）" fatal
log_info "目标内核：${TARGET_REL}（来自 linux-image-generic ${CAND}）"

# ── 预防性修补：System76 DKMS 模块跳过 <6.11 内核 ────────────────────
# 其源码使用 6.11+ 内核 API（platform_driver .remove 改 void、
# LED_REJECT_NAME_CONFLICT 等），在 6.8 上必然编译失败并让 apt 陷入
# 半配置状态。BUILD_EXCLUSIVE_KERNEL 使 DKMS 对不匹配内核直接跳过。
log_section "修补 System76 DKMS 模块内核版本门槛"

for f in /usr/src/system76-*/dkms.conf /usr/src/system76_acpi-*/dkms.conf; do
    [[ -f "$f" ]] || continue
    if sudo grep -q '^BUILD_EXCLUSIVE_KERNEL' "$f"; then
        log_info "$(basename "$(dirname "$f")") 已有版本门槛，跳过"
    else
        echo 'BUILD_EXCLUSIVE_KERNEL="^(6\.(1[1-9]|[2-9][0-9])|7\.|[89]\.)"' | sudo tee -a "$f" > /dev/null
        log_success "已为 $(basename "$(dirname "$f")") 添加 BUILD_EXCLUSIVE_KERNEL（仅 ≥6.11 编译）"
    fi
done

# ── 安装内核（幂等）──────────────────────────────────────────────────
log_section "安装内核 ${TARGET_REL}"

if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "linux-image-${TARGET_REL}" 2>/dev/null || true) == ii* ]]; then
    log_info "内核 ${TARGET_REL} 已安装，跳过"
else
    sudo apt-get -y install \
        "linux-image-${TARGET_REL}" \
        "linux-headers-${TARGET_REL}" \
        "linux-modules-${TARGET_REL}" \
        "linux-modules-extra-${TARGET_REL}"
    log_success "内核 ${TARGET_REL} 安装完成"
fi

# ── 校验 NVIDIA DKMS 模块 ────────────────────────────────────────────
log_section "校验 NVIDIA DKMS 模块"

# 先捕获输出再 grep：pipefail 下 grep -q 提前退出会令上游收到
# SIGPIPE（退出码 141），导致条件被误判为假
DKMS_OUT=$(dkms status 2>/dev/null || true)
if grep -qE "^nvidia/[^,]+, ${TARGET_REL}, .*: installed" <<<"$DKMS_OUT"; then
    log_success "NVIDIA DKMS 模块已为 ${TARGET_REL} 编译安装"
else
    log_error "NVIDIA DKMS 模块未在 ${TARGET_REL} 上编译成功" fatal
fi

# ── 清理多余 Pop 内核（760-xxx 编号），为 6.8 腾出启动槽位 ────────────
# kernelstub 只为"最新 + 次新"两个内核创建启动项；若保留两个以上
# 7.x 内核，6.8 将排不进 ESP。全部 7.x 均 ≥6.11（睡眠已损坏），
# 仅保留最新一个用于 A/B 对比。
log_section "清理多余 Pop 内核"

mapfile -t POP_KERNELS < <(dpkg -l | awk \
    '$1=="ii" && $2 ~ /^linux-image-[0-9.]+-760[0-9]+-generic$/ {print $2}' \
    | sed -E 's/^linux-image-//; s/-generic$//' | sort -V)

if [[ ${#POP_KERNELS[@]} -le 1 ]]; then
    log_info "最多只剩 1 个 Pop 内核（${POP_KERNELS[*]:-无}），无需清理"
else
    KEEP="${POP_KERNELS[-1]}"
    log_info "保留最新 Pop 内核：${KEEP}"
    for ver in "${POP_KERNELS[@]}"; do
        [[ "$ver" == "$KEEP" ]] && continue
        esc=${ver//./\\.}
        mapfile -t PKGS < <(dpkg -l | awk -v re="(^|-)${esc}(-generic)?$" \
            '$1=="ii" && $2 ~ /^linux-(image|headers|modules)/ && $2 ~ re {print $2}')
        if [[ ${#PKGS[@]} -gt 0 ]]; then
            [[ "$ver" == "$(uname -r | sed 's/-generic$//')" ]] \
                && log_info "注意：正在卸载当前运行中的内核 ${ver}，卸载后请勿再切换回该内核"
            log_info "卸载内核 ${ver}（${#PKGS[@]} 个包）"
            sudo apt-get -y purge "${PKGS[@]}"
        fi
    done
fi

# ── 收尾 dpkg 状态 + 刷新 ESP 启动项 ─────────────────────────────────
log_section "刷新启动项"

sudo dpkg --configure -a || true
sudo kernelstub

REMAIN_7X=$(dpkg -l | awk \
    '$1=="ii" && $2 ~ /^linux-image-[0-9.]+-760[0-9]+-generic$/' | wc -l)
if (( REMAIN_7X > 0 )); then
    # kernelstub：最新内核 → Pop_OS-current，次新（6.8）→ Pop_OS-oldkern
    DEFAULT_ENTRY="Pop_OS-oldkern.conf"
else
    DEFAULT_ENTRY="Pop_OS-current.conf"
fi
log_info "设置默认引导项：${DEFAULT_ENTRY}"

sudo bootctl set-default "$DEFAULT_ENTRY" || true
BOOTCTL_LIST=$(sudo bootctl list --no-pager 2>/dev/null || true)
if ! grep -qF "${DEFAULT_ENTRY}) (default)" <<<"$BOOTCTL_LIST"; then
    # bootctl set-default 偶发静默失败，直接改 loader.conf 兜底
    log_info "bootctl 设置未生效，直接修改 loader.conf"
    if sudo grep -q '^default' /boot/efi/loader/loader.conf; then
        sudo sed -i "s/^default .*/default ${DEFAULT_ENTRY%.conf}/" /boot/efi/loader/loader.conf
    else
        echo "default ${DEFAULT_ENTRY%.conf}" | sudo tee -a /boot/efi/loader/loader.conf > /dev/null
    fi
    sudo grep -q '^timeout' /boot/efi/loader/loader.conf \
        || echo "timeout 3" | sudo tee -a /boot/efi/loader/loader.conf > /dev/null
fi
sudo bootctl set-timeout 3
sudo cat /boot/efi/loader/loader.conf
sudo bootctl list --no-pager 2>/dev/null | grep -E 'default\)|selected\)' || true

# ── 锁定 meta 包，防止 apt 拉回 7.x ──────────────────────────────────
log_section "锁定内核 meta 包"

# Pop /release 仓库（优先级 1001）把三个 meta 全部劫持为 7.x，若不
# hold，apt upgrade 会顺着 meta 依赖把 7.x 内核链条重新装回来
for meta in linux-generic linux-image-generic linux-headers-generic; do
    sudo apt-mark hold "$meta" > /dev/null
done
log_success "已锁定：$(apt-mark showhold | tr '\n' ' ')"

# ── 完成报告 ─────────────────────────────────────────────────────────
log_section "完成"
log_success "内核 ${TARGET_REL} 已就绪并设为默认引导"
log_info "重启后请确认：uname -r 输出 ${TARGET_REL}"
log_info "随后测试睡眠唤醒与重启；确认稳定后可清理 7.x 内核（先降级被"
log_info "Pop 劫持的 meta 到 6.8，解除依赖后再卸载 7.x）："
cat <<'HINT'
  sudo apt-mark unhold linux-generic linux-image-generic linux-headers-generic
  sudo apt install linux-image-generic=6.8.0-139.139 linux-headers-generic=6.8.0-139.139 linux-generic=6.8.0-139.139
  sudo apt purge $(dpkg -l | awk '/^ii/ && $2 ~ /760[0-9]+/ && $2 ~ /^linux-(image|headers|modules)/ {print $2}')
  sudo kernelstub
HINT
