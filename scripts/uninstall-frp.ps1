# OrzMCProxy - 卸载 frps/frpc（Windows 11），支持多实例
# 用法（管理员 PowerShell）:
#   .\scripts\uninstall-frp.ps1                        # 卸载 default 实例
#   .\scripts\uninstall-frp.ps1 -Role frpc -Name relay-b -Purge
param(
    [ValidateSet("frps", "frpc")]
    [string]$Role = "frpc",
    [string]$Name = "default",
    [switch]$Purge
)

$ErrorActionPreference = "Continue"
$InstallDir = "$env:ProgramFiles\OrzMCProxy"
$taskName = "OrzMCProxy-$Role-$Name"
$cfg = "$InstallDir\$Role-$Name.toml"
$logFile = "$InstallDir\$Role-$Name.log"
$exeName = if ($Role -eq "frps") { "frps.exe" } else { "frpc.exe" }

# 1. 停任务
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "✅ 已删除计划任务 $taskName"

# 2. 删配置/日志（可选）
if ($Purge) {
    Remove-Item $cfg, $logFile -Force -ErrorAction SilentlyContinue
    # 二进制共享：仅当无任何同角色实例配置时才删
    if (-not (Get-ChildItem "$InstallDir\$Role-*.toml" -ErrorAction SilentlyContinue)) {
        Remove-Item "$InstallDir\$exeName" -Force -ErrorAction SilentlyContinue
        if (-not (Get-ChildItem $InstallDir -ErrorAction SilentlyContinue)) {
            Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "✅ 二进制 $exeName 已清除（无其他实例引用）"
    } else {
        Write-Host "ℹ️  检测到其他实例配置，保留共享二进制 $exeName"
    }
    Write-Host "✅ 配置与日志已清除（-Purge）"
} else {
    Write-Host "ℹ️  配置保留（如需清除加 -Purge）"
}
Write-Host "🎉 卸载完成"
