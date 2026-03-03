#!/usr/bin/env bash

OPENCLAW_INSTALLER_URLS_DEFAULT="https://install.openclaw.ai/installer.sh https://openclaw.ai/install.sh"
OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT:-18789}
OPENCLAW_TAILSCALE_MODE=${OPENCLAW_TAILSCALE_MODE:-serve}
OPENCLAW_ENV_EXPORTS='export XDG_RUNTIME_DIR="/run/user/$(id -u)"; export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"; export PNPM_HOME="$HOME/.local/share/pnpm"; export NPM_CONFIG_PREFIX="$HOME/.npm-global"; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PNPM_HOME:$PATH";'
OPENCLAW_BIN_PATH="openclaw"
OPENCLAW_UID=""
OPENCLAW_TAILNET_DNS=""
OPENCLAW_GATEWAY_UNIT=""
OPENCLAW_SERVICE_SCOPE="user"
OPENCLAW_USER_SYSTEMD_READY=0
OPENCLAW_SYSTEMCTL_MODE=""

ensure_openclaw_preflight() {
  log_info "Проверка preflight (openclaw)"

  if [[ "$EUID" -eq 0 ]]; then
    log_warn "Запуск от root разрешен (bootstrap режим)."
  fi

  if ! supported_ubuntu; then
    fatal 10 "Поддерживаются только Ubuntu 22.04 и 24.04"
  fi

  ensure_sudo_access || fatal 10 "Sudo-права обязательны"
  state_init

  if ! state_get_bool infra_completed; then
    fatal 30 "Infra этап не завершен. Сначала выполните --mode infra"
  fi

  if ! sudo id -u openclaw >/dev/null 2>&1; then
    fatal 30 "Пользователь openclaw не найден"
  fi

  require_cmd curl sudo bash jq tailscale || fatal 30 "Не хватает базовых команд для установки OpenClaw"
}

ensure_tailscale_online() {
  log_info "Проверка Tailscale"

  run_sudo systemctl enable --now tailscaled

  if tailscale_online; then
    OPENCLAW_TAILNET_DNS="$(tailscale_dns_name)"
    return 0
  fi

  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    run_sudo tailscale up --authkey "${TAILSCALE_AUTHKEY}"
  else
    log_warn "Tailscale не online, требуется интерактивный tailscale up"
    run_sudo tailscale up
  fi

  if ! tailscale_online; then
    fatal 30 "Tailscale остаётся offline. Выполните этап infra повторно и проверьте tailscale up"
  fi

  OPENCLAW_TAILNET_DNS="$(tailscale_dns_name)"
}

tailscale_online() {
  local json
  json="$(sudo tailscale status --json 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    return 1
  fi

  printf '%s' "$json" | jq -e '.BackendState == "Running" and (.Self.Online // false) and ((.TailscaleIPs // []) | length > 0)' >/dev/null 2>&1
}

tailscale_dns_name() {
  local dns
  dns="$(sudo tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
  printf '%s' "$dns"
}

ensure_openclaw_user_pnpm_layout() {
  log_info "Подготовка окружения openclaw (pnpm + npm global bin)"

  run_as_openclaw "mkdir -p ~/.local/bin ~/.local/share/pnpm ~/.local/share/pnpm/store ~/.npm-global/bin ~/.openclaw/credentials"
  run_as_openclaw "chmod 700 ~/.openclaw/credentials"
  run_as_openclaw "npm config set prefix ~/.npm-global"
  run_as_openclaw "pnpm config set global-dir ~/.local/share/pnpm"
  run_as_openclaw "pnpm config set global-bin-dir ~/.local/bin"

  local block
  block=$(cat <<'BLOCK'
export PNPM_HOME="$HOME/.local/share/pnpm"
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PNPM_HOME:$PATH"
BLOCK
)
  ensure_block_in_file "/home/openclaw/.bashrc" "NMC-AI.V1 PNPM" "^$" "$block"
  run_sudo chown openclaw:openclaw /home/openclaw/.bashrc
}

