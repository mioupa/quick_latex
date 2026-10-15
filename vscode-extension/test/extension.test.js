'use strict';
// End-to-end smoke test of extension.js / lib/preview.js with a stubbed `vscode` API and the real CLI.
// It cannot replace a manual check in VS Code (webview rendering, keybindings), but it exercises the whole
// command -> source resolution -> CLI -> clipboard / webview message / diagnostics path.
// Run: node vscode-extension/test/extension.test.js   (needs bin/quicklatex)
const assert = require('node:assert/strict');
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ql-ext-test-'));
const paths = {
  supportDir: tmp,
  scratchPath: path.join(tmp, 'scratch.tex'),
  preamblePath: path.join(tmp, 'preamble.tex'),
};
fs.writeFileSync(paths.preamblePath, '\\usepackage{amsmath,amssymb}\n');

// ---- vscode stub -------------------------------------------------------------------------------
const settings = { mode: 'display', color: '000000', fontSize: 20, padding: 2, binaryPath: '' };
const listeners = { text: [], config: [], save: [], activeEditor: [] };
const commands = new Map();
const contexts = {};
const messages = { status: [], warning: [], error: [] };
const posted = [];
const diagnostics = new Map();
const docs = [];
let activeTextEditor;
let panel;
let panelMessageHandler;

function makeDoc(fsPath, text, languageId = 'latex') {
  let content = text;
  const doc = {
    uri: { scheme: 'file', fsPath },
    languageId,
    get lineCount() { return content.split('\n').length; },
    getText(range) {
      if (!range) return content;
      return content.slice(doc.offsetAt(range.start), doc.offsetAt(range.end));
    },
    offsetAt(pos) {
      const lines = content.split('\n');
      let off = 0;
      for (let i = 0; i < pos.line; i++) off += lines[i].length + 1;
      return off + pos.character;
    },
    lineAt(line) { return { range: { line } }; },
    setText(t) { content = t; },
  };
  docs.push(doc);
  return doc;
}
function positionAt(doc, offset) {
  const before = doc.getText().slice(0, offset).split('\n');
  return { line: before.length - 1, character: before[before.length - 1].length };
}
function editorFor(doc, selStart = 0, selEnd = selStart) {
  const start = positionAt(doc, selStart), end = positionAt(doc, selEnd);
  return { document: doc, selection: { isEmpty: selStart === selEnd, start, end, active: end } };
}
const emitter = (arr) => (fn) => { arr.push(fn); return { dispose() {} }; };

const vscodeStub = {
  Uri: {
    file: (p) => ({ scheme: 'file', fsPath: p }),
    joinPath: (base, ...parts) => ({ scheme: 'file', fsPath: path.join(base.fsPath, ...parts) }),
  },
  ViewColumn: { Active: -1, Beside: -2 },
  ConfigurationTarget: { Global: 1 },
  DiagnosticSeverity: { Error: 0 },
  Diagnostic: class { constructor(range, message, severity) { this.range = range; this.message = message; this.severity = severity; } },
  Range: class { constructor(a, b, c, d) { this.start = { line: a, character: b }; this.end = { line: c, character: d }; } },
  RelativePattern: class { constructor(base, pattern) { this.base = base; this.pattern = pattern; } },
  workspace: {
    getConfiguration: () => ({
      get: (k, d) => (k in settings ? settings[k] : d),
      update: async (k, v) => { settings[k] = v; listeners.config.forEach((f) => f({ affectsConfiguration: () => true })); },
    }),
    onDidChangeTextDocument: emitter(listeners.text),
    onDidChangeConfiguration: emitter(listeners.config),
    onDidSaveTextDocument: emitter(listeners.save),
    createFileSystemWatcher: () => ({ onDidChange() {}, onDidCreate() {}, dispose() {} }),
    get textDocuments() { return docs; },
    openTextDocument: async (uri) => docs.find((d) => d.uri.fsPath === uri.fsPath) || makeDoc(uri.fsPath, fs.readFileSync(uri.fsPath, 'utf8')),
  },
  window: {
    get activeTextEditor() { return activeTextEditor; },
    onDidChangeActiveTextEditor: emitter(listeners.activeEditor),
    showTextDocument: async (doc) => { activeTextEditor = editorFor(doc); return activeTextEditor; },
    createWebviewPanel: (viewType, title, opts, options) => {
      assert.equal(viewType, 'quickLatex.preview');
      assert.equal(opts.preserveFocus, true);
      assert.equal(opts.viewColumn, vscodeStub.ViewColumn.Beside);
      assert.equal(options.retainContextWhenHidden, true);
      panel = {
        active: false, viewColumn: 2, disposed: false,
        webview: {
          options: {}, html: '', cspSource: 'vscode-resource:',
          asWebviewUri: (u) => `webview://${u.fsPath}`,
          postMessage: (m) => { posted.push(m); return Promise.resolve(true); },
          onDidReceiveMessage: (fn) => { panelMessageHandler = fn; return { dispose() {} }; },
        },
        reveal() {},
        onDidDispose() { return { dispose() {} }; },
        dispose() { panel.disposed = true; },
      };
      return panel;
    },
    registerWebviewPanelSerializer: () => ({ dispose() {} }),
    setStatusBarMessage: (m) => { messages.status.push(m); return { dispose() {} }; },
    showWarningMessage: (m) => { messages.warning.push(m); },
    showErrorMessage: (m) => { messages.error.push(m); },
  },
  commands: {
    registerCommand: (id, fn) => { commands.set(id, fn); return { dispose() {} }; },
    executeCommand: async (id, ...args) => {
      if (id === 'setContext') { contexts[args[0]] = args[1]; return undefined; }
      return commands.get(id)(...args);
    },
  },
  languages: {
    createDiagnosticCollection: () => ({
      set: (uri, d) => diagnostics.set(uri.fsPath, d),
      clear: () => diagnostics.clear(),
      dispose() {},
    }),
  },
};

