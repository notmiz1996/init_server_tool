#!/bin/bash
#
# EasyTier 安装脚本（完全离线版 + 密钥治理）
# 前置：
#   1. 官方 install.sh 已下载到本脚本同目录，命名为 easytier_install.sh
#   2. 自定义配置命名为 easytier_notmiz1996.conf
#      （network_secret 使用占位符 {{EASYTIER_SECRET}}，见下方密钥说明）
#   3. EasyTier 离线 zip 包放在本脚本同目录
# 用法：sudo bash install-easytier.sh
#
# 密钥说明（重要）：
#   - 模板配置里的 network_secret 是占位符 {{EASYTIER_SECRET}}；
#   - 首次安装：自动生成随机密钥写入 ${SECRET_DIR}/easytier_secret（600），
#     然后替换进配置。所有设备（含对端）必须使用同一密钥才能组网；
#   - 加入既有 mesh：运行前把该 mesh 的真实密钥写入 ${SECRET_DIR}/easytier_secret。
#   - 切勿把真实密钥长期留在仓库/脚本里。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi

# ================== 可调整参数 ==================
EASYTIER_VERSION="${EASYTIER_VERSION:-v2.6.4}"
EASYTIER_ZIP_NAME="easytier-linux-x86_64-${EASYTIER_VERSION}.zip"
SECRET_DIR="${SECRET_DIR:-/opt/secrets}"
# 本地 zip 的 SHA256（更新 zip 后需同步改这里，可用 Get-FileHash / sha256sum 计算）
EASYTIER_ZIP_SHA256="61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6"
# ================================================

# ---------- 日志 ----------
LOG_FILE="/var/log/install-easytier-$(date +%Y%m%d-%H%M%S).log"
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

# ---------- SHA256 校验 ----------
sha256_check() { # sha256_check <文件> <期望值> <名称>
    local expect_sum
    expect_sum=$(sha256sum "$1" | awk '{print $1}')
    if [[ "$expect_sum" != "$2" ]]; then
        log_error "$3 的 SHA256 与预期不符（离线包可能被篡改或版本不一致）"
        log_error "  实际: $expect_sum"
        log_error "  预期: $2"
        exit 1
    fi
}

log_info "日志文件：$LOG_FILE"

# ================== 路径配置 ==================
EASYTIER_INSTALL_SCRIPT="${SCRIPT_DIR}/easytier_install.sh"
EASYTIER_CONF_SRC="${SCRIPT_DIR}/easytier_notmiz1996.conf"
EASYTIER_CONF_DST="/opt/easytier/config/default.conf"
EASYTIER_ZIP_SRC="${SCRIPT_DIR}/${EASYTIER_ZIP_NAME}"
EASYTIER_ZIP_DST="/tmp/easytier_tmp_install.zip"
SECRET_FILE="${SECRET_DIR}/easytier_secret"

# ================== 前置检查 ==================
log_step "前置检查"

# 1. 官方安装脚本
if [[ ! -f "$EASYTIER_INSTALL_SCRIPT" ]]; then
    log_error "未找到官方安装脚本：$EASYTIER_INSTALL_SCRIPT"
    log_warn  "请将 https://raw.githubusercontent.com/EasyTier/EasyTier/main/script/install.sh 下载到本脚本同目录，命名为 easytier_install.sh"
    exit 1
fi
log_info "找到官方安装脚本：$(basename "$EASYTIER_INSTALL_SCRIPT")"

# 2. 自定义配置（可选）
if [[ ! -f "$EASYTIER_CONF_SRC" ]]; then
    log_warn "未找到自定义配置文件：$EASYTIER_CONF_SRC"
    log_warn "安装完成后将使用 EasyTier 默认配置，不进行覆盖。"
    SKIP_CONF=1
else
    log_info "找到自定义配置：$(basename "$EASYTIER_CONF_SRC")"
    SKIP_CONF=0
fi

# 3. 本地 zip 包 + SHA256
if [[ ! -f "$EASYTIER_ZIP_SRC" ]]; then
    log_error "未找到本地 zip 包：$EASYTIER_ZIP_SRC"
    log_warn  "请将 ${EASYTIER_ZIP_NAME} 放到本脚本同目录。"
    exit 1
fi
if [[ -n "$EASYTIER_ZIP_SHA256" ]]; then
    sha256_check "$EASYTIER_ZIP_SRC" "$EASYTIER_ZIP_SHA256" "EasyTier zip"
fi
log_info "找到本地 zip 包：$(basename "$EASYTIER_ZIP_SRC")（SHA256 校验通过）"

# 4. 环境检查
for cmd in unzip curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "缺少命令：$cmd，请先安装：sudo apt install -y $cmd"
        exit 1
    fi
done
log_info "依赖命令检查通过"

# ================== 密钥准备 ==================
mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

