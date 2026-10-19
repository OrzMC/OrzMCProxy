# NetherNet 诊断脚本 使用说明

> 脚本：`scripts/nethernet_check.py` ｜ 版本：v1.0（2026-10-19）
> 配套：`scripts/bedrock_host_check.sh`（RakNet 时代五项体检）、`scripts/bedrock_ping.py`（RakNet 单点探测）

## 这个脚本解决什么问题

Mojang 已从基岩版 **26.40** 起推送 **NetherNet**（WebRTC + HTTP 信令），并**在 2026-10-27 停用 RakNet**。
两代传输层对**网络端口的要求不一样**，只测 RakNet 会漏掉致命项：

| 传输层 | 游戏流量 | 信令 | 公网需转发 |
|:--|:--|:--|:--|
| RakNet（旧） | UDP | — | 只 UDP |
| **NetherNet（新）** | UDP（WebRTC） | **TCP（HTTP/HTTPS）** | **UDP + TCP** |

`nethernet_check.py` 一次同时检查两条通道，并直接给出「NetherNet 是否可用 / 缺哪一步」的结论。

## 用法

```bash
# 本机（默认 127.0.0.1:19132）
python3 nethernet_check.py

# 只给端口（本机）
python3 nethernet_check.py 19133

# 远程
python3 nethernet_check.py dev.jokerhub.cn
python3 nethernet_check.py dev.jokerhub.cn 19133

# 帮助
python3 nethernet_check.py -h
```

退出码：**0** = 信令可用；**1** = 信令不可用（可直接用于监控/定时任务）。

## 输出解读

```
[0] 域名解析        dev.jokerhub.cn → <IP>
[1] RakNet(UDP)      ✅ 应达（17ms）+ MOTD        ← 旧通道基线
[2] NetherNet 信令   ✅/🟡/❌ TCP <port> → <state>
```

| `[2]` 状态 | 含义 | 处置 |
|:--|:--|:--|
| `HTTP` | TCP 有 HTTP 应答，信令服务在线 | 可用 ✅ |
| `OPEN_RAW` | 端口有私有协议应答（非 HTTP） | 需人工确认是否为信令 |
| `OPEN_NO_HTTP` | TCP 能连但立即关闭 | ⚠️ **本机代理常造成假阳性**，见下方「坑」 |
| `REFUSED` | 已转发但无人监听 | 打开 Geyser 的 `transport` |
| `TIMEOUT` | 被防火墙/NAT 丢弃 | 端口未转发（docker 映射 / 路由器）|

## 两个必须知道的坑

### 1. 本机走代理（Clash TUN）测 TCP 会假阳性

本机 DNS 常被 Clash TUN 改成 fake-IP（`198.18.x.x`），TCP 握手被本地栈「接住」后立刻关闭，
脚本会显示 `OPEN_NO_HTTP`——**看起来可连，其实没到服务器**。正确做法：

```bash
# ① DoH 取真实公网 IP
curl -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=dev.jokerhub.cn&type=A'

# ② 用外部节点验证 TCP（返回 request_id 后查结果）
curl -H 'Accept: application/json' 'https://check-host.net/check-tcp?host=<IP>:19132&max_nodes=3'
curl -H 'Accept: application/json' 'https://check-host.net/check-result/<request_id>'
#    外部节点 "Connection timed out" = 未转发；"Connection refused" = 已转发但无监听
```

脚本对**端口状态**的判定逻辑是准的，但**本机只要开着 Clash TUN，任何 TCP 探测（哪怕直连真实 IP）都可能被本地栈接管** →
TCP 结论一律以**外部节点**为准；脚本更适合在**服务器本机/外部节点**上跑（无代理环境）。

### 2. `check-host.net` 的 UDP 检测没有意义

UDP 检测发的是普通 UDP 包，Geyser 只回应 **RakNet 专有包**，所以 UDP 永远 timeout。
UDP 是否通请用 `bedrock_ping.py`（发 RakNet Unconnected Ping，收到 `0x1C` Pong 即为通）。

## 切换到 NetherNet 的动作清单（脚本报 `[2]` 不通时照做）

1. **Geyser 配置**（`plugins/Geyser-Spigot/config.yml`）：
   ```yaml
   bedrock:
     port: 19132
     transport: nethernet        # 或 both（过渡期，需同时设 webrtc-port 为另一 UDP）
   ```
2. **docker 端口映射**：给实例补 `宿主:容器/tcp`（如 19132/tcp）
3. **路由器 / 防火墙**：放通 **TCP 同端口**（`both` 模式再加一个 UDP `webrtc-port`）
4. 重启后复跑本脚本，应看到 `[2] ... HTTP 2xx/4xx`

详细原理、配置字段、方案对比与官方错误对照表见 OrzMC 技能
`references/nethernet.md`。

## 已知限制

- 只做「端口层 + HTTP 信令层」探测，**不做真实 Bedrock 登录**（需要 Bedrock 协议客户端）
- 不解析 WebRTC 连接建立结果——真正的端到端验证仍需 **Bedrock 26.40+ 客户端实连**
- IPv4 only
