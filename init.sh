#!/bin/bash
#
# init_server_tool 统一执行入口
#
# 用法：
#   sudo bash init.sh              # 交互式菜单
#   sudo bash init.sh base         # 直接执行指定阶段（可配 -y 跳过交互确认）
#   sudo bash init.sh all -y       # 顺序执行全部初始化阶段（遇到需重启点在提示处停）
#
# 阶段：base | nvidia | python | easytier | clash | vllm | verify | all
#   base     基础环境（含 Nouveau 两阶段，可能需要中途 reboot）
#   nvidia   NVIDIA 驱动 + Docker + GPU Toolkit + 功率上限
#   python   pipx + modelscope + uv（对 SUDO_USER）
#   easytier EasyTier 离线安装 + 配置
#   clash    Clash for Linux 离线安装
#   vllm     启动 vLLM 推理服务（服务操作，不属于初始化）
#   verify   统一验证矩阵
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 统一配置 ----------
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi

SECRET_DIR="${SECRET_DIR:-/opt/secrets}"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

# ---------- 状态 ----------
STATE_DIR="/var/lib/init-server-tool"
STATE_FILE="${STATE_DIR}/state"

state_get() { grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2; }
state_show() {
    if [[ -f "$STATE_FILE" ]]; then
        sed 's/^/  /' "$STATE_FILE"
    else
        echo "  （尚未执行过任何阶段）"
    fi
}

# ---------- 工具 ----------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 或 sudo 执行：sudo bash $0"
        exit 1
    fi
}

cleanup_old_logs() {
    find /var/log -maxdepth 1 -type f \
        \( -name 'init-*.log' -o -name 'install-*.log' -o -name 'verify-*.log' \) \
        -mtime +30 -delete 2>/dev/null || true
}

ASSUME_YES=0
y=""

# ---------- 阶段执行 ----------
stage_base() {
    log_step "阶段 base：基础环境（含 Nouveau 两阶段）"
    bash "${SCRIPT_DIR}/init-server.sh" $y
    local st; st=$(state_get base)
    if [[ "$st" == "pending-reboot" ]]; then
        log_warn "base 阶段一完成（Nouveau 已禁用），需要重启后才能继续。"
    fi
}

stage_nvidia() {
    log_step "阶段 nvidia：NVIDIA 驱动 + Docker + GPU Toolkit"
    if [[ -f /var/run/reboot-required ]]; then
        log_error "系统标记有待重启的更新（内核可能已升级）。"
        log_error "请先 sudo reboot，重启后再执行本阶段，否则驱动可能按旧内核编译失败。"
        exit 1
    fi
    bash "${SCRIPT_DIR}/install-nvidia.sh" $y
    local st; st=$(state_get nvidia)
    [[ "$st" == "pending-reboot" ]] && log_warn "nvidia 阶段需要重启后生效，请 sudo reboot。"
}

stage_python() {
    log_step "阶段 python：pipx + modelscope + uv"
    [[ -n "${SUDO_USER:-}" ]] || { log_error "请通过 sudo 执行，需要 SUDO_USER 作为目标用户。"; exit 1; }
    bash "${SCRIPT_DIR}/install-python-tools.sh"
}

stage_easytier() {
    log_step "阶段 easytier：EasyTier 离线安装"
    bash "${SCRIPT_DIR}/easytier_install/install-easytier.sh" $y
}

stage_clash() {
    log_step "阶段 clash：Clash for Linux 离线安装"
    bash "${SCRIPT_DIR}/clash-install/install-clash.sh" $y
}

stage_vllm() {
    log_step "阶段 vllm：启动 vLLM 推理服务"
    bash "${SCRIPT_DIR}/start-vllm.sh" $y
}

stage_verify() {
    log_step "阶段 verify：统一验证矩阵"
    if bash "${SCRIPT_DIR}/verify.sh"; then
        log_info "验证通过。"
    else
        log_error "验证存在失败项，请按上方 [FAIL] 清单处理。"
        return 1
    fi
}

