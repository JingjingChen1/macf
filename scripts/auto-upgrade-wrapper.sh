#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 模块注释原则（最新版本唯一基线）
# - 每个模块注释只写三项：type / purpose / version_scope。
# - type: flow（固定流程）或 legacy-fix（历史修复）。
# - 本脚本默认只允许 flow；若出现 legacy-fix，必须写明修复问题与版本范围。
# -----------------------------------------------------------------------------

REPO_META_URL="${MACF_REPO_META_URL:-https://api.github.com/repos/JingjingChen1/Multi-Agent-Collaboration-Framework}"
UPDATE_SCRIPT_API_URL="${MACF_UPDATE_SCRIPT_API_URL:-https://api.github.com/repos/JingjingChen1/Multi-Agent-Collaboration-Framework/contents/scripts/update.sh?ref=main}"

ASSETS_ROOT="${MACF_ASSETS_ROOT:-${HOME}/macf-assets}"
GITHUB_TOKEN="${MACF_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
GITHUB_TOKEN_FILE="${MACF_GITHUB_TOKEN_FILE:-${HOME}/.openclaw/credentials/macf-github-token.env}"
SYSTEM_ROOT="${MACF_SYSTEM_ROOT:-${HOME}/.openclaw/system}"
OPENCLAW_JSON="${MACF_OPENCLAW_JSON:-${HOME}/.openclaw/openclaw.json}"
FRAMEWORK_WS="${MACF_FRAMEWORK_WORKSPACE:-${HOME}/.openclaw/workspace/multiAC}"
SKIP_OPENCLAW_SYSTEM_UPGRADE="${MACF_AUTO_UPGRADE_SKIP_OPENCLAW_SYSTEM_UPGRADE:-1}"
UPGRADE_BASELINE_VERSION="${MACF_AUTO_UPGRADE_BASELINE_VERSION:-v2.4.3}"
LOCK_FILE="${MACF_AUTO_UPGRADE_LOCK_FILE:-${HOME}/.openclaw/locks/macf-auto-upgrade.lock}"
MULTIAC_DISABLED_NAME="${MACF_MULTIAC_DISABLED_NAME:-授权码过期，multiAC已禁用}"
TOKEN_INVALID_CLEANUP_SCRIPT="${MACF_TOKEN_INVALID_CLEANUP_SCRIPT:-${SYSTEM_ROOT}/tools/core-runtime/token-invalid-cleanup.sh}"

## [MODULE] log
## type: flow
## purpose: 输出自动升级外壳日志。
## version_scope: all (latest baseline)
log() {
  echo "[MACF-AUTO-UPGRADE] $*"
}

## [MODULE] token-load
## type: flow
## purpose: 加载持久化 token。
## version_scope: all (latest baseline)
load_persisted_token() {
  [[ -n "${GITHUB_TOKEN}" ]] && return 0
  local token_file
  token_file="${GITHUB_TOKEN_FILE/#\~/$HOME}"
  [[ -f "${token_file}" ]] || return 0
  # shellcheck disable=SC1090
  source "${token_file}" || true
  GITHUB_TOKEN="${MACF_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
}

## [MODULE] token-status
## type: flow
## purpose: 获取 token 访问目标仓库状态码。
## version_scope: all (latest baseline)
get_token_http_status() {
  local token="$1"
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    "${REPO_META_URL}" || true
}

