import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';
const dir = 'D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(`${dir}/TW-FF-2026-09-repair-costs-detailed.xlsx`));
for (const shop of ['TW', 'FF']) {
  const sheet = workbook.worksheets.getItem(shop);
  sheet.getRange('H5').values = [[1 / 4.7]];
  sheet.getRange('H5').format.numberFormat = '0.000000';
}
workbook.recalculate();
const file = await SpreadsheetFile.exportXlsx(workbook);
await file.save(`${dir}/TW-FF-2026-09-repair-costs-fx47.xlsx`);
