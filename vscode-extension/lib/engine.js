'use strict';
// Thin wrapper around the bundled Quick LaTeX CLI (execFile with an args array, no shell).
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vscode = require('vscode');

let counter = 0;

class Engine {
  /** @param {vscode.ExtensionContext} context */
  constructor(context) {
    this.context = context;
    this.tmpDir = context.globalStorageUri.fsPath;
    fs.mkdirSync(this.tmpDir, { recursive: true });
    this.ensureExecutable();
  }

  binaryPath() {
    const override = String(vscode.workspace.getConfiguration('quickLatex').get('binaryPath') || '').trim();
    if (override) return override.replace(/^~(?=$|\/)/, os.homedir());
    return path.join(this.context.extensionPath, 'bin', 'quicklatex');
  }

  /** vsix extraction may drop the executable bit. */
  ensureExecutable() {
    try { fs.chmodSync(path.join(this.context.extensionPath, 'bin', 'quicklatex'), 0o755); } catch { /* not bundled */ }
  }

  /**
   * Run a render. Resolves to the parsed JSON object, `{cancelled: true}` when killed, or an
   * `{ok: false, message}` object for launch problems.
   * @param {{source: string, mode: string, color: string, size: number, padding: number,
   *          png?: boolean, copy?: boolean, copySvg?: boolean}} job
   * @param {{current: import('child_process').ChildProcess|null}} [slot] holder for the child so a newer
   *        render can kill this one
   */
  async render(job, slot) {
    const id = `${process.pid}-${++counter}`;
    const srcFile = path.join(this.tmpDir, `src-${id}.tex`);
    const pngFile = job.png ? path.join(this.tmpDir, `out-${id}.png`) : null;
    await fs.promises.writeFile(srcFile, job.source, 'utf8');

    const args = [
      '--source-file', srcFile,
      '--mode', job.mode,
      '--color', job.color,
      '--size', String(job.size),
      '--padding', String(job.padding),
      '--json',
    ];
    if (pngFile) args.push('--png', pngFile);
    if (job.copy) args.push('--copy');
    if (job.copySvg) args.push('--copy-svg');

    try {
      const out = await this.exec(args, slot);
      if (out.cancelled) return { cancelled: true };
      if (out.ok && pngFile) {
        try { out.pngBase64 = (await fs.promises.readFile(pngFile)).toString('base64'); }
        catch (e) { return { ok: false, message: `PNGを読み込めません: ${e.message}` }; }
      }
      return out;
    } finally {
      fs.promises.unlink(srcFile).catch(() => {});
      if (pngFile) fs.promises.unlink(pngFile).catch(() => {});
    }
  }

  /** Ensure ~/Library/Application Support/QuickLaTeX/preamble.tex exists and return its path. */
  async ensurePreamble() {
    const { preamblePath } = require('./paths');
    try {
      const out = await new Promise((resolve, reject) => {
        cp.execFile(this.binaryPath(), ['--print-preamble-path'], { timeout: 15000 }, (err, stdout) =>
          err ? reject(err) : resolve(String(stdout).trim()));
      });
      return out || preamblePath;
    } catch {
      return preamblePath;
    }
  }

  exec(args, slot) {
    return new Promise((resolve) => {
      let killed = false;
      const child = cp.execFile(this.binaryPath(), args, { timeout: 90000, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
        if (slot && slot.current === child) slot.current = null;
        if (killed || (err && err.killed && err.signal === 'SIGTERM' && !String(stdout).trim())) {
          return resolve({ cancelled: true });
        }
        const line = String(stdout).split('\n').map((l) => l.trim()).filter(Boolean).pop();
        if (line) {
          try { return resolve(JSON.parse(line)); } catch { /* fall through */ }
        }
        if (err && (err.code === 'ENOENT' || err.code === 'EACCES')) {
          return resolve({ ok: false, message: `エンジンを起動できません（${this.binaryPath()}）: ${err.message}` });
        }
        const detail = String(stderr || '').trim().split('\n').pop() || (err ? err.message : '不明なエラー');
        resolve({ ok: false, message: `エンジンの出力を解釈できません: ${detail}` });
      });
      child.on('error', () => { /* reported through the callback */ });
      if (slot) {
        if (slot.current) { try { slot.current.kill('SIGTERM'); } catch { /* already gone */ } }
        slot.current = child;
        const origKill = child.kill.bind(child);
        child.kill = (sig) => { killed = true; return origKill(sig); };
      }
    });
  }
}

/** "行 N: message" / "プリアンブル 行 N: message" plus context, for display. */
function formatFailure(r) {
  let prefix = '';
  if (r.line != null && r.region === 'preamble') prefix = `プリアンブル 行 ${r.line}: `;
  else if (r.line != null && r.region === 'source') prefix = `行 ${r.line}: `;
  return prefix + (r.message || 'エラー') + (r.context ? `\n${r.context}` : '');
}

module.exports = { Engine, formatFailure };
