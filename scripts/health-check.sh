#!/usr/bin/env bash
# OrzMCProxy - 健康检查（frps/frpc 进程、隧道状态、日志尾部）
# 用法: health-check.sh [frps|frpc]
set -uo pipefail

ROLE="${1:-frpc}"
case "$ROLE" in frps|frpc) ;; *) echo "用法: $0 [frps|frpc]"; exit 1 ;; esac

echo "==== OrzMCProxy ${ROLE} 健康检查 ===="

# 1. 进程
PID="$(pgrep -f "${INSTALL_DIR:-/usr/local/bin}/${ROLE}" | head -1 || true)"
if [ -z "${PID}" ]; then
  PID="$(pgrep -x "${ROLE}" | head -1 || true)"
fi
if [ -n "${PID}" ]; then
  echo "✅ 进程运行中 (PID ${PID})"
else
  echo "❌ 进程未运行"
fi

# 2. 守护服务状态
OS="$(uname -s)"
if [ "${OS}" = "Linux" ]; then
  systemctl is-active "${ROLE}" 2>/dev/null | sed 's/^/systemd: /'
  echo "--- systemd 最近 5 行 ---"
  journalctl -u "${ROLE}" -n 5 --no-pager 2>/dev/null || true
elif [ "${OS}" = "Darwin" ]; then
  launchctl list | grep "com.orzmc.${ROLE}" || echo "launchd: 未找到 com.orzmc.${ROLE}"
  echo "--- 日志尾部 ---"
  tail -5 "/usr/local/var/log/orzmcproxy/${ROLE}.log" 2>/dev/null || true
fi

# 3. 隧道代理状态（frp 日志关键行）
echo "--- 最近隧道事件 ---"
LOG=""
if [ "${OS}" = "Darwin" ]; then LOG="/usr/local/var/log/orzmcproxy/${ROLE}.log"; fi
if [ -n "${LOG}" ] && [ -f "${LOG}" ]; then
  grep -E "start proxy success|proxy .* closed|login to server success|error" "${LOG}" | tail -5 || echo "（暂无隧道事件日志）"
fi

echo "==== 完成 ===="
echo "提示: 隧道正常时 frpc 日志应含 'start proxy success'，frps 应含 'login to server success'"
