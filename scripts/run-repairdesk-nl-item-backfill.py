"""Send matched North Lakes item details to the guarded Supabase RPC."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from importlib.machinery import SourceFileLoader


transport = SourceFileLoader(
    "repairdesk_transport", str(Path(__file__).with_name("run-repairdesk-import-batches.py"))
).load_module()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", type=Path, required=True)
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--key-file", type=Path, default=transport.DEFAULT_KEY_FILE)
    parser.add_argument("--project-url", default=transport.DEFAULT_PROJECT_URL)
    args = parser.parse_args()
    if not 1 <= args.batch_size <= 100:
        raise SystemExit("Batch size must be between 1 and 100")

    key = transport.load_service_role_key(args.key_file)
    url = args.project_url.rstrip("/") + "/rest/v1/rpc/backfill_repairdesk_north_lakes_sales_items"
    items = json.loads(args.prepared.read_text(encoding="utf-8"))
    state_file = args.state_file or args.prepared.with_name("item-backfill-state.json")
    start = int(json.loads(state_file.read_text(encoding="utf-8")).get("sent_lines", 0)) if state_file.exists() else 0
    for offset in range(start, len(items), args.batch_size):
        batch = items[offset:offset + args.batch_size]
        result = transport.post_batch(url, key, batch, 180, 4)
        if isinstance(result, list):
            result = result[0] if result else {}
        if not result.get("ok") or result.get("updated_lines") != len(batch):
            raise RuntimeError(f"Unexpected result at item {offset}: {result}")
        sent = offset + len(batch)
        state_file.write_text(json.dumps({"sent_lines": sent}) + "\n", encoding="utf-8")
        print(f"{sent}/{len(items)} sale lines enriched", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
