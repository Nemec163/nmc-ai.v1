#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
FORCE=0
STATE_FILE="/var/lib/openclaw-installer/state.json"
OPENCLAW_HOME="/home/openclaw"

usage() {
  cat <<'USAGE'
reset-openclaw-stage.sh — полный сброс второго этапа (openclaw)

Что удаляет:
- официальный OpenClaw uninstall --all (если доступен)
- user systemd units OpenClaw у пользователя openclaw
- system-level fallback unit openclaw-gateway-host.service
- orphan gateway-процессы и занятый порт 18789
- установленный openclaw (user/root npm/pnpm global)
- бинарники openclaw в ~/.local/bin и ~/.npm-global/bin
- конфиг/данные ~/.openclaw и XDG-каталоги openclaw (включая profiles)
- маркерный блок NMC-AI.V1 PNPM в ~/.bashrc
- tailscale serve publish для OpenClaw
- временные runtime-файлы OpenClaw в /tmp/openclaw*
- стерильный rebuild /home/openclaw до baseline infra (с сохранением ~/.ssh)
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

run_openclaw_systemctl_user() {
  local uid="$1"
  shift

  if run_root systemctl --machine "openclaw@" --user "$@" 2>/dev/null; then
    return 0
  fi

  run_root -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" systemctl --user "$@" 2>/dev/null
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
  run_openclaw_systemctl_user "$uid" list-unit-files --type=service --no-legend \
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
      run_openclaw_systemctl_user "$uid" stop "$unit" || true
      run_openclaw_systemctl_user "$uid" disable "$unit" || true
      run_root rm -f "${OPENCLAW_HOME}/.config/systemd/user/${unit}" || true
      run_root rm -f "${OPENCLAW_HOME}/.config/systemd/user/default.target.wants/${unit}" || true
      run_root rm -f "${OPENCLAW_HOME}/.config/systemd/user/multi-user.target.wants/${unit}" || true
    done <<< "$units"
  else
    warn "User units OpenClaw не найдены"
  fi

  run_openclaw_systemctl_user "$uid" daemon-reload || true
  run_openclaw_systemctl_user "$uid" reset-failed || true
}

cleanup_user_gateway_unit_files() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Удаление файлов user-unit OpenClaw (включая stale fallback)"
  run_root find "${OPENCLAW_HOME}/.config/systemd/user" -maxdepth 1 -type f \
    \( -name 'openclaw-gateway*.service*' -o -name '*openclaw*gateway*.service*' -o -name '*openclaw*.service*' \) \
    -delete 2>/dev/null || true

  run_root find "${OPENCLAW_HOME}/.config/systemd/user/default.target.wants" -maxdepth 1 -type l \
    \( -name 'openclaw-gateway*.service*' -o -name '*openclaw*gateway*.service*' -o -name '*openclaw*.service*' \) \
    -delete 2>/dev/null || true

  run_root find "${OPENCLAW_HOME}/.config/systemd/user/multi-user.target.wants" -maxdepth 1 -type l \
    \( -name 'openclaw-gateway*.service*' -o -name '*openclaw*gateway*.service*' -o -name '*openclaw*.service*' \) \
    -delete 2>/dev/null || true

  run_root find "${OPENCLAW_HOME}/.config/systemd/user/graphical-session.target.wants" -maxdepth 1 -type l \
    \( -name 'openclaw-gateway*.service*' -o -name '*openclaw*gateway*.service*' -o -name '*openclaw*.service*' \) \
    -delete 2>/dev/null || true
}

remove_system_gateway_fallback_unit() {
  log "Удаление system-level fallback unit OpenClaw"

  run_root systemctl stop openclaw-gateway-host.service || true
  run_root systemctl disable openclaw-gateway-host.service || true
  run_root systemctl stop openclaw-gateway.service || true
  run_root systemctl disable openclaw-gateway.service || true
  run_root rm -f /etc/systemd/system/openclaw-gateway-host.service || true
  run_root rm -f /etc/systemd/system/openclaw-gateway.service || true
  run_root rm -f /etc/systemd/system/multi-user.target.wants/openclaw-gateway-host.service || true
  run_root rm -f /etc/systemd/system/multi-user.target.wants/openclaw-gateway.service || true
  run_root rm -f "${OPENCLAW_HOME}/.local/bin/openclaw-gateway-run.sh" || true
  run_root systemctl daemon-reload || true
  run_root systemctl reset-failed openclaw-gateway-host.service || true
  run_root systemctl reset-failed openclaw-gateway.service || true
}

stop_orphan_gateway_processes() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Остановка orphan gateway процессов и освобождение порта 18789"
  run_as_openclaw 'export PNPM_HOME="$HOME/.local/share/pnpm"; export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PNPM_HOME:$PATH"; openclaw gateway stop || true'

  run_root pkill -u openclaw -f 'openclaw-gateway' || true
  run_root pkill -u openclaw -f 'openclaw gateway' || true
  run_root pkill -u openclaw -f 'node .*openclaw.*dist/index.js.*gateway' || true

  if (( DRY_RUN )); then
    printf '[dry-run] kill listeners on tcp:18789 (if any)\n'
  else
    local pids
    pids="$(run_root bash -lc "ss -ltnp '( sport = :18789 )' 2>/dev/null | sed -n 's/.*pid=\\([0-9]\\+\\).*/\\1/p' | sort -u")"
    if [[ -n "${pids}" ]]; then
      while IFS= read -r pid; do
        [[ -z "${pid}" ]] && continue
        run_root kill -TERM "${pid}" || true
        sleep 0.2
        run_root kill -KILL "${pid}" || true
      done <<< "${pids}"
    fi
  fi
}

