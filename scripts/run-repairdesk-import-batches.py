"""Send prepared RepairDesk history batches to the protected import RPC.

The generated batches contain customer data, so they stay in an ignored
temporary directory and are streamed straight from disk to Supabase instead of
passing through any transcript. The RPC is idempotent per store and invoice
number, so an interrupted run can simply be started again.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_PROJECT_URL = "https://abkjbhmifswfexpjkval.supabase.co"
DEFAULT_KEY_FILE = Path(".secrets/supabase-service-role-key.txt")
RPC_PATH = "/rest/v1/rpc/import_repairdesk_sales_batch"


def extract_key(raw: bytes) -> str:
    """Pull the key out of a file that may carry a BOM or a stray encoding."""
    text = raw.decode("ascii", "ignore")
    match = re.search(r"(sb_secret_[A-Za-z0-9_\-]{8,}|eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)", text)
    return match.group(1) if match else ""


def load_service_role_key(key_file: Path) -> str:
    key = extract_key(os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").encode("utf-8", "ignore"))
    if key:
        return key
    if key_file.exists():
        key = extract_key(key_file.read_bytes())
        if key:
            return key
    raise SystemExit(
        "No service role key found. Set SUPABASE_SERVICE_ROLE_KEY or write the key to "
        f"{key_file} (that directory is git-ignored)."
    )


def post_batch(url: str, key: str, batch: list, timeout: int, attempts: int) -> dict:
    body = json.dumps({"batch_payload": batch}, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST")
    request.add_header("apikey", key)
    request.add_header("Authorization", f"Bearer {key}")
    request.add_header("Content-Type", "application/json")

    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            # 4xx means the payload itself was rejected; retrying cannot help.
            if exc.code < 500:
                raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc
            last_error = RuntimeError(f"HTTP {exc.code}: {detail}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last_error = RuntimeError(str(exc))
        if attempt < attempts:
            time.sleep(min(2 ** attempt, 30))
    raise last_error if last_error else RuntimeError("Unknown transport failure")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", type=Path, required=True,
                        help="prepared-invoices.json produced by the import builder")
    parser.add_argument("--state-file", type=Path,
                        help="records the number of invoices already accepted (defaults next to --prepared)")
    parser.add_argument("--project-url", default=DEFAULT_PROJECT_URL)
    parser.add_argument("--key-file", type=Path, default=DEFAULT_KEY_FILE)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--attempts", type=int, default=4)
    parser.add_argument("--restart", action="store_true",
                        help="ignore a previous state file and resend every batch")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not 1 <= args.batch_size <= 100:
        raise SystemExit("Batch size must be between 1 and 100")

    key = load_service_role_key(args.key_file)
    url = args.project_url.rstrip("/") + RPC_PATH
    state_file = args.state_file or args.prepared.with_name("import-state.json")

    invoices = json.loads(args.prepared.read_text(encoding="utf-8"))
    total = len(invoices)

    start = 0
    if state_file.exists() and not args.restart:
        start = int(json.loads(state_file.read_text(encoding="utf-8")).get("sent_invoices", 0))
        if start:
            print(f"Resuming after {start} invoices already accepted.", flush=True)

    totals = {"invoice_count": 0, "line_count": 0, "payment_count": 0}
    started_at = time.time()

    for offset in range(start, total, args.batch_size):
        batch = invoices[offset:offset + args.batch_size]
        result = post_batch(url, key, batch, args.timeout, args.attempts)
        if isinstance(result, list):
            result = result[0] if result else {}
        if not result.get("ok"):
            raise SystemExit(f"Batch at offset {offset} was rejected: {result}")
        for field in totals:
            totals[field] += int(result.get(field, 0))

        sent = offset + len(batch)
        state_file.write_text(json.dumps({"sent_invoices": sent}) + "\n", encoding="utf-8")
        elapsed = time.time() - started_at
        print(f"{sent}/{total} invoices  ({elapsed:6.1f}s)", flush=True)

    print(json.dumps({"ok": True, "total_invoices": total, **totals}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
