# Windows 宿主机手动改法（MCSM 面板不可用场景）

> 适用：MCSM 面板不可用、需要手动在生产服（Windows 11 宿主机）应用正式档配置。
> 全程只需改 **2 个文件** + 重启 1 次。改完验证见文末。

## ⚠️ 执行顺序铁律（先隧道后改服）

**必须先保证 frpc 隧道已通，再改服务器配置重启**——因为开启 proxy-protocol 后，**直连（无代理头）会被服务器拒绝**，顺序错了玩家会全连不上：

1. ① 中转机 frps 已部署（上海按量 CVM）
2. ② Windows 宿主机 frpc 已安装且隧道 `start proxy success` —— 安装步骤见 `windows/README.md`（管理员 PowerShell 跑 `scripts/install-frp.ps1 -Role frpc`，改 `C:\Program Files\OrzMCProxy\frpc.toml` 的 serverAddr/token 后 `Restart-ScheduledTask -TaskName "OrzMCProxy-frpc"`）
3. ③ **才执行本文件的 2 处配置修改 + 重启**

## 第 1 步：找到 MCSM 实例目录

- 实例工作目录 = 服务器的 `paper-*.jar` 所在目录（老板装 MCSM 时配置的实例路径）
- 确认方法：看 MCSM 安装目录 `data\InstanceConfig\` 下实例 JSON 里的 `cwd` 字段，或直接找 `paper-26.2-111.jar` / `start.bat` 所在文件夹
- 下文用 `<实例目录>` 表示

## 第 2 步：改 Paper 配置（真实 IP 透传）

**文件**：`<实例目录>\config\paper-global.yml`

用文本编辑器（推荐 **Notepad++** 或 VS Code，勿用记事本——编码问题）打开，找到 `proxies:` 段（约 111 行附近）：

```yaml
proxies:
  bungee-cord:
    online-mode: true
  proxy-protocol: false     ← 改这一行
  velocity:
    enabled: false
    ...
```

**改法**：`proxy-protocol: false` → `proxy-protocol: true`

⚠️ 只改 `proxy-protocol` 这一项；`bungee-cord` / `velocity` 保持不动（正式档走 PROXY protocol，不开 bungee）。

**保存**（UTF-8 无 BOM，原格式不动）。

## 第 3 步：改 Geyser 配置（基岩入口保命）

**文件**：`<实例目录>\plugins\Geyser-Spigot\config.yml`

找到 `java:` 段里（约 186 行附近）带注释的这项：

```yaml
    # Whether to enable HAPROXY protocol when connecting to the Java server.
    ...
    use-haproxy-protocol: false     ← 改这一行
```

**改法**：`use-haproxy-protocol: false` → `use-haproxy-protocol: true`

⚠️ 只改 **java 段的** `use-haproxy-protocol`（第 186-191 行那个）；**不要动** bedrock 段的（215-224 行那个，那是给 UDP 前置用的）。

**保存**。

## 第 4 步：重启服务器

MCSM 面板不可用，直接操作进程：

```powershell
# 1. 找到服务器 java 进程 PID（只杀 MC 服务器，别误杀其他 java）
tasklist | findstr /i java

# 2. 按 PID 结束（替换 <PID> 为服务器进程号）
taskkill /PID <PID> /F

# 3. 用原来的启动方式重新启动（start.bat 或 MCSM 的启动命令）
#    建议用后台方式，别关窗口：
Start-Process -FilePath "cmd" -ArgumentList "/c", "cd /d <实例目录> && start.bat" -WindowStyle Hidden
```

> 如果宿主机有多个 java 进程（如其他服务），用 PID 精确结束，勿用 `taskkill /IM java.exe`。

## 第 5 步：验证

1. **隧道连通**（在任意机器，含 Mac）：`bash scripts/verify-tunnel.sh <中转机IP> 25565` → 返回服务器 MOTD
2. **真实 IP**：玩家进服后服务端日志显示玩家公网 IP（不是中转机 IP）
3. **直连被拒 = 正常**：直接连家里 IP:25565 会被静默拒（proxy-protocol 特性），**这不是故障**
4. **基岩玩家**：直连家里 IP:19132（UDP）正常进服（Geyser haproxy 已开，转发带 PROXY 头）

## 回滚（紧急）

把两处配置改回 `false` → 重启 → 玩家恢复直连家里 IP:25565。

## 停机窗口

全程停机 = 改 2 个文件 + 1 次重启 ≈ **3–5 分钟**。选无玩家时段（如活动前夜/清晨）执行。
