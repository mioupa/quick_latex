'use strict';
// Runs media/preview.js against a tiny fake DOM and checks how it reacts to the extension's messages.
// Run: node vscode-extension/test/webview.test.js
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function makeEl(id) {
  const classes = new Set();
  const el = {
    id, value: '', textContent: '', dataset: {}, style: {}, listeners: {},
    classList: {
      add: (c) => classes.add(c), remove: (c) => classes.delete(c),
      contains: (c) => classes.has(c),
      toggle: (c, on) => { if (on) classes.add(c); else classes.delete(c); },
    },
    get className() { return [...classes].join(' '); },
    set className(v) { classes.clear(); String(v).split(/\s+/).filter(Boolean).forEach((c) => classes.add(c)); },
    addEventListener(type, fn) { (el.listeners[type] ||= []).push(fn); },
    fire(type) { (el.listeners[type] || []).forEach((f) => f({})); },
  };
  return el;
}
const els = {};
for (const id of ['mode', 'color', 'fontSize', 'padding', 'copy', 'copySvg', 'preamble', 'box', 'image', 'status']) els[id] = makeEl(id);
const swatches = ['000000', 'FFFFFF', 'D0021B', '1F4FD8'].map((c) => { const e = makeEl('sw' + c); e.dataset.color = c; return e; });
const sent = [];
let messageHandler;
const sandbox = {
  document: { getElementById: (id) => els[id], querySelectorAll: () => swatches },
  window: { addEventListener: (t, fn) => { if (t === 'message') messageHandler = fn; } },
  acquireVsCodeApi: () => ({ postMessage: (m) => sent.push(m) }),
  Number, Math, parseInt, Array, Object,
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '..', 'media', 'preview.js'), 'utf8'), sandbox);
const msg = (data) => messageHandler({ data });

const plain = (x) => JSON.parse(JSON.stringify(x));   // objects from the vm realm have another prototype
assert.deepEqual(plain(sent[0]), { type: 'ready' });
swatches.forEach((s) => assert.equal(s.style.background, '#' + s.dataset.color));

msg({ type: 'state', state: { mode: 'inline', color: 'FFFFFF', fontSize: 30, padding: 4 } });
assert.equal(els.mode.value, 'inline');
assert.equal(els.fontSize.value, 30);
assert.equal(els.color.value, '#ffffff');
assert.equal(els.box.style.background, '#2B2B2B', 'white text -> dark box');
assert.ok(swatches[1].classList.contains('selected') && !swatches[0].classList.contains('selected'));
msg({ type: 'state', state: { color: 'D0021B' } });
assert.equal(els.box.style.background, '#FFFFFF', 'red text -> white box');

msg({ type: 'result', png: 'data:image/png;base64,AAAA', width: 166.25, height: 52, seconds: 0.2946 });
assert.equal(els.image.src, 'data:image/png;base64,AAAA');
assert.equal(els.image.style.width, '166.25px');
assert.ok(els.image.classList.contains('visible') && !els.image.classList.contains('stale'));
assert.equal(els.status.textContent, '✓ 0.29s');

msg({ type: 'error', text: '行 2: Undefined control sequence.' });
assert.ok(els.image.classList.contains('stale'), 'last good image stays, dimmed');
assert.equal(els.status.textContent, '行 2: Undefined control sequence.');
assert.ok(els.status.classList.contains('error'));
msg({ type: 'busy' });                       // must not wipe the error text while compiling
assert.equal(els.status.textContent, '行 2: Undefined control sequence.');

msg({ type: 'empty' });
assert.ok(!els.image.classList.contains('visible'));

// toolbar -> extension messages
sent.length = 0;
els.mode.value = 'text'; els.mode.fire('change');
els.fontSize.value = '24'; els.fontSize.fire('change');
els.padding.value = 'abc'; els.padding.fire('change');          // invalid: nothing sent
swatches[3].fire('click');
els.copy.fire('click'); els.copySvg.fire('click'); els.preamble.fire('click');
assert.deepEqual(plain(sent), [
  { type: 'setSetting', key: 'mode', value: 'text' },
  { type: 'setSetting', key: 'fontSize', value: 24 },
  { type: 'setSetting', key: 'color', value: '1F4FD8' },
  { type: 'copy' }, { type: 'copySvg' }, { type: 'editPreamble' },
]);
console.log('ok   webview script behaves (state, result, error, empty, toolbar messages)');
