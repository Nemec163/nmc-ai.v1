#!/usr/bin/env bash

INFRA_BASE_PACKAGES=(
  curl
  ca-certificates
  gnupg
  lsb-release
  jq
  git
  ufw
  fail2ban
  unattended-upgrades
  apt-listchanges
)

DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

ensure_infra_preflight() {
  log_info "Проверка preflight (infra)"

  if [[ "$EUID" -eq 0 ]]; then
    log_warn "Запуск от root разрешен (bootstrap режим). Root SSH будет оставлен только по ключу."
  fi

  if ! supported_ubuntu; then
    fatal 10 "Поддерживаются только Ubuntu 22.04 и 24.04"
  fi

  require_cmd sudo systemctl apt-get python3 || fatal 10 "Отсутствуют обязательные команды для запуска"
  ensure_sudo_access || fatal 10 "Sudo-права обязательны"

  if ! run_cmd systemctl --version >/dev/null 2>&1; then
    fatal 10 "Systemd недоступен"
  fi

  state_init
}

configure_openclaw_user() {
  log_info "Настройка пользователя openclaw"

  if sudo id -u openclaw >/dev/null 2>&1; then
    log_info "Пользователь openclaw уже существует"
  else
    run_sudo useradd -m -s /bin/bash openclaw
    log_success "Пользователь openclaw создан"
  fi

  run_sudo usermod -aG sudo openclaw

  if [[ -n "${OPENCLAW_PASSWORD:-}" ]]; then
    if (( DRY_RUN )); then
      log_info "[dry-run] set password for openclaw"
    else
      printf 'openclaw:%s\n' "$OPENCLAW_PASSWORD" | sudo chpasswd
    fi
  fi

  run_sudo loginctl enable-linger openclaw || true
}

configure_openclaw_ssh_keys() {
  log_info "Настройка authorized_keys для openclaw"

  local invoking_user_home
  invoking_user_home="$(getent passwd "$INVOKING_USER" | cut -d: -f6 || true)"
  if [[ -z "$invoking_user_home" ]]; then
    fatal 20 "Не удалось определить home для пользователя $INVOKING_USER"
  fi

  local temp_keys
  temp_keys="$(mktemp)"

  if sudo test -f /home/openclaw/.ssh/authorized_keys >/dev/null 2>&1; then
    sudo cat /home/openclaw/.ssh/authorized_keys >> "$temp_keys" || true
  fi

  if [[ -f "$invoking_user_home/.ssh/authorized_keys" ]]; then
    cat "$invoking_user_home/.ssh/authorized_keys" >> "$temp_keys"
  else
    log_warn "У пользователя $INVOKING_USER нет ~/.ssh/authorized_keys, копирование пропущено"
  fi

  if [[ -n "${EXTRA_SSH_KEYS:-}" ]]; then
    printf '%s' "$EXTRA_SSH_KEYS" | tr ';' '\n' >> "$temp_keys"
  fi

  local filtered_keys
  filtered_keys="$(mktemp)"
  awk 'NF > 1 && ($1 ~ /^ssh-/ || $1 ~ /^ecdsa-/) {print}' "$temp_keys" | sed 's/[[:space:]]\+$//' | sort -u > "$filtered_keys"

  run_sudo install -d -m 0700 -o openclaw -g openclaw /home/openclaw/.ssh
  write_root_file "$filtered_keys" /home/openclaw/.ssh/authorized_keys 0600 openclaw openclaw

  rm -f "$temp_keys" "$filtered_keys"
}

install_base_components() {
  log_info "Установка базовых пакетов"
  run_sudo apt-get update -y
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${INFRA_BASE_PACKAGES[@]}"
}

install_docker() {
  log_info "Установка Docker CE (без docker group для openclaw)"

  run_sudo install -d -m 0755 /etc/apt/keyrings

  if ! sudo test -f /etc/apt/keyrings/docker.gpg >/dev/null 2>&1; then
    run_sudo bash -lc "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    run_sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  if ! sudo test -f /etc/apt/sources.list.d/docker.list >/dev/null 2>&1; then
    run_sudo bash -lc "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable' > /etc/apt/sources.list.d/docker.list"
  fi

  run_sudo apt-get update -y
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${DOCKER_PACKAGES[@]}"
  run_sudo systemctl enable --now docker

  if sudo id -nG openclaw | grep -qw docker; then
    log_warn "openclaw состоит в группе docker, удаляю для соблюдения политики безопасности"
    run_sudo gpasswd -d openclaw docker || true
  fi

  if sudo test -f /etc/docker/daemon.json >/dev/null 2>&1 && ! sudo test -f /etc/docker/daemon.json.nmc-ai.v1.bak >/dev/null 2>&1; then
    run_sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.nmc-ai.v1.bak
  fi

  write_root_file "$SCRIPT_ROOT/templates/docker-daemon.json" /etc/docker/daemon.json 0644 root root
  run_sudo systemctl restart docker
}

install_nodejs_and_pnpm() {
  log_info "Установка Node.js 22.x и pnpm"

  run_sudo install -d -m 0755 /etc/apt/keyrings

  if ! sudo test -f /etc/apt/keyrings/nodesource.gpg >/dev/null 2>&1; then
    run_sudo bash -lc "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg"
    run_sudo chmod a+r /etc/apt/keyrings/nodesource.gpg
  fi

  if ! sudo test -f /etc/apt/sources.list.d/nodesource.list >/dev/null 2>&1; then
    run_sudo bash -lc "echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' > /etc/apt/sources.list.d/nodesource.list"
  fi

  run_sudo apt-get update -y
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

  if ! command -v pnpm >/dev/null 2>&1; then
    run_sudo npm install -g pnpm
  fi
}

