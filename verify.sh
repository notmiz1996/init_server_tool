#!/bin/bash
#
# 统一验证矩阵：红灯清单，全部通过才允许打"模板完成"
# 用法：bash verify.sh   （root）
# 设计：只校验"已安装"的东西（未装的跳过并提示），失败项计数汇总
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    set -a; source "${SCRIPT_DIR}/config.env"; set +a
fi
SECRET_DIR="${SECRET_DIR:-/opt/secrets}"
GPU_COUNT_EXPECT="${GPU_COUNT_EXPECT:-0}"
VLLM_PORT="${VLLM_PORT:-8000}"
VERIFY_DOCKER_SMOKE="${VERIFY_DOCKER_SMOKE:-1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
FAILS=0
ok()  { echo -e "  ${GREEN}[PASS]${NC} $*"; }
ko()  { echo -e "  ${RED}[FAIL]${NC} $*"; FAILS=$((FAILS+1)); }
info(){ echo -e "  ${YELLOW}[SKIP]${NC} $*"; }
sec() { echo -e "\n${BLUE}== $* =="; }

# 若 systemd 单元已安装则必须 active；未安装则跳过
svc_active() {
    local unit="$1"
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${unit}\.service"; then
        if systemctl is-active --quiet "$unit"; then
            ok "$unit 运行中"
        else
            ko "$unit 未运行（systemctl status $unit）"
        fi
    else
        info "$unit 未安装，跳过"
    fi
}

unit_exists() {
    systemctl list-unit-files 2>/dev/null | grep -qE "^$1\.service"
}

sec "基础环境"
svc_active ssh
svc_active fail2ban
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    ok "NTP 已同步"
else
    ko "NTP 未同步（timedatectl status）"
fi
TZ=$(timedatectl show -p Timezone --value 2>/dev/null)
[[ "$TZ" == "UTC" ]] && ok "时区 UTC" || ko "时区为 $TZ，非 UTC"

# SSH 加固（init-server.sh 生成 99-init.conf 时生效）
if [[ -f /etc/ssh/sshd_config.d/99-init.conf ]]; then
    SSHD_T=$(sshd -T 2>/dev/null)
    echo "$SSHD_T" | grep -qi '^permitrootlogin no' && ok "sshd: PermitRootLogin no" || ko "sshd: PermitRootLogin 未禁 root"
    if grep -qi 'passwordauthentication no' /etc/ssh/sshd_config.d/99-init.conf; then
        echo "$SSHD_T" | grep -qi '^passwordauthentication no' && ok "sshd: PasswordAuthentication no" || ko "sshd: 密码登录未禁用（运行值）"
    else
        info "sshd: 未禁密码登录（当时未检测到非 root 密钥，属预期）"
    fi
else
    info "SSH 加固配置不存在（init base 未执行或未加固）"
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qE '^Status:[[:space:]]*active'; then
    ok "UFW 已启用"
else
    ko "UFW 未启用（init base 的 UFW_ENABLE=1 时应当启用）"
fi

