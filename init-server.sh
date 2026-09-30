#!/bin/bash
#
# Ubuntu 24.04 服务器初始化脚本（基础环境部分）
# 功能：临时停用自动更新 / 换源 / 更新系统 / OpenSSH / 常用工具 / Fail2ban
#       SSH 安全加固 + UFW / 中文环境(保留系统默认 C.UTF-8) / 静态IP
#       时区 / Swap / 禁用 Nouveau（两阶段）
# 用法：sudo bash init-server.sh [-y]
#      -y / --yes：跳过交互确认（无人值守）
#      第一次执行：禁用 Nouveau 后提示重启（自动恢复自动更新计时器）
#      重启后再次执行：跳过禁用步骤，完成收尾
#
# 参数优先取自同目录 config.env，改参数请编辑 config.env
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi

# ================== 可调整参数（config.env 未定义时的默认值） ==================
STATIC_IP="${STATIC_IP:-192.168.11.251}"
PREFIX_LEN="${PREFIX_LEN:-24}"
GATEWAY="${GATEWAY:-192.168.11.1}"
DNS1="${DNS1:-223.5.5.5}"
DNS2="${DNS2:-114.114.114.114}"
MIRROR="${MIRROR:-tuna}"
UFW_ENABLE="${UFW_ENABLE:-1}"
# ==============================================================================

# ---------- 日志 ----------
LOG_FILE="/var/log/init-server-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; return 0; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; return 0; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; return 0; }
log_step()  { echo -e "\n${BLUE}===== $* =====${NC}"; }

# ---------- 权限检查 ----------
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 或 sudo 执行：sudo bash $0"
    exit 1
fi

# ---------- -y 参数 ----------
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        *) log_warn "忽略未知参数：$a" ;;
    esac
