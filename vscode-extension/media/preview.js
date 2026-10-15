(function () {
  'use strict';
  const vscode = acquireVsCodeApi();
  const $ = (id) => document.getElementById(id);
  const els = {
    mode: $('mode'), color: $('color'), fontSize: $('fontSize'), padding: $('padding'),
    copy: $('copy'), copySvg: $('copySvg'), preamble: $('preamble'),
    box: $('box'), image: $('image'), status: $('status'),
  };
  const swatches = Array.from(document.querySelectorAll('.swatch'));
  let state = { mode: 'display', color: '000000', fontSize: 20, padding: 2 };

  swatches.forEach((b) => { b.style.background = '#' + b.dataset.color; });

  function luminance(hex) {
    const v = parseInt(hex, 16);
    const r = ((v >> 16) & 255) / 255, g = ((v >> 8) & 255) / 255, b = (v & 255) / 255;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  function applyState(s) {
    state = Object.assign({}, state, s);
    els.mode.value = state.mode;
    els.fontSize.value = state.fontSize;
    els.padding.value = state.padding;
    els.color.value = '#' + state.color.toLowerCase();
    swatches.forEach((b) => b.classList.toggle('selected', b.dataset.color === state.color.toUpperCase()));
    // The background auto-contrasts with the text colour.
    els.box.style.background = luminance(state.color) > 0.6 ? '#2B2B2B' : '#FFFFFF';
  }

  function setStatus(text, cls) {
    els.status.textContent = text;
    els.status.className = cls || '';
  }

  function send(key, value) { vscode.postMessage({ type: 'setSetting', key, value }); }

  els.mode.addEventListener('change', () => send('mode', els.mode.value));
  els.color.addEventListener('input', () => send('color', els.color.value.replace('#', '').toUpperCase()));
  swatches.forEach((b) => b.addEventListener('click', () => send('color', b.dataset.color)));
  for (const key of ['fontSize', 'padding']) {
    els[key].addEventListener('change', () => {
      const n = Number(els[key].value);
      if (Number.isFinite(n)) send(key, n); else applyState({});
    });
  }
  els.copy.addEventListener('click', () => vscode.postMessage({ type: 'copy' }));
  els.copySvg.addEventListener('click', () => vscode.postMessage({ type: 'copySvg' }));
  els.preamble.addEventListener('click', () => vscode.postMessage({ type: 'editPreamble' }));

  window.addEventListener('message', (event) => {
    const m = event.data;
    switch (m.type) {
      case 'state':
        applyState(m.state);
        break;
      case 'busy':
        if (!els.status.classList.contains('error')) setStatus('レンダリング中…', 'busy');
        break;
      case 'result':
        els.image.src = m.png;
        els.image.style.width = m.width + 'px';        // the PNG is 4 px/pt; show it at its point size
        els.image.classList.add('visible');
        els.image.classList.remove('stale');
        els.box.classList.add('has-image');
        setStatus('✓ ' + Number(m.seconds).toFixed(2) + 's', 'ok');
        break;
      case 'error':
        els.image.classList.add('stale');               // keep the last good image, dimmed
        setStatus(m.text, 'error');
        break;
      case 'empty':
        els.image.classList.remove('visible');
        els.box.classList.remove('has-image');
        setStatus('', '');
        break;
      default:
        break;
    }
  });

  applyState(state);
  vscode.postMessage({ type: 'ready' });
})();
