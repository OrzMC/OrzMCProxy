# ============================================================
# 基岩版 Geyser 连通性诊断脚本 (Windows PowerShell)
# 双模式:
#   ① 本机诊断(默认): .\bedrock_host_check.ps1 [-Port 19132]
#   ② 远程探测: .\bedrock_host_check.ps1 <host> [-Port 19132]
# 用法:
#   .\bedrock_host_check.ps1                    # 本机 19132 (五项检查)
#   .\bedrock_host_check.ps1 -Port 39742        # 本机 39742
#   .\bedrock_host_check.ps1 mc.example.com     # 远程 19132
#   .\bedrock_host_check.ps1 mc.example.com -Port 39742
#   .\bedrock_host_check.ps1 -Help              # 显示帮助
# 无需 Python, 纯 PowerShell 5.1+ 即可
# ============================================================
param([string]$HostAddr = "", [int]$Port = 19132, [switch]$Help)

if ($Help) {
    Write-Host @'
基岩版 Geyser 连通性诊断脚本 (Windows PowerShell)

用法:
  .\bedrock_host_check.ps1 [host] [-Port port]

参数:
  host    目标服务器 IP/域名; 不传 = 本机诊断(127.0.0.1)
  -Port   基岩 RakNet 端口; 默认 19132
  -Help   显示本帮助

示例:
  .\bedrock_host_check.ps1                      # 本机 19132 (五项检查)
  .\bedrock_host_check.ps1 -Port 39742          # 本机 39742
  .\bedrock_host_check.ps1 mc.example.com       # 远程 19132 (可达性)
  .\bedrock_host_check.ps1 mc.example.com -Port 39742

输出说明:
  [1] RakNet 握手   Geyser 是否存活 + MOTD
  [2] 端口监听      本机模式: UDP 是否在听
  [3] 进程检查      本机模式: Geyser/服务端进程
  [4] 防火墙        本机模式: Windows 防火墙规则 (需管理员)
  [5] 外部提示      UDP 需单独放行 (TCP 通 ≠ UDP 通)
'@
    exit 0
}

if ($HostAddr -eq "") { $HostAddr = "127.0.0.1" }

$LocalMode = $false
if ($HostAddr -eq "127.0.0.1" -or $HostAddr -eq "localhost" -or $HostAddr -eq "::1") { $LocalMode = $true }
Write-Host ""
Write-Host "========== 基岩版 Geyser 连通性诊断 ==========" -ForegroundColor Cyan
Write-Host ("目标: {0} UDP {1} (基岩 RakNet 端口){2}" -f $HostAddr, $Port, $(if ($LocalMode) { " [本机模式]" } else { "" }))
Write-Host ""

# ---------- 1. RakNet Unconnected Ping (真实基岩握手) ----------
function Send-RakNetPing {
    param([string]$Addr, [int]$Port, [int]$TimeoutMs = 4000)
    $magic = [byte[]]@(0x00,0xff,0xff,0x00,0xfe,0xfe,0xfe,0xfe,0xfd,0xfd,0xfd,0xfd,0x12,0x34,0x56,0x78)
    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = $TimeoutMs
    try {
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $tsBytes = [BitConverter]::GetBytes([int64]$ts); [Array]::Reverse($tsBytes)   # big-endian
        $idBytes = [BitConverter]::GetBytes([int64]0x1234567890ABCDEF); [Array]::Reverse($idBytes)
        $payload = [byte[]]@(0x01) + $tsBytes + $magic + $idBytes
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Addr), $Port)
        [void]$client.Send($payload, $payload.Length, $ep)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $client.Receive([ref]$remote)
        if ($data[0] -eq 0x1C) {
            # 解析 MOTD: Geyser 的 Pong 响应中，MOTD 从偏移 34 开始一直到包尾(UTF-8)
            # (部分服务器长度字段为 0/缺失, 直接取剩余全部字节最稳健)
            $motdBytes = $data[34..($data.Length - 1)]
            $motd = [System.Text.Encoding]::UTF8.GetString($motdBytes).Trim([char]0)
            return @{ OK = $true; Motd = $motd }
        } else {
            return @{ OK = $true; Motd = ("非预期 packet 0x{0:X2}" -f $data[0]) }
        }
    } catch {
        return @{ OK = $false; Err = $_.Exception.Message }
    } finally {
        $client.Close()
    }
}

$r = Send-RakNetPing -Addr $HostAddr -Port $Port
if ($r.OK) {
    Write-Host "[1] RakNet 握手      : PASS ✅ (Geyser 存活)" -ForegroundColor Green
    Write-Host ("    MOTD: {0}" -f $r.Motd)
} else {
    Write-Host "[1] RakNet 握手      : FAIL ❌ (${HostAddr}:${Port} 无响应)" -ForegroundColor Red
    Write-Host ("    详情: {0}" -f $r.Err)
}