run_official_openclaw_uninstall() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Официальный OpenClaw uninstall --all (если команда доступна)"
  run_as_openclaw 'export PNPM_HOME="$HOME/.local/share/pnpm"; export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PNPM_HOME:$PATH"; if ! command -v openclaw >/dev/null 2>&1; then exit 0; fi; HELP="$(openclaw uninstall --help 2>&1 || true)"; if [[ -z "$HELP" ]]; then exit 0; fi; if printf "%s" "$HELP" | grep -q -- "--all"; then openclaw uninstall --all --yes --non-interactive >/dev/null 2>&1 || openclaw uninstall --all --yes >/dev/null 2>&1 || printf "yes\n" | openclaw uninstall --all >/dev/null 2>&1 || true; fi; openclaw gateway uninstall >/dev/null 2>&1 || true' || true
}

reset_tailscale_serve() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  log "Сброс tailscale serve publish для OpenClaw"
  run_root tailscale serve reset || true
}

cleanup_tmp_runtime() {
  log "Удаление временных runtime-файлов OpenClaw (/tmp/openclaw*)"
  run_root rm -rf /tmp/openclaw /tmp/openclaw-* || true
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

remove_root_openclaw_packages() {
  log "Удаление root-level инсталляции openclaw (если есть)"

  run_root bash -lc 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; npm uninstall -g openclaw >/dev/null 2>&1 || true; pnpm remove -g openclaw >/dev/null 2>&1 || true' || true

  run_root rm -f /usr/local/bin/openclaw /usr/local/bin/claw /usr/bin/openclaw /usr/bin/claw || true
  run_root rm -rf /usr/local/lib/node_modules/openclaw /usr/lib/node_modules/openclaw || true
}

remove_openclaw_data() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Удаление данных/конфига OpenClaw"
  run_root rm -rf "${OPENCLAW_HOME}/.openclaw" || true
  run_root rm -rf "${OPENCLAW_HOME}/.openclaw-"* || true
  run_root rm -rf "${OPENCLAW_HOME}/.config/openclaw" || true
  run_root rm -rf "${OPENCLAW_HOME}/.config/openclaw-"* || true
  run_root rm -rf "${OPENCLAW_HOME}/.cache/openclaw" || true
  run_root rm -rf "${OPENCLAW_HOME}/.cache/openclaw-"* || true
  run_root rm -rf "${OPENCLAW_HOME}/.local/state/openclaw" || true
  run_root rm -rf "${OPENCLAW_HOME}/.local/state/openclaw-"* || true
  run_root rm -rf "${OPENCLAW_HOME}/.local/share/openclaw" || true
  run_root rm -rf "${OPENCLAW_HOME}/.local/share/openclaw-"* || true

  run_as_openclaw 'export PNPM_HOME="$HOME/.local/share/pnpm"; export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PNPM_HOME:$PATH"; npm config delete prefix || true; pnpm config delete global-dir || true; pnpm config delete global-bin-dir || true' || true

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

rebuild_openclaw_home_baseline() {
  if ! openclaw_user_exists; then
    return 0
  fi

  log "Стерильный rebuild /home/openclaw до baseline infra (с сохранением ~/.ssh)"

  run_root install -d -m 0755 -o openclaw -g openclaw "${OPENCLAW_HOME}"

  if (( DRY_RUN )); then
    printf '[dry-run] prune %s except .ssh\n' "$OPENCLAW_HOME"
  else
    run_root find "${OPENCLAW_HOME}" -mindepth 1 -maxdepth 1 ! -name '.ssh' -exec rm -rf {} + || true
  fi

  if (( DRY_RUN )); then
    printf '[dry-run] restore baseline dotfiles from /etc/skel (.bashrc .profile .bash_logout)\n'
  else
    local dot
    for dot in .bashrc .profile .bash_logout; do
      if run_root test -f "/etc/skel/${dot}"; then
        run_root install -m 0644 -o openclaw -g openclaw "/etc/skel/${dot}" "${OPENCLAW_HOME}/${dot}"
      else
        run_root touch "${OPENCLAW_HOME}/${dot}"
        run_root chown openclaw:openclaw "${OPENCLAW_HOME}/${dot}"
        run_root chmod 0644 "${OPENCLAW_HOME}/${dot}"
      fi
    done
  fi

  run_root install -d -m 0700 -o openclaw -g openclaw "${OPENCLAW_HOME}/.ssh"
  run_root chown -R openclaw:openclaw "${OPENCLAW_HOME}/.ssh" || true
  run_root chmod 0700 "${OPENCLAW_HOME}/.ssh" || true
  run_root chmod 0600 "${OPENCLAW_HOME}/.ssh/authorized_keys" || true
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
  cleanup_user_gateway_unit_files
  remove_system_gateway_fallback_unit
  stop_orphan_gateway_processes
  run_official_openclaw_uninstall
  remove_openclaw_packages
  remove_root_openclaw_packages
  remove_openclaw_data
  reset_tailscale_serve
  cleanup_tmp_runtime
  rebuild_openclaw_home_baseline
  clear_openclaw_state_flags

  log "Сброс второго этапа завершен"
  log "Теперь можно повторно запускать: ./nmc-ai.v1.sh --mode openclaw"
}

main "$@"