resolve_openclaw_installer_urls() {
  if [[ -n "${OPENCLAW_OFFICIAL_INSTALLER_URLS:-}" ]]; then
    printf '%s\n' "$OPENCLAW_OFFICIAL_INSTALLER_URLS"
    return
  fi
  printf '%s\n' "$OPENCLAW_INSTALLER_URLS_DEFAULT"
}

attempt_official_openclaw_install() {
  local urls
  urls="$(resolve_openclaw_installer_urls)"

  local url
  for url in $urls; do
    log_info "Пробую официальный installer: $url"
    if ! curl -fsSLI --max-time 10 "$url" >/dev/null 2>&1; then
      log_warn "Installer недоступен: $url"
      continue
    fi

    if run_as_openclaw "curl -fsSL '$url' | bash -s -- --no-onboard --no-prompt"; then
      log_success "Установка через официальный installer выполнена"
      return 0
    fi

    log_warn "Официальный installer завершился ошибкой: $url"
  done

  return 1
}

fallback_install_with_pnpm() {
  log_info "Fallback: установка openclaw@latest через pnpm"
  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} pnpm install -g openclaw@latest"
}

discover_openclaw_binary() {
  local detected

  detected="$(run_as_openclaw "${OPENCLAW_ENV_EXPORTS} command -v openclaw || true" | tail -n1 | tr -d '\r')"
  if [[ -n "$detected" ]]; then
    OPENCLAW_BIN_PATH="$detected"
    return 0
  fi

  if run_as_openclaw "test -x /home/openclaw/.npm-global/bin/openclaw"; then
    OPENCLAW_BIN_PATH="/home/openclaw/.npm-global/bin/openclaw"
    return 0
  fi

  if run_as_openclaw "test -x /home/openclaw/.local/bin/openclaw"; then
    OPENCLAW_BIN_PATH="/home/openclaw/.local/bin/openclaw"
    return 0
  fi

  return 1
}

verify_openclaw_binary() {
  log_info "Проверка установленного OpenClaw"

  if ! discover_openclaw_binary; then
    fatal 30 "OpenClaw установлен некорректно: бинарник не найден в PATH пользователя openclaw"
  fi

  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" --version"
}

openclaw_onboard_supports_flag() {
  local flag="$1"
  if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" onboard --help 2>/dev/null | grep -q -- \"$flag\""; then
    return 0
  fi
  return 1
}

onboard_default_flags() {
  local flags=""

  if openclaw_onboard_supports_flag "--gateway-bind"; then
    flags+=" --gateway-bind loopback"
  fi

  if openclaw_onboard_supports_flag "--gateway-port"; then
    flags+=" --gateway-port ${OPENCLAW_GATEWAY_PORT}"
  fi

  if openclaw_onboard_supports_flag "--tailscale"; then
    flags+=" --tailscale ${OPENCLAW_TAILSCALE_MODE}"
  fi

  printf '%s' "$flags"
}

run_openclaw_onboard_interactive() {
  log_info "Запуск openclaw onboard (interactive)"

  local flags
  local daemon_flag
  flags="$(onboard_default_flags)"
  daemon_flag="$(onboard_daemon_flag)"
  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" onboard${daemon_flag}${flags}"
}

