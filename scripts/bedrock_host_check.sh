#!/bin/bash
# ============================================================
# 基岩版 Geyser 连通性诊断脚本 (Linux/macOS)
# 双模式:
#   ① 本机诊断(默认): 不传参 或 只传端口
#   ② 远程探测: 传 host (端口可选, 默认 19132)
# 用法:
#   bash bedrock_host_check.sh                  # 本机 19132
#   bash bedrock_host_check.sh 39742            # 本机 39742
#   bash bedrock_host_check.sh mc.example.com   # 远程 19132
#   bash bedrock_host_check.sh mc.example.com 39742  # 远程指定端口
#   bash bedrock_host_check.sh -h|--help        # 显示帮助
# ============================================================
show_help() {
    cat <<'EOF'
基岩版 Geyser 连通性诊断脚本 (Linux/macOS)

用法:
  bash bedrock_host_check.sh [host] [port]

参数:
  host   目标服务器 IP/域名; 不传 = 本机诊断(127.0.0.1)
  port   基岩 RakNet 端口; 默认 19132; 可单独作为第一个参数传入
  -h, --help   显示本帮助

示例:
  bash bedrock_host_check.sh                    # 本机 19132 (五项检查)
  bash bedrock_host_check.sh 39742              # 本机 39742
  bash bedrock_host_check.sh mc.example.com     # 远程 19132 (可达性)
  bash bedrock_host_check.sh mc.example.com 39742

输出说明:
  [1] RakNet 握手   Geyser 是否存活 + MOTD
  [2] 端口监听      本机模式: UDP 是否在听
  [3] 进程检查      本机模式: Geyser/服务端进程
  [4] 防火墙        本机模式: macOS/Linux 防火墙规则
  [5] 外部提示      UDP 需单独放行 (TCP 通 ≠ UDP 通)
EOF
}

case "${1:-}" in
    -h|--help|-help)
        show_help
        exit 0
        ;;
esac

# 参数智能识别: 第一个参数是纯数字 → 视为端口(本机模式); 否则 → 视为 host
if [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    HOST="127.0.0.1"
    PORT="${1:-19132}"
else
    HOST="${1:-127.0.0.1}"
    PORT="${2:-19132}"
fi
LOCAL_MODE=""
case "$HOST" in
    127.*|localhost|::1) LOCAL_MODE="yes" ;;
esac
# 选择可用的 Python：优先真实解释器，排除 WindowsApps 的 Store 占位 stub
# （AppInstallerPythonRedirector.exe 运行时无输出即退出，会静默导致握手失败）
find_real_python() {
    local cmd
    for cmd in python python3 py; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local path
            path=$(command -v "$cmd")
            case "$path" in
                *WindowsApps*) continue ;;   # 跳过 Store 占位符
            esac
            # 验证它真的是 Python 且能输出版本
            if "$cmd" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
                printf '%s' "$cmd"
                return 0
            fi
        fi
    done
    return 1
}
PYTHON=$(find_real_python)

echo ""
echo "========== 基岩版 Geyser 连通性诊断 =========="
echo "目标: $HOST UDP $PORT (基岩 RakNet 端口)${LOCAL_MODE:+ [本机模式]}"
echo ""

# ---------- 1. RakNet Unconnected Ping (真实基岩握手) ----------
echo "[1] RakNet 握手 ($HOST:$PORT):"
RCPID=""
if [ -n "$PYTHON" ]; then
    # 用内联 python 做 UDP 探测，避免依赖脚本路径
    OUT=$("$PYTHON" - "$HOST" "$PORT" <<'EOF'
import socket, struct, sys, time
host, port = sys.argv[1], int(sys.argv[2])
magic = bytes([0x00,0xff,0xff,0x00,0xfe,0xfe,0xfe,0xfe,0xfd,0xfd,0xfd,0xfd,0x12,0x34,0x56,0x78])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
payload = b"\x01" + struct.pack(">Q", int(time.time()*1000)) + magic + struct.pack(">Q", 0x1234567890ABCDEF)
s.sendto(payload, (host, port))
try:
    data, addr = s.recvfrom(4096)
    if data[0] == 0x1C:
        motd = data[34:].decode("utf-8", "replace").rstrip("\x00")
        print(f"PONG_OK|{motd[:160]}")
    else:
        print(f"UNEXPECTED|packet 0x{data[0]:02x}")
except socket.timeout:
    print("TIMEOUT")
except OSError as e:
    print(f"SOCKET_ERROR|{e}")
EOF
)
    if echo "$OUT" | grep -q "^PONG_OK"; then
        MOTD=$(echo "$OUT" | cut -d'|' -f2-)
        echo "    PASS ✅ (Geyser 存活)"
        echo "    MOTD: $MOTD"
    else
        echo "    FAIL ❌ ($HOST:$PORT 无响应: $OUT)"
    fi
else
    echo "    SKIP (无 python3/python, 无法做 RakNet 握手)"
fi

# 远程模式：握手已足够判断可达性, 跳过本机专属检查
if [ -z "$LOCAL_MODE" ]; then
    echo ""
    echo "========== 远程探测结论 =========="
    if echo "$OUT" | grep -q "^PONG_OK"; then
        echo "  ✅ $HOST:$PORT 基岩入口可达 —— Geyser 存活且响应"
    else
        echo "  ❌ $HOST:$PORT 基岩入口不可达 —— UDP $PORT 无响应"
        echo "     排查: 服务器 Geyser 是否运行 / 路由器或云安全组 UDP $PORT 转发"
    fi
    echo "================================"
    exit 0
