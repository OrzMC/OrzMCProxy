# OrzMCProxy - 卸载 frps/frpc（Windows 11）
# 用法（管理员 PowerShell）: .\scripts\uninstall-frp.ps1 [-Purge]
param(
    [ValidateSet("frps", "frpc")]
    [string]$Role = "frpc",
    [switch]$Purge
)

$ErrorActionPreference = "Continue"
$InstallDir = "$env:ProgramFiles\OrzMCProxy"
$taskName = "OrzMCProxy-$Role"

# 1. 停任务
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "✅ 已删除计划任务 $taskName"

# 2. 删二进制
$exeName = if ($Role -eq "frps") { "frps.exe" } else { "frpc.exe" }
Remove-Item "$InstallDir\$exeName" -Force -ErrorAction SilentlyContinue

# 3. 配置（可选）
if ($Purge) {
    Remove-Item "$InstallDir\$Role.toml" -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem $InstallDir -ErrorAction SilentlyContinue)) {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "✅ 配置已清除（-Purge）"
} else {
    Write-Host "ℹ️  配置保留（如需清除加 -Purge）"
}
Write-Host "🎉 卸载完成"
