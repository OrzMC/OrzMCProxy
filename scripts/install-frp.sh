#!/usr/bin/env bash
# OrzMCProxy - 一键安装 frps/frpc（Linux / macOS，x86_64 / arm64），支持多实例
# 用法: sudo bash install-frp.sh frps|frpc [name]
#   name 默认 default；多中转机→单服务时用不同 name 装多个 frpc 实例
# 环境变量: FRP_VERSION(默认0.70.1) GH_MIRROR(下载镜像前缀) INSTALL_DIR CONFIG_DIR SKIP_SERVICE(1=跳过服务注册,CI测试用)
set -euo pipefail

ROLE="${1:-frpc}"
NAME="${2:-default}"
case "$ROLE" in
  frps|frpc) ;;
  *) echo "用法: $0 frps|frpc [name]"; exit 1 ;;
esac

FRP_VERSION="${FRP_VERSION:-0.70.1}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BASE_URL="${GH_MIRROR:-https://github.com/fatedier/frp/releases/download}"

# ---------- 检测 OS / 架构 ----------
OS="$(uname -s)"
case "$OS" in
  Darwin) OS_KIND="darwin";  CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/orzmcproxy}"; LOG_DIR="/usr/local/var/log/orzmcproxy" ;;
  Linux)  OS_KIND="linux";   CONFIG_DIR="${CONFIG_DIR:-/etc/orzmcproxy}";           LOG_DIR="/var/log/orzmcproxy" ;;
  *) echo "❌ 不支持的 OS: ${OS}（本脚本支持 Linux/macOS；Windows 用 install-frp.ps1）"; exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH_KIND="amd64" ;;
  arm64|aarch64) ARCH_KIND="arm64" ;;
  *) echo "❌ 不支持的架构: ${ARCH}"; exit 1 ;;
esac

CFG="${CONFIG_DIR}/${ROLE}-${NAME}.toml"
LOG_FILE="${LOG_DIR}/${ROLE}-${NAME}.log"

echo "==> 检测: ${OS} ${ARCH} | frp v${FRP_VERSION} (${OS_KIND}_${ARCH_KIND}) | 角色: ${ROLE} | 实例: ${NAME}"

# ---------- 下载并解压（二进制共享，只装一份） ----------
if [ ! -f "${INSTALL_DIR}/${ROLE}" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  FILE="frp_${FRP_VERSION}_${OS_KIND}_${ARCH_KIND}.tar.gz"
  URL="${BASE_URL}/v${FRP_VERSION}/${FILE}"
  echo "==> 下载 ${URL}"
  curl -fL --retry 3 -o "${TMP}/${FILE}" "${URL}"
  tar -xzf "${TMP}/${FILE}" -C "${TMP}"
  SRC="${TMP}/frp_${FRP_VERSION}_${OS_KIND}_${ARCH_KIND}"
  echo "==> 安装 ${ROLE} → ${INSTALL_DIR}/${ROLE}"
  mkdir -p "${INSTALL_DIR}"
  install -m 0755 "${SRC}/${ROLE}" "${INSTALL_DIR}/${ROLE}"
else
  echo "==> 二进制 ${INSTALL_DIR}/${ROLE} 已存在，跳过下载"
fi

# ---------- 生成配置模板（按实例隔离） ----------
mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"
if [ ! -f "${CFG}" ]; then
  echo "==> 生成配置模板 ${CFG}（⚠️ 请修改 token/地址后重启服务）"
  if [ "${ROLE}" = "frps" ]; then
    cat > "${CFG}" <<EOF
# OrzMCProxy frps 配置（实例: ${NAME}，请修改后重启）
bindPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"
allowPorts = [
  { start = 25565, end = 25565 },
]
log.to = "${LOG_FILE}"
log.level = "info"
EOF
  else
    cat > "${CFG}" <<EOF
# OrzMCProxy frpc 配置（实例: ${NAME}，请修改后重启）
serverAddr = "CHANGE_ME_RELAY_IP"
serverPort = 7000
auth.method = "token"
auth.token = "CHANGE_ME_STRONG_TOKEN"
log.to = "${LOG_FILE}"
log.level = "info"

[[proxies]]
name = "mc-java-main"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25565
remotePort = 25565

[proxies.transport]
proxyProtocolVersion = "v2"
EOF
  fi
else
  echo "==> 已存在 ${CFG}，跳过生成（如需重置请先删除）"
fi

# ---------- 注册守护服务（按实例） ----------
if [ "${SKIP_SERVICE:-0}" = "1" ]; then
  echo "==> SKIP_SERVICE=1，跳过服务注册（CI/测试模式）"
elif [ "${OS_KIND}" = "linux" ]; then
  # systemd 模板单元: frpc@default.service / frpc@relay-b.service（%i = 实例名）
  cat > "/etc/systemd/system/${ROLE}@.service" <<EOF
[Unit]
Description=OrzMCProxy ${ROLE} %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${ROLE} -c ${CONFIG_DIR}/${ROLE}-%i.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${ROLE}@${NAME}"
  echo "✅ 已注册并启动 systemd 服务: ${ROLE}@${NAME}"
  systemctl --no-pager status "${ROLE}@${NAME}" | head -5 || true
else
  # macOS LaunchDaemon（按实例生成 plist）
  PLIST="/Library/LaunchDaemons/com.orzmc.${ROLE}-${NAME}.plist"
  cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.orzmc.${ROLE}-${NAME}</string>
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
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
EOF
  launchctl unload "${PLIST}" 2>/dev/null || true
  launchctl load "${PLIST}"
  echo "✅ 已注册并启动 LaunchDaemon: ${PLIST}"
fi

echo ""
echo "🎉 安装完成！实例: ${ROLE}-${NAME}"
echo "  1. 编辑 ${CFG} 修改配置"
echo "  2. 重启服务: systemctl restart ${ROLE}@${NAME}   (macOS: launchctl unload/load ${PLIST:-/Library/LaunchDaemons/com.orzmc.${ROLE}-${NAME}.plist})"
echo "  3. 验证: bash verify-tunnel.sh <中转机IP> 25565"
echo ""
echo "多实例提示: 再装一台中转机执行 sudo bash install-frp.sh ${ROLE} <别名>"
