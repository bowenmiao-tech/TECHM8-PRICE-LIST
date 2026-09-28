import fs from 'node:fs/promises';
import { Workbook, SpreadsheetFile } from '@oai/artifact-tool';

const source = await fs.readFile('D:/program/TECHM8 PRICE LIST/outputs/2026-09-TW-FF-repair-costs.md', 'utf8');
const outputDir = 'D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const workbook = Workbook.create();
const sections = {};
let current = null;
for (const line of source.split(/\r?\n/)) {
  const heading = line.match(/^## (TW|FF)（/);
  if (heading) { current = heading[1]; sections[current] = []; continue; }
  if (!current || !line.startsWith('| ') || line.startsWith('|---') || line.includes('| 维修项目 |')) continue;
  const cells = line.slice(2, -2).split(' | ');
  if (cells.length >= 2) sections[current].push([cells[0].replaceAll('\\|', '|'), Number(cells[1])]);
}
for (const shop of ['TW', 'FF']) {
  const data = sections[shop];
  const sh = workbook.worksheets.add(shop);
  sh.showGridLines = false;
  sh.tabColor = shop === 'TW' ? '#155E75' : '#9A3412';
  sh.getRange('A1:G1').merge();
  sh.getRange('A1').values = [[`${shop}｜2026年9月维修配件成本`]];
  sh.getRange('A1:G1').format = { fill: '#15324A', font: { name: 'Microsoft YaHei', size: 16, bold: true, color: '#FFFFFF' } };
  sh.getRange('A1:G1').format.rowHeight = 34;
  sh.getRange('A2:G2').merge();
  sh.getRange('A2').values = [['POS 销售记录：2026-09-01 至 2026-09-25；同名维修项目已合并。数量为维修销售条目数。']];
  sh.getRange('A3:G3').merge();
  sh.getRange('A3').values = [['填写 C 栏每次实际使用的配件成本，并在 D 栏填“含 GST”或“不含 GST”；未用配件填 0。']];
  sh.getRange('A5:B5').values = [['维修销售条目数', data.reduce((a, x) => a + x[1], 0)]];
  sh.getRange('D5:E5').values = [['已填成本合计', null]];
  sh.getRange('A6:B6').values = [['未填成本项目数', null]];
  sh.getRange('A8:G8').values = [['维修项目', '数量', '单次配件成本 (AUD)', '成本 GST 口径', '单次不含 GST 成本', '配件总成本（不含 GST）', '备注']];
  sh.getRange('A8:G8').format = { fill: '#155E75', font: { name: 'Microsoft YaHei', bold: true, color: '#FFFFFF' } };
  const start = 9, end = start + data.length - 1;
  sh.getRange(`A${start}:B${end}`).values = data;
  sh.getRange(`C${start}:D${end}`).values = data.map(() => [null, null]);
  sh.getRange(`G${start}:G${end}`).values = data.map(() => [null]);
  sh.getRange(`E${start}`).formulas = [[`=IF(C${start}="","",IF(D${start}="含 GST",C${start}/1.1,C${start}))`]];
  sh.getRange(`E${start}:E${end}`).fillDown();
  sh.getRange(`F${start}`).formulas = [[`=IF(E${start}="","",B${start}*E${start})`]];
  sh.getRange(`F${start}:F${end}`).fillDown();
  sh.getRange('E5').formulas = [[`=SUM(F${start}:F${end})`]];
  sh.getRange('B6').formulas = [[`=COUNTBLANK(C${start}:C${end})`]];
  sh.getRange(`C${start}:D${end}`).format.fill = '#FFF1D6';
  sh.getRange(`A${start}:G${end}`).format.borders = { preset: 'all', style: 'thin', color: '#D9E2E8' };
  sh.getRange(`C${start}:C${end}`).format.numberFormat = '$#,##0.00';
  sh.getRange(`E${start}:F${end}`).format.numberFormat = '$#,##0.00';
  sh.getRange('E5').format.numberFormat = '$#,##0.00';
  sh.getRange('A:A').format.columnWidth = 72;
  sh.getRange('B:B').format.columnWidth = 10;
  sh.getRange('C:C').format.columnWidth = 23;
  sh.getRange('D:D').format.columnWidth = 18;
  sh.getRange('E:F').format.columnWidth = 26;
  sh.getRange('G:G').format.columnWidth = 35;
  sh.freezePanes.freezeRows(8);
  console.log(`${shop}: ${data.length} distinct projects, ${data.reduce((a, x) => a + x[1], 0)} lines`);
}
workbook.recalculate();
await fs.mkdir(outputDir, { recursive: true });
for (const shop of ['TW', 'FF']) {
  const preview = await workbook.render({ sheetName: shop, range: 'A1:G14', scale: 1.5, format: 'png' });
  await fs.writeFile(`${outputDir}/${shop}-preview.png`, new Uint8Array(await preview.arrayBuffer()));
}
const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(`${outputDir}/TW-FF-2026-09-repair-costs.xlsx`);
