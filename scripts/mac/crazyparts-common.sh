# Shared settings for the macOS Crazy Parts runners. Source this file; do not run it.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

MAC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname "$MAC_SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$SCRIPTS_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/outputs/crazyparts-price-monitor"
LOG_DIR="$OUTPUT_DIR/logs"
LOCK_DIR="$PROJECT_ROOT/.runtime/crazyparts-run.lock"
KEYCHAIN_SERVICE="techm8-crazyparts"

mkdir -p "$LOG_DIR" "$PROJECT_ROOT/.runtime"

# macOS copy of @oai/artifact-tool (the repo's copy is a Windows install).
MAC_ARTIFACT_TOOL="${CRAZYPARTS_MAC_RUNTIME:-$HOME/.local/techm8-crazyparts-runtime}/node_modules/@oai/artifact-tool"
export CRAZYPARTS_ARTIFACT_TOOL_ENTRY="$MAC_ARTIFACT_TOOL/dist/artifact_tool.mjs"
export NODE_OPTIONS="--import=$MAC_SCRIPT_DIR/artifact-tool-loader.mjs ${NODE_OPTIONS:-}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

# One Crazy Parts run at a time across the monthly schedule and the Admin queue.
# A lock left by a process that no longer exists is cleared automatically.
try_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  local holder
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    try_lock
    return $?
  fi
  return 1
}

wait_for_lock() {
  until try_lock; do sleep 30; done
}

release_lock() {
  if [[ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" == "$$" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}
