"""Match North Lakes RepairDesk item sales rows to imported invoice lines.

The generated payload contains item metadata and cost only. It does not contain
customer details and can be sent to the guarded backfill RPC in small batches.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

import openpyxl


def clean(value: object) -> str:
    return str(value if value is not None else "").strip()


def decimal(value: object) -> Decimal:
    raw = clean(value).replace("$", "").replace(",", "")
    return Decimal(raw if raw not in {"", "-"} else "0").quantize(Decimal("0.01"))


def key(value: object) -> str:
    return " ".join(clean(value).casefold().replace("|", ",").split())


def load_report(path: Path) -> dict[int, list[dict]]:
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    rows = iter(workbook.active.values)
    headers = [clean(value) for value in next(rows)]
    report = defaultdict(list)
    for values in rows:
        row = dict(zip(headers, values))
        if clean(row.get("Store Name")) != "TechM8 North Lakes":
            continue
        number = int(clean(row["Invoice ID"]))
        report[number].append(row)
    workbook.close()
    return report


def match_score(item: dict, row: dict) -> int:
    source = item["line_payload"]
    if decimal(item["quantity"]) != decimal(row["Quantity"]):
        return -1
    item_id, report_id = key(source.get("source_item_id")), key(row["Item ID"])
    sku, report_sku = key(item.get("sku")), key(row["SKU"])
    name, report_name = key(item["name"]), key(row["Product Name"])
    score = 0
    if item_id and item_id == report_id:
        score += 8
    if sku and sku == report_sku:
        score += 6
    if name == report_name:
        score += 4
    if abs(decimal(item["line_total"]) - decimal(row["Total Sales"]) - decimal(row["Tax"]) + decimal(row["Discount"])) <= Decimal("0.02"):
        score += 2
    if item_id and report_id and item_id != report_id and item_id != "-" and report_id != "-":
        return -1
    if sku and report_sku and sku != report_sku and sku != "-" and report_sku != "-":
        return -1
    return score


def prepare(prepared_path: Path, report_path: Path, output_path: Path) -> dict:
    invoices = json.loads(prepared_path.read_text(encoding="utf-8"))
    report = load_report(report_path)
    prepared_numbers = {int(invoice["invoice_number"]) for invoice in invoices}
    if set(report) != prepared_numbers:
        raise ValueError(f"Invoice sets differ: report-only {len(set(report)-prepared_numbers)}, import-only {len(prepared_numbers-set(report))}")
    payload = []
    failures = []
    score_counts = defaultdict(int)
    for invoice in invoices:
        number = int(invoice["invoice_number"])
        candidates = report[number][:]
        if len(candidates) != len(invoice["items"]):
            failures.append({"invoice": number, "reason": "line count differs"})
            continue
        for item in invoice["items"]:
            scored = sorted((
                ((match_score(item, row), -abs(decimal(item["line_total"]) - decimal(row["Total Sales"]) - decimal(row["Tax"]) + decimal(row["Discount"]))), index)
                for index, row in enumerate(candidates)
            ), reverse=True)
            if not scored or scored[0][0][0] <= 0:
                failures.append({"invoice": number, "line": item["line_number"], "reason": "no matching item", "name": item["name"]})
                continue
            (best_score, _), index = scored[0]
            if len(scored) > 1 and scored[1][0] == scored[0][0] and any(clean(candidates[index].get(field)) != clean(candidates[scored[1][1]].get(field)) for field in ("Type", "Manufacturer", "Device", "COGS", "Discount", "Total Sales")):
                failures.append({"invoice": number, "line": item["line_number"], "reason": "ambiguous item", "name": item["name"]})
                continue
            row = candidates.pop(index)
            score_counts[best_score] += 1
            source = item["line_payload"]
            payload.append({
                "invoice_number": number,
                "line_number": int(item["line_number"]),
                "item_id": source.get("source_item_id", ""),
                "sku": item.get("sku", ""),
                "quantity": item["quantity"],
                "line_total": item["line_total"],
                "source_type": clean(row["Type"]),
                "source_manufacturer": clean(row["Manufacturer"]),
                "source_device": clean(row["Device"]),
                "source_cogs": str(decimal(row["COGS"])),
                "source_discount": str(decimal(row["Discount"])),
                "source_total_sales_ex_gst": str(decimal(row["Total Sales"])),
                "source_report_item_id": clean(row["Item ID"]),
            })
        if candidates:
            failures.append({"invoice": number, "reason": "unmatched report rows", "count": len(candidates)})
    summary = {"invoices": len(invoices), "report_rows": sum(map(len, report.values())), "matched": len(payload), "score_counts": dict(score_counts), "failures": failures[:100], "failure_count": len(failures), "cogs_total": str(sum((decimal(x["source_cogs"]) for x in payload), Decimal("0")))}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.prepared, args.report, args.output), indent=2))
