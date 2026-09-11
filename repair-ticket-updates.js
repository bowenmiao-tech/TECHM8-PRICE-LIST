(function () {
  'use strict';
  const states = new Map();
  const mounts = new Set();
  const escape = value => String(value == null ? '' : value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const icon = name => `<i class="bi bi-${name}" aria-hidden="true"></i>`;
  const date = value => value && Number.isFinite(Date.parse(value)) ? new Date(value).toLocaleString('en-AU') : '';
  function stateFor(options) {
    const key = `${options.storeCode}/${options.ticketCode}`;
    if (!states.has(key)) states.set(key, {entries: [], draft: '', queue: [], writable: false});
    return states.get(key);
  }
  function notify(state) {
    for (const mount of mounts) {
      if (!mount.root.isConnected) { mount.controller.abort(); mounts.delete(mount); continue; }
      if (mount.state === state) mount.render();
    }
  }
  async function request(options, payload) {
    const config = window.TECHM8_SUPABASE || {};
    const token = options.getToken();
    if (!token) throw new Error('Please sign in again. Your comment has not been cleared.');
    const args = {store_code: options.storeCode, ticket_code: options.ticketCode};
    const url = new URL(`${config.url}/functions/v1/pos-repair-updates`);
    if (!payload) url.search = new URLSearchParams(args).toString();
    const response = await fetch(url, {
      method: payload ? 'POST' : 'GET',
      headers: {'Content-Type': 'application/json', 'x-staff-session': token, apikey: config.anonKey || ''},
      ...(payload ? {body: JSON.stringify({...args, ...payload})} : {})
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.ok) throw new Error(data.message || 'Could not save or load repair updates. Please retry.');
    return data;
  }
  async function load(mount) {
    const state = mount.state;
    if (state.loading) { await state.loadPromise; return load(mount); }
    state.loading = true;
    notify(state);
    state.loadPromise = (async () => {
    try {
      const data = await request(mount.options);
      state.entries = data.updates || [];
      state.writable = data.writable === true;
      state.loaded = true;
      state.error = false;
      state.message = '';
    } catch (error) { state.error = true; state.message = error.message; }
    finally { state.loading = false; notify(state); }
    })();
    return state.loadPromise;
  }
  async function imageData(file) {
    if (!/^image\/(jpeg|png|webp|gif|bmp)$/.test(file.type)) throw new Error('Choose a JPG, PNG, WebP, GIF or BMP image.');
    if (file.size > 20 * 1024 * 1024) throw new Error('Each image must be under 20 MB.');
    let bitmap;
    try { bitmap = await createImageBitmap(file); }
    catch (_) { throw new Error('This image could not be opened. Try a JPG or PNG screenshot.'); }
    try {
      const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      for (const quality of [0.9, 0.75, 0.55]) {
        const data = canvas.toDataURL('image/jpeg', quality);
        if (data.length < 4100000) return data;
      }
      throw new Error('The image is too large. Try a smaller screenshot.');
    } finally { bitmap.close(); }
  }
  async function upload(mount, files) {
    const state = mount.state;
    if (state.busy || !state.writable || mount.options.readonly) return;
    if (files) {
      if (files.length > 10) { state.error = true; state.message = 'Choose up to 10 images at a time.'; notify(state); return; }
      state.queue.push(...files.map(file => ({file, id: crypto.randomUUID()})));
    }
    if (!state.queue.length) return;
    state.busy = true; state.error = false;
    try {
      while (state.queue.length) {
        const item = state.queue[0];
        const fileName = item.file?.name || item.fileName || 'Screenshot.jpg';
        state.message = `Uploading ${fileName} (${state.queue.length} remaining)...`; notify(state);
        item.data = item.data || await imageData(item.file);
        await request(mount.options, {id: item.id, kind: 'photo', data_url: item.data, file_name: fileName});
        state.queue.shift();
      }
      await load(mount);
      if (!state.error) state.message = 'Images saved.';
    } catch (error) { state.error = true; state.message = error.message; }
    finally { state.busy = false; notify(state); }
  }
  function mount(root, options) {
    if (!root) return;
    for (const old of mounts) if (old.root === root || !old.root.isConnected) { old.controller.abort(); mounts.delete(old); }
    const state = stateFor(options);
    const controller = new AbortController();
    const instance = {root, options, state, render, controller};
    mounts.add(instance);
    const comments = options.mode !== 'photos';
    const photos = options.mode !== 'comments';
    root.classList.add('rtu');
    root.innerHTML = `<header><h3>${comments ? 'Comments' : 'Images'}</h3><button type="button" data-action="refresh" title="Refresh comments and images" aria-label="Refresh comments and images">${icon('arrow-clockwise')}</button></header>
      ${comments ? '<textarea maxlength="5000" aria-label="Ticket comment" placeholder="Add a comment"></textarea>' : ''}
      <div class="rtu-toolbar">
        ${comments ? `<button type="button" class="rtu-save" data-action="save">${icon('send')} Save comment</button>` : ''}
        ${photos ? `<button type="button" data-action="upload">${icon('image')} Upload images</button><button type="button" data-action="paste">${icon('clipboard')} Paste screenshot</button><input type="file" accept="image/jpeg,image/png,image/webp,image/gif,image/bmp" multiple hidden aria-label="Upload ticket images"><button type="button" data-action="retry" hidden>${icon('arrow-repeat')} Retry upload</button><button type="button" data-action="clear" hidden>${icon('x-lg')} Clear pending</button>` : ''}
      </div><p class="rtu-status" role="status" aria-live="polite"></p>
      ${photos ? '<div class="rtu-gallery"></div>' : ''}${comments ? '<div class="rtu-list"></div>' : ''}`;
    const textarea = root.querySelector('textarea');
    if (textarea) {
      textarea.value = state.draft;
      textarea.addEventListener('input', () => { state.draft = textarea.value; }, {signal: controller.signal});
    }
    function render() {
      const readonly = options.readonly || !state.writable;
      root.querySelectorAll('button').forEach(button => {
        button.disabled = Boolean(state.busy || (button.dataset.action !== 'refresh' && readonly));
      });
      if (textarea) { textarea.disabled = Boolean(readonly || state.busy); if (textarea.value !== state.draft) textarea.value = state.draft; }
      root.querySelectorAll('[data-action="retry"], [data-action="clear"]').forEach(button => { button.hidden = !state.queue.length || Boolean(state.busy); });
      const status = root.querySelector('.rtu-status');
      status.textContent = state.message || (state.loading ? 'Loading...' : options.readonly ? 'Read-only ticket' : '');
      status.dataset.error = String(Boolean(state.error));
      const entries = state.entries.slice().sort((a, b) => (Date.parse(b.created_at) || 0) - (Date.parse(a.created_at) || 0));
      const meta = entry => `<div class="rtu-meta"><strong>${escape(entry.author)}</strong><time>${escape(date(entry.created_at))}</time></div>`;
      if (comments) root.querySelector('.rtu-list').innerHTML = entries.filter(entry => entry.kind === 'comment').map(entry => `<article class="rtu-comment">${meta(entry)}<p>${escape(entry.body)}</p></article>`).join('') || (state.loaded ? '<p class="rtu-empty">No comments yet.</p>' : '');
      if (photos) root.querySelector('.rtu-gallery').innerHTML = entries.filter(entry => entry.kind === 'photo').map(entry => {
        const url = /^https?:\/\//.test(entry.image_url || '') ? entry.image_url : '';
        return `<div class="rtu-photo"><a href="${escape(url)}" target="_blank" rel="noopener noreferrer" title="Open image"><img src="${escape(url)}" alt="${escape(entry.file_name || 'Repair image')}" loading="lazy"></a>${meta(entry)}</div>`;
      }).join('');
    }
    root.querySelector('input[type=file]')?.addEventListener('change', event => {
      const files = Array.from(event.target.files); event.target.value = ''; upload(instance, files);
    }, {signal: controller.signal});
    root.addEventListener('click', async event => {
      const action = event.target.closest('[data-action]')?.dataset.action;
      if (!action || state.busy) return;
      if (action === 'refresh') return load(instance);
      if (action === 'upload') return root.querySelector('input[type=file]').click();
      if (action === 'retry') return upload(instance);
      if (action === 'clear') { state.queue = []; state.message = ''; state.error = false; notify(state); return; }
      if (action === 'paste') {
        try {
          if (!navigator.clipboard?.read) throw new Error('Click here and paste your screenshot with Ctrl+V, or upload an image file.');
          const items = await navigator.clipboard.read();
          const files = [];
          for (const item of items) {
            const type = item.types.find(type => type.startsWith('image/'));
            if (type) files.push(new File([await item.getType(type)], 'Screenshot.png', {type}));
          }
          if (!files.length) throw new Error('No screenshot found in the clipboard.');
          return upload(instance, files);
        } catch (error) { state.error = true; state.message = error.name === 'NotAllowedError' ? 'Clipboard access was blocked. Paste with Ctrl+V or upload an image file.' : error.message; notify(state); }
      }
      if (action === 'save') {
        const body = state.draft.trim();
        if (!body) return;
        state.busy = true; state.error = false; state.message = 'Saving comment...';
        if (!state.pendingComment || state.pendingComment.body !== body) state.pendingComment = {kind: 'comment', id: crypto.randomUUID(), body};
        notify(state);
        try {
          await request(options, state.pendingComment);
          state.draft = ''; state.pendingComment = null;
          await load(instance); if (!state.error) state.message = 'Comment saved.';
        } catch (error) { state.error = true; state.message = error.message; }
        finally { state.busy = false; notify(state); }
      }
    }, {signal: controller.signal});
    render(); load(instance);
    return instance;
  }
  async function uploadPrepared(options, images) {
    const state = stateFor(options);
    const prepared = (Array.isArray(images) ? images : []).filter(item => item && item.data);
    if (!prepared.length) return {ok: true, message: '', pending: state.queue.length};
    if (state.queue.length + prepared.length > 10) {
      state.error = true;
      state.message = 'Choose up to 10 images at a time.';
      notify(state);
      return {ok: false, message: state.message, pending: state.queue.length};
    }
    state.writable = true;
    state.queue.push(...prepared.map(item => ({
      id: item.id || crypto.randomUUID(),
      data: item.data,
      fileName: item.fileName || 'Screenshot.jpg'
    })));
    await upload({state, options});
    return {ok: !state.error && state.queue.length === 0, message: state.message, pending: state.queue.length};
  }
  // Route image paste to the open ticket only; ordinary text paste is untouched.
  document.addEventListener('paste', event => {
    const files = Array.from(event.clipboardData?.items || []).filter(item => item.kind === 'file' && item.type.startsWith('image/')).map(item => item.getAsFile()).filter(Boolean);
    if (!files.length) return;
    const scope = event.target.closest('dialog, [role=dialog], .modal, .modal-backdrop') || event.target.closest('.rtu');
    const target = [...mounts].reverse().find(item => item.root.isConnected && item.options.mode !== 'comments' && scope?.contains(item.root) && item.root.getClientRects().length);
    if (!target) return;
    event.preventDefault(); upload(target, files);
  });
  window.Techm8RepairUpdates = {mount, prepareImage: imageData, uploadPrepared};
})();
