'use strict';
// Run: node vscode-extension/test/source.test.js
const assert = require('node:assert/strict');
const { fromSelection, findMathAround, resolveSource, DISPLAY_ENVS } = require('../lib/source');

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log(`ok   ${name}`); } catch (e) { console.error(`FAIL ${name}\n${e.message}`); process.exitCode = 1; }
}
/** Text with a `|` cursor marker. */
function cur(marked) {
  const offset = marked.indexOf('|');
  assert.ok(offset >= 0, 'missing cursor marker');
  return { text: marked.slice(0, offset) + marked.slice(offset + 1), offset };
}
const around = (marked) => { const { text, offset } = cur(marked); return findMathAround(text, offset); };

// ---- (b) selections -------------------------------------------------------
test('$...$ -> inline, delimiters stripped', () => {
  assert.deepEqual(fromSelection('$x^2$', 'display'), { source: 'x^2', mode: 'inline' });
});
test('$$...$$ -> display, content only', () => {
  assert.deepEqual(fromSelection('  $$ a+b $$ ', 'inline'), { source: 'a+b', mode: 'display' });
});
test('\\(...\\) -> inline', () => {
  assert.deepEqual(fromSelection('\\(\\alpha\\)', 'display'), { source: '\\alpha', mode: 'inline' });
});
test('\\[...\\] -> display, multi-line content', () => {
  assert.deepEqual(fromSelection('\\[\n  a = b\n\\]', 'text'), { source: 'a = b', mode: 'display' });
});
test('\\begin{align*}...\\end{align*} passed as-is, forced display (engine routes to text body)', () => {
  const s = '\\begin{align*} a &= b \\\\ c &= d \\end{align*}';
  assert.deepEqual(fromSelection(s, 'inline'), { source: s, mode: 'display' });
});
test('non-display env keeps the configured mode', () => {
  const s = '\\begin{pmatrix}1&2\\end{pmatrix}';
  assert.deepEqual(fromSelection(s, 'inline'), { source: s, mode: 'inline' });
});
test('plain selection uses the configured mode and is untouched', () => {
  assert.deepEqual(fromSelection('a + b', 'text'), { source: 'a + b', mode: 'text' });
  assert.deepEqual(fromSelection('\\frac{1}{2}', 'display'), { source: '\\frac{1}{2}', mode: 'display' });
});
test('"$a$ and $b$" is not a single delimited expression', () => {
  assert.deepEqual(fromSelection('$a$ and $b$', 'display'), { source: '$a$ and $b$', mode: 'display' });
});
test('escaped trailing dollar is not a delimiter', () => {
  assert.deepEqual(fromSelection('$5 \\$', 'display'), { source: '$5 \\$', mode: 'display' });
});
test('display env list incl. starred', () => {
  for (const e of ['equation', 'equation*', 'align', 'align*', 'gather*', 'multline*', 'flalign*', 'alignat*', 'eqnarray*', 'empheq', 'subequations']) {
    assert.ok(DISPLAY_ENVS.has(e), e);
  }
  assert.ok(!DISPLAY_ENVS.has('pmatrix') && !DISPLAY_ENVS.has('itemize'));
});

