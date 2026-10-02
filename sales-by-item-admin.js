(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  const state = { loaded: false, loading: false, page: 0, report: null, preset: 'lastMonth' };
  const money = value => value == null ? '—' : new Intl.NumberFormat('en-AU', { style: 'currency', currency: 'AUD' }).format(Number(value));
  const qty = value => new Intl.NumberFormat('en-AU', { maximumFractionDigits: 2 }).format(Number(value || 0));
  const html = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[c]);
  const today = () => {
    const parts = new Intl.DateTimeFormat('en-AU', { timeZone: 'Australia/Brisbane', year:'numeric', month:'2-digit', day:'2-digit' }).formatToParts(new Date());
    const values = Object.fromEntries(parts.filter(p => p.type !== 'literal').map(p => [p.type, p.value]));
    return `${values.year}-${values.month}-${values.day}`;
  };
  const at = iso => new Date(`${iso}T12:00:00Z`);
  const iso = date => `${date.getUTCFullYear()}-${String(date.getUTCMonth()+1).padStart(2,'0')}-${String(date.getUTCDate()).padStart(2,'0')}`;
  const add = (date, days) => { const d = at(date); d.setUTCDate(d.getUTCDate()+days); return iso(d); };
  function dates(preset) {
    const now = today(), current = at(now);
    if (preset === 'yesterday') return [add(now,-1),add(now,-1)];
    if (preset === 'last7') return [add(now,-6),now];
    if (preset === 'month') return [`${now.slice(0,8)}01`,now];
    if (preset === 'lastMonth') return [iso(new Date(Date.UTC(current.getUTCFullYear(),current.getUTCMonth()-1,1))),iso(new Date(Date.UTC(current.getUTCFullYear(),current.getUTCMonth(),0)))];
    if (preset === 'year') return [`${now.slice(0,4)}-01-01`,now];
    if (preset === 'all') return ['2020-01-01',now];
    return [now,now];
  }
  function formatDate(value) { return new Intl.DateTimeFormat('en-AU',{day:'2-digit',month:'short',year:'numeric'}).format(at(value)); }
  function setPreset(preset, run) {
    state.preset = preset;
    const [from,to] = dates(preset);
    $('itemDateFrom').value = from; $('itemDateTo').value = to;
    document.querySelectorAll('[data-item-preset]').forEach(button => button.classList.toggle('active',button.dataset.itemPreset === preset));
    if (run) load(true);
  }
  function alert(text, error) {
    const box = $('itemAlert'); box.textContent = text || ''; box.hidden = !text;
    box.classList.toggle('error',Boolean(error));
  }
  function params(limit, offset) {
    return {
      session_token: window.Techm8StaffAuth.getToken(),
      date_from: $('itemDateFrom').value,
      date_to: $('itemDateTo').value,
      target_store_code: $('itemStore').value || null,
      target_type: $('itemType').value || null,
      criteria_field: $('itemCriteria').value || null,
      criteria_query: $('itemCriteria').value ? $('itemQuery').value.trim() : null,
      page_limit: limit,
      page_offset: offset
    };
  }
  function rowHtml(row, interactive = false) {
    const costMissing = Number(row.unknown_cost_lines) > 0;
    const storeCell = interactive && row.store_name === 'Stores'
      ? `<button class="item-store-toggle" type="button" aria-expanded="false"><span>⊕</span> Stores</button>`
      : html(row.store_name);
    const main = `<tr><td>${storeCell}</td><td>${html(row.type)}</td><td>${html(row.repair_category)}</td><td>${html(row.category)}</td><td>${html(row.brand)}</td><td>${html(row.model)}</td><td class="item-name">${html(row.product_name)}</td><td class="num">${qty(row.qty)}</td><td class="num">${money(row.total)}</td><td class="num" title="${costMissing ? 'Cost not recorded for some sales' : ''}">${money(row.cogs)}</td><td class="num">${money(row.net_profit)}</td><td class="num">${row.margin == null ? '—' : `${qty(row.margin)}%`}</td></tr>`;
    if (!interactive || row.store_name !== 'Stores') return main;
    const breakdown = (row.stores || []).map(store => `<span><b>${html(store.store_name)}</b> · ${qty(store.qty)} · ${money(store.total)}${store.cogs == null ? ' · COGS —' : ` · COGS ${money(store.cogs)}`}</span>`).join('');
    return main + `<tr class="item-store-detail" hidden><td colspan="12">${breakdown}</td></tr>`;
  }
  function render(report) {
    state.report = report;
    const rows = Array.isArray(report.rows) ? report.rows : [];
    $('itemBody').innerHTML = rows.length ? rows.map(row => rowHtml(row,true)).join('') : '<tr><td class="item-empty" colspan="12">No results found.</td></tr>';
    const totals = report.totals || {};
    $('itemFoot').innerHTML = `<tr><th colspan="7">Total</th><th class="num">${qty(totals.qty)}</th><th class="num">${money(totals.total)}</th><th class="num">${money(totals.cogs)}</th><th class="num">${money(totals.net_profit)}</th><th class="num">${totals.margin == null ? '—' : `${qty(totals.margin)}%`}</th></tr>`;
    const count = Number(report.row_count || 0), size = Number($('itemPageSize').value);
    $('itemRange').textContent = `${formatDate(report.date_from)} – ${formatDate(report.date_to)}`;
    $('itemCount').textContent = count ? `${state.page*size+1}–${Math.min((state.page+1)*size,count)} of ${count} items` : '0 items';
    $('itemPageLabel').textContent = `Page ${state.page+1} of ${Math.max(1,Math.ceil(count/size))}`;
    $('itemPrevious').disabled = state.page === 0;
    $('itemNext').disabled = (state.page+1)*size >= count;
    if (Number(totals.unknown_cost_lines) > 0) alert(`${totals.unknown_cost_lines} sale or refund lines have no recorded cost. COGS and profit for affected items and the grand total are shown as —.`);
    else alert('');
  }
  async function load(resetPage) {
    if (state.loading) return;
    const from = $('itemDateFrom').value, to = $('itemDateTo').value;
    if (!from || !to || from > to) { alert('Choose a valid date range.',true); return; }
    if (resetPage) state.page = 0;
    state.loading = true; $('itemRun').disabled = true;
    $('itemBody').innerHTML = '<tr><td class="item-empty" colspan="12">Running report…</td></tr>';
    try {
      const report = await window.Techm8StaffAuth.callRpc('get_admin_sales_by_item', params(Number($('itemPageSize').value),state.page*Number($('itemPageSize').value)));
      state.loaded = true;
      render(report || {});
    } catch (error) {
      $('itemBody').innerHTML = '<tr><td class="item-empty" colspan="12">The report could not be loaded.</td></tr>';
      alert(error.message || 'The report could not be loaded.',true);
    } finally { state.loading = false; $('itemRun').disabled = false; }
  }
  async function allRows() {
    const collected = [];
    const fixedParams = params(1000, 0);
    let report;
    do {
      report = await window.Techm8StaffAuth.callRpc('get_admin_sales_by_item',{...fixedParams,page_offset:collected.length});
      collected.push(...(report.rows || []));
    } while (collected.length < Number(report.row_count || 0) && (report.rows || []).length);
    return { report, rows: collected };
  }
  async function exportExcel() {
    $('itemExportExcel').disabled = true;
    try {
      alert('Preparing Excel export…');
      const { report, rows } = await allRows();
      const headings = ['Stores','Type','Repair Category','Category/Sub Category','Brand','Model','Product Name','QTY','Total','COGS','Net Profit','Net Profit Margin'];
      const numeric = value => value == null ? '' : Number(value);
      const lines = [headings, ...rows.map(row => [row.store_name,row.type,row.repair_category,row.category,row.brand,row.model,row.product_name,numeric(row.qty),numeric(row.total),numeric(row.cogs),numeric(row.net_profit),numeric(row.margin)])];
      const totals = report.totals || {};
      lines.push(['Total','','','','','','',numeric(totals.qty),numeric(totals.total),numeric(totals.cogs),numeric(totals.net_profit),numeric(totals.margin)]);
      const blob = window.Techm8SalesByItemXlsx.createWorkbook(lines);
      const url = URL.createObjectURL(blob), link = document.createElement('a');
      link.href = url; link.download = `sales-by-item-${report.date_from}-${report.date_to}.xlsx`;
      document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url),30000);
      alert(Number(totals.unknown_cost_lines) > 0 ? `${totals.unknown_cost_lines} lines have no recorded cost; incomplete profit cells are blank in the export.` : '');
    } catch (error) { alert(error.message || 'Export failed.',true); }
    finally { $('itemExportExcel').disabled = false; }
  }
  async function printReport() {
    try {
      alert('Preparing full report for printing…');
      const { report, rows } = await allRows();
      const headers = Array.from(document.querySelectorAll('.item-report-table thead th')).map(cell => `<th>${html(cell.textContent)}</th>`).join('');
      const totals = report.totals || {};
      $('itemPrintArea').innerHTML = `<h1>Sales By Item Report</h1><p>${formatDate(report.date_from)} – ${formatDate(report.date_to)} · Accrual Basis · Amounts ex GST</p><table><thead><tr>${headers}</tr></thead><tbody>${rows.map(rowHtml).join('')}</tbody><tfoot><tr><th colspan="7">Total</th><th class="num">${qty(totals.qty)}</th><th class="num">${money(totals.total)}</th><th class="num">${money(totals.cogs)}</th><th class="num">${money(totals.net_profit)}</th><th class="num">${totals.margin == null ? '—' : `${qty(totals.margin)}%`}</th></tr></tfoot></table><p>${rows.length} items</p>`;
      alert(Number(report.totals?.unknown_cost_lines) > 0 ? 'Some items have no recorded cost; incomplete COGS and profit values are shown as —.' : '');
      window.print();
    } catch (error) { alert(error.message || 'Print preparation failed.',true); }
  }
  document.querySelectorAll('[data-item-preset]').forEach(button => button.addEventListener('click',() => setPreset(button.dataset.itemPreset,true)));
  $('itemRun').addEventListener('click',() => load(true));
  $('itemReset').addEventListener('click',() => { $('itemStore').value=''; $('itemType').value=''; $('itemCriteria').value=''; $('itemQuery').value=''; $('itemQueryLabel').hidden=true; setPreset('lastMonth',true); });
  $('itemCriteria').addEventListener('change',() => { $('itemQueryLabel').hidden = !$('itemCriteria').value; if (!$('itemCriteria').value) $('itemQuery').value=''; });
  [$('itemDateFrom'),$('itemDateTo')].forEach(input => input.addEventListener('change',() => { state.preset=''; document.querySelectorAll('[data-item-preset]').forEach(button => button.classList.remove('active')); }));
  $('itemPageSize').addEventListener('change',() => load(true));
  $('itemPrevious').addEventListener('click',() => { if (state.page > 0) { state.page--; load(false); } });
  $('itemNext').addEventListener('click',() => { if (state.report && (state.page+1)*Number($('itemPageSize').value) < Number(state.report.row_count)) { state.page++; load(false); } });
  $('itemExportExcel').addEventListener('click',exportExcel);
  $('itemBody').addEventListener('click',event => {
    const button = event.target.closest('.item-store-toggle');
    if (!button) return;
    const detail = button.closest('tr').nextElementSibling;
    const open = button.getAttribute('aria-expanded') === 'true';
    button.setAttribute('aria-expanded',String(!open));
    button.querySelector('span').textContent = open ? '⊕' : '⊖';
    if (detail) detail.hidden = open;
  });
  $('itemExportPdf').addEventListener('click',printReport);
  $('itemPrint').addEventListener('click',printReport);
  setPreset('lastMonth',false);
  window.Techm8SalesByItem = { open() { if (!state.loaded) load(true); } };
})();