done
confirm() { # confirm "提示" || exit
    (( ASSUME_YES )) && return 0
    read -rp "$* (y/N) " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

export DEBIAN_FRONTEND=noninteractive

# ---------- 状态标记 ----------
STATE_DIR="/var/lib/init-server-tool"
state_set() { # state_set <stage> <value>
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local f="${STATE_DIR}/state"
    { grep -v "^$1=" "$f" 2>/dev/null || true; echo "$1=$2"; } > "${f}.tmp" 2>/dev/null \
        && mv -f "${f}.tmp" "$f" 2>/dev/null || true
}

log_info "日志文件：$LOG_FILE"

# ---------- 自动更新：脚本运行期间临时停用，退出时恢复 ----------
restore_auto_update() {
    systemctl restart apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl enable --now unattended-upgrades 2>/dev/null || true
    log_info "已恢复自动更新（security 补丁将自动安装）"
}
AUTO_UPDATE_MANAGED=0

log_step "前置检查"

AVAIL_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [[ "$AVAIL_GB" -lt 20 ]]; then
    log_error "根分区可用空间仅 ${AVAIL_GB}GB，小于 20GB，请先清理。"
    exit 1
fi
log_info "根分区可用空间：${AVAIL_GB}GB"

if ! grep -qi "24.04" /etc/os-release; then
    log_warn "当前系统不是 Ubuntu 24.04，部分路径可能不适用。"
    confirm "是否继续？" || exit 1
fi

echo ""
log_warn "即将执行服务器基础环境初始化，包括："
echo "    - apt 源（${MIRROR}）+ 系统 full-upgrade"
echo "    - OpenSSH / 常用工具 / Fail2ban / SSH 加固${UFW_ENABLE:+/ UFW 防火墙}"
echo "    - 中文环境（系统默认 locale 保持 C.UTF-8，生成 zh_CN.UTF-8 供个人使用）"
echo "    - 静态 IP ${STATIC_IP}/${PREFIX_LEN}，网关 ${GATEWAY}"
echo "    - 时区 UTC + NTP、Swap"
echo "    - 禁用 Nouveau（第一次执行后会提示重启）"
echo "  说明：自动更新仅在本脚本运行期间临时停用，退出时自动恢复。"
echo ""
confirm "确认继续？" || { log_info "已取消。"; exit 0; }

# ================== 0. 临时停用自动更新并等待 dpkg 锁 ==================
log_step "0. 临时停用自动更新、等待 dpkg 锁"

systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.service 2>/dev/null || true
systemctl stop apt-daily-upgrade.service 2>/dev/null || true
systemctl stop apt-daily.timer 2>/dev/null || true
systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
AUTO_UPDATE_MANAGED=1
trap '[[ "$AUTO_UPDATE_MANAGED" = "1" ]] && restore_auto_update || true' EXIT

log_info "等待 dpkg 锁释放..."
for i in $(seq 1 60); do
    if flock -n /var/lib/dpkg/lock-frontend true 2>/dev/null; then
        log_info "dpkg 锁已释放"
        break
    fi
    if [[ "$i" -eq 60 ]]; then
        log_error "等待 60 秒后锁仍未释放，请手动检查：sudo fuser -v /var/lib/dpkg/lock-frontend"
        exit 1
    fi
    sleep 1
done

# ================== 1. 更换 apt 源（先换源，后续操作走镜像） ==================
log_step "1. apt 源配置（${MIRROR}）"

SOURCES_FILE="/etc/apt/sources.list.d/ubuntu.sources"

if [[ "$MIRROR" == "tuna" ]]; then
    if [[ ! -f "${SOURCES_FILE}.bak" ]]; then
        cp "$SOURCES_FILE" "${SOURCES_FILE}.bak"
        log_info "已备份原源文件到 ${SOURCES_FILE}.bak"
    fi

    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" == "amd64" || "$ARCH" == "i386" ]]; then
        TUNA_PATH="ubuntu"
    else
        TUNA_PATH="ubuntu-ports"
    fi

    cat > "$SOURCES_FILE" <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/${TUNA_PATH}
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/${TUNA_PATH}
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    log_info "清华源已配置"
elif [[ "$MIRROR" == "official" ]]; then
    log_info "MIRROR=official，保持默认官方源"
else
    log_error "MIRROR 配置无效：${MIRROR}（可选 tuna|official）"
    exit 1
fi

if ! apt update -y; then
    log_error "apt update 失败。清华源不可用且回滚方法：cp ${SOURCES_FILE}.bak ${SOURCES_FILE} && apt update"
    exit 1
fi
log_info "apt update 通过"

# ================== 2. 更新系统 ==================
log_step "2. 系统 full-upgrade"
apt full-upgrade -y
apt autoremove -y
apt clean
if [[ -f /var/run/reboot-required ]]; then
    log_warn "系统升级后标记需要重启（可能升级了内核）。"
    log_warn "可现在完成本脚本剩余步骤后重启；也可现在 reboot，重启后重跑本脚本与其他阶段。"
fi

# ================== 3. OpenSSH ==================
log_step "3. 安装 OpenSSH 并配置自启"
apt install -y openssh-server
systemctl enable --now ssh
log_info "OpenSSH 安装并启用完成"

# ================== 4. 常用工具 ==================
log_step "4. 安装常用工具"
apt install -y curl wget git unzip htop alsa-utils nvtop python3-pip python3-venv iputils-arping fail2ban psmisc
log_info "常用工具安装完成"

# Fail2ban：手写最小 jail.local（只覆盖必要项，其余继承 jail.conf 并随包更新）
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
mode    = aggressive
EOF
systemctl enable --now fail2ban
log_info "Fail2ban 已启用（最小 jail.local：sshd 失败 5 次封禁 1 小时）"

# ================== 4.5 中文环境 ==================
log_step "4.5 配置中文环境"

apt install -y locales fonts-noto-cjk
locale-gen zh_CN.UTF-8
log_info "已生成 zh_CN.UTF-8 locale 并安装中文字体。"
log_info "系统默认 locale 保持 C.UTF-8（生产脚本解析英文输出更稳）；"
log_info "个人终端中文：在 ~/.bashrc 加 export LANG=zh_CN.UTF-8 后重新登录生效。"

# ================== 4.6 安全加固：SSH / sysctl / UFW ==================
log_step "4.6 安全加固"

# --- SSH ---
SSHD_HARDEN_DIR="/etc/ssh/sshd_config.d"
SSHD_HARDEN="${SSHD_HARDEN_DIR}/99-init.conf"
mkdir -p "$SSHD_HARDEN_DIR"
{
    echo "# 由 init-server.sh 生成"
    echo "PermitRootLogin no"
} > "$SSHD_HARDEN"
if ls /home/*/.ssh/authorized_keys >/dev/null 2>&1; then
    echo "PasswordAuthentication no" >> "$SSHD_HARDEN"
    log_info "sshd 加固：禁 root 登录 + 禁密码登录（检测到非 root authorized_keys）"
else
    log_warn "未发现非 root 的 ~/.ssh/authorized_keys，未禁用密码登录（避免锁死）。"
    log_warn "配好密钥后，在 $SSHD_HARDEN 追加：PasswordAuthentication no"
fi
systemctl reload ssh

# --- sysctl ---
cat > /etc/sysctl.d/99-init.conf <<'EOF'
# 由 init-server.sh 生成
vm.swappiness = 10
EOF
sysctl --system >/dev/null 2>&1 || true
log_info "sysctl：vm.swappiness=10"

# --- 日志轮转（本工具各阶段产生的日志） ---
cat > /etc/logrotate.d/init-server-tool <<'EOF'
/var/log/init-*.log /var/log/install-*.log /var/log/verify-*.log {
    weekly
    rotate 4
    maxsize 50M
    missingok
    notifempty
    compress
    copytruncate
}
EOF
log_info "已配置日志轮转 /etc/logrotate.d/init-server-tool（每周或超 50M 轮转，保留 4 份）"

# --- UFW ---
# 注意（重要）：Docker 会绕过 UFW 的 FORWARD 链直接发布端口，
# 因此不要把"靠 UFW 限制容器端口"当作安全边界——容器端口必须在 docker run
# 时显式绑定到具体 IP（本模板 start-vllm.sh 已用 -p ${VLLM_BIND_IP}:... 做到）。
# 本处 UFW 规则用于收紧宿主机自身服务（如 easytier 监听端口）。
if [[ "$UFW_ENABLE" == "1" ]]; then
    if ! command -v ufw >/dev/null 2>&1; then
        apt install -y ufw
    fi
    if [[ "$PREFIX_LEN" == "24" ]]; then
        LAN_CIDR="${GATEWAY%.*}.0/24"
        # 先放行再 enable，防止锁死
        ufw allow 22/tcp
        ufw allow from "$LAN_CIDR" to any port 8000 proto tcp
        ufw allow from "$LAN_CIDR" to any port 11010,11011 proto udp
        ufw allow from "$LAN_CIDR" to any port 11010 proto tcp
        log_info "UFW 规则：22/tcp 全放行；${LAN_CIDR} → 8000/tcp, 11010/tcp, 11010-11011/udp"
    else
        ufw allow 22/tcp
        log_warn "网关前缀不是 /24，无法推导局域网段，仅放行 22/tcp。其余端口请手动：ufw allow ..."
    fi
    ufw --force enable
    ufw status | sed 's/^/  /' || true
else
    log_info "UFW_ENABLE=0，跳过防火墙"
fi

# ================== 5. 配置静态 IP ==================
log_step "5. 配置静态 IP：${STATIC_IP}/${PREFIX_LEN}"

NIC=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1 || true)
if [[ -z "${NIC:-}" ]]; then
    log_warn "未能自动检测网卡，请手动输入网卡名："
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
    read -rp "请输入网卡名称：" NIC
fi
log_info "使用网卡：$NIC"

# 幂等：本机已配置该 IP 则跳过占用检测（否则自己的内核会对 ARP 应答导致误报）
if ip -4 -o addr show "$NIC" | awk '{print $4}' | grep -qw "${STATIC_IP}/${PREFIX_LEN}"; then
    log_info "网卡 $NIC 已配置 ${STATIC_IP}/${PREFIX_LEN}，跳过占用检测"
elif arping -c 3 -I "$NIC" "$STATIC_IP" >/dev/null 2>&1; then
    log_error "$STATIC_IP 已被其他设备占用，脚本中止！"
    exit 1
fi
log_info "IP $STATIC_IP 未被占用"

mkdir -p /etc/netplan/backup
cp /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true

# 回滚：删除新配置 + 把被改名的原文件 mv 回去 + 用备份兜底 + apply
rollback_netplan() {
    log_error "回滚网络配置..."
    rm -f /etc/netplan/01-static-ip.yaml
    while IFS= read -r f; do
        if [[ -n "$f" ]]; then
            mv -f "$f" "${f%.disabled}"
        fi
    done < <(ls /etc/netplan/*.disabled 2>/dev/null || true)
    cp -f /etc/netplan/backup/*.yaml /etc/netplan/ 2>/dev/null || true
    netplan apply 2>/dev/null || true
    sleep 3
    log_error "已回滚至原网络配置。"
    exit 1
}

cat > /etc/netplan/01-static-ip.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}:
      dhcp4: no
      addresses:
        - ${STATIC_IP}/${PREFIX_LEN}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS1}
          - ${DNS2}
EOF
chmod 600 /etc/netplan/01-static-ip.yaml

for f in /etc/netplan/50-cloud-init.yaml /etc/netplan/90-NM-*.yaml; do
    if [[ -f "$f" ]] && grep -q "dhcp4: true" "$f" 2>/dev/null; then
        mv "$f" "${f}.disabled"
        log_warn "已禁用 $f（改名为 ${f}.disabled，回滚时会自动恢复）"
    fi
done

if ! netplan generate; then
    log_error "netplan generate 失败，回滚..."
    rollback_netplan
fi

if ! netplan apply; then
    log_error "netplan apply 失败，回滚..."
    rollback_netplan
fi

sleep 5

if ! ping -c 2 -W 3 "$GATEWAY" >/dev/null 2>&1; then
    log_error "无法 ping 通网关 $GATEWAY，回滚配置..."
    rollback_netplan
fi

log_info "静态 IP 已应用，网关可达"
ip -4 addr show "$NIC" | grep inet || true
log_warn "如果通过 SSH 连接，现在可能已断开，请用新 IP ${STATIC_IP} 重新连接！"

# ================== 5.5 时区与 NTP ==================
log_step "5.5 配置时区与时间同步"
timedatectl set-timezone UTC
timedatectl set-ntp true
timedatectl status | grep -E "Time zone|synchronized" || true
log_info "时区已设为 UTC，NTP 已启用"

# ================== 5.6 Swap ==================
log_step "5.6 检查并配置 Swap"
MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [[ "$MEM_GB" -lt 32 ]] && [[ ! -f /swapfile ]]; then
    # 内存 ×2，上限 16G，下限 2G
    SWAP_GB=$(( MEM_GB * 2 ))
    [[ "$SWAP_GB" -gt 16 ]] && SWAP_GB=16
    [[ "$SWAP_GB" -lt 2 ]] && SWAP_GB=2
    log_info "内存 ${MEM_GB}GB < 32GB，正在创建 ${SWAP_GB}G swapfile..."
    if ! fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null; then
        log_warn "fallocate 失败（文件系统不支持？），改用 dd 写入（较慢）..."
        dd if=/dev/zero of=/swapfile bs=1M count=$(( SWAP_GB * 1024 )) status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    log_info "Swap 配置完成（${SWAP_GB}G，vm.swappiness=10）"
else
    log_info "内存 ${MEM_GB}GB，无需额外 swap，或 swapfile 已存在"
fi

# ================== 6. 禁用 Nouveau（两阶段） ==================
log_step "6. 禁用 Nouveau（两阶段）"

NOUVEAU_BLACKLIST="/etc/modprobe.d/blacklist-nouveau.conf"
NOUVEAU_LOADED=$(lsmod | grep -c '^nouveau' || true)

if [[ "$NOUVEAU_LOADED" -gt 0 ]]; then
    log_warn "检测到 Nouveau 仍在内核中加载，进入【阶段一】：禁用 Nouveau 并提示重启。"

    cat > "$NOUVEAU_BLACKLIST" <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u
    state_set base pending-reboot
    log_info "已写入黑名单并更新 initramfs。"

    echo ""
    log_warn "=========================================================="
    log_warn "  阶段一完成：Nouveau 已被禁用，但需要重启才能生效。"
    log_warn "  请执行：sudo reboot"
    log_warn "  重启后，再次运行本脚本（或 sudo bash init.sh all -y），"
    log_warn "  将跳过禁用步骤，完成收尾。"
    log_warn "  然后执行 sudo bash install-nvidia.sh 安装驱动和 toolkit。"
    log_warn "=========================================================="
    echo ""
    exit 0
else
    log_info "Nouveau 未加载，跳过禁用步骤。"
    cat > "$NOUVEAU_BLACKLIST" <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
fi

# ================== 完成 ==================
state_set base done
log_step "基础环境初始化完成"
echo -e "${GREEN}所有步骤已完成！${NC}"
echo ""
echo "已完成项汇总："
echo "  ✓ 临时停用自动更新（退出时已恢复）+ 释放 dpkg 锁"
echo "  ✓ apt 源（${MIRROR}）+ 系统 full-upgrade"
echo "  ✓ OpenSSH / 常用工具 / Fail2ban / SSH 加固${UFW_ENABLE:+/ UFW}"
echo "  ✓ 中文环境（系统默认 C.UTF-8）"
echo "  ✓ 静态 IP ${STATIC_IP}"
echo "  ✓ 时区 UTC + NTP"
echo "  ✓ Swap + vm.swappiness=10"
echo "  ✓ Nouveau 禁用"
if [[ -f /var/run/reboot-required ]]; then
    echo ""
    log_warn "注意：系统仍标记待重启（内核可能已升级）。"
    log_warn "装 NVIDIA 驱动前必须先重启，否则驱动会按旧内核编译（dkms 不匹配）。"
fi
echo ""
log_warn "下一步："
echo "    1. 如刚禁用 Nouveau，请先 sudo reboot"
echo "    2. 重启后确认 lsmod | grep nouveau 无输出"
echo "    3. 执行 sudo bash install-nvidia.sh（或 sudo bash init.sh nvidia）"
log_info "完整日志：$LOG_FILE"
