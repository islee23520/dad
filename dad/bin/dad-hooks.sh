#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  dad-hooks.sh install [--socket <tmux-socket>]
  dad-hooks.sh remove [--socket <tmux-socket>]
  dad-hooks.sh status [--socket <tmux-socket>]

Installs or removes DAD's runtime Grok hook registration. The plugin does not
ship auto-loaded hooks/hooks.json; /dad starts this hook while at least one DAD
window is active and removes it after the last DAD stops.
USAGE
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DAD_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_ROOT="$(CDPATH= cd -- "${DAD_ROOT}/.." && pwd)"
if [[ -f "${PLUGIN_ROOT}/hooks/dad-events.json" ]]; then
  HOOK_SOURCE="${PLUGIN_ROOT}/hooks/dad-events.json"
elif [[ -f "${DAD_ROOT}/hooks/dad-events.json" ]]; then
  HOOK_SOURCE="${DAD_ROOT}/hooks/dad-events.json"
else
  HOOK_SOURCE="${PLUGIN_ROOT}/hooks/dad-events.json"
fi
GROK_HOME="${GROK_HOME:-${HOME}/.grok}"
HOOK_DIR="${GROK_HOME}/hooks"
HOOK_TARGET="${HOOK_DIR}/dad-events.json"
HOOK_COMMAND="$(CDPATH= cd -- "$(dirname -- "$HOOK_SOURCE")" && pwd)/scripts/dad-event-hook.sh"
LIVE_STATES_RE='^(booting|working|recovering|waiting|verifying|done|paused|broken)$'

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

socket=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket)
      socket="${2:-}"
      [[ -n "$socket" ]] || { echo "DAD_HOOKS_ERROR: missing --socket value" >&2; exit 2; }
      shift 2
      ;;
    *)
      echo "DAD_HOOKS_ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

tmux_args=()
if [[ -n "$socket" ]]; then
  tmux_args=(-S "$socket")
elif [[ -n "${TMUX:-}" ]]; then
  tmux_args=(-S "${TMUX%%,*}")
fi

active_dad_count() {
  command -v tmux >/dev/null 2>&1 || return 0
  local window_id state count=0
  while IFS= read -r window_id; do
    [[ -n "$window_id" ]] || continue
    state="$(tmux "${tmux_args[@]}" show-window-option -v -t "$window_id" @dad_state 2>/dev/null || true)"
    if [[ "$state" =~ $LIVE_STATES_RE ]]; then
      count=$((count + 1))
    fi
  done < <(tmux "${tmux_args[@]}" list-windows -a -F '#{window_id}' 2>/dev/null || true)
  printf '%s\n' "$count"
}

install_hook() {
  [[ -f "$HOOK_SOURCE" ]] || { echo "DAD_HOOKS_ERROR: missing hook source: $HOOK_SOURCE" >&2; exit 1; }
  [[ -x "$HOOK_COMMAND" ]] || { echo "DAD_HOOKS_ERROR: missing hook command: $HOOK_COMMAND" >&2; exit 1; }
  mkdir -p "$HOOK_DIR"
  if [[ -e "$HOOK_TARGET" ]]; then
    if [[ -L "$HOOK_TARGET" ]]; then
      rm -f "$HOOK_TARGET"
    elif ! grep -q 'dad-event-hook.sh' "$HOOK_TARGET"; then
      echo "DAD_HOOKS_ERROR: refusing to overwrite non-DAD hook: $HOOK_TARGET" >&2
      exit 1
    fi
  fi
  python3 - "$HOOK_SOURCE" "${HOOK_TARGET}.tmp" "$HOOK_COMMAND" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
command = sys.argv[3]
data = json.loads(source.read_text(encoding="utf-8"))
for entries in data.get("hooks", {}).values():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        for hook in entry.get("hooks", []) if isinstance(entry, dict) else []:
            if isinstance(hook, dict) and hook.get("type") == "command":
                hook["command"] = command
target.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")
PY
  mv -Tf "${HOOK_TARGET}.tmp" "$HOOK_TARGET"
  echo "DAD_HOOKS_INSTALLED: $HOOK_TARGET -> $HOOK_COMMAND"
}

remove_hook() {
  local active_count
  active_count="$(active_dad_count)"
  if [[ "$active_count" != "0" ]]; then
    echo "DAD_HOOKS_KEEP: active_dad_windows=$active_count"
    return 0
  fi
  if [[ -L "$HOOK_TARGET" ]]; then
    local resolved
    resolved="$(readlink -f "$HOOK_TARGET" 2>/dev/null || true)"
    if [[ "$resolved" == "$HOOK_SOURCE" ]]; then
      rm -f "$HOOK_TARGET"
      echo "DAD_HOOKS_REMOVED: $HOOK_TARGET"
      return 0
    fi
  fi
  if [[ -f "$HOOK_TARGET" ]] && grep -q 'dad-event-hook.sh' "$HOOK_TARGET"; then
    rm -f "$HOOK_TARGET"
    echo "DAD_HOOKS_REMOVED: $HOOK_TARGET"
    return 0
  fi
  echo "DAD_HOOKS_ABSENT: $HOOK_TARGET"
}

case "$cmd" in
  install)
    install_hook
    ;;
  remove)
    remove_hook
    ;;
  status)
    printf 'DAD_HOOKS_SOURCE: %s\n' "$HOOK_SOURCE"
    printf 'DAD_HOOKS_COMMAND: %s\n' "$HOOK_COMMAND"
    printf 'DAD_HOOKS_TARGET: %s\n' "$HOOK_TARGET"
    printf 'DAD_HOOKS_TARGET_PRESENT: %s\n' "$([[ -e "$HOOK_TARGET" ]] && echo yes || echo no)"
    printf 'DAD_HOOKS_ACTIVE_DAD_WINDOWS: %s\n' "$(active_dad_count)"
    ;;
  *)
    echo "DAD_HOOKS_ERROR: unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
