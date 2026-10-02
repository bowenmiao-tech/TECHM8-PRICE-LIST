(function () {
  'use strict';

  const SUPABASE = window.TECHM8_SUPABASE || {};
  const ENDPOINT = window.TECHM8_PURCHASING_ENDPOINT
    || 'https://fwlronvmgqzkleofriis.supabase.co/functions/v1/admin-purchasing';
  const DEFAULT_STORE_SLUG = 'fairfield';
  const RATE_KEY = 'techm8_purchase_cny_aud_rate';
  const SIGNER_KEY = 'techm8_purchase_receiver';
  const DOMESTIC_TRACK_URL = 'https://www.kuaidi100.com/chaxun?nu=';

  const COURIERS = ['顺丰', '中通', '圆通', '韵达', '申通', '极兔', '京东', '邮政', '德邦', '加运美', '信丰物流',
    '京广速递', '联昊通', '源安达', '速腾', '优速', '邦德', '平安达', '跨越速运', '安能', '其他'];
  const PAYMENT_METHODS = ['支付宝', '微信', '银行转账', 'PayPal', '信用卡', '现金', '其他'];
  const CURRENCIES = ['CNY', 'AUD', 'USD'];

  const SHIPMENT_STATUS = {
    draft: { label: '组批中', tone: '' },
    declared: { label: '已出收据', tone: 'amber' },
    shipped: { label: '转运发货', tone: 'blue' },
    arrived: { label: '到达澳洲', tone: 'orange' },
    received: { label: '已签收·待入库', tone: 'purple' },
    stocked: { label: '已入库', tone: 'green' },
    closed: { label: '已完成(历史)', tone: '' }
  };
  const SHIPMENT_FLOW = ['draft', 'declared', 'shipped', 'arrived', 'received', 'stocked'];
  const NEXT_STEP = {
    draft: { status: 'declared', label: '标记已出收据' },
    declared: { status: 'shipped', label: '标记转运发货' },
    shipped: { status: 'arrived', label: '标记到达澳洲' }
  };
  const PARCEL_STAGE = Object.assign({
    domestic: { label: '国内运输中', tone: 'blue' },
    at_forwarder: { label: '转运仓已签收', tone: 'amber' }
  }, SHIPMENT_STATUS);
  const ORDER_STAGE = {
    ordered: { label: '待出明细', tone: '' },
    awaiting_payment: { label: '待付款', tone: 'orange' },
    awaiting_dispatch: { label: '待供货商发货', tone: 'amber' },
    dispatched: { label: '已发货', tone: 'blue' },
    complete: { label: '已入库', tone: 'green' },
    cancelled: { label: '已取消', tone: 'red' }
  };
  const DONE = new Set(['stocked', 'closed']);

  const ERROR_TEXT = [
    [/Supplier name is required/i, '请填写供货商名称'],
    [/Forwarder name is required/i, '请填写转运公司名称'],
    [/Order line (\d+) needs a description/i, '产品明细第 $1 行没有品名'],
    [/Order line (\d+) needs a quantity/i, '产品明细第 $1 行数量要大于 0'],
    [/already been received cannot be removed/i, '这一行已经入库，不能删除'],
    [/parcels first/i, '这张采购单还有包裹，请先删除包裹，或者勾选「已取消」'],
    [/already been counted into stock and cannot (be deleted|change batch)/i, '这个包裹已经点数入库，不能删除或换批次'],
    [/batch has already been counted/i, '这个批次已经有入库记录，不能删除'],
    [/counted cannot (be removed|move)/i, '已经点数入库的包裹不能移出批次'],
    [/shipped or arrived before counting/i, '请先把批次标记为「转运发货」或「到达澳洲」再点数入库'],
    [/Add at least one counted line/i, '请至少填一行点数'],
    [/Choose a SKU on line (\d+)/i, '第 $1 行还没选 SKU'],
    [/Choose a store on line (\d+)/i, '第 $1 行还没选门店'],
    [/Line (\d+) must have a counted quantity/i, '第 $1 行数量为 0'],
    [/Retail price is required/i, '请填写零售价'],
    [/Choose a valid POS category/i, '请选择 POS 分类'],
    [/SKU (\S+) is already used/i, 'SKU $1 已经存在'],
    [/SKU must be/i, 'SKU 只能用字母、数字和 - _ . /，2-80 位'],
    [/Admin session/i, '登录已过期，请重新登录'],
    [/Failed to fetch|NetworkError/i, '网络连接失败，请检查网络后重试']
  ];

  const state = {
    data: null,
    tab: 'board',
    search: '',
    orderFilter: 'open',
    parcelFilter: 'open',
    parcelForwarder: '',
    shipmentFilter: 'open',
    showStockedReceiving: false,
    selectedParcels: new Set(),
    receiving: null,
    drawer: null,
    modal: null
  };
  let index = null;
  let lineSeq = 0;
  let searchTimer = null;
  let skuTimer = null;
  let toastTimer = null;

  const els = {
    view: document.getElementById('view'),
    tabs: document.getElementById('tabs'),
    status: document.getElementById('statusBar'),
    search: document.getElementById('globalSearch'),
    drawer: document.getElementById('drawer'),
    drawerTitle: document.getElementById('drawerTitle'),
    drawerSubtitle: document.getElementById('drawerSubtitle'),
    drawerBody: document.getElementById('drawerBody'),
    drawerFoot: document.getElementById('drawerFoot'),
    modal: document.getElementById('modal'),
    toast: document.getElementById('toast')
  };

  // ---------- helpers ----------

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, char => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[char]));
  }

  function pad(value) { return String(value).padStart(2, '0'); }

  function todayISO() {
    const now = new Date();
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  }

  function nowLocalInput() {
    const now = new Date();
    return `${todayISO()}T${pad(now.getHours())}:${pad(now.getMinutes())}`;
  }

  function fmtDate(value) {
    if (!value) return '';
    const text = String(value);
    const date = text.length > 10 ? new Date(text) : new Date(`${text}T00:00:00`);
    if (Number.isNaN(date.getTime())) return text;
    const sameYear = date.getFullYear() === new Date().getFullYear();
    return `${sameYear ? '' : `${String(date.getFullYear()).slice(2)}/`}${pad(date.getMonth() + 1)}/${pad(date.getDate())}`;
  }

  function fmtDateTime(value) {
    if (!value) return '';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return String(value);
    return `${fmtDate(value)} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  function money(amount, currency) {
    if (amount == null || amount === '') return '';
    const symbol = currency === 'AUD' ? 'A$' : currency === 'USD' ? 'US$' : '¥';
    const number = Number(amount);
    if (!Number.isFinite(number)) return '';
    return symbol + number.toLocaleString('en-AU', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  }

  function num(value) {
    if (value == null || String(value).trim() === '') return null;
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  }

  function uuid() {
    if (window.crypto && typeof window.crypto.randomUUID === 'function') return window.crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, char => {
      const random = Math.random() * 16 | 0;
      return (char === 'x' ? random : (random & 0x3 | 0x8)).toString(16);
    });
  }

  function chip(text, tone, icon) {
    if (!text) return '';
    return `<span class="pa-chip ${tone || ''}">${icon ? `<i class="bi ${icon}"></i>` : ''}${esc(text)}</span>`;
  }

  function readStorage(key, fallback) {
    try { return localStorage.getItem(key) || fallback; } catch (error) { return fallback; }
  }

  function writeStorage(key, value) {
    try { localStorage.setItem(key, value); } catch (error) { /* per-viewer convenience only */ }
  }

  function translateError(message) {
    const text = String(message || '请求失败');
    for (const [pattern, replacement] of ERROR_TEXT) {
      if (pattern.test(text)) return text.replace(new RegExp(`^.*?${pattern.source}.*$`, pattern.flags), replacement);
    }
    return text;
  }

  function toast(message, isError) {
    els.toast.textContent = message;
    els.toast.classList.toggle('error', Boolean(isError));
    els.toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { els.toast.hidden = true; }, isError ? 5200 : 2600);
  }

  function setStatus(message, isError) {
    els.status.hidden = !message;
    els.status.textContent = message || '';
    els.status.classList.toggle('error', Boolean(isError));
  }

  function copyText(text) {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    let copied = false;
    try { copied = document.execCommand('copy'); } catch (error) { copied = false; }
    area.remove();
    if (!copied && navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
    return true;
  }

  // ---------- data ----------

  async function api(action, payload, options) {
    const token = window.Techm8StaffAuth.getToken();
    const response = await fetch(ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE.anonKey || '',
        'x-admin-session': token || ''
      },
      body: JSON.stringify({
        action,
        payload: payload || {},
        actor_name: options && options.actorName ? options.actorName : ''
      })
    });
    const result = await response.json().catch(() => ({}));
    if (response.status === 401) {
      toast('登录已过期，请重新登录', true);
      setTimeout(() => window.Techm8StaffAuth.logout(), 1200);
      throw new Error('登录已过期，请重新登录');
    }
    if (!response.ok || !result.ok) throw new Error(translateError(result.message || `请求失败 (${response.status})`));
    if (result.snapshot) applySnapshot(result.snapshot);
    return result;
  }

  async function load() {
    try {
      setStatus('');
      await api('snapshot');
    } catch (error) {
      setStatus(translateError(error.message), true);
      if (!state.data) els.view.innerHTML = '<div class="pa-empty">数据加载失败，请点右上角刷新。</div>';
    }
  }

  function group(list, key) {
    const map = new Map();
    list.forEach(item => {
      const value = item[key] == null ? null : Number(item[key]);
      if (value == null) return;
      if (!map.has(value)) map.set(value, []);
      map.get(value).push(item);
    });
    return map;
  }

  function applySnapshot(snapshot) {
    const data = {
      suppliers: snapshot.suppliers || [],
      forwarders: snapshot.forwarders || [],
      stores: snapshot.stores || [],
      pos_categories: snapshot.pos_categories || [],
      orders: snapshot.orders || [],
      parcels: snapshot.parcels || [],
      shipments: snapshot.shipments || [],
      receipt_lines: snapshot.receipt_lines || []
    };
    const byId = list => new Map(list.map(item => [Number(item.id), item]));
    state.data = data;
    index = {
      suppliers: byId(data.suppliers),
      forwarders: byId(data.forwarders),
      stores: byId(data.stores),
      orders: byId(data.orders),
      parcels: byId(data.parcels),
      shipments: byId(data.shipments),
      parcelsByShipment: group(data.parcels, 'shipment_id'),
      parcelsByOrder: group(data.parcels, 'purchase_order_id'),
      receiptsByShipment: group(data.receipt_lines, 'shipment_id'),
      defaultStore: data.stores.find(store => store.slug === DEFAULT_STORE_SLUG) || data.stores[0] || null
    };
    state.selectedParcels.forEach(id => { if (!index.parcels.has(id)) state.selectedParcels.delete(id); });
    if (state.receiving && !index.shipments.has(state.receiving.shipmentId)) state.receiving = null;
    render();
  }

  function supplierName(id) {
    const supplier = id && index.suppliers.get(Number(id));
    return supplier ? supplier.name : '';
  }

  function forwarderName(id) {
    const forwarder = id && index.forwarders.get(Number(id));
    return forwarder ? forwarder.name : '';
  }

  function storeName(id) {
    const store = id && index.stores.get(Number(id));
    return store ? store.name : '';
  }

  function storeNameBySlug(slug) {
    const store = state.data.stores.find(item => item.slug === slug);
    return store ? store.name : slug;
  }

  function parcelSupplierId(parcel) {
    if (parcel.supplier_id) return parcel.supplier_id;
    const order = parcel.purchase_order_id && index.orders.get(Number(parcel.purchase_order_id));
    return order ? order.supplier_id : null;
  }

  function parcelStage(parcel) {
    const shipment = parcel.shipment_id && index.shipments.get(Number(parcel.shipment_id));
    if (shipment) return shipment.status;
    return parcel.forwarder_received_at ? 'at_forwarder' : 'domestic';
  }

  function orderStage(order) {
    if (order.cancelled_at) return 'cancelled';
    const parcels = index.parcelsByOrder.get(Number(order.id)) || [];
    if (parcels.length) return parcels.every(parcel => DONE.has(parcelStage(parcel))) ? 'complete' : 'dispatched';
    if (order.paid_at) return 'awaiting_dispatch';
    if (order.invoice_received_at || (order.items || []).length) return 'awaiting_payment';
    return 'ordered';
  }

  function orderTotal(order) {
    if (order.goods_amount != null) return Number(order.goods_amount) + Number(order.domestic_shipping_amount || 0);
    const items = (order.items || []).reduce((sum, item) => sum + (Number(item.unit_cost) || 0) * (Number(item.quantity) || 0), 0);
    return items ? items + Number(order.domestic_shipping_amount || 0) : null;
  }

  function itemsSummary(order) {
    return (order.items || []).map(item => `${item.description} ×${item.quantity}`).join('，');
  }

  function shipmentParcels(shipment) {
    return index.parcelsByShipment.get(Number(shipment.id)) || [];
  }

  function shipmentTitle(shipment) {
    const parts = [forwarderName(shipment.forwarder_id) || '未选转运', shipment.channel].filter(Boolean);
    return parts.join(' · ');
  }

  // ---------- payload builders (the API replaces whole records) ----------

  function orderPayload(order, overrides) {
    return Object.assign({
      id: order.id || null,
      supplier_id: order.supplier_id || null,
      supplier_order_ref: order.supplier_order_ref || '',
      order_date: order.order_date || todayISO(),
      currency: order.currency || 'CNY',
      goods_amount: order.goods_amount,
      domestic_shipping_amount: order.domestic_shipping_amount,
      invoice_received_at: order.invoice_received_at || '',
      paid_amount: order.paid_amount,
      paid_at: order.paid_at || '',
      payment_method: order.payment_method || '',
      payment_ref: order.payment_ref || '',
      cancelled: Boolean(order.cancelled_at),
      notes: order.notes || '',
      items: (order.items || []).map(item => ({
        id: item.id || null,
        description: item.description,
        quantity: item.quantity,
        unit_cost: item.unit_cost,
        product_id: item.product_id || null,
        declared_name: item.declared_name || '',
        notes: item.notes || ''
      }))
    }, overrides || {});
  }

  function parcelPayload(parcel, overrides) {
    return Object.assign({
      id: parcel.id || null,
      purchase_order_id: parcel.purchase_order_id || null,
      supplier_id: parcel.supplier_id || null,
      contents: parcel.contents || '',
      courier: parcel.courier || '',
      tracking_no: parcel.tracking_no || '',
      carton_count: parcel.carton_count == null ? 1 : parcel.carton_count,
      shipped_at: parcel.shipped_at || '',
      forwarder_id: parcel.forwarder_id || null,
      channel: parcel.channel || '',
      forwarder_received_at: parcel.forwarder_received_at || '',
      forwarder_ref: parcel.forwarder_ref || '',
      shipment_id: parcel.shipment_id || null,
      declared_value: parcel.declared_value,
      has_battery: Boolean(parcel.has_battery),
      has_magnet: Boolean(parcel.has_magnet),
      weight_kg: parcel.weight_kg,
      notes: parcel.notes || ''
    }, overrides || {});
  }

  function shipmentPayload(shipment, overrides) {
    return Object.assign({
      id: shipment.id || null,
      forwarder_id: shipment.forwarder_id || null,
      channel: shipment.channel || '',
      tracking_numbers: shipment.tracking_numbers || [],
      status: shipment.status || 'draft',
      declared_at: shipment.declared_at || '',
      shipped_at: shipment.shipped_at || '',
      eta: shipment.eta || '',
      arrived_at: shipment.arrived_at || '',
      received_at: shipment.received_at || '',
      received_by: shipment.received_by || '',
      received_store_id: shipment.received_store_id || null,
      received_cartons: shipment.received_cartons,
      freight_amount: shipment.freight_amount,
      freight_currency: shipment.freight_currency || 'CNY',
      weight_kg: shipment.weight_kg,
      notes: shipment.notes || ''
    }, overrides || {});
  }

  // ---------- small renderers ----------

  function trackButton(number, kind, forwarderId) {
    if (!number) return '';
    return `<button class="pa-track" type="button" data-action="track" data-no="${esc(number)}" data-kind="${kind}" data-forwarder="${esc(forwarderId || '')}" title="复制单号并打开查询网站"><i class="bi bi-box-arrow-up-right"></i>${esc(number)}</button>`;
  }

  function trackingList(shipment) {
    return (shipment.tracking_numbers || []).map(number => trackButton(number, 'intl', shipment.forwarder_id)).join(' ');
  }

  function stageChip(map, key) {
    const stage = map[key] || { label: key, tone: '' };
    return chip(stage.label, stage.tone);
  }

  function supplierOptions(selected) {
    const options = state.data.suppliers
      .filter(supplier => supplier.is_active !== false || Number(supplier.id) === Number(selected))
      .map(supplier => `<option value="${supplier.id}" ${Number(selected) === Number(supplier.id) ? 'selected' : ''}>${esc(supplier.name)}</option>`);
    return `<option value="">— 未指定 —</option>${options.join('')}`;
  }

  function forwarderOptions(selected) {
    const options = state.data.forwarders
      .filter(forwarder => forwarder.is_active !== false || Number(forwarder.id) === Number(selected))
      .map(forwarder => `<option value="${forwarder.id}" ${Number(selected) === Number(forwarder.id) ? 'selected' : ''}>${esc(forwarder.name)}</option>`);
    return `<option value="">— 未指定 —</option>${options.join('')}`;
  }

  function storeOptions(selected) {
    return state.data.stores.map(store => `<option value="${store.id}" ${Number(selected) === Number(store.id) ? 'selected' : ''}>${esc(store.name)}</option>`).join('');
  }

  function listOptions(values, selected) {
    return values.map(value => `<option value="${esc(value)}" ${value === selected ? 'selected' : ''}>${esc(value)}</option>`).join('');
  }

  function channelDatalist(id, forwarderId) {
    const forwarder = forwarderId && index.forwarders.get(Number(forwarderId));
    const channels = new Set((forwarder ? forwarder.channels : []).concat(['海运普货', '海运纯电', '空运普货', '空运电池', '快递']));
    return `<datalist id="${id}">${Array.from(channels).map(value => `<option value="${esc(value)}"></option>`).join('')}</datalist>`;
  }

  function field(label, control, wide) {
    return `<label class="pa-field ${wide ? 'full' : ''}"><span>${esc(label)}</span>${control}</label>`;
  }

  function input(name, value, attrs) {
    return `<input name="${name}" value="${esc(value == null ? '' : value)}" ${attrs || ''}>`;
  }

  // ---------- main render ----------

  function render() {
    if (!state.data) return;
    renderTabCounts();
    els.tabs.querySelectorAll('[data-tab]').forEach(button => {
      button.classList.toggle('active', !state.search && button.dataset.tab === state.tab);
    });
    if (state.search.trim()) {
      els.view.innerHTML = renderSearch(state.search.trim());
      return;
    }
    const renderers = {
      board: renderBoard,
      orders: renderOrders,
      parcels: renderParcels,
      shipments: renderShipments,
      receiving: renderReceiving,
      settings: renderSettings
    };
    els.view.innerHTML = (renderers[state.tab] || renderBoard)();
  }

  function renderTabCounts() {
    const counts = {
      orders: state.data.orders.filter(order => ['awaiting_payment', 'awaiting_dispatch', 'ordered'].includes(orderStage(order))).length,
      parcels: state.data.parcels.filter(parcel => !parcel.shipment_id).length,
      shipments: state.data.shipments.filter(shipment => !DONE.has(shipment.status)).length,
      receiving: state.data.shipments.filter(shipment => ['arrived', 'received'].includes(shipment.status)).length
    };
    els.tabs.querySelectorAll('[data-count]').forEach(badge => {
      const value = counts[badge.dataset.count] || 0;
      badge.hidden = value === 0;
      badge.textContent = value;
    });
  }

  function orderCard(order) {
    const total = orderTotal(order);
    return `<div class="pa-card" role="button" tabindex="0" data-action="open-order" data-id="${order.id}">
      <div class="pa-card-title">${esc(itemsSummary(order) || order.notes || '(还没有明细)')}</div>
      <div class="pa-card-meta"><span>${esc(order.po_number)}</span><span>${esc(supplierName(order.supplier_id) || '未指定供货商')}</span><span>${fmtDate(order.order_date)}</span></div>
      <div class="pa-card-foot">${stageChip(ORDER_STAGE, orderStage(order))}${total != null ? chip(money(total, order.currency)) : ''}${order.paid_at ? chip('已付', 'green', 'bi-check2') : ''}</div>
    </div>`;
  }

  function parcelCard(parcel) {
    const stage = parcelStage(parcel);
    const supplier = supplierName(parcelSupplierId(parcel));
    return `<div class="pa-card" role="button" tabindex="0" data-action="open-parcel" data-id="${parcel.id}">
      <div class="pa-card-title">${esc(parcel.contents || '(未填内容)')}</div>
      <div class="pa-card-meta">${supplier ? `<span>${esc(supplier)}</span>` : ''}${parcel.courier ? `<span>${esc(parcel.courier)}</span>` : ''}${parcel.shipped_at ? `<span>发 ${fmtDate(parcel.shipped_at)}</span>` : ''}${parcel.carton_count > 1 ? `<span>${parcel.carton_count} 箱</span>` : ''}</div>
      <div class="pa-card-foot">
        ${trackButton(parcel.tracking_no, 'cn')}
        ${parcel.forwarder_id ? chip(forwarderName(parcel.forwarder_id), '', 'bi-building') : ''}
        ${parcel.forwarder_ref ? chip(`入仓 ${parcel.forwarder_ref.split(/\s+/)[0]}`, 'amber') : ''}
        ${stage === 'domestic' ? '<button class="pa-btn small" type="button" data-action="parcel-at-forwarder" data-id="' + parcel.id + '">转运已签收</button>' : ''}
      </div>
    </div>`;
  }

  function shipmentCard(shipment, extraClass) {
    const parcels = shipmentParcels(shipment);
    const preview = parcels.slice(0, 3).map(parcel => parcel.contents).filter(Boolean).join(' / ');
    const next = NEXT_STEP[shipment.status];
    let action = '';
    if (next) action = `<button class="pa-btn small" type="button" data-action="advance-shipment" data-id="${shipment.id}">${esc(next.label)}</button>`;
    if (shipment.status === 'arrived' || shipment.status === 'received') {
      action = `<button class="pa-btn small primary" type="button" data-action="go-receive" data-id="${shipment.id}">${shipment.status === 'arrived' ? '签收点数' : '点数入库'}</button>`;
    }
    const dateText = shipment.status === 'shipped' && shipment.eta ? `预计 ${fmtDate(shipment.eta)}`
      : shipment.arrived_at ? `到 ${fmtDate(shipment.arrived_at)}`
        : shipment.shipped_at ? `发 ${fmtDate(shipment.shipped_at)}`
          : shipment.declared_at ? `收据 ${fmtDate(shipment.declared_at)}` : '';
    return `<div class="pa-card ${extraClass || ''}" role="button" tabindex="0" data-action="open-shipment" data-id="${shipment.id}">
      <div class="pa-card-title">${esc(shipmentTitle(shipment))}</div>
      <div class="pa-card-meta"><span>${esc(shipment.shipment_number)}</span><span>${parcels.length} 个包裹</span>${dateText ? `<span>${dateText}</span>` : ''}</div>
      ${preview ? `<div class="pa-small pa-muted" style="margin-top:4px">${esc(preview)}${parcels.length > 3 ? ' …' : ''}</div>` : ''}
      <div class="pa-card-foot">${trackingList(shipment)} ${action}</div>
    </div>`;
  }

  function column(title, hint, cards) {
    return `<section class="pa-column">
      <div class="pa-column-head"><div>${esc(title)}<small>${esc(hint)}</small></div><span class="num">${cards.length}</span></div>
      <div class="pa-column-body">${cards.length ? cards.join('') : '<div class="pa-column-empty">暂无</div>'}</div>
    </section>`;
  }

  function renderBoard() {
    const data = state.data;
    const openOrders = data.orders.filter(order => !order.cancelled_at);
    const looseParcels = data.parcels.filter(parcel => !parcel.shipment_id);
    const shipmentsIn = status => data.shipments.filter(shipment => shipment.status === status);
    const doneCount = data.shipments.filter(shipment => DONE.has(shipment.status)).length;
    return `<div class="pa-board">
      ${column('下单 · 待付款', '等供货商出明细 / 付款', openOrders.filter(order => ['ordered', 'awaiting_payment'].includes(orderStage(order))).map(orderCard))}
      ${column('已付款 · 待发货', '等供货商发国内快递', openOrders.filter(order => orderStage(order) === 'awaiting_dispatch').map(orderCard))}
      ${column('国内运输中', '供货商已发货', looseParcels.filter(parcel => !parcel.forwarder_received_at).map(parcelCard))}
      ${column('转运仓 · 待出收据', '勾选包裹组成批次，出明细给转运', shipmentsIn('draft').map(shipment => shipmentCard(shipment)).concat(looseParcels.filter(parcel => parcel.forwarder_received_at).map(parcelCard)))}
      ${column('已出收据', '等转运发货', shipmentsIn('declared').map(shipment => shipmentCard(shipment)))}
      ${column('转运发货', '国际运输中', shipmentsIn('shipped').map(shipment => shipmentCard(shipment)))}
      ${column('到达澳洲', '待签收', shipmentsIn('arrived').map(shipment => shipmentCard(shipment)))}
      ${column('已签收 · 待入库', '点数后入库', shipmentsIn('received').map(shipment => shipmentCard(shipment)))}
    </div>
    <p class="pa-small pa-muted">已完成 ${doneCount} 个批次 · <button class="pa-btn small ghost" type="button" data-action="show-done">查看</button></p>`;
  }

  function filterBar(name, current, options) {
    return `<div class="pa-filters">${options.map(([value, label]) => `<button class="pa-filter ${current === value ? 'active' : ''}" type="button" data-action="filter" data-filter="${name}" data-value="${value}">${esc(label)}</button>`).join('')}</div>`;
  }

  function renderOrders() {
    const filters = {
      open: order => !['cancelled', 'complete'].includes(orderStage(order)),
      payment: order => ['ordered', 'awaiting_payment'].includes(orderStage(order)),
      dispatch: order => orderStage(order) === 'awaiting_dispatch',
      dispatched: order => orderStage(order) === 'dispatched',
      complete: order => orderStage(order) === 'complete',
      cancelled: order => orderStage(order) === 'cancelled',
      all: () => true
    };
    const rows = state.data.orders.filter(filters[state.orderFilter] || filters.open);
    return `<section class="pa-panel">
      <div class="pa-panel-head">
        ${filterBar('orderFilter', state.orderFilter, [['open', '进行中'], ['payment', '待付款'], ['dispatch', '待发货'], ['dispatched', '已发货'], ['complete', '已入库'], ['cancelled', '已取消'], ['all', '全部']])}
        <button class="pa-btn small primary" type="button" data-action="new-order"><i class="bi bi-plus-lg"></i> 新采购单</button>
      </div>
      ${rows.length ? `<div class="pa-table-wrap"><table class="pa-table">
        <thead><tr><th>采购单</th><th>日期</th><th>供货商</th><th>明细</th><th class="num">金额</th><th>付款</th><th>包裹</th><th>状态</th></tr></thead>
        <tbody>${rows.map(order => {
          const parcels = index.parcelsByOrder.get(Number(order.id)) || [];
          const total = orderTotal(order);
          return `<tr data-action="open-order" data-id="${order.id}">
            <td><strong>${esc(order.po_number)}</strong>${order.supplier_order_ref ? `<div class="pa-small pa-muted">${esc(order.supplier_order_ref)}</div>` : ''}</td>
            <td>${fmtDate(order.order_date)}</td>
            <td>${esc(supplierName(order.supplier_id) || '—')}</td>
            <td class="wrap">${esc(itemsSummary(order) || order.notes || '')}</td>
            <td class="num">${total != null ? money(total, order.currency) : ''}</td>
            <td>${order.paid_at ? chip(`已付 ${fmtDate(order.paid_at)}`, 'green') : chip('未付', 'orange')}</td>
            <td>${parcels.length ? `${parcels.length} 个` : '—'}</td>
            <td>${stageChip(ORDER_STAGE, orderStage(order))}</td>
          </tr>`;
        }).join('')}</tbody></table></div>` : '<div class="pa-empty">没有符合条件的采购单</div>'}
    </section>`;
  }

  function parcelRow(parcel, selectable) {
    const shipment = parcel.shipment_id && index.shipments.get(Number(parcel.shipment_id));
    const selected = state.selectedParcels.has(Number(parcel.id));
    return `<tr data-action="open-parcel" data-id="${parcel.id}" class="${selected ? 'selected' : ''}">
      ${selectable ? `<td><input type="checkbox" data-action="toggle-parcel" data-id="${parcel.id}" ${selected ? 'checked' : ''} ${shipment && DONE.has(shipment.status) ? 'disabled' : ''} aria-label="选择包裹"></td>` : ''}
      <td class="wrap"><strong>${esc(parcel.contents || '(未填内容)')}</strong>${parcel.notes ? `<div class="pa-small pa-muted">${esc(parcel.notes)}</div>` : ''}</td>
      <td>${esc(supplierName(parcelSupplierId(parcel)) || '—')}</td>
      <td>${parcel.courier ? `<div class="pa-small">${esc(parcel.courier)}</div>` : ''}${trackButton(parcel.tracking_no, 'cn')}</td>
      <td>${esc(forwarderName(parcel.forwarder_id) || '—')}${parcel.channel ? `<div class="pa-small pa-muted">${esc(parcel.channel)}</div>` : ''}</td>
      <td class="pa-small">${esc(parcel.forwarder_ref || '')}</td>
      <td>${shipment ? `<div class="pa-small"><strong>${esc(shipment.shipment_number)}</strong></div>${trackingList(shipment)}` : '—'}</td>
      <td>${stageChip(PARCEL_STAGE, parcelStage(parcel))}</td>
      <td class="pa-small">${fmtDate(parcel.shipped_at || parcel.created_at)}</td>
    </tr>`;
  }

  function parcelTable(rows, selectable) {
    if (!rows.length) return '<div class="pa-empty">没有包裹</div>';
    return `<div class="pa-table-wrap"><table class="pa-table">
      <thead><tr>${selectable ? '<th></th>' : ''}<th>内容</th><th>供货商</th><th>国内快递</th><th>转运 / 渠道</th><th>入仓号</th><th>批次 / 国际单号</th><th>状态</th><th>日期</th></tr></thead>
      <tbody>${rows.map(parcel => parcelRow(parcel, selectable)).join('')}</tbody>
    </table></div>`;
  }

  function renderParcels() {
    const filters = {
      open: parcel => !DONE.has(parcelStage(parcel)),
      domestic: parcel => parcelStage(parcel) === 'domestic',
      at_forwarder: parcel => parcelStage(parcel) === 'at_forwarder',
      unbatched: parcel => !parcel.shipment_id,
      in_batch: parcel => parcel.shipment_id && !DONE.has(parcelStage(parcel)),
      done: parcel => DONE.has(parcelStage(parcel)),
      all: () => true
    };
    let rows = state.data.parcels.filter(filters[state.parcelFilter] || filters.open);
    if (state.parcelForwarder) rows = rows.filter(parcel => String(parcel.forwarder_id || '') === state.parcelForwarder);
    const selected = Array.from(state.selectedParcels);
    const openBatches = state.data.shipments.filter(shipment => ['draft', 'declared'].includes(shipment.status));
    return `<section class="pa-panel">
      <div class="pa-panel-head">
        ${filterBar('parcelFilter', state.parcelFilter, [['open', '未完成'], ['domestic', '国内运输中'], ['at_forwarder', '转运仓已签收'], ['unbatched', '未组批'], ['in_batch', '已组批'], ['done', '已完成'], ['all', '全部']])}
        <div class="pa-filters">
          <select class="pa-select-inline" data-change="parcelForwarder" aria-label="按转运筛选"><option value="">全部转运</option>${state.data.forwarders.map(forwarder => `<option value="${forwarder.id}" ${state.parcelForwarder === String(forwarder.id) ? 'selected' : ''}>${esc(forwarder.name)}</option>`).join('')}</select>
          <button class="pa-btn small primary" type="button" data-action="new-parcel"><i class="bi bi-plus-lg"></i> 登记包裹</button>
        </div>
      </div>
      ${parcelTable(rows, true)}
    </section>
    ${selected.length ? `<div class="pa-bulkbar">
      <span>已选 ${selected.length} 个包裹</span>
      <div class="pa-row-actions">
        <button class="pa-btn small primary" type="button" data-action="batch-new">新建转运批次（出收据）</button>
        ${openBatches.length ? `<select class="pa-select-inline" data-change="batchExisting" aria-label="加入现有批次"><option value="">加入现有批次…</option>${openBatches.map(shipment => `<option value="${shipment.id}">${esc(shipment.shipment_number)} · ${esc(shipmentTitle(shipment))} · ${esc(SHIPMENT_STATUS[shipment.status].label)}</option>`).join('')}</select>` : ''}
        <button class="pa-btn small" type="button" data-action="clear-selection">清除</button>
      </div>
    </div>` : ''}`;
  }

  function shipmentRow(shipment) {
    const parcels = shipmentParcels(shipment);
    return `<tr data-action="open-shipment" data-id="${shipment.id}">
      <td><strong>${esc(shipment.shipment_number)}</strong></td>
      <td>${esc(forwarderName(shipment.forwarder_id) || '—')}${shipment.channel ? `<div class="pa-small pa-muted">${esc(shipment.channel)}</div>` : ''}</td>
      <td>${trackingList(shipment) || '<span class="pa-muted">—</span>'}</td>
      <td class="wrap pa-small">${parcels.length} 个：${esc(parcels.map(parcel => parcel.contents).filter(Boolean).slice(0, 4).join(' / '))}${parcels.length > 4 ? ' …' : ''}</td>
      <td>${stageChip(SHIPMENT_STATUS, shipment.status)}</td>
      <td class="pa-small">${[
        shipment.declared_at ? `收据 ${fmtDate(shipment.declared_at)}` : '',
        shipment.shipped_at ? `发货 ${fmtDate(shipment.shipped_at)}` : '',
        shipment.eta && !shipment.arrived_at ? `预计 ${fmtDate(shipment.eta)}` : '',
        shipment.arrived_at ? `到达 ${fmtDate(shipment.arrived_at)}` : ''
      ].filter(Boolean).join('<br>')}</td>
      <td class="num">${shipment.freight_amount != null ? money(shipment.freight_amount, shipment.freight_currency) : ''}</td>
    </tr>`;
  }

  function renderShipments() {
    const filters = {
      open: shipment => !DONE.has(shipment.status),
      declared: shipment => ['draft', 'declared'].includes(shipment.status),
      shipped: shipment => shipment.status === 'shipped',
      arrived: shipment => ['arrived', 'received'].includes(shipment.status),
      done: shipment => DONE.has(shipment.status),
      all: () => true
    };
    const rows = state.data.shipments.filter(filters[state.shipmentFilter] || filters.open);
    return `<section class="pa-panel">
      <div class="pa-panel-head">
        ${filterBar('shipmentFilter', state.shipmentFilter, [['open', '进行中'], ['declared', '已出收据'], ['shipped', '转运发货'], ['arrived', '到达 / 待入库'], ['done', '已完成'], ['all', '全部']])}
        <button class="pa-btn small primary" type="button" data-action="new-shipment"><i class="bi bi-plus-lg"></i> 新转运批次</button>
      </div>
      ${rows.length ? `<div class="pa-table-wrap"><table class="pa-table">
        <thead><tr><th>批次</th><th>转运 / 渠道</th><th>国际单号</th><th>包裹</th><th>状态</th><th>日期</th><th class="num">运费</th></tr></thead>
        <tbody>${rows.map(shipmentRow).join('')}</tbody>
      </table></div>` : '<div class="pa-empty">没有符合条件的批次</div>'}
    </section>`;
  }

  function renderSettings() {
    const suppliers = state.data.suppliers;
    const forwarders = state.data.forwarders;
    return `<section class="pa-panel">
      <div class="pa-panel-head"><h2>转运公司</h2><button class="pa-btn small primary" type="button" data-action="new-forwarder"><i class="bi bi-plus-lg"></i> 新增转运</button></div>
      <div class="pa-panel-body"><div class="pa-grid">${forwarders.map(forwarder => `
        <div class="pa-card" role="button" tabindex="0" data-action="open-forwarder" data-id="${forwarder.id}">
          <div class="pa-card-title">${esc(forwarder.name)} ${forwarder.is_active === false ? chip('停用', 'red') : ''}</div>
          <dl class="pa-kv">
            <dt>查询网站</dt><dd>${esc(forwarder.tracking_url || '—')}</dd>
            <dt>渠道</dt><dd>${esc((forwarder.channels || []).join('、') || '—')}</dd>
            <dt>单号前缀</dt><dd>${esc((forwarder.tracking_prefixes || []).join('、') || '—')}</dd>
            <dt>国内仓</dt><dd>${esc(forwarder.warehouse_address || '—')}</dd>
            ${forwarder.contact ? `<dt>联系</dt><dd>${esc(forwarder.contact)}</dd>` : ''}
          </dl>
        </div>`).join('')}</div></div>
    </section>
    <section class="pa-panel">
      <div class="pa-panel-head"><h2>供货商</h2><button class="pa-btn small primary" type="button" data-action="new-supplier"><i class="bi bi-plus-lg"></i> 新增供货商</button></div>
      ${suppliers.length ? `<div class="pa-table-wrap"><table class="pa-table">
        <thead><tr><th>名称</th><th>平台</th><th>联系人</th><th>微信</th><th>电话</th><th>网址</th><th>备注</th></tr></thead>
        <tbody>${suppliers.map(supplier => `<tr data-action="open-supplier" data-id="${supplier.id}">
          <td><strong>${esc(supplier.name)}</strong> ${supplier.is_active === false ? chip('停用', 'red') : ''}</td>
          <td>${esc(supplier.platform || '')}</td><td>${esc(supplier.contact_name || '')}</td><td>${esc(supplier.wechat || '')}</td>
          <td>${esc(supplier.phone || '')}</td><td class="pa-small">${esc(supplier.website_url || '')}</td><td class="wrap pa-small">${esc(supplier.notes || '')}</td>
        </tr>`).join('')}</tbody></table></div>` : '<div class="pa-empty">还没有供货商</div>'}
    </section>`;
  }

  function renderSearch(query) {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    const matches = text => words.every(word => text.toLowerCase().includes(word));
    const parcels = state.data.parcels.filter(parcel => {
      const order = parcel.purchase_order_id && index.orders.get(Number(parcel.purchase_order_id));
      const shipment = parcel.shipment_id && index.shipments.get(Number(parcel.shipment_id));
      return matches([parcel.contents, parcel.tracking_no, parcel.courier, parcel.forwarder_ref, parcel.notes,
        supplierName(parcelSupplierId(parcel)), order && order.po_number,
        shipment && shipment.shipment_number, shipment && (shipment.tracking_numbers || []).join(' ')].join(' ').replace(/\s+/g, ' '));
    });
    const shipments = state.data.shipments.filter(shipment => matches([shipment.shipment_number,
      (shipment.tracking_numbers || []).join(' '), shipment.notes, shipment.channel, forwarderName(shipment.forwarder_id)].join(' ')));
    const orders = state.data.orders.filter(order => matches([order.po_number, order.supplier_order_ref, order.notes,
      supplierName(order.supplier_id), itemsSummary(order)].join(' ')));
    const total = parcels.length + shipments.length + orders.length;
    return `<p class="pa-muted">搜索「${esc(query)}」找到 ${total} 条 · <button class="pa-btn small ghost" type="button" data-action="clear-search">清除搜索</button></p>
      ${shipments.length ? `<section class="pa-panel"><div class="pa-panel-head"><h2>转运批次 (${shipments.length})</h2></div><div class="pa-table-wrap"><table class="pa-table"><thead><tr><th>批次</th><th>转运 / 渠道</th><th>国际单号</th><th>包裹</th><th>状态</th><th>日期</th><th class="num">运费</th></tr></thead><tbody>${shipments.map(shipmentRow).join('')}</tbody></table></div></section>` : ''}
      ${parcels.length ? `<section class="pa-panel"><div class="pa-panel-head"><h2>国内包裹 (${parcels.length})</h2></div>${parcelTable(parcels, false)}</section>` : ''}
      ${orders.length ? `<section class="pa-panel"><div class="pa-panel-head"><h2>采购单 (${orders.length})</h2></div><div class="pa-panel-body"><div class="pa-grid">${orders.map(orderCard).join('')}</div></div></section>` : ''}
      ${total ? '' : '<div class="pa-empty">没有找到</div>'}`;
  }

  // ---------- receiving ----------

  function receivingShipments() {
    return state.data.shipments
      .filter(shipment => ['shipped', 'arrived', 'received'].includes(shipment.status)
        || (state.showStockedReceiving && shipment.status === 'stocked'))
      .sort((a, b) => {
        const rank = { arrived: 0, received: 1, shipped: 2, stocked: 3 };
        return (rank[a.status] - rank[b.status]) || (Number(b.id) - Number(a.id));
      });
  }

  function newLine(block, extra) {
    lineSeq += 1;
    return Object.assign({
      key: `l${lineSeq}`,
      block: block.key,
      parcel_id: block.parcels[0].id,
      item_id: null,
      product: null,
      q: '',
      results: null,
      quantity: '',
      damaged: '',
      store_id: state.receiving ? state.receiving.storeId : (index.defaultStore && index.defaultStore.id),
      cost: '',
      expected: null,
      description: '',
      unit_cost: null,
      currency: 'CNY'
    }, extra || {});
  }

  function initReceiving(shipmentId) {
    const shipment = index.shipments.get(Number(shipmentId));
    if (!shipment) { state.receiving = null; return; }
    const storeId = shipment.received_store_id || (index.defaultStore && index.defaultStore.id);
    state.receiving = {
      shipmentId: Number(shipmentId),
      receiptKey: uuid(),
      storeId,
      signer: readStorage(SIGNER_KEY, ''),
      rate: readStorage(RATE_KEY, '0.21'),
      updateCost: false,
      markStocked: false,
      blocks: [],
      lines: [],
      searchKey: null
    };
    const blocks = [];
    const byOrder = new Map();
    shipmentParcels(shipment).forEach(parcel => {
      const order = parcel.purchase_order_id && index.orders.get(Number(parcel.purchase_order_id));
      if (order && (order.items || []).length) {
        if (byOrder.has(order.id)) { byOrder.get(order.id).parcels.push(parcel); return; }
        const block = { key: `o${order.id}`, order, parcels: [parcel] };
        byOrder.set(order.id, block);
        blocks.push(block);
      } else {
        blocks.push({ key: `p${parcel.id}`, order: null, parcels: [parcel] });
      }
    });
    state.receiving.blocks = blocks;
    blocks.forEach(block => {
      if (block.order) {
        block.order.items.forEach(item => {
          const remaining = Math.max(0, Number(item.quantity) - Number(item.received_quantity || 0));
          if (!remaining) return;
          state.receiving.lines.push(newLine(block, {
            item_id: item.id,
            expected: remaining,
            description: item.description,
            unit_cost: item.unit_cost,
            currency: block.order.currency,
            product: item.product_id ? { id: item.product_id, sku: item.product_sku, name: item.product_name } : null
          }));
        });
      }
      if (!state.receiving.lines.some(line => line.block === block.key)) state.receiving.lines.push(newLine(block));
    });
  }

  function renderReceiving() {
    const list = receivingShipments();
    if (state.receiving && !list.some(shipment => Number(shipment.id) === state.receiving.shipmentId)) state.receiving = null;
    if (!state.receiving && list.length && ['arrived', 'received'].includes(list[0].status)) initReceiving(list[0].id);
    const current = state.receiving && index.shipments.get(state.receiving.shipmentId);
    return `<div class="pa-receive-layout">
      <aside>
        <div class="pa-section-title">选择批次 <label class="pa-check pa-small"><input type="checkbox" data-change="showStocked" ${state.showStockedReceiving ? 'checked' : ''}> 含已入库</label></div>
        <div class="pa-receive-list">${list.length ? list.map(shipment => shipmentCard(shipment, current && Number(current.id) === Number(shipment.id) ? 'active' : '').replace('data-action="open-shipment"', 'data-action="pick-receive"')).join('') : '<div class="pa-empty">没有在途或待入库的批次</div>'}</div>
      </aside>
      <section id="receivePanel">${current ? renderReceivePanel(current) : '<div class="pa-panel pa-empty">在左边选一个批次开始签收点数</div>'}</section>
    </div>`;
  }

  function renderReceivePanel(shipment) {
    const receiving = state.receiving;
    const signed = ['received', 'stocked'].includes(shipment.status);
    const history = index.receiptsByShipment.get(Number(shipment.id)) || [];
    return `<div class="pa-panel">
      <div class="pa-panel-head">
        <div><h2>${esc(shipment.shipment_number)} · ${esc(shipmentTitle(shipment))}</h2><div class="pa-card-foot">${stageChip(SHIPMENT_STATUS, shipment.status)} ${trackingList(shipment)}</div></div>
        <button class="pa-btn small" type="button" data-action="open-shipment" data-id="${shipment.id}">批次详情</button>
      </div>
      <div class="pa-panel-body">
        <div class="pa-section">
          <div class="pa-section-title">1 · 签收</div>
          ${signed ? `<p>已签收：${esc(shipment.received_by || '—')} · ${esc(storeName(shipment.received_store_id) || '—')} · ${fmtDateTime(shipment.received_at)}${shipment.received_cartons != null ? ` · ${shipment.received_cartons} 箱` : ''}</p>` : `
          <div class="pa-form pa-form-4">
            ${field('签收人', `<input id="signBy" value="${esc(receiving.signer)}" placeholder="名字">`)}
            ${field('签收门店', `<select id="signStore">${storeOptions(receiving.storeId)}</select>`)}
            ${field('箱数', '<input id="signCartons" type="number" min="0" inputmode="numeric">')}
            ${field('签收时间', `<input id="signAt" type="datetime-local" value="${nowLocalInput()}">`)}
          </div>
          <div style="margin-top:10px"><button class="pa-btn primary" type="button" data-action="sign-shipment">确认签收</button> <span class="pa-small pa-muted">也可以直接点数入库，系统会自动记为已签收</span></div>`}
        </div>
        <div class="pa-section">
          <div class="pa-section-title">2 · 点数 &amp; 入库
            <span class="pa-row-actions"><label class="pa-small">汇率 ¥→A$ <input class="pa-input" style="width:80px;height:30px;display:inline-block" type="number" step="0.001" min="0" data-receive-field="rate" value="${esc(receiving.rate)}"></label>
            <button class="pa-btn small" type="button" data-action="estimate-cost" title="按采购单价 × 汇率 + 平摊运费估算每件到岸成本">估算成本</button></span>
          </div>
          <div id="receiveBlocks">${receiving.blocks.length ? receiving.blocks.map(renderReceiveBlock).join('') : '<div class="pa-empty">这个批次还没有包裹，先在批次详情里添加包裹。</div>'}</div>
          <div class="pa-receive-foot" id="receiveFoot">${renderReceiveFoot()}</div>
        </div>
        ${history.length ? `<div class="pa-section"><div class="pa-section-title">已入库记录</div><div class="pa-table-wrap"><table class="pa-table">
          <thead><tr><th>时间</th><th>SKU</th><th>门店</th><th class="num">入库</th><th class="num">损坏</th><th class="num">库存 前→后</th><th class="num">成本</th><th>操作人</th></tr></thead>
          <tbody>${history.map(line => `<tr><td class="pa-small">${fmtDateTime(line.created_at)}</td><td><strong>${esc(line.product_sku)}</strong><div class="pa-small pa-muted">${esc(line.product_name)}</div></td><td>${esc(line.store_name)}</td><td class="num">${line.quantity}</td><td class="num">${line.damaged_quantity || ''}</td><td class="num pa-small">${line.quantity_before} → ${line.quantity_after}</td><td class="num">${line.unit_cost_aud != null ? money(line.unit_cost_aud, 'AUD') : ''}</td><td class="pa-small">${esc(line.created_by)}</td></tr>`).join('')}</tbody>
        </table></div></div>` : ''}
      </div>
    </div>`;
  }

  function renderReceiveBlock(block) {
    const receiving = state.receiving;
    const lines = receiving.lines.filter(line => line.block === block.key);
    const order = block.order;
    const items = order ? order.items : [];
    return `<div class="pa-parcel-block" data-block="${block.key}">
      <h3>${esc(order ? `${order.po_number} · ${supplierName(order.supplier_id) || '未指定供货商'}` : (block.parcels[0].contents || '(未填内容)'))}</h3>
      <div class="pa-card-meta">${block.parcels.map(parcel => `<span>${esc(parcel.courier || '')} ${esc(parcel.tracking_no || '')}${order ? ` · ${esc(parcel.contents || '')}` : ''}</span>`).join('')}</div>
      ${items.length ? `<div class="pa-expect">${items.map(item => `${esc(item.description)}：订 ${item.quantity}，已收 ${item.received_quantity || 0}`).join('；')}</div>` : ''}
      <div class="pa-line pa-line-head"><span>SKU</span><span>入库数量</span><span>损坏</span><span>入哪个店</span><span>单件成本 A$</span><span></span></div>
      ${lines.map(renderLine).join('')}
      <div style="margin-top:8px"><button class="pa-btn small" type="button" data-action="line-add" data-block="${block.key}"><i class="bi bi-plus-lg"></i> 加一行</button></div>
    </div>`;
  }

  function renderLine(line) {
    return `<div class="pa-line" data-line="${line.key}">
      <div class="pa-sku">${renderSkuCell(line)}</div>
      <input type="number" min="0" inputmode="numeric" data-line-field="quantity" value="${esc(line.quantity)}" placeholder="${line.expected != null ? `应到 ${line.expected}` : '数量'}">
      <input type="number" min="0" inputmode="numeric" data-line-field="damaged" value="${esc(line.damaged)}" placeholder="0">
      <select data-line-field="store_id">${storeOptions(line.store_id)}</select>
      <input type="number" min="0" step="0.01" data-line-field="cost" value="${esc(line.cost)}" placeholder="可不填">
      <button class="pa-btn small ghost danger" type="button" data-action="line-remove" title="删除这一行"><i class="bi bi-trash"></i></button>
    </div>`;
  }

  function renderSkuCell(line) {
    const top = line.product
      ? `<div class="pa-sku-chosen"><div class="grow"><strong>${esc(line.product.sku)}</strong>${esc(line.product.name || '')}</div><button class="pa-btn small ghost" type="button" data-action="line-clear-sku" title="换一个 SKU"><i class="bi bi-x-lg"></i></button></div>`
      : `<input class="pa-input" data-line-field="q" value="${esc(line.q)}" placeholder="搜 SKU / 名称 / 条码" autocomplete="off">`;
    const results = !line.product && line.results
      ? `<div class="pa-sku-results">${line.results.length ? line.results.map((product, position) => `<button class="pa-sku-option" type="button" data-action="line-pick-sku" data-index="${position}"><strong>${esc(product.sku)}</strong> ${esc(product.name)}${product.variant_name ? ` · ${esc(product.variant_name)}` : ''}<small>库存 ${esc(Object.entries(product.stock || {}).map(([slug, qty]) => `${storeNameBySlug(slug)} ${qty}`).join(' · ') || '无')}${product.is_pos_visible ? '' : ' · POS 隐藏'}</small></button>`).join('') : '<div class="pa-empty pa-small">没找到，点「新建 SKU」</div>'}</div>`
      : '';
    const hint = line.description ? `<div class="pa-small pa-muted">订单：${esc(line.description)}${line.expected != null ? ` · 应到 ${line.expected}` : ''}${line.expected != null ? ` <button class="pa-btn small ghost" type="button" data-action="line-fill-expected" style="height:22px;padding:0 6px">=应到</button>` : ''}</div>` : '';
    return `${top}${results}${hint}<div class="pa-row-actions" style="margin-top:2px">
      ${line.product ? '' : '<button class="pa-btn small ghost" type="button" data-action="line-new-sku" style="height:24px;padding:0 6px"><i class="bi bi-plus-circle"></i> 新建 SKU</button>'}
      <button class="pa-btn small ghost" type="button" data-action="line-split" style="height:24px;padding:0 6px"><i class="bi bi-diagram-2"></i> 拆到其他店</button>
    </div>`;
  }

  function renderReceiveFoot() {
    const receiving = state.receiving;
    const counted = receiving.lines.filter(line => (num(line.quantity) || 0) + (num(line.damaged) || 0) > 0);
    const byStore = new Map();
    counted.forEach(line => byStore.set(Number(line.store_id), (byStore.get(Number(line.store_id)) || 0) + (num(line.quantity) || 0)));
    const damaged = counted.reduce((sum, line) => sum + (num(line.damaged) || 0), 0);
    const summary = Array.from(byStore.entries()).map(([storeId, qty]) => `${storeName(storeId)} +${qty}`).join(' · ');
    return `<div>
        <strong>${counted.length} 行</strong> <span class="pa-muted">${esc(summary || '还没填数量')}${damaged ? ` · 损坏 ${damaged}` : ''}</span>
        <div class="pa-row-actions" style="margin-top:6px">
          <label class="pa-check pa-small"><input type="checkbox" data-receive-field="updateCost" ${receiving.updateCost ? 'checked' : ''}> 用填的成本更新 SKU 成本价</label>
          <label class="pa-check pa-small"><input type="checkbox" data-receive-field="markStocked" ${receiving.markStocked ? 'checked' : ''}> 这批已全部点完（标记已入库）</label>
        </div>
      </div>
      <button class="pa-btn primary" type="button" data-action="post-receipt"><i class="bi bi-box-arrow-in-down"></i> 确认入库</button>`;
  }

  function findLine(element) {
    const row = element.closest('[data-line]');
    return row && state.receiving ? state.receiving.lines.find(line => line.key === row.dataset.line) : null;
  }

  function rerenderLine(line) {
    const row = els.view.querySelector(`[data-line="${line.key}"] .pa-sku`);
    if (row) row.innerHTML = renderSkuCell(line);
  }

  function rerenderBlocks() {
    const container = document.getElementById('receiveBlocks');
    if (container) container.innerHTML = state.receiving.blocks.map(renderReceiveBlock).join('');
    rerenderFoot();
  }

  function rerenderFoot() {
    const foot = document.getElementById('receiveFoot');
    if (foot && state.receiving) foot.innerHTML = renderReceiveFoot();
  }

  async function searchSku(line) {
    const query = line.q.trim();
    if (query.length < 2) { line.results = null; rerenderLine(line); focusSku(line); return; }
    try {
      const result = await api('search_products', { q: query });
      if (line.q.trim() !== query) return;
      line.results = result.products || [];
      rerenderLine(line);
      focusSku(line);
    } catch (error) {
      toast(error.message, true);
    }
  }

  function focusSku(line) {
    const inputEl = els.view.querySelector(`[data-line="${line.key}"] [data-line-field="q"]`);
    if (inputEl) {
      inputEl.focus();
      inputEl.setSelectionRange(inputEl.value.length, inputEl.value.length);
    }
  }

  function estimateCosts() {
    const receiving = state.receiving;
    const shipment = index.shipments.get(receiving.shipmentId);
    const rate = num(receiving.rate) || 0;
    const counted = receiving.lines.filter(line => (num(line.quantity) || 0) + (num(line.damaged) || 0) > 0);
    const units = counted.reduce((sum, line) => sum + (num(line.quantity) || 0) + (num(line.damaged) || 0), 0);
    let freight = num(shipment.freight_amount) || 0;
    if (shipment.freight_currency === 'CNY') freight *= rate;
    const freightPerUnit = units ? freight / units : 0;
    let filled = 0;
    counted.forEach(line => {
      if (line.unit_cost == null) return;
      const goods = line.currency === 'AUD' ? Number(line.unit_cost) : Number(line.unit_cost) * rate;
      line.cost = (goods + freightPerUnit).toFixed(2);
      filled += 1;
    });
    rerenderBlocks();
    toast(filled ? `已估算 ${filled} 行成本（每件运费 A$${freightPerUnit.toFixed(2)}）` : '先填数量；只有采购单里有单价的行才能估算', !filled);
  }

  async function postReceipt() {
    const receiving = state.receiving;
    const counted = receiving.lines.filter(line => (num(line.quantity) || 0) + (num(line.damaged) || 0) > 0);
    const invalidQty = receiving.lines.find(line => (num(line.quantity) || 0) < 0 || (num(line.damaged) || 0) < 0
      || (line.quantity !== '' && !Number.isInteger(num(line.quantity))) || (line.damaged !== '' && !Number.isInteger(num(line.damaged))));
    if (invalidQty) { toast('数量要填整数', true); return; }
    const missingSku = counted.findIndex(line => !line.product);
    if (missingSku >= 0) { toast(`第 ${missingSku + 1} 行有数量但还没选 SKU`, true); return; }
    if (!counted.length && !receiving.markStocked) { toast('还没有填数量', true); return; }

    const byStore = new Map();
    counted.forEach(line => byStore.set(Number(line.store_id), (byStore.get(Number(line.store_id)) || 0) + (num(line.quantity) || 0)));
    const summary = Array.from(byStore.entries()).map(([storeId, qty]) => `${storeName(storeId)} +${qty}`).join('\n');
    const message = counted.length
      ? `确认入库？\n\n${summary}${receiving.markStocked ? '\n\n并把这个批次标记为「已入库」' : ''}`
      : '没有新的数量，只把这个批次标记为「已入库」？';
    if (!window.confirm(message)) return;

    const signer = (document.getElementById('signBy') || {}).value || receiving.signer || '';
    if (signer) writeStorage(SIGNER_KEY, signer);
    try {
      const result = await api('post_receipt', {
        shipment_id: receiving.shipmentId,
        receipt_key: receiving.receiptKey,
        update_cost: receiving.updateCost,
        mark_stocked: receiving.markStocked,
        lines: counted.map(line => ({
          parcel_id: line.parcel_id,
          purchase_order_item_id: line.item_id,
          product_id: line.product.id,
          store_id: Number(line.store_id),
          quantity: num(line.quantity) || 0,
          damaged_quantity: num(line.damaged) || 0,
          unit_cost_aud: num(line.cost)
        }))
      }, { actorName: signer });
      const shipmentId = receiving.shipmentId;
      initReceiving(shipmentId);
      render();
      toast(result.result && result.result.replayed ? '这次入库之前已经提交过了' : `已入库 ${result.result ? result.result.stocked_quantity : ''} 件`);
    } catch (error) {
      toast(error.message, true);
    }
  }

  async function signShipment() {
    const shipment = index.shipments.get(state.receiving.shipmentId);
    const signer = document.getElementById('signBy').value.trim();
    if (!signer) { toast('请填签收人', true); return; }
    writeStorage(SIGNER_KEY, signer);
    const storeId = Number(document.getElementById('signStore').value) || null;
    const signedAt = document.getElementById('signAt').value;
    try {
      await api('save_shipment', shipmentPayload(shipment, {
        status: 'received',
        received_by: signer,
        received_store_id: storeId,
        received_cartons: num(document.getElementById('signCartons').value),
        received_at: signedAt ? new Date(signedAt).toISOString() : ''
      }), { actorName: signer });
      state.receiving.storeId = storeId || state.receiving.storeId;
      state.receiving.lines.forEach(line => { if (!line.quantity) line.store_id = state.receiving.storeId; });
      render();
      toast('已签收');
    } catch (error) {
      toast(error.message, true);
    }
  }

  // ---------- drawers ----------

  function openDrawer(type, title, subtitle, body, foot, draft) {
    state.drawer = { type, draft };
    els.drawerTitle.textContent = title;
    els.drawerSubtitle.textContent = subtitle || '';
    els.drawerBody.innerHTML = body;
    els.drawerFoot.innerHTML = foot;
    els.drawer.hidden = false;
    const first = els.drawerBody.querySelector('input:not([type=checkbox]), select, textarea');
    if (first && type !== 'shipment') setTimeout(() => first.focus(), 30);
  }

  function closeDrawer() {
    state.drawer = null;
    els.drawer.hidden = true;
    els.drawerBody.innerHTML = '';
  }

  function drawerValue(name) {
    const element = els.drawerBody.querySelector(`[name="${name}"]`);
    if (!element) return undefined;
    if (element.type === 'checkbox') return element.checked;
    return element.value.trim();
  }

  function drawerFoot(deleteAction, canDelete) {
    return `${canDelete ? `<button class="pa-btn danger" type="button" data-action="${deleteAction}"><i class="bi bi-trash"></i> 删除</button>` : '<span></span>'}
      <div class="right"><button class="pa-btn" type="button" data-action="close-drawer">取消</button><button class="pa-btn primary" type="button" data-action="save-drawer"><i class="bi bi-check2"></i> 保存</button></div>`;
  }

  // Order drawer

  function openOrderDrawer(id) {
    const existing = id ? index.orders.get(Number(id)) : null;
    const draft = existing ? JSON.parse(JSON.stringify(existing)) : { items: [], currency: 'CNY', order_date: todayISO() };
    if (!draft.items.length) draft.items.push({ description: '', quantity: '', unit_cost: '' });
    const stage = existing ? orderStage(existing) : 'ordered';
    const parcels = existing ? (index.parcelsByOrder.get(Number(existing.id)) || []) : [];
    const steps = [['ordered', '下单'], ['awaiting_payment', '出明细'], ['awaiting_dispatch', '已付款'], ['dispatched', '已发货'], ['complete', '已入库']];
    const stageIndex = steps.findIndex(([key]) => key === stage);
    const body = `
      ${existing && stage !== 'cancelled' ? `<div class="pa-steps">${steps.map(([key, label], position) => `<span class="pa-step ${position < stageIndex ? 'done' : position === stageIndex ? 'current' : ''}">${label}</span>`).join('')}</div>` : ''}
      <div class="pa-section"><div class="pa-section-title">供货商</div>
        <div class="pa-form">
          ${field('供货商', `<div style="display:flex;gap:6px"><select name="supplier_id" style="flex:1">${supplierOptions(draft.supplier_id)}</select><button class="pa-btn small" type="button" data-action="quick-supplier" title="新增供货商"><i class="bi bi-plus-lg"></i></button></div>`)}
          ${field('平台 / 订单号', input('supplier_order_ref', draft.supplier_order_ref, 'placeholder="1688 / 淘宝 订单号"'))}
          ${field('下单日期', input('order_date', draft.order_date, 'type="date"'))}
          ${field('供货商出明细日期', input('invoice_received_at', draft.invoice_received_at, 'type="date"'))}
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">产品明细 <button class="pa-btn small" type="button" data-action="order-item-add"><i class="bi bi-plus-lg"></i> 加一行</button></div>
        <div id="orderItems">${renderOrderItems(draft)}</div>
      </div>
      <div class="pa-section"><div class="pa-section-title">金额 &amp; 付款</div>
        <div class="pa-form">
          ${field('币种', `<select name="currency">${listOptions(CURRENCIES, draft.currency || 'CNY')}</select>`)}
          ${field('货款合计', input('goods_amount', draft.goods_amount, `type="number" step="0.01" min="0" id="goodsAmount" placeholder="${orderItemsTotal(draft) || '自动按明细合计'}"`))}
          ${field('国内运费', input('domestic_shipping_amount', draft.domestic_shipping_amount, 'type="number" step="0.01" min="0"'))}
          ${field('付款金额', input('paid_amount', draft.paid_amount, 'type="number" step="0.01" min="0"'))}
          ${field('付款日期', `<div style="display:flex;gap:6px">${input('paid_at', draft.paid_at, 'type="date" style="flex:1"')}<button class="pa-btn small" type="button" data-action="paid-today">今天</button></div>`)}
          ${field('付款方式', `<select name="payment_method"><option value=""></option>${listOptions(PAYMENT_METHODS, draft.payment_method)}</select>`)}
          ${field('付款备注 / 流水号', input('payment_ref', draft.payment_ref), true)}
        </div>
      </div>
      <div class="pa-section">
        <div class="pa-form">
          ${field('备注', `<textarea name="notes">${esc(draft.notes || '')}</textarea>`, true)}
          <label class="pa-check"><input type="checkbox" name="cancelled" ${draft.cancelled_at ? 'checked' : ''}> 已取消</label>
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">国内包裹 ${existing ? `<button class="pa-btn small" type="button" data-action="order-add-parcel" data-id="${existing.id}"><i class="bi bi-plus-lg"></i> 供货商发货了，登记包裹</button>` : ''}</div>
        ${existing ? (parcels.length ? `<div class="pa-mini-list">${parcels.map(parcel => `<div class="pa-mini"><div class="pa-mini-main"><strong>${esc(parcel.contents || '(未填内容)')}</strong><span class="pa-small pa-muted">${esc(parcel.courier || '')}</span> ${trackButton(parcel.tracking_no, 'cn')}</div><div>${stageChip(PARCEL_STAGE, parcelStage(parcel))} <button class="pa-btn small" type="button" data-action="open-parcel" data-id="${parcel.id}">打开</button></div></div>`).join('')}</div>` : '<p class="pa-muted pa-small">还没有包裹</p>') : '<p class="pa-muted pa-small">保存采购单之后可以登记包裹</p>'}
      </div>`;
    openDrawer('order', existing ? `采购单 ${existing.po_number}` : '新采购单', existing ? stageLabel(ORDER_STAGE, stage) : '下单 → 出明细 → 付款 → 发货', body, drawerFoot('delete-order', Boolean(existing)), draft);
  }

  function stageLabel(map, key) { return (map[key] || {}).label || ''; }

  function orderItemsTotal(draft) {
    const total = (draft.items || []).reduce((sum, item) => sum + (num(item.unit_cost) || 0) * (num(item.quantity) || 0), 0);
    return total ? Math.round(total * 100) / 100 : '';
  }

  function renderOrderItems(draft) {
    return `<table class="pa-items"><thead><tr><th>品名 / 规格</th><th>数量</th><th>单价</th><th>小计</th><th>SKU</th><th></th></tr></thead><tbody>
      ${draft.items.map((item, position) => `<tr data-item="${position}">
        <td><input data-item-field="description" value="${esc(item.description || '')}" placeholder="例如 荔枝纹 iPad 壳 黑色"></td>
        <td class="qty"><input data-item-field="quantity" type="number" min="1" value="${esc(item.quantity == null ? '' : item.quantity)}"></td>
        <td class="money"><input data-item-field="unit_cost" type="number" min="0" step="0.01" value="${esc(item.unit_cost == null ? '' : item.unit_cost)}"></td>
        <td class="pa-small pa-muted" data-item-subtotal>${(num(item.quantity) && num(item.unit_cost) != null) ? money(num(item.quantity) * num(item.unit_cost), draft.currency) : ''}</td>
        <td class="pa-small">${item.product_sku ? esc(item.product_sku) : '<span class="pa-muted">入库时匹配</span>'}${item.received_quantity ? `<div class="pa-muted">已收 ${item.received_quantity}</div>` : ''}</td>
        <td><button class="pa-btn small ghost danger" type="button" data-action="order-item-remove" title="删除"><i class="bi bi-x-lg"></i></button></td>
      </tr>`).join('')}
    </tbody></table>`;
  }

  async function saveOrder() {
    const draft = state.drawer.draft;
    const items = draft.items.filter(item => String(item.description || '').trim() || num(item.quantity));
    const payload = orderPayload(draft, {
      supplier_id: num(drawerValue('supplier_id')),
      supplier_order_ref: drawerValue('supplier_order_ref'),
      order_date: drawerValue('order_date'),
      invoice_received_at: drawerValue('invoice_received_at'),
      currency: drawerValue('currency'),
      goods_amount: num(drawerValue('goods_amount')),
      domestic_shipping_amount: num(drawerValue('domestic_shipping_amount')),
      paid_amount: num(drawerValue('paid_amount')),
      paid_at: drawerValue('paid_at'),
      payment_method: drawerValue('payment_method'),
      payment_ref: drawerValue('payment_ref'),
      notes: drawerValue('notes'),
      cancelled: drawerValue('cancelled')
    });
    payload.items = items.map(item => ({
      id: item.id || null,
      description: String(item.description || '').trim(),
      quantity: num(item.quantity),
      unit_cost: num(item.unit_cost),
      product_id: item.product_id || null,
      declared_name: item.declared_name || '',
      notes: item.notes || ''
    }));
    const result = await api('save_order', payload);
    const id = result.result && result.result.id;
    toast('采购单已保存');
    if (!draft.id && id) openOrderDrawer(id);
    else closeDrawer();
  }

  // Parcel drawer

  function openParcelDrawer(id, preset) {
    const existing = id ? index.parcels.get(Number(id)) : null;
    const draft = existing ? Object.assign({}, existing) : Object.assign({ carton_count: 1, shipped_at: todayISO() }, preset || {});
    if (!existing && draft.purchase_order_id && !draft.contents) {
      const order = index.orders.get(Number(draft.purchase_order_id));
      if (order) draft.contents = itemsSummary(order);
    }
    const orders = state.data.orders.filter(order => !order.cancelled_at || Number(order.id) === Number(draft.purchase_order_id));
    const shipments = state.data.shipments.filter(shipment => !DONE.has(shipment.status) || Number(shipment.id) === Number(draft.shipment_id));
    const stage = existing ? parcelStage(existing) : 'domestic';
    const body = `
      <div class="pa-section"><div class="pa-section-title">包裹内容</div>
        <div class="pa-form">
          ${field('内容（品名 + 数量）', `<textarea name="contents" placeholder="例如 荔枝纹 iPad 壳 45 个">${esc(draft.contents || '')}</textarea>`, true)}
          ${field('采购单', `<select name="purchase_order_id"><option value="">— 不关联 —</option>${orders.map(order => `<option value="${order.id}" ${Number(order.id) === Number(draft.purchase_order_id) ? 'selected' : ''}>${esc(order.po_number)} · ${esc(supplierName(order.supplier_id) || '未指定')} · ${esc((itemsSummary(order) || '').slice(0, 30))}</option>`).join('')}</select>`)}
          ${field('供货商', `<div style="display:flex;gap:6px"><select name="supplier_id" style="flex:1">${supplierOptions(draft.supplier_id)}</select><button class="pa-btn small" type="button" data-action="quick-supplier" title="新增供货商"><i class="bi bi-plus-lg"></i></button></div>`)}
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">国内快递</div>
        <div class="pa-form">
          ${field('快递公司', `${input('courier', draft.courier, 'list="courierList" placeholder="顺丰 / 中通 …"')}<datalist id="courierList">${COURIERS.map(courier => `<option value="${esc(courier)}"></option>`).join('')}</datalist>`)}
          ${field('快递单号', `<div style="display:flex;gap:6px">${input('tracking_no', draft.tracking_no, 'style="flex:1" autocomplete="off"')}${draft.tracking_no ? trackButton(draft.tracking_no, 'cn') : ''}</div>`)}
          ${field('供货商发货日期', input('shipped_at', draft.shipped_at, 'type="date"'))}
          ${field('箱数', input('carton_count', draft.carton_count, 'type="number" min="0"'))}
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">转运</div>
        <div class="pa-form">
          ${field('寄到哪个转运', `<select name="forwarder_id" data-change="parcelForwarderField">${forwarderOptions(draft.forwarder_id)}</select>`)}
          ${field('渠道', `${input('channel', draft.channel, 'list="parcelChannels" placeholder="海运普货 / 空运 …"')}<span id="parcelChannelList">${channelDatalist('parcelChannels', draft.forwarder_id)}</span>`)}
          ${field('转运仓签收日期', `<div style="display:flex;gap:6px">${input('forwarder_received_at', draft.forwarder_received_at, 'type="date" style="flex:1"')}<button class="pa-btn small" type="button" data-action="set-today" data-target="forwarder_received_at">今天</button></div>`)}
          ${field('转运入仓号', input('forwarder_ref', draft.forwarder_ref, 'placeholder="例如 HT2609090021"'))}
          ${field('转运批次', `<select name="shipment_id"><option value="">— 还没组批 —</option>${shipments.map(shipment => `<option value="${shipment.id}" ${Number(shipment.id) === Number(draft.shipment_id) ? 'selected' : ''}>${esc(shipment.shipment_number)} · ${esc(shipmentTitle(shipment))} · ${esc(SHIPMENT_STATUS[shipment.status].label)}${(shipment.tracking_numbers || [])[0] ? ` · ${esc(shipment.tracking_numbers[0])}` : ''}</option>`).join('')}</select>`)}
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">申报信息（出明细给转运用）</div>
        <div class="pa-form">
          ${field('申报货值 ¥', input('declared_value', draft.declared_value, 'type="number" min="0" step="0.01"'))}
          ${field('重量 kg', input('weight_kg', draft.weight_kg, 'type="number" min="0" step="0.01"'))}
          <label class="pa-check"><input type="checkbox" name="has_battery" ${draft.has_battery ? 'checked' : ''}> 带电</label>
          <label class="pa-check"><input type="checkbox" name="has_magnet" ${draft.has_magnet ? 'checked' : ''}> 带磁</label>
          ${field('备注', `<textarea name="notes">${esc(draft.notes || '')}</textarea>`, true)}
        </div>
      </div>`;
    openDrawer('parcel', existing ? '国内包裹' : '登记包裹', existing ? `${stageLabel(PARCEL_STAGE, stage)}${existing.source === 'sheet_import' ? ' · 从表格导入' : ''}` : '供货商发货后登记快递单号', body, drawerFoot('delete-parcel', Boolean(existing)), draft);
  }

  async function saveParcel() {
    const draft = state.drawer.draft;
    const payload = parcelPayload(draft, {
      contents: drawerValue('contents'),
      purchase_order_id: num(drawerValue('purchase_order_id')),
      supplier_id: num(drawerValue('supplier_id')),
      courier: drawerValue('courier'),
      tracking_no: drawerValue('tracking_no'),
      shipped_at: drawerValue('shipped_at'),
      carton_count: num(drawerValue('carton_count')),
      forwarder_id: num(drawerValue('forwarder_id')),
      channel: drawerValue('channel'),
      forwarder_received_at: drawerValue('forwarder_received_at'),
      forwarder_ref: drawerValue('forwarder_ref'),
      shipment_id: num(drawerValue('shipment_id')),
      declared_value: num(drawerValue('declared_value')),
      weight_kg: num(drawerValue('weight_kg')),
      has_battery: drawerValue('has_battery'),
      has_magnet: drawerValue('has_magnet'),
      notes: drawerValue('notes')
    });
    if (!payload.contents && !payload.tracking_no) { toast('至少填内容或者快递单号', true); return; }
    await api('save_parcel', payload);
    toast('包裹已保存');
    closeDrawer();
  }

  // Shipment drawer

  function openShipmentDrawer(id, preset) {
    const existing = id ? index.shipments.get(Number(id)) : null;
    const draft = existing ? JSON.parse(JSON.stringify(existing)) : Object.assign({ status: 'declared', freight_currency: 'CNY', tracking_numbers: [] }, preset || {});
    draft.parcel_ids = existing ? shipmentParcels(existing).map(parcel => Number(parcel.id)) : (draft.parcel_ids || []);
    if (!existing && !draft.forwarder_id && draft.parcel_ids.length) {
      const selected = draft.parcel_ids.map(parcelId => index.parcels.get(Number(parcelId))).filter(Boolean);
      const withForwarder = selected.find(parcel => parcel.forwarder_id);
      draft.forwarder_id = withForwarder ? withForwarder.forwarder_id : null;
      const withChannel = selected.find(parcel => parcel.channel);
      draft.channel = draft.channel || (withChannel ? withChannel.channel : '');
    }
    const stepIndex = SHIPMENT_FLOW.indexOf(draft.status);
    const body = `
      ${draft.status !== 'closed' ? `<div class="pa-steps">${SHIPMENT_FLOW.map((key, position) => `<span class="pa-step ${position < stepIndex ? 'done' : position === stepIndex ? 'current' : ''}">${SHIPMENT_STATUS[key].label}</span>`).join('')}</div>` : ''}
      <div class="pa-section"><div class="pa-section-title">转运 &amp; 状态</div>
        <div class="pa-form">
          ${field('转运公司', `<select name="forwarder_id" data-change="shipmentForwarderField">${forwarderOptions(draft.forwarder_id)}</select>`)}
          ${field('渠道', `${input('channel', draft.channel, 'list="shipmentChannels"')}<span id="shipmentChannelList">${channelDatalist('shipmentChannels', draft.forwarder_id)}</span>`)}
          ${field('状态', `<select name="status">${Object.entries(SHIPMENT_STATUS).map(([key, value]) => `<option value="${key}" ${draft.status === key ? 'selected' : ''}>${value.label}</option>`).join('')}</select>`)}
          ${field('国际单号（一行一个）', `<textarea name="tracking_numbers" rows="2" placeholder="ACWL26081102207">${esc((draft.tracking_numbers || []).join('\n'))}</textarea>`)}
          ${field('出收据日期', input('declared_at', draft.declared_at, 'type="date"'))}
          ${field('转运发货日期', input('shipped_at', draft.shipped_at, 'type="date"'))}
          ${field('预计到达', input('eta', draft.eta, 'type="date"'))}
          ${field('到达澳洲日期', input('arrived_at', draft.arrived_at, 'type="date"'))}
        </div>
        ${(draft.tracking_numbers || []).length ? `<div class="pa-card-foot">${trackingList(draft)}</div>` : ''}
      </div>
      <div class="pa-section"><div class="pa-section-title">运费</div>
        <div class="pa-form">
          ${field('运费', `<div style="display:flex;gap:6px">${input('freight_amount', draft.freight_amount, 'type="number" min="0" step="0.01" style="flex:1"')}<select name="freight_currency" style="width:90px">${listOptions(CURRENCIES, draft.freight_currency || 'CNY')}</select></div>`)}
          ${field('计费重量 kg', input('weight_kg', draft.weight_kg, 'type="number" min="0" step="0.01"'))}
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">签收</div>
        <div class="pa-form">
          ${field('签收人', input('received_by', draft.received_by))}
          ${field('签收门店', `<select name="received_store_id"><option value=""></option>${storeOptions(draft.received_store_id)}</select>`)}
          ${field('箱数', input('received_cartons', draft.received_cartons, 'type="number" min="0"'))}
          ${field('签收时间', input('received_at', draft.received_at ? toLocalInput(draft.received_at) : '', 'type="datetime-local"'))}
        </div>
      </div>
      <div class="pa-section"><div class="pa-section-title">包裹 <span class="pa-row-actions"><button class="pa-btn small" type="button" data-action="copy-declaration"><i class="bi bi-clipboard"></i> 复制明细</button><button class="pa-btn small" type="button" data-action="download-declaration"><i class="bi bi-download"></i> 下载明细 CSV</button></span></div>
        <div id="shipmentParcels">${renderShipmentParcels(draft)}</div>
      </div>
      <div class="pa-section">${field('备注', `<textarea name="notes">${esc(draft.notes || '')}</textarea>`, true)}</div>`;
    openDrawer('shipment', existing ? `转运批次 ${existing.shipment_number}` : '新转运批次', existing ? stageLabel(SHIPMENT_STATUS, existing.status) : '选包裹 → 出明细给转运 → 等转运发货', body, drawerFoot('delete-shipment', Boolean(existing)), draft);
  }

  function toLocalInput(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return '';
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  function renderShipmentParcels(draft) {
    const included = draft.parcel_ids.map(id => index.parcels.get(Number(id))).filter(Boolean);
    const candidates = state.data.parcels
      .filter(parcel => !parcel.shipment_id && !draft.parcel_ids.includes(Number(parcel.id)))
      .sort((a, b) => (Number(String(b.forwarder_id) === String(draft.forwarder_id)) - Number(String(a.forwarder_id) === String(draft.forwarder_id)))
        || (Number(Boolean(b.forwarder_received_at)) - Number(Boolean(a.forwarder_received_at))));
    return `${included.length ? `<div class="pa-mini-list">${included.map(parcel => `<div class="pa-mini">
        <div class="pa-mini-main"><strong>${esc(parcel.contents || '(未填内容)')}</strong><span class="pa-small pa-muted">${esc(supplierName(parcelSupplierId(parcel)))} ${esc(parcel.courier || '')} ${esc(parcel.tracking_no || '')}${parcel.forwarder_ref ? ` · 入仓 ${esc(parcel.forwarder_ref)}` : ''}</span></div>
        <button class="pa-btn small ghost danger" type="button" data-action="shipment-remove-parcel" data-id="${parcel.id}" title="移出批次"><i class="bi bi-x-lg"></i></button>
      </div>`).join('')}</div>` : '<p class="pa-muted pa-small">还没有包裹</p>'}
      ${candidates.length ? `<div style="display:flex;gap:6px;margin-top:10px"><select class="pa-input" id="shipmentAddParcel"><option value="">添加还没组批的包裹…</option>${candidates.map(parcel => `<option value="${parcel.id}">${parcel.forwarder_received_at ? '✓ 已到仓 · ' : ''}${esc(forwarderName(parcel.forwarder_id) || '未指定转运')} · ${esc((parcel.contents || '').slice(0, 40))} · ${esc(parcel.tracking_no || '')}</option>`).join('')}</select><button class="pa-btn small" type="button" data-action="shipment-add-parcel">添加</button></div>` : ''}`;
  }

  function declarationRows(parcelIds) {
    const header = ['序号', '品名 / 内容', '供货商', '国内快递', '快递单号', '箱数', '申报货值(¥)', '带电', '带磁', '重量kg', '入仓号', '备注'];
    const rows = parcelIds.map(id => index.parcels.get(Number(id))).filter(Boolean).map((parcel, position) => [
      position + 1,
      parcel.contents || '',
      supplierName(parcelSupplierId(parcel)),
      parcel.courier || '',
      parcel.tracking_no || '',
      parcel.carton_count == null ? '' : parcel.carton_count,
      parcel.declared_value == null ? '' : parcel.declared_value,
      parcel.has_battery ? '是' : '否',
      parcel.has_magnet ? '是' : '否',
      parcel.weight_kg == null ? '' : parcel.weight_kg,
      parcel.forwarder_ref || '',
      parcel.notes || ''
    ]);
    return [header].concat(rows);
  }

  function copyDeclaration() {
    const rows = declarationRows(state.drawer.draft.parcel_ids);
    if (rows.length < 2) { toast('这个批次还没有包裹', true); return; }
    copyText(rows.map(row => row.map(cell => String(cell).replace(/[\t\r\n]+/g, ' ')).join('\t')).join('\n'));
    toast('明细已复制，可以直接粘贴到微信或 Excel');
  }

  function downloadDeclaration() {
    const draft = state.drawer.draft;
    const rows = declarationRows(draft.parcel_ids);
    if (rows.length < 2) { toast('这个批次还没有包裹', true); return; }
    const csv = '﻿' + rows.map(row => row.map(cell => {
      const text = String(cell);
      return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
    }).join(',')).join('\r\n');
    const link = document.createElement('a');
    link.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    link.download = `${draft.shipment_number || '转运明细'}-${todayISO()}.csv`;
    document.body.appendChild(link);
    link.click();
    setTimeout(() => { URL.revokeObjectURL(link.href); link.remove(); }, 500);
  }

  async function saveShipment() {
    const draft = state.drawer.draft;
    const receivedAt = drawerValue('received_at');
    const payload = shipmentPayload(draft, {
      forwarder_id: num(drawerValue('forwarder_id')),
      channel: drawerValue('channel'),
      status: drawerValue('status'),
      tracking_numbers: drawerValue('tracking_numbers').split(/[\s,，;；]+/).map(value => value.trim()).filter(Boolean),
      declared_at: drawerValue('declared_at'),
      shipped_at: drawerValue('shipped_at'),
      eta: drawerValue('eta'),
      arrived_at: drawerValue('arrived_at'),
      freight_amount: num(drawerValue('freight_amount')),
      freight_currency: drawerValue('freight_currency'),
      weight_kg: num(drawerValue('weight_kg')),
      received_by: drawerValue('received_by'),
      received_store_id: num(drawerValue('received_store_id')),
      received_cartons: num(drawerValue('received_cartons')),
      received_at: receivedAt ? new Date(receivedAt).toISOString() : '',
      notes: drawerValue('notes'),
      parcel_ids: draft.parcel_ids
    });
    if (payload.status === 'shipped' && !payload.tracking_numbers.length && !window.confirm('还没有填国际单号，确定标记为「转运发货」？')) return;
    await api('save_shipment', payload);
    state.selectedParcels.clear();
    render();
    toast('批次已保存');
    closeDrawer();
  }

  // Supplier / forwarder

  function supplierForm(draft) {
    return `<div class="pa-form">
      ${field('名称', input('name', draft.name, 'required'), true)}
      ${field('平台', input('platform', draft.platform, 'placeholder="1688 / 淘宝 / 微信 / 工厂"'))}
      ${field('联系人', input('contact_name', draft.contact_name))}
      ${field('微信', input('wechat', draft.wechat))}
      ${field('电话', input('phone', draft.phone))}
      ${field('邮箱', input('email', draft.email))}
      ${field('网址 / 店铺链接', input('website_url', draft.website_url))}
      ${field('备注', `<textarea name="notes">${esc(draft.notes || '')}</textarea>`, true)}
      <label class="pa-check"><input type="checkbox" name="is_active" ${draft.is_active === false ? '' : 'checked'}> 启用</label>
    </div>`;
  }

  function collectSupplier(root, draft) {
    const value = name => {
      const element = root.querySelector(`[name="${name}"]`);
      return element.type === 'checkbox' ? element.checked : element.value.trim();
    };
    return {
      id: draft.id || null,
      name: value('name'),
      platform: value('platform'),
      contact_name: value('contact_name'),
      wechat: value('wechat'),
      phone: value('phone'),
      email: value('email'),
      website_url: value('website_url'),
      notes: value('notes'),
      is_active: value('is_active')
    };
  }

  function openSupplierDrawer(id) {
    const existing = id ? index.suppliers.get(Number(id)) : null;
    const draft = existing ? Object.assign({}, existing) : { is_active: true };
    openDrawer('supplier', existing ? existing.name : '新增供货商', '供货商资料', supplierForm(draft), drawerFoot('', false), draft);
  }

  function openForwarderDrawer(id) {
    const existing = id ? index.forwarders.get(Number(id)) : null;
    const draft = existing ? Object.assign({}, existing) : { is_active: true, channels: [], tracking_prefixes: [] };
    const body = `<div class="pa-form">
      ${field('名称', input('name', draft.name), true)}
      ${field('单号查询网站', input('tracking_url', draft.tracking_url, 'placeholder="http://..."'), true)}
      ${field('后台 / 官网', input('website_url', draft.website_url, 'placeholder="下单后台或官网"'), true)}
      ${field('国内仓收货地址（发给供货商）', `<textarea name="warehouse_address">${esc(draft.warehouse_address || '')}</textarea>`, true)}
      ${field('联系人 / 微信', input('contact', draft.contact))}
      ${field('渠道（逗号分隔）', input('channels', (draft.channels || []).join('，'), 'placeholder="海运普货，空运普货，海运纯电"'))}
      ${field('国际单号前缀（逗号分隔）', input('tracking_prefixes', (draft.tracking_prefixes || []).join('，'), 'placeholder="ACWL，BKP"'))}
      ${field('备注', `<textarea name="notes">${esc(draft.notes || '')}</textarea>`, true)}
      <label class="pa-check"><input type="checkbox" name="is_active" ${draft.is_active === false ? '' : 'checked'}> 启用</label>
      ${draft.tracking_url ? `<div class="full"><a class="pa-btn small" href="${esc(draft.tracking_url)}" target="_blank" rel="noopener"><i class="bi bi-box-arrow-up-right"></i> 打开查询网站</a></div>` : ''}
    </div>`;
    openDrawer('forwarder', existing ? existing.name : '新增转运公司', '每家转运有自己的查询网站、渠道和国内仓地址', body, drawerFoot('', false), draft);
  }

  async function saveSupplier() {
    const payload = collectSupplier(els.drawerBody, state.drawer.draft);
    await api('save_supplier', payload);
    toast('供货商已保存');
    closeDrawer();
  }

  async function saveForwarder() {
    const split = value => String(value || '').split(/[,，、;；\n]+/).map(item => item.trim()).filter(Boolean);
    await api('save_forwarder', {
      id: state.drawer.draft.id || null,
      name: drawerValue('name'),
      tracking_url: drawerValue('tracking_url'),
      website_url: drawerValue('website_url'),
      warehouse_address: drawerValue('warehouse_address'),
      contact: drawerValue('contact'),
      channels: split(drawerValue('channels')),
      tracking_prefixes: split(drawerValue('tracking_prefixes')),
      notes: drawerValue('notes'),
      is_active: drawerValue('is_active'),
      sort_order: state.drawer.draft.sort_order
    });
    toast('转运公司已保存');
    closeDrawer();
  }

  // Modals (quick supplier, new SKU)

  function openModal(type, title, body, draft) {
    state.modal = { type, draft };
    els.modal.innerHTML = `<div class="pa-modal-card" role="dialog" aria-modal="true">
      <div class="pa-drawer-head"><div><h2>${esc(title)}</h2></div><button class="pa-close" type="button" data-action="close-modal" aria-label="关闭"><i class="bi bi-x-lg"></i></button></div>
      <div class="pa-drawer-body">${body}</div>
      <div class="pa-drawer-foot"><span></span><div class="right"><button class="pa-btn" type="button" data-action="close-modal">取消</button><button class="pa-btn primary" type="button" data-action="save-modal"><i class="bi bi-check2"></i> 保存</button></div></div>
    </div>`;
    els.modal.hidden = false;
    const first = els.modal.querySelector('input, select');
    if (first) setTimeout(() => first.focus(), 30);
  }

  function closeModal() {
    state.modal = null;
    els.modal.hidden = true;
    els.modal.innerHTML = '';
  }

  function openNewSkuModal(line) {
    const block = state.receiving.blocks.find(item => item.key === line.block);
    const supplierId = block ? (block.order ? block.order.supplier_id : parcelSupplierId(block.parcels[0])) : null;
    const categories = new Map();
    state.data.pos_categories.forEach(category => {
      if (!categories.has(category.category_name)) categories.set(category.category_name, []);
      categories.get(category.category_name).push(category);
    });
    const body = `<div class="pa-form">
      ${field('商品名称（POS 上显示）', input('name', '', `placeholder="${esc(line.description || (block && block.parcels[0].contents) || '')}"`), true)}
      ${field('SKU（不填自动生成）', input('sku', '', 'placeholder="TM8-CN-…" style="text-transform:uppercase"'))}
      ${field('条码 UPC', input('upc', ''))}
      ${field('POS 分类', `<select name="pos_category_id"><option value="">请选择</option>${Array.from(categories.entries()).map(([name, list]) => `<optgroup label="${esc(name)}">${list.map(category => `<option value="${category.id}">${esc(category.subcategory_name)}</option>`).join('')}</optgroup>`).join('')}</select>`, true)}
      ${field('零售价 A$', input('retail_price', '', 'type="number" min="0" step="0.01"'))}
      ${field('成本价 A$', input('cost_price', line.cost, 'type="number" min="0" step="0.01"'))}
      ${field('供货商', `<select name="supplier_id">${supplierOptions(supplierId)}</select>`, true)}
      <p class="pa-small pa-muted full">新 SKU 会在 POS 显示，网站默认不显示（以后可以在网站后台补图片再上架）。</p>
    </div>`;
    openModal('sku', '新建 SKU', body, { lineKey: line.key });
    const nameInput = els.modal.querySelector('[name="name"]');
    if (nameInput && line.description) nameInput.value = line.description;
  }

  async function saveModal() {
    const modal = state.modal;
    const value = name => {
      const element = els.modal.querySelector(`[name="${name}"]`);
      if (!element) return '';
      return element.type === 'checkbox' ? element.checked : element.value.trim();
    };
    if (modal.type === 'supplier') {
      const payload = collectSupplier(els.modal, {});
      const result = await api('save_supplier', payload);
      const newId = result.result && result.result.id;
      const select = els.drawerBody.querySelector('[name="supplier_id"]');
      if (select && newId) {
        select.innerHTML = supplierOptions(newId);
        select.value = String(newId);
      }
      closeModal();
      toast('供货商已添加');
      return;
    }
    if (modal.type === 'sku') {
      const line = state.receiving && state.receiving.lines.find(item => item.key === modal.draft.lineKey);
      const result = await api('create_product', {
        name: value('name'),
        sku: value('sku'),
        upc: value('upc'),
        pos_category_id: num(value('pos_category_id')),
        retail_price: num(value('retail_price')),
        cost_price: num(value('cost_price')),
        supplier_id: num(value('supplier_id'))
      });
      const product = result.result && result.result.product;
      if (line && product) {
        line.product = product;
        line.results = null;
      }
      closeModal();
      rerenderBlocks();
      toast(`已新建 SKU ${product ? product.sku : ''}`);
    }
  }

  // ---------- actions ----------

  async function advanceShipment(id) {
    const shipment = index.shipments.get(Number(id));
    const next = shipment && NEXT_STEP[shipment.status];
    if (!next) return;
    if (next.status === 'shipped' && !(shipment.tracking_numbers || []).length) {
      openShipmentDrawer(id);
      const select = els.drawerBody.querySelector('[name="status"]');
      if (select) select.value = 'shipped';
      const numbers = els.drawerBody.querySelector('[name="tracking_numbers"]');
      if (numbers) numbers.focus();
      toast('填上国际单号后保存');
      return;
    }
    await api('save_shipment', shipmentPayload(shipment, { status: next.status }));
    toast(`已标记为「${SHIPMENT_STATUS[next.status].label}」`);
  }

  function trackNumber(element) {
    const number = element.dataset.no;
    let url = '';
    if (element.dataset.kind === 'cn') {
      url = DOMESTIC_TRACK_URL + encodeURIComponent(number);
    } else {
      const forwarder = element.dataset.forwarder && index.forwarders.get(Number(element.dataset.forwarder));
      url = forwarder && forwarder.tracking_url;
    }
    copyText(number);
    if (url) window.open(url, '_blank', 'noopener');
    toast(url ? `已复制 ${number}，在查询网站粘贴即可` : `已复制 ${number}（这个转运还没设置查询网站）`);
  }

  const actions = {
    'refresh': () => load(),
    'new-order': () => openOrderDrawer(null),
    'new-parcel': () => openParcelDrawer(null),
    'new-shipment': () => openShipmentDrawer(null),
    'new-supplier': () => openSupplierDrawer(null),
    'new-forwarder': () => openForwarderDrawer(null),
    'open-order': element => openOrderDrawer(element.dataset.id),
    'open-parcel': element => openParcelDrawer(element.dataset.id),
    'open-shipment': element => openShipmentDrawer(element.dataset.id),
    'open-supplier': element => openSupplierDrawer(element.dataset.id),
    'open-forwarder': element => openForwarderDrawer(element.dataset.id),
    'close-drawer': () => closeDrawer(),
    'close-modal': () => closeModal(),
    'track': element => trackNumber(element),
    'clear-search': () => { state.search = ''; els.search.value = ''; render(); },
    'show-done': () => { state.tab = 'shipments'; state.shipmentFilter = 'done'; render(); },
    'filter': element => {
      state[element.dataset.filter] = element.dataset.value;
      render();
    },
    'toggle-parcel': (element, event) => {
      event.stopPropagation();
      const id = Number(element.dataset.id);
      if (element.checked) state.selectedParcels.add(id);
      else state.selectedParcels.delete(id);
      render();
    },
    'clear-selection': () => { state.selectedParcels.clear(); render(); },
    'batch-new': () => {
      const ids = Array.from(state.selectedParcels);
      const forwarders = new Set(ids.map(id => (index.parcels.get(id) || {}).forwarder_id).filter(Boolean).map(String));
      if (forwarders.size > 1 && !window.confirm('选中的包裹在不同的转运，确定放进同一个批次？')) return;
      openShipmentDrawer(null, { parcel_ids: ids });
    },
    'parcel-at-forwarder': async (element, event) => {
      event.stopPropagation();
      const parcel = index.parcels.get(Number(element.dataset.id));
      await api('save_parcel', parcelPayload(parcel, { forwarder_received_at: todayISO() }));
      toast('已标记转运仓签收');
    },
    'advance-shipment': async (element, event) => {
      event.stopPropagation();
      await advanceShipment(element.dataset.id);
    },
    'go-receive': (element, event) => {
      event.stopPropagation();
      state.tab = 'receiving';
      state.search = '';
      els.search.value = '';
      initReceiving(element.dataset.id);
      render();
    },
    'pick-receive': element => {
      if (state.receiving && state.receiving.shipmentId === Number(element.dataset.id)) return;
      initReceiving(element.dataset.id);
      render();
    },
    'save-drawer': async () => {
      const savers = { order: saveOrder, parcel: saveParcel, shipment: saveShipment, supplier: saveSupplier, forwarder: saveForwarder };
      await savers[state.drawer.type]();
    },
    'save-modal': () => saveModal(),
    'delete-order': async () => {
      if (!window.confirm('删除这张采购单？')) return;
      await api('delete_order', { id: state.drawer.draft.id });
      toast('采购单已删除');
      closeDrawer();
    },
    'delete-parcel': async () => {
      if (!window.confirm('删除这个包裹？')) return;
      await api('delete_parcel', { id: state.drawer.draft.id });
      toast('包裹已删除');
      closeDrawer();
    },
    'delete-shipment': async () => {
      if (!window.confirm('删除这个批次？里面的包裹会变回「未组批」。')) return;
      await api('delete_shipment', { id: state.drawer.draft.id });
      toast('批次已删除');
      closeDrawer();
    },
    'order-item-add': () => {
      state.drawer.draft.items.push({ description: '', quantity: '', unit_cost: '' });
      document.getElementById('orderItems').innerHTML = renderOrderItems(state.drawer.draft);
    },
    'order-item-remove': element => {
      const position = Number(element.closest('[data-item]').dataset.item);
      const item = state.drawer.draft.items[position];
      if (item && item.received_quantity) { toast('这一行已经入库，不能删除', true); return; }
      state.drawer.draft.items.splice(position, 1);
      document.getElementById('orderItems').innerHTML = renderOrderItems(state.drawer.draft);
    },
    'order-add-parcel': element => openParcelDrawer(null, { purchase_order_id: Number(element.dataset.id) }),
    'paid-today': () => {
      els.drawerBody.querySelector('[name="paid_at"]').value = todayISO();
      const paid = els.drawerBody.querySelector('[name="paid_amount"]');
      if (paid && !paid.value) {
        const goods = num(els.drawerBody.querySelector('[name="goods_amount"]').value) || orderItemsTotal(state.drawer.draft) || 0;
        const shipping = num(els.drawerBody.querySelector('[name="domestic_shipping_amount"]').value) || 0;
        if (goods + shipping) paid.value = Math.round((goods + shipping) * 100) / 100;
      }
    },
    'set-today': element => { els.drawerBody.querySelector(`[name="${element.dataset.target}"]`).value = todayISO(); },
    'quick-supplier': () => openModal('supplier', '新增供货商', supplierForm({ is_active: true }), {}),
    'shipment-add-parcel': () => {
      const select = document.getElementById('shipmentAddParcel');
      const id = num(select && select.value);
      if (!id) return;
      state.drawer.draft.parcel_ids.push(id);
      document.getElementById('shipmentParcels').innerHTML = renderShipmentParcels(state.drawer.draft);
    },
    'shipment-remove-parcel': element => {
      const id = Number(element.dataset.id);
      state.drawer.draft.parcel_ids = state.drawer.draft.parcel_ids.filter(value => Number(value) !== id);
      document.getElementById('shipmentParcels').innerHTML = renderShipmentParcels(state.drawer.draft);
    },
    'copy-declaration': () => copyDeclaration(),
    'download-declaration': () => downloadDeclaration(),
    'sign-shipment': () => signShipment(),
    'estimate-cost': () => estimateCosts(),
    'post-receipt': () => postReceipt(),
    'line-add': element => {
      const block = state.receiving.blocks.find(item => item.key === element.dataset.block);
      state.receiving.lines.push(newLine(block));
      rerenderBlocks();
    },
    'line-remove': element => {
      const line = findLine(element);
      state.receiving.lines = state.receiving.lines.filter(item => item !== line);
      rerenderBlocks();
    },
    'line-split': element => {
      const line = findLine(element);
      const copy = newLine({ key: line.block, parcels: [{ id: line.parcel_id }] }, {
        item_id: line.item_id,
        product: line.product,
        description: line.description,
        unit_cost: line.unit_cost,
        currency: line.currency,
        cost: line.cost,
        store_id: (state.data.stores.find(store => Number(store.id) !== Number(line.store_id)) || {}).id || line.store_id
      });
      state.receiving.lines.splice(state.receiving.lines.indexOf(line) + 1, 0, copy);
      rerenderBlocks();
    },
    'line-clear-sku': element => {
      const line = findLine(element);
      line.product = null;
      line.results = null;
      rerenderLine(line);
      focusSku(line);
    },
    'line-pick-sku': element => {
      const line = findLine(element);
      line.product = line.results[Number(element.dataset.index)];
      line.results = null;
      rerenderLine(line);
    },
    'line-fill-expected': element => {
      const line = findLine(element);
      line.quantity = String(line.expected);
      const quantityInput = els.view.querySelector(`[data-line="${line.key}"] [data-line-field="quantity"]`);
      if (quantityInput) quantityInput.value = line.quantity;
      rerenderFoot();
    },
    'line-new-sku': element => openNewSkuModal(findLine(element))
  };

  document.addEventListener('click', async event => {
    const element = event.target.closest('[data-action]');
    if (!element) {
      if (event.target === els.drawer) closeDrawer();
      if (event.target === els.modal) closeModal();
      return;
    }
    const handler = actions[element.dataset.action];
    if (!handler) return;
    if (element.tagName === 'BUTTON' && element.disabled) return;
    const busyButton = element.tagName === 'BUTTON' && /save|delete|post|sign|advance|at-forwarder/.test(element.dataset.action) ? element : null;
    try {
      if (busyButton) busyButton.disabled = true;
      await handler(element, event);
    } catch (error) {
      toast(translateError(error.message), true);
    } finally {
      if (busyButton && busyButton.isConnected) busyButton.disabled = false;
    }
  });

  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      if (state.modal) closeModal();
      else if (state.drawer) closeDrawer();
      return;
    }
    if ((event.key === 'Enter' || event.key === ' ') && event.target.matches('.pa-card[role="button"]')) {
      event.preventDefault();
      event.target.click();
    }
  });

  document.addEventListener('input', event => {
    const target = event.target;
    if (target === els.search) {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { state.search = target.value; render(); }, 180);
      return;
    }
    if (target.dataset.itemField && state.drawer && state.drawer.type === 'order') {
      const row = target.closest('[data-item]');
      const item = state.drawer.draft.items[Number(row.dataset.item)];
      item[target.dataset.itemField] = target.value;
      const subtotal = row.querySelector('[data-item-subtotal]');
      if (subtotal) subtotal.textContent = (num(item.quantity) && num(item.unit_cost) != null) ? money(num(item.quantity) * num(item.unit_cost), drawerValue('currency')) : '';
      const goods = document.getElementById('goodsAmount');
      if (goods) goods.placeholder = orderItemsTotal(state.drawer.draft) || '自动按明细合计';
      return;
    }
    if (target.dataset.lineField) {
      const line = findLine(target);
      if (!line) return;
      const fieldName = target.dataset.lineField;
      line[fieldName] = target.value;
      if (fieldName === 'q') {
        clearTimeout(skuTimer);
        skuTimer = setTimeout(() => searchSku(line), 280);
      } else {
        rerenderFoot();
      }
      return;
    }
    if (target.dataset.receiveField === 'rate' && state.receiving) {
      state.receiving.rate = target.value;
      writeStorage(RATE_KEY, target.value);
    }
  });

  document.addEventListener('change', event => {
    const target = event.target;
    const key = target.dataset.change;
    if (target.dataset.lineField === 'store_id') {
      const line = findLine(target);
      if (line) { line.store_id = Number(target.value); rerenderFoot(); }
      return;
    }
    if (target.dataset.receiveField && state.receiving && target.type === 'checkbox') {
      state.receiving[target.dataset.receiveField] = target.checked;
      return;
    }
    if (!key) return;
    if (key === 'parcelForwarder') { state.parcelForwarder = target.value; render(); }
    if (key === 'showStocked') { state.showStockedReceiving = target.checked; render(); }
    if (key === 'batchExisting' && target.value) {
      const shipment = index.shipments.get(Number(target.value));
      openShipmentDrawer(shipment.id);
      const ids = new Set(state.drawer.draft.parcel_ids.concat(Array.from(state.selectedParcels)));
      state.drawer.draft.parcel_ids = Array.from(ids);
      document.getElementById('shipmentParcels').innerHTML = renderShipmentParcels(state.drawer.draft);
      toast('已加入，检查后点保存');
    }
    if (key === 'parcelForwarderField') {
      document.getElementById('parcelChannelList').innerHTML = channelDatalist('parcelChannels', target.value);
    }
    if (key === 'shipmentForwarderField') {
      state.drawer.draft.forwarder_id = num(target.value);
      document.getElementById('shipmentChannelList').innerHTML = channelDatalist('shipmentChannels', target.value);
    }
  });

  els.tabs.addEventListener('click', event => {
    const button = event.target.closest('[data-tab]');
    if (!button) return;
    state.tab = button.dataset.tab;
    state.search = '';
    els.search.value = '';
    render();
  });

  window.Techm8StaffAuth.init({
    rootSelector: '#app',
    title: 'Admin Login',
    subtitle: 'Sign in with the admin account to open China purchasing.',
    requireLoginEmail: true,
    loginInputType: 'text',
    loginPlaceholder: 'Admin account',
    sessionKey: 'techm8_admin_session_token',
    createRpc: 'create_admin_session',
    verifyRpc: 'verify_admin_session',
    revokeRpc: 'revoke_admin_session'
  }).then(load);
})();
