#!/usr/bin/env python3
"""NetherNet（基岩新传输层）连通性探测 — 与 RakNet 对照

NetherNet 与 RakNet 的关键差别：
  · RakNet  : 只需 UDP（游戏流量直连）
  · NetherNet: UDP（WebRTC 游戏流量） + **TCP（HTTP/HTTPS 信令）**
    玩家先走 TCP 向服务器「信令」询问怎么连，再走 UDP/WebRTC 传游戏流量；
    MOTD / 在线人数 也从信令获取。

因此判断「NetherNet 是否可用」= ① UDP RakNet 是否应答（现状基线）
                              ② TCP 信令端口是否可连且返回 HTTP 应答

用法:
  python3 nethernet_check.py                          # 本机 127.0.0.1:19132
  python3 nethernet_check.py dev.jokerhub.cn          # 远程 19132
  python3 nethernet_check.py dev.jokerhub.cn 19133
  python3 nethernet_check.py dev.jokerhub.cn --signal-port 8080 --scheme http
  python3 nethernet_check.py dev.jokerhub.cn --json   # 机器可读
  python3 nethernet_check.py --self-test              # 自检（Pong 解析回归）
  python3 nethernet_check.py -h | --help

退出码:
  0 = 信令可用（TCP 返回 HTTP 2xx/4xx）
  1 = 不可达（UDP/TCP 超时、拒绝、连接错误、DNS 失败）
  2 = 用法/参数错误（含端口、超时非法）
  3 = 降级待确认（私有协议应答 / HTTP 3xx、5xx / TCP 通但无 HTTP 应答）

注意: 本机若开着 Clash 等 TUN 代理，任何 TCP 探测都可能被本地栈接管（域名被
fake-IP 成 198.18.x），表现为「TCP 能连但立即关闭」→ 请以外部节点结论为准。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import struct
import sys
import time

__version__ = "1.1.0"

MAGIC = bytes([0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
               0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78])

EXIT_OK = 0
EXIT_UNREACHABLE = 1
EXIT_USAGE = 2
EXIT_DEGRADED = 3

# 状态 → (人类可读含义, 退出码)
STATE_MAP = {
    "HTTP_OK": ("HTTP 应答（信令服务在线）", EXIT_OK),
    "HTTP_5XX": ("HTTP 5xx（服务端异常，需确认）", EXIT_DEGRADED),
    "HTTP_3XX": ("HTTP 3xx（重定向，未验证目标）", EXIT_DEGRADED),
    "OPEN_RAW": ("TCP 有非 HTTP 应答（私有协议？需人工确认）", EXIT_DEGRADED),
    "OPEN_NO_HTTP": ("TCP 可连但无 HTTP 应答（本机代理常见假象）", EXIT_DEGRADED),
    "REFUSED": ("TCP 被拒绝（端口未监听/信令未启用）", EXIT_UNREACHABLE),
    "TIMEOUT": ("TCP 超时（端口未转发或被丢弃）", EXIT_UNREACHABLE),
    "ERROR": ("TCP 连接错误", EXIT_UNREACHABLE),
}

EMOJI = {"OK": "✅", "WARN": "🟡", "FAIL": "❌", "INFO": "▪"}


class Out:
    """输出封装：支持 --no-emoji 与非 UTF-8 终端的 ASCII 降级"""

    def __init__(self, no_emoji=False, ascii_only=False):
        self.no_emoji = no_emoji or ascii_only

    def icon(self, kind):
        if self.no_emoji:
            return {"OK": "[OK]", "WARN": "[WARN]", "FAIL": "[FAIL]", "INFO": "[i]"}[kind]
        return EMOJI[kind]

    def line(self, text=""):
        if self.no_emoji:
            text = text.replace("→", "->").replace("·", "-").replace("✅", "[OK]") \
                       .replace("❌", "[FAIL]").replace("🟡", "[WARN]")
        print(text)


def _configure_stdout():
    """Windows/Git Bash 重定向时避免 UnicodeEncodeError"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


def _is_ascii_stdout():
    enc = (getattr(sys.stdout, "encoding", "") or "").lower()
    return bool(enc) and "utf" not in enc


