'use strict';
const fs = require('fs');
const vscode = require('vscode');
const { supportDir, scratchPath, preamblePath } = require('./lib/paths');
const { Engine, formatFailure } = require('./lib/engine');
const { PreviewController, VIEW_TYPE, setFailureDiagnostic, readSettings } = require('./lib/preview');
const { resolveSource } = require('./lib/source');

const SAMPLE = '\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}\n';

/** @type {Engine} */ let engine;
/** @type {PreviewController} */ let preview;
/** @type {vscode.DiagnosticCollection} */ let diagnostics;
const copySlot = { current: null };

function isScratchDoc(doc) {
  return !!doc && doc.uri.scheme === 'file' && doc.uri.fsPath === scratchPath;
}

function updateContext() {
  const ed = vscode.window.activeTextEditor;
  vscode.commands.executeCommand('setContext', 'quickLatex.scratchFocused', !!ed && isScratchDoc(ed.document));
}

function ensureScratch() {
  fs.mkdirSync(supportDir, { recursive: true });
  if (!fs.existsSync(scratchPath)) fs.writeFileSync(scratchPath, SAMPLE, 'utf8');
}

async function openScratch() {
  ensureScratch();
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(scratchPath));
  await vscode.window.showTextDocument(doc, { viewColumn: vscode.ViewColumn.Active, preview: false });
  preview.show();
  preview.schedule(0);
}

async function editPreamble() {
  const file = await engine.ensurePreamble();
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(file || preamblePath));
  await vscode.window.showTextDocument(doc, { viewColumn: vscode.ViewColumn.Active, preview: false });
}

/**
 * What to render for the copy commands (see lib/source.js for the rules).
 * @returns {{source: string, mode: string, isScratch: boolean, wholeScratch: boolean}|null}
 */
function currentTarget() {
  const settings = readSettings();
  const ed = vscode.window.activeTextEditor;

  // Invoked from the preview webview (button / cmd+enter): always the scratch document.
  if (preview.isActive() || !ed) {
    return { source: preview.scratchText(), mode: settings.mode, isScratch: true, wholeScratch: true };
  }
  const doc = ed.document;
  const scratch = isScratchDoc(doc);
  const sel = ed.selection;
  const resolved = resolveSource({
    isScratch: scratch,
    fullText: doc.getText(),
    selectionText: sel.isEmpty ? '' : doc.getText(sel),
    offset: doc.offsetAt(sel.active),
    configuredMode: settings.mode,
  });
  if (!resolved) return null;
  return { ...resolved, isScratch: scratch };
}

async function copy(kind) {
  const target = currentTarget();
  if (!target) {
    vscode.window.showWarningMessage('カーソル位置に数式が見つかりません');
    return;
  }
  if (!target.source.trim()) {
    vscode.window.showWarningMessage('Quick LaTeX: 入力が空です');
    return;
  }
  const s = readSettings();
  const result = await engine.render({
    source: target.source, mode: target.mode, color: s.color, size: s.fontSize, padding: s.padding,
    copy: kind === 'png', copySvg: kind === 'svg',
  }, copySlot);
  if (result.cancelled) return;

  if (result.ok) {
    if (target.isScratch && target.wholeScratch) diagnostics.clear();
    vscode.window.setStatusBarMessage('Quick LaTeX: コピーしました', 3000);
    return;
  }
  const text = formatFailure(result);
  if (target.isScratch && target.wholeScratch) {
    diagnostics.clear();
    setFailureDiagnostic(diagnostics, result);
  }
  vscode.window.showErrorMessage(`Quick LaTeX: ${text}`);
}

function activate(context) {
  engine = new Engine(context);
  diagnostics = vscode.languages.createDiagnosticCollection('quick-latex');
  preview = new PreviewController(context, engine, diagnostics);

  context.subscriptions.push(
    diagnostics,
    preview,
    vscode.commands.registerCommand('quickLatex.open', openScratch),
    vscode.commands.registerCommand('quickLatex.copy', () => copy('png')),
    vscode.commands.registerCommand('quickLatex.copySvg', () => copy('svg')),
    vscode.commands.registerCommand('quickLatex.editPreamble', editPreamble),
    vscode.window.onDidChangeActiveTextEditor(updateContext),
    // Re-attach the panel after a window reload.
    vscode.window.registerWebviewPanelSerializer(VIEW_TYPE, {
      async deserializeWebviewPanel(panel) {
        preview.attach(panel);
      },
    }),
  );
  updateContext();
}

function deactivate() {
  if (copySlot.current) { try { copySlot.current.kill('SIGTERM'); } catch { /* gone */ } }
}

module.exports = { activate, deactivate };