run_openclaw_onboard_non_interactive() {
  log_info "Запуск openclaw onboarding в non-interactive режиме"

  local cmd="${OPENCLAW_ENV_EXPORTS}"
  local daemon_flag
  daemon_flag="$(onboard_daemon_flag)"

  if [[ -n "${OPENCLAW_PROVIDER:-}" ]]; then
    cmd+=" export OPENCLAW_PROVIDER='${OPENCLAW_PROVIDER}';"
  fi
  if [[ -n "${OPENCLAW_MODEL:-}" ]]; then
    cmd+=" export OPENCLAW_MODEL='${OPENCLAW_MODEL}';"
  fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    cmd+=" export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}';"
  fi
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    cmd+=" export OPENAI_API_KEY='${OPENAI_API_KEY}';"
  fi
  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    cmd+=" export GEMINI_API_KEY='${GEMINI_API_KEY}';"
  fi

  cmd+=" \"${OPENCLAW_BIN_PATH}\" onboard${daemon_flag}"

  if openclaw_onboard_supports_flag "--non-interactive"; then
    cmd+=" --non-interactive"
  fi

  if openclaw_onboard_supports_flag "--provider" && [[ -n "${OPENCLAW_PROVIDER:-}" ]]; then
    cmd+=" --provider '${OPENCLAW_PROVIDER}'"
  fi

  if openclaw_onboard_supports_flag "--model" && [[ -n "${OPENCLAW_MODEL:-}" ]]; then
    cmd+=" --model '${OPENCLAW_MODEL}'"
  fi

  cmd+="$(onboard_default_flags)"

  if ! run_as_openclaw_sensitive "$cmd"; then
    log_warn "Non-interactive onboarding не удался, перехожу в interactive режим"
    run_openclaw_onboard_interactive
  fi
}

openclaw_systemctl_user_via_machine() {
  run_sudo systemctl --machine "openclaw@" --user "$@"
}

openclaw_systemctl_user_via_bus() {
  run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${OPENCLAW_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${OPENCLAW_UID}/bus" systemctl --user "$@"
}

detect_openclaw_systemctl_mode() {
  if [[ "${OPENCLAW_SYSTEMCTL_MODE}" == "machine" || "${OPENCLAW_SYSTEMCTL_MODE}" == "bus" ]]; then
    return 0
  fi

  if openclaw_systemctl_user_via_machine show-environment >/dev/null 2>&1; then
    OPENCLAW_SYSTEMCTL_MODE="machine"
    return 0
  fi

  if openclaw_systemctl_user_via_bus show-environment >/dev/null 2>&1; then
    OPENCLAW_SYSTEMCTL_MODE="bus"
    return 0
  fi

  OPENCLAW_SYSTEMCTL_MODE="unavailable"
  return 1
}

openclaw_systemctl_user() {
  if [[ "${OPENCLAW_SYSTEMCTL_MODE}" == "machine" ]]; then
    if openclaw_systemctl_user_via_machine "$@"; then
      return 0
    fi
    OPENCLAW_SYSTEMCTL_MODE=""
  elif [[ "${OPENCLAW_SYSTEMCTL_MODE}" == "bus" ]]; then
    if openclaw_systemctl_user_via_bus "$@"; then
      return 0
    fi
    OPENCLAW_SYSTEMCTL_MODE=""
  fi

  if ! detect_openclaw_systemctl_mode; then
    return 1
  fi

  if [[ "${OPENCLAW_SYSTEMCTL_MODE}" == "machine" ]]; then
    openclaw_systemctl_user_via_machine "$@"
    return $?
  fi

  openclaw_systemctl_user_via_bus "$@"
}

openclaw_systemd_available() {
  if ! detect_openclaw_systemctl_mode; then
    return 1
  fi
  openclaw_systemctl_user list-unit-files --type=service --no-legend >/dev/null 2>&1
}

onboard_daemon_flag() {
  if [[ "${OPENCLAW_USER_SYSTEMD_READY}" -eq 1 ]]; then
    printf ' --install-daemon'
    return 0
  fi

  log_warn "User-systemd недоступен, onboarding выполнится без --install-daemon; daemon подниму system fallback unit"
  printf ''
}

ensure_openclaw_user_systemd_runtime() {
  log_info "Проверка user-systemd runtime для openclaw"

  OPENCLAW_UID="$(sudo id -u openclaw)"
  OPENCLAW_USER_SYSTEMD_READY=0
  OPENCLAW_SYSTEMCTL_MODE=""

  if (( DRY_RUN )); then
    log_info "[dry-run] проверка user-systemd runtime пропущена"
    OPENCLAW_USER_SYSTEMD_READY=1
    return 0
  fi

  run_sudo loginctl enable-linger openclaw || true
  run_sudo systemctl enable "user-runtime-dir@${OPENCLAW_UID}.service" || true
  run_sudo systemctl start "user-runtime-dir@${OPENCLAW_UID}.service" || true
  run_sudo systemctl enable "user@${OPENCLAW_UID}.service" || true
  run_sudo systemctl start "user@${OPENCLAW_UID}.service" || true
  run_sudo install -d -m 0700 -o openclaw -g openclaw "/run/user/${OPENCLAW_UID}"
  run_sudo systemctl status "user@${OPENCLAW_UID}.service" --no-pager >/dev/null 2>&1 || true

  local attempt
  for attempt in $(seq 1 10); do
    if run_sudo test -S "/run/user/${OPENCLAW_UID}/bus"; then
      break
    fi
    sleep 1
  done

  if ! run_sudo test -S "/run/user/${OPENCLAW_UID}/bus"; then
    openclaw_systemctl_user start dbus.service || true
  fi

  if openclaw_systemd_available; then
    OPENCLAW_USER_SYSTEMD_READY=1
    return 0
  fi

  log_warn "systemd user services недоступны для openclaw (No medium found/нет user bus). Будет использован system-level fallback unit."
  return 0
}

ensure_openclaw_gateway_config() {
  log_info "Приведение gateway конфигурации к tailnet-only (loopback + tailscale serve)"

  local config_path="/home/openclaw/.openclaw/openclaw.json"

  if ! run_sudo test -f "$config_path"; then
    fatal 30 "Не найден конфиг OpenClaw: $config_path"
  fi

  if (( DRY_RUN )); then
    log_info "[dry-run] update $config_path (gateway.bind/port/tailscale)"
    return 0
  fi

  local dns="${OPENCLAW_TAILNET_DNS:-}"

  run_sudo python3 - "$config_path" "$OPENCLAW_GATEWAY_PORT" "$OPENCLAW_TAILSCALE_MODE" "$dns" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])
