# init_server_tool —— Ubuntu 24.04 GPU 服务器初始化模板

面向**全新安装的 Ubuntu 24.04 Server**（4×NVIDIA + Docker + vLLM 推理）的一键初始化工具。
所有可调参数集中在 `config.env`，统一入口为 `init.sh`（编号菜单）。

---

## 1. 文件清单

| 文件 | 作用 |
|------|------|
| `init.sh` | **统一入口**（编号菜单 / 自动化阶段参数） |
| `config.env` | 全局配置（IP、网关、镜像源、驱动版本、功率比例、密钥目录等） |
| `init-server.sh` | 基础环境：换源、升级、OpenSSH、常用工具、Fail2ban、SSH 加固、UFW、中文、静态 IP、时区、Swap、禁用 Nouveau（两阶段） |
| `install-nvidia.sh` | NVIDIA 驱动 + Docker + nvidia-container-toolkit + GPU 功率上限 |
| `install-python-tools.sh` | pipx + modelscope + uv（对 `SUDO_USER`） |
| `easytier_install/` | EasyTier 离线安装（`install-easytier.sh` 为入口，含官方脚本与自定义配置） |
| `clash-install/` | Clash for Linux 离线安装（含 4 个离线二进制） |
| `start-vllm.sh` | 启动 vLLM 推理容器（日常操作，不属于初始化） |
| `verify.sh` | 统一验证矩阵（红灯清单） |
| `优化建议-脚本审查.md` | 本次改造前的完整审查报告（问题清单与依据） |

---

## 2. 快速开始

```bash
# 1) 上传整个目录到服务器（例如 /root/init_server_tool）
# 2) 按需修改参数
vi config.env
# 3) 进菜单
sudo bash init.sh
```

菜单：

```
1) base      基础环境（含 Nouveau 两阶段，可能需要中途 reboot）
2) nvidia    NVIDIA 驱动 + Docker + GPU Toolkit + 功率上限
3) python    Python 工具链（pipx / modelscope / uv）
4) easytier  EasyTier 组网（离线）
5) clash     Clash for Linux（离线）
6) vllm      启动 vLLM 推理服务（日常操作）
7) verify    统一验证矩阵
8) 查看状态
0) all       顺序执行全部初始化阶段（不含 vllm 启动）
q) 退出
```

无人值守（自动化）等价用法：

```bash
sudo bash init.sh base -y        # 单阶段
sudo bash init.sh all -y         # 全流程
sudo bash init.sh verify         # 只验证
```

---

## 3. 标准执行顺序与重启点

```
① sudo bash init.sh base -y
   └─ 若 Nouveau 在运行 → 写入黑名单 → 提示重启（状态记为 base=pending-reboot）
② sudo reboot
③ sudo bash init.sh all -y        # 自动跳过已完成项，继续 base 收尾 + 后续阶段
   └─ 装完驱动若需要重启 → 再次提示（nvidia=pending-reboot）
④ [如提示] sudo reboot && sudo bash init.sh all -y
⑤ sudo bash init.sh verify        # 全绿即模板合格
⑥ bash start-vllm.sh              # 日常起推理服务
```

**为什么必须先重启再装驱动**：驱动按 `uname -r` 对应的内核编译（dkms），
若内核已升级但未重启，重启后模块与新内核不匹配会导致 `nvidia-smi` 失效。
`install-nvidia.sh` 已内置 `/var/run/reboot-required` 检查，会主动拦住这种状态。

状态文件：`/var/lib/init-server-tool/state`（记录每个阶段的状态，菜单可直接查看）。

---

## 4. 密钥管理（重要）

所有密钥集中在 `config.env` 的 `SECRET_DIR`（默认 `/opt/secrets`，权限 700/600）：

| 文件 | 用途 | 生成方式 |
|------|------|----------|
| `vllm_api_key` | vLLM API key | `start-vllm.sh` 首次运行自动随机生成 |
| `easytier_secret` | EasyTier mesh 密钥 | `install-easytier.sh` 首次运行自动随机生成 |

要点：

- **脚本与配置里不再保存明文密钥**（EasyTier 配置用 `{{EASYTIER_SECRET}}` 占位符）。
- **首次生成后需要同步客户端**：vLLM 的 key 变了，IDE/DSH 里配置的 key 要一起改；
  EasyTier 的密钥变了，mesh 内其它设备的 `network_secret` 要一起改成相同值。
- **加入既有 mesh**：先写入 `sudo install -m600 /dev/null /opt/secrets/easytier_secret`
  再把真实密钥放进去，然后运行 EasyTier 阶段，脚本会直接使用它而不是随机生成。
- 旧版本脚本里的明文口令（曾同时用于 vLLM 与 EasyTier）**已视为泄露，务必轮换**。

---

## 5. 验证矩阵

```bash
sudo bash init.sh verify
```

检查项（只校验"已安装"的组件，未装的跳过）：

- 基础：ssh / fail2ban 运行、NTP 同步、时区 UTC、SSH 加固（`PermitRootLogin no` 等）、UFW 已启用
- GPU：`nvidia-smi -L` 数量 == `GPU_COUNT_EXPECT`、**每卡 `power.limit < power.max_limit`**、
  `gpu-power-limit.service` / `docker` 运行、`nvidia-ctk` 就位、`docker --gpus all` 冒烟