configure_fail2ban_and_unattended() {
  log_info "Настройка fail2ban и unattended-upgrades"

  write_root_file "$SCRIPT_ROOT/templates/fail2ban-jail.local" /etc/fail2ban/jail.local 0644 root root
  run_sudo systemctl enable --now fail2ban
  run_sudo systemctl restart fail2ban

  if (( DRY_RUN )); then
    log_info "[dry-run] write unattended-upgrades config"
    return 0
  fi

  run_sudo bash -lc "cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CFG'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
CFG"

  run_sudo bash -lc "cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'CFG'
Unattended-Upgrade::Allowed-Origins {
    \"\${distro_id}:\${distro_codename}-security\";
    \"\${distro_id}ESMApps:\${distro_codename}-apps-security\";
    \"\${distro_id}ESM:\${distro_codename}-infra-security\";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg \"true\";
Unattended-Upgrade::MinimalSteps \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
Unattended-Upgrade::Automatic-Reboot \"false\";
CFG"
}

configure_ufw_with_docker_isolation() {
  log_info "Настройка UFW и изоляции Docker"

  run_sudo ufw --force reset
  run_sudo ufw default deny incoming
  run_sudo ufw default allow outgoing
  run_sudo ufw default deny routed

  run_sudo ufw allow 22/tcp comment 'SSH temporary'
  run_sudo ufw allow 41641/udp comment 'Tailscale'

  local docker_user_block
  docker_user_block=$(cat <<'BLOCK'
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -i lo -j ACCEPT
-A DOCKER-USER -j DROP
BLOCK
)

  ensure_block_in_file "/etc/ufw/after.rules" "NMC-AI.V1 DOCKER ISOLATION" "^COMMIT$" "$docker_user_block"

  run_sudo ufw --force enable
  run_sudo ufw reload
}

install_and_connect_tailscale() {
  log_info "Установка и подключение Tailscale"

  if ! sudo test -f /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null 2>&1; then
    run_sudo bash -lc "curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(. /etc/os-release && echo \"$VERSION_CODENAME\").noarmor.gpg > /usr/share/keyrings/tailscale-archive-keyring.gpg"
  fi

  if ! sudo test -f /etc/apt/sources.list.d/tailscale.list >/dev/null 2>&1; then
    run_sudo bash -lc "curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(. /etc/os-release && echo \"$VERSION_CODENAME\").tailscale-keyring.list > /etc/apt/sources.list.d/tailscale.list"
  fi

  run_sudo apt-get update -y
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
  run_sudo systemctl enable --now tailscaled

  if tailscale_connected; then
    log_info "Tailscale уже подключен"
    return 0
  fi

  if [[ "${TAILSCALE_AUTH_MODE}" == "authkey" ]]; then
    run_sudo tailscale up --authkey "${TAILSCALE_AUTHKEY}"
  else
    log_info "Запускаю интерактивный tailscale up"
    run_sudo tailscale up
  fi

  if ! tailscale_connected; then
    fatal 40 "Tailscale не подключен, блокировка внешнего SSH небезопасна"
  fi
}

tailscale_connected() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 1
  fi

  local json
  json="$(sudo tailscale status --json 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    return 1
  fi

  printf '%s' "$json" | jq -e '.BackendState == "Running" and ((.TailscaleIPs // []) | length > 0)' >/dev/null 2>&1
}

lockdown_ssh_to_tailscale_only() {
  log_info "Перевод SSH в режим только через Tailscale"

  if ! tailscale_connected; then
    fatal 40 "Tailscale не активен, отмена lock-down"
  fi

  run_sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH via Tailscale'

  # Удаляем публичные разрешения SSH.
  run_sudo ufw --force delete allow 22/tcp || true
  run_sudo ufw --force delete allow OpenSSH || true

  run_sudo ufw reload

  if (( ! DRY_RUN )) && sudo ufw status | grep -E "22/tcp" | grep -vq "tailscale0"; then
    fatal 40 "Обнаружен публичный SSH rule после lock-down"
  fi
}

harden_sshd() {
  log_info "SSH hardening"

  write_root_file "$SCRIPT_ROOT/templates/sshd-hardening.conf" /etc/ssh/sshd_config.d/99-openclaw-hardening.conf 0644 root root
  run_sudo sshd -t

  if run_sudo systemctl is-active ssh >/dev/null 2>&1; then
    run_sudo systemctl reload ssh
  else
    run_sudo systemctl reload sshd
  fi
}

harden_openclaw_sudo_policy() {
  log_info "Применение sudo hardening для openclaw"

  write_root_file "$SCRIPT_ROOT/templates/sudoers-openclaw-hardening" /etc/sudoers.d/openclaw-hardening 0440 root root
  run_sudo visudo -cf /etc/sudoers.d/openclaw-hardening
}

infra_summary() {
  local tailnet_ip="N/A"
  if tailscale_connected; then
    tailnet_ip="$(sudo tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi

  log_success "Infra этап завершен"
  log_info "Tailnet IP: ${tailnet_ip}"
  run_sudo ufw status verbose || true
}

run_infra_mode() {
  ensure_infra_preflight
  collect_infra_inputs_ru

  install_base_components
  configure_openclaw_user
  configure_openclaw_ssh_keys
  install_docker
  install_nodejs_and_pnpm
  configure_fail2ban_and_unattended
  configure_ufw_with_docker_isolation
  install_and_connect_tailscale
  lockdown_ssh_to_tailscale_only
  harden_sshd
  harden_openclaw_sudo_policy

  state_set_bool infra_completed true
  state_set_string infra_completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  infra_summary
}
