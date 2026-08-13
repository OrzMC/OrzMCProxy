# Windows 11 部署说明

frpc 通过**计划任务**注册为开机自启服务（含 5 分钟自愈），不依赖第三方工具（NSSM）。

## 安装（管理员 PowerShell）

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\install-frp.ps1 -Role frpc
```

自动完成：

1. 检测架构（x86_64/arm64）并下载对应 frp v0.70.1 zip
2. 解压到 `C:\Program Files\OrzMCProxy\`（二进制共享，只装一份）
3. 复制 `frpc-default.toml` 配置模板
4. 注册计划任务 `OrzMCProxy-frpc-default`：
   - 触发器：开机时
   - 设置：失败后每 5 分钟重启（自愈）、最大运行时间不限
   - 以 SYSTEM 运行（`-RunLevel Highest`）

## 多实例（多中转机 → 单服务）

每台中转机一个 frpc 实例，**二进制共享、配置/任务/日志按实例隔离**：

```powershell
# 第一台中转机
.\scripts\install-frp.ps1 -Role frpc                    # 实例 default
# 第二台中转机
.\scripts\install-frp.ps1 -Role frpc -Name relay-b      # 实例 relay-b
# 第三台...
.\scripts\install-frp.ps1 -Role frpc -Name relay-c
```

实例布局：

| 实例名 | 配置 | 计划任务 | 日志 |
|:--|:--|:--|:--|
| default | `frpc-default.toml` | `OrzMCProxy-frpc-default` | `frpc-default.log` |
| relay-b | `frpc-relay-b.toml` | `OrzMCProxy-frpc-relay-b` | `frpc-relay-b.log` |

每个实例的 `frpc.toml` 独立配置（`serverAddr` 指向各自中转机），都转发本地 `25565`（frpc 是主动连接方，多实例同端口无冲突），都开 `proxyProtocolVersion = "v2"`（真实 IP 透传）。所有 frpc 同时转发同一服务器 → 玩家任选中转地址，PROXY protocol 无缝。

⚠️ 一台中转机只配一个 frpc 实例（同一 frps 上代理名冲突）。

## 配置

```powershell
notepad 'C:\Program Files\OrzMCProxy\frpc-default.toml'
# 修改 serverAddr / auth.token 后：
Restart-ScheduledTask -TaskName "OrzMCProxy-frpc-default"
```

## 常用命令

```powershell
Get-ScheduledTask -TaskName "OrzMCProxy-frpc-*"              # 查看所有实例
Start-ScheduledTask -TaskName "OrzMCProxy-frpc-default"      # 启动
Stop-ScheduledTask -TaskName "OrzMCProxy-frpc-default"       # 停止
Restart-ScheduledTask -TaskName "OrzMCProxy-frpc-default"    # 重启
Get-Content 'C:\Program Files\OrzMCProxy\frpc-default.log' -Tail 50   # 日志
```

## 卸载

```powershell
# 卸载单个实例（-Purge 连配置一起删；二进制仅在无其他实例引用时删除）
.\scripts\uninstall-frp.ps1 -Role frpc -Name relay-b -Purge
```
