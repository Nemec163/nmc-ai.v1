#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
MODE="${MODE:-}"
CONFIG_FILE=""
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
DRY_RUN=${DRY_RUN:-0}
VERBOSE=${VERBOSE:-0}
INVOKING_USER="${SUDO_USER:-$USER}"

print_usage() {
  cat <<'USAGE'
nmc-ai.v1 — двухрежимный установщик OpenClaw для Ubuntu VPS

Usage:
  ./nmc-ai.v1.sh --mode infra [--dry-run] [--verbose]
  ./nmc-ai.v1.sh --mode openclaw [--dry-run] [--verbose]
  ./nmc-ai.v1.sh --mode <infra|openclaw> --non-interactive --config /path/installer.env

Опции:
  --mode <infra|openclaw>   Режим выполнения
  --config <path>           Путь к env-конфигу
  --non-interactive         Без wizard, данные из env/config
  --dry-run                 Только план действий, без изменений
  --verbose                 Подробный вывод
  -h, --help                Показать помощь

Exit codes:
  0  success
  10 preflight/config error
  20 infra mode failed
  30 openclaw mode failed
  40 lockout safety stop
USAGE
}

load_config_file() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    echo "Config file not found: $path" >&2
    exit 10
  fi

  set -a
  # shellcheck disable=SC1090
  source "$path"
  set +a
}

first_pass_parse() {
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --config)
        i=$((i + 1))
        if [[ $i -ge ${#args[@]} ]]; then
          echo "--config requires value" >&2
          exit 10
        fi
        CONFIG_FILE="${args[$i]}"
        ;;
    esac
    i=$((i + 1))
  done
}

second_pass_parse() {
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --mode)
        i=$((i + 1))
        if [[ $i -ge ${#args[@]} ]]; then
          echo "--mode requires value" >&2
          exit 10
        fi
        MODE="${args[$i]}"
        ;;
      --config)
        i=$((i + 1))
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --verbose)
        VERBOSE=1
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        echo "Unknown option: ${args[$i]}" >&2
        print_usage
        exit 10
        ;;
    esac
    i=$((i + 1))
  done
}

first_pass_parse "$@"
load_config_file "$CONFIG_FILE"
second_pass_parse "$@"

if [[ -z "$MODE" ]]; then
  echo "Mode is required (--mode infra|openclaw)" >&2
  exit 10
fi

case "$MODE" in
  infra|openclaw) ;;
  *)
    echo "Invalid mode: $MODE" >&2
    exit 10
    ;;
esac

if (( VERBOSE )); then
  set -x
fi

# shellcheck disable=SC1091
source "$SCRIPT_ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_ROOT/lib/state.sh"
# shellcheck disable=SC1091
source "$SCRIPT_ROOT/lib/wizard_ru.sh"
# shellcheck disable=SC1091
source "$SCRIPT_ROOT/modes/infra.sh"
# shellcheck disable=SC1091
source "$SCRIPT_ROOT/modes/openclaw.sh"

log_info "Запуск ${SCRIPT_NAME}"
log_info "Режим: $MODE"
if (( NON_INTERACTIVE )); then
  log_info "Режим ввода: non-interactive"
else
  log_info "Режим ввода: interactive wizard (RU)"
fi

if [[ "$MODE" == "infra" ]]; then
  if run_infra_mode; then
    rc=0
  else
    rc=$?
  fi
else
  if run_openclaw_mode; then
    rc=0
  else
    rc=$?
  fi
fi

if [[ $rc -eq 0 ]]; then
  exit 0
fi

if [[ $rc -eq 10 || $rc -eq 40 ]]; then
  exit "$rc"
fi

if [[ "$MODE" == "infra" ]]; then
  exit 20
fi

exit 30