mode = sys.argv[3]
dns = sys.argv[4].strip()

raw = path.read_text()
cfg = json.loads(raw if raw.strip() else "{}")

gateway = cfg.get("gateway")
if not isinstance(gateway, dict):
    gateway = {}

gateway["mode"] = "local"
gateway["bind"] = "loopback"
gateway["port"] = port

tailscale = gateway.get("tailscale")
if not isinstance(tailscale, dict):
    tailscale = {}

tailscale["mode"] = mode
if "resetOnExit" not in tailscale:
    tailscale["resetOnExit"] = False

gateway["tailscale"] = tailscale

trusted_proxies = gateway.get("trustedProxies")
if not isinstance(trusted_proxies, list):
    trusted_proxies = []

normalized_proxies = []
seen_proxy_keys = set()
for item in trusted_proxies:
    value = str(item).strip()
    if not value:
        continue
    key = value.lower()
    if key in seen_proxy_keys:
        continue
    normalized_proxies.append(value)
    seen_proxy_keys.add(key)

for proxy in ("127.0.0.1", "::1"):
    if proxy.lower() not in seen_proxy_keys:
        normalized_proxies.append(proxy)
        seen_proxy_keys.add(proxy.lower())

gateway["trustedProxies"] = normalized_proxies

recommended_deny = [
    "canvas.present",
    "canvas.hide",
    "canvas.navigate",
    "canvas.eval",
    "canvas.snapshot",
    "canvas.a2ui.push",
    "canvas.a2ui.pushJSONL",
    "canvas.a2ui.reset",
]
recommended_deny_keys = {x.lower() for x in recommended_deny}
exact_cmd = re.compile(r"^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+$")

nodes = gateway.get("nodes")
if not isinstance(nodes, dict):
    nodes = {}

deny_commands = nodes.get("denyCommands")
if isinstance(deny_commands, list):
    sanitized = []
    seen_cmd_keys = set()
    has_ineffective_or_unknown = False

    for item in deny_commands:
        value = str(item).strip()
        if not value:
            continue
        if not exact_cmd.fullmatch(value):
            has_ineffective_or_unknown = True
            continue

        key = value.lower()
        if key not in recommended_deny_keys:
            has_ineffective_or_unknown = True
            continue
        if key in seen_cmd_keys:
            continue

        sanitized.append(value)
        seen_cmd_keys.add(key)

    if has_ineffective_or_unknown:
        for command in recommended_deny:
            key = command.lower()
            if key in seen_cmd_keys:
                continue
            sanitized.append(command)
            seen_cmd_keys.add(key)
        nodes["denyCommands"] = sanitized
        gateway["nodes"] = nodes

