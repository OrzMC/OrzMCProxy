#!/usr/bin/env bash
# OrzMCProxy - 卸载 frps/frpc（Linux / macOS）
# 用法: sudo bash uninstall-frp.sh [frps|frpc] [--purge]
#   --purge: 连配置一起删除（默认保留配置）
set -uo pipefail

ROLE="${1:-frpc}"
PURGE="0"
[ "${2:-}" = "--purge" ] && PURGE="1"
case "$ROLE" in frps|frpc) ;; *) echo "用法: $0 [frps|frpc] [--purge]"; exit 1 ;; esac

OS="$(uname -s)"

# 1. 停服务
if [ "${OS}" = "Linux" ]; then
  systemctl disable --now "${ROLE}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${ROLE}.service"
  systemctl daemon-reload
else
  PLIST="/Library/LaunchDaemons/com.orzmc.${ROLE}.plist"
  launchctl unload "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}"
fi

# 2. 删二进制
rm -f "/usr/local/bin/${ROLE}"
echo "✅ 已停止服务并删除 /usr/local/bin/${ROLE}"

# 3. 配置（可选）
if [ "${PURGE}" = "1" ]; then
  CONFIG_DIR="/etc/orzmcproxy"
  [ "${OS}" = "Darwin" ] && CONFIG_DIR="/usr/local/etc/orzmcproxy"
  rm -f "${CONFIG_DIR}/${ROLE}.toml"
  rmdir "${CONFIG_DIR}" 2>/dev/null || true
  rm -rf /usr/local/var/log/orzmcproxy 2>/dev/null || true
  echo "✅ 配置与日志已清除（--purge）"
else
  echo "ℹ️  配置保留（如需清除加 --purge）"
fi
echo "🎉 卸载完成"
