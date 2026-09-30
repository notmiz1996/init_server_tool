#!/bin/bash
#
# NVIDIA 驱动 + Docker + nvidia-container-toolkit + GPU 功率上限 安装脚本
# 前提：已通过 init-server.sh 禁用 Nouveau，并重启，且 lsmod | grep nouveau 无输出
#        且 /var/run/reboot-required 不存在（内核更新需先重启）
# 用法：sudo bash install-nvidia.sh [-y]
#
# 逻辑：
#   - 已安装驱动且版本 >= 目标版本：跳过驱动安装
#   - 已安装驱动且版本 <  目标版本：卸载旧驱动，安装目标版本
#   - 未安装驱动：直接安装目标版本
#   - 安装后按 GPU 最大功率的 80%（可配）设置功率上限，并配置开机自启
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi

# ================== 可调整参数（config.env 未定义时的默认值） ==================
NVIDIA_DRIVER="${NVIDIA_DRIVER:-nvidia-driver-610}"
TARGET_VERSION="${TARGET_VERSION:-610.57.04}"   # 期望安装的驱动版本，用于版本比较
POWER_LIMIT_RATIO="${POWER_LIMIT_RATIO:-80}"    # 功率上限百分比，80 表示 80%
GPU_COUNT_EXPECT="${GPU_COUNT_EXPECT:-4}"       # 期望 GPU 数，0=跳过数量校验
# ==============================================================================

# ---------- 日志 ----------
LOG_FILE="/var/log/install-nvidia-$(date +%Y%m%d-%H%M%S).log"
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
for a in "$@"; do
    case "$a" in
        -y|--yes) ;;
        *) log_warn "忽略未知参数：$a" ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive

# ---------- 状态标记 ----------
STATE_DIR="/var/lib/init-server-tool"
state_set() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    local f="${STATE_DIR}/state"
    { grep -v "^$1=" "$f" 2>/dev/null || true; echo "$1=$2"; } > "${f}.tmp" 2>/dev/null \
        && mv -f "${f}.tmp" "$f" 2>/dev/null || true
}

log_info "日志文件：$LOG_FILE"

# ================== 前置检查 ==================
log_step "前置检查"

if lsmod | grep -q '^nouveau'; then
    log_error "检测到 Nouveau 仍在内核中加载！"
    log_error "请先禁用 Nouveau 并重启，确认 'lsmod | grep nouveau' 无输出后，再执行本脚本。"
    exit 1
fi
log_info "Nouveau 未加载，可以继续"

if [[ -f /var/run/reboot-required ]]; then
    log_error "系统标记有待重启的更新（内核可能已升级但尚未重启）。"
    log_error "驱动必须按"当前运行的内核"编译，否则 dkms 产物与重启后的新内核不匹配。"
    log_error "请先执行：sudo reboot ，然后重跑本脚本（或 sudo bash init.sh all -y）。"
    exit 1
fi
log_info "无待重启更新"

AVAIL_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
if [[ "$AVAIL_GB" -lt 10 ]]; then
    log_error "根分区可用空间仅 ${AVAIL_GB}GB，小于 10GB，请先清理。"
    exit 1
fi
log_info "根分区可用空间：${AVAIL_GB}GB"

if ! lspci 2>/dev/null | grep -qi nvidia; then
    log_warn "lspci 未发现 NVIDIA GPU（虚拟机未透传？），仍将继续安装包。"
fi

# ================== 驱动版本检测 ==================
log_step "驱动版本检测"

CURRENT_VERSION=""
CURRENT_SOURCE=""

if command -v nvidia-smi >/dev/null 2>&1; then
    CURRENT_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
    [[ -n "$CURRENT_VERSION" ]] && CURRENT_SOURCE="nvidia-smi"
fi

if [[ -z "$CURRENT_VERSION" ]]; then
    PKG_VERSION=$(dpkg-query -W -f='${Package} ${Version}\n' 'nvidia-driver-*' 2>/dev/null | head -n1 || true)
    if [[ -n "$PKG_VERSION" ]]; then
        CURRENT_VERSION=$(echo "$PKG_VERSION" | awk '{print $2}' | cut -d'-' -f1)
        CURRENT_SOURCE="dpkg"
    fi
fi

