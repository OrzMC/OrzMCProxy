# 排障手册

按现象分类，从上到下排查。

## 1. 玩家报「连接超时 / Connection throttled」

**Connection throttled（最常见）**

- 原因：Paper `connection-throttle` 限制同 IP 连接频率；中转后所有玩家同源 IP
- 修复：放宽/关闭（`server.properties` 或 Paper 配置），见 setup-guide 关键坑 1
- 确认：服务端日志 grep `Connection throttled`

**连接超时 / 被拒绝**

1. 中转机安全组是否放行 `TCP 25565/25566`？
2. frps 是否监听：`ss -lntp | grep 25565`（中转机上）
3. frpc 隧道是否在线：`bash scripts/health-check.sh`（家里）
4. frps 日志有无报错：`journalctl -u frps -n 50`（中转机）
5. 家里是否断网/断电

## 2. 玩家延迟还是高

1. 先确认链路分段：
   - 玩家 → 中转机：`ping <中转机IP>`（玩家端）——高则中转地域/线路问题
   - 中转机 → 家里：`ping <家里IP>`（中转机上）——高则家里上行/跨网问题
2. 中转机地域是否在玩家聚集地附近（同城最佳）
3. 检查家里上行是否被顶满（100 人峰值 20–30Mbps vs 家宽 50Mbps 上行）：
   - 家里：`nettop -P -L 1`（macOS）或 `iftop`（Linux）看 frpc 出站流量
   - 云监控看中转机带宽曲线

## 3. frpc 频繁掉线 / 隧道断

1. `systemctl status frpc` / `launchctl list | grep frpc` 确认 KeepAlive/Restart
2. 日志：`journalctl -u frpc -n 50`（Linux）、`/usr/local/var/log/orzmcproxy/frpc.log`（macOS）
3. 常见原因：
   - token 不一致（frps/frpc 两端）
   - 家里网络抖动（家宽 NAT 会话超时——frp 有心跳，正常会自动重连）
   - frps/frpc 版本不一致
4. frp 心跳参数（必要时在 frpc.toml 调优）：

```toml
transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30
```

## 4. 中转机被 DDoS / IP 被封

- 云厂商免费 DDoS 防护（腾讯 5Gbps / 阿里 5Gbps）触发后 IP 黑洞一段时间
- 缓解：确认玩家连接地址改用新 IP（中转机销毁重建会换 IP）；家里 IP 不受影响（已隐藏）
- 长期：可考虑高防 IP / CDN 前置（成本高，活动场景一般不需要）

## 5. 基岩版（Geyser）玩家异常

- UDP 经 frp 转发有 NAT 超时，空闲连接可能断开
- 一期方案：基岩玩家**直连家宽 IP**（绕过中转），或在群里告知 Geyser 直连地址
- 二期评估：UDP 隧道调优或单独方案

## 6. 验证工具速查

| 工具 | 用途 |
|:--|:--|
| `scripts/verify-tunnel.sh <IP> <port>` | TCP + Minecraft 协议握手探测 |
| `scripts/health-check.sh` | frpc/frps 进程、隧道、日志状态 |
| `nc -vz <IP> <port>` | 纯 TCP 连通性 |
| 服务端日志 grep | `Connection throttled` / `Timed out` / `Lost connection` |