def resolve_ipv4(host):
    """返回 IPv4 字符串；失败抛 socket.gaierror"""
    try:
        infos = socket.getaddrinfo(host, None, family=socket.AF_INET, type=socket.SOCK_DGRAM)
        if infos:
            return infos[0][4][0]
    except socket.gaierror:
        raise
    return socket.gethostbyname(host)


def parse_raknet_pong(data):
    """解析 RakNet Unconnected Pong → (ok, motd, reason)

    布局: id(1) + time(8) + guid(8) + magic(16) + len(2) + motd(len)
    长度字段不可靠（部分实现写错），故 len 越界时回退到包尾。
    """
    if not data:
        return False, "", "空数据报"
    if len(data) < 35:
        return False, "", f"包过短（{len(data)}B，期望 ≥35）"
    if data[0] != 0x1C:
        return False, "", f"非 Pong 响应 packet_id=0x{data[0]:02x}"
    if data[17:33] != MAGIC:
        return False, "", "MAGIC 校验失败（响应可能来自非 RakNet 服务）"
    declared = struct.unpack(">H", data[33:35])[0]
    body = data[35:]
    if declared and declared <= len(body):
        body = body[:declared]
    motd = body.decode("utf-8", "replace").rstrip("\x00")
    return True, motd, ""