if dns:
    origin = f"https://{dns}"
    control_ui = gateway.get("controlUi")
    if not isinstance(control_ui, dict):
        control_ui = {}
    allowed = control_ui.get("allowedOrigins")
    if not isinstance(allowed, list):
        allowed = []
    if origin.lower() not in {str(x).lower() for x in allowed}:
        allowed.append(origin)
    control_ui["allowedOrigins"] = allowed
    gateway["controlUi"] = control_ui

cfg["gateway"] = gateway

channels = cfg.get("channels")
if isinstance(channels, dict):
    telegram = channels.get("telegram")
    if isinstance(telegram, dict):
        policy = str(telegram.get("groupPolicy", "")).strip().lower()

        def has_entries(value):
            return isinstance(value, list) and any(str(x).strip() for x in value)

        if policy == "allowlist":
            if not has_entries(telegram.get("groupAllowFrom")) and not has_entries(telegram.get("allowFrom")):
                telegram["groupPolicy"] = "disabled"
                channels["telegram"] = telegram
                cfg["channels"] = channels

path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
PY

  run_sudo chown openclaw:openclaw "$config_path"
  run_as_openclaw "mkdir -p ~/.openclaw/credentials && chmod 700 ~/.openclaw/credentials"
}

harden_openclaw_state_permissions() {
  log_info "Ужесточение прав на state OpenClaw"

  run_sudo install -d -m 0700 -o openclaw -g openclaw /home/openclaw/.openclaw
  run_sudo chown openclaw:openclaw /home/openclaw/.openclaw || true
  run_sudo chmod 700 /home/openclaw/.openclaw || true
  run_sudo chmod 600 /home/openclaw/.openclaw/openclaw.json || true
}

openclaw_doctor_supports_flag() {
  local flag="$1"
  if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" doctor --help 2>/dev/null | grep -q -- \"$flag\""; then
    return 0
  fi
  return 1
}

restart_openclaw_gateway_service_unit() {
  if [[ -z "${OPENCLAW_GATEWAY_UNIT:-}" ]]; then
    return 1
  fi

  if [[ "${OPENCLAW_SERVICE_SCOPE}" == "user" ]]; then
    openclaw_systemctl_user restart "$OPENCLAW_GATEWAY_UNIT"
    return $?
  fi

  run_sudo systemctl restart "$OPENCLAW_GATEWAY_UNIT"
}

openclaw_gateway_service_path() {
  printf '%s' "/home/openclaw/.local/share/pnpm:/home/openclaw/.npm-global/bin:/home/openclaw/.local/bin:/home/openclaw/bin:/home/openclaw/.volta/bin:/home/openclaw/.asdf/shims:/home/openclaw/.bun/bin:/home/openclaw/.nvm/current/bin:/home/openclaw/.fnm/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

read_openclaw_gateway_token() {
  run_sudo python3 - <<'PY'
import json
from pathlib import Path

path = Path("/home/openclaw/.openclaw/openclaw.json")
if not path.exists():
    raise SystemExit(0)

try:
    cfg = json.loads(path.read_text() or "{}")
except json.JSONDecodeError:
    raise SystemExit(0)

gateway = cfg.get("gateway")
if not isinstance(gateway, dict):
    raise SystemExit(0)

auth = gateway.get("auth")
if not isinstance(auth, dict):
    raise SystemExit(0)

token = auth.get("token")
if isinstance(token, str) and token.strip():
    print(token.strip())
PY
}

openclaw_gateway_execstart() {
  local resolved
  resolved="$(run_as_openclaw "${OPENCLAW_ENV_EXPORTS} readlink -f \"${OPENCLAW_BIN_PATH}\" 2>/dev/null || true" | tail -n1 | tr -d '\r')"
  if [[ -n "$resolved" && "$resolved" == *.js ]]; then
    printf '/usr/bin/node %s gateway --port %s' "$resolved" "$OPENCLAW_GATEWAY_PORT"
    return 0
  fi

  printf '%s gateway --port %s' "$OPENCLAW_BIN_PATH" "$OPENCLAW_GATEWAY_PORT"
}

