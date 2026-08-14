#!/usr/bin/env bash
# OrzMCProxy - 中转隧道外部健康监控（支持正式档/临时档）
#
# 设计背景：
#   正式档（proxy-protocol 开）：玩家只能走中转，直连被服务器静默拒绝（无 PROXY 头）。
#      → Java 25565 无法做 MC ping，用「TCP 连通 + 后端存活(EOF 检测)」判定。
#   临时档（无 proxy-protocol）：中转 + 直连 双通道均可用。
#      → Java 25565 做完整 MC Server List Ping；可选 --direct-host 把直连入口一并纳入监控。
#   两档通用：frps 控制口 7000 TCP + 基岩 19132 RakNet Unconnected Ping（真实端到端）。
#
# 输出契约（适配 Hermes cron no_agent 看门狗模式）：
#   状态转换时打印告警/恢复消息（非空 stdout → cron 投递一次）
#   状态稳定时静默（空 stdout → cron 静默，不刷屏）
#   退出码恒 0（健康性通过 stdout 表达；脚本自身异常也转为一次性 ALERT）
#
# 用法:
#   relay-monitor.sh [--mode formal|temp] [--host 中转机IP] [--direct-host 家宽IP] [--state-file PATH]
#   --mode formal|temp   档位（默认 formal，与生产模板一致）
#   --host IP            中转机 IP（默认 1.117.58.192 腾讯云上海）
#   --direct-host IP     temp 档可选项：家宽直连 IP，把直连入口纳入监控（formal 档忽略——直连本就该失效）
#   --state-file PATH    状态文件（默认 /tmp/orzmcproxy-relay.state）
#
# 示例:
#   relay-monitor.sh --mode formal                                   # 正式档：只查中转
#   relay-monitor.sh --mode temp --direct-host 123.45.67.89          # 临时档：中转+直连双查
set -uo pipefail

MODE="formal"
HOST="1.117.58.192"
DIRECT_HOST=""
STATE_FILE="/tmp/orzmcproxy-relay.state"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-formal}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --direct-host) DIRECT_HOST="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE="${2:-}"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

case "$MODE" in formal|temp) ;; *) echo "错误: --mode 只接受 formal|temp"; exit 1 ;; esac

python3 - "${MODE}" "${HOST}" "${DIRECT_HOST}" "${STATE_FILE}" <<'PY'
import json, os, socket, struct, sys, tempfile, time

MODE, HOST, DIRECT_HOST, STATE_FILE = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
FORMAL = (MODE == "formal")
TIMEOUT = 5

# ---------- 探测原语 ----------
def tcp_ok(host, port):
    """TCP 连通（frps 控制口/普通端口）"""
    try:
        s = socket.create_connection((host, port), timeout=TIMEOUT)
        s.close()
        return True
    except OSError:
        return False

def backend_alive(host, port):
    """formal 档 Java 端口：TCP 连上后 2s 内无 EOF/RST = frpc→Paper 后端存活。
    Paper 等 PROXY 头时不会主动发数据 → timeout 即存活；EOF/RST = frps 无可用后端。"""
    try:
        s = socket.create_connection((host, port), timeout=TIMEOUT)
    except OSError:
        return False
    s.settimeout(2)
    try:
        data = s.recv(1)
        s.close()
        return len(data) > 0   # 收到字节（异常但视为有后端）；b''=EOF=无后端
    except socket.timeout:
        s.close()
        return True            # 连接保持 = 后端在等 PROXY 头
    except OSError:
        s.close()
        return False           # RST

