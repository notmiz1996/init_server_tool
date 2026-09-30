#!/bin/bash
#
# Clash for Linux 安装脚本（完全离线版，自动配置 .env.install）
# 前置：
#   1. clash-for-linux-install-master.zip 放在本脚本同目录
#   2. 三个离线二进制放在本脚本同目录：
#        mihomo-linux-amd64-v3-v1.19.31.gz
#        yq_linux_amd64.tar.gz
#        subconverter_linux64.tar.gz
#   3. 以上文件的 SHA256 与本脚本内嵌值一致（更新包后需同步更新）
# 用法：sudo bash install-clash.sh
#       （也可通过 sudo bash init.sh clash 执行）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi

# ================== 可调整参数 ==================
CLASH_ZIP_NAME="clash-for-linux-install-master.zip"
MIHOMO_FILE="mihomo-linux-amd64-v3-v1.19.31.gz"
YQ_FILE="yq_linux_amd64.tar.gz"
SUBCONVERTER_FILE="subconverter_linux64.tar.gz"
# 硬编码版本号（与本地文件版本一致；mihomo 版本从文件名派生，yq/subconverter 手工维护）
VERSION_YQ="v4.53.6"
VERSION_SUBCONVERTER="v0.9.9"
CLASH_DIR="/opt/clash-for-linux-install"
CLASH_ARCHIVES="${CLASH_DIR}/archives"
ENV_INSTALL="${CLASH_DIR}/.env.install"

# SHA256 校验和（更新离线包后请同步更新，可用 sha256sum 计算）
SHA_CLASH_ZIP="bd978e8dc19d221efbe666d1e531747ee5364c21d93805f1133ae3fde0d16752"
SHA_MIHOMO="4e8808e79f1e452a0300ce1ee89fcaf2cccd5249a100f2238877214e5ca316b3"
SHA_YQ="38b907b21b1b04327fb9481c595331d925a67c6ee1aabd0ef419d0b7d12dfb3d"
SHA_SUBCONVERTER="b9d6f969300d3c8398f9d970db7436274df0ff3e7c91d935d26bbd79fafc8488"
# ================================================

# ---------- 日志 ----------
LOG_FILE="/var/log/install-clash-$(date +%Y%m%d-%H%M%S).log"
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

log_info "日志文件：$LOG_FILE"

# ================== 架构断言 ==================
log_step "前置检查"

if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    log_error "本离线包仅支持 amd64（当前架构：$(dpkg --print-architecture)）。"
    exit 1
fi

for cmd in unzip curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "缺少命令：$cmd，请先安装：sudo apt install -y $cmd"
        exit 1
    fi
done
log_info "依赖命令检查通过"

# ================== 路径配置 ==================
CLASH_ZIP_SRC="${SCRIPT_DIR}/${CLASH_ZIP_NAME}"
MIHOMO_SRC="${SCRIPT_DIR}/${MIHOMO_FILE}"
YQ_SRC="${SCRIPT_DIR}/${YQ_FILE}"
SUBCONVERTER_SRC="${SCRIPT_DIR}/${SUBCONVERTER_FILE}"

MISSING=0
for f in "$CLASH_ZIP_SRC" "$MIHOMO_SRC" "$YQ_SRC" "$SUBCONVERTER_SRC"; do
    if [[ ! -f "$f" ]]; then
        log_error "缺少文件：$f"
        MISSING=1
    else
        log_info "找到：$(basename "$f")（$(du -h "$f" | cut -f1)）"
    fi
done
if [[ "$MISSING" -eq 1 ]]; then
    log_error "请把缺失文件放到本脚本同目录后重试。"
    exit 1
fi

# mihomo 版本号从文件名派生，避免与文件名手工失配（纯参数展开，不依赖外部命令）
MIHOMO_VER_RAW="${MIHOMO_FILE##*-v}"   # 1.19.31.gz
MIHOMO_VER_RAW="${MIHOMO_VER_RAW%.gz}" # 1.19.31
VERSION_MIHOMO="v${MIHOMO_VER_RAW}"
log_info "mihomo 版本（自文件名派生）：$VERSION_MIHOMO"

# ================== SHA256 校验 ==================
log_info "校验离线包 SHA256..."
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
sha256_check "$CLASH_ZIP_SRC" "$SHA_CLASH_ZIP" "clash 源码包"
sha256_check "$MIHOMO_SRC" "$SHA_MIHOMO" "mihomo 内核二进制"
sha256_check "$YQ_SRC" "$SHA_YQ" "yq"
sha256_check "$SUBCONVERTER_SRC" "$SHA_SUBCONVERTER" "subconverter"
log_info "离线包 SHA256 校验全部通过"

