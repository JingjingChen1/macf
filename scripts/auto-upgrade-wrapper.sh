#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 模块注释原则（最新版本唯一基线）
# - 每个模块注释只写三项：type / purpose / version_scope。
# - type: flow（固定流程）或 legacy-fix（历史修复）。
# - 本脚本默认只允许 flow；若出现 legacy-fix，必须写明修复问题与版本范围。
# -----------------------------------------------------------------------------
#
# 公开发布：本文件同步至 github.com/JingjingChen1/macf/scripts/（由 macf-auto-upgrade runner curl 下载后再 bash，无 core-runtime 副本）。
# 内层 update.sh 由下方 API 从私研仓拉取；默认勿改为 macf 仓库（macf 仅托管外壳）。
# 注：runner 在下载本文件失败（离线等）时直接退出，不会执行到此处；401 仍可能调用本机 token-invalid-cleanup.sh。
# 注：token-invalid-cleanup 仅清理可重建目录（system/tools|governance|templates）与 multiAC 托管文档；
#     system/protocol 与 .macf-version 保留用于后续 update 入口判定与重建。
# 每次执行结束（成功 / 失败 / 跳过）会向 MACF_AUTO_UPGRADE_JOURNAL_FILE 追加一行 TSV：时间、状态、原因。
# 注：远端 update 阶段 D 会执行 deploy-framework（render、~/.local/bin PATH 片段、registry 等与手动升级一致）；本外壳传入 MACF_OPENCLAW_BIN 优先 ~/.local/bin，避免定时任务环境 PATH 过窄。
# 注：资产同步/恢复 heartbeat 汇总快照采用“优先直拷 + 缺失回退生成”策略（effective + registry），与手动升级链路保持一致。
#

REPO_META_URL="${MACF_REPO_META_URL:-https://api.github.com/repos/JingjingChen1/Multi-Agent-Collaboration-Framework}"
UPDATE_SCRIPT_API_URL="${MACF_UPDATE_SCRIPT_API_URL:-https://api.github.com/repos/JingjingChen1/Multi-Agent-Collaboration-Framework/contents/scripts/update.sh?ref=main}"

ASSETS_ROOT="${MACF_ASSETS_ROOT:-${HOME}/macf-assets}"
GITHUB_TOKEN="${MACF_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
GITHUB_TOKEN_FILE="${MACF_GITHUB_TOKEN_FILE:-${HOME}/.openclaw/credentials/macf-github-token.env}"
SYSTEM_ROOT="${MACF_SYSTEM_ROOT:-${HOME}/.openclaw/system}"
OPENCLAW_JSON="${MACF_OPENCLAW_JSON:-${HOME}/.openclaw/openclaw.json}"
FRAMEWORK_WS="${MACF_FRAMEWORK_WORKSPACE:-${HOME}/.openclaw/workspace/multiAC}"
SKIP_OPENCLAW_SYSTEM_UPGRADE="${MACF_AUTO_UPGRADE_SKIP_OPENCLAW_SYSTEM_UPGRADE:-1}"
# 与内层 update 默认基线一致；若 ~/.openclaw/macf-auto-upgrade.env 中仍留有旧版 MACF_AUTO_UPGRADE_BASELINE_VERSION，会覆盖此处（建议删除该行或重跑 setup-auto-upgrade 以去掉固化基线）。
UPGRADE_BASELINE_VERSION="${MACF_AUTO_UPGRADE_BASELINE_VERSION:-v2.5.25}"
LOCK_FILE="${MACF_AUTO_UPGRADE_LOCK_FILE:-${HOME}/.openclaw/locks/macf-auto-upgrade.lock}"
MULTIAC_DISABLED_NAME="${MACF_MULTIAC_DISABLED_NAME:-授权码过期，multiAC已禁用}"
TOKEN_INVALID_CLEANUP_SCRIPT="${MACF_TOKEN_INVALID_CLEANUP_SCRIPT:-${SYSTEM_ROOT}/tools/core-runtime/token-invalid-cleanup.sh}"
MACF_AUTO_UPGRADE_JOURNAL_FILE="${MACF_AUTO_UPGRADE_JOURNAL_FILE:-${HOME}/.openclaw/logs/macf-auto-upgrade.log}"

