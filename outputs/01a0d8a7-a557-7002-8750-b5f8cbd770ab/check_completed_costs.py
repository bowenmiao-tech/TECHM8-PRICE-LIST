import openpyxl
import re
from collections import defaultdict

base = r'D:\program\TECHM8 PRICE LIST\outputs\01a0d8a7-a557-7002-8750-b5f8cbd770ab'
workbook = openpyxl.load_workbook(base + r'\FF-remaining-repair-costs.xlsx')
full = workbook['FF完整清单']
pending = workbook['待补成本']
totals = defaultdict(float)
bad = []
for cells in full.iter_rows(min_row=7, max_col=10):
    if not cells[3].value:
        continue
    value = cells[5].value
    if cells[5].data_type == 'f':
        match = re.search(r'F(\d+)', value)
        value = pending[f'F{match.group(1)}'].value if match else None
    if isinstance(value, (int, float)):
        currency = 'AUD' if cells[5].data_type == 'f' else (cells[6].value or 'AUD')
        totals[currency] += float(value)
    elif isinstance(value, str) and re.search(r'CNY|RMB', value, re.I):
        totals['CNY'] += float(re.search(r'[\d.]+', value).group())
    else:
        bad.append((cells[0].row, cells[3].value, value))
print('All currency buckets:', dict(totals))
print('AUD cost:', round(totals['AUD'], 2))
print('CNY cost:', round(totals['CNY'], 2))
print('AUD converted:', round(totals['AUD'] + totals['CNY'] / 4.7, 2))
print('Unparsed:', bad)