list_openclaw_gateway_user_units() {
  openclaw_systemctl_user list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^openclaw-gateway.*\.service$' \
    | sort -u || true
}

detect_openclaw_gateway_unit() {
  local unit
  unit="$(list_openclaw_gateway_user_units | head -n1 || true)"
  if [[ -z "$unit" ]]; then
    return 1
  fi

  OPENCLAW_GATEWAY_UNIT="$unit"
  return 0
}

openclaw_devices_approve_supports_flag() {
  local flag="$1"
  if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" devices approve --help 2>/dev/null | grep -q -- \"$flag\""; then
    return 0
  fi
  return 1
}

attempt_openclaw_pairing_repair() {
  log_warn "gateway probe вернул pairing required. Пытаюсь auto-approve pending devices."
  local base_cmd="${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" devices approve --all"

  if openclaw_devices_approve_supports_flag "--yes"; then
    if run_as_openclaw "${base_cmd} --yes"; then
      return 0
    fi
  fi

  if openclaw_devices_approve_supports_flag "--non-interactive"; then
    if run_as_openclaw "${base_cmd} --non-interactive"; then
      return 0
    fi
  fi

  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} printf 'yes\n' | \"${OPENCLAW_BIN_PATH}\" devices approve --all"
}

attempt_openclaw_gateway_service_repair() {
  log_warn "Пробую repair через openclaw gateway install --force"

  if ! run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway install --force"; then
    log_warn "gateway install --force вернул ошибку; продолжаю с проверкой unit вручную"
  fi

  if [[ "${OPENCLAW_SERVICE_SCOPE}" == "user" ]]; then
    if ! detect_openclaw_gateway_unit; then
      return 1
    fi
    openclaw_systemctl_user daemon-reload || true
    openclaw_systemctl_user enable "$OPENCLAW_GATEWAY_UNIT" || true
  fi

  restart_openclaw_gateway_service_unit
}

