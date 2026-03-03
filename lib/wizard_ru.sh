#!/usr/bin/env bash

prompt_text_ru() {
  local prompt="$1"
  local default_value="${2:-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " value
    if [[ -z "$value" ]]; then
      value="$default_value"
    fi
  else
    read -r -p "$prompt: " value
  fi
  printf '%s' "$value"
}

prompt_secret_confirm_ru() {
  local prompt="$1"
  local v1=""
  local v2=""

  while true; do
    read -r -s -p "$prompt: " v1
    printf '\n'
    read -r -s -p "Повторите ввод: " v2
    printf '\n'

    if [[ -z "$v1" ]]; then
      log_warn "Значение не может быть пустым."
      continue
    fi

    if [[ "$v1" != "$v2" ]]; then
      log_warn "Значения не совпадают, повторите ввод."
      continue
    fi

    printf '%s' "$v1"
    return 0
  done
}

prompt_choice_ru() {
  local prompt="$1"
  shift
  local options=("$@")
  local idx=1
  local ans

  printf "%s\n" "$prompt"
  for opt in "${options[@]}"; do
    printf "  %d) %s\n" "$idx" "$opt"
    idx=$((idx + 1))
  done

  while true; do
    read -r -p "Выберите номер: " ans
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#options[@]} )); then
      printf '%s' "${options[$((ans - 1))]}"
      return 0
    fi
    log_warn "Некорректный выбор, введите номер из списка."
  done
}

collect_infra_inputs_ru() {
  if (( NON_INTERACTIVE )); then
    if [[ -z "${OPENCLAW_PASSWORD:-}" ]]; then
      fatal 10 "В non-interactive режиме требуется OPENCLAW_PASSWORD"
    fi

    if [[ -z "${TAILSCALE_AUTH_MODE:-}" ]]; then
      TAILSCALE_AUTH_MODE="interactive"
    fi

    if [[ "$TAILSCALE_AUTH_MODE" == "authkey" && -z "${TAILSCALE_AUTHKEY:-}" ]]; then
      fatal 10 "TAILSCALE_AUTH_MODE=authkey требует TAILSCALE_AUTHKEY"
    fi

    EXTRA_SSH_KEYS="${EXTRA_SSH_KEYS:-}"
    return 0
  fi

  if ! is_interactive_tty; then
    fatal 10 "Нет интерактивного TTY. Используйте --non-interactive --config"
  fi

  log_info "Infra wizard (RU): минимально необходимые параметры"
  OPENCLAW_PASSWORD="$(prompt_secret_confirm_ru 'Введите пароль для пользователя openclaw')"

  local choice
  choice="$(prompt_choice_ru 'Режим авторизации Tailscale:' 'authkey' 'interactive')"
  TAILSCALE_AUTH_MODE="$choice"

  if [[ "$TAILSCALE_AUTH_MODE" == "authkey" ]]; then
    read -r -s -p "Введите Tailscale auth key: " TAILSCALE_AUTHKEY
    printf '\n'
    if [[ -z "$TAILSCALE_AUTHKEY" ]]; then
      fatal 10 "Tailscale auth key не может быть пустым"
    fi
  fi

  EXTRA_SSH_KEYS="$(prompt_text_ru 'Дополнительные SSH public keys (через ;), можно пусто' '')"
}

collect_openclaw_inputs_ru() {
  if (( NON_INTERACTIVE )); then
    OPENCLAW_ONBOARD="${OPENCLAW_ONBOARD:-interactive}"
    OPENCLAW_PROVIDER="${OPENCLAW_PROVIDER:-}"
    OPENCLAW_MODEL="${OPENCLAW_MODEL:-}"
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
    OPENAI_API_KEY="${OPENAI_API_KEY:-}"
    GEMINI_API_KEY="${GEMINI_API_KEY:-}"
    return 0
  fi

  if ! is_interactive_tty; then
    fatal 10 "Нет интерактивного TTY. Используйте --non-interactive --config"
  fi

  log_info "OpenClaw wizard (RU): минимально необходимые параметры"
  OPENCLAW_ONBOARD="$(prompt_choice_ru 'Режим onboard:' 'interactive' 'non_interactive')"

  if [[ "$OPENCLAW_ONBOARD" == "non_interactive" ]]; then
    OPENCLAW_PROVIDER="$(prompt_choice_ru 'Провайдер модели:' 'anthropic' 'openai' 'gemini' 'custom')"
    OPENCLAW_MODEL="$(prompt_text_ru 'Модель (можно пусто)' '')"

    case "$OPENCLAW_PROVIDER" in
      anthropic)
        read -r -s -p "Введите ANTHROPIC_API_KEY: " ANTHROPIC_API_KEY
        printf '\n'
        ;;
      openai)
        read -r -s -p "Введите OPENAI_API_KEY: " OPENAI_API_KEY
        printf '\n'
        ;;
      gemini)
        read -r -s -p "Введите GEMINI_API_KEY: " GEMINI_API_KEY
        printf '\n'
        ;;
      custom)
        log_warn "Для custom провайдера задайте нужные переменные окружения заранее."
        ;;
      *)
        ;;
    esac
  fi
}