log_info "目标驱动版本：$TARGET_VERSION"
if [[ -z "$CURRENT_VERSION" ]]; then
    log_warn "未检测到已安装的 NVIDIA 驱动"
else
    log_info "当前驱动版本：$CURRENT_VERSION（来源：$CURRENT_SOURCE）"
fi

version_ge() {
    [[ "$1" == "$2" ]] && return 0
    local highest
    highest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)
    [[ "$highest" == "$1" ]]
}

check_gpu_count() {
    local n
    n=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [[ "$GPU_COUNT_EXPECT" -gt 0 ]]; then
        if [[ "$n" -eq "$GPU_COUNT_EXPECT" ]]; then
            log_info "GPU 数量校验通过：$n"
        else
            log_error "GPU 数量异常：nvidia-smi 识别 $n 张，期望 $GPU_COUNT_EXPECT"
            log_error "请执行 nvidia-smi / dmesg | tail 排查（掉卡、PCIe 故障等）。"
            exit 1
        fi
    else
        [[ "$n" -gt 0 ]] || { log_error "nvidia-smi 未发现任何 GPU"; exit 1; }
        log_info "GPU 数量校验通过：$n（未设置期望值）"
    fi
}

# ================== 决定是否安装驱动 ==================
log_step "驱动安装决策"

INSTALL_DRIVER=0

if [[ -z "$CURRENT_VERSION" ]]; then
    log_info "未安装驱动，将安装 $NVIDIA_DRIVER（$TARGET_VERSION）"
    INSTALL_DRIVER=1
elif version_ge "$CURRENT_VERSION" "$TARGET_VERSION"; then
    log_info "当前版本 $CURRENT_VERSION >= 目标版本 $TARGET_VERSION，跳过驱动安装"
    INSTALL_DRIVER=0
else
    log_warn "当前版本 $CURRENT_VERSION < 目标版本 $TARGET_VERSION，将卸载旧驱动并安装新版本"
    INSTALL_DRIVER=1
fi

# ================== 安装 / 卸载 NVIDIA 驱动 ==================
NEED_REBOOT=0

if [[ "$INSTALL_DRIVER" -eq 1 ]]; then
    log_step "安装 NVIDIA 驱动（${NVIDIA_DRIVER}）"

    # 源可用性预检
    if ! apt-cache policy "$NVIDIA_DRIVER" 2>/dev/null | grep -q '^  Version:'; then
        log_error "当前 apt 源中没有 $NVIDIA_DRIVER。"
        log_error "可尝试：1) 回退 NVIDIA_DRIVER=nvidia-driver-580/575；2) 添加 NVIDIA 官方 apt 源"
        log_error "  （https://docs.nvidia.com/datacenter/cloud-native/deb-install-guide.html 所列 download.nvidia.com 源）"
        exit 1
    fi

    log_info "清理旧 NVIDIA 驱动（精确包名，避免误删 nvidia-container-toolkit）..."
    apt purge -y 'nvidia-driver-*' 'nvidia-dkms-*' 'nvidia-headless-*' 'nvidia-tesla-*' 'nvidia-compute-utils*' 'libnvidia-.*' 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true

    apt install -y build-essential dkms linux-headers-$(uname -r)

    if apt install -y "$NVIDIA_DRIVER"; then
        log_info "$NVIDIA_DRIVER 安装成功"

        systemctl enable --now nvidia-persistenced 2>/dev/null || true
        nvidia-smi -pm 1 2>/dev/null || log_warn "开启持久化模式失败，请手动执行 nvidia-smi -pm 1"
        log_info "nvidia-persistenced 已启用，持久化模式已尝试开启"

        # 硬校验：装完必须识别 GPU
        check_gpu_count

        # headless 计算机：保留 nvidia_drm 模块但关闭 modeset（标准做法，可逆）
        DRM_CONF="/etc/modprobe.d/nvidia-headless.conf"
        NEW_CONTENT=$'options nvidia-drm modeset=0'
        if [[ -f "/etc/modprobe.d/disable-nvidia-drm.conf" ]]; then
            rm -f /etc/modprobe.d/disable-nvidia-drm.conf
            log_info "已移除旧式 /etc/modprobe.d/disable-nvidia-drm.conf（install /bin/false 写法）"
        fi
        if [[ ! -f "$DRM_CONF" ]] || [[ "$(cat "$DRM_CONF")" != "$NEW_CONTENT" ]]; then
            echo "$NEW_CONTENT" > "$DRM_CONF"
            update-initramfs -u -k "$(uname -r)"
            log_info "已配置 nvidia-drm modeset=0（headless 计算模式，重启后生效）"
            NEED_REBOOT=1
        fi
    else
        log_error "$NVIDIA_DRIVER 安装失败，请检查 apt 源。"
        exit 1
    fi
