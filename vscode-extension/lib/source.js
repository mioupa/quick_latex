'use strict';
// Pure source-resolution logic (no `vscode` import, so it is testable with plain Node).
//
//   resolveSource(...)   decide what to render for the copy commands
//   fromSelection(...)   strip surrounding math delimiters / pick the mode
//   findMathAround(...)  find the math expression around a cursor offset

/** Environments the engine routes to the text body (mirrors DocumentParts.shouldUseTextBody in the Swift engine). */
const DISPLAY_ENV_BASES = ['equation', 'align', 'gather', 'multline', 'flalign', 'alignat', 'eqnarray'];
const DISPLAY_ENVS = new Set([
  ...DISPLAY_ENV_BASES.flatMap((b) => [b, `${b}*`]),
  'empheq',
  'subequations',
]);

const MODES = ['display', 'inline', 'text'];

function normalizeMode(mode) {
  return MODES.includes(mode) ? mode : 'display';
}

const UNESCAPED_DOLLAR = /(?<!\\)\$/;
const UNESCAPED_DOUBLE_DOLLAR = /(?<!\\)\$\$/;

/**
 * Strip surrounding math delimiters from a user selection and pick the mode.
 * @param {string} selection
 * @param {string} configuredMode
 * @returns {{source: string, mode: string}}
 */
function fromSelection(selection, configuredMode) {
  const mode = normalizeMode(configuredMode);
  const t = selection.trim();

  if (t.length >= 4 && t.startsWith('$$') && t.endsWith('$$') && !t.endsWith('\\$$')) {
    const inner = t.slice(2, -2);
    if (!UNESCAPED_DOUBLE_DOLLAR.test(inner)) return { source: inner.trim(), mode: 'display' };
  }
  if (t.length >= 2 && t.startsWith('$') && !t.startsWith('$$') && t.endsWith('$') && !t.endsWith('\\$')) {
    const inner = t.slice(1, -1);
    if (!UNESCAPED_DOLLAR.test(inner)) return { source: inner.trim(), mode: 'inline' };
  }
  if (t.startsWith('\\(') && t.endsWith('\\)') && t.length >= 4) {
    const inner = t.slice(2, -2);
    if (!/\\[()]/.test(inner)) return { source: inner.trim(), mode: 'inline' };
  }
  if (t.startsWith('\\[') && t.endsWith('\\]') && t.length >= 4) {
    const inner = t.slice(2, -2);
    if (!/\\[[\]]/.test(inner)) return { source: inner.trim(), mode: 'display' };
  }
  const env = /^\\begin\s*\{([^{}]+)\}[\s\S]*\\end\s*\{\1\}$/.exec(t);
  if (env) {
    // Display environments: force display mode so the engine's auto-detect routes them to the text body.
    return { source: t, mode: DISPLAY_ENVS.has(env[1]) ? 'display' : mode };
  }
  return { source: selection, mode };
}

/**
 * Tokenise the delimiters we care about, skipping comments and control symbols.
 * Token types: '[' ']' '(' ')' (\[ \] \( \)), '$$', '$', 'begin', 'end' (with .env).
 */
function tokenize(text, base = 0) {
  const toks = [];
  const n = text.length;
  let i = 0;
  const push = (t, s, e, extra) => toks.push({ t, s: base + s, e: base + e, ...extra });
  while (i < n) {
    const c = text[i];
    if (c === '%') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }
    if (c === '\\') {
      const d = text[i + 1];
      if (d === undefined) { i++; continue; }
      if (d === '[' || d === ']' || d === '(' || d === ')') {
        push(d, i, i + 2);
        i += 2;
        continue;
      }
      if (/[A-Za-z@]/.test(d)) {
        let j = i + 1;
        while (j < n && /[A-Za-z@]/.test(text[j])) j++;
        const name = text.slice(i + 1, j);
        if (name === 'begin' || name === 'end') {
          const m = /^\s*\{([^{}\n]*)\}/.exec(text.slice(j, j + 80));
          if (m) {
            push(name, i, j + m[0].length, { env: m[1] });
            i = j + m[0].length;
            continue;
          }
        }
        i = j;
        continue;
      }
      i += 2; // control symbol: \\ \$ \% \{ ...
      continue;
    }
    if (c === '$') {
      if (text[i + 1] === '$') { push('$$', i, i + 2); i += 2; } else { push('$', i, i + 1); i += 1; }
      continue;
    }
    i++;
  }
  return toks;
}

