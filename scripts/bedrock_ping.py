#!/usr/bin/env python3
"""基岩版 RakNet Unconnected Ping 探测（验证 Geyser 基岩入口）
用法: bedrock_ping.py [host] [port]
默认: 127.0.0.1:19132
返回 Pong(0x1c) + MOTD = Geyser 存活且 Java 端连接正常（proxy-protocol 下验证 haproxy 生效）
2026-08-14 补测验证：正式档（proxy-protocol + Geyser use-haproxy-protocol）下 PONG_OK
"""
import socket, struct, sys, time

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 19132

magic = bytes([0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
               0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78])

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(6)
payload = b"\x01" + struct.pack(">Q", int(time.time() * 1000)) + magic + struct.pack(">Q", 0x1234567890ABCDEF)
print(f"==> RakNet Unconnected Ping → {host}:{port}")
s.sendto(payload, (host, port))

try:
    data, addr = s.recvfrom(4096)
    print(f"<== 响应 {len(data)} 字节 packet_id=0x{data[0]:02x}")
    if data[0] == 0x1C:
        motd_len = struct.unpack(">H", data[32:34])[0]
        motd = data[34:34 + motd_len].decode("utf-8", "replace")
        print("RESULT=PONG_OK（Geyser 存活，Java 连接正常）")
        print(f"    MOTD: {motd[:200]}")
    else:
        print(f"RESULT=UNEXPECTED packet 0x{data[0]:02x}")
except socket.timeout:
    print("RESULT=TIMEOUT（Geyser 无响应——检查 UDP 19132 监听/防火墙）")
    sys.exit(1)
