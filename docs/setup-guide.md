# 部署手册

完整步骤：**准备 → 中转机 frps → 家里 frpc → 验证 → 灰度 → 全量切换 → 回滚**。

## 0. 准备

1. 中转机：腾讯/阿里**按量计费 CVM**（按天场景）或轻量（长期），2C2G 起步，地域选玩家集中地
2. 带宽计费选**按流量**（峰值设 100Mbps 不另收费，只按实际流量 ~0.8 元/GB）
3. 安全组放行：
   - `TCP 7000` ← 仅家里出口 IP（中转控制通道）
   - `TCP 25565`、`TCP 25566` ← 全部（玩家入口）
   - `UDP 19132` ← 全部（基岩 Geyser 入口，2026-08-14 实测 UDP 中转可行）
4. 生成强随机 token：

```bash
openssl rand -hex 32   # 或 python3 -c "import secrets;print(secrets.token_hex(32))"
```

## 1. 中转机部署 frps（Linux）

```bash
# 一键安装（自动检测 OS/arch，下载 frp v0.70.1，生成 frps-default.toml + 注册 systemd frps@default）
sudo bash scripts/install-frp.sh frps

# 配置：编辑模板（安装脚本已自动生成）
sudo vi /etc/orzmcproxy/frps-default.toml    # 改 auth.token = "<强随机token>"

sudo systemctl restart frps@default
sudo systemctl status frps@default
```

验证：`sudo ss -lntp | grep -E '7000|25565'` 应看到监听。

## 2. 家里部署 frpc（Linux / macOS / Windows）

### Linux / macOS

```bash
sudo bash scripts/install-frp.sh frpc          # 生成 frpc-default.toml + 注册 frpc@default / LaunchDaemon

sudo vi /etc/orzmcproxy/frpc-default.toml      # macOS: /usr/local/etc/orzmcproxy/frpc-default.toml
# 改 serverAddr = "<中转机IP>" + auth.token
sudo systemctl restart frpc@default            # macOS: launchctl unload/load
```

**多实例（多中转机 → 单服务）**：每台中转机一个实例

```bash
sudo bash scripts/install-frp.sh frpc relay-b  # 第二台中转机 → frpc-relay-b.toml + frpc@relay-b.service
sudo vi /etc/orzmcproxy/frpc-relay-b.toml      # serverAddr 指向第二台中转机
sudo systemctl restart frpc@relay-b
```

### Windows 11（管理员 PowerShell）

```powershell
# 自动下载、解压到 C:\Program Files\OrzMCProxy、注册开机自启计划任务（含 5 分钟自愈）
.\scripts\install-frp.ps1 -Role frpc
# 多实例：.\scripts\install-frp.ps1 -Role frpc -Name relay-b
# 编辑 C:\Program Files\OrzMCProxy\frpc-default.toml 后：
Restart-ScheduledTask -TaskName "OrzMCProxy-frpc-default"
```

## 3. 隧道验证（在中转机上或任意机器）

```bash
# TCP 连通性 + Minecraft 协议握手探测
bash scripts/verify-tunnel.sh <中转机IP> 25565
bash scripts/verify-tunnel.sh <中转机IP> 25566
```

预期输出：TCP 握手成功 + 返回服务器 MOTD/版本（Minecraft Server List Ping 协议）。

**真实 IP 透传验证**（开 proxy-protocol 后）：
- 进服后 `list` / 服务器日志看玩家 IP 是否为真实公网 IP（而非中转机 IP）
- 直接连接服务器（不带代理）应被拒——这是**正常现象**（proxy-protocol 模式特性），不是故障

**基岩入口验证**（无需真实基岩客户端）：
```bash
python3 scripts/bedrock_ping.py <家里IP> 19132
# PONG_OK + MOTD = Geyser 存活且 Geyser→Java 连接（haproxy 头）被 Paper 接受
```

## 3b. 隧道监控（生产上线后必接）

```bash
# 临时档：中转+直连双通道完整检测（玩家两条路都通才算健康）
scripts/relay-monitor.sh --mode temp --direct-host <家宽IP>

# 正式档：Java 只做 TCP+后端存活检测（proxy-protocol 下 MC ping 被拒属预期），RakNet 通用
scripts/relay-monitor.sh --mode formal
```

