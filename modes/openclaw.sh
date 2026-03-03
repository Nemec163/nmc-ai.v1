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
  if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" onboard --help 2>/dev/null | grep -q -- '$flag'"; then
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

openclaw_systemctl_user() {
  run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${OPENCLAW_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${OPENCLAW_UID}/bus" systemctl --user "$@"
}

openclaw_systemd_available() {
  openclaw_systemctl_user show-environment >/dev/null 2>&1
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

  if (( DRY_RUN )); then
    log_info "[dry-run] проверка user-systemd runtime пропущена"
    OPENCLAW_USER_SYSTEMD_READY=1
    return 0
  fi

  run_sudo loginctl enable-linger openclaw || true
  run_sudo systemctl enable "user@${OPENCLAW_UID}.service" || true
  run_sudo systemctl start "user@${OPENCLAW_UID}.service" || true
  run_sudo install -d -m 0700 -o openclaw -g openclaw "/run/user/${OPENCLAW_UID}"
  run_sudo systemctl status "user@${OPENCLAW_UID}.service" --no-pager >/dev/null 2>&1 || true

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
path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n")
PY

  run_sudo chown openclaw:openclaw "$config_path"
  run_as_openclaw "mkdir -p ~/.openclaw/credentials && chmod 700 ~/.openclaw/credentials"
}

install_system_gateway_service_fallback() {
  log_warn "User-systemd недоступен для OpenClaw daemon, включаю system-level fallback (User=openclaw)"

  OPENCLAW_SERVICE_SCOPE="system"
  OPENCLAW_GATEWAY_UNIT="openclaw-gateway-host.service"

  local launch_script="/home/openclaw/.local/bin/openclaw-gateway-run.sh"
  local unit_tmp
  local launch_tmp
  unit_tmp="$(mktemp)"
  launch_tmp="$(mktemp)"

cat > "$launch_tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
${OPENCLAW_ENV_EXPORTS}
if "${OPENCLAW_BIN_PATH}" gateway run --help 2>/dev/null | grep -q -- '--allow-unconfigured'; then
  exec "${OPENCLAW_BIN_PATH}" gateway run --allow-unconfigured
else
  exec "${OPENCLAW_BIN_PATH}" gateway run
fi
EOF

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
ExecStart=${launch_script}
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  write_root_file "$launch_tmp" "$launch_script" 0755 openclaw openclaw
  write_root_file "$unit_tmp" "/etc/systemd/system/${OPENCLAW_GATEWAY_UNIT}" 0644 root root

  rm -f "$unit_tmp" "$launch_tmp"

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

  if ! run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway install --force"; then
    log_warn "gateway install через user-systemd завершился ошибкой"
    install_system_gateway_service_fallback
    return 0
  fi

  local unit
  unit="$(openclaw_systemctl_user list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^openclaw-gateway.*\\.service$' | head -n1 || true)"
  if [[ -z "$unit" ]]; then
    log_warn "После gateway install не найден unit openclaw-gateway*.service"
    install_system_gateway_service_fallback
    return 0
  fi

  OPENCLAW_GATEWAY_UNIT="$unit"

  openclaw_systemctl_user daemon-reload
  openclaw_systemctl_user enable "$OPENCLAW_GATEWAY_UNIT"
  openclaw_systemctl_user restart "$OPENCLAW_GATEWAY_UNIT"

  if ! openclaw_systemctl_user is-active "$OPENCLAW_GATEWAY_UNIT" >/dev/null 2>&1; then
    openclaw_systemctl_user status "$OPENCLAW_GATEWAY_UNIT" --no-pager || true
    fatal 30 "Gateway unit не перешел в active: $OPENCLAW_GATEWAY_UNIT"
  fi
}

configure_tailscale_https_endpoint() {
  log_info "Публикация Web UI через Tailscale HTTPS"

  local target="http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}"
  local configured=0

  run_sudo tailscale serve reset || true

  if run_sudo tailscale serve --bg --https=443 / "$target"; then
    configured=1
  elif run_sudo tailscale serve --bg --https=443 "$target"; then
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
  for attempt in $(seq 1 30); do
    if run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway probe >/dev/null 2>&1"; then
      log_success "Gateway успешно отвечает на probe"
      return 0
    fi
    sleep 2
  done

  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" gateway status --deep || true"
  fatal 30 "Gateway не отвечает после запуска сервиса"
}

run_openclaw_health_checks() {
  log_info "Проверка состояния OpenClaw"

  run_as_openclaw "${OPENCLAW_ENV_EXPORTS} \"${OPENCLAW_BIN_PATH}\" status"

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
  install_and_start_gateway_service
  wait_for_gateway_probe
  configure_tailscale_https_endpoint
  run_openclaw_health_checks

  state_set_bool openclaw_completed true
  state_set_string openclaw_completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  print_openclaw_summary
}
