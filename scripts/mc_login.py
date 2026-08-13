#!/usr/bin/env python3
"""MC 登录验证脚本（完整协议流程，含压缩协议）：
帧(VarInt长度) → [压缩后: VarInt(解压长度)+zlib | 未压缩: 原始包]
Handshake → Login Start → Set Compression 应答 → Login Success/Disconnect
用法: python3 mc_login.py <host> <port> [src_ip] [src_port] [username] [proxy|plain]
proxy = 手动加 PROXY v2 头（直连本地测试服验证 Paper 侧机制）；经 frpc 隧道必须 plain
"""
import socket, struct, sys, uuid as uuid_mod, zlib, time

def varint(n):
    out = b''
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            out += bytes([b])
            return out

def read_varint(sock):
    shift = 0
    result = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise EOFError('连接被关闭')
        result |= (b[0] & 0x7F) << shift
        if not (b[0] & 0x80):
            return result
        shift += 7

def recv_exact(sock, n):
    data = b''
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError('连接被关闭')
        data += chunk
    return data

def parse_varint_at(buf, off):
    val = 0
    shift = 0
    while off < len(buf):
        b = buf[off]
        off += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, off
        shift += 7
    raise EOFError('varint 不完整')

def proxy_v2_header(src_ip, src_port, dst_ip, dst_port):
    sig = b'\x0d\x0a\x0d\x0a\x00\x0d\x0a\x51\x55\x49\x54\x0a'
    return sig + b'\x21' + b'\x11' + struct.pack('!H', 12) + \
        socket.inet_aton(src_ip) + socket.inet_aton(dst_ip) + struct.pack('!HH', src_port, dst_port)

def mc_string(s):
    return varint(len(s)) + s.encode()

host = sys.argv[1] if len(sys.argv) > 1 else '1.117.58.192'
port = int(sys.argv[2]) if len(sys.argv) > 2 else 25565
src_ip = sys.argv[3] if len(sys.argv) > 3 else '203.0.113.5'
src_port = int(sys.argv[4]) if len(sys.argv) > 4 else 40000
username = sys.argv[5] if len(sys.argv) > 5 else 'proxytestD'
send_proxy = len(sys.argv) > 6 and sys.argv[6] == 'proxy'
PROTOCOL = 776

sock = socket.create_connection((host, port), timeout=10)
sock.settimeout(10)
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

if send_proxy:
    sock.sendall(proxy_v2_header(src_ip, src_port, host, port))
    time.sleep(0.3)

compressed = False

def send_packet(pid, payload=b''):
    body = varint(pid) + payload
    if compressed:
        inner = varint(0) + body          # 未压缩形式（dataLength=0）
        sock.sendall(varint(len(inner)) + inner)
    else:
        sock.sendall(varint(len(body)) + body)

def read_packet():
    framelen = read_varint(sock)
    frame = recv_exact(sock, framelen)
    if compressed:
        dlen, off = parse_varint_at(frame, 0)
        raw = zlib.decompress(frame[off:]) if dlen > 0 else frame[off:]
    else:
        raw = frame
    pid, poff = parse_varint_at(raw, 0)
    return pid, raw[poff:]

# 1. Handshake (nextState=2)
send_packet(0x00, varint(PROTOCOL) + mc_string(host) + struct.pack('!H', port) + varint(2))
# 2. Login Start
send_packet(0x00, mc_string(username) + uuid_mod.UUID('12345678-1234-1234-1234-123456789012').bytes)

# 3. 响应循环
while True:
    pid, payload = read_packet()
    if pid == 0x00:  # Login Disconnect
        print(f'Disconnect(白名单/鉴权拒绝): {payload[:200]!r}')
        break
    elif pid == 0x01:
        print('Encryption Request（离线模式异常）')
        break
    elif pid == 0x02:  # Login Success
        print('Login Success ✅ 登录成功')
        break
    elif pid == 0x03:  # Set Compression → 回 Login Acknowledged
        compressed = True
        send_packet(0x03)
    else:
        print(f'未知包 pid={pid} len={len(payload)}')
        break

sock.close()