// ---- (c) cursor search ----------------------------------------------------
test('enclosing align* environment (cursor on a middle line)', () => {
  const r = around('text\n\\begin{align*}\n  a &= b \\\\\n  c &= |d\n\\end{align*}\nmore');
  assert.equal(r.mode, 'display');
  assert.equal(r.kind, 'env');
  assert.equal(r.source, '\\begin{align*}\n  a &= b \\\\\n  c &= d\n\\end{align*}');
});
test('enclosing equation, cursor right after \\begin', () => {
  const r = around('\\begin{equation}|\n x = 1\n\\end{equation}');
  assert.equal(r.kind, 'env');
  assert.match(r.source, /^\\begin\{equation\}[\s\S]*\\end\{equation\}$/);
});
test('\\[ ... \\] across lines -> display content', () => {
  const r = around('before\n\\[\n  \\int_0^1 |x\\,dx\n\\]\nafter');
  assert.deepEqual({ source: r.source, mode: r.mode }, { source: '\\int_0^1 x\\,dx', mode: 'display' });
});
test('$$ ... $$ across lines -> display content', () => {
  const r = around('a\n$$\n x|^2\n$$\nb');
  assert.deepEqual({ source: r.source, mode: r.mode }, { source: 'x^2', mode: 'display' });
});
test('\\( ... \\) -> inline content', () => {
  const r = around('we have \\(a^|2 + b^2\\) here');
  assert.deepEqual({ source: r.source, mode: r.mode }, { source: 'a^2 + b^2', mode: 'inline' });
});
test('$...$ on the current line (second pair)', () => {
  const r = around('$a$ and $b|^2$ and $c$');
  assert.deepEqual({ source: r.source, mode: r.mode }, { source: 'b^2', mode: 'inline' });
});
test('cursor between two inline pairs finds nothing', () => {
  assert.equal(around('$a$ and| $b$'), null);
});
test('cursor on the delimiter itself still matches', () => {
  assert.equal(around('x |$y$ z').source, 'y');
  assert.equal(around('x $y|$ z').source, 'y');
});
test('non-display environment (itemize) is not math', () => {
  assert.equal(around('\\begin{itemize}\n\\item |a\n\\end{itemize}'), null);
});
test('line breaks "\\\\[2pt]" inside align do not look like \\[', () => {
  const r = around('\\begin{align}\n a &= 1 \\\\[2pt]\n b &= |2\n\\end{align}');
  assert.equal(r.kind, 'env');
  assert.match(r.source, /\\\\\[2pt\]/);
});
test('$ inside comments and escaped \\$ are ignored', () => {
  assert.equal(around('% $x$ comment |here'), null);
  assert.equal(around('cost \\$5 and| $y$'), null);       // the escaped \\$ must not pair with the next $
  assert.equal(around('cost \\$5 and $y|$').source, 'y');
});
test('innermost display structure wins ($x$ inside \\text in align still gives the align)', () => {
  const r = around('\\begin{align*}\n a &= \\text{if $x|$}\n\\end{align*}');
  assert.equal(r.kind, 'env');
});
test('unterminated environment finds nothing', () => {
  assert.equal(around('\\begin{align*}\n a |&= b'), null);
});
test('plain text finds nothing', () => {
  assert.equal(around('just some |text'), null);
});

// ---- resolveSource --------------------------------------------------------
test('scratch: whole text, or the selection when non-empty', () => {
  assert.deepEqual(resolveSource({ isScratch: true, fullText: 'x^2\ny', selectionText: '', offset: 0, configuredMode: 'inline' }),
    { source: 'x^2\ny', mode: 'inline', wholeScratch: true });
  assert.deepEqual(resolveSource({ isScratch: true, fullText: 'x^2\ny', selectionText: 'y', offset: 0, configuredMode: 'display' }),
    { source: 'y', mode: 'display', wholeScratch: false });
});
test('other doc with selection strips delimiters', () => {
  const r = resolveSource({ isScratch: false, fullText: 'ignored', selectionText: '$$ E=mc^2 $$', offset: 0, configuredMode: 'inline' });
  assert.deepEqual(r, { source: 'E=mc^2', mode: 'display', wholeScratch: false });
});
test('other doc without selection falls back to cursor search, or null', () => {
  const { text, offset } = cur('a \\[ q|q \\] b');
  assert.deepEqual(resolveSource({ isScratch: false, fullText: text, selectionText: '', offset, configuredMode: 'inline' }),
    { source: 'qq', mode: 'display', wholeScratch: false });
  assert.equal(resolveSource({ isScratch: false, fullText: 'nothing here', selectionText: '', offset: 3, configuredMode: 'inline' }), null);
});
test('whitespace-only selection counts as no selection', () => {
  const { text, offset } = cur('$a|$');
  assert.equal(resolveSource({ isScratch: false, fullText: text, selectionText: '  \n ', offset, configuredMode: 'display' }).source, 'a');
});

console.log(`\n${passed} passed${process.exitCode ? ', with failures' : ''}`);
