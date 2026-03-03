#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
FORCE=0
STATE_FILE="/var/lib/openclaw-installer/state.json"
OPENCLAW_HOME="/home/openclaw"

usage() {
  cat <<'USAGE'
reset-openclaw-stage.sh — полный сброс только второго этапа (openclaw)

Что удаляет:
- user systemd units OpenClaw у пользователя openclaw
- system-level fallback unit openclaw-gateway-host.service
- установленный openclaw (npm/pnpm global)
- бинарники openclaw в ~/.local/bin и ~/.npm-global/bin
- конфиг/данные ~/.openclaw
- маркерный блок NMC-AI.V1 PNPM в ~/.bashrc
- tailscale serve publish для OpenClaw
- флаги openclaw_completed/openclaw_completed_at в state.json

Что НЕ трогает:
- infra-этап (UFW, fail2ban, Docker, tailscale, SSH hardening)
- пользователя openclaw и его sudo-группу

Usage:
  ./reset-openclaw-stage.sh [--dry-run] [--force]

Options:
  --dry-run   показать действия без изменений
  --force     не запрашивать подтверждение
  -h, --help  помощь
USAGE
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

run_root() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  # Keep support for sudo-style flags (`-iu user ...`) even in root shell.
  if [[ "$EUID" -eq 0 && "${1:-}" != -* ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_openclaw() {
  local cmd="$1"

  if (( DRY_RUN )); then
    printf '[dry-run] sudo -iu openclaw bash -lc %q\n' "$cmd"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo -iu openclaw bash -lc "$cmd"
  else
    printf '%s\n' "$cmd" | su - openclaw -s /bin/bash -c 'bash -se'
  fi
}

openclaw_user_exists() {
  if [[ "$EUID" -eq 0 ]]; then
    id -u openclaw >/dev/null 2>&1
  else
    sudo id -u openclaw >/dev/null 2>&1
  fi
}

openclaw_uid() {
  if [[ "$EUID" -eq 0 ]]; then
    id -u openclaw
  else
    sudo id -u openclaw
  fi
}

confirm_reset() {
  if (( FORCE )); then
    return 0
  fi

  local answer
  printf "Это удалит весь результат второго этапа OpenClaw. Продолжить? [yes/NO]: " > /dev/tty
  IFS= read -r answer < /dev/tty || true
  if [[ "$answer" != "yes" ]]; then
    err "Операция отменена"
    exit 1
  fi
}

ensure_prereqs() {
  if [[ "$EUID" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    err "Нужен root или sudo"
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    err "Требуется python3"
    exit 1
  fi

  if ! openclaw_user_exists; then
    warn "Пользователь openclaw не найден. Выполню только очистку state"
  fi
}

collect_openclaw_units() {
  local uid="$1"
  run_root -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -Ei 'openclaw|claw' \
    | sort -u || true
}

stop_and_remove_openclaw_units() {
  if ! openclaw_user_exists; then
    return 0
  fi

  local uid
  uid="$(openclaw_uid)"

  log "Остановка и удаление user-systemd units OpenClaw"
  local units
  units="$(collect_openclaw_units "$uid")"

  if [[ -n "$units" ]]; then
    while IFS= read -r unit; do
      [[ -z "$unit" ]] && continue
      run_root -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user stop "$unit" || true
      run_root -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user disable "$unit" || true
      run_root rm -f "${OPENCLAW_HOME}/.config/systemd/user/${unit}" || true
      run_root rm -f "${OPENCLAW_HOME}/.config/systemd/user/default.target.wants/${unit}" || true
      run_root rm -f "${OPENCLAW_HOME}/.config/systemd/user/multi-user.target.wants/${unit}" || true
    done <<< "$units"
  else
    warn "User units OpenClaw не найдены"
  fi

  run_root -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user daemon-reload || true
  run_root -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user reset-failed || true
}

remove_system_gateway_fallback_unit() {
  log "Удаление system-level fallback unit OpenClaw"

  run_root systemctl stop openclaw-gateway-host.service || true
  run_root systemctl disable openclaw-gateway-host.service || true
  run_root rm -f /etc/systemd/system/openclaw-gateway-host.service || true
  run_root rm -f /etc/systemd/system/multi-user.target.wants/openclaw-gateway-host.service || true
  run_root rm -f "${OPENCLAW_HOME}/.local/bin/openclaw-gateway-run.sh" || true
  run_root systemctl daemon-reload || true
  run_root systemctl reset-failed openclaw-gateway-host.service || true
}

reset_tailscale_serve() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  log "Сброс tailscale serve publish для OpenClaw"
  run_root tailscale serve reset || true
}

remove_openclaw_packages() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Удаление openclaw из npm/pnpm"
  run_as_openclaw 'export PNPM_HOME="$HOME/.local/share/pnpm"; export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PNPM_HOME:$PATH"; pnpm remove -g openclaw || true; npm uninstall -g openclaw || true'

  run_root rm -f "${OPENCLAW_HOME}/.local/bin/openclaw" || true
  run_root rm -f "${OPENCLAW_HOME}/.npm-global/bin/openclaw" || true
  run_root rm -f "${OPENCLAW_HOME}/.local/bin/claw" || true
  run_root rm -f "${OPENCLAW_HOME}/.npm-global/bin/claw" || true

  # remove package folders directly in case uninstall did not clean up
  run_root rm -rf "${OPENCLAW_HOME}/.npm-global/lib/node_modules/openclaw" || true
  run_root bash -lc "find '${OPENCLAW_HOME}/.local/share/pnpm' -type d -name openclaw 2>/dev/null | grep '/node_modules/openclaw$' | xargs -r rm -rf" || true
}

remove_openclaw_data() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Удаление данных/конфига OpenClaw"
  run_root rm -rf "${OPENCLAW_HOME}/.openclaw" || true

  if (( DRY_RUN )); then
    printf '[dry-run] remove block NMC-AI.V1 PNPM from %s/.bashrc\n' "$OPENCLAW_HOME"
  else
    run_root python3 - "${OPENCLAW_HOME}/.bashrc" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

start = "# BEGIN NMC-AI.V1 PNPM"
end = "# END NMC-AI.V1 PNPM"
lines = path.read_text().splitlines()
out = []
in_block = False
for line in lines:
    if line.strip() == start:
        in_block = True
        continue
    if in_block and line.strip() == end:
        in_block = False
        continue
    if not in_block:
        out.append(line)
path.write_text(("\n".join(out).rstrip("\n") + "\n") if out else "")
PY
    run_root chown openclaw:openclaw "${OPENCLAW_HOME}/.bashrc" || true
  fi
}

clear_openclaw_state_flags() {
  log "Очистка флагов второго этапа в state"

  if (( DRY_RUN )); then
    printf '[dry-run] update %s\n' "$STATE_FILE"
    return 0
  fi

  run_root python3 - "$STATE_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

try:
    data = json.loads(path.read_text() or "{}")
except json.JSONDecodeError:
    data = {}

data.pop("openclaw_completed", None)
data.pop("openclaw_completed_at", None)

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Неизвестный аргумент: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  ensure_prereqs
  confirm_reset

  stop_and_remove_openclaw_units
  remove_system_gateway_fallback_unit
  remove_openclaw_packages
  remove_openclaw_data
  reset_tailscale_serve
  clear_openclaw_state_flags

  log "Сброс второго этапа завершен"
  log "Теперь можно повторно запускать: ./nmc-ai.v1.sh --mode openclaw"
}

main "$@"