install_user_gateway_service_fallback() {
  log_warn "gateway install через user-systemd завершился ошибкой, пробую ручной user-unit"

  OPENCLAW_SERVICE_SCOPE="user"
  OPENCLAW_GATEWAY_UNIT="openclaw-gateway.service"

  local unit_path="/home/openclaw/.config/systemd/user/${OPENCLAW_GATEWAY_UNIT}"
  local unit_tmp
  local service_path
  local gateway_token
  local exec_start
  unit_tmp="$(mktemp)"
  service_path="$(openclaw_gateway_service_path)"
  gateway_token="$(read_openclaw_gateway_token)"
  exec_start="$(openclaw_gateway_execstart)"

  cat > "$unit_tmp" <<EOF
[Unit]
Description=OpenClaw Gateway (manual user-unit fallback, port ${OPENCLAW_GATEWAY_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/openclaw
Environment=HOME=/home/openclaw
Environment=PATH=${service_path}
Environment=OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}
Environment=OPENCLAW_CONFIG=/home/openclaw/.openclaw/openclaw.json
${gateway_token:+Environment=OPENCLAW_GATEWAY_TOKEN=${gateway_token}}
ExecStart=${exec_start}
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF

  run_sudo install -d -m 0755 -o openclaw -g openclaw /home/openclaw/.config/systemd/user
  write_root_file "$unit_tmp" "$unit_path" 0644 openclaw openclaw

  rm -f "$unit_tmp"

  if ! openclaw_systemctl_user daemon-reload; then
    return 1
  fi
  if ! openclaw_systemctl_user enable "$OPENCLAW_GATEWAY_UNIT"; then
    return 1
  fi
  if ! openclaw_systemctl_user restart "$OPENCLAW_GATEWAY_UNIT"; then
    return 1
  fi
  if ! openclaw_systemctl_user is-active "$OPENCLAW_GATEWAY_UNIT" >/dev/null 2>&1; then
    openclaw_systemctl_user status "$OPENCLAW_GATEWAY_UNIT" --no-pager || true
    return 1
  fi

  return 0
}

install_system_gateway_service_fallback() {
  log_warn "User-systemd недоступен для OpenClaw daemon, включаю system-level fallback (User=openclaw)"

  OPENCLAW_SERVICE_SCOPE="system"
  OPENCLAW_GATEWAY_UNIT="openclaw-gateway-host.service"

  local unit_tmp
  local service_path
  local gateway_token
  local exec_start
  unit_tmp="$(mktemp)"
  service_path="$(openclaw_gateway_service_path)"
  gateway_token="$(read_openclaw_gateway_token)"
  exec_start="$(openclaw_gateway_execstart)"

  cat > "$unit_tmp" <<EOF
[Unit]
Description=OpenClaw Gateway Host (system fallback)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw
Environment=HOME=/home/openclaw
Environment=PATH=${service_path}
Environment=OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}
Environment=OPENCLAW_CONFIG=/home/openclaw/.openclaw/openclaw.json
${gateway_token:+Environment=OPENCLAW_GATEWAY_TOKEN=${gateway_token}}
ExecStart=${exec_start}
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  write_root_file "$unit_tmp" "/etc/systemd/system/${OPENCLAW_GATEWAY_UNIT}" 0644 root root

  rm -f "$unit_tmp"

  run_sudo systemctl daemon-reload
  run_sudo systemctl enable --now "${OPENCLAW_GATEWAY_UNIT}"

  if ! run_sudo systemctl is-active --quiet "${OPENCLAW_GATEWAY_UNIT}"; then
    run_sudo systemctl status "${OPENCLAW_GATEWAY_UNIT}" --no-pager || true
    fatal 30 "System fallback unit не перешел в active: ${OPENCLAW_GATEWAY_UNIT}"
  fi
}

install_and_start_gateway_service() {
  log_info "Установка и запуск gateway service OpenClaw"

  if [[ "${OPENCLAW_USER_SYSTEMD_READY}" -ne 1 ]]; then
    install_system_gateway_service_fallback
    return 0
  fi

  OPENCLAW_SERVICE_SCOPE="user"
  local install_failed=0
  if ! run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway install --force"; then
    install_failed=1
    log_warn "gateway install --force вернул ошибку; проверяю фактический статус user-unit"
  fi

  if detect_openclaw_gateway_unit; then
    openclaw_systemctl_user daemon-reload || true
    openclaw_systemctl_user enable "$OPENCLAW_GATEWAY_UNIT" || true

    if openclaw_systemctl_user restart "$OPENCLAW_GATEWAY_UNIT" && openclaw_systemctl_user is-active "$OPENCLAW_GATEWAY_UNIT" >/dev/null 2>&1; then
      if [[ "$install_failed" -eq 1 ]]; then
        log_warn "gateway install вернул ошибку, но unit активен; продолжаю"
      fi
      return 0
    fi

    openclaw_systemctl_user status "$OPENCLAW_GATEWAY_UNIT" --no-pager || true
  else
    log_warn "После gateway install не найден unit openclaw-gateway*.service"
  fi

  if install_user_gateway_service_fallback; then
    return 0
  fi

  install_system_gateway_service_fallback
}

configure_tailscale_https_endpoint() {
  log_info "Публикация Web UI через Tailscale HTTPS"

  local target="http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}"
  local configured=0

  run_sudo tailscale serve reset || true

  if run_sudo tailscale serve --bg --https=443 "$target"; then
    configured=1
  elif run_sudo tailscale serve --bg --https=443 / "$target"; then
    configured=1
  elif run_sudo tailscale serve --bg 443 "$target"; then
    configured=1
  elif run_sudo tailscale serve --bg / "$target"; then
    configured=1
  fi

  if [[ "$configured" -ne 1 ]]; then
    run_sudo tailscale serve status || true
    fatal 30 "Не удалось настроить tailscale serve для Web UI"
  fi

  run_sudo tailscale serve status || true
  OPENCLAW_TAILNET_DNS="$(tailscale_dns_name)"
}