# 远程模式：握手已足够判断可达性, 跳过本机专属检查
if (-not $LocalMode) {
    Write-Host ""
    Write-Host "========== 远程探测结论 ==========" -ForegroundColor Cyan
    if ($r.OK) {
        Write-Host ("  ✅ {0}:{1} 基岩入口可达 —— Geyser 存活且响应" -f $HostAddr, $Port)
    } else {
        Write-Host ("  ❌ {0}:{1} 基岩入口不可达 —— UDP {1} 无响应" -f $HostAddr, $Port) -ForegroundColor Yellow
        Write-Host "     排查: 服务器 Geyser 是否运行 / 路由器或云安全组 UDP $Port 转发"
    }
    Write-Host "=================================" -ForegroundColor Cyan
    exit 0
}

# ---------- 2. 端口监听检查 ----------
Write-Host ""
Write-Host "[2] 端口监听检查 (netstat):" -ForegroundColor Cyan
$netstat = netstat -an | Select-String (":{0}\s" -f $Port)
if ($netstat) {
    $netstat | ForEach-Object { Write-Host "    $_" }
    $udpListen = $netstat | Select-String "UDP" | Select-String "0.0.0.0|::|127.0.0.1"
    if ($udpListen) {
        Write-Host "    → UDP $Port 正在监听 ✅" -ForegroundColor Green
    } else {
        Write-Host "    → UDP $Port 未见监听（可能只监听了 TCP）⚠️" -ForegroundColor Yellow
    }
} else {
    Write-Host "    → 未找到 $Port 端口监听记录 ❌" -ForegroundColor Red
}

# ---------- 3. Geyser / Java 进程检查 ----------
Write-Host ""
Write-Host "[3] 进程检查:" -ForegroundColor Cyan
$java = tasklist /FI "IMAGENAME eq java.exe" 2>$null | Select-String "java"
$geyser = tasklist 2>$null | Select-String -Pattern "geyser|Geyser"
if ($geyser) {
    Write-Host "    → 找到 Geyser 相关进程 ✅"
    $geyser | ForEach-Object { Write-Host "      $_" }
} elseif ($java) {
    Write-Host "    → 未找到 Geyser 进程名，但有 java 进程（Geyser 可能随服务端内嵌运行）⚠️"
    $java | ForEach-Object { Write-Host "      $_" }
} else {
    Write-Host "    → 既无 Geyser 也无 java 进程 ❌ Geyser 可能没启动" -ForegroundColor Red
}

# ---------- 4. 防火墙入站规则 ----------
Write-Host ""
Write-Host "[4] Windows 防火墙检查 (需管理员权限):" -ForegroundColor Cyan
$fwOk = $false
try {
    $rules = Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction Stop |
             Where-Object { ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq $Port } 2>$null
    if ($rules) {
        $rules | ForEach-Object { Write-Host ("    {0} [{1}] Action={2} Profile={3}" -f $_.DisplayName, $_.Name, $_.Action, $_.Profile) }
        if ($rules.Action -contains "Allow") {
            Write-Host "    → 存在放行规则 ✅"
        } else {
            Write-Host "    → 存在规则但 Action 非 Allow ⚠️" -ForegroundColor Yellow
        }
        $fwOk = $true
    } else {
        Write-Host "    → 未找到 $Port 的入站放行规则 ⚠️（Windows 防火墙可能拦截 UDP）" -ForegroundColor Yellow
        $fwOk = $true
    }
} catch {
    Write-Host "    → 无管理员权限，跳过防火墙检查（请用管理员 PowerShell 重跑本脚本）" -ForegroundColor Yellow
}

# ---------- 5. 外部网络环境提示 ----------
Write-Host ""
Write-Host "[5] 外部网络（路由器/云防火墙）:" -ForegroundColor Cyan
Write-Host "    ⚠️ 本机自测无法覆盖【路由器/云防火墙转发】——基岩是 UDP,"
Write-Host "       需要在公网侧验证: 用另一台机器跑"
Write-Host ("       bedrock_ping.py <公网IP或域名> {0}" -f $Port)
Write-Host "       或从手机基岩客户端直连测试。TCP 通 ≠ UDP 通, 必须单独放行 UDP。"

# ---------- 汇总 ----------
Write-Host ""
Write-Host "========== 诊断汇总 ==========" -ForegroundColor Cyan
if ($r.OK) {
    Write-Host "  ✅ Geyser 本机存活且响应握手 —— 问题大概率在【外部转发/防火墙】"
    Write-Host "     下一步: 检查路由器/云安全组的 UDP $Port 转发规则" -ForegroundColor Yellow
} else {
    Write-Host "  ❌ 本机 UDP $Port 无响应 —— 问题在【Geyser 本身或本机防火墙】"
    Write-Host "     下一步: 确认 Geyser 实例运行 + 端口配置 + 本机防火墙放行" -ForegroundColor Yellow
}
Write-Host "================================="
