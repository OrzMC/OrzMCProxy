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

1. **Paper `connection-throttle` 必须放宽**：中转后所有玩家同源 IP（中转机 IP），默认 4000ms 会误伤高峰进服 → `server.properties` 或 Paper 配置中**调大或设 0**（0 = 关闭），否则报 `Connection throttled! Please wait 4000 ms`
2. **中转机安全组别开 RCON/MCSM 面板端口**（25575/23333 绝不暴露公网）
3. **frps/frpc 版本必须一致**（都用 v0.70.1），避免 wire protocol 不兼容
4. **家里断电/断网 = 全服不可达**：活动日确认供电（UPS）与网络
5. **带宽顶满先查家里上行**：100 人峰值 20–30Mbps vs 家宽上行 50Mbps——活动前用压测验证（stress-stay.js 100 bot + 观察上行利用率）
6. **基岩 UDP（19132）经 frp 有 NAT 超时坑**：Geyser 玩家一期先保持直连，二期再评估

## 活动日检查清单

- [ ] 中转机实例已创建、安全组正确
- [ ] frps/frpc 服务 running（`systemctl status`）
- [ ] `verify-tunnel.sh` 两个端口均通过
- [ ] Paper `connection-throttle` 已放宽
- [ ] 压测：家里上行未顶满
- [ ] 群公告连接地址已更新