else
    log_step "跳过 NVIDIA 驱动安装"

    systemctl enable --now nvidia-persistenced 2>/dev/null || true
    nvidia-smi -pm 1 2>/dev/null || true
    if command -v nvidia-smi >/dev/null 2>&1; then
        check_gpu_count
    else
        log_error "驱动"跳过安装"但 nvidia-smi 不可用，状态异常，请手动排查。"
        exit 1
    fi

    DRM_CONF="/etc/modprobe.d/nvidia-headless.conf"
    NEW_CONTENT=$'options nvidia-drm modeset=0'
    if [[ -f "/etc/modprobe.d/disable-nvidia-drm.conf" ]]; then
        rm -f /etc/modprobe.d/disable-nvidia-drm.conf
        log_info "已移除旧式 /etc/modprobe.d/disable-nvidia-drm.conf（install /bin/false 写法）"
    fi
    if [[ ! -f "$DRM_CONF" ]] || [[ "$(cat "$DRM_CONF")" != "$NEW_CONTENT" ]]; then
        echo "$NEW_CONTENT" > "$DRM_CONF"
        update-initramfs -u -k "$(uname -r)"
        log_info "已配置 nvidia-drm modeset=0（headless 计算模式，重启后生效）"
        NEED_REBOOT=1
    fi
fi

# ================== GPU 功率上限 ==================
log_step "配置 GPU 功率上限（${POWER_LIMIT_RATIO}%）"

POWER_SCRIPT="/usr/local/bin/set-gpu-power-limit.sh"
POWER_CONF="/etc/gpu-power-limit.conf"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_warn "nvidia-smi 未找到，跳过功率上限配置。"
else
    # 运行期参数（改百分比只改 conf 即可，不必重新生成脚本）
    echo "POWER_LIMIT_RATIO=${POWER_LIMIT_RATIO}" > "$POWER_CONF"

    cat > "$POWER_SCRIPT" <<'EOF'
#!/bin/bash
# 自动生成：按 GPU 最大功率的 POWER_LIMIT_RATIO% 设置功率上限
CONF=/etc/gpu-power-limit.conf
RATIO=80
[[ -f "$CONF" ]] && . "$CONF"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi 不可用"; exit 1
fi

# 正确的计数方式（--query-gpu 没有 count 字段）
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
if [[ -z "$GPU_COUNT" || "$GPU_COUNT" -eq 0 ]]; then
    echo "未发现 GPU"; exit 1
fi

rc=0
for ((i=0; i<GPU_COUNT; i++)); do
    MAX_W_RAW=$(nvidia-smi -i "$i" --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null)
    if [[ -z "$MAX_W_RAW" || "$MAX_W_RAW" == *"N/A"* ]]; then
        echo "GPU$i: 无最大功率信息，跳过"; continue
    fi
    # 把 "150.00" 转成整数 150，避免 bash 算术报错
    MAX_W=$(echo "$MAX_W_RAW" | awk '{printf "%d", $1}')
    LIMIT_W=$(( MAX_W * RATIO / 100 ))
    if nvidia-smi -i "$i" -pl "$LIMIT_W" >/dev/null 2>&1; then
        NOW=$(nvidia-smi -i "$i" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null)
        echo "GPU$i: ${MAX_W}W -> ${LIMIT_W}W (实际: ${NOW:-?}W)"
        [[ "${NOW}" == "$LIMIT_W" ]] || { echo "GPU$i: 回读值 ${NOW:-?} 与目标 ${LIMIT_W} 不一致"; rc=1; }
    else
        echo "GPU$i: -pl ${LIMIT_W} 设置失败（若 GPU 模型不支持降额，可设 POWER_LIMIT_RATIO=100）"
        rc=1
    fi