## [MODULE] token-invalid-handle
## type: flow
## purpose: 在 token 401 时执行清理，并兼容旧运行时补写 multiAC 禁用名。
## version_scope: all (latest baseline)
enforce_multiac_disabled_name() {
  local openclaw_json
  openclaw_json="${OPENCLAW_JSON/#\~/$HOME}"
  [[ -f "${openclaw_json}" ]] || return 0
  python3 - "${openclaw_json}" "${MULTIAC_DISABLED_NAME}" <<'PY' >/dev/null 2>&1
import json
import os
import sys
from pathlib import Path

path = Path(os.path.expanduser(sys.argv[1])).resolve()
disabled_name = sys.argv[2].strip()
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
agents = data.get("agents", {}).get("list", []) if isinstance(data, dict) else []
target = None
for item in agents:
    if not isinstance(item, dict):
        continue
    aid = str(item.get("id", "")).strip().lower()
    ws = str(item.get("workspace", "")).strip()
    name = str(item.get("name", "")).strip().lower()
    ws_base = Path(os.path.expanduser(ws)).name.strip().lower() if ws else ""
    if aid == "multiac" or ws_base == "multiac" or name == "multiac":
        target = item
        break
if not isinstance(target, dict):
    raise SystemExit(0)
if str(target.get("name", "")).strip() == disabled_name:
    raise SystemExit(0)
target["name"] = disabled_name
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

handle_token_invalid() {
  if [[ -f "${TOKEN_INVALID_CLEANUP_SCRIPT}" ]]; then
    MACF_OPENCLAW_JSON="${OPENCLAW_JSON}" \
    MACF_FRAMEWORK_WORKSPACE="${FRAMEWORK_WS}" \
    MACF_SYSTEM_ROOT="${SYSTEM_ROOT}" \
    MACF_MULTIAC_DISABLED_NAME="${MULTIAC_DISABLED_NAME}" \
    bash "${TOKEN_INVALID_CLEANUP_SCRIPT}"
  fi
  enforce_multiac_disabled_name
}

## [MODULE] run-remote-update
## type: flow
## purpose: token 有效后仅执行远端 update.sh（自动升级模式）。
## version_scope: all (latest baseline)
run_remote_update() {
  local token="$1"
  curl -fsSL --oauth2-bearer "${token}" \
    -H "Accept: application/vnd.github.raw" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${UPDATE_SCRIPT_API_URL}" | \
    MACF_GITHUB_TOKEN="${token}" \
    MACF_GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE}" \
    MACF_ASSETS_ROOT="${ASSETS_ROOT}" \
    MACF_OPENCLAW_JSON="${OPENCLAW_JSON}" \
    MACF_FRAMEWORK_WORKSPACE="${FRAMEWORK_WS}" \
    MACF_SYSTEM_ROOT="${SYSTEM_ROOT}" \
    MACF_MULTIAC_DISABLED_NAME="${MULTIAC_DISABLED_NAME}" \
    MACF_AUTO_UPGRADE_MODE=1 \
    MACF_SKIP_OPENCLAW_SYSTEM_UPGRADE="${SKIP_OPENCLAW_SYSTEM_UPGRADE}" \
    MACF_UPGRADE_BASELINE_VERSION="${UPGRADE_BASELINE_VERSION}" \
    bash
}

## [MODULE] lock
## type: flow
## purpose: 防止自动升级并发执行。
## version_scope: all (latest baseline)
acquire_lock() {
  local lock_file
  lock_file="${LOCK_FILE/#\~/$HOME}"
  mkdir -p "$(dirname "${lock_file}")"
  exec 9>"${lock_file}"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
      log "检测到已有自动升级任务在运行，跳过本次执行。"
      exit 0
    fi
  fi
}

## [MODULE] main
## type: flow
## purpose: 自动升级外壳流程（仅做 token 校验与分流）。
## version_scope: all (latest baseline)
main() {
  acquire_lock
  load_persisted_token
  if [[ -z "${GITHUB_TOKEN}" ]]; then
    log "未找到持久化 token，终止本次自动升级。"
    exit 0
  fi

  local token_status
  token_status="$(get_token_http_status "${GITHUB_TOKEN}")"
  if [[ "${token_status}" == "401" ]]; then
    log "检测到 token 已过期（HTTP 401），终止本次自动升级。"
    handle_token_invalid
    exit 0
  fi
  if [[ "${token_status}" != "200" ]]; then
    log "检测到 token 无效或无权限（HTTP ${token_status:-unknown}），终止本次自动升级。"
    exit 0
  fi

  log "token 有效，开始执行远端升级脚本（auto mode）。"
  run_remote_update "${GITHUB_TOKEN}"
  log "自动升级执行结束。"
}

main "$@"
