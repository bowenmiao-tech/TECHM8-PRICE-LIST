import fs from 'node:fs/promises';
import { Workbook, SpreadsheetFile } from '@oai/artifact-tool';

const dir = 'D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const wb = Workbook.create();
const sh = wb.worksheets.add('待补成本');
sh.showGridLines = false;
sh.getRange('A2').values = [['TW / FF 2026 年 9 月月底待补成本']];
sh.getRange('A3').values = [['只填写黄色的“单件成本”和“货币”栏。金额不含 GST；货币填 AUD 或 CNY。若没有成本，请填 0。']];
sh.getRange('A4').values = [['人民币按 1 AUD = 4.7 CNY 换算；数量已按 POS 记录填好。']];
sh.getRange('A6:G6').values = [['编号','门店','项目','数量','单件成本（不含 GST）','货币（AUD/CNY）','备注']];
const rows = [
  [1,'TW','iPhone 14 OLED 换屏',1,null,null,'维修配件成本'],
  [2,'TW','Google Pixel 9A 换屏',1,null,null,'维修配件成本'],
  [3,'TW','iPhone 12 Pro 电池',1,null,null,'维修配件成本'],
  [4,'TW','iPad 6 (2018) 电池',1,null,null,'维修配件成本'],
  [5,'TW','Miscellaneous & Other Products',1,null,null,'9 月 26 日销售 $10；请填实际商品成本'],
  [6,'TW','$2 SIM',7,null,null,'请确认是否每张成本 $0；如是填 0'],
  [7,'FF','iPhone 11 充电口',1,null,null,'维修配件成本'],
  [8,'FF','Samsung Z Flip 7 主屏',1,null,null,'维修配件成本'],
  [9,'FF','Lenovo Yoga 7 2-in-1 14IML9 键盘更换',1,null,null,'维修配件成本'],
  [10,'FF','Battery 维修（9 月 29 日已退款 $110）',1,null,null,'若配件已耗用仍填成本；未耗用填 0'],
  [11,'FF','Galaxy Note 10 电池',1,null,null,'维修配件成本'],
  [12,'FF','Google Pixel 6 电池',1,null,null,'维修配件成本'],
  [13,'FF','HP ew0023TU 铰链维修',1,null,null,'POS 售 $200；若纯人工填 0'],
];
sh.getRange('A7:G19').values = rows;
sh.getRange('A2:G19').format.font = {name:'Arial',size:10,color:'#1F2937'};
sh.getRange('A2').format.font = {name:'Arial',size:15,bold:true,color:'#172B4D'};
sh.getRange('A3:A4').format.font = {name:'Arial',size:10,italic:true,color:'#526274'};
sh.getRange('A6:G6').format = {fill:'#243B53',font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'}};
sh.getRange('E7:F19').format.fill = '#FFF2C6';
sh.getRange('E7:E19').setNumberFormat('"$"#,##0.00');
sh.getRange('A7:A19').setNumberFormat('0');
sh.getRange('D7:D19').setNumberFormat('0');
sh.getRange('A6:G19').format.verticalAlignment='center';
sh.getRange('A6:G6').format.horizontalAlignment='center';
sh.getRange('A7:G19').format.rowHeight=29;
sh.getRange('A6:G6').format.rowHeight=32;
for (const [col,width] of Object.entries({A:8,B:10,C:43,D:9,E:23,F:20,G:48})) sh.getRange(`${col}:${col}`).format.columnWidth=width;
sh.getRange('A7:A12').format.fill='#EAF2FF';
sh.getRange('A13:A19').format.fill='#E7F5F1';
sh.getRange('F7:F19').dataValidation={rule:{type:'list',values:['AUD','CNY']}};
sh.freezePanes.freezeRows(6);
wb.recalculate();
const inspected = await wb.inspect({kind:'table',range:'待补成本!A6:G19',include:'values',tableMaxRows:14,tableMaxCols:7,maxChars:9000});
console.log(inspected.ndjson);
const preview = await wb.render({sheetName:'待补成本',range:'A2:G19',scale:1.4,format:'png'});
await fs.writeFile(`${dir}/month-end-missing-costs-preview.png`,new Uint8Array(await preview.arrayBuffer()));
const out = await SpreadsheetFile.exportXlsx(wb);
await out.save(`${dir}/TW-FF-2026-09-month-end-missing-costs.xlsx`);
