# OrzMCProxy

OrzMC 跨网中转方案（FRP）——解决**电信家宽服务器**下**联通/移动玩家延迟高、被主动拒连**的问题。

## 问题背景

三大运营商骨干网互相独立，跨网流量必须绕行国家级互联互通节点（带宽稀缺、晚高峰拥塞）：

| 场景 | 典型 RTT | 丢包率 |
|:--|:--|:--|
| 同网（电信→电信） | 10–30ms | ≈0 |
| 跨网（联通→电信） | 60–200ms+ | 1–10% |
| 跨网（移动→电信） | 100–300ms+ | 5–30% |

详见 `docs/architecture.md`。

## 架构

```
联通/移动玩家 ──┐
电信玩家   ──┼──► 中转机 frps (三线BGP, 公网IP) ──frp加密隧道──► 家里 frpc (主动出站)
                │   TCP 7000(控制) / 25565 / 25566 + UDP 19132     无需路由器端口映射
                └────────────────────────────────────────────┘
```

- **中转机**：云主机（腾讯/阿里轻量或按量 CVM），跑 `frps`，公网 IP 对玩家开放
- **家里**：MCSM 宿主机跑 `frpc`，**主动出站**连中转机 → 家宽无公网 IP 也能用，路由器零改动
- 玩家只连中转 IP，家宽真实 IP 被隐藏

## 支持矩阵

| 部署端 | macOS | Linux | Windows 11 |
|:--|:--|:--|:--|
| x86_64 | ✅ (launchd) | ✅ (systemd) | ✅ (计划任务) |
| arm64 | ✅ (launchd) | ✅ (systemd) | ✅ (计划任务) |

frp 版本固定 **v0.70.1**（TOML 配置）。安装脚本自动检测 OS/架构并下载对应二进制。

## 快速开始

```bash
# 1. 中转机（Linux）：装 frps（生成 frps-default.toml + systemd frps@default）
sudo bash scripts/install-frp.sh frps

# 2. 家里（Linux/macOS）：装 frpc（多中转机时加实例名参数）
sudo bash scripts/install-frp.sh frpc
sudo bash scripts/install-frp.sh frpc relay-b    # 第二台中转机
```

Windows：管理员 PowerShell 执行 `scripts/install-frp.ps1 -Role frpc`（多实例加 `-Name relay-b`）

详细步骤见 `docs/setup-guide.md`。

## 两种档位（核心决策）

| 维度 | 临时档（一天活动） | 正式档（长期） |
|:--|:--|:--|
| 玩家入口 | 中转 + 家宽直连 **双通道** | **只有中转**（直连被拒） |
| 真实 IP 透传 | ❌ 无（全部同源 IP） | ✅ 有（frpc PROXY v2 头） |
| connection-throttle | 必须设 0（防误伤） | 保持默认即可 |
| 部署复杂度 | ⭐ 低（改 frpc + 1 配置） | ⭐⭐⭐ 高（三处联动 + 重启） |
| 监控 | `relay-monitor.sh --mode temp --direct-host 家宽IP` | `relay-monitor.sh --mode formal` |
| 适用 | 一次性活动，快速零风险 | 日常长期运营，要真实 IP |

> 完整对比（含切换成本/风险/基岩双通道）见 `docs/architecture.md`「两种档位」。

## 隧道监控（外部视角，cron 看门狗）

```bash
# 正式档（proxy-protocol 开）：Java 只能查 TCP+后端存活，MC ping 被拒属预期
scripts/relay-monitor.sh --mode formal

# 临时档（无 proxy-protocol）：中转+直连双通道完整 MC ping / RakNet 探测
scripts/relay-monitor.sh --mode temp --direct-host 家宽IP
```

- **输出契约**：状态翻转（健康↔故障）才输出告警/恢复消息；状态稳定静默 → 适合 cron no_agent 看门狗（空输出不投递，不刷屏）
- 首次运行输出基线；退出码恒 0，健康性通过 stdout 表达
- 检查项：frps 控制口 7000 + Java 入口（按档位）+ 基岩 RakNet 19132（真实端到端，Geyser→Paper）

## 目录结构

```
├── docs/
│   ├── architecture.md      # 架构/端口/延迟链路/成本 + 两种档位完整对比表
│   ├── setup-guide.md       # 完整部署手册（含灰度迁移/回滚 + 隧道监控接线）
│   ├── manual-apply-windows.md  # MCSM 面板不可用时 Windows 手动改法（2 文件+重启）
│   └── troubleshooting.md   # 排障手册（含验证工具速查）
├── configs/                 # 配置模板（复制为 frps.toml / frpc.toml 修改）
├── scripts/                 # 安装/验证/健康检查/监控/卸载（sh + ps1）
│   ├── relay-monitor.sh     # 🆕 外部隧道监控（formal/temp 双档，状态转换告警，适配 cron 看门狗）
│   ├── verify-tunnel.sh     # 隧道验证（TCP + MC Server List Ping）
│   ├── bedrock_ping.py      # 基岩 RakNet 探测（真实端到端）
│   ├── health-check.sh      # 本机进程/守护状态检查
│   └── install-frp.* / uninstall-frp.*
├── systemd/                 # Linux 服务单元
├── launchd/                 # macOS 服务 plist
├── windows/                 # Windows 服务方案说明
└── .github/workflows/       # CI：frps/frpc 配置语法校验
```

## 开发流程

- 功能/修复一律 **feature 分支**（`feat/xxx`、`fix/xxx`），验收通过后合 PR 发版，期间 main 冻结
- CI 绿 + 本地验证通过后才允许合并
