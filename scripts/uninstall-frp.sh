#!/usr/bin/env bash
# OrzMCProxy - 卸载 frps/frpc（Linux / macOS），支持多实例
# 用法: sudo bash uninstall-frp.sh [frps|frpc] [name] [--purge]
#   name 默认 default；--purge 连配置一起删（二进制仅当无其他实例引用时删）
set -uo pipefail

ROLE="${1:-frpc}"
NAME="${2:-default}"
PURGE="0"
[ "${3:-}" = "--purge" ] && PURGE="1"
case "$ROLE" in frps|frpc) ;; *) echo "用法: $0 [frps|frpc] [name] [--purge]"; exit 1 ;; esac

OS="$(uname -s)"
if [ "${OS}" = "Linux" ]; then
  CONFIG_DIR="/etc/orzmcproxy"
  LOG_DIR="/var/log/orzmcproxy"
else
  CONFIG_DIR="/usr/local/etc/orzmcproxy"
  LOG_DIR="/usr/local/var/log/orzmcproxy"
fi

# 1. 停服务（按实例）
if [ "${OS}" = "Linux" ]; then
  systemctl disable --now "${ROLE}@${NAME}" 2>/dev/null || true
else
  PLIST="/Library/LaunchDaemons/com.orzmc.${ROLE}-${NAME}.plist"
  launchctl unload "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}"
fi
echo "✅ 已停止服务: ${ROLE}@${NAME}"

# 2. 配置/日志（可选）
CFG="${CONFIG_DIR}/${ROLE}-${NAME}.toml"
LOG_FILE="${LOG_DIR}/${ROLE}-${NAME}.log"
if [ "${PURGE}" = "1" ]; then
  rm -f "${CFG}" "${LOG_FILE}"
  # 模板单元仅当该角色无任何实例配置时删除
  if ! ls "${CONFIG_DIR}/${ROLE}-"*.toml >/dev/null 2>&1; then
    rm -f "/etc/systemd/system/${ROLE}@.service" 2>/dev/null || true
    rm -f "/usr/local/bin/${ROLE}"
    echo "✅ 模板单元与二进制 ${ROLE} 已清除（无其他实例引用）"
  else
    echo "ℹ️  检测到其他实例配置，保留共享二进制 ${ROLE}"
  fi
  rmdir "${CONFIG_DIR}" "${LOG_DIR}" 2>/dev/null || true
  echo "✅ 配置与日志已清除（--purge）"
else
  echo "ℹ️  配置保留（如需清除加 --purge）"
fi
echo "🎉 卸载完成"