REMOTE_UPDATE_FAILURE_DETAIL=""

## [MODULE] log
## type: flow
## purpose: 输出自动升级外壳日志。
## version_scope: all (latest baseline)
log() {
  echo "[MACF-AUTO-UPGRADE] $*"
}

## [MODULE] journal
## type: flow
## purpose: 将本次自动升级结果追加写入本地日志（TSV：时间\t状态\t原因）。
## version_scope: all (latest baseline)
write_journal() {
  local status="$1"
  local reason="${2:-}"
  local path ts
  path="${MACF_AUTO_UPGRADE_JOURNAL_FILE/#\~/$HOME}"
  mkdir -p "$(dirname "${path}")" || return 0
  reason="$(printf '%s' "${reason}" | tr '\n\r\t' ' ' | sed 's/  */ /g')"
  if [[ ${#reason} -gt 2000 ]]; then
    reason="${reason:0:2000}…"
  fi
  ts="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '%s\t%s\t%s\n' "${ts}" "${status}" "${reason}" >>"${path}"
  chmod 600 "${path}" 2>/dev/null || true
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
## purpose: 在 token 401 时执行清理，并统一写入 multiAC 禁用态（name + identity.name）。
## version_scope: all (latest baseline)
enforce_multiac_disabled_name() {
  local openclaw_json
  openclaw_json="${OPENCLAW_JSON/#\~/$HOME}"
  [[ -f "${openclaw_json}" ]] || return 0
  python3 - "${openclaw_json}" "${MULTIAC_DISABLED_NAME}" <<'PY' >/dev/null 2>&1
import json
import os
import re
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
    norm_aid = re.sub(r"[^a-z0-9]+", "", aid)
    norm_ws = re.sub(r"[^a-z0-9]+", "", ws_base)
    norm_name = re.sub(r"[^a-z0-9]+", "", name)
    if norm_aid == "multiac" or norm_ws == "multiac" or norm_name == "multiac":
        target = item
        break
if not isinstance(target, dict):
    raise SystemExit(0)
# 401 禁用态需要同步写入两处展示字段，避免 UI/运行时读取字段不一致。
identity = target.get("identity")
if not isinstance(identity, dict):
    identity = {}
    target["identity"] = identity
name_changed = str(target.get("name", "")).strip() != disabled_name
identity_changed = str(identity.get("name", "")).strip() != disabled_name
if not name_changed and not identity_changed:
    raise SystemExit(0)
target["name"] = disabled_name
identity["name"] = disabled_name
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
  # 目录删除后的收尾动作统一在外壳脚本执行，避免依赖可能被删除的本地清理脚本继续收尾。
  enforce_multiac_disabled_name
}

## [MODULE] openclaw-bin-for-remote
## type: flow
## purpose: 为远端 update 提供 MACF_OPENCLAW_BIN（优先 ~/.local/bin，定时任务环境常无完整 PATH）。
## version_scope: all (latest baseline)
remote_openclaw_bin_for_pipe() {
  if [[ -n "${MACF_OPENCLAW_BIN:-}" ]]; then
    printf '%s\n' "${MACF_OPENCLAW_BIN}"
    return 0
  fi
  local lp="${HOME}/.local/bin/openclaw"
  if [[ -x "${lp}" ]]; then
    printf '%s\n' "${lp}"
    return 0
  fi
  command -v openclaw || true
}

## [MODULE] run-remote-update
## type: flow
## purpose: token 有效后仅执行远端 update.sh（自动升级模式）；区分 curl 与内层 bash 退出码并收集 stderr 摘要。
## version_scope: all (latest baseline)
run_remote_update() {
  local token="$1"
  local ecurl ebash rc_curl rc_bash oc_bin
  local -a pipe_rc=()
  REMOTE_UPDATE_FAILURE_DETAIL=""
  oc_bin="$(remote_openclaw_bin_for_pipe)"
  ecurl="$(mktemp)"
  ebash="$(mktemp)"
  trap 'rm -f "${ecurl}" "${ebash}"' RETURN
  set +e
  curl -fsSL --oauth2-bearer "${token}" \
    -H "Accept: application/vnd.github.raw" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${UPDATE_SCRIPT_API_URL}" 2>"${ecurl}" | \
    MACF_GITHUB_TOKEN="${token}" \
    MACF_GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE}" \
    MACF_ASSETS_ROOT="${ASSETS_ROOT}" \
    MACF_OPENCLAW_JSON="${OPENCLAW_JSON}" \
    MACF_FRAMEWORK_WORKSPACE="${FRAMEWORK_WS}" \
    MACF_SYSTEM_ROOT="${SYSTEM_ROOT}" \
    MACF_OPENCLAW_BIN="${oc_bin}" \
    MACF_MULTIAC_DISABLED_NAME="${MULTIAC_DISABLED_NAME}" \
    MACF_AUTO_UPGRADE_MODE=1 \
    MACF_SKIP_OPENCLAW_SYSTEM_UPGRADE="${SKIP_OPENCLAW_SYSTEM_UPGRADE}" \
    MACF_UPGRADE_BASELINE_VERSION="${UPGRADE_BASELINE_VERSION}" \
    bash 2>"${ebash}"
  # set -u 下需先整体快照 PIPESTATUS；逐项读取会被中间赋值语句覆盖，可能误报“未绑定变量”。
  pipe_rc=("${PIPESTATUS[@]}")
  rc_curl="${pipe_rc[0]:-1}"
  rc_bash="${pipe_rc[1]:-1}"
  set -e
  if [[ "${rc_curl}" -ne 0 ]]; then
    REMOTE_UPDATE_FAILURE_DETAIL="curl 拉取 update.sh 失败 exit=${rc_curl} $(tail -c 800 "${ecurl}" | tr '\n' ' ')"
    return "${rc_curl}"
  fi
  if [[ "${rc_bash}" -ne 0 ]]; then
    REMOTE_UPDATE_FAILURE_DETAIL="远端 update.sh 失败 exit=${rc_bash} $(tail -c 2000 "${ebash}" | tr '\n' ' ')"
    return "${rc_bash}"
  fi
  return 0
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
      write_journal skipped "已有实例占用锁（flock），跳过"
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
    write_journal skipped "未配置 GitHub token（MACF_GITHUB_TOKEN 为空）"
    exit 0
  fi

  local token_status
  token_status="$(get_token_http_status "${GITHUB_TOKEN}")"
  if [[ "${token_status}" == "401" ]]; then
    log "检测到 token 已过期（HTTP 401），终止本次自动升级。"
    handle_token_invalid
    write_journal skipped "GitHub token HTTP 401，已执行失效清理"
    exit 0
  fi
  if [[ "${token_status}" != "200" ]]; then
    log "检测到 token 无效或无权限（HTTP ${token_status:-unknown}），终止本次自动升级。"
    write_journal skipped "GitHub token 校验非 200（HTTP ${token_status:-unknown}）"
    exit 0
  fi

  log "token 有效，开始执行远端升级脚本（auto mode）。"
  if run_remote_update "${GITHUB_TOKEN}"; then
    log "自动升级执行结束。"
    write_journal success "远端 update.sh 执行成功"
  else
    log "自动升级失败：${REMOTE_UPDATE_FAILURE_DETAIL}"
    write_journal failure "${REMOTE_UPDATE_FAILURE_DETAIL}"
    exit 1
  fi
}

main "$@"
