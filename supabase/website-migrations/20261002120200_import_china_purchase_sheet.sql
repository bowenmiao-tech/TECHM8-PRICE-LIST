-- Product project: one-off import of the "中澳跟单" Google Sheet (Sheet1 + 货运 tab).
-- Rows that share an international number (ACWL/BKP/APE…) become one forwarder batch.
-- 到达澳洲 rows become closed history batches; they were never counted into system stock.
-- HT numbers are 浩兔 warehouse numbers, so they are kept on the parcel as forwarder_ref.
do $import$
begin
  if exists (select 1 from public.purchase_parcels where source = 'sheet_import') then
    raise notice 'Sheet import already applied';
    return;
  end if;

  insert into public.purchase_shipments (forwarder_id, channel, tracking_numbers, status, notes, source, source_ref, created_by)
  select forwarder.id, s.channel, s.tracking, s.status, s.note, 'sheet_import', s.ref, 'Sheet import'
  from (values
    ('sheet:ACWL26081102207', 'FST Express', '海运普货', array['ACWL26081102207']::text[], 'shipped', '从「中澳跟单」表格导入'),
    ('sheet:closed:none:海运普货', null, '海运普货', array[]::text[], 'closed', '从「中澳跟单」表格导入：表格里状态为「到达澳洲」但没有国际单号'),
    ('sheet:closed:none:空运普货', null, '空运普货', array[]::text[], 'closed', '从「中澳跟单」表格导入：表格里状态为「到达澳洲」但没有国际单号'),
    ('sheet:closed:none:海运纯电', null, '海运纯电', array[]::text[], 'closed', '从「中澳跟单」表格导入：表格里状态为「到达澳洲」但没有国际单号'),
    ('sheet:shipped:none:海运普货', null, '海运普货', array[]::text[], 'shipped', '从「中澳跟单」表格导入：表格里状态为「转运发货」但没有国际单号'),
    ('sheet:BKP33211004775', 'FST Express', '海运普货', array['BKP33211004775']::text[], 'closed', '从「中澳跟单」表格导入'),
    ('sheet:ACWL26072902259', 'FST Express', '海运普货', array['ACWL26072902259']::text[], 'declared', '从「中澳跟单」表格导入'),
    ('sheet:closed:none:空运电池', null, '空运电池', array[]::text[], 'closed', '从「中澳跟单」表格导入：表格里状态为「到达澳洲」但没有国际单号'),
    ('sheet:shipped:浩兔:海运普货', '浩兔', '海运普货', array[]::text[], 'shipped', '从「中澳跟单」表格导入：表格里状态为「转运发货」但没有国际单号'),
    ('sheet:closed:none:空运', null, '空运', array[]::text[], 'closed', '从「中澳跟单」表格导入：表格里状态为「到达澳洲」但没有国际单号'),
    ('sheet:8968840090132', '浩兔', '海运普货', array['8968840090132']::text[], 'declared', '从「中澳跟单」表格导入'),
    ('sheet:APE000017862', '浩兔', '海运普货', array['APE000017862']::text[], 'shipped', '从「中澳跟单」表格导入'),
    ('sheet:freight-tab', null, null, array[]::text[], 'closed', '从「中澳跟单」表格的「货运」页导入的旧申报明细（国内收货：深圳），当时没有记录状态')
  ) as s(ref, forwarder_name, channel, tracking, status, note)
  left join public.purchase_forwarders forwarder on forwarder.name = s.forwarder_name;

  insert into public.purchase_parcels (contents, courier, tracking_no, carton_count, forwarder_id, channel, forwarder_ref,
    shipment_id, declared_value, notes, source, source_ref, created_by)
  select coalesce(p.contents, ''), p.courier, p.tracking, p.cartons, forwarder.id, p.channel, p.forwarder_ref,
    shipment.id, p.declared_value, p.notes, 'sheet_import', p.ref, 'Sheet import'
  from (values
    ('中澳跟单 Sheet1 第877行', 'c to c 1m的 苹果能用的 x100。
2m type cto typec 苹果能用的x20
2m usb to typec 苹果能用的x20
3m usb to lightning x5', '信丰物流', '188138160600', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, '已发新的截图'),
    ('中澳跟单 Sheet1 第878行', '当当垫子', '邮政', '8199833190510', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第879行', '3usb x30, 45w 2type x50', '加运美', 'JYM800118713634', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第880行', '手机链条44条', '圆通', 'YT2545957857208', 1, null, '空运普货', null, 'sheet:closed:none:空运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第881行', '米尔48个 26/26 黑绿粉5each，26+三色3each，17e黑绿粉3each', '加运美', 'JYM800100326997', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第882行', 'c to usb otg  x 30', '中通', '78999564029687', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第883行', 'wk耳机x40 支架 x20 线x1', '顺丰', 'SF1566509588438', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第884行', '车尾箱垫', '圆通', 'YT7620145813248', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第885行', 'flip case x10，apple logo， casetify', '加运美', 'JYM188055146850', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第886行', '小颜壳', '加运美', 'JYM188055143562', 1, null, '空运普货', null, 'sheet:closed:none:空运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第887行', '拆机线 x4', '韵达', '435174961919943', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第888行', '维修电池', '中通', '79004289848030', 1, null, '海运纯电', null, 'sheet:closed:none:海运纯电', null::numeric, null),
    ('中澳跟单 Sheet1 第889行', '荔枝纹ipad壳 45个', '加运美', 'JYM188049944309', 1, null, '海运普货', null, 'sheet:shipped:none:海运普货', null::numeric, '表格国际单号栏写着「不见」'),
    ('中澳跟单 Sheet1 第890行', '2m数据线x40', '信丰物流', '188136281506', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第891行', '内胆包', '顺丰', 'SF0221036459145', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第892行', '拖鞋x2', '邮政', '9822383105287', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第893行', 'ipad hard case 31个', '信丰物流', 'XF0067394931', 1, 'FST Express', '海运普货', null, 'sheet:BKP33211004775', null::numeric, null),
    ('中澳跟单 Sheet1 第894行', '钢化膜海运 28/05', '京广速递', '300057900556', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第895行', '荔枝纹ipad壳 36个', '加运美', 'JYM188056174591', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第896行', '数据线 1m 130根', '信丰物流', '188133189667', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第897行', '数据线2m &3m 35根', '信丰物流', '188144331847', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第898行', '包装盒 150个', '联昊通', '801774373670', 1, 'FST Express', '海运普货', null, 'sheet:BKP33211004775', null::numeric, null),
    ('中澳跟单 Sheet1 第899行', '荔枝纹ipad壳 21个', '加运美', 'JYM88058100288', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第900行', '荔枝纹ipad壳 13个', '加运美', 'JYM188058183484', 1, null, '海运普货', null, 'sheet:closed:none:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第901行', 'Flip case99个', '加运美', 'JYM800100327424', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第902行', '1u1c charge x200, 2u2c charger x100, 120W x20', '加运美', 'JYM800121956437', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第903行', 'remax 车载支架，订了需要补资料', '源安达', '800021999346', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第904行', 'WK 176 条线', '源安达', '800020632337', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第905行', 'sd读卡器x30', '中通', '79019379538626', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第906行', '小配件盒子x30', '中通', '79019408211007', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第907行', '2m网限 x30', '圆通', 'YT7633378814164', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第908行', '电池一个FA7', '顺丰', 'SF5159672550781', 1, null, '空运电池', null, 'sheet:closed:none:空运电池', null::numeric, null),
    ('中澳跟单 Sheet1 第909行', '风枪一个', '申通', '773432459579076', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第910行', '风枪+爆破笔x3', '圆通', 'YT7633742358214', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第911行', '钳子x5', '申通', '773432448107934', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第912行', '屏幕x1', '京东', 'JDAP20517064303', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第913行', 'ctomagsafe 3x10', '速腾', '888073514489', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第914行', '猫玩具', '邮政', '9822831592285', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第915行', '贵妃椅', '顺丰', 'S71296109517', 2, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第916行', '沙发 吧台椅', '韵达', '990391524', 1, '浩兔', '海运普货', 'HT26009010015', 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第917行', '遮阳帘', '邮政', '8193256140910', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第918行', '小颜手机壳106', '加运美', 'JYM188061404885', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第919行', '加米尔23+36=59个，米罗3代24', '加运美', 'JYM800114738127', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26072902259', null::numeric, null),
    ('中澳跟单 Sheet1 第920行', '空运钢化膜 675 看表3', null, null, 1, null, '空运普货', null, 'sheet:closed:none:空运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第921行', '18系列90个', '京广速递', 'KK000035275306', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第922行', '胡椒研磨机', '中通', '79024079547359', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第923行', '锅盖把手', '极兔', 'JT3172966118653', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第924行', '层板', '中通', '79021109305971', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第925行', '挂钩', '中通', '79021145229338', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第926行', '特斯拉', '韵达', '435294334853154', 1, null, '空运', null, 'sheet:closed:none:空运', null::numeric, null),
    ('中澳跟单 Sheet1 第927行', '垃圾桶', '极兔', 'JT3173017151052', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第928行', '置物架', '中通', '79024097915778', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第929行', '支架', '极兔', 'JT3173012159802', 1, 'FST Express', '海运普货', null, 'sheet:ACWL26081102207', null::numeric, null),
    ('中澳跟单 Sheet1 第930行', 'pop 100个', '极兔', 'JT3174092955726', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第931行', '对联 （搬家）', '极兔', 'JT3173013417822', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第932行', '窗帘 主卧', '顺丰', 'SF5110574741352', 1, null, '海运普货', null, null, null::numeric, '表格里没有填状态'),
    ('中澳跟单 Sheet1 第933行', '饮水机（在沙发里面）', null, null, 1, '浩兔', '海运普货', 'HT26009010015', 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第934行', '窗帘杆（在沙发里面）', null, null, 1, '浩兔', '海运普货', 'HT26009010015', 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第935行', '荔枝纹ipad壳 56个', '加运美', 'JYM188062471123', 1, '浩兔', '海运普货', null, 'sheet:8968840090132', null::numeric, null),
    ('中澳跟单 Sheet1 第936行', '厨房水槽收纳', '申通', '773437151300201', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第937行', '小颜壳 （17pm）', '加运美', 'JYM88062483244', 1, null, '空运', null, 'sheet:closed:none:空运', null::numeric, null),
    ('中澳跟单 Sheet1 第938行', '样品 新壳x1', '加运美', 'JYM80010857112', 1, null, '空运', null, 'sheet:closed:none:空运', null::numeric, null),
    ('中澳跟单 Sheet1 第939行', '胶水x10', '韵达', '435317442455546', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第940行', 'dptodp 4k x10', '韵达', '435317358980528', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第941行', '贴纸x20排', '中通', '79026693261876', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第942行', '翻新手机屏幕和ipad屏幕', '顺丰', 'SF0216716701455', 1, '浩兔', '海运普货', null, 'sheet:APE000017862', null::numeric, null),
    ('中澳跟单 Sheet1 第943行', '海运钢化膜', '京广速递', '300057901621', 1, '浩兔', '海运普货', null, 'sheet:APE000017862', null::numeric, null),
    ('中澳跟单 Sheet1 第944行', '数据线', '信丰物流', '188145302768', 1, '浩兔', '海运普货', null, 'sheet:APE000017862', null::numeric, null),
    ('中澳跟单 Sheet1 第945行', '空气炸锅', '顺丰', 'SF1983643527231', 1, '浩兔', '海运普货', null, 'sheet:APE000017862', null::numeric, null),
    ('中澳跟单 Sheet1 第946行', '小颜手机壳 86个+ipad壳44个', '加运美', 'JYM188062483397', 1, '浩兔', '海运普货', 'HT2608220021 HT2608220022 HT2608220023 HT2608220024 HT2608220025 HT2608220026 HT2608220027', 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第947行', '展示盒 4个', null, null, 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第948行', 'remax 耳机+手机支架+p10', '源之安', '800021999930', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第949行', 'wk 数据线+充电宝', '加运美', 'JYM188062515015001', 3, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, '表格发货人栏: 三箱'),
    ('中澳跟单 Sheet1 第950行', '后摄像头+镜片', '中通', '7926350462712', 1, null, '空运', null, 'sheet:closed:none:空运', null::numeric, null),
    ('中澳跟单 Sheet1 第951行', '键盘x3', '顺丰', 'SF0217826824649', 1, '浩兔', '海运普货', null, 'sheet:shipped:浩兔:海运普货', null::numeric, null),
    ('中澳跟单 Sheet1 第952行(1)', '挤酱瓶x10', '圆通', 'YT7633940635223', 1, null, '海运普货', null, null, null::numeric, '表格原单元格: BBK'),
    ('中澳跟单 Sheet1 第952行(2)', '贴纸300张', '圆通', 'YT7634316416459', 1, null, '海运普货', null, null, null::numeric, '表格原单元格: BBK'),
    ('中澳跟单 Sheet1 第952行(3)', '吸管桶', '圆通', 'YT7629075591723', 1, null, '海运普货', null, null, null::numeric, '表格原单元格: BBK'),
    ('中澳跟单 Sheet1 第953行', '窗帘', '邦德', 'DPK202799473674', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第954行', '鞋垫', '极兔', 'JT3174573192829', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第955行', '马桶刷', '中通', '79024225729500', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第956行', '热狗盒子', '中通', 'YT7606354808132', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第957行', '45kg的东西', '顺丰', 'S71296109517', 1, null, '海运普货', null, null, null::numeric, '单号备注: S7296109517001'),
    ('中澳跟单 Sheet1 第958行', '18系列Flip case 59个', '加运美', 'JYM800114738127', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第959行', 'Flip Case78个', '加运美', 'JYM800100327407', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第960行', '小颜iphone 18 case 58个', '加运美', 'JYM188064025909', 1, null, '空运', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第961行', '小颜silicon Samsung 33个', '加运美', 'JYM188064025859', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第962行', '18系列 back cover 肤感 240个', '加运美', 'JYM800124145306', 1, null, '空运', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第963行', 'magsafe car holder x100，台面car holder x100', '优速', '519222114846', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第964行', '钢化膜空运 18系列 和s24+ （表3左上）', '京广速递', '300059078743', 1, null, '空运', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第965行', '钢化膜海运iPad和iPhone 表三右上', '京广速递', '300057901661', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第966行', '手机长链条', '圆通', 'YT2551856390120', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第967行', 'A3 支架x5', '邮政', '9823112235482', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第968行', '32寸显示器', '德邦', 'DPK301925753062', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第969行', '金属片 300个', '中通', '79030070316652', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第970行', 'HDMI 2M 4K 20', null, null, 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第971行', 'MINI USB X10', '韵达', '435346439028609', 1, '浩兔', '海运普货', 'HT2609090021', null, null::numeric, null),
    ('中澳跟单 Sheet1 第972行', 'wk 有线耳机25x3', null, null, 1, '浩兔', '海运普货', null, null, null::numeric, '表格里没有填状态'),
    ('中澳跟单 Sheet1 第973行', '维修后玻璃+电池', '中通', '79031293507083', 1, null, '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第974行', '带灯2.1m支架', '平安达', '700081250848', 1, '浩兔', '海运普货', 'HT2609090022', null, null::numeric, null),
    ('中澳跟单 Sheet1 第975行', '打印机线20条', null, null, 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第976行', '手套 bbk', '中通', '79031601482810', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第977行', null, '申通', '773440803678471', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第978行', 'airpods 4 卡通壳 20个', '申通', '5127456062007037744', 1, '浩兔', '海运普货', null, null, null::numeric, null),
    ('中澳跟单 Sheet1 第979行', '空运钢化膜 24/09', null, null, 1, null, '空运', null, null, null::numeric, null),
    ('中澳跟单 货运 第2行', 'ipad 壳 19 个', null, null, 1, null, null, null, 'sheet:freight-tab', 855::numeric, '发货人: 欧硕；表格编号: 8866990008312；电/磁: NO'),
    ('中澳跟单 货运 第3行', '钢化膜', null, null, 1, null, null, null, 'sheet:freight-tab', 720::numeric, '发货人: 膜；电/磁: NO'),
    ('中澳跟单 货运 第4行', '书', null, null, 1, null, null, null, 'sheet:freight-tab', 0::numeric, '电/磁: NO'),
    ('中澳跟单 货运 第5行', 'REMAX 线', null, null, 1, null, null, null, 'sheet:freight-tab', 932::numeric, '电/磁: NO'),
    ('中澳跟单 货运 第6行', '行车记录仪', null, null, 1, null, null, null, 'sheet:freight-tab', 330::numeric, '电/磁: NO'),
    ('中澳跟单 货运 第7行', '表带', null, null, 1, null, null, null, 'sheet:freight-tab', 577::numeric, '电/磁: NO'),
    ('中澳跟单 货运 第8行', '表带', null, null, 1, null, null, null, 'sheet:freight-tab', 30.4::numeric, '电/磁: NO'),
    ('中澳跟单 货运 第9行', 'MAC CHARGER', null, null, 1, null, null, null, 'sheet:freight-tab', 1179::numeric, '电/磁: NO')
  ) as p(ref, contents, courier, tracking, cartons, forwarder_name, channel, forwarder_ref, shipment_ref, declared_value, notes)
  left join public.purchase_forwarders forwarder on forwarder.name = p.forwarder_name
  left join public.purchase_shipments shipment on shipment.source = 'sheet_import' and shipment.source_ref = p.shipment_ref
  order by p.ref;
end;
$import$;