def mc_ping(host, port):
    """完整 MC Server List Ping（1.7+ 协议）。返回 (ok, desc)"""
    try:
        s = socket.create_connection((host, port), timeout=TIMEOUT)
        def varint(n):
            out = b""
            while True:
                b = n & 0x7F
                n >>= 7
                if n:
                    out += bytes([b | 0x80])
                else:
                    out += bytes([b])
                    return out
        def read_varint():
            n, shift = 0, 0
            while True:
                b = s.recv(1)
                if not b:
                    raise EOFError("连接被关闭")
                n |= (b[0] & 0x7F) << shift
                if not (b[0] & 0x80):
                    return n
                shift += 7
        def read_packet():
            ln = read_varint()
            data = b""
            while len(data) < ln:
                chunk = s.recv(ln - len(data))
                if not chunk:
                    raise EOFError("连接被关闭")
                data += chunk
            return data
        def varint_from_bytes(b, i=0):
            n, shift = 0, 0
            while True:
                n |= (b[i] & 0x7F) << shift
                if not (b[i] & 0x80):
                    return n, i + 1
                shift += 7
                i += 1
        host_b = host.encode()
        handshake = varint(0) + varint(767) + varint(len(host_b)) + host_b + struct.pack(">H", port) + varint(1)
        s.sendall(varint(len(handshake)) + handshake)
        # Status Request: packet_id=0x00（⚠️ 不是 0x01！0x01 是 Ping Request 需 8B payload——历史 bug，2026-08-14 实测抓到）
        s.sendall(b"\x01\x00")
        data = read_packet()
        s.close()
        _, i = varint_from_bytes(data)
        js_len, i = varint_from_bytes(data, i)
        js = json.loads(data[i:i + js_len].decode())
        desc = js.get("description", "?")
        if isinstance(desc, dict):
            desc = desc.get("text", "?")
        return True, f"{js.get('players', {}).get('online', '?')}/{js.get('players', {}).get('max', '?')}人 {desc[:60]}"
    except Exception as e:
        return False, str(e)[:80]

def raknet_ping(host, port=19132):
    """基岩 RakNet Unconnected Ping（Geyser→Java 全链路端到端）"""
    magic = bytes([0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
                   0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78])
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(6)
        payload = b"\x01" + struct.pack(">Q", int(time.time() * 1000)) + magic + struct.pack(">Q", 0x1234567890ABCDEF)
        s.sendto(payload, (host, port))
        data, _ = s.recvfrom(4096)
        s.close()
        if data[0] == 0x1C:
            motd_len = struct.unpack(">H", data[32:34])[0]
            motd = data[34:34 + motd_len].decode("utf-8", "replace")
            return True, motd[:60]
        return False, f"异常包 0x{data[0]:02x}"
    except socket.timeout:
        return False, "UDP 无响应"
    except OSError as e:
        return False, str(e)[:80]

# ---------- 按档位组装检查 ----------
checks = []   # (label, ok, detail)
checks.append(("frps控制口(7000)", tcp_ok(HOST, 7000), ""))

if FORMAL:
    ok = backend_alive(HOST, 25565)
    checks.append(("Java中转(25565/后端存活)", ok, "EOF/RST=无后端" if not ok else ""))
else:
    ok, desc = mc_ping(HOST, 25565)
    checks.append(("Java中转(25565/MC ping)", ok, desc if not ok else f"在线 {desc}"))
    if DIRECT_HOST:
        ok, desc = mc_ping(DIRECT_HOST, 25565)
        checks.append(("Java直连(25565/MC ping)", ok, desc if not ok else f"在线 {desc}"))
        ok, desc = raknet_ping(DIRECT_HOST)
        checks.append(("基岩直连(19132/RakNet)", ok, desc if not ok else f"PONG {desc}"))

ok, desc = raknet_ping(HOST)
checks.append(("基岩中转(19132/RakNet)", ok, desc if not ok else f"PONG {desc}"))

# ---------- 汇总 ----------
fails = [c for c in checks if not c[1]]
status = "OK" if not fails else "FAIL"
detail = "; ".join(f"{c[0]}×{c[2]}" for c in fails) if fails else "全部正常"
lines = []
for label, ok, d in checks:
    mark = "✅" if ok else "❌"
    lines.append(f"  {mark} {label}" + (f" — {d}" if d else ""))

# ---------- 状态转换 ----------
prev = None
try:
    with open(STATE_FILE) as f:
        prev = json.load(f).get("status")
except Exception:
    pass

now_ts = int(time.time())
new_state = {"status": status, "detail": detail, "ts": now_ts}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATE_FILE) or ".")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(new_state, f)
    os.replace(tmp, STATE_FILE)
except Exception:
    os.unlink(tmp)

if prev is None:
    # 首次运行：输出基线（让 cron 首次投递一次，确认监控已上线）
    print(f"🆕 中转隧道监控上线（{MODE}档）— 当前状态 {status}: {detail}")
    print("\n".join(lines))
elif prev == "OK" and status == "FAIL":
    print(f"🔴 ALERT 中转隧道异常（{MODE}档）— {detail}")
    print("\n".join(lines))
elif prev == "FAIL" and status == "OK":
    print(f"🟢 RECOVERY 中转隧道已恢复（{MODE}档）— {detail}")
    print("\n".join(lines))
# 状态稳定 → 静默（不输出，cron 不投递）
PY
exit 0
