# OrzMCProxy - 一键安装 frps/frpc（Windows 11，x86_64 / arm64）
# 用法（管理员 PowerShell）: .\scripts\install-frp.ps1 -Role frpc
# 环境变量: FRP_VERSION(默认0.70.1)
param(
    [ValidateSet("frps", "frpc")]
    [string]$Role = "frpc"
)

$ErrorActionPreference = "Stop"
$Version = if ($env:FRP_VERSION) { $env:FRP_VERSION } else { "0.70.1" }
$InstallDir = "$env:ProgramFiles\OrzMCProxy"

# ---------- 检测架构 ----------
$arch = if ($env:PROCESSOR_ARCHITECTURE -match "ARM") { "arm64" } else { "amd64" }
Write-Host "==> 检测: Windows $arch | frp v$Version | 角色: $Role"

# ---------- 下载并解压 ----------
$url = "https://github.com/fatedier/frp/releases/download/v$Version/frp_${Version}_windows_$arch.zip"
$zip = "$env:TEMP\frp_$Version.zip"
$extract = "$env:TEMP\frp_$Version"
Write-Host "==> 下载 $url"
Invoke-WebRequest -Uri $url -OutFile $zip
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $extract -Force
$src = "$extract\frp_${Version}_windows_$arch"
$exeName = if ($Role -eq "frps") { "frps.exe" } else { "frpc.exe" }

# ---------- 安装 ----------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item "$src\$exeName" "$InstallDir\$exeName" -Force
$cfg = "$InstallDir\$Role.toml"
if (-not (Test-Path $cfg)) {
    Write-Host "==> 生成配置模板 $cfg （⚠️ 请修改 token/地址后重启任务）"
    if ($Role -eq "frps") {
        @"
bindPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"
allowPorts = [
  { start = 25565, end = 25566 },
]
"@ | Set-Content -Path $cfg -Encoding UTF8
    } else {
        @"
serverAddr = "CHANGE_ME_RELAY_IP"
serverPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"

[[proxies]]
name = "mc-java-main"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25565
remotePort = 25565

[[proxies]]
name = "mc-java-second"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25566
remotePort = 25566
"@ | Set-Content -Path $cfg -Encoding UTF8
    }
} else {
    Write-Host "==> 已存在 $cfg，跳过生成（如需重置请先删除）"
}

# ---------- 注册计划任务（开机自启 + 失败每 5 分钟自愈） ----------
$taskName = "OrzMCProxy-$Role"
$action = New-ScheduledTaskAction -Execute "$InstallDir\$exeName" -Argument "-c `"$cfg`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host ""
Write-Host "🎉 安装完成！"
Write-Host "  1. 编辑 $cfg 修改配置"
Write-Host "  2. Restart-ScheduledTask -TaskName $taskName"
Write-Host "  3. 日志: Get-Content '$InstallDir\frp.log' -Tail 50"
