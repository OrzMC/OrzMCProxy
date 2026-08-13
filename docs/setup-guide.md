# 部署手册

完整步骤：**准备 → 中转机 frps → 家里 frpc → 验证 → 灰度 → 全量切换 → 回滚**。

## 0. 准备

1. 中转机：腾讯/阿里**按量计费 CVM**（按天场景）或轻量（长期），2C2G 起步，地域选玩家集中地
2. 带宽计费选**按流量**（峰值设 100Mbps 不另收费，只按实际流量 ~0.8 元/GB）
3. 安全组放行：
   - `TCP 7000` ← 仅家里出口 IP（中转控制通道）
   - `TCP 25565`、`TCP 25566` ← 全部（玩家入口）
4. 生成强随机 token：

```bash
openssl rand -hex 32   # 或 python3 -c "import secrets;print(secrets.token_hex(32))"
```

## 1. 中转机部署 frps（Linux）

```bash
# 一键安装（自动检测 OS/arch，下载 frp v0.70.1，注册 systemd 服务）
sudo bash scripts/install-frp.sh frps

# 配置：复制模板并填写
sudo mkdir -p /etc/orzmcproxy
sudo cp configs/frps.toml.example /etc/orzmcproxy/frps.toml
sudo vi /etc/orzmcproxy/frps.toml    # 改 auth.token = "<强随机token>"

sudo systemctl enable --now frps
sudo systemctl status frps
```

验证：`sudo ss -lntp | grep -E '7000|25565|25566'` 应看到监听。

## 2. 家里部署 frpc（Linux / macOS / Windows）

### Linux / macOS

```bash
sudo bash scripts/install-frp.sh frpc

sudo mkdir -p /etc/orzmcproxy          # macOS: /usr/local/etc/orzmcproxy
sudo cp configs/frpc.toml.example /etc/orzmcproxy/frpc.toml
sudo vi /etc/orzmcproxy/frpc.toml      # 改 serverAddr + auth.token
```

- Linux：`sudo systemctl enable --now frpc`
- macOS：`launchctl load /Library/LaunchDaemons/com.orzmc.frpc.plist`（安装脚本自动处理）

### Windows 11（管理员 PowerShell）

```powershell
# 自动下载、解压到 C:\Program Files\OrzMCProxy、注册开机自启计划任务（含 5 分钟自愈）
.\scripts\install-frp.ps1 -Role frpc
# 编辑 C:\Program Files\OrzMCProxy\frpc.toml 后：
Restart-ScheduledTask -TaskName "OrzMCProxy-frpc"
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

## 4. 灰度测试

1. 拉 2–3 个联通/移动玩家连中转 IP，对比直连延迟（ping/mtr 中转 IP）
2. 预期：跨网玩家延迟从 100–300ms 降到 30–60ms
3. 观察中转机出站流量（`iftop`/云监控）与家里上行占用

## 5. 全量切换

1. 群公告连接地址改为 `<中转机IP>:25565`
2. 保留家宽直连 IP 作备用入口（双入口并行一周）
3. 观察一周：连接数、`Connection throttled` / `Timed out` 踢人日志、带宽曲线

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
7. **基岩 UDP（19132）经 frp 有 NAT 超时坑**：Geyser 玩家一期先保持直连（此时 Paper 不能开 proxy-protocol，否则直连被拒；或开 proxy-protocol + Geyser 开 haproxy 双向支持），二期再评估

## 活动日检查清单

- [ ] 中转机实例已创建、安全组正确
- [ ] frps/frpc 服务 running（`systemctl status`）
- [ ] `verify-tunnel.sh` 两个端口均通过
- [ ] 档位确认：正式档 → Paper proxy-protocol + Geyser haproxy 已开；临时档 → `connection-throttle` 已放宽
- [ ] 压测：家里上行未顶满
- [ ] 群公告连接地址已更新