- 输出契约：状态翻转（健康↔故障）才输出 `🔴 ALERT`/`🟢 RECOVERY`/`🆕 首次基线`，稳定静默 → 适配 cron no_agent 看门狗（空输出不投递不刷屏），退出码恒 0
- 检查项：frps 控制口 7000 + Java 入口（按档位）+ 基岩 19132 RakNet（真实端到端 Geyser→Paper）
- cron 接线示例（每 5 分钟）：`*/5 * * * * /path/to/relay-monitor.sh --mode formal`，stdout 非空即投递

## 4. 灰度测试

1. 拉 2–3 个联通/移动玩家连中转 IP，对比直连延迟（ping/mtr 中转 IP）
2. 预期：跨网玩家延迟从 100–300ms 降到 30–60ms
3. 观察中转机出站流量（`iftop`/云监控）与家里上行占用

## 5. 全量切换

1. 群公告连接地址改为 `<中转机IP>:25565`
2. **正式档**：直连地址从此失效（proxy-protocol 拒绝无头连接）——玩家只有中转一条路，切换即完成
3. **临时档**：保留家宽直连 IP 作备用入口（双入口并行一周）
4. 观察一周：连接数、`Connection throttled` / `Timed out` 踢人日志、带宽曲线

## 6. 回滚

```bash
# 家里：停 frpc（玩家恢复直连家宽 IP）
sudo systemctl stop frpc          # macOS: launchctl unload ...
```

## ⚠️ 关键坑

1. **真实 IP 透传（正式方案必做）**：
   - frpc 每个代理的 `[proxies.transport]` 配 `proxyProtocolVersion = "v2"`（⚠️ **frp ≥0.60 位置在 transport 子表，不在 proxies 顶层**——顶层会报 `unknown field`）
   - Paper 端 `config/paper-global.yml` 开 `proxies.proxy-protocol: true`（⚠️ **不是 spigot.yml 的 bungeecord**——bungeecord 模式解析的是 BungeeCord 转发数据，不认 PROXY 头）
   - 开启后服务器日志显示玩家真实 IP（2026-08-13 本地实测：PROXY 头伪造 IP 被服务器如实显示）
   - ⚠️ 开 proxy-protocol 后**直连（无 PROXY 头）会被服务器静默拒绝/超时**（官方行为）→ 基岩 Geyser 必须同步开 `use-haproxy-protocol: true`（Geyser config.yml java 段），否则基岩入口挂
2. **Paper `connection-throttle`**：开 proxy-protocol 后服务器看到真实 IP，无需放宽；**不开 proxy-protocol 的临时方案**（一天活动）才需要设 0（同源 IP 误伤）
3. **中转机安全组别开 RCON/MCSM 面板端口**（25575/23333 绝不暴露公网）
4. **frps/frpc 版本必须一致**（都用 v0.70.1），避免 wire protocol 不兼容
5. **家里断电/断网 = 全服不可达**：活动日确认供电（UPS）与网络
6. **带宽顶满先查家里上行**：100 人峰值 20–30Mbps vs 家宽上行 50Mbps——活动前用压测验证（stress-stay.js 100 bot + 观察上行利用率）
7. **基岩 UDP（19132）中转已实测可行（2026-08-14）**：frpc 加 `type = "udp"` proxy + frps `allowPorts` 加 19132 + 云防火墙放行 UDP 19132。⚠️ Geyser 配置只改 **java 段** `use-haproxy-protocol: true`（正式档时），**bedrock 段必须保持 false**（frp UDP 代理不支持 PROXY protocol，两个同名配置项极易改错，patch 勿 replace_all）。UDP 中转**无真实 IP 透传**（Geyser 看到 127.0.0.1），基岩玩家 IP 级管控失效（XUID 管控不受影响）
8. **verify-tunnel.sh 修复后的正确行为（2026-08-14）**：正式档下**经中转 MC ping 成功**（frpc 自动加 PROXY v2 头，服务器正常响应）——不是「ping 失败」；只有**直连无头**才 timed out（proxy-protocol 拦截，正常现象）。旧版脚本 Status Request 包 ID 写错（0x01→应为 0x00）曾导致误判，已修复

## 活动日检查清单

- [ ] 中转机实例已创建、安全组正确（TCP 7000/25565/25566 + UDP 19132）
- [ ] frps/frpc 服务 running（`systemctl status`）
- [ ] `verify-tunnel.sh` 两个端口均通过（正式档经中转 ping；基岩用 `bedrock_ping.py`）
- [ ] `relay-monitor.sh` 已接 cron 且当前状态 OK
- [ ] 档位确认：正式档 → Paper proxy-protocol + Geyser haproxy 已开；临时档 → `connection-throttle` 已放宽
- [ ] 压测：家里上行未顶满
- [ ] 群公告连接地址已更新