const extensionPathForStub = path.join(__dirname, '..');
const origLoad = Module._load;
Module._load = function (request, parent, ...rest) {
  if (request === 'vscode') return vscodeStub;
  if (/(^|[\\/])paths(\.js)?$/.test(request) && parent && parent.filename && parent.filename.startsWith(extensionPathForStub)) return paths;
  return origLoad.call(this, request, parent, ...rest);
};

const extensionPath = path.join(__dirname, '..');
if (!fs.existsSync(path.join(extensionPath, 'bin', 'quicklatex'))) {
  console.error('bin/quicklatex is missing: run ./build.sh vscode first');
  process.exit(2);
}
const ext = require('../extension.js');
const context = {
  extensionPath,
  extensionUri: { scheme: 'file', fsPath: extensionPath },
  globalStorageUri: { fsPath: path.join(tmp, 'storage') },
  subscriptions: [],
};

let passed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log(`ok   ${name}`); } catch (e) { console.error(`FAIL ${name}\n${e.stack}`); process.exitCode = 1; }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clipboardInfo = () => cp.execFileSync('osascript', ['-e', 'clipboard info']).toString();
const setClipboard = (s) => cp.execFileSync('osascript', ['-e', `set the clipboard to "${s}"`]);
async function waitFor(pred, ms = 8000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (pred()) return true; await sleep(50); }
  return false;
}

