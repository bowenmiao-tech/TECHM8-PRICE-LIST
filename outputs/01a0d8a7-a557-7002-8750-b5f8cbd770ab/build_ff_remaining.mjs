import fs from 'node:fs/promises';
import { FileBlob, Workbook, SpreadsheetFile } from '@oai/artifact-tool';
const dir = 'D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const source = await SpreadsheetFile.importXlsx(await FileBlob.load(`${dir}/TW-consolidated-FF-repair-costs.xlsx`));
const twRows = source.worksheets.getItem('TW 汇总').getRange('A7:J57').values;
const ffRows = source.worksheets.getItem('FF 逐单').getRange('A8:J50').values;
const findTw = (model, item) => {
  const hits = twRows.filter(r => r[0] === model && r[1] === item);
  if (hits.length !== 1) throw new Error(`TW match not unique: ${model}, ${item}, ${hits.length}`);
  return { cost: hits[0][3], currency: hits[0][4] || 'AUD', model, item };
};
const matches = new Map([
  ['RPR-1788397157905', findTw('Apple iPhone iPhone 14 Plus', 'Apple iPhone - iPhone 14 Plus - Battery')],
  ['RPR-1788656888464', findTw('Samsung S Series Samsung S23 Ultra', 'Screen Replacement')],
  ['RPR-1788916220145', findTw('Apple iPhone iPhone 13', 'Battery')],
  ['RPR-1789023748341', findTw('Apple iPhone iPhone 11', 'Apple iPhone - iPhone 11 - Screen Replacement')],
  ['RPR-1789096276805', findTw('Apple iPhone iPhone SE 3', 'Apple iPhone - iPhone SE 3 - Battery')],
]);
const wb = Workbook.create();
const full = wb.worksheets.add('FF完整清单');
const missing = wb.worksheets.add('待补成本');
full.showGridLines = false; missing.showGridLines = false;
full.tabColor = '#155E75'; missing.tabColor = '#D97706';
full.getRange('A1:J1').merge(); full.getRange('A1').values = [['FF｜2026年9月维修配件成本']];
full.getRange('A1:J1').format = { fill: '#15324A', font: { name: 'Microsoft YaHei', size: 16, bold: true, color: '#FFFFFF' } };
full.getRange('A1:J1').format.rowHeight = 34;
full.getRange('A2:J2').merge(); full.getRange('A2').values = [['已保留 FF 手填成本；仅对同机型、同维修项目的 5 条空白记录套用 TW 成本。待补成本请到第二个工作表填写。']];
full.getRange('A4:B4').values = [['维修销售条目数', 43]];
full.getRange('D4:E4').values = [['仍待补成本', null]];
full.getRange('G4:H4').values = [['1 AUD = CNY', 4.7]];
full.getRange('A6:J6').values = [['日期', '工单号', '设备/机型', '维修项目', '销售额含 GST', '单次配件成本', '货币', '成本 GST 口径', '成本 AUD 不含 GST', '成本来源/备注']];
full.getRange('A6:J6').format = { fill: '#155E75', font: { name: 'Microsoft YaHei', bold: true, color: '#FFFFFF' } };
missing.getRange('A1:H1').merge(); missing.getRange('A1').values = [['FF｜TW 无同款维修的待补成本']];
missing.getRange('A1:H1').format = { fill: '#15324A', font: { name: 'Microsoft YaHei', size: 16, bold: true, color: '#FFFFFF' } };
missing.getRange('A1:H1').format.rowHeight = 34;
missing.getRange('A2:H2').merge(); missing.getRange('A2').values = [['只需填写黄色的单次配件成本、货币与 GST 口径；无用料填 0。1 AUD = 4.7 CNY。']];
missing.getRange('A4:H4').values = [['日期', '工单号', '设备/机型', '维修项目', '销售额含 GST', '单次配件成本', '货币', '成本 GST 口径']];
missing.getRange('A4:H4').format = { fill: '#9A3412', font: { name: 'Microsoft YaHei', bold: true, color: '#FFFFFF' } };
const pending = [];
const rows = [];
const matched = [];
for (const r of ffRows) {
  if (!r[3]) continue;
  const x = { date:r[0], ticket:r[1], device:r[2], item:r[3], sale:r[4], cost:r[5], currency:r[6], gst:r[7], note:r[9] };
  let origin = 'FF 已填';
  if (x.cost === null || x.cost === '') {
    const m = matches.get(x.ticket);
    if (m) { x.cost = m.cost; x.currency = m.currency; x.gst = '不含 GST'; origin = `参考 TW：${m.model}／${m.item}`; matched.push(x); }
    else { x.pendingRow = 5 + pending.length; pending.push(x); origin = '待补成本'; }
  } else if (typeof x.cost === 'string' && /CNY|RMB/i.test(x.cost)) {
    x.currency = 'CNY'; x.cost = Number((x.cost.match(/[\d.]+/) || [])[0]);
  } else if (typeof x.cost === 'number' && !x.currency) x.currency = 'AUD';
  rows.push({ ...x, origin });
}
if (matched.length !== 5 || pending.length !== 11) throw new Error(`Unexpected match counts ${matched.length} ${pending.length}`);
missing.getRange('A5:H15').values = pending.map(x => [x.date,x.ticket,x.device,x.item,x.sale,null,null,null]);
missing.getRange('F5:H15').format.fill = '#FFF1D6';
missing.getRange('A5:H15').format.borders = { preset: 'all', style: 'thin', color: '#D9E2E8' };
full.getRange('A7:J49').values = rows.map(x => [x.date,x.ticket,x.device,x.item,x.sale,typeof x.cost==='number'?x.cost:null,x.currency,x.gst,null,x.origin]);
for (let i=0;i<rows.length;i++) {
  const row = i+7, x=rows[i];
  if (x.pendingRow) {
    const p = x.pendingRow;
    full.getRange(`F${row}:H${row}`).formulas = [[`=IF('待补成本'!F${p}="","",'待补成本'!F${p})`,`=IF('待补成本'!G${p}="","",'待补成本'!G${p})`,`=IF('待补成本'!H${p}="","",'待补成本'!H${p})`]];
  }
  full.getRange(`I${row}`).formulas = [[`=IF(OR(F${row}="",NOT(ISNUMBER(F${row}))),"",IF(G${row}="CNY",F${row}/$H$4,IF(H${row}="含 GST",F${row}/1.1,IF(H${row}="不含 GST",F${row},""))))`]];
}
full.getRange('E4').formulas = [['=COUNTBLANK(F7:F49)']];
full.getRange('A7:J49').format.borders = { preset: 'all', style: 'thin', color: '#D9E2E8' };
full.getRange('E7:F49').format.numberFormat = '$#,##0.00';
full.getRange('I7:I49').format.numberFormat = '$#,##0.00';
missing.getRange('E5:F15').format.numberFormat = '$#,##0.00';
for (const sh of [full,missing]) {
  sh.getRange('A:A').format.columnWidth = 14;
  sh.getRange('B:B').format.columnWidth = 25;
  sh.getRange('C:C').format.columnWidth = 38;
  sh.getRange('D:D').format.columnWidth = 74;
  sh.getRange('E:E').format.columnWidth = 20;
  sh.getRange('F:F').format.columnWidth = 22;
  sh.getRange('G:H').format.columnWidth = 18;
}
full.getRange('I:I').format.columnWidth = 25; full.getRange('J:J').format.columnWidth = 65;
full.freezePanes.freezeRows(6); missing.freezePanes.freezeRows(4);
wb.recalculate();
const preview = await wb.render({ sheetName: '待补成本', range: 'A1:H15', scale: 1.3, format: 'png' });
await fs.writeFile(`${dir}/FF-remaining-preview.png`, new Uint8Array(await preview.arrayBuffer()));
const file = await SpreadsheetFile.exportXlsx(wb);
await file.save(`${dir}/FF-remaining-repair-costs.xlsx`);
console.log({ filledFromTw: matched.map(x=>({ticket:x.ticket,item:x.item,cost:x.cost,currency:x.currency})), missing:pending.length, total:rows.length });
