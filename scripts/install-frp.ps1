# OrzMCProxy - 一键安装 frps/frpc（Windows 11，x86_64 / arm64），支持多实例
# 用法（管理员 PowerShell）:
#   .\scripts\install-frp.ps1 -Role frpc                 # 默认实例 default
#   .\scripts\install-frp.ps1 -Role frpc -Name relay-b   # 第二台中转机实例（多中转机 → 单服务）
# 环境变量: FRP_VERSION(默认0.70.1)
param(
    [ValidateSet("frps", "frpc")]
    [string]$Role = "frpc",
    [string]$Name = "default"
)

$ErrorActionPreference = "Stop"
$Version = if ($env:FRP_VERSION) { $env:FRP_VERSION } else { "0.70.1" }
$InstallDir = "$env:ProgramFiles\OrzMCProxy"
$exeName = if ($Role -eq "frps") { "frps.exe" } else { "frpc.exe" }
$cfg = "$InstallDir\$Role-$Name.toml"
$logFile = "$InstallDir\$Role-$Name.log"
$taskName = "OrzMCProxy-$Role-$Name"

# ---------- 检测架构 ----------
$arch = if ($env:PROCESSOR_ARCHITECTURE -match "ARM") { "arm64" } else { "amd64" }
Write-Host "==> 检测: Windows $arch | frp v$Version | 角色: $Role | 实例: $Name"

# ---------- 下载并解压（二进制共享，只装一份） ----------
if (-not (Test-Path "$InstallDir\$exeName")) {
    $url = "https://github.com/fatedier/frp/releases/download/v$Version/frp_${Version}_windows_$arch.zip"
    $zip = "$env:TEMP\frp_$Version.zip"
    $extract = "$env:TEMP\frp_$Version"
    Write-Host "==> 下载 $url"
    Invoke-WebRequest -Uri $url -OutFile $zip
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $src = "$extract\frp_${Version}_windows_$arch"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item "$src\$exeName" "$InstallDir\$exeName" -Force
} else {
    Write-Host "==> 二进制 $exeName 已存在，跳过下载"
}

# ---------- 生成配置模板（按实例隔离） ----------
if (-not (Test-Path $cfg)) {
    Write-Host "==> 生成配置模板 $cfg （⚠️ 请修改 token/地址后重启任务）"
    $logPath = $logFile.Replace("\", "/")  # TOML 用正斜杠避免转义
    if ($Role -eq "frps") {
        @"
bindPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"
allowPorts = [
  { start = 25565, end = 25565 },
]
log.to = "$logPath"
log.level = "info"
"@ | Set-Content -Path $cfg -Encoding UTF8
    } else {
        @"
serverAddr = "CHANGE_ME_RELAY_IP"
serverPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"
log.to = "$logPath"
log.level = "info"

[[proxies]]
name = "mc-java-main"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25565
remotePort = 25565

[proxies.transport]
proxyProtocolVersion = "v2"
"@ | Set-Content -Path $cfg -Encoding UTF8
    }
} else {
    Write-Host "==> 已存在 $cfg，跳过生成（如需重置请先删除）"
}

# ---------- 注册计划任务（按实例，开机自启 + 失败每 5 分钟自愈） ----------
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
Write-Host "🎉 安装完成！计划任务: $taskName"
Write-Host "  1. 编辑 $cfg 修改配置（serverAddr/token 等）"
Write-Host "  2. Restart-ScheduledTask -TaskName $taskName"
Write-Host "  3. 日志: Get-Content '$logFile' -Tail 50"
Write-Host ""
Write-Host "多实例提示: 再装一台中转机执行 .\scripts\install-frp.ps1 -Role frpc -Name <别名>"
