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
                │   TCP 7000(控制) / 25565 / 25566                无需路由器端口映射
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
# 1. 中转机（Linux）：装 frps
sudo bash scripts/install-frp.sh frps

# 2. 家里（Linux/macOS）：装 frpc
sudo bash scripts/install-frp.sh frpc
```

Windows：管理员 PowerShell 执行 `scripts/install-frp.ps1 -Role frpc`

详细步骤见 `docs/setup-guide.md`。

## 目录结构

```
├── docs/
│   ├── architecture.md      # 架构/端口/延迟链路/成本
│   ├── setup-guide.md       # 完整部署手册（含灰度迁移/回滚）
│   └── troubleshooting.md   # 排障手册
├── configs/                 # 配置模板（复制为 frps.toml / frpc.toml 修改）
├── scripts/                 # 安装/验证/健康检查/卸载（sh + ps1）
├── systemd/                 # Linux 服务单元
├── launchd/                 # macOS 服务 plist
├── windows/                 # Windows 服务方案说明
└── .github/workflows/       # CI：frps/frpc 配置语法校验
```

## 开发流程

- 功能/修复一律 **feature 分支**（`feat/xxx`、`fix/xxx`），验收通过后合 PR 发版，期间 main 冻结
- CI 绿 + 本地验证通过后才允许合并
