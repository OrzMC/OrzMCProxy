#!/usr/bin/env bash
# OrzMCProxy - 一键安装 frps/frpc（Linux / macOS，x86_64 / arm64）
# 用法: sudo bash install-frp.sh frps|frpc
# 环境变量: FRP_VERSION(默认0.70.1) GH_MIRROR(下载镜像前缀) INSTALL_DIR CONFIG_DIR
set -euo pipefail

ROLE="${1:-frpc}"
case "$ROLE" in
  frps|frpc) ;;
  *) echo "用法: $0 frps|frpc"; exit 1 ;;
esac

FRP_VERSION="${FRP_VERSION:-0.70.1}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BASE_URL="${GH_MIRROR:-https://github.com/fatedier/frp/releases/download}"

# ---------- 检测 OS / 架构 ----------
OS="$(uname -s)"
case "$OS" in
  Darwin) OS_KIND="darwin";  CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/orzmcproxy}" ;;
  Linux)  OS_KIND="linux";   CONFIG_DIR="${CONFIG_DIR:-/etc/orzmcproxy}" ;;
  *) echo "❌ 不支持的 OS: ${OS}（本脚本支持 Linux/macOS；Windows 用 install-frp.ps1）"; exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH_KIND="amd64" ;;
  arm64|aarch64) ARCH_KIND="arm64" ;;
  *) echo "❌ 不支持的架构: ${ARCH}"; exit 1 ;;
esac

echo "==> 检测: ${OS} ${ARCH} | frp v${FRP_VERSION} (${OS_KIND}_${ARCH_KIND}) | 角色: ${ROLE}"

# ---------- 下载并解压 ----------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FILE="frp_${FRP_VERSION}_${OS_KIND}_${ARCH_KIND}.tar.gz"
URL="${BASE_URL}/v${FRP_VERSION}/${FILE}"
echo "==> 下载 ${URL}"
curl -fL --retry 3 -o "${TMP}/${FILE}" "${URL}"
tar -xzf "${TMP}/${FILE}" -C "${TMP}"
SRC="${TMP}/frp_${FRP_VERSION}_${OS_KIND}_${ARCH_KIND}"

# ---------- 安装二进制 ----------
echo "==> 安装 ${ROLE} → ${INSTALL_DIR}/${ROLE}"
mkdir -p "${INSTALL_DIR}"
install -m 0755 "${SRC}/${ROLE}" "${INSTALL_DIR}/${ROLE}"

# ---------- 生成配置模板 ----------
mkdir -p "${CONFIG_DIR}"
CFG="${CONFIG_DIR}/${ROLE}.toml"
if [ ! -f "${CFG}" ]; then
  echo "==> 生成配置模板 ${CFG}（⚠️ 请修改 token/地址后重启服务）"
  if [ "${ROLE}" = "frps" ]; then
    cat > "${CFG}" <<'EOF'
# OrzMCProxy frps 配置（自动生成，请修改后重启）
bindPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"
allowPorts = [
  { start = 25565, end = 25566 },
]
EOF
  else
    cat > "${CFG}" <<'EOF'
# OrzMCProxy frpc 配置（自动生成，请修改后重启）
serverAddr = "CHANGE_ME_RELAY_IP"
serverPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"

[[proxies]]
name = "mc-java-main"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25565
remotePort = 25565

[[proxies]]
name = "mc-java-second"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25566
remotePort = 25566
EOF
  fi
else
  echo "==> 已存在 ${CFG}，跳过生成（如需重置请先删除）"
fi

# ---------- 注册守护服务 ----------
if [ "${OS_KIND}" = "linux" ]; then
  cat > "/etc/systemd/system/${ROLE}.service" <<EOF
[Unit]
Description=OrzMCProxy ${ROLE}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${ROLE} -c ${CFG}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${ROLE}"
  echo "✅ 已注册并启动 systemd 服务: ${ROLE}"
  systemctl --no-pager status "${ROLE}" | head -5 || true
else
  # macOS: LaunchDaemon
  mkdir -p /Library/LaunchDaemons /usr/local/var/log/orzmcproxy
  PLIST="/Library/LaunchDaemons/com.orzmc.${ROLE}.plist"
  cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.orzmc.${ROLE}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${ROLE}</string>
        <string>-c</string>
        <string>${CFG}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/usr/local/var/log/orzmcproxy/${ROLE}.log</string>
    <key>StandardErrorPath</key>
    <string>/usr/local/var/log/orzmcproxy/${ROLE}.log</string>
</dict>
</plist>
EOF
  launchctl unload "${PLIST}" 2>/dev/null || true
  launchctl load "${PLIST}"
  echo "✅ 已注册并启动 LaunchDaemon: ${PLIST}"
fi

echo ""
echo "🎉 安装完成！下一步："
echo "  1. 编辑 ${CFG} 修改配置"
echo "  2. 重启服务: systemctl restart ${ROLE}   (macOS: launchctl unload/load ${PLIST})"
echo "  3. 验证: bash verify-tunnel.sh <中转机IP> 25565"
