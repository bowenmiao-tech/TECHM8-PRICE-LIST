#!/bin/bash
# macOS equivalent of process-crazyparts-run-queue.ps1: picks up one Admin
# "Run Now" request from public.crazyparts_run_requests and runs it.
set -uo pipefail
source "$(dirname "$0")/crazyparts-common.sh"

# Skip quietly while another Crazy Parts run is in progress.
try_lock || exit 0
trap release_lock EXIT

query_json() {
  local out attempt
  for attempt in 1 2 3; do
    if out="$(cd "$PROJECT_ROOT" && supabase db query --linked "$1" --output json --agent=no 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
    [[ $attempt -lt 3 ]] && sleep $((attempt * 3))
  done
  log 'Could not contact the price update queue after three attempts.' >&2
  return 1
}

claim_sql="with next_request as (
  select id from public.crazyparts_run_requests
  where status = 'queued'
  order by requested_at
  for update skip locked
  limit 1
)
update public.crazyparts_run_requests as request
set status = 'running', started_at = now(), message = 'This computer is starting the requested update.'
from next_request
where request.id = next_request.id
returning request.id, request.family, request.brand;"

claimed="$(query_json "$claim_sql")" || exit 1
row="$(printf '%s' "$claimed" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  if(!s.trim())return;
  let v=JSON.parse(s); if(!Array.isArray(v)) v=v.rows||[];
  const r=v.find(x=>x); if(r) process.stdout.write(`${Number(r.id)}\t${r.family}`);
});')"
[[ -z "$row" ]] && exit 0

request_id="${row%%$'\t'*}"
family="${row#*$'\t'}"
[[ "$request_id" =~ ^[0-9]+$ ]] || { log "Unexpected queue row: $row"; exit 1; }

log "Queue request $request_id: running $family."
"$MAC_SCRIPT_DIR/run-crazyparts-price-monitor.sh" --family "$family" --concurrency 1 --sync
exit_code=$?

if [[ $exit_code == 0 ]]; then
  query_json "update public.crazyparts_run_requests set status = 'completed', completed_at = now(), message = 'Latest verified prices are live.' where id = $request_id;" >/dev/null
else
  query_json "update public.crazyparts_run_requests set status = 'failed', completed_at = now(), message = 'The requested update did not finish. Check the brand status and run it again.' where id = $request_id;" >/dev/null
fi
log "Queue request $request_id finished with exit $exit_code."
exit $exit_code
