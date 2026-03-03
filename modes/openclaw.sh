#!/usr/bin/env bash

OPENCLAW_INSTALLER_URLS_DEFAULT="https://install.openclaw.ai/installer.sh https://openclaw.ai/install.sh"

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

  require_cmd curl sudo bash || fatal 30 "Не хватает базовых команд для установки OpenClaw"
}

ensure_openclaw_user_pnpm_layout() {
  log_info "Подготовка pnpm окружения пользователя openclaw"

  run_as_openclaw "mkdir -p ~/.local/bin ~/.local/share/pnpm ~/.local/share/pnpm/store"
  run_as_openclaw "pnpm config set global-dir ~/.local/share/pnpm"
  run_as_openclaw "pnpm config set global-bin-dir ~/.local/bin"

  local block
  block=$(cat <<'BLOCK'
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$HOME/.local/bin:$PNPM_HOME:$PATH"
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
  run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; pnpm install -g openclaw@latest"
}

verify_openclaw_binary() {
  log_info "Проверка установленного OpenClaw"
  run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw --version"
}

openclaw_onboard_supports_flag() {
  local flag="$1"
  if run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw onboard --help 2>/dev/null | grep -q -- '$flag'"; then
    return 0
  fi
  return 1
}

run_openclaw_onboard_interactive() {
  log_info "Запуск openclaw onboard --install-daemon (interactive)"
  run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw onboard --install-daemon"
}

run_openclaw_onboard_non_interactive() {
  log_info "Запуск openclaw onboarding в non-interactive режиме"

  local cmd="export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\";"

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

  cmd+=" openclaw onboard --install-daemon"

  if openclaw_onboard_supports_flag "--non-interactive"; then
    cmd+=" --non-interactive"
  fi

  if openclaw_onboard_supports_flag "--provider" && [[ -n "${OPENCLAW_PROVIDER:-}" ]]; then
    cmd+=" --provider '${OPENCLAW_PROVIDER}'"
  fi

  if openclaw_onboard_supports_flag "--model" && [[ -n "${OPENCLAW_MODEL:-}" ]]; then
    cmd+=" --model '${OPENCLAW_MODEL}'"
  fi

  if ! run_as_openclaw_sensitive "$cmd"; then
    log_warn "Non-interactive onboarding не удался, перехожу в interactive режим"
    run_openclaw_onboard_interactive
  fi
}

verify_openclaw_service() {
  log_info "Проверка user-systemd сервиса OpenClaw"

  local uid
  uid="$(sudo id -u openclaw)"

  run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user daemon-reload || true

  if run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user is-active openclaw >/dev/null 2>&1; then
    log_success "User service openclaw активен"
    return 0
  fi

  if run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user list-units --type=service --all | grep -qi openclaw; then
    run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user start openclaw || true
  fi

  if run_sudo -iu openclaw env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user list-units --type=service --all | grep -qi openclaw; then
    log_info "Обнаружен user service с именем, содержащим openclaw"
  else
    log_warn "Не найден user-systemd unit с openclaw в имени"
  fi
}

run_openclaw_health_checks() {
  log_info "Проверка состояния OpenClaw"

  run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw status" || true

  if run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw doctor --help 2>/dev/null | grep -q -- '--non-interactive'"; then
    run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw doctor --non-interactive" || true
  else
    run_as_openclaw "export PNPM_HOME=\"$HOME/.local/share/pnpm\"; export PATH=\"$HOME/.local/bin:$HOME/.local/share/pnpm:$PATH\"; openclaw doctor" || true
  fi

  if run_sudo grep -R -E '0\.0\.0\.0|"host"\s*:\s*"0.0.0.0"' /home/openclaw/.openclaw >/dev/null 2>&1; then
    log_warn "Обнаружены признаки публичного bind в конфиге OpenClaw. Проверьте tailnet-only конфигурацию"
  else
    log_success "Явных признаков публичного bind в конфиге OpenClaw не найдено"
  fi
}

run_openclaw_mode() {
  ensure_openclaw_preflight
  collect_openclaw_inputs_ru

  ensure_openclaw_user_pnpm_layout

  if ! attempt_official_openclaw_install; then
    log_warn "Официальный installer недоступен или завершился ошибкой, использую native fallback"
    fallback_install_with_pnpm
  fi

  verify_openclaw_binary

  if [[ "${OPENCLAW_ONBOARD:-interactive}" == "non_interactive" ]]; then
    run_openclaw_onboard_non_interactive
  else
    run_openclaw_onboard_interactive
  fi

  verify_openclaw_service
  run_openclaw_health_checks

  state_set_bool openclaw_completed true
  state_set_string openclaw_completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  log_success "OpenClaw этап завершен"
  log_info "Docker sandbox OpenClaw целенаправленно не настраивался (по вашей политике)."
}
