window.Techm8StaffAuth = (function () {
  const SUPABASE = window.TECHM8_SUPABASE || null;
  const SESSION_KEY = 'techm8_staff_session_token';

  function getToken() {
    return sessionStorage.getItem(SESSION_KEY) || '';
  }

  function setToken(token) {
    if (token) {
      sessionStorage.setItem(SESSION_KEY, token);
    }
  }

  function clearToken() {
    sessionStorage.removeItem(SESSION_KEY);
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
    `;
    document.head.appendChild(style);
  }

  function buildOverlay(options, onSubmit) {
    const overlay = document.createElement('div');
    overlay.className = 'tm-auth-overlay';
    overlay.innerHTML = `
      <div class="tm-auth-card">
        <h1 class="tm-auth-title">${options.title || 'Staff Access'}</h1>
        <p class="tm-auth-text">${options.subtitle || 'Enter the staff password to continue.'}</p>
        <div class="tm-auth-stack">
          <input class="tm-auth-input" type="password" placeholder="Password" autocomplete="current-password">
          <button class="tm-auth-button" type="button">${options.buttonLabel || 'Unlock'}</button>
          <div class="tm-auth-error"></div>
        </div>
      </div>
    `;

    const input = overlay.querySelector('.tm-auth-input');
    const button = overlay.querySelector('.tm-auth-button');
    const error = overlay.querySelector('.tm-auth-error');

    async function submit() {
      const password = input.value.trim();
      if (!password) {
        error.textContent = 'Password is required.';
        return;
      }

      button.disabled = true;
      button.textContent = 'Checking...';
      error.textContent = '';

      try {
        await onSubmit(password);
        overlay.remove();
      } catch (submitError) {
        error.textContent = submitError.message || 'Login failed.';
      } finally {
        button.disabled = false;
        button.textContent = options.buttonLabel || 'Unlock';
      }
    }

    button.addEventListener('click', submit);
    input.addEventListener('keydown', event => {
      if (event.key === 'Enter') submit();
    });

    document.body.appendChild(overlay);
    input.focus();
  }

  async function verifyExistingSession() {
    const token = getToken();
    if (!token) return false;

    try {
      const result = await callRpc('verify_staff_session', { session_token: token });
      if (result && result.ok) return true;
    } catch (error) {
      console.error(error);
    }

    clearToken();
    return false;
  }

  async function init(options) {
    injectStyles();

    const settings = options || {};
    if (await verifyExistingSession()) {
      return true;
    }

    return await new Promise(resolve => {
      buildOverlay(settings, async password => {
        const result = await callRpc('create_staff_session', { input_password: password });
        if (!result || !result.ok || !result.session_token) {
          throw new Error((result && result.message) || 'Incorrect password.');
        }
        setToken(result.session_token);
        resolve(true);
      });
    });
  }

  async function logout() {
    const token = getToken();
    if (token) {
      try {
        await callRpc('revoke_staff_session', { session_token: token });
      } catch (error) {
        console.error(error);
      }
    }
    clearToken();
    window.location.reload();
  }

  return {
    init,
    getToken,
    callRpc,
    logout
  };
})();