fi

# ---------- 2. 端口监听检查 ----------
echo ""
echo "[2] 端口监听检查:"
UDP_LINE=""
if command -v ss >/dev/null 2>&1; then
    UDP_LINE=$(ss -lun 2>/dev/null | grep ":$PORT ")
    SS_TCP=$(ss -ltn 2>/dev/null | grep ":$PORT ")
elif command -v netstat >/dev/null 2>&1; then
    # macOS netstat: "udp46 0 0 *.19132 *.*"；Linux: "udp 0 0 0.0.0.0:19132"
    UDP_LINE=$(netstat -an 2>/dev/null | grep -iE "^udp" | grep "\.$PORT ")
    SS_TCP=$(netstat -an 2>/dev/null | grep -iE "^tcp" | grep ":$PORT " | grep -i "LISTEN")
else
    UDP_LINE=""; SS_TCP=""
    echo "    (无 ss/netstat)"
fi
if [ -n "$UDP_LINE" ]; then
    echo "    UDP $PORT 监听中 ✅"
    echo "$UDP_LINE" | head -3 | sed 's/^/      /'
else
    echo "    UDP $PORT 未监听 ❌"
fi
if [ -n "$SS_TCP" ]; then
    echo "    注: TCP $PORT 有监听 (基岩不走 TCP, 仅参考)"
fi

# ---------- 3. 进程检查 ----------
echo ""
echo "[3] 进程检查:"
# 跨平台进程匹配: 统一走 ps aux/-ef + grep（兼容 busybox/精简 Linux/MSYS/macOS）
# ⚠️ 勿用 pgrep 输出做二次 grep：pgrep 只给 pid 数字（BSD/macOS 的 -a 也不输出命令行），
#    pid 里永远匹配不到进程名 → 误报"未找到"。pgrep 仅用于快速判断存在性。
ps_lines() {
    local pat="$1"
    if command -v ps >/dev/null 2>&1; then
        (ps aux 2>/dev/null || ps -ef 2>/dev/null) | grep -i -E "$pat" | grep -v "grep -i" | head -3
    fi
}
GEYSER_LINES=$(ps_lines "geyser")
SVR_LINES=$(ps_lines "paper.*jar|spigot.*jar|purpur.*jar|paperclip")
if [ -n "$GEYSER_LINES" ]; then
    echo "    → 找到 Geyser 进程 ✅"
    echo "$GEYSER_LINES" | sed 's/^/      /'
elif [ -n "$SVR_LINES" ]; then
    echo "    → 无 Geyser 独立进程, 但服务端运行中 (Geyser 可能内嵌) ⚠️"
    echo "$SVR_LINES" | sed 's/^/      /'
else
    echo "    → 无 Geyser/服务端进程 ❌ Geyser 可能没启动" 
fi

# ---------- 4. 防火墙检查 ----------
echo ""
echo "[4] 防火墙检查:"
FW=""
if command -v ufw >/dev/null 2>&1; then FW="ufw"; fi
if command -v firewall-cmd >/dev/null 2>&1; then FW="firewall-cmd"; fi
case "$FW" in
    ufw)
        UFW_OUT=$(sudo -n ufw status 2>/dev/null | grep "$PORT" || ufw status 2>/dev/null | grep "$PORT")
        if [ -n "$UFW_OUT" ]; then echo "    ufw: $UFW_OUT"; else echo "    ufw 未找到 $PORT 规则 ⚠️"; fi ;;
    firewall-cmd)
        FC_OUT=$(firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep "^$PORT/udp")
        if [ -n "$FC_OUT" ]; then echo "    firewalld: $FC_OUT ✅"; else echo "    firewalld 未放行 $PORT/udp ⚠️"; fi ;;
    *)
        # macOS: socketfilterfw（应用防火墙，无需 root 查全局状态）
        if [ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]; then
            STATE=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
            echo "    macOS Application Firewall: $STATE"
            # 检查 java 是否被防火墙放行（Geyser 跑在 JVM 里）
            JAVA_ALLOW=$(/usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null | grep -i -A2 "java" | grep -i "allow" | head -1)
            if [ -n "$JAVA_ALLOW" ]; then
                echo "    java 入站放行 ✅"
            else
                echo "    ⚠️ 未确认 java 入站放行（socketfilterfw --listapps 需 root；若防火墙开启且 java 未在列表放行，UDP 可能被拦）"
            fi
        else
            echo "    (未检测到 ufw/firewalld; 云安全组需在控制台确认 UDP $PORT)"
        fi ;;
esac

# ---------- 5. 汇总 ----------
echo ""
echo "========== 诊断汇总 =========="
if [ -n "$UDP_LINE" ]; then
    echo "  ✅ 本机 UDP $PORT 在监听 —— 问题大概率在【外部转发/防火墙】"
    echo "     下一步: 检查路由器/云安全组的 UDP $PORT 转发规则"
else
    echo "  ❌ 本机 UDP $PORT 未监听 —— 问题在【Geyser 本身】"
    echo "     下一步: 确认 Geyser 实例运行 + 端口配置 + 本机防火墙放行"
fi
echo "================================="