# ================== 准备 Clash 目录 ==================
log_step "准备 Clash 目录"

if [[ -d "$CLASH_DIR" ]]; then
    log_warn "$CLASH_DIR 已存在，跳过解压。"
    log_info "如需重装，请先手动删除：sudo rm -rf $CLASH_DIR"
else
    log_info "解压 $CLASH_ZIP_NAME 到临时目录..."
    TMP_EXTRACT=$(mktemp -d /tmp/clash_extract_XXXXXX)

    if ! unzip -o "$CLASH_ZIP_SRC" -d "$TMP_EXTRACT"; then
        log_error "解压失败，请检查 zip 文件完整性。"
        rm -rf "$TMP_EXTRACT"
        exit 1
    fi

    SRC_DIR=$(find "$TMP_EXTRACT" -maxdepth 1 -type d -name 'clash-for-linux-install-*' | head -n1)
    if [[ -z "$SRC_DIR" ]]; then
        log_error "解压后未找到 clash-for-linux-install-* 目录。"
        ls -la "$TMP_EXTRACT"
        rm -rf "$TMP_EXTRACT"
        exit 1
    fi
    log_info "解压目录：$SRC_DIR"

    mv "$SRC_DIR" "$CLASH_DIR"
    rm -rf "$TMP_EXTRACT"
    log_info "已移动到 $CLASH_DIR"
fi

if [[ ! -f "$CLASH_DIR/install.sh" ]]; then
    log_error "找不到 $CLASH_DIR/install.sh，无法继续。"
    exit 1
fi
log_info "找到 $CLASH_DIR/install.sh"

# ================== 复制离线二进制到 archives ==================
log_step "部署离线二进制到 archives"

mkdir -p "$CLASH_ARCHIVES"

rm -f "$CLASH_ARCHIVES"/mihomo* 2>/dev/null || true
rm -f "$CLASH_ARCHIVES"/yq_linux_amd64.tar.gz 2>/dev/null || true
rm -f "$CLASH_ARCHIVES"/subconverter_linux64.tar.gz 2>/dev/null || true

cp -f "$MIHOMO_SRC" "$CLASH_ARCHIVES/${MIHOMO_FILE}"
cp -f "$YQ_SRC" "$CLASH_ARCHIVES/${YQ_FILE}"
cp -f "$SUBCONVERTER_SRC" "$CLASH_ARCHIVES/${SUBCONVERTER_FILE}"

log_info "已复制到 $CLASH_ARCHIVES："
ls -lh "$CLASH_ARCHIVES" | grep -E "mihomo|yq|subconverter" | awk '{print "  " $9 "  (" $5 ")"}'

# ================== 配置 .env.install（离线模式） ==================
log_step "配置 .env.install（离线模式）"

# 如果文件不存在，创建一个空的
touch "$ENV_INSTALL"

# 备份一次（只备份第一次）
if [[ ! -f "${ENV_INSTALL}.bak" ]]; then
    cp "$ENV_INSTALL" "${ENV_INSTALL}.bak"
    log_info "已备份原 .env.install 到 ${ENV_INSTALL}.bak"
fi

# 删除已存在的相关行，避免重复
sed -i '/^CLASHCTL_CHECK_LATEST_VERSION=/d' "$ENV_INSTALL"
sed -i '/^VERSION_MIHOMO=/d' "$ENV_INSTALL"
sed -i '/^VERSION_YQ=/d' "$ENV_INSTALL"
sed -i '/^VERSION_SUBCONVERTER=/d' "$ENV_INSTALL"

# 追加离线配置
{
    echo ""
    echo "# ---- 离线安装配置（由 install-clash.sh 自动写入）----"
    echo "CLASHCTL_CHECK_LATEST_VERSION=0"
    echo "VERSION_MIHOMO=${VERSION_MIHOMO}"
    echo "VERSION_YQ=${VERSION_YQ}"
    echo "VERSION_SUBCONVERTER=${VERSION_SUBCONVERTER}"
} >> "$ENV_INSTALL"

log_info "已写入 .env.install："
grep -E "CLASHCTL_CHECK_LATEST_VERSION|VERSION_MIHOMO|VERSION_YQ|VERSION_SUBCONVERTER" "$ENV_INSTALL" | sed 's/^/  /'