# ---------- 参数解析 ----------
STAGE="${1:-}"
shift 2>/dev/null || true
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1; y="-y" ;;
        # 其他无意义位置已在上层解析
        *) log_warn "忽略未知参数：$a" ;;
    esac
done

# ---------- 菜单 ----------
banner() {
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  init_server_tool —— Ubuntu 24.04 服务器初始化模板${NC}"
    echo -e "${CYAN}============================================================${NC}"
    if [[ -f /var/run/reboot-required ]]; then
        echo -e "${YELLOW}  ⚠ 检测到待重启更新（/var/run/reboot-required），建议先 sudo reboot${NC}"
    fi
    echo "  当前初始化状态（${STATE_FILE}）："
    state_show
    echo ""
    echo "  1) base     基础环境（静态IP/源/SSH/Fail2ban/中文/Nouveau）"
    echo "  2) nvidia   NVIDIA 驱动 + Docker + GPU Toolkit + 功率上限"
    echo "  3) python   Python 工具链（pipx / modelscope / uv）"
    echo "  4) easytier EasyTier 组网（离线）"
    echo "  5) clash    Clash for Linux（离线）"
    echo "  6) vllm     启动 vLLM 推理服务（日常操作）"
    echo "  7) verify   统一验证矩阵"
    echo "  8) 查看状态"
    echo "  0) all      顺序执行全部初始化阶段（不含 vllm 启动）"
    echo "  q) 退出"
}

MENU_MODE=1
if [[ -n "$STAGE" ]]; then
    MENU_MODE=0
else
    [[ -t 0 ]] || { log_error "非交互模式必须指定阶段，例如：sudo bash init.sh base -y"; exit 2; }
fi

# ---------- 主流程 ----------
if (( MENU_MODE )); then
    require_root
    cleanup_old_logs
    while true; do
        banner
        read -rp "请输入菜单编号: " sel
        case "$sel" in
            1) stage_base ;;
            2) stage_nvidia ;;
            3) stage_python ;;
            4) stage_easytier ;;
            5) stage_clash ;;
            6) stage_vllm ;;
            7) stage_verify ;;
            8) echo ""; state_show ;;
            0)
                stage_base
                [[ "$(state_get base)" == "pending-reboot" ]] || [[ -f /var/run/reboot-required ]] && {
                    echo ""; log_warn "base 需要重启。请 sudo reboot，重启后再次执行 \`sudo bash init.sh all -y\` 续跑。"
                    break
                }
                stage_nvidia || break
                [[ "$(state_get nvidia)" == "pending-reboot" ]] && {
                    echo ""; log_warn "nvidia 需要重启。请 sudo reboot，重启后再次执行 \`sudo bash init.sh all -y\` 续跑。"
                    break
                }
                stage_python || break
                stage_easytier || break
                stage_clash || break
                stage_verify || true
                echo ""; log_info "all 流程执行完毕（verify 结果如上）。"
                break
                ;;
            q|Q) echo "已退出。"; break ;;
            *) log_warn "无效输入：$sel" ;;
        esac
    done
else
    require_root
    cleanup_old_logs
    case "$STAGE" in
        base)     stage_base ;;
        nvidia)   stage_nvidia ;;
        python)   stage_python ;;
        easytier) stage_easytier ;;
        clash)    stage_clash ;;
        vllm)     stage_vllm ;;
        verify)   stage_verify ;;
        all)
            stage_base
            if [[ "$(state_get base)" == "pending-reboot" ]] || [[ -f /var/run/reboot-required ]]; then
                log_warn "base 需要重启。重启后再次执行：sudo bash init.sh all $y"
                exit 10
            fi
            stage_nvidia || exit 1
            if [[ "$(state_get nvidia)" == "pending-reboot" ]]; then
                log_warn "nvidia 需要重启。重启后再次执行：sudo bash init.sh all $y"
                exit 10
            fi
            stage_python || exit 1
            stage_easytier || exit 1
            stage_clash || exit 1
            stage_verify || true
            ;;
        *) log_error "未知阶段：$STAGE（可选 base|nvidia|python|easytier|clash|vllm|verify|all）"; exit 2 ;;
    esac
fi
