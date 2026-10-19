# NetherNet 诊断脚本 使用说明

> 脚本：`scripts/nethernet_check.py` ｜ 版本：**v1.1.0**（2026-10-19）
> 配套：`scripts/bedrock_host_check.sh` / `.ps1`（RakNet 时代五项体检）、`scripts/bedrock_ping.py`（RakNet 单点探测）

## 这个脚本解决什么问题

Mojang 已从基岩版 **26.40** 起推送 **NetherNet**（WebRTC + HTTP 信令），并**在 2026-10-27 停用 RakNet**。
两代传输层对**网络端口的要求不一样**，只测 RakNet 会漏掉致命项：

| 传输层 | 游戏流量 | 信令 | 公网需转发 |
|:--|:--|:--|:--|
| RakNet（旧） | UDP | — | 只 UDP |
| **NetherNet（新）** | UDP（WebRTC） | **TCP（HTTP/HTTPS）** | **UDP + TCP** |

`nethernet_check.py` 一次同时检查两条通道，并给出「NetherNet 是否可用 / 缺哪一步」的结论。

> 说明：脚本显示的 **MOTD 来自 RakNet Pong**（UDP 基线），信令侧只做「端口 + HTTP 应答」探测，不解析信令内容。

## 用法

```bash
# 本机（默认 127.0.0.1:19132）
python3 nethernet_check.py

# 只给端口（本机）
python3 nethernet_check.py 19133

# 远程
python3 nethernet_check.py dev.jokerhub.cn
python3 nethernet_check.py dev.jokerhub.cn 19133

# 信令端口与基岩端口不同 / 信令走 HTTPS
python3 nethernet_check.py dev.jokerhub.cn 19132 --signal-port 8080 --scheme https

# 机器可读（监控采集）
python3 nethernet_check.py dev.jokerhub.cn --json

# Windows / cron 友好（纯 ASCII，无 emoji）
python3 nethernet_check.py dev.jokerhub.cn --no-emoji

# 自检（Pong 解析回归，改脚本后先跑这个）
python3 nethernet_check.py --self-test

python3 nethernet_check.py -h    # 完整帮助
```

常用参数：`--signal-port`（信令 TCP 端口，默认同基岩端口）、`--scheme http|https`（默认 http）、
`--timeout`（单步超时，默认 8s）、`--json`、`--no-emoji`、`--version`。

## 退出码（可直接接监控）

| 退出码 | 含义 | 对应 `[2]` 状态 |
|:--|:--|:--|
| **0** | 信令可用（TCP 返回 HTTP **2xx/4xx**） | `HTTP_OK` |
| **1** | 不可达（超时 / 拒绝 / 连接错误 / DNS 失败） | `TIMEOUT` `REFUSED` `ERROR` |
| **2** | 用法或参数错误 | —（argparse 报错） |
| **3** | 降级待确认（**不算可用**） | `OPEN_RAW` `OPEN_NO_HTTP` `HTTP_5XX` `HTTP_3XX` |

> 只有 **0** 代表「可以确认信令在线」；**3** 必须人工看一眼再判断，不要按可用处理。

## 输出解读

```
[0] 域名解析        dev.jokerhub.cn -> <IP>
[1] RakNet(UDP)     ✅ 应答（17ms）+ MOTD        ← 旧通道基线
[2] NetherNet 信令  ✅/🟡/❌ TCP <port> -> <state>
```

| `[2]` 状态 | 含义 | 处置 |
|:--|:--|:--|
| `HTTP_OK` | 有 HTTP 2xx/4xx 应答，信令服务在线 | 可用 |
| `HTTP_3XX` | 重定向（目标未验证） | 人工确认 |
| `HTTP_5XX` | 服务端 5xx（反代/后端异常） | 查 Geyser 日志 |
| `OPEN_RAW` | 端口有非 HTTP 应答（可能是私有协议） | 人工确认，**不要判可用** |
| `OPEN_NO_HTTP` | TCP 能连但无 HTTP 应答 | ⚠️ 本机代理常见假象，见下节 |
| `REFUSED` | 已转发但无人监听 | 打开 Geyser 的 `transport` |
| `TIMEOUT` | 被防火墙/NAT 丢弃 | 端口未转发（docker 映射 / 路由器）|
| `ERROR` | 其他连接错误 | 看提示信息 |

## 两个必须知道的坑

### 1. 本机走代理（Clash TUN）测 TCP 会假阳性

本机 DNS 常被 Clash TUN 改成 fake-IP（`198.18.x.x`），TCP 握手被本地栈「接住」后立刻关闭，
脚本会显示 `OPEN_NO_HTTP`（退出码 3）——**看起来可连，其实没到服务器**，直连真实 IP 也一样会被接管。
正确做法：

```bash
# ① DoH 取真实公网 IP
curl -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=dev.jokerhub.cn&type=A'

# ② 用外部节点验证 TCP（返回 request_id 后查结果）
curl -H 'Accept: application/json' 'https://check-host.net/check-tcp?host=<IP>:19132&max_nodes=3'
curl -H 'Accept: application/json' 'https://check-host.net/check-result/<request_id>'
#    外部节点 "Connection timed out" = 未转发；"Connection refused" = 已转发但无监听
```

> ⚠️ 隐私提示：`check-host.net` 是第三方服务，提交 `IP:端口` 等于向它公开你的服务器地址。
> 在意的话改用自有外部节点（如中转机）跑本脚本。

TCP 结论一律以**外部节点**为准；脚本最适合在**服务器本机或外部探测机**（无代理环境）上跑。

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
4. 重启后复跑本脚本，应看到 `[2] ... HTTP_OK`（退出码 0）

详细原理、配置字段、方案对比与官方错误对照表见 OrzMC 运维技能的 `references/nethernet.md`。

## 已知限制

- 只做「端口层 + HTTP 信令层」探测，**不做真实 Bedrock 登录**（需要 Bedrock 协议客户端）
- 不解析 WebRTC 连接建立结果——真正的端到端验证仍需 **Bedrock 26.40+ 客户端实连**
- **IPv4 only**（`--host` 传域名时只解析 A 记录）
- HTTPS 探测**不校验证书**（诊断用途，允许自签）
