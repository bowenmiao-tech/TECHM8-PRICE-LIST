"""Prepare repeatable, client-side SQL batches for the North Lakes RepairDesk cutover.

The spreadsheets stay on the local computer. Generated SQL is written outside
the repository and is applied only after its counts have been checked.
"""

from __future__ import annotations

import argparse
import base64
from collections import defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo

import openpyxl


BRISBANE = ZoneInfo("Australia/Brisbane")
CENT = Decimal("0.01")


def text(value: object) -> str:
    return str(value).strip() if value is not None else ""


def money(value: object) -> Decimal:
    try:
        return Decimal(text(value).replace(",", "") or "0")
    except InvalidOperation as exc:
        raise ValueError(f"Invalid amount: {value!r}") from exc


def records(path: Path):
    sheet = openpyxl.load_workbook(path, read_only=True, data_only=True).active
    rows = sheet.iter_rows(values_only=True)
    headers = [text(value) for value in next(rows)]
    for values in rows:
        yield {header: value for header, value in zip(headers, values)}


def source_timestamp(value: object) -> str:
    raw = text(value)
    return datetime.strptime(raw, "%d %b %Y (%I:%M %p)").replace(tzinfo=BRISBANE).isoformat()


def compact(row: dict[str, object]) -> dict[str, str]:
    return {key: text(value) for key, value in row.items() if text(value)}


def prepare(ticket_path: Path, invoice_path: Path):
    tickets: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in records(ticket_path):
        code = text(row.get("Ticket ID"))
        if not code:
            continue
        if not re.fullmatch(r"T-[0-9]+", code):
            raise ValueError(f"Unexpected ticket ID: {code!r}")
        tickets[code].append(row)

    invoices: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in records(invoice_path):
        if text(row.get("Store name")) != "TechM8 North Lakes":
            raise ValueError("Invoice export contains another store")
        code = text(row.get("Ticket number"))
        if code:
            invoices[code].append(row)

    output = []
    counts = defaultdict(int)
    for code, items in sorted(tickets.items(), key=lambda item: int(item[0][2:])):
        first = items[0]
        linked = invoices.get(code, [])
        invoice_total = sum((money(row.get("Sub Total")) for row in linked), Decimal(0))
        invoice_paid = sum((money(row.get("Amount Paid")) for row in linked), Decimal(0))
        balance = max(invoice_total - invoice_paid, Decimal(0)).quantize(CENT)
        archived = bool(linked) and balance <= CENT
        if archived:
            counts["archived"] += 1
        elif linked:
            counts["balance_due"] += 1
        else:
            counts["no_invoice"] += 1

        names = list(dict.fromkeys(text(row.get("Customer")) for row in items if text(row.get("Customer"))))
        phone = next((text(row.get("Customer Mobile") or row.get("Customer Phone"))
                      for row in items if text(row.get("Customer Mobile") or row.get("Customer Phone"))), "")
        tasks = list(dict.fromkeys(text(row.get("Task")) for row in items if text(row.get("Task"))))
        devices = list(dict.fromkeys(text(row.get("Ticket Items")) for row in items if text(row.get("Ticket Items"))))
        manufacturer = text(first.get("Manufacturer"))
        device = text(first.get("Device"))
        title = (devices[0] if devices else " ".join(part for part in (manufacturer, device) if part)) or (
            tasks[0] if tasks else f"RepairDesk {code}"
        )
        issue = "; ".join(tasks) or "RepairDesk repair record"
        total = sum((money(row.get("Total")) for row in items), Decimal(0)).quantize(CENT)
        created = source_timestamp(first["Created Time"])
        invoice_numbers = list(dict.fromkeys(text(row.get("Invoice number")) for row in linked if text(row.get("Invoice number"))))
        legacy = {
            "sourceSystem": "repairdesk",
            "storeCode": "northlakes",
            "sourceTicketId": code,
            "sourceCreatedAt": created,
            "sourceStatuses": list(dict.fromkeys(text(row.get("Ticket Status")) for row in items)),
            "sourceInvoiceStatuses": list(dict.fromkeys(text(row.get("Invoice Status")) for row in items)),
            "invoiceNumbers": invoice_numbers,
            "invoiceTotal": str(invoice_total.quantize(CENT)) if linked else None,
            "invoicePaid": str(invoice_paid.quantize(CENT)) if linked else None,
            "invoiceBalance": str(balance) if linked else None,
            "invoicePaidAt": text(linked[0].get("Invoice Paid date")) if linked else "",
            "paymentClassification": "settled" if archived else ("balance_due" if linked else "no_invoice"),
            "items": [compact(row) for row in items],
            "invoiceItems": [compact(row) for row in linked],
        }
        output.append({
            "ticket_code": code,
            "title": title[:500],
            "issue": issue[:2000],
            "price": f"${total}",
            "customer_name": (names[0] if names else f"Unknown RepairDesk customer ({code})")[:300],
            "customer_phone": phone[:100],
            "status": "closed" if archived else "repairing",
            "closed": archived,
            "status_updated_at": created,
            "intake": {"legacy": legacy},
        })
    counts["tickets"] = len(output)
    counts["invoice_ticket_links_not_in_export"] = len(set(invoices) - set(tickets))
    return output, dict(counts)


def write_batches(rows: list[dict[str, object]], out_dir: Path, batch_size: int):
    out_dir.mkdir(parents=True, exist_ok=True)
    for index in range(0, len(rows), batch_size):
        payload = json.dumps(rows[index:index + batch_size], ensure_ascii=False, separators=(",", ":"))
        encoded = base64.b64encode(payload.encode("utf-8")).decode("ascii")
        sql = f"""
with source_rows as (
  select * from jsonb_to_recordset(
    convert_from(decode('{encoded}', 'base64'), 'UTF8')::jsonb
  ) as row(
    ticket_code text, title text, issue text, price text,
    customer_name text, customer_phone text, status text,
    closed boolean, status_updated_at timestamptz, intake jsonb
  )
), inserted as (
  insert into public.pos_repair_tickets (
    ticket_code, store_id, title, issue, price, status, closed_at,
    status_updated_at, customer_name, customer_phone, customer_contact,
    created_by, updated_by, intake, active
  )
  select ticket_code, (select id from public.store_locations where store_code='northlakes'),
    title, issue, price, status, case when closed then now() else null end,
    status_updated_at, customer_name, customer_phone, customer_phone,
    'RepairDesk import', 'RepairDesk import', intake, true
  from source_rows
  on conflict (ticket_code) do nothing
  returning ticket_code
)
select count(*) as inserted from inserted;
""".strip()
        (out_dir / f"tickets_{index // batch_size + 1:03d}.sql").write_text(sql, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tickets", type=Path)
    parser.add_argument("invoices", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--batch-size", type=int, default=100)
    args = parser.parse_args()
    rows, counts = prepare(args.tickets, args.invoices)
    write_batches(rows, args.output, args.batch_size)
    print(json.dumps(counts, sort_keys=True))
    print(f"batches={len(list(args.output.glob('tickets_*.sql')))}")


if __name__ == "__main__":
    main()