- 服务：vLLM 容器运行 + 端口监听
- 组网：`easytier@default` 运行 + TUN 网卡存在；mihomo/clash 运行 + 9090 监听
- 机密：密钥文件存在且权限为 600

失败项会以 `[FAIL]` 列出并以退出码 1 结束（可接入流水线）。

---

## 6. 关键注意事项

1. **UFW 与 Docker**：Docker 绕过 UFW 的 FORWARD 链，靠 UFW 限制容器端口**无效**。
   本模板的做法是容器端口显式绑定到指定 IP（`-p ${VLLM_BIND_IP}:${VLLM_PORT}:8000`），
   请勿改成 `-p 8000:8000`，否则等于对全网开放推理服务。
2. **自动安全更新**：脚本只在运行期间临时停用 `unattended-upgrades` / `apt-daily.timer`，
   退出时（含"提示重启"的提前退出路径）自动恢复，不再永久禁用。
3. **中文环境**：只生成 `zh_CN.UTF-8` 并装中文字体，**系统默认 locale 仍为 `C.UTF-8`**
   （避免脚本解析 `df`/`date`/`ls` 英文输出出错）。个人终端中文请在 `~/.bashrc` 里
   `export LANG=zh_CN.UTF-8`。
4. **静态 IP 幂等**：重复执行时会先判断该 IP 是否已在本机网卡上，避免自己的内核
   应答 ARP 导致误报"IP 被占用"。
5. **失败回滚**：netplan 静态 IP 有三段式回滚（generate / apply / ping 网关），
   回滚会把 `*.disabled` 改回原名并用 `/etc/netplan/backup/` 兜底。
   源文件备份：`/etc/apt/sources.list.d/ubuntu.sources.bak`。
6. **日志**：每次运行写 `/var/log/init-*.log`、`install-*.log`、`verify-*.log`；
   已安装 `/etc/logrotate.d/init-server-tool`（每周或超 50M 轮转，保留 4 份）。
7. **docker 组 = root 权限**：`install-nvidia.sh` 会把 `SUDO_USER` 加入 docker 组，
   请勿授予不可信用户。

---

## 7. 离线包与校验

脚本内嵌 SHA256，安装前自动校验（不匹配即中止）：

| 文件 | SHA256 |
|------|--------|
| `easytier_install/easytier-linux-x86_64-v2.6.4.zip` | `61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6` |
| `clash-install/clash-for-linux-install-master.zip` | `bd978e8dc19d221efbe666d1e531747ee5364c21d93805f1133ae3fde0d16752` |
| `clash-install/mihomo-linux-amd64-v3-v1.19.31.gz` | `4e8808e79f1e452a0300ce1ee89fcaf2cccd5249a100f2238877214e5ca316b3` |
| `clash-install/yq_linux_amd64.tar.gz` | `38b907b21b1b04327fb9481c595331d925a67c6ee1aabd0ef419d0b7d12dfb3d` |
| `clash-install/subconverter_linux64.tar.gz` | `b9d6f969300d3c8398f9d970db7436274df0ff3e7c91d935d26bbd79fafc8488` |

换包后必须同步更新脚本里的 `SHA_*` / `EASYTIER_ZIP_SHA256`，否则会中止（这是有意的保护）。

> NVIDIA 驱动（`nvidia-driver-610` = 610.57.04，noble updates/multiverse）与
> `nvidia-container-toolkit` 需要联网从 apt 源拉取，不在离线包范围内。

---

## 8. 故障恢复手册

| 症状 | 处理 |
|------|------|
| `init-server.sh` 换源后 `apt update` 失败 | `sudo cp /etc/apt/sources.list.d/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources && sudo apt update` |
| 静态 IP 配错、SSH 连不上 | 控制台登录：`sudo rm -f /etc/netplan/01-static-ip.yaml`，把 `/etc/netplan/*.disabled` 改回原名，`sudo netplan apply` |
| 驱动装完 `nvidia-smi` 无输出 | 确认已重启；`dmesg \| grep -i nvidia`；`dkms status`；必要时 `sudo apt purge 'nvidia-driver-*' 'nvidia-dkms-*'` 后重装 |
| GPU 数量不足 | `nvidia-smi -L`、`lspci \| grep -i nvidia`、`dmesg \| tail`；检查 PCIe/掉卡/供电 |
| 功率上限未生效 | `sudo /usr/local/bin/set-gpu-power-limit.sh` 看逐卡报错；型号不支持降额时把 `POWER_LIMIT_RATIO=100` |
| EasyTier 起不来 | `systemctl status easytier@default`、`journalctl -u easytier@default -n 50`；确认 `network_secret` 与对端一致、peer 端口与本机 listeners 对应（wg → 11011） |
| mihomo 面板打不开 | `systemctl status mihomo`；确认 `external-controller` 绑定与端口，注意 9090 不要暴露公网 |
| 上机前语法自检 | `for f in *.sh */*.sh; do bash -n "$f" || echo "语法错误: $f"; done` |

---

## 9. 上机前自检（本机无法进 Linux 环境时）

```bash
cd /path/to/init_server_tool
for f in *.sh */*.sh; do bash -n "$f" || echo "语法错误: $f"; done
bash -n config.env 2>/dev/null || true   # config.env 是纯变量文件，不必检查
sudo bash init.sh verify                 # 初始化完成后跑
```
