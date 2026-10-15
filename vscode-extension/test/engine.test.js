'use strict';
// Smoke test of lib/engine.js against the real CLI, with a stubbed `vscode` module.
// Run: node vscode-extension/test/engine.test.js   (needs bin/quicklatex, i.e. after `./build.sh vscode`)
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const Module = require('module');

const settings = { binaryPath: '' };
const fakeVscode = {
  workspace: { getConfiguration: () => ({ get: (k, d) => (k in settings ? settings[k] : d) }) },
};
const origLoad = Module._load;
Module._load = function (request, ...rest) {
  return request === 'vscode' ? fakeVscode : origLoad.call(this, request, ...rest);
};

const { Engine, formatFailure } = require('../lib/engine');
const extensionPath = path.join(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ql-engine-test-'));
const engine = new Engine({ extensionPath, globalStorageUri: { fsPath: tmp } });
if (!fs.existsSync(path.join(extensionPath, 'bin', 'quicklatex'))) {
  console.error('bin/quicklatex is missing: run ./build.sh vscode first');
  process.exit(2);
}

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log(`ok   ${name}`); } catch (e) { console.error(`FAIL ${name}\n${e.stack}`); process.exitCode = 1; }
}
const base = { mode: 'display', color: '1F4FD8', size: 20, padding: 2 };

(async () => {
  await test('render success returns size and a PNG', async () => {
    const r = await engine.render({ ...base, source: '\\frac{a}{b}', png: true });
    assert.equal(r.ok, true);
    assert.ok(r.width > 5 && r.height > 5);
    const png = Buffer.from(r.pngBase64, 'base64');
    assert.equal(png.subarray(1, 4).toString(), 'PNG');
  });

  await test('source error -> region/line (relative to the source)', async () => {
    const r = await engine.render({ ...base, source: 'x^2 +\n\\fracc{1}{2}' });
    assert.equal(r.ok, false);
    assert.equal(r.region, 'source');
    assert.equal(r.line, 2);
    assert.equal(formatFailure(r).split('\n')[0], '行 2: Undefined control sequence.');
  });

  await test('multi-line align source (& and \\\\ without environment)', async () => {
    const r = await engine.render({ ...base, source: 'a &= b \\\\\nc &= d', png: true });
    assert.equal(r.ok, true);
  });

  await test('a newer render kills the in-flight one (cancelled), the newer one completes', async () => {
    const slot = { current: null };
    const p1 = engine.render({ ...base, source: 'x_1' }, slot);
    const p2 = engine.render({ ...base, source: 'x_2' }, slot);
    const [r1, r2] = await Promise.all([p1, p2]);
    assert.equal(r1.cancelled, true, JSON.stringify(r1));
    assert.equal(r2.ok, true);
    assert.equal(slot.current, null);
  });

  await test('a killed CLI cleans up its private job dir', async () => {
    const cache = path.join(os.homedir(), 'Library', 'Caches', 'QuickLaTeX');
    const before = fs.readdirSync(cache).filter((n) => n.startsWith('job-cli-'));
    const slot = { current: null };
    const p = engine.render({ ...base, source: '\\def\\x{\\x}\\x', mode: 'text' }, slot);  // never terminates
    await new Promise((r) => setTimeout(r, 1200));
    slot.current.kill('SIGTERM');
    const r = await p;
    assert.equal(r.cancelled, true);
    await new Promise((r2) => setTimeout(r2, 400));
    const after = fs.readdirSync(cache).filter((n) => n.startsWith('job-cli-'));
    assert.deepEqual(after.sort(), before.sort());
  });

  await test('missing binary reports a launch error', async () => {
    settings.binaryPath = '/nonexistent/quicklatex';
    const r = await engine.render({ ...base, source: 'x' });
    settings.binaryPath = '';
    assert.equal(r.ok, false);
    assert.match(r.message, /エンジンを起動できません/);
  });

  await test('ensurePreamble returns the shared preamble path', async () => {
    const p = await engine.ensurePreamble();
    assert.equal(p, path.join(os.homedir(), 'Library', 'Application Support', 'QuickLaTeX', 'preamble.tex'));
    assert.ok(fs.existsSync(p));
  });

  const hasQuarantine = (file) => {
    try { cp.execFileSync('/usr/bin/xattr', ['-p', 'com.apple.quarantine', file], { stdio: 'pipe' }); return true; } catch { return false; }
  };
  const quarantine = (file) => cp.execFileSync('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0081;00000000;Safari;', file]);

  await test('activation strips com.apple.quarantine from the bundled binary (and chmods it) before the first run', async () => {
    const extQ = path.join(tmp, 'ext-quarantined');
    fs.mkdirSync(path.join(extQ, 'bin'), { recursive: true });
    const copy = path.join(extQ, 'bin', 'quicklatex');
    fs.copyFileSync(path.join(extensionPath, 'bin', 'quicklatex'), copy);
    fs.chmodSync(copy, 0o644);                       // as if the vsix extraction dropped the executable bit
    quarantine(copy);
    assert.ok(hasQuarantine(copy), 'precondition: quarantined');

    const e = new Engine({ extensionPath: extQ, globalStorageUri: { fsPath: path.join(tmp, 'storage-q') } });
    await e.ready;
    assert.equal(hasQuarantine(copy), false, 'quarantine removed');
    assert.equal(fs.statSync(copy).mode & 0o777, 0o755);
    const r = await e.render({ ...base, source: 'x^2' });      // first CLI invocation only after the removal
    assert.equal(r.ok, true, JSON.stringify(r));
  });

  await test('render waits for the quarantine removal (no race with the first invocation)', async () => {
    const extQ = path.join(tmp, 'ext-quarantined2');
    fs.mkdirSync(path.join(extQ, 'bin'), { recursive: true });
    const copy = path.join(extQ, 'bin', 'quicklatex');
    fs.copyFileSync(path.join(extensionPath, 'bin', 'quicklatex'), copy);
    quarantine(copy);
    const e = new Engine({ extensionPath: extQ, globalStorageUri: { fsPath: path.join(tmp, 'storage-q2') } });
    // No explicit wait on e.ready: render() itself must not start the binary while it is still quarantined.
    const r = await e.render({ ...base, source: 'y^2' });
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(hasQuarantine(copy), false);
  });

  await test('a user-set binaryPath is never touched (quarantine attribute stays)', async () => {
    const userBin = path.join(tmp, 'user-engine.txt');      // not executable on purpose: nothing quarantined gets run
    fs.writeFileSync(userBin, 'not a program\n');
    quarantine(userBin);
    settings.binaryPath = userBin;
    const e = new Engine({ extensionPath, globalStorageUri: { fsPath: path.join(tmp, 'storage-u') } });
    await e.ready;
    const r = await e.render({ ...base, source: 'x' });
    settings.binaryPath = '';
    assert.equal(r.ok, false);
    assert.ok(hasQuarantine(userBin), 'user binary keeps its attribute');
  });

  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`\n${passed} passed${process.exitCode ? ', with failures' : ''}`);
})();
