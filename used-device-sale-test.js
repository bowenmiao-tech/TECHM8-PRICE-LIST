(function () {
  'use strict';

  // The pre-sale test for a second-hand device, shared by the POS and the
  // admin portal.
  //
  // Two records, deliberately kept apart:
  //
  //   at purchase   - what the device was like when the shop bought it. Shown
  //                   here read-only; the database refuses any change to it.
  //   pre-sale test - a fresh, complete run of the checklist once the device
  //                   has been cleaned up or repaired. Every run is kept. The
  //                   latest one decides whether the device can be sold.
  //
  // Staff sessions see their own store's devices; an admin session sees any.

  const ANSWERS = [
    {value: 'pass', label: 'Pass'},
    {value: 'fail', label: 'Fail'},
    {value: 'na', label: 'N/A'}
  ];
  const escape = value => String(value == null ? '' : value).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
  const when = value => (value && Number.isFinite(Date.parse(value)) ? new Date(value).toLocaleString('en-AU') : '');
  const answerLabel = value => ({pass: 'Pass', fail: 'Fail', na: 'N/A'})[value] || 'Not tested';
  const answerClass = value => (['pass', 'fail', 'na'].includes(value) ? value : 'none');
  let mountCount = 0;

  async function rpc(name, params) {
    const config = window.TECHM8_SUPABASE || {};
    const response = await fetch(`${config.url}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: config.anonKey || '',
        Authorization: `Bearer ${config.anonKey || ''}`
      },
      body: JSON.stringify(params)
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || (data && data.ok === false)) {
      throw new Error((data && data.message) || 'The pre-sale test could not be loaded or saved. Please retry.');
    }
    return data;
  }

  function intakeMarkup(data) {
    const intake = data.intake || {};
    const answers = intake.inspection || {};
    const known = new Set((data.checklist || []).map(item => item.key));
    const rows = (data.checklist || []).map(item => ({key: item.key, label: item.label}))
      .concat(Object.keys(answers).filter(key => !known.has(key)).map(key => ({key, label: key.replace(/_/g, ' ')})));
    return `
      <section class="udt-block udt-intake">
        <div class="udt-head">
          <h4><i class="bi bi-lock-fill" aria-hidden="true"></i> At purchase</h4>
          <span class="udt-locked">Locked · cannot be changed</span>
        </div>
        <p class="udt-hint">
          Recorded at the counter${intake.acquired_by ? ` by ${escape(intake.acquired_by)}` : ''}${intake.acquired_at ? ` on ${escape(when(intake.acquired_at))}` : ''}.
          Condition ${escape(intake.condition_grade || '—')} · battery ${intake.battery_health == null ? '—' : `${escape(intake.battery_health)}%`}.
        </p>
        <div class="udt-grid">
          ${rows.map(item => `
            <div class="udt-readonly">
              <span>${escape(item.label)}</span>
              <span class="udt-answer ${answerClass(answers[item.key])}">${answerLabel(answers[item.key])}</span>
            </div>
          `).join('') || '<p class="udt-hint">No checks were recorded at purchase.</p>'}
        </div>
      </section>
    `;
  }

  function latestMarkup(data) {
    const latest = (data.tests || [])[0];
    if (!latest) {
      return '<div class="udt-status udt-status-none">No pre-sale test yet. This device cannot be sold until one passes.</div>';
    }
    return data.passed
      ? `<div class="udt-status udt-status-pass"><i class="bi bi-check-circle-fill" aria-hidden="true"></i> Passed on ${escape(when(latest.tested_at))} by ${escape(latest.tested_by)}.</div>`
      : `<div class="udt-status udt-status-fail"><i class="bi bi-x-circle-fill" aria-hidden="true"></i> The latest test on ${escape(when(latest.tested_at))} did not pass${latest.failed_count ? ` (${escape(latest.failed_count)} failed)` : ''}. Fix and test again.</div>`;
  }

  function formMarkup(instance) {
    const data = instance.state.data;
    const draft = instance.state.draft;
    const name = instance.name;
    return `
      <form class="udt-form" data-udt-form>
        <div class="udt-grid">
          ${(data.checklist || []).map(item => `
            <fieldset class="udt-item ${draft.answers[item.key] ? `answered ${answerClass(draft.answers[item.key])}` : ''}">
              <legend>${escape(item.label)}</legend>
              <div class="udt-choices">
                ${ANSWERS.map(answer => `
                  <label class="udt-choice">
                    <input type="radio" name="${name}-${escape(item.key)}" value="${answer.value}" data-udt-key="${escape(item.key)}" ${draft.answers[item.key] === answer.value ? 'checked' : ''}>
                    <span>${answer.label}</span>
                  </label>
                `).join('')}
              </div>
            </fieldset>
          `).join('')}
        </div>
        <div class="udt-form-row">
          <label class="udt-field udt-battery">Battery health now %
            <input type="number" min="0" max="100" step="1" inputmode="numeric" data-udt-battery value="${escape(draft.battery)}" placeholder="Optional">
          </label>
          <label class="udt-field udt-notes">What was done, what was checked
            <textarea data-udt-notes maxlength="1000" placeholder="Optional. Example: screen replaced, all functions tested, reset and signed out.">${escape(draft.notes)}</textarea>
          </label>
        </div>
        <div class="udt-actions">
          <span class="udt-progress">${Object.keys(draft.answers).length} of ${(data.checklist || []).length} answered</span>
          <button type="submit" class="udt-save" ${instance.state.busy ? 'disabled' : ''}>
            <i class="bi bi-clipboard-check" aria-hidden="true"></i> ${instance.state.busy ? 'Saving…' : 'Save test result'}
          </button>
        </div>
      </form>
    `;
  }

  function historyMarkup(data) {
    const tests = data.tests || [];
    if (!tests.length) return '';
    return `
      <details class="udt-history">
        <summary>Every test run (${tests.length})</summary>
        <div class="udt-history-list">
          ${tests.map(test => `
            <div class="udt-run">
              <div>
                <strong class="${test.passed ? 'udt-pass-text' : 'udt-fail-text'}">${test.passed ? 'Passed' : `Failed · ${escape(test.failed_count)} check${test.failed_count === 1 ? '' : 's'}`}</strong>
                <span> · ${escape(when(test.tested_at))} · ${escape(test.tested_by)}${test.tested_by_admin ? ' (admin)' : ''}${test.battery_health == null ? '' : ` · battery ${escape(test.battery_health)}%`}</span>
              </div>
              ${test.notes ? `<p>${escape(test.notes)}</p>` : ''}
              ${test.passed ? '' : `<p class="udt-failed-list">${Object.entries(test.answers || {}).filter(([, value]) => value === 'fail')
                .map(([key]) => escape(((data.checklist || []).find(item => item.key === key) || {}).label || key)).join(' · ')}</p>`}
            </div>
          `).join('')}
        </div>
      </details>
    `;
  }

  function render(instance) {
    const {root, state, options} = instance;
    if (!root.isConnected) return;
    if (state.loading && !state.data) {
      root.innerHTML = '<div class="udt"><p class="udt-hint">Loading the pre-sale test…</p></div>';
      return;
    }
    if (!state.data) {
      root.innerHTML = `<div class="udt"><p class="udt-message" data-error="true">${escape(state.message)}</p><button type="button" class="udt-retry" data-udt-retry>Try again</button></div>`;
      return;
    }
    const data = state.data;
    root.innerHTML = `
      <div class="udt">
        ${options.showIntake === false ? '' : intakeMarkup(data)}
        <section class="udt-block">
          <div class="udt-head">
            <h4><i class="bi bi-clipboard2-pulse" aria-hidden="true"></i> Pre-sale test</h4>
          </div>
          ${latestMarkup(data)}
          ${data.writable
            ? formMarkup(instance)
            : '<p class="udt-hint">This device is no longer in stock, so it cannot be tested.</p>'}
          <p class="udt-message" data-error="${state.error ? 'true' : 'false'}" role="status">${escape(state.message)}</p>
          ${historyMarkup(data)}
        </section>
      </div>
    `;
  }

  async function load(instance) {
    const {state, options} = instance;
    state.loading = true;
    render(instance);
    try {
      state.data = await rpc('get_pos_used_device_sale_tests', {
        session_token: options.getToken(),
        target_store_code: options.storeCode,
        target_device_code: options.deviceCode
      });
      state.error = false;
    } catch (error) {
      state.error = true;
      state.message = error.message;
    } finally {
      state.loading = false;
      render(instance);
    }
  }

  async function save(instance) {
    const {state, options} = instance;
    const checklist = (state.data && state.data.checklist) || [];
    const missing = checklist.filter(item => !state.draft.answers[item.key]);
    if (missing.length) {
      state.error = true;
      state.message = `${missing.length} check${missing.length === 1 ? ' is' : 's are'} still to answer: ${missing.slice(0, 4).map(item => item.label).join(', ')}${missing.length > 4 ? '…' : ''}`;
      render(instance);
      return;
    }
    const battery = String(state.draft.battery || '').trim();
    if (battery && !(/^\d{1,3}$/.test(battery) && Number(battery) <= 100)) {
      state.error = true;
      state.message = 'Battery health is a number from 0 to 100.';
      render(instance);
      return;
    }
    state.busy = true;
    state.error = false;
    state.message = '';
    render(instance);
    try {
      const result = await rpc('record_pos_used_device_sale_test', {
        session_token: options.getToken(),
        target_store_code: options.storeCode,
        target_device_code: options.deviceCode,
        payload: {answers: state.draft.answers, battery_health: battery, notes: state.draft.notes}
      });
      state.draft = {answers: {}, battery: '', notes: ''};
      state.busy = false;
      await load(instance);
      state.error = !result.passed;
      state.message = result.passed
        ? 'Saved. The device passed and can be priced and put on sale.'
        : `Saved. ${result.failed_count} check${result.failed_count === 1 ? '' : 's'} failed, so it stays off sale${result.withdrawn ? ' and has been taken off the website' : ''}.`;
      render(instance);
      if (options.onChange) options.onChange(result);
    } catch (error) {
      state.busy = false;
      state.error = true;
      state.message = error.message;
      render(instance);
    }
  }

  function mount(root, options) {
    if (!root) return null;
    mountCount += 1;
    const instance = {
      root,
      options,
      name: `udt${mountCount}`,
      state: {data: null, loading: false, busy: false, error: false, message: '', draft: {answers: {}, battery: '', notes: ''}}
    };
    root.addEventListener('change', event => {
      const key = event.target.dataset.udtKey;
      if (!key) return;
      instance.state.draft.answers[key] = event.target.value;
      const item = event.target.closest('.udt-item');
      if (item) item.className = `udt-item answered ${answerClass(event.target.value)}`;
      const progress = root.querySelector('.udt-progress');
      if (progress) progress.textContent = `${Object.keys(instance.state.draft.answers).length} of ${(instance.state.data.checklist || []).length} answered`;
      // A "still to answer" warning is out of date the moment an answer lands.
      if (instance.state.error) {
        instance.state.error = false;
        instance.state.message = '';
        const message = root.querySelector('.udt-message');
        if (message) { message.textContent = ''; message.dataset.error = 'false'; }
      }
    });
    root.addEventListener('input', event => {
      if (event.target.matches('[data-udt-battery]')) instance.state.draft.battery = event.target.value;
      if (event.target.matches('[data-udt-notes]')) instance.state.draft.notes = event.target.value;
    });
    root.addEventListener('submit', event => {
      if (!event.target.matches('[data-udt-form]')) return;
      event.preventDefault();
      save(instance);
    });
    root.addEventListener('click', event => {
      if (event.target.closest('[data-udt-retry]')) load(instance);
    });
    load(instance);
    return instance;
  }

  window.Techm8UsedDeviceSaleTest = {mount};
})();
