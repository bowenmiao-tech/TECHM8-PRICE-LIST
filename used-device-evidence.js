(function () {
  'use strict';

  // Photographic evidence for second-hand devices, in two modes.
  //
  //   intake  - photos taken while the purchase form is still open. They are
  //             stored against a client-generated intake key and claimed by the
  //             acquisition, so a purchase cannot be saved without them.
  //   device  - evidence and the running memo for a device that already exists.
  //
  // The image handling mirrors repair-ticket-updates.js: everything is
  // re-encoded to JPEG in the browser so the endpoint only ever accepts one
  // format, and each upload carries a client-generated ID so a retry after an
  // uncertain response cannot create a second copy.

  const STAGES = [
    {key: 'intake', label: 'Intake evidence', hint: 'What was handed over: front, back, and the screen showing the IMEI or serial.'},
    {key: 'refurb', label: 'Refurbishment', hint: 'Work needed and work done. Photos before and after.'},
    {key: 'listing', label: 'Listing photos', hint: 'The photos the device is sold and advertised with.'},
    {key: 'seller_id', label: 'Seller ID', hint: 'Identity document. Visible to admin only, and every view is logged.'}
  ];
  const INTAKE_STAGES = ['intake', 'seller_id'];
  const REQUIRED_INTAKE_PHOTOS = 3;

  const mounts = new Set();
  const escape = value => String(value == null ? '' : value).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
  const icon = name => `<i class="bi bi-${name}" aria-hidden="true"></i>`;
  const date = value => (value && Number.isFinite(Date.parse(value)) ? new Date(value).toLocaleString('en-AU') : '');

  function notify(instance) {
    for (const mount of mounts) {
      if (!mount.root.isConnected) { mount.controller.abort(); mounts.delete(mount); continue; }
      if (mount === instance) mount.render();
    }
  }

  async function request(options, payload) {
    const config = window.TECHM8_SUPABASE || {};
    const token = options.getToken();
    if (!token) throw new Error('Please sign in again. Nothing has been cleared.');
    const args = {store_code: options.storeCode};
    if (options.intakeKey) args.intake_key = options.intakeKey;
    if (options.deviceCode) args.device_code = options.deviceCode;
    const url = new URL(`${config.url}/functions/v1/pos-used-device-updates`);
    if (!payload) url.search = new URLSearchParams(args).toString();
    const response = await fetch(url, {
      method: payload ? 'POST' : 'GET',
      headers: {'Content-Type': 'application/json', 'x-staff-session': token, apikey: config.anonKey || ''},
      ...(payload ? {body: JSON.stringify({...args, ...payload})} : {})
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.ok) throw new Error(data.message || 'Could not save or load device evidence. Please retry.');
    return data;
  }

  async function load(instance) {
    const state = instance.state;
    if (state.loading) { await state.loadPromise; return; }
    state.loading = true;
    notify(instance);
    state.loadPromise = (async () => {
      try {
        const data = await request(instance.options);
        state.entries = (data.updates || data.uploads || []).map(entry => ({kind: 'photo', ...entry}));
        state.writable = instance.options.intakeKey ? true : data.writable === true;
        state.isAdmin = data.is_admin === true;
        state.loaded = true;
        state.error = false;
        state.message = '';
      } catch (error) {
        state.error = true;
        state.message = error.message;
      } finally {
        state.loading = false;
        notify(instance);
        if (instance.options.onChange) instance.options.onChange(counts(state));
      }
    })();
    return state.loadPromise;
  }

  function counts(state) {
    const result = {total: 0};
    for (const stage of STAGES) result[stage.key] = 0;
    for (const entry of state.entries) {
      if (entry.kind !== 'photo') continue;
      result.total += 1;
      if (result[entry.stage] != null) result[entry.stage] += 1;
    }
    return result;
  }

  async function imageData(file) {
    if (!/^image\/(jpeg|png|webp|gif|bmp)$/.test(file.type)) throw new Error('Choose a JPG, PNG, WebP, GIF or BMP image.');
    if (file.size > 20 * 1024 * 1024) throw new Error('Each image must be under 20 MB.');
    let bitmap;
    try { bitmap = await createImageBitmap(file); }
    catch (_) { throw new Error('This image could not be opened. Try a JPG or PNG photo.'); }
    try {
      const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      const context = canvas.getContext('2d');
      context.fillStyle = '#fff';
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      for (const quality of [0.9, 0.75, 0.55]) {
        const data = canvas.toDataURL('image/jpeg', quality);
        if (data.length < 4100000) return data;
      }
      throw new Error('The image is too large. Try a smaller photo.');
    } finally { bitmap.close(); }
  }

  async function upload(instance, stage, files) {
    const state = instance.state;
    if (state.busy || !state.writable) return;
    if (files) {
      if (files.length > 10) {
        state.error = true;
        state.message = 'Choose up to 10 images at a time.';
        notify(instance);
        return;
      }
      state.queue.push(...files.map(file => ({file, stage, id: crypto.randomUUID()})));
    }
    if (!state.queue.length) return;
    state.busy = true;
    state.error = false;
    try {
      while (state.queue.length) {
        const item = state.queue[0];
        state.message = `Uploading ${item.file.name || 'photo'} (${state.queue.length} remaining)...`;
        notify(instance);
        item.data = item.data || await imageData(item.file);
        await request(instance.options, {
          id: item.id, kind: 'photo', stage: item.stage,
          data_url: item.data, file_name: item.file.name || 'Device photo.jpg'
        });
        state.queue.shift();
      }
      await load(instance);
      if (!state.error) state.message = 'Photos saved.';
    } catch (error) {
      state.error = true;
      state.message = error.message;
    } finally {
      state.busy = false;
      notify(instance);
    }
  }

  async function saveComment(instance) {
    const state = instance.state;
    const body = state.draft.trim();
    if (!body || state.busy || !state.writable) return;
    state.busy = true;
    state.error = false;
    state.message = 'Saving note...';
    if (!state.pendingComment || state.pendingComment.body !== body) {
      state.pendingComment = {kind: 'comment', stage: state.commentStage, id: crypto.randomUUID(), body};
    }
    notify(instance);
    try {
      await request(instance.options, state.pendingComment);
      state.draft = '';
      state.pendingComment = null;
      await load(instance);
      if (!state.error) state.message = 'Note saved.';
    } catch (error) {
      state.error = true;
      state.message = error.message;
    } finally {
      state.busy = false;
      notify(instance);
    }
  }

  function mount(root, options) {
    if (!root) return null;
    for (const old of mounts) {
      if (old.root === root || !old.root.isConnected) { old.controller.abort(); mounts.delete(old); }
    }
    const intakeMode = Boolean(options.intakeKey);
    const stages = STAGES.filter(stage => (intakeMode ? INTAKE_STAGES.includes(stage.key) : true));
    const state = {
      entries: [], queue: [], draft: '', writable: intakeMode, isAdmin: false,
      commentStage: 'refurb', activeStage: stages[0].key
    };
    const controller = new AbortController();
    const instance = {root, options, state, render, controller, reload: () => load(instance)};
    mounts.add(instance);

    root.classList.add('ude');
    root.innerHTML = `
      <div class="ude-tabs" role="tablist">${stages.map(stage => `
        <button type="button" role="tab" data-stage="${stage.key}">${escape(stage.label)} <span data-stage-count="${stage.key}">0</span></button>
      `).join('')}</div>
      <p class="ude-hint"></p>
      <div class="ude-toolbar">
        <button type="button" data-action="upload">${icon('camera')} Add photos</button>
        <input type="file" accept="image/jpeg,image/png,image/webp,image/gif,image/bmp" capture="environment" multiple hidden aria-label="Add device photos">
        <button type="button" data-action="retry" hidden>${icon('arrow-repeat')} Retry upload</button>
        <button type="button" data-action="clear" hidden>${icon('x-lg')} Clear pending</button>
        <button type="button" data-action="refresh" title="Refresh">${icon('arrow-clockwise')}</button>
      </div>
      <p class="ude-status" role="status" aria-live="polite"></p>
      <div class="ude-gallery"></div>
      ${intakeMode ? '' : `
        <div class="ude-memo">
          <textarea maxlength="5000" aria-label="Device note" placeholder="Add a note - what needs repairing, what was replaced, what it cost"></textarea>
          <button type="button" data-action="save-note">${icon('send')} Save note</button>
        </div>
      `}
    `;

    const textarea = root.querySelector('textarea');
    if (textarea) {
      textarea.addEventListener('input', () => { state.draft = textarea.value; }, {signal: controller.signal});
    }

    function render() {
      const readonly = !state.writable;
      const tally = counts(state);
      const active = stages.find(stage => stage.key === state.activeStage) || stages[0];
      root.querySelectorAll('[data-stage]').forEach(button => {
        button.classList.toggle('active', button.dataset.stage === state.activeStage);
        button.hidden = button.dataset.stage === 'seller_id' && !intakeMode && !state.isAdmin;
      });
      root.querySelectorAll('[data-stage-count]').forEach(node => {
        node.textContent = String(tally[node.dataset.stageCount] || 0);
      });
      root.querySelector('.ude-hint').textContent = active.hint;
      root.querySelectorAll('.ude-toolbar button, .ude-memo button').forEach(button => {
        button.disabled = Boolean(state.busy || (button.dataset.action !== 'refresh' && readonly));
      });
      root.querySelectorAll('[data-action="retry"], [data-action="clear"]').forEach(button => {
        button.hidden = !state.queue.length || Boolean(state.busy);
      });
      if (textarea) {
        textarea.disabled = Boolean(readonly || state.busy);
        if (textarea.value !== state.draft) textarea.value = state.draft;
      }
      const status = root.querySelector('.ude-status');
      status.textContent = state.message || (state.loading ? 'Loading...' : readonly ? 'Read-only record' : '');
      status.dataset.error = String(Boolean(state.error));

      const entries = state.entries.slice().sort((a, b) => (Date.parse(b.created_at) || 0) - (Date.parse(a.created_at) || 0));
      const meta = entry => `<div class="ude-meta"><strong>${escape(entry.author)}</strong><time>${escape(date(entry.created_at))}</time></div>`;
      const photos = entries.filter(entry => entry.kind === 'photo' && entry.stage === state.activeStage);
      const notes = entries.filter(entry => entry.kind === 'comment');
      root.querySelector('.ude-gallery').innerHTML = photos.map(entry => {
        const url = /^https?:\/\//.test(entry.image_url || '') ? entry.image_url : '';
        return `<figure class="ude-photo"><a href="${escape(url)}" target="_blank" rel="noopener noreferrer" title="Open photo"><img src="${escape(url)}" alt="${escape(entry.file_name || 'Device photo')}" loading="lazy"></a>${meta(entry)}</figure>`;
      }).join('') || (state.loaded ? `<p class="ude-empty">No ${escape(active.label.toLowerCase())} yet.</p>` : '');
      const list = root.querySelector('.ude-list');
      if (list) {
        list.innerHTML = notes.map(entry => `<article class="ude-note">${meta(entry)}<p>${escape(entry.body)}</p></article>`).join('')
          || (state.loaded ? '<p class="ude-empty">No notes yet.</p>' : '');
      }
    }

    if (!intakeMode) {
      root.querySelector('.ude-memo').insertAdjacentHTML('afterend', '<div class="ude-list"></div>');
    }

    root.querySelector('input[type=file]').addEventListener('change', event => {
      const files = Array.from(event.target.files);
      event.target.value = '';
      upload(instance, state.activeStage, files);
    }, {signal: controller.signal});

    root.addEventListener('click', event => {
      const stageButton = event.target.closest('[data-stage]');
      if (stageButton) {
        state.activeStage = stageButton.dataset.stage;
        state.commentStage = stageButton.dataset.stage === 'seller_id' ? 'refurb' : stageButton.dataset.stage;
        notify(instance);
        return;
      }
      const action = event.target.closest('[data-action]')?.dataset.action;
      if (!action || state.busy) return;
      if (action === 'refresh') return load(instance);
      if (action === 'upload') return root.querySelector('input[type=file]').click();
      if (action === 'retry') return upload(instance);
      if (action === 'save-note') return saveComment(instance);
      if (action === 'clear') {
        state.queue = [];
        state.message = '';
        state.error = false;
        notify(instance);
      }
    }, {signal: controller.signal});

    render();
    load(instance);
    return instance;
  }

  window.Techm8UsedDeviceEvidence = {mount, REQUIRED_INTAKE_PHOTOS, STAGES};
})();
