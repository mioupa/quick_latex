'use strict';
const crypto = require('crypto');
const fs = require('fs');
const vscode = require('vscode');
const { scratchPath, preamblePath, supportDir } = require('./paths');
const { formatFailure } = require('./engine');

const VIEW_TYPE = 'quickLatex.preview';
const SETTING_KEYS = ['mode', 'color', 'fontSize', 'padding'];

function readSettings() {
  const c = vscode.workspace.getConfiguration('quickLatex');
  return {
    mode: c.get('mode', 'display'),
    color: String(c.get('color', '000000')).replace(/^#/, '').toUpperCase(),
    fontSize: c.get('fontSize', 20),
    padding: c.get('padding', 2),
  };
}

function sanitizeSetting(key, value) {
  switch (key) {
    case 'mode': return ['display', 'inline', 'text'].includes(value) ? value : null;
    case 'color': {
      const v = String(value).replace(/^#/, '');
      return /^[0-9a-fA-F]{6}$/.test(v) ? v.toUpperCase() : null;
    }
    case 'fontSize': { const n = Number(value); return Number.isFinite(n) ? Math.min(200, Math.max(4, n)) : null; }
    case 'padding': { const n = Number(value); return Number.isFinite(n) ? Math.min(100, Math.max(0, n)) : null; }
    default: return null;
  }
}

class PreviewController {
  /**
   * @param {vscode.ExtensionContext} context
   * @param {import('./engine').Engine} engine
   * @param {vscode.DiagnosticCollection} diagnostics
   */
  constructor(context, engine, diagnostics) {
    this.context = context;
    this.engine = engine;
    this.diagnostics = diagnostics;
    /** @type {vscode.WebviewPanel|undefined} */
    this.panel = undefined;
    this.ready = false;
    this.seq = 0;
    this.slot = { current: null };
    this.timer = undefined;
    this.lastMessage = undefined;     // last result/error message, re-sent when the webview (re)loads
    this.disposables = [];

    this.disposables.push(
      vscode.workspace.onDidChangeTextDocument((e) => {
        if (this.isScratch(e.document)) this.schedule(250);
      }),
      vscode.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration('quickLatex')) {
          this.postState();
          this.schedule(30);
        }
      }),
      vscode.workspace.onDidSaveTextDocument((doc) => {
        if (doc.uri.fsPath === preamblePath) this.schedule(100);
      }),
    );
    // The preamble may also be edited by the app or another editor.
    try {
      const watcher = vscode.workspace.createFileSystemWatcher(
        new vscode.RelativePattern(vscode.Uri.file(supportDir), 'preamble.tex'));
      watcher.onDidChange(() => this.schedule(300));
      watcher.onDidCreate(() => this.schedule(300));
      this.disposables.push(watcher);
    } catch { /* watching outside the workspace is best-effort */ }
  }

  isScratch(doc) {
    return doc && doc.uri.scheme === 'file' && doc.uri.fsPath === scratchPath;
  }

  /** Current scratch text: the in-memory document when open (no save needed), else the file. */
  scratchText() {
    const doc = vscode.workspace.textDocuments.find((d) => this.isScratch(d));
    if (doc) return doc.getText();
    try { return fs.readFileSync(scratchPath, 'utf8'); } catch { return ''; }
  }

  isActive() { return !!(this.panel && this.panel.active); }

  // ---- panel lifecycle -------------------------------------------------------------------

  /** Create (beside the active editor, without stealing focus) or reveal the panel. */
  show() {
    if (this.panel) {
      this.panel.reveal(this.panel.viewColumn, true);
      return;
    }
    const panel = vscode.window.createWebviewPanel(
      VIEW_TYPE, 'Quick LaTeX',
      { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true },
      this.webviewOptions());
    this.attach(panel);
  }

  webviewOptions() {
    return {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(this.context.extensionUri, 'media')],
    };
  }

  /** Wire up a (new or restored) panel. */
  attach(panel) {
    this.panel = panel;
    this.ready = false;
    panel.webview.options = this.webviewOptions();
    panel.webview.html = this.html(panel.webview);
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.ready = false;
      this.cancel();
    }, null, this.disposables);
    panel.webview.onDidReceiveMessage((m) => this.onMessage(m), null, this.disposables);
  }

  html(webview) {
    const media = (f) => webview.asWebviewUri(vscode.Uri.joinPath(this.context.extensionUri, 'media', f));
    const nonce = crypto.randomBytes(16).toString('base64');
    const csp = [
      "default-src 'none'",
      'img-src data:',
      `style-src ${webview.cspSource}`,
      `script-src 'nonce-${nonce}'`,
    ].join('; ');
    return `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="${media('preview.css')}">
<title>Quick LaTeX</title>
</head>
<body>
<div id="toolbar">
  <label class="field">モード
    <select id="mode">
      <option value="display">数式</option>
      <option value="inline">インライン</option>
      <option value="text">テキスト</option>
    </select>
  </label>
  <span class="field">色
    <span id="swatches">
      <button class="swatch" data-color="000000" title="黒"></button>
      <button class="swatch" data-color="FFFFFF" title="白"></button>
      <button class="swatch" data-color="D0021B" title="赤"></button>
      <button class="swatch" data-color="1F4FD8" title="青"></button>
    </span>
    <input type="color" id="color" title="カスタム色">
  </span>
  <label class="field">文字サイズ
    <input type="number" id="fontSize" min="4" max="200" step="1"> pt
  </label>
  <label class="field">余白
    <input type="number" id="padding" min="0" max="100" step="0.5"> pt
  </label>
  <span class="spacer"></span>
  <button id="copy" class="primary" title="PDF+PNGをコピー（⌘↩）">コピー ⌘↩</button>
  <button id="copySvg" title="SVGをコピー（⇧⌘↩）">SVG</button>
  <button id="preamble">プリアンブル</button>
</div>
<div id="stage"><div id="box"><img id="image" alt=""><div id="placeholder">scratch.tex に数式を書くとここに表示されます</div></div></div>
<div id="status"></div>
<script nonce="${nonce}" src="${media('preview.js')}"></script>
</body>
</html>`;
  }

  // ---- messages --------------------------------------------------------------------------

  postState() {
    this.post({ type: 'state', state: readSettings() });
  }

  post(message) {
    if (this.panel && this.ready) this.panel.webview.postMessage(message);
  }

  onMessage(m) {
    switch (m && m.type) {
      case 'ready':
        this.ready = true;
        this.postState();
        if (this.lastMessage) this.post(this.lastMessage);
        this.schedule(0);
        break;
      case 'setSetting': {
        if (!SETTING_KEYS.includes(m.key)) return;
        const value = sanitizeSetting(m.key, m.value);
        if (value === null) { this.postState(); return; }
        vscode.workspace.getConfiguration('quickLatex')
          .update(m.key, value, vscode.ConfigurationTarget.Global)
          .then(undefined, (e) => vscode.window.showErrorMessage(`設定を保存できません: ${e.message}`));
        break;
      }
      case 'copy': vscode.commands.executeCommand('quickLatex.copy'); break;
      case 'copySvg': vscode.commands.executeCommand('quickLatex.copySvg'); break;
      case 'editPreamble': vscode.commands.executeCommand('quickLatex.editPreamble'); break;
      default: break;
    }
  }

  // ---- rendering -------------------------------------------------------------------------

  schedule(delay) {
    if (!this.panel) return;           // nothing to show: don't spawn processes
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.render(), delay);
  }

  cancel() {
    clearTimeout(this.timer);
    this.seq++;
    if (this.slot.current) { try { this.slot.current.kill('SIGTERM'); } catch { /* gone */ } }
  }

  async render() {
    if (!this.panel) return;
    const mySeq = ++this.seq;
    const source = this.scratchText();
    if (!source.trim()) {
      this.diagnostics.clear();
      this.lastMessage = { type: 'empty' };
      this.post(this.lastMessage);
      return;
    }
    const s = readSettings();
    this.post({ type: 'busy' });
    const result = await this.engine.render({
      source, mode: s.mode, color: s.color, size: s.fontSize, padding: s.padding, png: true,
    }, this.slot);
    if (result.cancelled || mySeq !== this.seq) return;        // superseded by a newer render

    if (result.ok) {
      this.diagnostics.clear();
      this.lastMessage = {
        type: 'result',
        png: `data:image/png;base64,${result.pngBase64}`,
        width: result.width,
        height: result.height,
        seconds: result.seconds,
      };
    } else {
      this.setDiagnostics(result);
      this.lastMessage = { type: 'error', text: formatFailure(result) };
    }
    this.post(this.lastMessage);
  }

  /** Error at the failing line of scratch.tex (region "source") or preamble.tex (region "preamble"). */
  setDiagnostics(failure) {
    this.diagnostics.clear();
    setFailureDiagnostic(this.diagnostics, failure);
  }

  dispose() {
    this.cancel();
    this.disposables.forEach((d) => { try { d.dispose(); } catch { /* ignore */ } });
    if (this.panel) this.panel.dispose();
  }
}

/** Put a diagnostic for `failure` on scratch.tex / preamble.tex. Returns true when one was added. */
function setFailureDiagnostic(collection, failure) {
  if (failure.line == null) return false;
  let fsPath;
  if (failure.region === 'source') fsPath = scratchPath;
  else if (failure.region === 'preamble') fsPath = preamblePath;
  else return false;
  const uri = vscode.Uri.file(fsPath);
  const doc = vscode.workspace.textDocuments.find((d) => d.uri.fsPath === fsPath);
  let line = failure.line - 1;
  if (doc) line = Math.min(Math.max(0, line), Math.max(0, doc.lineCount - 1));
  const range = doc ? doc.lineAt(line).range : new vscode.Range(line, 0, line, 1000);
  const message = failure.message + (failure.context ? `\n${failure.context}` : '');
  const diag = new vscode.Diagnostic(range, message, vscode.DiagnosticSeverity.Error);
  diag.source = 'Quick LaTeX';
  collection.set(uri, [diag]);
  return true;
}

module.exports = { PreviewController, VIEW_TYPE, setFailureDiagnostic, readSettings };
