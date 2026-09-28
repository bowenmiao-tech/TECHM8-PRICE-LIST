import fs from 'node:fs/promises';
import { Workbook, SpreadsheetFile } from '@oai/artifact-tool';
const dir = 'D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const lines = JSON.parse(await fs.readFile(`${dir}/missing-retail-costs-corrected.json`, 'utf8'));
const workbook = Workbook.create();
for (const shop of ['TW','FF']) {
  const groups = new Map();
  for (const x of lines.filter(x=>x.shop===shop)) {
    const key = `${x.product_id}¦${x.label}`;
    if (!groups.has(key)) groups.set(key,{ label:x.label,qty:0,sales:0,dates:[],ids:[] });
    const g=groups.get(key);g.qty+=x.net_qty;g.sales+=x.net_sales;g.dates.push(x.date);g.ids.push(x.line_id);
  }
  const sh=workbook.worksheets.add(shop);
  sh.showGridLines=false;sh.tabColor=shop==='TW'?'#155E75':'#9A3412';
  sh.getRange('A1:H1').merge();sh.getRange('A1').values=[[`${shop}｜POS 未记录进货成本的已售商品`]];
  sh.getRange('A1:H1').format={fill:'#15324A',font:{name:'Microsoft YaHei',size:16,bold:true,color:'#FFFFFF'}};
  sh.getRange('A1:H1').format.rowHeight=34;
  sh.getRange('A2:H2').merge();sh.getRange('A2').values=[['2026-09-01 至 2026-09-25；已剔除全额退货，部分退货按净售数量。请填黄色的单件进货成本及货币。']];
  sh.getRange('A4:B4').values=[['待补商品种类',groups.size]];
  sh.getRange('D4:E4').values=[['1 AUD = CNY',4.7]];
  sh.getRange('A6:H6').values=[['商品／备注','净售数量','单件进货成本','货币 (AUD/CNY)','总成本 AUD','净销售额含 GST','销售日期','POS 明细编号']];
  sh.getRange('A6:H6').format={fill:'#155E75',font:{name:'Microsoft YaHei',bold:true,color:'#FFFFFF'}};
  const data=[...groups.values()].map(g=>[g.label,g.qty,null,null,null,Math.round(g.sales*100)/100,[...new Set(g.dates)].join(', '),g.ids.join(', ')]);
  const end=6+data.length;
  sh.getRange(`A7:H${end}`).values=data;
  sh.getRange('E7').formulas=[['=IF(OR(C7="",NOT(ISNUMBER(C7))),"",IF(D7="CNY",B7*C7/$E$4,IF(D7="AUD",B7*C7,"")))']];
  sh.getRange(`E7:E${end}`).fillDown();
  sh.getRange(`C7:D${end}`).format.fill='#FFF1D6';
  sh.getRange(`A7:H${end}`).format.borders={preset:'all',style:'thin',color:'#D9E2E8'};
  sh.getRange(`C7:C${end}`).format.numberFormat='$#,##0.00';
  sh.getRange(`E7:F${end}`).format.numberFormat='$#,##0.00';
  sh.getRange('A:A').format.columnWidth=74;
  sh.getRange('B:B').format.columnWidth=13;
  sh.getRange('C:C').format.columnWidth=22;
  sh.getRange('D:D').format.columnWidth=20;
  sh.getRange('E:F').format.columnWidth=22;
  sh.getRange('G:G').format.columnWidth=35;
  sh.getRange('H:H').format.columnWidth=38;
  sh.freezePanes.freezeRows(6);
  console.log(`${shop}: ${groups.size} kinds, ${data.reduce((a,x)=>a+x[1],0)} net units`);
}
workbook.recalculate();
for(const shop of ['TW','FF']){
  const preview=await workbook.render({sheetName:shop,range:shop==='TW'?'A1:H10':'A1:H12',scale:1.3,format:'png'});
  await fs.writeFile(`${dir}/${shop}-retail-gap-preview.png`,new Uint8Array(await preview.arrayBuffer()));
}
const file=await SpreadsheetFile.exportXlsx(workbook);
await file.save(`${dir}/TW-FF-missing-retail-costs-corrected.xlsx`);
