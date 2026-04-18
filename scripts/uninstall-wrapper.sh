#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 模块注释原则（最新版本唯一基线）
# - 每个模块注释只写三项：type / purpose / version_scope。
# - type: flow（固定流程）或 legacy-fix（历史修复）。
# - 本脚本默认只允许 flow；若出现 legacy-fix，必须写明修复问题与版本范围。
# -----------------------------------------------------------------------------

LOCAL_UNINSTALL_SCRIPT="${MACF_LOCAL_UNINSTALL_SCRIPT:-${HOME}/.openclaw/system/tools/core-runtime/uninstall-framework.sh}"

## [MODULE] die
## type: flow
## purpose: 输出错误并终止卸载入口。
## version_scope: all (latest baseline)
die() {
  echo "[MACF-UNINSTALL-WRAPPER ERROR] $*" >&2
  exit 1
}

## [MODULE] main
## type: flow
## purpose: 从公开入口触发本地卸载（通过临时副本执行，避免自删冲突）。
## version_scope: all (latest baseline)
main() {
  [[ -f "${LOCAL_UNINSTALL_SCRIPT}" ]] || die "未检测到本地卸载脚本：${LOCAL_UNINSTALL_SCRIPT}"
  local tmp_script
  tmp_script="$(mktemp /tmp/macf-uninstall-wrapper-XXXXXX.sh)"
  cp "${LOCAL_UNINSTALL_SCRIPT}" "${tmp_script}"
  chmod 700 "${tmp_script}"
  bash "${tmp_script}" "$@"
  rm -f "${tmp_script}" || true
}

main "$@"
