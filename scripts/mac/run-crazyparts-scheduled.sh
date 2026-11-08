#!/bin/bash
# Runs the brand assigned to today's day of month (1st–11th), the same
# sequence as install-crazyparts-daily-brand-tasks.ps1 on Windows.
# Pass a day number to run that day's work manually: run-crazyparts-scheduled.sh 3
set -uo pipefail
source "$(dirname "$0")/crazyparts-common.sh"

day="${1:-$(date +%-d)}"
run="$MAC_SCRIPT_DIR/run-crazyparts-price-monitor.sh"

case "$day" in
  1) steps=('A Series') ;;
  2) steps=('Oppo' 'iPad') ;;
  3) steps=('Huawei' 'Apple Mac' 'Pixel') ;;
  4) steps=('Xiaomi') ;;
  5) steps=('Redmi') ;;
  6) steps=('Motorola') ;;
  7) steps=('Nokia') ;;
  8) steps=('Oneplus') ;;
  9) steps=('Realme') ;;
  10) steps=('Vivo') ;;
  11) steps=('Sony') ;;
  *) log "Day $day has no Crazy Parts update."; exit 0 ;;
esac

log "Day $day: waiting for any other Crazy Parts run to finish."
wait_for_lock
trap release_lock EXIT

failed=0
for family in "${steps[@]}"; do
  log "Starting $family."
  if "$run" --family "$family" --concurrency 1 --sync; then
    log "Completed and verified $family."
  else
    log "FAILED: $family (exit $?)."
    failed=1
  fi
done
exit $failed
