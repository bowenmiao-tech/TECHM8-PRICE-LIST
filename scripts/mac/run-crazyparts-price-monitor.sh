#!/bin/bash
# macOS equivalent of scripts/run-crazyparts-price-monitor.ps1.
# Usage examples:
#   run-crazyparts-price-monitor.sh --family 'A Series' --sync
#   run-crazyparts-price-monitor.sh --family 'Apple Mac' --sync
#   run-crazyparts-price-monitor.sh --family iPad --sync
#   run-crazyparts-price-monitor.sh --model 'a17-5g-(a176)'
set -uo pipefail
source "$(dirname "$0")/crazyparts-common.sh"

families=()
models=()
all=0
headful=0
sync=0
concurrency=1
max_models=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --family) families+=("$2"); shift 2 ;;
    --model) models+=("$2"); shift 2 ;;
    --all) all=1; shift ;;
    --supported-brands)
      families+=('A Series' 'Oppo' 'Huawei' 'Xiaomi' 'Redmi' 'Motorola' 'Nokia' 'Oneplus' 'Realme' 'Vivo' 'Sony' 'Apple Mac')
      shift ;;
    --headful) headful=1; shift ;;
    --sync) sync=1; shift ;;
    --concurrency) concurrency="$2"; shift 2 ;;
    --max-models) max_models="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

email="$(security find-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null | sed -n 's/.*"acct"<blob>="\(.*\)"/\1/p')"
password="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"
if [[ -z "$email" || -z "$password" ]]; then
  echo 'Crazy Parts login not found in Keychain. Run scripts/mac/setup-crazyparts-credential.sh first.' >&2
  exit 1
fi
export CRAZYPARTS_EMAIL="$email"
export CRAZYPARTS_PASSWORD="$password"
unset password
export CRAZYPARTS_TRACK_STATUS=$([[ $sync == 1 ]] && echo 1 || echo 0)

# Expand the same family aliases as the Windows runner.
expanded=()
for f in ${families[@]+"${families[@]}"}; do
  case "$f" in
    'A Series') expanded+=('A Series' 'Tab A Series' 'Tab S Series') ;;
    'Apple Mac') expanded+=('iMac' 'Macbook Pro' 'Macbook Air' 'Macbook') ;;
    'iPad') expanded+=('iPad Pro' 'iPad Air' 'iPad Mini') ;;
    *) [[ -n "${f// }" ]] && expanded+=("$f") ;;
  esac
done

history_file="$OUTPUT_DIR/.run-history-$$.txt"
args=("$SCRIPTS_DIR/crazyparts-price-monitor.mjs" --history-path-file "$history_file")
[[ $all == 1 ]] && args+=(--all)
for m in ${models[@]+"${models[@]}"}; do [[ -n "${m// }" ]] && args+=(--model "$m"); done
seen='|'
for f in ${expanded[@]+"${expanded[@]}"}; do
  [[ "$seen" == *"|$f|"* ]] && continue
  seen+="$f|"
  args+=(--family "$f")
done
[[ $headful == 1 ]] && args+=(--headful)
[[ "$max_models" -gt 0 ]] && args+=(--max-models "$max_models")
args+=(--concurrency "$concurrency")

cleanup() {
  unset CRAZYPARTS_EMAIL CRAZYPARTS_PASSWORD CRAZYPARTS_TRACK_STATUS
  rm -f "$history_file"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"
node "${args[@]}"
exit_code=$?

if [[ $exit_code == 0 && $sync == 1 ]]; then
  captured="$(tr -d '\r\n' < "$history_file" 2>/dev/null)"
  if [[ -z "$captured" || ! -f "$captured" ]]; then
    echo 'The captured price history file could not be verified.' >&2
    exit 1
  fi
  node "$SCRIPTS_DIR/sync-crazyparts-to-supabase.mjs" --apply --history "$captured"
  exit_code=$?
fi

exit $exit_code
