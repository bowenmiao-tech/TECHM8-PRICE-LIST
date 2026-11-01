import fs from 'node:fs/promises';
import {Workbook,SpreadsheetFile} from '@oai/artifact-tool';
const dir='D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const d=JSON.parse(await fs.readFile(dir+'/october_profit_data.json','utf8'));
const wb=Workbook.create();
const sh=wb.worksheets.add('十月利润汇总');sh.showGridLines=false;
sh.getRange('A2').values=[['TW · FF · NL｜2026 年 10 月估算经营利润']];
sh.getRange('A3').values=[['金额 AUD；销售、租金、电费、网费按不含 GST 计算。PR 不计入。']];
sh.getRange('A4').values=[['工资按营业工时 × $30，不加 super/leave；POS 费、水费为 $0。']];
sh.getRange('A6:E6').values=[['项目','TW','FF','NL','三店合计']];
const rent={TW:7376,FF:5154,NL:15829.26};
const vals=[
 ['净收款（不含 GST）',...['TW','FF','NL'].map(s=>d.sums[s].sales)],
 ['工资',...['TW','FF','NL'].map(s=>d.sums[s].wages*30/32)],
 ['租金及商场费（不含 GST）',...['TW','FF','NL'].map(s=>rent[s]/1.1)],
 ['电费（不含 GST）',...['TW','FF','NL'].map(s=>130/1.1)],
 ['网费（不含 GST）',...['TW','FF','NL'].map(s=>120/1.1)],
 ['商品成本',...['TW','FF','NL'].map(s=>d.sums[s].retail)],
 ['二手机成本',...['TW','FF','NL'].map(s=>d.sums[s].used)],
 ['维修成本（含估算）',...['TW','FF','NL'].map(s=>d.sums[s].repair)],
 ['费用及成本合计',null,null,null],
 ['估算经营利润',null,null,null],
];
sh.getRange('A7:D16').values=vals;
for(const c of ['B','C','D']){sh.getRange(c+'15').formulas=[['=SUM('+c+'8:'+c+'14)']];sh.getRange(c+'16').formulas=[['='+c+'7-'+c+'15']];}
for(let r=7;r<=16;r++)sh.getRange('E'+r).formulas=[['=SUM(B'+r+':D'+r+')']];
sh.getRange('A19').values=[['维修成本来源']];
sh.getRange('A20:E20').values=[['来源','TW','FF','NL','合计']];
const comp=[['本月及此前填写',...['TW','FF','NL'].map(s=>d.sums[s].manual)],['本次屏幕价目',...['TW','FF','NL'].map(s=>d.sums[s].screenCost)],['现有维修参考价',...['TW','FF','NL'].map(s=>d.sums[s].priorReference)],['13 条无详情估算',...['TW','FF','NL'].map(s=>d.sums[s].estimated)]];
sh.getRange('A21:D24').values=comp;
for(let r=21;r<=24;r++)sh.getRange('E'+r).formulas=[['=SUM(B'+r+':D'+r+')']];
sh.getRange('A26').values=[['口径：按十月实际收款减退款，销售额先剔除 GST；成本按对应十月销售/维修记录扣除。']];
sh.getRange('A27').values=[['13 条不完整维修记录的估算见“13条估算”；现有维修参考价也属于估算，结果并非会计报表净利润。']];
sh.getRange('A28').values=[['NL 租金及商场费采用十月发票 12668636：$15,829.26 含 GST；电费、周日费和利息另开票，未并入此租金。']];
sh.getRange('A29').values=[['NL 有一笔 A3434 Balance 销售 $599（含 GST），你填的成本 $800 已全额计入十月。']];
sh.getRange('A2:E29').format.font={name:'Arial',size:11,color:'#1F2937'};
sh.getRange('A2').format.font={name:'Arial',size:17,bold:true,color:'#17324D'};
sh.getRange('A3:A4').format.font={name:'Arial',size:10,italic:true,color:'#526274'};
for(const r of [6,20])sh.getRange('A'+r+':E'+r).format={fill:'#243B53',font:{name:'Arial',size:11,bold:true,color:'#FFFFFF'}};
for(const r of [15,16])sh.getRange('A'+r+':E'+r).format={fill:r===16?'#DCEFE8':'#EAF2FF',font:{name:'Arial',size:12,bold:true,color:'#17324D'}};
sh.getRange('A19').format.font={name:'Arial',size:13,bold:true,color:'#17324D'};
sh.getRange('B7:E24').setNumberFormat('"$"#,##0.00;[Red]("$"#,##0.00)');
for(const [c,w] of Object.entries({A:48,B:22,C:22,D:22,E:24}))sh.getRange(c+':'+c).format.columnWidth=w;
sh.getRange('A6:E24').format.rowHeight=29;sh.freezePanes.freezeRows(6);
const es=wb.worksheets.add('13条估算');es.showGridLines=false;
es.getRange('A2').values=[['缺少型号或内容的维修｜逐条估算']];
es.getRange('A3').values=[['单件成本均为 AUD、不含 GST；估算金额可在取得实际采购记录后替换。']];
es.getRange('A6:H6').values=[['原编号','门店','日期','维修项目','POS 明细','销售额 含 GST','估算成本','估算依据']];
const rows=d.latest.repair.filter(r=>r[7]===null).map(r=>[r[0],r[1],r[2],r[3],r[4],r[6],d.estimates[Number(r[10])][0],d.estimates[Number(r[10])][1]]);
es.getRange('A7:H19').values=rows;
es.getRange('A2:H19').format.font={name:'Arial',size:10,color:'#1F2937'};
es.getRange('A2').format.font={name:'Arial',size:15,bold:true,color:'#17324D'};
es.getRange('A3').format.font={name:'Arial',size:10,italic:true,color:'#526274'};
es.getRange('A6:H6').format={fill:'#243B53',font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'}};
es.getRange('G7:G19').format.fill='#FFF2C6';
es.getRange('F7:G19').setNumberFormat('"$"#,##0.00');
for(const [c,w] of Object.entries({A:10,B:10,C:24,D:58,E:22,F:22,G:20,H:67}))es.getRange(c+':'+c).format.columnWidth=w;
es.getRange('A6:H19').format.rowHeight=30;es.freezePanes.freezeRows(6);
wb.recalculate();
const preview=await wb.render({sheetName:'十月利润汇总',range:'A2:E24',scale:1.4,format:'png'});
await fs.writeFile(dir+'/2026-10-利润汇总预览.png',new Uint8Array(await preview.arrayBuffer()));
const out=await SpreadsheetFile.exportXlsx(wb);await out.save(dir+'/TW-FF-NL-2026-10-估算利润-时薪30.xlsx');
console.log('saved');