if [[ "$SKIP_CONF" -eq 0 ]] && grep -q "{{EASYTIER_SECRET}}" "$EASYTIER_CONF_SRC"; then
    log_step "准备 mesh 密钥"
    if [[ -s "$SECRET_FILE" ]]; then
        EASYTIER_SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"
        log_info "使用已有密钥文件：$SECRET_FILE"
    else
        EASYTIER_SECRET=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
        umask 077
        printf '%s' "$EASYTIER_SECRET" > "$SECRET_FILE"
        log_warn "首次安装：已生成随机 mesh 密钥并保存到 $SECRET_FILE"
        log_warn "请把该密钥同步给 mesh 的其它设备（替换它们的 network_secret）！"
    fi
else
    EASYTIER_SECRET=""
fi

# ================== 移动 zip 到 /tmp ==================
log_step "准备 zip 包"

if [[ -f "$EASYTIER_ZIP_DST" ]]; then
    log_warn "$EASYTIER_ZIP_DST 已存在，将覆盖。"
fi
cp -f "$EASYTIER_ZIP_SRC" "$EASYTIER_ZIP_DST"
chmod 644 "$EASYTIER_ZIP_DST"
log_info "已将 zip 包复制到：$EASYTIER_ZIP_DST"
log_info "文件大小：$(du -h "$EASYTIER_ZIP_DST" | cut -f1)"

# ================== 执行安装 ==================
log_step "执行 EasyTier 安装"

log_info "执行：bash $EASYTIER_INSTALL_SCRIPT install --no-gh-proxy"
if bash "$EASYTIER_INSTALL_SCRIPT" install --no-gh-proxy; then
    log_info "EasyTier 安装脚本执行完毕。"
else
    log_error "EasyTier 安装脚本退出状态非 0，请检查上面的输出。"
    exit 1
fi

# ================== 替换配置文件 ==================
log_step "配置 EasyTier"

if [[ "$SKIP_CONF" -eq 0 ]]; then
    if [[ ! -d "$(dirname "$EASYTIER_CONF_DST")" ]]; then
        log_error "目标目录不存在：$(dirname "$EASYTIER_CONF_DST")，跳过配置替换。"
    else
        # 先停服务，消除"默认配置（public peer + default 密码）"的暴露窗口
        systemctl stop easytier@default 2>/dev/null || true

        if [[ -f "$EASYTIER_CONF_DST" ]]; then
            cp "$EASYTIER_CONF_DST" "${EASYTIER_CONF_DST}.bak.$(date +%Y%m%d-%H%M%S)"
            log_info "已备份原配置到 ${EASYTIER_CONF_DST}.bak.*"
        fi

        STAGED_CONF="$(mktemp /tmp/easytier_conf.XXXXXX)"
        if [[ -n "$EASYTIER_SECRET" ]]; then
            # 转义 sed 替换串中的特殊字符（/ & |），避免自定义密钥破坏 sed 语法
            SECRET_ESC="$(printf '%s' "$EASYTIER_SECRET" | sed -e 's/[\/&|]/\\&/g')"
            sed "s/{{EASYTIER_SECRET}}/${SECRET_ESC}/g" "$EASYTIER_CONF_SRC" > "$STAGED_CONF"
            log_info "已用随机/已有密钥替换配置中的 {{EASYTIER_SECRET}} 占位符"
        else
            cp "$EASYTIER_CONF_SRC" "$STAGED_CONF"
        fi
        cp "$STAGED_CONF" "$EASYTIER_CONF_DST"
        rm -f "$STAGED_CONF"
        chmod 600 "$EASYTIER_CONF_DST"
        log_info "已部署配置到 $EASYTIER_CONF_DST（权限 600）"
    fi
else
    log_info "跳过配置替换，使用默认配置。"
fi

# ================== 重启服务 ==================
log_step "重启 EasyTier 服务"

if systemctl list-unit-files | grep -q "easytier@default"; then
    systemctl enable easytier@default 2>/dev/null || true
    if systemctl restart easytier@default 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet easytier@default; then
            log_info "EasyTier 服务已重启并处于运行状态"
        else
            log_warn "EasyTier 服务未处于运行状态，请检查：systemctl status easytier@default"
        fi
    else
        log_warn "EasyTier 服务重启失败，请检查配置：$EASYTIER_CONF_DST"
    fi
else
    [[ -f /etc/systemd/system/easytier@.service ]] || log_warn "未找到 easytier@default 服务，请手动检查。"
fi

# ================== 清理 ==================
log_step "清理临时文件"
rm -f "$EASYTIER_ZIP_DST"
log_info "已删除 $EASYTIER_ZIP_DST"

# ================== 完成 ==================
log_step "安装完成"
echo -e "${GREEN}EasyTier 安装流程结束。${NC}"
echo ""
echo "常用命令："
echo "  查看状态：systemctl status easytier@default"
echo "  启动：    systemctl start easytier@default"
echo "  停止：    systemctl stop easytier@default"
echo "  重启：    systemctl restart easytier@default"
echo "  配置文件：$EASYTIER_CONF_DST"
echo "  配置目录：/opt/easytier/config/"
echo "  mesh 密钥：$SECRET_FILE"
echo ""
log_info "完整日志：$LOG_FILE"