wait_for_gateway_probe() {
  log_info "Проверка доступности gateway"

  local attempt
  local pairing_repaired=0
  local service_repaired=0
  local last_probe_error=""
  for attempt in $(seq 1 30); do
    local probe_output
    if probe_output="$(run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway probe" 2>&1)"; then
      log_success "Gateway успешно отвечает на probe"
      return 0
    fi

    last_probe_error="$probe_output"

    if printf '%s' "$probe_output" | grep -qi 'pairing required'; then
      if [[ "$pairing_repaired" -eq 0 ]]; then
        pairing_repaired=1
        if attempt_openclaw_pairing_repair; then
          sleep 1
          continue
        fi
      fi

      if [[ "$service_repaired" -eq 0 ]]; then
        service_repaired=1
        if attempt_openclaw_gateway_service_repair; then
          sleep 1
          continue
        fi
      fi

      sleep 2
      continue
    fi

    if [[ "$service_repaired" -eq 0 ]]; then
      service_repaired=1
      if attempt_openclaw_gateway_service_repair; then
        sleep 1
        continue
      fi
    fi

    sleep 2
  done

  if [[ -n "$last_probe_error" ]]; then
    log_warn "Последняя ошибка probe: ${last_probe_error}"
  fi
  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway status --deep || true"
  fatal 30 "Gateway не отвечает после запуска сервиса"
}

run_openclaw_health_checks() {
  log_info "Проверка состояния OpenClaw"

  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" status"

  if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" security audit --help 2>/dev/null | grep -q -- '--fix'"; then
    run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" security audit --fix" || true
  fi

  if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" doctor --help 2>/dev/null | grep -q -- '--non-interactive'"; then
    run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" doctor --non-interactive" || true
  else
    run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" doctor" || true
  fi

  if run_sudo grep -R -E '0\.0\.0\.0|"host"\s*:\s*"0.0.0.0"' /home/openclaw/.openclaw >/dev/null 2>&1; then
    fatal 30 "Обнаружены признаки публичного bind в конфиге OpenClaw (ожидался loopback)"
  fi

  if ! tailscale_online; then
    fatal 30 "Tailscale ушел в offline после настройки OpenClaw"
  fi
}

print_openclaw_summary() {
  local dns="${OPENCLAW_TAILNET_DNS:-$(tailscale_dns_name)}"

  log_success "OpenClaw этап завершен"
  if [[ -n "$OPENCLAW_GATEWAY_UNIT" ]]; then
    log_info "Gateway unit: ${OPENCLAW_GATEWAY_UNIT} (scope=${OPENCLAW_SERVICE_SCOPE})"
  fi

  log_info "Local UI: http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/"

  if [[ -n "$dns" ]]; then
    log_info "Tailscale UI: https://${dns}/"
  else
    log_warn "Не удалось определить Tailnet DNS имя для HTTPS URL"
  fi
}

run_openclaw_mode() {
  ensure_openclaw_preflight
  collect_openclaw_inputs_ru

  ensure_tailscale_online
  ensure_openclaw_user_pnpm_layout

  if ! attempt_official_openclaw_install; then
    log_warn "Официальный installer недоступен или завершился ошибкой, использую native fallback"
    fallback_install_with_pnpm
  fi

  verify_openclaw_binary
  ensure_openclaw_user_systemd_runtime

  if [[ "${OPENCLAW_ONBOARD:-interactive}" == "non_interactive" ]]; then
    run_openclaw_onboard_non_interactive
  else
    run_openclaw_onboard_interactive
  fi

  ensure_openclaw_gateway_config
  harden_openclaw_state_permissions
  install_and_start_gateway_service
  wait_for_gateway_probe
  configure_tailscale_https_endpoint
  run_openclaw_health_checks

  state_set_bool openclaw_completed true
  state_set_string openclaw_completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  print_openclaw_summary
}
