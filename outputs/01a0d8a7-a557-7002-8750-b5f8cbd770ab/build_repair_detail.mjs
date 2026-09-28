import fs from 'node:fs/promises';
import { FileBlob, Workbook, SpreadsheetFile } from '@oai/artifact-tool';

const dir = 'D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const source = JSON.parse(await fs.readFile(`${dir}/repair-detail-source.json`, 'utf8'));
const old = await SpreadsheetFile.importXlsx(await FileBlob.load(`${dir}/TW-FF-2026-09-repair-costs.xlsx`));
const inputMap = {};
for (const shop of ['TW', 'FF']) {
  inputMap[shop] = new Map();
  const values = old.worksheets.getItem(shop).getRange(`A9:G${shop === 'TW' ? 54 : 41}`).values;
  for (const row of values) if (row[0]) inputMap[shop].set(String(row[0]), { cost: row[2], gst: row[3], note: row[6] });
}
const wb = Workbook.create();
for (const [shop, id] of [['TW', 1], ['FF', 4]]) {
  const rows = source.filter(x => x.store_id === id);
  const sh = wb.worksheets.add(shop);
  sh.showGridLines = false;
  sh.tabColor = shop === 'TW' ? '#155E75' : '#9A3412';
  sh.getRange('A1:J1').merge();
  sh.getRange('A1').values = [[`${shop}｜2026年9月维修成本逐单复查`]];
  sh.getRange('A1:J1').format = { fill: '#15324A', font: { name: 'Microsoft YaHei', size: 16, bold: true, color: '#FFFFFF' } };
  sh.getRange('A1:J1').format.rowHeight = 34;
  sh.getRange('A2:J2').merge();
  sh.getRange('A2').values = [['来源：POS 维修销售明细及对应工单；日期 2026-09-01 至 2026-09-25。原表已填成本已带入。']];
  sh.getRange('A3:J3').merge();
  sh.getRange('A3').values = [['每行是一条维修销售项；黄色栏可修改。GST 口径填“含 GST”或“不含 GST”，人民币成本填 CNY 并在 H5 输入兑换率。']];
  sh.getRange('A5:B5').values = [['维修销售条目数', rows.length]];
  sh.getRange('D5:E5').values = [['未填成本条目数', null]];
  sh.getRange('G5:H5').values = [['1 CNY 折合 AUD', null]];
  sh.getRange('J5').values = [['CNY 成本需填 H5 汇率']];
  sh.getRange('A7:J7').values = [['日期', '工单号', '设备/机型（工单）', '维修销售项目', '销售额含 GST', '单次配件成本', '货币', 'GST 口径', '配件成本 AUD 不含 GST', '复查备注']];
  sh.getRange('A7:J7').format = { fill: '#155E75', font: { name: 'Microsoft YaHei', bold: true, color: '#FFFFFF' } };
  const first = 8, last = first + rows.length - 1;
  const data = rows.map(x => {
    const prior = inputMap[shop].get(x.name) || {};
    let cost = prior.cost ?? null, currency = cost === null ? null : 'AUD';
    if (typeof cost === 'string' && /RMB|CNY/i.test(cost)) { currency = 'CNY'; cost = Number((cost.match(/[\d.]+/) || [])[0]); }
    const device = x.title?.startsWith('Onsite/Remote Assistance') ? '' : (x.title || '');
    const notes = [];
    if (prior.note) notes.push(String(prior.note));
    if (x.issue && x.issue !== x.name && !x.title?.startsWith('Onsite/Remote Assistance') && /Battery|Back Glass Replacement/i.test(x.name) && !/Battery|Back Glass Replacement/i.test(x.issue)) notes.push(`工单故障为 ${x.issue}，请核对销售项目`);
    if (!device && /^(Battery|Charging port|Charging Socket|Screen Replacement|Screen Replacement \(LCD\)|Screen Replacement \(OLED\))$/i.test(x.name)) notes.push('工单未写具体机型');
    return [x.business_date, x.ticket_code || '', device, x.name, x.line_total, Number.isFinite(cost) ? cost : null, currency, prior.gst || null, null, notes.join('；')];
  });
  sh.getRange(`A${first}:J${last}`).values = data;
  sh.getRange(`I${first}`).formulas = [[`=IF(F${first}="","",IF(G${first}="CNY",IF($H$5="","",F${first}*$H$5),IF(H${first}="含 GST",F${first}/1.1,IF(H${first}="不含 GST",F${first},""))))`]];
  sh.getRange(`I${first}:I${last}`).fillDown();
  sh.getRange('E5').formulas = [[`=COUNTBLANK(F${first}:F${last})`]];
  sh.getRange(`F${first}:H${last}`).format.fill = '#FFF1D6';
  sh.getRange('H5').format.fill = '#FFF1D6';
  sh.getRange(`A${first}:J${last}`).format.borders = { preset: 'all', style: 'thin', color: '#D9E2E8' };
  sh.getRange(`E${first}:F${last}`).format.numberFormat = '$#,##0.00';
  sh.getRange(`I${first}:I${last}`).format.numberFormat = '$#,##0.00';
  sh.getRange('A:A').format.columnWidth = 14;
  sh.getRange('B:B').format.columnWidth = 25;
  sh.getRange('C:C').format.columnWidth = 40;
  sh.getRange('D:D').format.columnWidth = 72;
  sh.getRange('E:E').format.columnWidth = 20;
  sh.getRange('F:F').format.columnWidth = 20;
  sh.getRange('G:H').format.columnWidth = 15;
  sh.getRange('I:I').format.columnWidth = 24;
  sh.getRange('J:J').format.columnWidth = 45;
  sh.freezePanes.freezeRows(7);
  console.log(`${shop}: ${rows.length} detail rows, ${data.filter(x => x[5] !== null).length} carried costs`);
}
wb.recalculate();
for (const shop of ['TW', 'FF']) {
  const preview = await wb.render({ sheetName: shop, range: 'A1:J13', scale: 1.2, format: 'png' });
  await fs.writeFile(`${dir}/${shop}-detail-preview.png`, new Uint8Array(await preview.arrayBuffer()));
}
const file = await SpreadsheetFile.exportXlsx(wb);
await file.save(`${dir}/TW-FF-2026-09-repair-costs-detailed.xlsx`);