(async () => {
  ext.activate(context);

  await test('commands are registered', () => {
    for (const c of ['quickLatex.open', 'quickLatex.copy', 'quickLatex.copySvg', 'quickLatex.editPreamble']) assert.ok(commands.has(c), c);
  });

  await test('open: creates the scratch file with a sample and shows the preview (preserveFocus, Beside)', async () => {
    await vscodeStub.commands.executeCommand('quickLatex.open');
    assert.ok(fs.existsSync(paths.scratchPath));
    assert.match(fs.readFileSync(paths.scratchPath, 'utf8'), /\\int_0\^\\infty/);
    assert.ok(panel, 'panel created');
    assert.match(panel.webview.html, /Content-Security-Policy/);
    assert.match(panel.webview.html, /script-src 'nonce-/);
    assert.ok(!/<script(?![^>]*nonce=)/.test(panel.webview.html), 'every script has a nonce');
    // scratch context key follows the active editor
    listeners.activeEditor.forEach((f) => f(activeTextEditor));
    assert.equal(contexts['quickLatex.scratchFocused'], true);
  });

  await test('preview: ready -> state + rendered PNG (from the in-memory document)', async () => {
    posted.length = 0;
    await panelMessageHandler({ type: 'ready' });
    assert.ok(await waitFor(() => posted.some((m) => m.type === 'result')), 'result message');
    const state = posted.find((m) => m.type === 'state');
    assert.deepEqual(state.state, { mode: 'display', color: '000000', fontSize: 20, padding: 2 });
    const result = posted.find((m) => m.type === 'result');
    assert.match(result.png, /^data:image\/png;base64,/);
    assert.ok(result.width > 50 && result.seconds > 0);
    assert.equal(diagnostics.size, 0);
  });

  await test('preview: unsaved edit in the document re-renders (debounced) without saving', async () => {
    posted.length = 0;
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('\\sum_{n=1}^\\infty \\frac{1}{n^2}');           // in memory only
    listeners.text.forEach((f) => f({ document: scratch }));
    assert.ok(await waitFor(() => posted.some((m) => m.type === 'result')), 'second result');
    assert.notEqual(fs.readFileSync(paths.scratchPath, 'utf8'), scratch.getText());
  });

  await test('preview: error -> diagnostic on scratch.tex at the failing line, last image kept (error message only)', async () => {
    posted.length = 0;
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('x^2 +\n\\fracc{1}{2}');
    listeners.text.forEach((f) => f({ document: scratch }));
    assert.ok(await waitFor(() => posted.some((m) => m.type === 'error')), 'error message');
    const err = posted.find((m) => m.type === 'error');
    assert.match(err.text, /^行 2: Undefined control sequence\./);
    const d = diagnostics.get(paths.scratchPath);
    assert.ok(d && d.length === 1 && d[0].range.line === 1, JSON.stringify(d));
  });

  await test('preview: fixing the source clears the diagnostic', async () => {
    posted.length = 0;
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('x^2 + \\frac{1}{2}');
    listeners.text.forEach((f) => f({ document: scratch }));
    assert.ok(await waitFor(() => posted.some((m) => m.type === 'result')));
    assert.equal(diagnostics.size, 0);
  });

  await test('preamble error -> diagnostic on preamble.tex (region "preamble")', async () => {
    fs.writeFileSync(paths.preamblePath, '\\usepackage{amsmath}\n');
    // The CLI uses the real shared preamble; simulate region handling directly through the failure helper.
    const { setFailureDiagnostic } = require('../lib/preview');
    const coll = vscodeStub.languages.createDiagnosticCollection();
    assert.equal(setFailureDiagnostic(coll, { message: 'Undefined control sequence.', context: 'x', line: 2, region: 'preamble' }), true);
    assert.ok(diagnostics.has(paths.preamblePath));
    assert.equal(setFailureDiagnostic(coll, { message: 'm', line: null, region: null }), false);
    diagnostics.clear();
  });

  await test('settings from the webview are written (clamped) and pushed back', async () => {
    posted.length = 0;
    await panelMessageHandler({ type: 'setSetting', key: 'fontSize', value: 999 });
    await sleep(100);
    assert.equal(settings.fontSize, 200);
    await panelMessageHandler({ type: 'setSetting', key: 'color', value: '#d0021b' });
    await sleep(100);
    assert.equal(settings.color, 'D0021B');
    await panelMessageHandler({ type: 'setSetting', key: 'mode', value: 'bogus' });
    assert.equal(settings.mode, 'display');
    assert.ok(posted.some((m) => m.type === 'state' && m.state.color === 'D0021B'));
    settings.fontSize = 20; settings.color = '000000';
  });

  await test('copy from scratch: whole text -> clipboard has PDF + PNG, status bar message', async () => {
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('E = mc^2');
    activeTextEditor = editorFor(scratch);
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copy');
    const info = clipboardInfo();
    assert.match(info, /PDF/);
    assert.match(info, /PNGf/);
    assert.deepEqual(messages.status.slice(-1), ['Quick LaTeX: コピーしました']);
  });

  await test('copy from another doc with a $$...$$ selection -> display, delimiters stripped', async () => {
    const doc = makeDoc(path.join(tmp, 'paper.tex'), 'intro\n$$ \\int_0^1 x\\,dx $$\noutro');
    const start = doc.getText().indexOf('$$');
    const end = doc.getText().lastIndexOf('$$') + 2;
    activeTextEditor = editorFor(doc, start, end);
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copy');
    assert.match(clipboardInfo(), /PDF/);
  });

  await test('copy without selection finds the enclosing align* and copies it', async () => {
    const text = 'a\n\\begin{align*}\n a &= b \\\\\n c &= d\n\\end{align*}\nb';
    const doc = makeDoc(path.join(tmp, 'paper2.tex'), text);
    activeTextEditor = editorFor(doc, text.indexOf('c &='));
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copy');
    assert.match(clipboardInfo(), /PDF/);
  });

  await test('copy without selection and no math -> warning, clipboard untouched', async () => {
    const doc = makeDoc(path.join(tmp, 'notes.md'), 'just text here', 'markdown');
    activeTextEditor = editorFor(doc, 5);
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copy');
    assert.deepEqual(messages.warning.slice(-1), ['カーソル位置に数式が見つかりません']);
    assert.doesNotMatch(clipboardInfo(), /PDF/);
  });

  await test('copySvg puts SVG on the clipboard', async () => {
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('\\frac{a}{b}');
    activeTextEditor = editorFor(scratch);
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copySvg');
    assert.match(clipboardInfo(), /svg/);
  });

  await test('TeX error on copy -> error notification (with line) and clipboard untouched', async () => {
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('\\fracc{1}{2}');
    activeTextEditor = editorFor(scratch);
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copy');
    assert.match(messages.error.slice(-1)[0], /行 1: Undefined control sequence/);
    assert.doesNotMatch(clipboardInfo(), /PDF/);
    assert.ok(diagnostics.has(paths.scratchPath));
  });

  await test('copy invoked while the preview is active uses the scratch text', async () => {
    const scratch = docs.find((d) => d.uri.fsPath === paths.scratchPath);
    scratch.setText('y = x^2');
    activeTextEditor = undefined;
    panel.active = true;
    setClipboard('sentinel');
    await vscodeStub.commands.executeCommand('quickLatex.copy');
    panel.active = false;
    assert.match(clipboardInfo(), /PDF/);
  });

  ext.deactivate();
  setClipboard('');
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`\n${passed} passed${process.exitCode ? ', with failures' : ''}`);
  process.exit(process.exitCode || 0);
})();
