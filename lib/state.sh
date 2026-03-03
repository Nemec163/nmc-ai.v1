#!/usr/bin/env bash

STATE_DIR=${STATE_DIR:-/var/lib/openclaw-installer}
STATE_FILE=${STATE_FILE:-${STATE_DIR}/state.json}

state_init() {
  if (( DRY_RUN )); then
    log_info "[dry-run] init state file: ${STATE_FILE}"
    return 0
  fi

  run_sudo mkdir -p "$STATE_DIR"
  if ! run_sudo test -f "$STATE_FILE"; then
    run_sudo bash -lc "printf '{}\n' > '$STATE_FILE'"
    run_sudo chmod 0644 "$STATE_FILE"
  fi
}

state_get_raw() {
  local key="$1"

  if ! sudo test -f "$STATE_FILE" >/dev/null 2>&1; then
    printf 'null\n'
    return 0
  fi

  sudo python3 - "$STATE_FILE" "$key" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if not path.exists():
    print("null")
    raise SystemExit(0)

try:
    data = json.loads(path.read_text() or "{}")
except json.JSONDecodeError:
    print("null")
    raise SystemExit(0)

value = data.get(key, None)
if value is None:
    print("null")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (int, float)):
    print(value)
else:
    print(str(value))
PY
}

state_get_bool() {
  local key="$1"
  local v
  v="$(state_get_raw "$key")"
  if [[ "$v" == "true" || "$v" == "1" ]]; then
    return 0
  fi
  return 1
}

state_set_string() {
  local key="$1"
  local value="$2"

  if (( DRY_RUN )); then
    log_info "[dry-run] state set string: $key=$value"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  sudo cat "$STATE_FILE" > "$tmp" 2>/dev/null || printf '{}\n' > "$tmp"

  python3 - "$tmp" "$key" "$value" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

try:
    data = json.loads(path.read_text() or "{}")
except json.JSONDecodeError:
    data = {}

data[key] = value
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY

  run_sudo install -m 0644 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

state_set_bool() {
  local key="$1"
  local value="$2"

  if (( DRY_RUN )); then
    log_info "[dry-run] state set bool: $key=$value"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  sudo cat "$STATE_FILE" > "$tmp" 2>/dev/null || printf '{}\n' > "$tmp"

  python3 - "$tmp" "$key" "$value" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3].strip().lower() in ("1", "true", "yes", "on")

try:
    data = json.loads(path.read_text() or "{}")
except json.JSONDecodeError:
    data = {}

data[key] = value
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY

  run_sudo install -m 0644 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}
