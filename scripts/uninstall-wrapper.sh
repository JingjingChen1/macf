#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 模块注释原则（最新版本唯一基线）
# - 每个模块注释只写三项：type / purpose / version_scope。
# - type: flow（固定流程）或 legacy-fix（历史修复）。
# - 本脚本默认只允许 flow；若出现 legacy-fix，必须写明修复问题与版本范围。
# -----------------------------------------------------------------------------
#
# 公开发布：本文件同步至 github.com/JingjingChen1/macf/scripts/（用户可无 token 直接 curl）。
# 卸载逻辑自包含在本脚本；不再从私研仓拉取大段 install/deploy/update 脚本。
# 注：清理 macf-auto-upgrade 与 ~/.openclaw/system；与是否曾存在 core-runtime/*-wrapper.sh 无关。
# 注：agent-lifecycle 新增的 normalize-agent-runtime-config.sh / route_policy_hints.py 同属 ~/.openclaw/system/tools，卸载时会一并清理。
# 注：runtime-platform 不再保存 openclaw.json/.env 快照；卸载备份仍直接从 ~/.openclaw 抽取关键文件，互不影响。
#

ASSETS_ROOT="${MACF_ASSETS_ROOT:-${HOME}/macf-assets}"
OPENCLAW_HOME="${MACF_OPENCLAW_HOME:-${HOME}/.openclaw}"
OPENCLAW_JSON="${MACF_OPENCLAW_JSON:-${OPENCLAW_HOME}/openclaw.json}"
FRAMEWORK_WS="${MACF_FRAMEWORK_WORKSPACE:-${OPENCLAW_HOME}/workspace/multiAC}"
SYSTEM_ROOT="${MACF_SYSTEM_ROOT:-${OPENCLAW_HOME}/system}"
SYSTEM_SERVICE_NAME="${MACF_SYSTEM_SERVICE_NAME:-openclaw-gateway-macf.service}"
NATIVE_GATEWAY_SERVICE_NAME="${MACF_OPENCLAW_NATIVE_GATEWAY_SERVICE_NAME:-openclaw-gateway.service}"
AUTO_UPGRADE_SERVICE_NAME="${MACF_AUTO_UPGRADE_SERVICE_NAME:-macf-auto-upgrade.service}"
AUTO_UPGRADE_TIMER_NAME="${MACF_AUTO_UPGRADE_TIMER_NAME:-macf-auto-upgrade.timer}"
BACKUP_ROOT="${MACF_UNINSTALL_BACKUP_ROOT:-${OPENCLAW_HOME}/backups}"
REMOVE_OPENCLAW_HOME="${MACF_REMOVE_OPENCLAW_HOME:-1}"
ASSUME_YES="${MACF_UNINSTALL_ASSUME_YES:-0}"
BACKUP_DIR=""

## [MODULE] log
## type: flow
## purpose: 输出卸载流程统一日志。
## version_scope: all (latest baseline)
log() {
  echo "[MACF-UNINSTALL-WRAPPER] $*"
}

## [MODULE] warn
## type: flow
## purpose: 输出卸载流程警告日志。
## version_scope: all (latest baseline)
warn() {
  echo "[MACF-UNINSTALL-WRAPPER WARN] $*" >&2
}

## [MODULE] die
## type: flow
## purpose: 输出错误并终止卸载入口。
## version_scope: all (latest baseline)
die() {
  echo "[MACF-UNINSTALL-WRAPPER ERROR] $*" >&2
  exit 1
}