# ================== 执行安装 ==================
log_step "执行 Clash 安装"

cd "$CLASH_DIR"
log_info "执行 install.sh ..."
if bash install.sh; then
    log_info "Clash 安装脚本执行完毕。"
else
    log_error "Clash 安装脚本退出状态非 0，判定安装失败（不再继续启用服务，请检查上面的输出）。"
    cd - >/dev/null
    exit 1
fi
cd - >/dev/null

# ================== 启用服务 ==================
log_step "启用 Clash 服务"

# 这个项目用 mihomo 内核时服务名是 mihomo.service
if systemctl list-unit-files | grep -qE "^(mihomo|clash|clashctl)\.service"; then
    SVC=$(systemctl list-unit-files | grep -oE "^(mihomo|clash|clashctl)\.service" | head -n1)
    log_info "检测到服务：$SVC"
    if systemctl enable --now "$SVC" 2>/dev/null; then
        log_info "$SVC 已启用"
        sleep 1
        if systemctl is-active --quiet "$SVC"; then
            log_info "$SVC 处于运行状态"
        else
            log_warn "$SVC 未处于运行状态，请检查：systemctl status $SVC"
        fi
    else
        log_warn "$SVC 启动失败，请检查配置。"
    fi
else
    log_warn "未找到 systemd 服务，请手动检查安装结果。"
fi

# ================== 管理口安全检查 ==================
log_step "管理口（9090）安全检查"

RUNTIME_CFG="/root/clashctl/resources/runtime.yaml"
if [[ -f "$RUNTIME_CFG" ]] && grep -qE '^[[:space:]]*external-controller' "$RUNTIME_CFG"; then
    # \042 = 双引号，\047 = 单引号；用八进制转义避免引号嵌套出错
    EXT=$(grep -E '^[[:space:]]*external-controller' "$RUNTIME_CFG" | head -n1 | awk '{print $2}' | tr -d '\042\047')
    case "$EXT" in
        127.0.0.1*) log_info "external-controller 绑定 ${EXT}（良好，仅本机可访问）" ;;
        0.0.0.0*)   log_warn "external-controller 绑定 ${EXT}：Web 管理面板可被局域网/公网访问！"
                    log_warn "建议改为 127.0.0.1:9090（mixin.yaml 与 runtime.yaml 同改，或用脚本结尾的 yq 命令），"
                    log_warn "需要远程管理时走 SSH 隧道：ssh -L 9090:127.0.0.1:9090 user@server"
                    ;;
        *) log_info "external-controller 绑定 ${EXT}"
    esac
else
    log_info "未在 $RUNTIME_CFG 找到 external-controller（使用默认值，一般为 127.0.0.1:9090）"
fi

# ================== 完成 ==================
log_step "安装完成"
echo -e "${GREEN}Clash for Linux 安装流程结束。${NC}"
echo ""
echo "常用命令："
echo "  查看状态：systemctl status mihomo"
echo "  启动：    systemctl start mihomo"
echo "  停止：    systemctl stop mihomo"
echo "  重启：    systemctl restart mihomo"
echo "  安装目录：/root/clashctl"
echo "  配置目录：/root/clashctl/resources"
echo "  Web 面板：http://<内网IP>:9090/ui"
echo ""
echo -e "${YELLOW}修改 Web 面板密码（默认密钥见安装日志）：${NC}"
echo "  1) 改 mixin 配置："
echo "     sudo SECRET='你的新密码' /root/clashctl/bin/yq -i '.secret = env(SECRET)' /root/clashctl/resources/mixin.yaml"
echo ""
echo "  2) 同步改 runtime 配置（mihomo 实际加载的文件）："
echo "     sudo SECRET='你的新密码' /root/clashctl/bin/yq -i '.secret = env(SECRET)' /root/clashctl/resources/runtime.yaml"
echo ""
echo "  3) 重启服务："
echo "     sudo systemctl restart mihomo"
echo ""
echo "  4) 验证："
echo "     curl -i -H \"Authorization: Bearer 你的新密码\" http://127.0.0.1:9090/configs"
echo "     # 返回 200 即成功"
echo ""
echo -e "${YELLOW}查看当前密码：${NC}"
echo "     sudo grep 'secret' /root/clashctl/resources/runtime.yaml"
echo ""
log_info "完整日志：$LOG_FILE"
