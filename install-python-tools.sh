#!/bin/bash
#
# Python 工具链安装脚本（pipx + modelscope + uv，针对当前 sudo 登录用户）
# 用法：sudo bash install-python-tools.sh
#       （也可通过 sudo bash init.sh python 执行）
#
# 结束行为：任一工具安装失败 => 退出码 1（模板流水线可感知）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi

# ---------- 日志 ----------
LOG_FILE="/var/log/install-python-tools-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; return 0; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; return 0; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; return 0; }
log_step()  { echo -e "\n${BLUE}===== $* =====${NC}"; }

if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 或 sudo 执行：sudo bash $0"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

FAILS=0

log_info "日志文件：$LOG_FILE"

# ================== 确定目标用户 ==================
log_step "确定目标用户"

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]] || [[ "$TARGET_USER" == "root" ]]; then
    log_error "未能检测到非 root 登录用户（SUDO_USER）。"
    log_warn  "请通过 sudo 执行本脚本。"
    exit 1
fi
log_info "目标用户：$TARGET_USER"

# ================== 安装 pipx ==================
log_step "安装 pipx"

if ! command -v pipx >/dev/null 2>&1; then
    apt install -y pipx
    log_info "pipx 安装完成"
else
    log_info "pipx 已安装，跳过"
fi

pipx_install() { # pipx_install <包名> [说明]
    local pkg="$1" desc="${2:-$1}"
    # 精确匹配应用名（避免 uv 之类短名撞上其它字符串）
    if sudo -u "$TARGET_USER" -H pipx list 2>/dev/null | grep -qE "(^|[[:space:]])${pkg}([[:space:]]|$)"; then
        log_info "$desc 已安装，跳过"
        return 0
    fi
    if sudo -u "$TARGET_USER" -H pipx install --include-deps "$pkg"; then
        log_info "$desc 安装完成"
    else
        log_error "$desc 安装失败，请检查上面的输出。"
        FAILS=$((FAILS+1))
        return 0
    fi
}

# ================== 安装 modelscope ==================
log_step "安装 modelscope（用户 $TARGET_USER）"
pipx_install modelscope

# ================== 安装 uv ==================
log_step "安装 uv（用户 $TARGET_USER）"
pipx_install uv

# ================== 共享模型缓存（可选） ==================
MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-}"
if [[ -n "$MODELSCOPE_CACHE" ]]; then
    log_step "配置模型缓存目录：$MODELSCOPE_CACHE"
    if [[ ! -d "$MODELSCOPE_CACHE" ]]; then
        USER_GROUP=$(id -gn "$TARGET_USER")
        install -d -m 755 -o "$TARGET_USER" -g "$USER_GROUP" "$MODELSCOPE_CACHE"
        log_info "已创建模型缓存目录并归属 $TARGET_USER"
    fi
    UCACHE_BASHRC="/home/${TARGET_USER}/.bashrc"
    if [[ -f "$UCACHE_BASHRC" ]] && ! grep -q 'export MODELSCOPE_CACHE=' "$UCACHE_BASHRC"; then
        {
            echo ""
            echo "# 由 install-python-tools.sh 追加"
            echo "export MODELSCOPE_CACHE=\"$MODELSCOPE_CACHE\""
        } >> "$UCACHE_BASHRC"
        log_info "已写入 ~/.bashrc：export MODELSCOPE_CACHE（重新登录后生效）"
    fi
    log_info "提示：若 start-vllm.sh 的 MODEL_CACHE 指向同一目录，宿主机下载与容器缓存可共用，避免重复下载"
fi

# ================== 确保 PATH ==================
log_step "配置 PATH"

sudo -u "$TARGET_USER" -H pipx ensurepath || true
log_info "已执行 pipx ensurepath（重新登录后生效）"

# ================== 完成 ==================
log_step "安装完成"
if (( FAILS > 0 )); then
    echo -e "${YELLOW}流程结束，但有 $FAILS 项失败，退出码 1。${NC}"
    log_info "完整日志：$LOG_FILE"
    exit 1
fi
echo -e "${GREEN}Python 工具链安装流程完成。${NC}"
echo ""
echo "验证方式（用户 $TARGET_USER 重新登录后）："
echo "  modelscope --version"
echo "  uv --version"
echo ""
echo "如果当前会话找不到命令，可临时执行："
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
log_info "完整日志：$LOG_FILE"