## [MODULE] sudo-ready
## type: flow
## purpose: 检测当前环境是否可执行 sudo 系统操作。
## version_scope: all (latest baseline)
sudo_ready() {
  if [[ "${EUID}" == "0" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -v >/dev/null 2>&1
}

## [MODULE] run-sudo-if-available
## type: flow
## purpose: root/sudo 可用时执行系统命令，不可用则返回失败。
## version_scope: all (latest baseline)
run_sudo_if_available() {
  if [[ "${EUID}" == "0" ]]; then
    "$@"
    return 0
  fi
  sudo_ready || return 1
  sudo "$@"
}

## [MODULE] installed-check
## type: flow
## purpose: 检测是否存在可卸载的 MACF/openclaw 运行时。
## version_scope: all (latest baseline)
is_macf_runtime_installed() {
  local markers=(
    "${SYSTEM_ROOT}/.macf-version"
    "${SYSTEM_ROOT}/tools"
    "${FRAMEWORK_WS}"
    "${OPENCLAW_HOME}/bin/macf-auto-upgrade.sh"
    "${OPENCLAW_HOME}/macf-auto-upgrade.env"
  )
  local marker
  for marker in "${markers[@]}"; do
    [[ -e "${marker}" ]] && return 0
  done
  [[ -f "${OPENCLAW_JSON}" ]] || return 1
  python3 - "${OPENCLAW_JSON}" <<'PY' >/dev/null 2>&1
import json
import re
import sys
from pathlib import Path
path = Path(sys.argv[1]).expanduser().resolve()
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
agents = data.get("agents", {}).get("list", []) if isinstance(data, dict) else []
for item in agents:
    if not isinstance(item, dict):
        continue
    aid = re.sub(r"[^a-z0-9]+", "", str(item.get("id", "")).lower())
    ws = str(item.get("workspace", ""))
    name = re.sub(r"[^a-z0-9]+", "", str(item.get("name", "")).lower())
    ws_base = re.sub(r"[^a-z0-9]+", "", Path(ws).name.lower()) if ws else ""
    if aid == "multiac" or ws_base == "multiac" or name == "multiac":
        raise SystemExit(0)
raise SystemExit(1)
PY
}

## [MODULE] interactive-confirm
## type: flow
## purpose: 卸载前交互确认，避免误删。
## version_scope: all (latest baseline)
confirm_uninstall() {
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi
  local answer="" prompt="确认执行卸载吗？(y/N): "
  echo "即将执行 MACF/openclaw 卸载（统一走公开仓内置卸载流程）。"
  if [[ -t 0 ]]; then
    read -r -p "${prompt}" answer
  elif [[ -r /dev/tty ]]; then
    read -r -p "${prompt}" answer </dev/tty
  else
    die "当前为非交互环境，无法确认卸载（可设置 MACF_UNINSTALL_ASSUME_YES=1）。"
  fi
  if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
    log "已取消卸载。"
    exit 0
  fi
}

## [MODULE] copy-path-if-exists
## type: flow
## purpose: 将存在的文件或目录复制到备份目录。
## version_scope: all (latest baseline)
copy_path_if_exists() {
  local src="$1" snapshot_root="$2"
  [[ -e "${src}" ]] || return 0
  local rel
  if [[ "${src}" == "${HOME}"/* ]]; then
    rel="${src#${HOME}/}"
  else
    rel="$(basename "${src}")"
  fi
  local dst="${snapshot_root}/${rel}"
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
}

## [MODULE] fallback-backup
## type: flow
## purpose: 兜底卸载前备份关键私有资产。
## version_scope: all (latest baseline)
backup_private_assets_fallback() {
  local ts snapshot_root archive_file sync_script
  ts="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="${BACKUP_ROOT}/macf-uninstall-fallback-${ts}"
  snapshot_root="${BACKUP_DIR}/snapshot"
  archive_file="${BACKUP_DIR}/private-assets.tar.gz"
  mkdir -p "${snapshot_root}"

  sync_script="${SYSTEM_ROOT}/tools/asset-ops/sync-all-runtime-assets.sh"
  if [[ -f "${sync_script}" ]]; then
    log "卸载前同步运行时资产到私有资产库。"
    # 协作模式一致性文档按“模式 shared 目录单份快照”策略写入资产库；
    # 其中 skills 统一收敛到 shared/skills，IDENTITY.md 保持成员独立，不进入 shared。
    # 同步器会清理成员资产中共享目录的空壳（如 runtime/workspace/agent-local）。
    # heartbeat 口径为 B1：sources 单源 + effective/registry 汇总快照；
    # sync 时优先复制运行时快照，缺失时再按 sources 生成并落盘到 heartbeats/。
    # 运行时 cron->sources 回写已并入 sync-all-runtime-assets：执行本同步器时会先前置回写，
    # 随后再做 runtime->assets，因此各 Agent heartbeats/sources 会按运行时 cron 事实源一并收敛进快照。
    # install.sh 的“重装前同步资产（禁用态先恢复目录结构）”属于重装路径；
    # 公开卸载入口仍按卸载前固定一次同步 + 归档备份执行，不复用重装前置流程。
    # 公开卸载入口在备份前复用同一同步器，确保快照口径与当前发布一致。
    MACF_ASSETS_ROOT="${ASSETS_ROOT}" \
    MACF_OPENCLAW_JSON="${OPENCLAW_JSON}" \
    MACF_FRAMEWORK_WORKSPACE="${FRAMEWORK_WS}" \
    MACF_SYSTEM_ROOT="${SYSTEM_ROOT}" \
      bash "${sync_script}" >/dev/null 2>&1 || true
  fi

  copy_path_if_exists "${ASSETS_ROOT}" "${snapshot_root}"
  copy_path_if_exists "${OPENCLAW_JSON}" "${snapshot_root}"
  copy_path_if_exists "${OPENCLAW_HOME}/.env" "${snapshot_root}"
  # 统一备份整个 workspace，覆盖 singleAgent 与 collaborationModes 两类运行时目录。
  # 资产库目录占位（singleAgent/collaborationModes README）由 init/create 链路维护；兜底备份按现状保留，不做额外改写。
  # 与 restore 口径一致：后续恢复会按 singleAgent/collaborationModes 作用域强制归位，不读取旧平铺 workspace 定义。
  # 模型口径与 deploy/update 一致：不在卸载流程改写默认模型；安装阶段写入的 agents.defaults.model
  # （如 Poe 预设 poe/GPT-5.4, responses）会随 openclaw.json 一并进入兜底备份。
  # 模型凭据口径与 deploy/update 一致：Poe 使用 ${POE_API_KEY} 占位，GitHub PAT 仅存 credentials/*.env；
  # 因此兜底备份也保留 credentials 目录，避免重建后丢失 token 来源。
  copy_path_if_exists "${OPENCLAW_HOME}/workspace" "${snapshot_root}"
  copy_path_if_exists "${OPENCLAW_HOME}/credentials" "${snapshot_root}"
  copy_path_if_exists "${OPENCLAW_HOME}/macf-auto-upgrade.env" "${snapshot_root}"
  copy_path_if_exists "${OPENCLAW_HOME}/bin/macf-auto-upgrade.sh" "${snapshot_root}"

  tar -czf "${archive_file}" -C "${snapshot_root}" .
  log "兜底卸载备份完成：${archive_file}"
}

## [MODULE] fallback-disable-services
## type: flow
## purpose: 兜底流程下停止并移除 systemd 单元。
## version_scope: all (latest baseline)
disable_and_remove_services_fallback() {
  local units=(
    "${AUTO_UPGRADE_TIMER_NAME}"
    "${AUTO_UPGRADE_SERVICE_NAME}"
    "${SYSTEM_SERVICE_NAME}"
    "${NATIVE_GATEWAY_SERVICE_NAME}"
  )
  local unit udir need_system_cleanup=0
  udir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
  for unit in "${units[@]}"; do
    systemctl --user stop "${unit}" >/dev/null 2>&1 || true
    systemctl --user disable "${unit}" >/dev/null 2>&1 || true
  done
  for unit in "${units[@]}"; do
    rm -f "${udir}/${unit}"
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true

  if [[ -e "/etc/systemd/system/${AUTO_UPGRADE_TIMER_NAME}" || -e "/etc/systemd/system/${AUTO_UPGRADE_SERVICE_NAME}" || -e "/etc/systemd/system/${SYSTEM_SERVICE_NAME}" || -e "/etc/systemd/system/${NATIVE_GATEWAY_SERVICE_NAME}" ]]; then
    need_system_cleanup=1
  fi
  if systemctl is-enabled "${AUTO_UPGRADE_TIMER_NAME}" >/dev/null 2>&1 || systemctl is-enabled "${AUTO_UPGRADE_SERVICE_NAME}" >/dev/null 2>&1 || systemctl is-enabled "${SYSTEM_SERVICE_NAME}" >/dev/null 2>&1 || systemctl is-enabled "${NATIVE_GATEWAY_SERVICE_NAME}" >/dev/null 2>&1; then
    need_system_cleanup=1
  fi

  if [[ "${need_system_cleanup}" == "1" ]]; then
    if ! sudo_ready; then
      die "检测到旧版系统级 systemd 单元仍存在，但当前无 sudo。请使用 sudo 重试卸载，或手动删除 /etc/systemd/system 下 MACF 相关单元。"
    fi
    for unit in "${units[@]}"; do
      run_sudo_if_available systemctl stop "${unit}" >/dev/null 2>&1 || true
      run_sudo_if_available systemctl disable "${unit}" >/dev/null 2>&1 || true
    done
    run_sudo_if_available rm -f "/etc/systemd/system/${AUTO_UPGRADE_TIMER_NAME}" || true
    run_sudo_if_available rm -f "/etc/systemd/system/${AUTO_UPGRADE_SERVICE_NAME}" || true
    run_sudo_if_available rm -f "/etc/systemd/system/${SYSTEM_SERVICE_NAME}" || true
    run_sudo_if_available rm -f "/etc/systemd/system/${NATIVE_GATEWAY_SERVICE_NAME}" || true
    run_sudo_if_available systemctl daemon-reload >/dev/null 2>&1 || true
    run_sudo_if_available systemctl reset-failed "${AUTO_UPGRADE_TIMER_NAME}" >/dev/null 2>&1 || true
    run_sudo_if_available systemctl reset-failed "${AUTO_UPGRADE_SERVICE_NAME}" >/dev/null 2>&1 || true
    run_sudo_if_available systemctl reset-failed "${SYSTEM_SERVICE_NAME}" >/dev/null 2>&1 || true
    run_sudo_if_available systemctl reset-failed "${NATIVE_GATEWAY_SERVICE_NAME}" >/dev/null 2>&1 || true
  fi

  if systemctl is-enabled "${AUTO_UPGRADE_TIMER_NAME}" >/dev/null 2>&1; then
    die "自动升级 timer 删除失败：${AUTO_UPGRADE_TIMER_NAME}"
  fi
  if systemctl is-enabled "${AUTO_UPGRADE_SERVICE_NAME}" >/dev/null 2>&1; then
    die "自动升级 service 删除失败：${AUTO_UPGRADE_SERVICE_NAME}"
  fi
  if systemctl --user is-enabled "${AUTO_UPGRADE_TIMER_NAME}" >/dev/null 2>&1; then
    die "用户级自动升级 timer 删除失败：${AUTO_UPGRADE_TIMER_NAME}"
  fi
  if systemctl --user is-enabled "${AUTO_UPGRADE_SERVICE_NAME}" >/dev/null 2>&1; then
    die "用户级自动升级 service 删除失败：${AUTO_UPGRADE_SERVICE_NAME}"
  fi
  if systemctl --user is-enabled "${SYSTEM_SERVICE_NAME}" >/dev/null 2>&1; then
    die "用户级 MACF Gateway 删除失败：${SYSTEM_SERVICE_NAME}"
  fi
  if systemctl --user is-enabled "${NATIVE_GATEWAY_SERVICE_NAME}" >/dev/null 2>&1; then
    die "用户级 OpenClaw 原生 Gateway 删除失败：${NATIVE_GATEWAY_SERVICE_NAME}"
  fi
  if [[ -e "${udir}/${AUTO_UPGRADE_TIMER_NAME}" || -e "${udir}/${AUTO_UPGRADE_SERVICE_NAME}" || -e "${udir}/${SYSTEM_SERVICE_NAME}" || -e "${udir}/${NATIVE_GATEWAY_SERVICE_NAME}" ]]; then
    die "用户级 systemd 单元文件仍存在：${udir}"
  fi
  if [[ -e "/etc/systemd/system/${AUTO_UPGRADE_TIMER_NAME}" ]]; then
    die "自动升级 timer 单元文件仍存在：/etc/systemd/system/${AUTO_UPGRADE_TIMER_NAME}"
  fi
  if [[ -e "/etc/systemd/system/${AUTO_UPGRADE_SERVICE_NAME}" ]]; then
    die "自动升级 service 单元文件仍存在：/etc/systemd/system/${AUTO_UPGRADE_SERVICE_NAME}"
  fi
  if systemctl is-enabled "${NATIVE_GATEWAY_SERVICE_NAME}" >/dev/null 2>&1; then
    die "OpenClaw 原生 Gateway 删除失败：${NATIVE_GATEWAY_SERVICE_NAME}"
  fi
  if [[ -e "/etc/systemd/system/${NATIVE_GATEWAY_SERVICE_NAME}" ]]; then
    die "OpenClaw 原生 Gateway 单元文件仍存在：/etc/systemd/system/${NATIVE_GATEWAY_SERVICE_NAME}"
  fi
}

## [MODULE] fallback-uninstall-openclaw
## type: flow
## purpose: 兜底流程下卸载 openclaw 进程与全局包。
## version_scope: all (latest baseline)
uninstall_openclaw_fallback() {
  local openclaw_bin prefix
  prefix="${MACF_OPENCLAW_NPM_PREFIX:-${HOME}/.local}"
  openclaw_bin="$(command -v openclaw || true)"
  if [[ -z "${openclaw_bin}" && -x "${prefix}/bin/openclaw" ]]; then
    openclaw_bin="${prefix}/bin/openclaw"
  fi
  if [[ -n "${openclaw_bin}" ]]; then
    "${openclaw_bin}" gateway stop >/dev/null 2>&1 || true
    "${openclaw_bin}" gateway uninstall >/dev/null 2>&1 || true
    "${openclaw_bin}" uninstall --all --yes --non-interactive >/dev/null 2>&1 || true
  fi

  if command -v npm >/dev/null 2>&1; then
    npm uninstall -g openclaw --prefix "${prefix}" >/dev/null 2>&1 || true
    run_sudo_if_available npm uninstall -g openclaw >/dev/null 2>&1 || true
  fi
  rm -f "${prefix}/bin/openclaw" >/dev/null 2>&1 || true
  run_sudo_if_available rm -f /usr/local/bin/openclaw /usr/bin/openclaw >/dev/null 2>&1 || true
}

## [MODULE] fallback-cleanup-runtime
## type: flow
## purpose: 清理 MACF 运行时与自动升级落地产物。
## version_scope: all (latest baseline)
cleanup_runtime_files_fallback() {
  # 与 token 失效清理不同：公开卸载入口按“用户确认后完整移除”语义执行，不保留 system 子目录。
  rm -rf "${SYSTEM_ROOT}" || true
  rm -rf "${FRAMEWORK_WS}" || true
  rm -f "${OPENCLAW_HOME}/bin/macf-auto-upgrade.sh" || true
  rm -f "${OPENCLAW_HOME}/macf-auto-upgrade.env" || true
  rm -f "${OPENCLAW_HOME}/credentials/macf-github-token.env" || true
}

## [MODULE] fallback-cleanup-openclaw-home
## type: flow
## purpose: 按配置删除 openclaw 主目录。
## version_scope: all (latest baseline)
cleanup_openclaw_home_if_configured() {
  if [[ "${REMOVE_OPENCLAW_HOME}" == "1" ]]; then
    rm -rf "${OPENCLAW_HOME}" || true
    log "已删除 openclaw 主目录：${OPENCLAW_HOME}"
  else
    log "按配置保留 openclaw 主目录：${OPENCLAW_HOME}"
  fi
}

## [MODULE] fallback-uninstall-run
## type: flow
## purpose: 统一执行公开仓内置卸载流程（不依赖本地卸载脚本）。
## version_scope: all (latest baseline)
run_fallback_uninstall() {
  if ! is_macf_runtime_installed; then
    log "未检测到可卸载的 MACF/openclaw 运行时，跳过。"
    exit 0
  fi
  confirm_uninstall
  backup_private_assets_fallback
  disable_and_remove_services_fallback
  uninstall_openclaw_fallback
  cleanup_runtime_files_fallback
  cleanup_openclaw_home_if_configured
  log "兜底卸载完成。备份目录：${BACKUP_DIR}"
}

## [MODULE] main
## type: flow
## purpose: 从公开入口统一执行内置卸载流程。
## version_scope: all (latest baseline)
main() {
  run_fallback_uninstall
}

main "$@"
