#!/usr/bin/env bash

SCRIPT_NAME="nmc-ai.v1"
DRY_RUN=${DRY_RUN:-0}
VERBOSE=${VERBOSE:-0}
NON_INTERACTIVE=${NON_INTERACTIVE:-0}

COLOR_RESET='\033[0m'
COLOR_INFO='\033[1;34m'
COLOR_WARN='\033[1;33m'
COLOR_ERROR='\033[1;31m'
COLOR_SUCCESS='\033[1;32m'

log_info() {
  printf "%b[%s] %s%b\n" "$COLOR_INFO" "INFO" "$*" "$COLOR_RESET"
}

log_warn() {
  printf "%b[%s] %s%b\n" "$COLOR_WARN" "WARN" "$*" "$COLOR_RESET" >&2
}

log_error() {
  printf "%b[%s] %s%b\n" "$COLOR_ERROR" "ERROR" "$*" "$COLOR_RESET" >&2
}

log_success() {
  printf "%b[%s] %s%b\n" "$COLOR_SUCCESS" "OK" "$*" "$COLOR_RESET"
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_interactive_tty() {
  [[ -t 0 && -t 1 ]]
}

require_cmd() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "Команда не найдена: $cmd"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    return 1
  fi
}

ensure_sudo_access() {
  if (( DRY_RUN )); then
    log_info "[dry-run] sudo -v"
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log_error "Требуется sudo, но команда sudo не найдена"
    return 1
  fi

  if ! sudo -v; then
    log_error "Не удалось получить sudo-доступ"
    return 1
  fi
}

run_cmd() {
  if (( DRY_RUN )); then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

run_sudo() {
  if (( DRY_RUN )); then
    log_info "[dry-run] sudo $*"
    return 0
  fi
  sudo "$@"
}

run_sudo_quiet() {
  if (( DRY_RUN )); then
    log_info "[dry-run] sudo (quiet) $*"
    return 0
  fi
  sudo "$@" >/dev/null 2>&1
}

run_as_openclaw() {
  local cmd="$1"
  if (( DRY_RUN )); then
    log_info "[dry-run] sudo -iu openclaw bash -lc '$cmd'"
    return 0
  fi
  sudo -iu openclaw bash -lc "$cmd"
}

run_as_openclaw_sensitive() {
  local cmd="$1"
  if (( DRY_RUN )); then
    log_info "[dry-run] sudo -iu openclaw bash -lc '<sensitive command>'"
    return 0
  fi
  sudo -iu openclaw bash -lc "$cmd"
}

fatal() {
  local code="$1"
  shift
  log_error "$*"
  exit "$code"
}

supported_ubuntu() {
  if [[ ! -r /etc/os-release ]]; then
    return 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    return 1
  fi

  case "${VERSION_ID:-}" in
    22.04|24.04) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_block_in_file() {
  local file="$1"
  local marker="$2"
  local insert_before_regex="$3"
  local block_content="$4"

  if (( DRY_RUN )); then
    log_info "[dry-run] upsert block '$marker' in $file"
    return 0
  fi

  local tmp_block
  tmp_block="$(mktemp)"
  printf '%s\n' "$block_content" > "$tmp_block"

  sudo python3 - "$file" "$marker" "$insert_before_regex" "$tmp_block" <<'PY'
import pathlib
import re
import sys

file_path = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
insert_before_regex = sys.argv[3]
block_path = pathlib.Path(sys.argv[4])

start = f"# BEGIN {marker}"
end = f"# END {marker}"
new_block_lines = [start] + block_path.read_text().splitlines() + [end]

text = file_path.read_text() if file_path.exists() else ""
lines = text.splitlines()

# Remove old block if present.
filtered = []
in_old = False
for line in lines:
    if line.strip() == start:
        in_old = True
        continue
    if in_old and line.strip() == end:
        in_old = False
        continue
    if not in_old:
        filtered.append(line)

insert_at = len(filtered)
pattern = re.compile(insert_before_regex)
for idx, line in enumerate(filtered):
    if pattern.search(line):
        insert_at = idx
        break

result = filtered[:insert_at] + new_block_lines + filtered[insert_at:]
output = "\n".join(result).rstrip("\n") + "\n"
file_path.write_text(output)
PY

  rm -f "$tmp_block"
}

ensure_line_in_file() {
  local file="$1"
  local line="$2"

  if (( DRY_RUN )); then
    log_info "[dry-run] ensure line in $file: $line"
    return 0
  fi

  run_sudo mkdir -p "$(dirname "$file")"
  if ! run_sudo test -f "$file"; then
    run_sudo touch "$file"
  fi

  if ! run_sudo grep -Fxq "$line" "$file"; then
    run_sudo bash -lc "printf '%s\n' \"$line\" >> \"$file\""
  fi
}

write_root_file() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"

  if (( DRY_RUN )); then
    log_info "[dry-run] install $src -> $dest ($owner:$group $mode)"
    return 0
  fi

  run_sudo install -D -m "$mode" -o "$owner" -g "$group" "$src" "$dest"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&/]/\\&/g'
}
