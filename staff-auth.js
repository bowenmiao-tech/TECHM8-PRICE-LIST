window.Techm8StaffAuth = (function () {
  const SUPABASE = window.TECHM8_SUPABASE || null;
  const DEFAULT_SESSION_KEY = 'techm8_staff_session_token';
  const DEFAULT_PROFILE_KEY = 'techm8_staff_session_profile';
  let activeSessionKey = DEFAULT_SESSION_KEY;
  let activeCreateRpc = 'create_staff_session';
  let activeVerifyRpc = 'verify_staff_session';
  let activeRevokeRpc = 'revoke_staff_session';

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  function expiryKey() {
    return activeSessionKey + '_expires_at';
  }

  function profileKey() {
    return activeSessionKey === DEFAULT_SESSION_KEY
      ? DEFAULT_PROFILE_KEY
      : activeSessionKey + '_profile';
  }

  function sessionStores() {
    return activeSessionKey === DEFAULT_SESSION_KEY
      ? [sessionStorage, localStorage]
      : [sessionStorage];
  }

  function getToken() {
    for (const storage of sessionStores()) {
      const token = storage.getItem(activeSessionKey) || '';
      if (!token) continue;
      const expiresAt = storage.getItem(expiryKey()) || '';
      if (expiresAt && Date.parse(expiresAt) <= Date.now()) {
        storage.removeItem(activeSessionKey);
        storage.removeItem(expiryKey());
        storage.removeItem(profileKey());
        continue;
      }
      if (activeSessionKey === DEFAULT_SESSION_KEY && storage === localStorage) {
        sessionStorage.setItem(activeSessionKey, token);
        if (expiresAt) sessionStorage.setItem(expiryKey(), expiresAt);
      }
      return token;
    }
    return '';
  }

  function setToken(token, expiresAt) {
    if (!token) return;
    sessionStores().forEach(storage => {
      storage.setItem(activeSessionKey, token);
      if (expiresAt) storage.setItem(expiryKey(), expiresAt);
      else storage.removeItem(expiryKey());
    });
  }

  function getProfile() {
    for (const storage of sessionStores()) {
      try {
        const profile = JSON.parse(storage.getItem(profileKey()) || 'null');
        if (profile) return profile;
      } catch (error) {
        storage.removeItem(profileKey());
      }
    }
    return null;
  }

  function setProfile(profile) {
    if (!profile) return;
    const storedProfile = JSON.stringify({
      staff_id: profile.staff_id,
      staff_name: profile.staff_name || '',
      staff_email: profile.staff_email || '',
      job_role: profile.job_role || '',
      must_change_credentials: Boolean(profile.must_change_credentials)
    });
    sessionStores().forEach(storage => storage.setItem(profileKey(), storedProfile));
  }

  function clearToken() {
    sessionStores().forEach(storage => {
      storage.removeItem(activeSessionKey);
      storage.removeItem(expiryKey());
      storage.removeItem(profileKey());
    });
  }

  async function callRpc(name, payload) {
    if (!SUPABASE) {
      throw new Error('Supabase config is missing.');
    }

    const response = await fetch(SUPABASE.url + '/rest/v1/rpc/' + name, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: SUPABASE.anonKey,
        Authorization: 'Bearer ' + SUPABASE.anonKey
      },
      body: JSON.stringify(payload || {})
    });

    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error((result && result.message) || 'Authentication request failed.');
    }
    return result;
  }

  function injectStyles() {
    if (document.getElementById('techm8-auth-style')) return;

    const style = document.createElement('style');
    style.id = 'techm8-auth-style';
    style.textContent = `
      [data-auth-protected] {
        visibility: hidden;
      }
      [data-auth-protected].tm-auth-ready {
        visibility: visible;
      }
      .tm-auth-overlay {
        position: fixed;
        inset: 0;
        z-index: 99999;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 20px;
        background: rgba(9, 18, 24, 0.48);
        backdrop-filter: blur(8px);
      }
      .tm-auth-card {
        width: min(460px, 100%);
        background: #ffffff;
        border-radius: 24px;
        border: 1px solid #d8e1e6;
        box-shadow: 0 24px 60px rgba(10, 20, 30, 0.18);
        padding: 24px;
        color: #16242b;
        font-family: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      }
      .tm-auth-title {
        margin: 0 0 8px;
        font-size: 30px;
        line-height: 1.1;
        font-weight: 800;
      }
      .tm-auth-text {
        margin: 0 0 18px;
        color: #667781;
        font-size: 14px;
        line-height: 1.7;
      }
      .tm-auth-input {
        width: 100%;
        min-height: 52px;
        border-radius: 16px;
        border: 1px solid #cfd9de;
        padding: 0 14px;
        font-size: 16px;
        outline: none;
      }
      .tm-auth-button {
        width: 100%;
        min-height: 52px;
        border: 0;
        border-radius: 16px;
        background: #163129;
        color: #fff;
        font-size: 16px;
        font-weight: 700;
        cursor: pointer;
      }
      .tm-auth-error {
        min-height: 20px;
        margin-top: 12px;
        color: #c63d2f;
        font-size: 13px;
      }
      .tm-auth-stack {
        display: grid;
        gap: 12px;
      }
      .tm-auth-account {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 12px 14px;
        border-radius: 16px;
        color: #164f43;
        background: #edf9f6;
        border: 1px solid #cae8e1;
        font-size: 13px;
        font-weight: 800;
      }
      .tm-auth-row {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 12px;
      }
      .tm-auth-label {
        display: grid;
        gap: 7px;
        color: #42545d;
        font-size: 12px;
        font-weight: 800;
      }
      .tm-auth-extra {
        margin: 0 0 18px;
        display: grid;
        gap: 12px;
      }
      .tm-auth-note {
        padding: 14px 16px;
        border-radius: 16px;
        background: #f5f8fa;
        border: 1px solid #d8e1e6;
        color: #42545d;
        font-size: 13px;
        line-height: 1.7;
      }
      .tm-auth-link {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 10px;
        min-height: 48px;
        padding: 0 16px;
        border-radius: 16px;
        background: #eef4f7;
        border: 1px solid #d8e1e6;
        color: #163129;
        text-decoration: none;
        font-size: 14px;
        font-weight: 700;
      }
      @media (max-width: 520px) {
        .tm-auth-row { grid-template-columns: 1fr; }
      }
    `;
    document.head.appendChild(style);
  }

  function buildOverlay(options, onSubmit) {
    const overlay = document.createElement('div');
    const hasLoginEmail = !options || options.requireLoginEmail !== false;
    const loginInputType = (options && options.loginInputType) || 'email';
    overlay.className = 'tm-auth-overlay';
    overlay.innerHTML = `
      <div class="tm-auth-card">
        <h1 class="tm-auth-title">${options.title || 'Staff Access'}</h1>
        <p class="tm-auth-text">${options.subtitle || 'Enter the staff password to continue.'}</p>
        ${options.extraHtml ? `<div class="tm-auth-extra">${options.extraHtml}</div>` : ''}
        <div class="tm-auth-stack">
          ${hasLoginEmail ? `<input class="tm-auth-input tm-auth-email" type="${loginInputType}" placeholder="${options.loginPlaceholder || 'Account'}" autocomplete="username">` : ''}
          <input class="tm-auth-input" type="password" placeholder="Password" autocomplete="current-password">
          <button class="tm-auth-button" type="button">${options.buttonLabel || 'Unlock'}</button>
          <div class="tm-auth-error"></div>
        </div>
      </div>
    `;

    const input = overlay.querySelector('.tm-auth-input[type="password"]');
    const emailInput = overlay.querySelector('.tm-auth-email');
    const button = overlay.querySelector('.tm-auth-button');
    const error = overlay.querySelector('.tm-auth-error');

    async function submit() {
      const password = input.value.trim();
      const loginEmail = emailInput ? emailInput.value.trim() : '';
      if (hasLoginEmail && !loginEmail) {
        error.textContent = 'Account is required.';
        return;
      }
      if (!password) {
        error.textContent = 'Password is required.';
        return;
      }

      button.disabled = true;
      button.textContent = 'Checking...';
      error.textContent = '';

      try {
        await onSubmit({
          password,
          loginEmail
        });
        overlay.remove();
      } catch (submitError) {
        error.textContent = submitError.message || 'Login failed.';
      } finally {
        button.disabled = false;
        button.textContent = options.buttonLabel || 'Unlock';
      }
    }

    button.addEventListener('click', submit);
    [input, emailInput].filter(Boolean).forEach(field => field.addEventListener('keydown', event => {
      if (event.key === 'Enter') submit();
    }));

    document.body.appendChild(overlay);
    (emailInput || input).focus();
  }

  function buildCredentialSetupOverlay(profile, onSubmit) {
    const overlay = document.createElement('div');
    overlay.className = 'tm-auth-overlay';
    overlay.innerHTML = `
      <form class="tm-auth-card" autocomplete="off">
        <h1 class="tm-auth-title">Secure Your Account</h1>
        <p class="tm-auth-text">This is your first login. Replace the temporary password and create your personal four-digit POS PIN.</p>
        <div class="tm-auth-account"><i class="bi bi-person-check"></i><span>${escapeHtml(profile.staff_name || profile.staff_email || 'Staff account')}</span></div>
        <div class="tm-auth-stack" style="margin-top:14px">
          <label class="tm-auth-label">New account password<input class="tm-auth-input tm-auth-new-password" type="password" minlength="8" autocomplete="new-password" placeholder="At least 8 characters" required></label>
          <label class="tm-auth-label">Confirm account password<input class="tm-auth-input tm-auth-confirm-password" type="password" minlength="8" autocomplete="new-password" placeholder="Repeat your password" required></label>
          <div class="tm-auth-row">
            <label class="tm-auth-label">New 4-digit PIN<input class="tm-auth-input tm-auth-new-pin" type="password" inputmode="numeric" maxlength="4" pattern="[0-9]{4}" autocomplete="new-password" placeholder="4 digits" required></label>
            <label class="tm-auth-label">Confirm PIN<input class="tm-auth-input tm-auth-confirm-pin" type="password" inputmode="numeric" maxlength="4" pattern="[0-9]{4}" autocomplete="new-password" placeholder="Repeat PIN" required></label>
          </div>
          <button class="tm-auth-button" type="submit">Save & Continue</button>
          <div class="tm-auth-error"></div>
        </div>
      </form>
    `;

    const form = overlay.querySelector('form');
    const passwordInput = overlay.querySelector('.tm-auth-new-password');
    const confirmPasswordInput = overlay.querySelector('.tm-auth-confirm-password');
    const pinInput = overlay.querySelector('.tm-auth-new-pin');
    const confirmPinInput = overlay.querySelector('.tm-auth-confirm-pin');
    const button = overlay.querySelector('.tm-auth-button');
    const error = overlay.querySelector('.tm-auth-error');

    form.addEventListener('submit', async event => {
      event.preventDefault();
      const password = passwordInput.value;
      const confirmPassword = confirmPasswordInput.value;
      const pin = pinInput.value.trim();
      const confirmPin = confirmPinInput.value.trim();
      if (password.length < 8) {
        error.textContent = 'Password must be at least 8 characters.';
        passwordInput.focus();
        return;
      }
      if (password === '123456') {
        error.textContent = 'Choose a password different from the temporary password.';
        passwordInput.focus();
        return;
      }
      if (password !== confirmPassword) {
        error.textContent = 'The account passwords do not match.';
        confirmPasswordInput.focus();
        return;
      }
      if (!/^\d{4}$/.test(pin)) {
        error.textContent = 'PIN must contain exactly four digits.';
        pinInput.focus();
        return;
      }
      if (pin !== confirmPin) {
        error.textContent = 'The PINs do not match.';
        confirmPinInput.focus();
        return;
      }

      button.disabled = true;
      button.textContent = 'Saving...';
      error.textContent = '';
      try {
        await onSubmit({ password, pin });
        overlay.remove();
      } catch (submitError) {
        error.textContent = submitError.message || 'Credentials could not be updated.';
      } finally {
        button.disabled = false;
        button.textContent = 'Save & Continue';
      }
    });

    document.body.appendChild(overlay);
    passwordInput.focus();
  }

  async function verifyExistingSession() {
    const token = getToken();
    if (!token) return null;

    try {
      const result = await callRpc(activeVerifyRpc, { session_token: token });
      if (result && result.ok) {
        setProfile(result);
        return result;
      }
    } catch (error) {
      console.error(error);
    }

    clearToken();
    return null;
  }

  async function login(loginEmail, password) {
    activeSessionKey = DEFAULT_SESSION_KEY;
    activeCreateRpc = 'create_staff_session';
    activeVerifyRpc = 'verify_staff_session';
    activeRevokeRpc = 'revoke_staff_session';
    const result = await callRpc(activeCreateRpc, {
      login_email: String(loginEmail || '').trim(),
      input_password: password || ''
    });
    if (!result || !result.ok || !result.session_token) {
      throw new Error((result && result.message) || 'Incorrect email or password.');
    }
    setToken(result.session_token, result.expires_at);
    setProfile(result);
    return result;
  }

  async function completeFirstLogin(newPassword, newPin) {
    const token = getToken();
    if (!token) throw new Error('Your login session has expired. Please sign in again.');
    const result = await callRpc('change_staff_credentials', {
      session_token: token,
      new_password: newPassword,
      new_pin: newPin
    });
    if (!result || !result.ok) {
      throw new Error((result && result.message) || 'Credentials could not be updated.');
    }
    setProfile(result);
    return result;
  }

  async function ensureCredentialsComplete(profile) {
    if (!profile || !profile.must_change_credentials) return profile;
    injectStyles();
    return await new Promise(resolve => {
      buildCredentialSetupOverlay(profile, async credentials => {
        const updated = await completeFirstLogin(credentials.password, credentials.pin);
        resolve(updated);
      });
    });
  }

  async function init(options) {
    injectStyles();

    const settings = options || {};
    const protectedRoot = document.querySelector(settings.rootSelector || '[data-auth-protected]');
    activeSessionKey = settings.sessionKey || DEFAULT_SESSION_KEY;
    activeCreateRpc = settings.createRpc || 'create_staff_session';
    activeVerifyRpc = settings.verifyRpc || 'verify_staff_session';
    activeRevokeRpc = settings.revokeRpc || 'revoke_staff_session';

    const existingSession = await verifyExistingSession();
    if (existingSession) {
      await ensureCredentialsComplete(existingSession);
      if (protectedRoot) protectedRoot.classList.add('tm-auth-ready');
      return true;
    }

    const loginResult = await new Promise(resolve => {
      buildOverlay(settings, async credentials => {
        const payload = settings.requireLoginEmail !== false
          ? {
              login_email: credentials.loginEmail,
              input_password: credentials.password
            }
          : {
              input_password: credentials.password
            };
        const result = await callRpc(activeCreateRpc, payload);
        if (!result || !result.ok || !result.session_token) {
          throw new Error((result && result.message) || 'Incorrect password.');
        }
        setToken(result.session_token, result.expires_at);
        setProfile(result);
        resolve(result);
      });
    });
    await ensureCredentialsComplete(loginResult);
    if (protectedRoot) protectedRoot.classList.add('tm-auth-ready');
    return true;
  }

  async function logout(options) {
    const token = getToken();
    if (token) {
      try {
        await callRpc(activeRevokeRpc, { session_token: token });
      } catch (error) {
        console.error(error);
      }
    }
    clearToken();
    const redirectTo = options && options.redirectTo;
    if (redirectTo) window.location.href = redirectTo;
    else window.location.reload();
  }

  return {
    init,
    getToken,
    getProfile,
    login,
    verify: verifyExistingSession,
    completeFirstLogin,
    ensureCredentialsComplete,
    callRpc,
    logout
  };
})();
