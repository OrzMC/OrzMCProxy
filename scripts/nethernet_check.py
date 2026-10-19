#!/usr/bin/env python3
"""NetherNet（基岩新传输层）连通性探测 — 与 RakNet 对照

NetherNet 与 RakNet 的关键差别：
  · RakNet  : 只需 UDP（游戏流量直连）
  · NetherNet: UDP（WebRTC 游戏流量） + **TCP（HTTP/HTTPS 信令）**
    玩家先走 TCP 向服务器「信令」询问怎么连，再走 UDP/WebRTC 传游戏流量；
    MOTD / 在线人数 也从信令获取。

因此判断「NetherNet 是否可用」= ① UDP RakNet 是否应答（现状基线）
                              ② **TCP 信令端口是否可连且返回 HTTP**

用法:
  python3 nethernet_check.py                       # 本机 127.0.0.1:19132
  python3 nethernet_check.py dev.jokerhub.cn       # 远程 19132
  python3 nethernet_check.py dev.jokerhub.cn 19133
  python3 nethernet_check.py -h | --help

退出码: 0 = NetherNet 信令可用；1 = 信令不可用（或仅 RakNet 可用）
"""
import socket
import struct
import sys
import time
import re
import ssl

MAGIC = bytes([0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
               0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78])


def help_text():
    print(__doc__)


def raknet_ping(host, port, timeout=6):
    """RakNet Unconnected Ping → (ok, motd_or_reason, elapsed_ms)"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    payload = b"\x01" + struct.pack(">Q", int(time.time() * 1000)) + MAGIC + struct.pack(">Q", 0x1234567890ABCDEF)
    t0 = time.time()
    try:
        s.sendto(payload, (host, port))
        data, _ = s.recvfrom(2048)
        ms = int((time.time() - t0) * 1000)
        if data and data[0] == 0x1C:
            # Pong: id(1)+time(8)+guid(8)+magic(16)+len(2)+motd
            try:
                ln = struct.unpack(">H", data[33:35])[0]
                motd = data[35:35 + ln].decode("utf-8", "replace")
            except Exception:
                motd = ""
            return True, motd, ms
        return False, f"非 Pong 响应 packet_id=0x{data[0]:02x}", ms
    except socket.timeout:
        return False, "超时（无应答）", int((time.time() - t0) * 1000)
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}", int((time.time() - t0) * 1000)
    finally:
        s.close()


def tcp_probe(host, port, timeout=8):
    """TCP 连接 + 尝试 HTTP(S) GET 信令根路径 → (state, detail)"""
    t0 = time.time()
    try:
        s = socket.create_connection((host, port), timeout=timeout)
    except socket.timeout:
        return "TIMEOUT", "TCP 连接超时（可能被防火墙静默丢弃）"
    except ConnectionRefusedError:
        return "REFUSED", "TCP 连接被拒绝（端口未监听 / NetherNet 信令未启用）"
    except Exception as exc:
        return "ERROR", f"{type(exc).__name__}: {exc}"
    try:
        s.settimeout(timeout)
        try:
            s.sendall(b"GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                      % host.encode())
            raw = s.recv(512)
        except socket.timeout:
            return "OPEN_NO_HTTP", "TCP 可连但 8s 内无 HTTP 响应（非信令服务？）"
        except Exception as exc:
            return "OPEN_NO_HTTP", f"TCP 可连但读取失败：{type(exc).__name__}"
        ms = int((time.time() - t0) * 1000)
        if not raw:
            return "OPEN_NO_HTTP", "TCP 可连但服务端立即关闭（无 HTTP 响应）"
        text = raw.decode("latin-1", "replace")
        first = text.splitlines()[0] if text else ""
        m = re.match(r"HTTP/\d\.\d\s+(\d{3})", first)
        if m:
            code = m.group(1)
            body_hint = text[text.find("\r\n\r\n") + 4:][:120].strip() if "\r\n\r\n" in text else ""
            return "HTTP", f"HTTP {code}（{ms}ms）{('· ' + body_hint) if body_hint else ''}"
        # 非 HTTP 但端口有应答（例如 NetherNet 信令的私有协议）
        return "OPEN_RAW", f"有 {len(raw)} 字节非 HTTP 应答（可能为私有信令协议）：{text[:80]!r}"
    finally:
        s.close()


def main():
    args = [a for a in sys.argv[1:]]
    if any(a in ("-h", "--help") for a in args):
        help_text()
        return 0
    host = args[0] if args and not args[0].isdigit() else "127.0.0.1"
    port = int(args[1]) if len(args) > 1 else (int(args[0]) if args and args[0].isdigit() else 19132)

    print("=" * 46)
    print(f"NetherNet 连通性探测  {host}:{port}")
    print("=" * 46)

    # 0. 解析
    try:
        ip = socket.gethostbyname(host)
        print(f"[0] 域名解析        {host} → {ip}")
    except Exception as exc:
        print(f"[0] 域名解析失败     {exc}")
        return 1

    # 1. RakNet（旧通道基线）
    ok_rak, motd, ms = raknet_ping(ip, port)
    if ok_rak:
        print(f"[1] RakNet(UDP)      ✅ 应达（{ms}ms）")
        if motd:
            print(f"                     MOTD: {motd[:110]}")
    else:
        print(f"[1] RakNet(UDP)      ❌ {motd}（{ms}ms）")

    # 2. NetherNet 信令（TCP，默认与 bedrock 端口同号）
    state, detail = tcp_probe(ip, port)
    icon = {"HTTP": "✅", "OPEN_RAW": "🟡"}.get(state, "❌")
    print(f"[2] NetherNet 信令   {icon} TCP {port} → {state}")
    print(f"                     {detail}")

    # 3. 结论
    print("-" * 46)
    if state in ("HTTP", "OPEN_RAW"):
        print("结论: NetherNet 信令端口可用（TCP 已放通且服务有应答）")
        rc = 0
    else:
        print("结论: NetherNet 信令不可用 → 基岩玩家 10-27 后将无法连接")
        print("      需: ① Geyser config bedrock.transport=nethernet|both")
        print("          ② 该端口 TCP 放通（docker 端口映射 + 路由器/防火墙）")
        rc = 1
    if ok_rak and state not in ("HTTP", "OPEN_RAW"):
        print("      注: 当前 RakNet 通道仍正常，10-27 前必须完成切换")
    return rc


if __name__ == "__main__":
    sys.exit(main())
