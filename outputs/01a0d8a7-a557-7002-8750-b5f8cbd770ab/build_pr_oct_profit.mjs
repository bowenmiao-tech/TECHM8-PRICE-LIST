import fs from 'node:fs/promises';
import {Workbook,SpreadsheetFile} from '@oai/artifact-tool';
const dir='D:/program/TECHM8 PRICE LIST/outputs/01a0d8a7-a557-7002-8750-b5f8cbd770ab';
const d=JSON.parse(await fs.readFile(dir+'/PR-2026-10-cost-analysis.json','utf8'));
const wb=Workbook.create(), sh=wb.worksheets.add('PR 十月利润');
sh.showGridLines=false;
sh.getRange('A2').values=[['Park Ridge｜2026 年 10 月估算经营利润']];
sh.getRange('A3').values=[['AUD、不含 GST；销售按十月实际收款减退款，成本按十月销售项目估算。']];
sh.getRange('A5:C5').values=[['项目','金额 AUD','来源 / 口径']];
const deviceKnown=1161,deviceSalesKnown=2276/1.1,deviceRemaining=3839.10-deviceSalesKnown,deviceUnknown=deviceRemaining*(deviceKnown/deviceSalesKnown);
const rows=[
 ['收款减退款（含 GST）',44585.25,'RepairDesk：十月 Cash Basis，Payments In $44,893.25 − Out $308.00'],
 ['销售净额（不含 GST）',null,'按已采用的 10% GST 估算'],
 ['工资',7815,'260.5 小时 × $30，不加 super / leave'],
 ['租金及经常性商场费',6885.35,'11 月账单经常性项目作为十月暂估；不含 GST'],
 ['电费',130/1.1,'每月 $130 含 GST 的估算'],
 ['网费',120/1.1,'每月 $120 含 GST 的估算'],
 ['商品成本',d.summary.product_book_cost+d.summary.product_missing_est,'POS 已记 $1,763.56 + 缺价商品估算'],
 ['维修配件成本',d.summary.repair_est_total,'按 75 类维修项目逐项估算，含 POS 已记 $110'],
 ['二手机成本',deviceKnown+deviceUnknown,'5 台 POS 进货成本 $1,161；另 4 台参照已知成本率估算'],
 ['总费用及成本',null,'工资、经常性费用及直接成本合计'],
 ['估算经营利润',null,'销售净额 − 总费用及成本']
];
sh.getRange('A6:C16').values=rows;
sh.getRange('B7').formulas=[['=B6/1.1']];
sh.getRange('B15').formulas=[['=SUM(B8:B14)']];
sh.getRange('B16').formulas=[['=B7-B15']];
sh.getRange('A19:C19').values=[['核对项','金额 AUD','说明']];
sh.getRange('A20:C26').values=[
 ['RepairDesk 十月销售（权责口径，不含 GST）',41173.91,'与上方收款口径不同，不能叠加'],
 ['RepairDesk 原始商品 COGS',1763.56,'200 类商品中 73 类成本为 $0'],
 ['商品缺价估算',d.summary.product_missing_est,'参照已填商品的成本率及杂项规则'],
 ['RepairDesk 原始维修 COGS',110,'149 个维修数量，绝大多数配件成本为 $0'],
 ['维修补估成本',d.summary.repair_missing_est,'参照屏幕价目及同类已填成本'],
 ['二手机未记录成本估算',deviceUnknown,'9 台设备中 5 台有 POS 进货价，其余 4 台估算'],
 ['销售按权责口径时的利润',null,'仅供与 RepairDesk Sales by Item 对照']
];
sh.getRange('B26').formulas=[['=B20-B15']];
sh.getRange('A28').values=[['租金暂估：11 月 WillCom 发票中 Retail Rent $5,720、Airconditioning $33.27、General Outgoings $846.08、Promotion $286（均未含 GST）。']];
sh.getRange('A29').values=[['未把账单内旧月份水电、FY25/26 调整及 GST 加入十月租金；PR 十月真实租金发票未取得。']];
sh.getRange('A30').values=[['商品及维修成本为估算；二手机 5 台实际进货成本来自 POS，剩余 4 台按同批设备成本/销售比率估算。']];
sh.getRange('A31').values=[['RepairDesk 商品/维修销售额和成本为权责口径；主结果沿用前三店的收款口径，存在交易时点差异。']];
sh.getRange('A2:C31').format.font={name:'Arial',size:10,color:'#1F2937'};
sh.getRange('A2').format.font={name:'Arial',size:16,bold:true,color:'#17324D'};
sh.getRange('A3').format.font={name:'Arial',size:10,italic:true,color:'#526274'};
for(const r of [5,19])sh.getRange('A'+r+':C'+r).format={fill:'#243B53',font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'}};
for(const r of [15,16])sh.getRange('A'+r+':C'+r).format={fill:r===16?'#DCEFE8':'#EAF2FF',font:{name:'Arial',size:12,bold:true,color:'#17324D'}};
sh.getRange('B6:B26').setNumberFormat('"$"#,##0.00;[Red]("$"#,##0.00)');
for(const [c,w] of Object.entries({A:45,B:22,C:100}))sh.getRange(c+':'+c).format.columnWidth=w;
sh.getRange('A5:C26').format.rowHeight=28;
sh.freezePanes.freezeRows(5);
function detail(name,title,headers,rows,widths,estimateCol){
 const s=wb.worksheets.add(name);s.showGridLines=false;s.getRange('A2').values=[[title]];
 const last=String.fromCharCode(64+headers.length),end=6+rows.length;
 s.getRange('A6:'+last+'6').values=[headers];
 s.getRange('A7:'+last+end).values=rows;
 s.getRange('A2:'+last+end).format.font={name:'Arial',size:10,color:'#1F2937'};
 s.getRange('A2').format.font={name:'Arial',size:15,bold:true,color:'#17324D'};
 s.getRange('A6:'+last+'6').format={fill:'#243B53',font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'}};
 s.getRange(estimateCol+'7:'+estimateCol+end).format.fill='#FFF2C6';
 for(let i=0;i<widths.length;i++)s.getRange(String.fromCharCode(65+i)+':'+String.fromCharCode(65+i)).format.columnWidth=widths[i];
 s.getRange('A6:'+last+end).format.rowHeight=27;s.freezePanes.freezeRows(6);return s;
}
let repair=d.repair.map((r,i)=>[i+1,r.model,r.name,r.qty,r.sales,r.book_cost,r.estimate,r.basis]);
let rs=detail('维修成本','75 类维修｜原成本与补估',['编号','型号','维修项目','数量','销售 不含GST','POS 成本','采用成本','依据'],repair,[8,30,76,10,22,19,19,31],'G');
rs.getRange('E7:G81').setNumberFormat('"$"#,##0.00');
let products=d.product_missing.map((r,i)=>[i+1,r.category,r.name,r.qty,r.sales,r.estimate,r.basis]);
let ps=detail('商品缺价估算','73 类 POS 成本为 $0 的商品',['编号','类别','商品','数量','销售 不含GST','补估成本','依据'],products,[8,62,80,10,22,19,38],'F');
ps.getRange('E7:F79').setNumberFormat('"$"#,##0.00');
wb.recalculate();
const preview=await wb.render({sheetName:'PR 十月利润',range:'A2:C26',scale:1.3,format:'png'});
await fs.writeFile(dir+'/PR-2026-10-估算利润预览.png',new Uint8Array(await preview.arrayBuffer()));
const out=await SpreadsheetFile.exportXlsx(wb);await out.save(dir+'/PR-2026-10-估算利润.xlsx');
console.log('saved');
