#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 模块注释原则（最新版本唯一基线）
# - 每个模块注释只写三项：type / purpose / version_scope。
# - type: flow（固定流程）或 legacy-fix（历史修复）。
# - 本脚本默认只允许 flow；若出现 legacy-fix，必须写明修复问题与版本范围。
# -----------------------------------------------------------------------------

REPO_META_URL="${MACF_REPO_META_URL:-https://api.github.com/repos/JingjingChen1/Multi-Agent-Collaboration-Framework}"
INSTALL_SCRIPT_API_URL="${MACF_INSTALL_SCRIPT_API_URL:-https://api.github.com/repos/JingjingChen1/Multi-Agent-Collaboration-Framework/contents/scripts/install.sh?ref=main}"

GITHUB_TOKEN="${MACF_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
GITHUB_TOKEN_FILE="${MACF_GITHUB_TOKEN_FILE:-${HOME}/.openclaw/credentials/macf-github-token.env}"
OPENCLAW_JSON="${MACF_OPENCLAW_JSON:-${HOME}/.openclaw/openclaw.json}"
FRAMEWORK_WS="${MACF_FRAMEWORK_WORKSPACE:-${HOME}/.openclaw/workspace/multiAC}"
SYSTEM_ROOT="${MACF_SYSTEM_ROOT:-${HOME}/.openclaw/system}"
ASSETS_ROOT="${MACF_ASSETS_ROOT:-${HOME}/macf-assets}"
MULTIAC_DISABLED_NAME="${MACF_MULTIAC_DISABLED_NAME:-授权码过期，multiAC已禁用}"
TOKEN_INVALID_CLEANUP_SCRIPT="${MACF_TOKEN_INVALID_CLEANUP_SCRIPT:-${SYSTEM_ROOT}/tools/core-runtime/token-invalid-cleanup.sh}"

## [MODULE] log
## type: flow
## purpose: 输出 install 外包入口日志。
## version_scope: all (latest baseline)
log() {
  echo "[MACF-INSTALL-WRAPPER] $*"
}

## [MODULE] die
## type: flow
## purpose: 输出错误并终止 wrapper。
## version_scope: all (latest baseline)
die() {
  echo "[MACF-INSTALL-WRAPPER ERROR] $*" >&2
  exit 1
}

## [MODULE] token-load
## type: flow
## purpose: 从本地凭据文件加载 token。
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

## [MODULE] token-prompt
## type: flow
## purpose: 交互读取 token（仅在未提供时触发）。
## version_scope: all (latest baseline)
prompt_token_if_needed() {
  [[ -n "${GITHUB_TOKEN}" ]] && return 0
  local input=""
  if [[ -t 0 ]]; then
    read -rsp "GitHub PAT: " input
    echo ""
  elif [[ -r /dev/tty ]]; then
    read -rsp "GitHub PAT: " input </dev/tty
    echo "" >/dev/tty
  else
    die "未检测到 token 且当前非交互环境。请设置 MACF_GITHUB_TOKEN 后重试。"
  fi
  GITHUB_TOKEN="${input}"
}

## [MODULE] token-persist
## type: flow
## purpose: 持久化可用 token，便于后续本地升级链路复用。
## version_scope: all (latest baseline)
persist_token() {
  local token="$1"
  [[ -n "${token}" ]] || return 0
  local token_file token_dir
  token_file="${GITHUB_TOKEN_FILE/#\~/$HOME}"
  token_dir="$(dirname "${token_file}")"
  mkdir -p "${token_dir}"
  chmod 700 "${token_dir}" || true
  python3 - "${token_file}" "${token}" <<'PY'
import shlex
import sys
from pathlib import Path
path = Path(sys.argv[1]).expanduser().resolve()
token = sys.argv[2].strip()
if token:
    path.write_text(f"MACF_GITHUB_TOKEN={shlex.quote(token)}\n", encoding="utf-8")
PY
  chmod 600 "${token_file}" || true
}

## [MODULE] token-status
## type: flow
## purpose: 获取 token 对目标私有仓库的访问状态码。
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
## purpose: 在 token 401 时执行定向禁用清理（若本地已安装运行时）。
## version_scope: all (latest baseline)
handle_token_invalid() {
  if [[ -f "${TOKEN_INVALID_CLEANUP_SCRIPT}" ]]; then
    MACF_OPENCLAW_JSON="${OPENCLAW_JSON}" \
    MACF_FRAMEWORK_WORKSPACE="${FRAMEWORK_WS}" \
    MACF_SYSTEM_ROOT="${SYSTEM_ROOT}" \
    MACF_MULTIAC_DISABLED_NAME="${MULTIAC_DISABLED_NAME}" \
    bash "${TOKEN_INVALID_CLEANUP_SCRIPT}"
    return 0
  fi
  log "未找到本地 token 失效清理脚本（首次安装可忽略）：${TOKEN_INVALID_CLEANUP_SCRIPT}"
}

## [MODULE] remote-install-run
## type: flow
## purpose: 拉取并执行远端 install.sh。
## version_scope: all (latest baseline)
run_remote_install() {
  local token="$1"
  shift
  curl -fsSL --oauth2-bearer "${token}" \
    -H "Accept: application/vnd.github.raw" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${INSTALL_SCRIPT_API_URL}" | \
    MACF_GITHUB_TOKEN="${token}" \
    MACF_GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE}" \
    MACF_ASSETS_ROOT="${ASSETS_ROOT}" \
    MACF_OPENCLAW_JSON="${OPENCLAW_JSON}" \
    MACF_FRAMEWORK_WORKSPACE="${FRAMEWORK_WS}" \
    MACF_SYSTEM_ROOT="${SYSTEM_ROOT}" \
    MACF_MULTIAC_DISABLED_NAME="${MULTIAC_DISABLED_NAME}" \
    bash -s -- "$@"
}

## [MODULE] main
## type: flow
## purpose: 执行 install 外包入口流程（校验 token 后分流）。
## version_scope: all (latest baseline)
main() {
  load_persisted_token
  prompt_token_if_needed
  [[ -n "${GITHUB_TOKEN}" ]] || die "token 不能为空。"

  local code
  code="$(get_token_http_status "${GITHUB_TOKEN}")"
  case "${code}" in
    200)
      persist_token "${GITHUB_TOKEN}"
      ;;
    401)
      log "检测到 token 无效/过期（401），执行禁用清理后终止安装。"
      handle_token_invalid
      exit 1
      ;;
    *)
      die "token 校验失败（HTTP ${code:-unknown}），终止安装。"
      ;;
  esac

  log "token 有效，开始执行远端安装脚本。"
  run_remote_install "${GITHUB_TOKEN}" "$@"
}

main "$@"