def raknet_ping(ip, port, timeout=6.0):
    """RakNet Unconnected Ping → (ok, motd, elapsed_ms, reason)"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    guid = struct.pack(">Q", int.from_bytes(os.urandom(8), "big"))
    payload = (b"\x01" + struct.pack(">Q", int(time.time() * 1000)) + MAGIC + guid)
    t0 = time.time()
    try:
        s.settimeout(timeout)          # 放进 try：非法超时值不应崩出 traceback
        s.connect((ip, port))          # 锁定对端，避免任意来源注入响应
        s.send(payload)
        data = s.recv(4096)
        ms = int((time.time() - t0) * 1000)
        ok, motd, reason = parse_raknet_pong(data)
        return ok, motd, ms, reason
    except socket.timeout:
        return False, "", int((time.time() - t0) * 1000), "超时（无应答）"
    except Exception as exc:                                   # noqa: BLE001
        return False, "", int((time.time() - t0) * 1000), f"{type(exc).__name__}: {exc}"
    finally:
        s.close()


def _read_http_head(sock, limit=4096):
    """读到头部结束（\\r\\n\\r\\n）或上限 → bytes"""
    buf = b""
    while len(buf) < limit:
        chunk = sock.recv(1024)
        if not chunk:
            break
        buf += chunk
        if b"\r\n\r\n" in buf:
            break
    return buf


def tcp_probe(ip, port, timeout=8.0, scheme="http", sni_host=None, no_verify=True):
    """TCP 连接 + HTTP(S) 探测 → (state, detail)"""
    host_header = sni_host or ip
    t0 = time.time()
    raw = None
    try:
        sock = socket.create_connection((ip, port), timeout=timeout)
    except socket.timeout:
        return "TIMEOUT", "TCP 连接超时（可能被防火墙静默丢弃/端口未转发）"
    except ConnectionRefusedError:
        return "REFUSED", "TCP 连接被拒绝（端口未监听 / NetherNet 信令未启用）"
    except Exception as exc:                                   # noqa: BLE001
        return "ERROR", f"{type(exc).__name__}: {exc}"

    try:
        sock.settimeout(timeout)
        if scheme == "https":
            ctx = ssl.create_default_context()
            if no_verify:          # 诊断用途：允许自签证书
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(sock, server_hostname=host_header)
        req = ("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: orzmc-nethernet-check/%s\r\n"
               "Connection: close\r\n\r\n" % (host_header, __version__)).encode()
        sock.sendall(req)
        raw = _read_http_head(sock)
    except socket.timeout:
        return "OPEN_NO_HTTP", f"TCP 可连但 {int(timeout)}s 内无应答（非 HTTP 服务？本机代理？）"
    except (ssl.SSLError, ssl.SSLEOFError) as exc:
        return "OPEN_NO_HTTP", f"TLS 握手失败：{type(exc).__name__}（信令可能是明文 HTTP）"
    except Exception as exc:                                   # noqa: BLE001
        return "OPEN_NO_HTTP", f"TCP 可连但读取失败：{type(exc).__name__}"
    finally:
        try:
            sock.close()
        except Exception:
            pass

    ms = int((time.time() - t0) * 1000)
    if not raw:
        return "OPEN_NO_HTTP", "TCP 可连但服务端立即关闭（无 HTTP 应答；本机代理常见假象）"
    text = raw.decode("latin-1", "replace")
    first = text.splitlines()[0] if text else ""
    if first.startswith("HTTP/"):
        parts = first.split()
        code = parts[1] if len(parts) > 1 else "???"
        body = text.split("\r\n\r\n", 1)[1][:120].strip() if "\r\n\r\n" in text else ""
        detail = f"HTTP {code}（{ms}ms）" + (f" · {body}" if body else "")
        if code.startswith("2") or code.startswith("4"):
            return "HTTP_OK", detail
        if code.startswith("5"):
            return "HTTP_5XX", detail
        return "HTTP_3XX", detail
    return "OPEN_RAW", f"有 {len(raw)} 字节非 HTTP 应答（可能为私有信令协议）：{text[:60]!r}"


def self_test(out):
    """Pong 解析回归自检（固定字节串）"""
    motd = b"MCPE;Geyser;2193;26.52;0;100;123;Test;Survival;1;19132;19132;"
    pong = b"\x1c" + struct.pack(">Q", 0) + struct.pack(">Q", 42) + MAGIC \
        + struct.pack(">H", len(motd)) + motd
    cases = [
        ("正常 Pong", pong, True),
        ("空包", b"", False),
        ("过短", b"\x1c\x00\x01", False),
        ("错 id", b"\x1d" + pong[1:], False),
        ("MAGIC 错", pong[:17] + b"\x00" * 16 + pong[33:], False),
        ("长度字段越界（应回退包尾）", pong[:33] + struct.pack(">H", 9999) + pong[35:], True),
    ]
    failed = 0
    for name, data, expect in cases:
        ok, parsed, reason = parse_raknet_pong(data)
        good = (ok == expect) and (not ok or parsed.startswith("MCPE;"))
        out.line(f"  {out.icon('OK') if good else out.icon('FAIL')} {name}: ok={ok} "
                 f"{'MOTD='+parsed[:40] if ok else reason}")
        failed += 0 if good else 1
    out.line(f"自检结果: {'通过' if failed == 0 else '失败 %d 项' % failed}")
    return EXIT_OK if failed == 0 else EXIT_UNREACHABLE


def build_parser():
    p = argparse.ArgumentParser(
        prog="nethernet_check.py",
        description="NetherNet（基岩新传输层）连通性探测：UDP RakNet 基线 + TCP 信令 HTTP(S) 探测",
        epilog="退出码: 0=信令可用 / 1=不可达 / 2=用法错误 / 3=降级待确认",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("host", nargs="?", default="127.0.0.1", help="目标域名或 IP（默认 127.0.0.1）")
    p.add_argument("port", nargs="?", type=int, default=19132, help="基岩端口（默认 19132）")
    p.add_argument("--signal-port", type=int, default=None,
                   help="信令 TCP 端口（默认与基岩端口相同）")
    p.add_argument("--scheme", choices=["http", "https"], default="http",
                   help="信令协议，默认 http；HTTPS 不校验证书（诊断用途）")
    p.add_argument("--timeout", type=float, default=8.0, help="单步超时秒数（默认 8）")
    p.add_argument("--json", action="store_true", help="以 JSON 输出结果")
    p.add_argument("--no-emoji", action="store_true", help="纯 ASCII 输出（Windows/cron 友好）")
    p.add_argument("--self-test", action="store_true", help="运行 Pong 解析自检后退出")
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)          # 用法错误 → argparse 自动 exit 2
    out = Out(no_emoji=args.no_emoji, ascii_only=_is_ascii_stdout())

    if args.self_test:
        return self_test(out)

    if not (1 <= args.port <= 65535):
        out.line(f"参数错误: 端口需在 1-65535 之间（当前 {args.port}）")
        return EXIT_USAGE
    if args.signal_port is not None and not (1 <= args.signal_port <= 65535):
        out.line(f"参数错误: --signal-port 需在 1-65535 之间（当前 {args.signal_port}）")
        return EXIT_USAGE
    if not (0 < args.timeout <= 300):
        out.line(f"参数错误: --timeout 需在 (0, 300] 秒之间（当前 {args.timeout}）")
        return EXIT_USAGE

    signal_port = args.signal_port if args.signal_port is not None else args.port
    result = {"tool": "nethernet_check", "version": __version__, "host": args.host,
              "bedrock_port": args.port, "signal_port": signal_port, "scheme": args.scheme}

    if not args.json:
        out.line("=" * 46)
        out.line(f"NetherNet 连通性探测  {args.host}:{args.port}（信令 {args.scheme}://{args.host}:{signal_port}）")
        out.line("=" * 46)

    # 0. 解析
    try:
        ip = resolve_ipv4(args.host)
    except Exception as exc:                                   # noqa: BLE001
        result.update({"resolved": None, "error": f"DNS: {exc}", "exit": EXIT_UNREACHABLE})
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=1))
        else:
            out.line(f"{out.icon('FAIL')} [0] 域名解析失败: {exc}")
        return EXIT_UNREACHABLE
    result["resolved"] = ip
    if not args.json:
        out.line(f"{out.icon('INFO')} [0] 域名解析        {args.host} → {ip}")

    # 1. RakNet（旧通道基线）
    ok_rak, motd, ms, reason = raknet_ping(ip, args.port, timeout=min(6.0, args.timeout))
    result["raknet"] = {"ok": ok_rak, "motd": motd, "elapsed_ms": ms, "reason": reason}
    if not args.json:
        if ok_rak:
            out.line(f"{out.icon('OK')} [1] RakNet(UDP)      ✅ 应答（{ms}ms）")
            if motd:
                out.line(f"                     MOTD: {motd[:110]}")
        else:
            out.line(f"{out.icon('FAIL')} [1] RakNet(UDP)      ❌ {reason}（{ms}ms）")

    # 2. NetherNet 信令（TCP）
    state, detail = tcp_probe(ip, signal_port, timeout=args.timeout,
                              scheme=args.scheme, sni_host=args.host)
    meaning, rc = STATE_MAP.get(state, ("未知状态", EXIT_UNREACHABLE))
    result["signaling"] = {"state": state, "detail": detail, "meaning": meaning}
    result["exit"] = rc
    if not args.json:
        icon = {"HTTP_OK": "OK", "HTTP_3XX": "WARN", "OPEN_RAW": "WARN",
                "HTTP_5XX": "WARN", "OPEN_NO_HTTP": "WARN"}.get(state, "FAIL")
        out.line(f"{out.icon(icon)} [2] NetherNet 信令   TCP {signal_port} → {state}")
        out.line(f"                     {detail}")

        # 3. 结论
        out.line("-" * 46)
        if rc == EXIT_OK:
            out.line(f"结论: {meaning} → 信令端口可用")
        elif rc == EXIT_DEGRADED:
            out.line(f"结论: {meaning} → 需人工确认（不要直接判为可用）")
        else:
            out.line(f"结论: {meaning} → 基岩玩家 10-27 后将无法连接")
            out.line("      需: ① Geyser config bedrock.transport=nethernet|both")
            out.line("          ② 该端口 TCP 放通（docker 端口映射 + 路由器/防火墙）")
        if ok_rak and rc != EXIT_OK:
            out.line("      注: 当前 RakNet 通道仍正常，10-27 前必须完成切换")
        if state in ("OPEN_NO_HTTP", "OPEN_RAW") and rc == EXIT_DEGRADED:
            out.line("      注: 本机开着 Clash 等 TUN 代理时 TCP 结论不可信 → 用外部节点复核")
    else:
        print(json.dumps(result, ensure_ascii=False, indent=1))
    return rc


if __name__ == "__main__":
    _configure_stdout()
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(EXIT_UNREACHABLE)