sec "GPU 与 Docker"
if command -v nvidia-smi >/dev/null 2>&1; then
    N_GPU=$(nvidia-smi -L 2>/dev/null | wc -l)
    if [[ "$GPU_COUNT_EXPECT" -gt 0 ]]; then
        [[ "$N_GPU" -eq "$GPU_COUNT_EXPECT" ]] && ok "识别 GPU 数 = $N_GPU" || ko "识别 GPU 数 $N_GPU != 期望 $GPU_COUNT_EXPECT"
    else
        [[ "$N_GPU" -gt 0 ]] && ok "识别 GPU 数 = $N_GPU" || ko "nvidia-smi 未发现 GPU"
    fi
    # 功率上限：每张卡 power.limit < power.max_limit
    PWR_BAD=0
    IFS=',' read -ra LIM < <(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null)
    IFS=',' read -ra MAX < <(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null)
    for i in "${!LIM[@]}"; do
        l=${LIM[$i]//[^0-9]/}; m=${MAX[$i]//[^0-9]/}
        if [[ -z "$l" || -z "$m" ]]; then PWR_BAD=1; break; fi
        [[ "$l" -lt "$m" ]] || PWR_BAD=1
    done
    [[ "$PWR_BAD" -eq 0 ]] && ok "GPU 功率上限已生效（limit < max）" || ko "GPU 功率上限未生效或查询失败"
else
    info "nvidia-smi 不存在（nvidia 阶段未执行），GPU 相关检查跳过"
fi
svc_active gpu-power-limit
svc_active docker
if command -v nvidia-ctk >/dev/null 2>&1; then
    ok "nvidia-container-toolkit 就位"
else
    ko "nvidia-ctk 不存在（nvidia-container-toolkit 未装）"
fi
if [[ "$VERIFY_DOCKER_SMOKE" == "1" ]] && command -v docker >/dev/null 2>&1; then
    if docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1; then
        ok "docker --gpus all 冒烟测试通过"
    else
        ko "docker GPU 冒烟失败（离线机可设 VERIFY_DOCKER_SMOKE=0 跳过）"
    fi
else
    info "docker GPU 冒烟测试跳过"
fi

sec "vLLM 推理服务"
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-turing-fp8$'; then
    if [[ "$(docker inspect -f '{{.State.Running}}' vllm-turing-fp8 2>/dev/null)" == "true" ]]; then
        ok "vllm-turing-fp8 容器运行中"
    else
        ko "vllm-turing-fp8 容器未运行（docker logs vllm-turing-fp8）"
    fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${VLLM_PORT}$"; then
        ok "端口 ${VLLM_PORT} 监听中"
    else
        ko "端口 ${VLLM_PORT} 未监听"
    fi
else
    info "vLLM 容器不存在（未启动，属正常，日常执行 start-vllm.sh）"
fi

sec "组网服务（已安装才校验）"
if [[ -f /etc/systemd/system/easytier@.service ]] || unit_exists "easytier@"; then
    if systemctl is-active --quiet easytier@default; then
        ok "easytier@default 运行中"
    else
        ko "easytier@default 未运行（systemctl status easytier@default）"
    fi
    if ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -qi '^easytier'; then
        ok "EasyTier TUN 网卡存在"
    else
        ko "未见 easytier* 网卡（检查配置 no_tun / 日志）"
    fi
else
    info "EasyTier 未安装，跳过"
fi
if unit_exists mihomo || unit_exists clash; then
    if unit_exists mihomo; then
        systemctl is-active --quiet mihomo && ok "mihomo 运行中" || ko "mihomo 未运行"
    else
        systemctl is-active --quiet clash && ok "clash 运行中" || ko "clash 未运行"
    fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]9090$'; then
        ok "9090 管理口监听中（确认绑定为 127.0.0.1，勿暴露公网）"
    else
        info "9090 未见监听（mihomo external-controller 可能配置为其他地址）"
    fi
else
    info "Clash 未安装，跳过"
fi

sec "机密文件"
for f in "$SECRET_DIR/vllm_api_key" "$SECRET_DIR/easytier_secret"; do
    if [[ -f "$f" ]]; then
        PERM=$(stat -c '%a' "$f" 2>/dev/null)
        [[ "$PERM" == "600" || "$PERM" == "400" ]] && ok "$(basename "$f") 存在且权限 $PERM" || ko "$(basename "$f") 权限为 $PERM，应为 600（chmod 600 $f）"
        [[ -s "$f" ]] || ko "$(basename "$f") 为空"
    else
        info "$(basename "$f") 不存在（对应服务未初始化）"
    fi
done

echo ""
echo "======================================================"
if (( FAILS > 0 )); then
    echo -e "${RED}验证结果：$FAILS 项失败，请逐项处理。${NC}"
    exit 1
fi
echo -e "${GREEN}验证结果：全部通过。${NC}"
exit 0
