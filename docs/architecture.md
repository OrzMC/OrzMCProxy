# 架构设计

## 1. 问题

服务器部署在电信家宽（单一运营商网络）时，联通/移动玩家：

1. **延迟高**：跨网流量绕行国家级互联互通节点（北京/上海/广州/郑州），带宽稀缺 + 晚高峰拥塞
2. **被主动拒绝**：四个机制叠加
   - Paper `connection-throttle`（默认 4000ms 同 IP 限频）+ CGNAT 共享出口 IP → `Connection throttled`
   - TCP 握手 SYN 丢包 → 客户端报连接超时
   - `server.properties` `connection-timeout`（默认 30s）登录超时被踢
   - OS SYN backlog 被慢握手占满 → 新 SYN 被内核丢弃

## 2. 方案：FRP 中转

```
玩家(三网) ──► 中转机 frps (三线 BGP 公网 IP) ── frp 隧道(加密+token) ──► 家里 frpc
                 ├─ TCP 7000   控制通道（frpc 主动出站连入）
                 ├─ TCP 25565  Java 主服
                 └─ TCP 25566  Java 第二服（分流，100 人双服场景）
```

### 为什么选 FRP

| 方案 | 结论 |
|:--|:--|
| FRP | ✅ 免费、token 认证、多端口、心跳自愈、跨平台 |
| iptables DNAT | ❌ 无认证、家宽直连暴露、难管理 |
| Tailscale Funnel | ❌ 玩家端需装客户端，仅 HTTPS |
| 加速器托管 | ❌ 按玩家收费、IP 不自主 |

### 关键特性

- **frpc 主动出站**：家里路由器零端口映射，家宽无公网 IPv4 也能用
- **IP 隐藏**：玩家只见中转 IP，家宽真实 IP 不暴露（附带 DDoS 转移效果）
- **多服复用**：一台中转机可转发多个端口（25565/25566/…），100 人双服分流成本不变
- **真实 IP 透传（PROXY protocol）**：frpc 每个代理 `[proxies.transport].proxyProtocolVersion = "v2"`（frp ≥0.60 位置）+ Paper `paper-global.yml` `proxies.proxy-protocol: true`。服务器看到玩家真实 IP（2026-08-13 本地实测验证），同源问题彻底解决；代价是**直连（无 PROXY 头）被服务器拒绝**，Geyser 需开 `use-haproxy-protocol: true` 同步适配

### 两种档位（按场景选）

| 维度 | 临时档（一天活动） | 正式档（长期） |
|:--|:--|:--|
| **配置** | 不开 proxy-protocol；frpc 无头透传；Paper `connection-throttle: 0` | 开 proxy-protocol 三处联动：frpc `[proxies.transport] proxyProtocolVersion = "v2"` + Paper `paper-global.yml proxies.proxy-protocol: true` + Geyser java 段 `use-haproxy-protocol: true`（bedrock 段不动） |
| **玩家入口** | 中转 IP + 家宽直连 IP **双通道**并行 | **只有中转 IP**（直连被服务器静默拒绝） |
| **真实 IP 透传** | ❌ 无（服务器看到全部玩家 = 中转机 IP） | ✅ 有（frpc 自动加 PROXY v2 头，服务器显示玩家真实公网 IP） |
| **同源 IP 问题** | ⚠️ 有：connection-throttle 误伤 → 必须设 0（有被刷风险） | ✅ 无：真实 IP 各自计数，throttle 可保持默认 |
| **基岩玩家** | 双通道（直连家里 19132 / 中转 19132 均可） | 双通道（Geyser haproxy 只影响 Geyser→Java 本地 TCP，与玩家怎么连无关） |
| **部署复杂度** | ⭐ 低：只改 frpc + 1 个 throttle | ⭐⭐⭐ 高：三处联动 + 必须重启服务器 + Geyser 配置易改错（java/bedrock 同名项） |
| **切换成本** | 5 分钟（改 frpc） | 30-60 分钟（3 文件 + 重启 + 验证矩阵）；回滚同样要重启 |
| **风险** | 低（不碰服务器配置）；但无真实 IP | 中（顺序错 = 全服不可达；直连地址永久失效） |
| **监控方式** | `relay-monitor.sh --mode temp --direct-host 家宽IP`：中转+直连双通道完整 MC ping + RakNet | `relay-monitor.sh --mode formal`：Java 只做 TCP+后端存活检测（MC ping 被服务器拒属预期），RakNet 两档通用 |
| **适用** | 一次性活动（一天），快速零风险，接受同源 IP | 长期运营（日常服），要真实 IP 防误伤 |

**选型建议**：默认正式档（防误伤 + 监控语义清晰）；只有「明天就开活动、来不及灰度」时才临时档救急——但注意临时档**没有真实 IP**，按 IP 的功能（GeoIP 拦截、黑名单、throttle 计数）全部失效或需放宽。

## 3. 延迟链路

| 链路 | 典型 RTT |
|:--|:--|
| 玩家直连家宽（跨网） | 100–300ms（问题根源） |
| 玩家 → 中转机（三线 BGP） | 10–40ms |
| 中转机 → 家里（电信网内） | 10–20ms |
| **玩家经中转（总计）** | **30–60ms** ✅ |

中转机选玩家聚集地同城/同省，延迟最优。

## 4. 端口规划

| 端口 | 用途 | 中转 |
|:--|:--|:--|
| 25565 | Java 主服 | ✅ TCP |
| 25566 | Java 第二服（分流） | ✅ TCP（预留，当前未启用） |
| 19132 | 基岩 Geyser | ✅ UDP（2026-08-14 真机实测可行：10/10 RakNet ping + 真机进服） |
| 25575 | RCON | ❌ 绝不暴露公网 |
| 23333 | MCSM 面板 | ❌ 绝不暴露公网 |

中转机安全组只放行：`TCP 7000`（仅限家里 IP）+ `TCP 25565/25566`（全部）+ `UDP 19132`（全部，基岩入口）。

## 5. 成本（按天活动场景）

| 项 | 说明 | 费用 |
|:--|:--|:--|
| 中转机实例 | 按量 CVM 2C2G，~0.15 元/h | ~4 元/天 |
| 带宽 | 按流量计费 ~0.8 元/GB（峰值可设 100Mbps 不另收费） | 100 人×8h ≈ 29 元/天 |
| **合计** | | **~33 元/天** |

对比「服务器直接上云」：云主机需要 4C8G×2（双服）≈ 53 元/天，且世界/插件/玩家数据要上传+迁回，工作量大数倍。一天活动场景 FRP 中转明显更优。

## 6. 已知边界

- 家里上行 50Mbps 是容量上限：100 人均值 ~10Mbps、峰值 20–30Mbps，**贴近上限**——活动前必须压测验证（stress-stay.js 100 bot + 观察上行利用率）
- 家里断电/断网 → 全服不可达（单点依赖，活动日需确认供电/网络）
- **临时档**下中转后所有玩家同源 IP（中转机 IP）→ Paper `connection-throttle` 必须放宽（设 0）；**正式档**有真实 IP 透传，throttle 保持默认即可（见「两种档位」表）
