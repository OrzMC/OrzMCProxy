# Windows 11 部署说明

frpc 通过**计划任务**注册为开机自启服务（含 5 分钟自愈），不依赖第三方工具（NSSM）。

## 安装（管理员 PowerShell）

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\install-frp.ps1 -Role frpc
```

自动完成：

1. 检测架构（x86_64/arm64）并下载对应 frp v0.70.1 zip
2. 解压到 `C:\Program Files\OrzMCProxy\`
3. 复制 `frpc.toml.example` → `frpc.toml`
4. 注册计划任务 `OrzMCProxy-frpc`：
   - 触发器：开机时
   - 设置：失败后每 5 分钟重启（自愈）、最大运行时间不限
   - 以 SYSTEM 运行（`-RunLevel Highest`）

## 配置

```powershell
notepad 'C:\Program Files\OrzMCProxy\frpc.toml'
# 修改 serverAddr / auth.token 后：
Restart-ScheduledTask -TaskName "OrzMCProxy-frpc"
```

## 常用命令

```powershell
Get-ScheduledTask -TaskName "OrzMCProxy-frpc"        # 查看任务
Start-ScheduledTask -TaskName "OrzMCProxy-frpc"      # 启动
Stop-ScheduledTask -TaskName "OrzMCProxy-frpc"       # 停止
Restart-ScheduledTask -TaskName "OrzMCProxy-frpc"    # 重启
Get-Content 'C:\Program Files\OrzMCProxy\frpc.log' -Tail 50   # 日志
```

## 卸载

```powershell
.\scripts\uninstall-frp.ps1
```
