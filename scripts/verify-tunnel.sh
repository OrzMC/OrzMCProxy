#!/usr/bin/env bash
# OrzMCProxy - 隧道验证：TCP 连通 + Minecraft Server List Ping 握手探测
# 用法: verify-tunnel.sh <host> <port> [timeout_s]
set -euo pipefail

HOST="${1:?用法: $0 <host> <port> [timeout_s]}"
PORT="${2:?用法: $0 <host> <port> [timeout_s]}"
TIMEOUT="${3:-5}"

echo "==> 探测 ${HOST}:${PORT}"

# 1. TCP 连通性（bash /dev/tcp，跨平台无依赖；macOS 无 GNU timeout 需检测）
if command -v timeout >/dev/null 2>&1; then
  ok="$(timeout "${TIMEOUT}" bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null && echo 1 || echo 0)"
else
  ok="$(bash -c "exec 3<>/dev/tcp/${HOST}/${PORT}" 2>/dev/null && echo 1 || echo 0)"
fi
if [ "${ok}" != "1" ]; then
  echo "❌ TCP 连接失败（端口未通）"
  exit 1
fi
echo "✅ TCP 握手成功"

# 2. Minecraft Server List Ping（协议 1.7+，需要 python3）
if command -v python3 >/dev/null 2>&1; then
  python3 - "${HOST}" "${PORT}" "${TIMEOUT}" <<'PY'
import json, socket, struct, sys

host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])

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

def read_varint(sock):
    n, shift = 0, 0
    while True:
        b = sock.recv(1)
        if not b:
            raise EOFError("连接被关闭")
        n |= (b[0] & 0x7F) << shift
        if not (b[0] & 0x80):
            return n
        shift += 7

def read_packet(sock):
    ln = read_varint(sock)
    data = b""
    while len(data) < ln:
        chunk = sock.recv(ln - len(data))
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

try:
    s = socket.create_connection((host, port), timeout=timeout)
    host_b = host.encode()
    # 握手包: packet_id=0 + protocol=767 + host + port + next_state=1
    handshake = varint(0) + varint(767) + varint(len(host_b)) + host_b + struct.pack(">H", port) + varint(1)
    s.sendall(varint(len(handshake)) + handshake)
    # Status Request: packet_id=0x01（空载荷）
    s.sendall(b"\x01\x01")
    data = read_packet(s)
    s.close()
    _, i = varint_from_bytes(data)          # 跳过 packet_id
    js_len, i = varint_from_bytes(data, i)  # JSON 字符串长度
    js = json.loads(data[i:i + js_len].decode())
    desc = js.get("description", "?")
    if isinstance(desc, dict):
        desc = desc.get("text", "?")
    print(f"✅ Minecraft 服务器响应:")
    print(f"   版本: {js.get('version', {}).get('name', '?')}")
    print(f"   在线: {js.get('players', {}).get('online', '?')}/{js.get('players', {}).get('max', '?')}")
    print(f"   MOTD: {desc}")
except Exception as e:
    print(f"⚠️  TCP 通了但 Minecraft ping 失败（可能是非 MC 端口）: {e}")
    sys.exit(0)

sys.exit(0)
PY
else
  echo "（未检测到 python3，跳过 Minecraft 协议探测；TCP 已通即可视为隧道正常）"
fi