done
exit $rc
EOF
    chmod +x "$POWER_SCRIPT"

    # 立即执行一次（失败不再静默）
    log_info "正在应用功率上限（${POWER_LIMIT_RATIO}%）..."
    if "$POWER_SCRIPT"; then
        log_info "功率上限应用成功："
        nvidia-smi --query-gpu=index,name,power.limit,power.max_limit --format=csv 2>/dev/null | sed 's/^/  /' || true
    else
        log_warn "功率上限应用失败（上方有逐卡原因）。不影响驱动与 Docker 使用。"
        log_warn "若个别 GPU 型号不支持 -pl，可把 config.env 的 POWER_LIMIT_RATIO 设为 100。"
    fi

    # systemd 服务，开机自启
    cat > /etc/systemd/system/gpu-power-limit.service <<'EOF'
[Unit]
Description=Set NVIDIA GPU power limit to configured ratio
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-gpu-power-limit.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gpu-power-limit.service 2>/dev/null || true
    log_info "已创建 gpu-power-limit.service，开机自动应用功率上限"
fi

# ================== 安装 Docker ==================
log_step "安装 Docker"

if ! command -v docker >/dev/null 2>&1; then
    # 采用 Ubuntu 官方源 docker.io（稳定、可离线审计）；
    # 如需最新 Docker Engine 版本，可改用 https://get.docker.com 安装的 Docker CE
    apt install -y docker.io
    systemctl enable --now docker
    log_info "Docker (docker.io, Ubuntu 官方源) 安装并启用完成"
else
    log_info "Docker 已安装，跳过"
fi

if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    usermod -aG docker "$SUDO_USER"
    log_warn "已将用户 $SUDO_USER 加入 docker 组（重新登录后生效）。"
    log_warn "注意：docker 组等同 root 权限，请勿授予不可信用户。"
fi

# ================== 安装 nvidia-container-toolkit ==================
log_step "安装 nvidia-container-toolkit"

log_info "添加 NVIDIA Container Toolkit GPG 密钥和软件源..."
apt-get install -y gnupg ca-certificates

if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
    log_error "下载/导入 NVIDIA Container Toolkit GPG key 失败（网络不通或需要代理）"
    exit 1
fi

if ! curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
    log_error "下载 nvidia-container-toolkit.list 失败（网络不通或需要代理）"
    exit 1
fi

log_info "更新包列表并安装 nvidia-container-toolkit..."
apt-get update -y
apt-get install -y nvidia-container-toolkit

if command -v nvidia-ctk >/dev/null 2>&1; then
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    log_info "nvidia-container-toolkit 已安装并配置 Docker 运行时"
else
    log_error "nvidia-ctk 未找到，请检查 nvidia-container-toolkit 安装结果。"
    exit 1
fi

# ================== 完成 ==================
if [[ "${NEED_REBOOT:-0}" -eq 1 ]]; then
    state_set nvidia pending-reboot
else
    state_set nvidia done
fi

log_step "安装完成"
echo -e "${GREEN}所有步骤已完成！${NC}"
echo ""
echo "已完成项："
if [[ "$INSTALL_DRIVER" -eq 1 ]]; then
    echo "  ✓ 已安装/更新为 ${NVIDIA_DRIVER}（目标 ${TARGET_VERSION}）"
else
    echo "  ✓ 已安装版本 ${CURRENT_VERSION} >= 目标 ${TARGET_VERSION}，跳过驱动安装"
fi
echo "  ✓ GPU 功率上限设为最大功率的 ${POWER_LIMIT_RATIO}%（开机自启：gpu-power-limit.service）"
echo "  ✓ Docker（Ubuntu 源 docker.io）"
echo "  ✓ nvidia-container-toolkit"
echo ""
if [[ "${NEED_REBOOT:-0}" -eq 1 ]]; then
    log_warn "请重启服务器使新驱动/模块参数生效：sudo reboot"
    log_warn "重启后重跑本脚本（或 sudo bash init.sh all -y）将以"版本已达标"路径快速收尾。"
    echo ""
fi
echo "验证："
echo "  nvidia-smi"
echo "  nvidia-smi --query-gpu=index,name,power.limit,power.max_limit --format=csv"
echo "  systemctl status gpu-power-limit.service"
echo "  nvidia-ctk --version"
echo "  docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi"
echo ""
echo "  统一验证：sudo bash init.sh verify"
log_info "完整日志：$LOG_FILE"