/** Find display-math regions in the whole text: environments, \[..\], $$..$$, \(..\). */
function displayCandidates(text) {
  const cands = [];
  let open = null; // {kind, tok, env?}
  for (const tk of tokenize(text)) {
    if (open) {
      if (open.kind === 'env') {
        if (tk.t === 'end' && tk.env === open.tok.env) {
          cands.push({ kind: 'env', start: open.tok.s, end: tk.e, env: tk.env, inner: [open.tok.s, tk.e] });
          open = null;
        }
      } else if (open.kind === 'bracket' && tk.t === ']') {
        cands.push({ kind: 'bracket', start: open.tok.s, end: tk.e, inner: [open.tok.e, tk.s] });
        open = null;
      } else if (open.kind === 'paren' && tk.t === ')') {
        cands.push({ kind: 'paren', start: open.tok.s, end: tk.e, inner: [open.tok.e, tk.s] });
        open = null;
      } else if (open.kind === 'dd' && tk.t === '$$') {
        cands.push({ kind: 'dd', start: open.tok.s, end: tk.e, inner: [open.tok.e, tk.s] });
        open = null;
      }
      continue;
    }
    if (tk.t === 'begin' && DISPLAY_ENVS.has(tk.env)) open = { kind: 'env', tok: tk };
    else if (tk.t === '[') open = { kind: 'bracket', tok: tk };
    else if (tk.t === '(') open = { kind: 'paren', tok: tk };
    else if (tk.t === '$$') open = { kind: 'dd', tok: tk };
  }
  return cands;
}

/** `$...$` pairs on the line containing `offset`. */
function inlineDollarCandidate(text, offset) {
  const lineStart = text.lastIndexOf('\n', offset - 1) + 1;
  let lineEnd = text.indexOf('\n', offset);
  if (lineEnd < 0) lineEnd = text.length;
  const singles = tokenize(text.slice(lineStart, lineEnd), lineStart).filter((t) => t.t === '$');
  for (let k = 0; k + 1 < singles.length; k += 2) {
    const a = singles[k], b = singles[k + 1];
    if (offset >= a.s && offset <= b.e) return { kind: 'dollar', start: a.s, end: b.e, inner: [a.e, b.s] };
  }
  return null;
}

/**
 * Find the math expression around a cursor.
 * @param {string} text   whole document text
 * @param {number} offset cursor offset into `text`
 * @returns {{source: string, mode: string, kind: string}|null}
 */
function findMathAround(text, offset) {
  const inside = displayCandidates(text).filter((c) => offset >= c.start && offset <= c.end);
  let best = null;
  for (const c of inside) if (!best || c.end - c.start < best.end - best.start) best = c; // innermost
  if (!best) best = inlineDollarCandidate(text, offset);
  if (!best) return null;
  if (best.kind === 'env') {
    return { source: text.slice(best.start, best.end), mode: 'display', kind: 'env' };
  }
  const source = text.slice(best.inner[0], best.inner[1]).trim();
  const mode = best.kind === 'paren' || best.kind === 'dollar' ? 'inline' : 'display';
  return { source, mode, kind: best.kind };
}

/**
 * What should the copy commands render?
 *  (a) scratch file            -> selection if non-empty, else the whole text (configured mode)
 *  (b) other doc + selection   -> fromSelection()
 *  (c) other doc, no selection -> findMathAround() (null when nothing is found)
 * @returns {{source: string, mode: string, wholeScratch: boolean}|null}
 */
function resolveSource({ isScratch, fullText, selectionText, offset, configuredMode }) {
  const mode = normalizeMode(configuredMode);
  const hasSelection = typeof selectionText === 'string' && selectionText.trim().length > 0;
  if (isScratch) {
    if (hasSelection) return { source: selectionText, mode, wholeScratch: false };
    return { source: fullText, mode, wholeScratch: true };
  }
  if (hasSelection) return { ...fromSelection(selectionText, mode), wholeScratch: false };
  const found = findMathAround(fullText, offset);
  return found ? { source: found.source, mode: found.mode, wholeScratch: false } : null;
}

module.exports = {
  DISPLAY_ENVS,
  fromSelection,
  findMathAround,
  resolveSource,
  tokenize,
};
