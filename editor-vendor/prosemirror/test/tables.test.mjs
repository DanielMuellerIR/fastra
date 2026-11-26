import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { JSDOM } from 'jsdom';
import { gapCursor } from 'prosemirror-gapcursor';
import { history, redo, undo, undoDepth } from 'prosemirror-history';
import { DOMParser } from 'prosemirror-model';
import { EditorState, TextSelection } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { schema } from '../src/schema.js';
import { createTableEditor } from '../src/tables.js';

const browser = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true });
const { window } = browser;
const { document } = window;
globalThis.window = window;
globalThis.document = document;
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
after(() => browser.window.close());

const nodes = schema.nodes;
const bytes = 1048576;
const ok = { ok: true, reason: '' };
const reject = reason => ({ ok: false, reason });
const paragraph = text => nodes.paragraph.create(null, text ? schema.text(text) : null);
const docOf = (...blocks) => nodes.doc.create(null, blocks);

function makeTable(values, attrs = {}, cellAttrs = () => null) {
  return nodes.table.create(attrs, values.map((row, y) => nodes.table_row.create(null,
    row.map((value, x) => (y ? nodes.table_cell : nodes.table_header).create(cellAttrs(y, x),
      typeof value === 'string' ? (value ? schema.text(value) : null) : value)))));
}

function fixture(t, doc, { useDispatch = false } = {}) {
  const mount = document.body.appendChild(document.createElement('div'));
  const transactions = [];
  const reports = [];
  const errors = [];
  let revision = 0;
  let busy = false;
  let allowTransaction = true;
  let editor;
  const view = new EditorView(mount, {
    state: EditorState.create({ schema, doc, plugins: [history(), gapCursor()] }),
    handleScrollToSelection: () => true,
    dispatchTransaction(tr) {
      transactions.push(tr);
      if (tr.docChanged) revision++;
      view.updateState(view.state.apply(tr));
    },
    handleKeyDown: (...args) => editor.handleKeyDown(...args),
    handlePaste: (...args) => editor.handlePaste(...args),
    handleDOMEvents: { copy: (...args) => editor.handleCopy(...args) }
  });
  editor = createTableEditor({
    view, schema, blocked: () => busy, revision: () => revision,
    applyTransaction: useDispatch ? undefined : tr => {
      if (!allowTransaction) return false;
      view.dispatch(tr);
    },
    report: context => reports.push(context), fail: reason => errors.push(reason)
  });
  t.after(() => {
    editor.destroy();
    view.destroy();
    mount.remove();
  });

  function cell(y, x, tableIndex = 0) {
    const tables = [];
    view.state.doc.descendants((node, pos) => {
      if (node.type !== nodes.table) return true;
      tables.push({ node, pos });
      return false;
    });
    const { node, pos } = tables[tableIndex];
    const row = node.child(y);
    const start = pos + 3 + node.children.slice(0, y).reduce((sum, n) => sum + n.nodeSize, 0) +
      row.children.slice(0, x).reduce((sum, n) => sum + n.nodeSize, 0);
    const selected = row.child(x);
    return { start, end: start + selected.content.size, node: selected };
  }

  function select(from, to = from) {
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to)));
  }

  function selectCell(y, x, all = false, tableIndex = 0) {
    const { start, end } = cell(y, x, tableIndex);
    select(start, all ? end : start);
  }

  function key(key, options = {}) {
    const event = new window.KeyboardEvent('keydown', { key, cancelable: true, bubbles: true, ...options });
    view.dom.dispatchEvent(event);
    return event.defaultPrevented;
  }

  function clipboard(type, entries = {}, throughView = false) {
    const event = new window.Event(type, { cancelable: true, bubbles: true });
    const data = { ...entries };
    Object.defineProperty(event, 'clipboardData', { value: {
      getData: mime => data[mime] ?? '', setData: (mime, value) => { data[mime] = value; }, files: []
    } });
    let handled;
    if (throughView) handled = !view.dom.dispatchEvent(event);
    else handled = type === 'paste' ? editor.handlePaste(event) : editor.handleCopy(event);
    return { handled, prevented: event.defaultPrevented, data };
  }

  return { view, editor, transactions, reports, errors, cell, select, selectCell, key, clipboard,
    setBusy: value => { busy = value; }, setTransactionAllowed: value => { allowTransaction = value; } };
}

function tableIn(view) {
  let table;
  view.state.doc.descendants(node => {
    if (table || node.type !== nodes.table) return !table;
    table = node;
    return false;
  });
  return table;
}

const values = view => tableIn(view).children.map(row => row.children.map(cell => cell.textContent));

function position(editor) {
  const context = editor.context();
  return [context.row, context.column];
}

test('insertTable inserts a GFM header and empty data cells at the caret', t => {
  const f = fixture(t, docOf(paragraph('beforeafter')), { useDispatch: true });
  f.select(7);
  assert.equal(f.editor.context(), null);
  assert.deepEqual(f.editor.execute('insertTable', { rows: 3, cols: 2 }), ok);
  assert.deepEqual(f.view.state.doc.children.map(node => node.type.name), ['paragraph', 'table', 'paragraph']);
  assert.equal(f.view.state.doc.firstChild.textContent, 'before');
  assert.equal(f.view.state.doc.lastChild.textContent, 'after');
  assert.equal(tableIn(f.view).attrs.gfm, true);
  assert.deepEqual(tableIn(f.view).children.map(row => row.children.map(cell => cell.type.name)), [
    ['table_header', 'table_header'], ['table_cell', 'table_cell'], ['table_cell', 'table_cell']
  ]);
  assert.deepEqual(values(f.view), [['', ''], ['', ''], ['', '']]);
  assert.deepEqual(position(f.editor), [0, 0]);
  assert.equal(f.view.state.selection.from, f.cell(0, 0).start);
  assert.equal(f.view.dom.querySelectorAll('th').length, 2);
  assert.equal(f.view.state.doc.check(), undefined);
  assert.deepEqual(f.editor.insertTable(1, 1), reject('format'));
});

test('table insertion validates dimensions and leaves an editable paragraph at the end', t => {
  const f = fixture(t, docOf(paragraph('start')));
  f.select(6);
  for (const [rows, cols] of [[0, 1], [1, 0], [2.5, 2], [1, '2'], [1001, 1], [1, 101], [101, 100]]) {
    assert.deepEqual(f.editor.insertTable(rows, cols), reject('size'));
  }
  assert.deepEqual(f.editor.insertTable(1, 1), ok);
  assert.deepEqual(f.view.state.doc.children.map(node => node.type.name), ['paragraph', 'table', 'paragraph']);
  assert.equal(f.view.state.doc.lastChild.content.size, 0);
});

test('Tab and Shift-Tab select whole cells and cross the row boundary', t => {
  const f = fixture(t, docOf(paragraph('before'), makeTable([['A', 'B'], ['alpha', 'beta']])));
  f.selectCell(0, 0);
  assert.equal(f.key('Tab'), true);
  assert.deepEqual(position(f.editor), [0, 1]);
  assert.equal(f.view.state.selection.from, f.cell(0, 1).start);
  assert.equal(f.view.state.selection.to, f.cell(0, 1).end);
  assert.equal(f.key('Tab'), true);
  assert.deepEqual(position(f.editor), [1, 0]);
  assert.equal(f.view.state.doc.textBetween(f.view.state.selection.from, f.view.state.selection.to), 'alpha');
  assert.equal(f.key('Tab', { shiftKey: true }), true);
  assert.deepEqual(position(f.editor), [0, 1]);
  f.selectCell(0, 0);
  assert.equal(f.key('Tab', { shiftKey: true }), true);
  assert.equal(f.editor.context(), null);
  assert.equal(f.view.state.selection.$from.parent.textContent, 'before');
  assert.equal(undoDepth(f.view.state), 0);
});

test('Shift-Tab at the start of a document leaves the first table without inserting content', t => {
  const f = fixture(t, docOf(makeTable([['A']])));
  f.selectCell(0, 0);
  const initial = f.view.state.doc;
  assert.equal(f.key('Tab', { shiftKey: true }), true);
  assert.equal(f.view.state.selection.from, 0);
  assert.equal(f.editor.context(), null);
  assert.equal(f.view.state.doc, initial);
});

test('Tab in the last cell appends exactly one body row and selects its first cell', t => {
  const f = fixture(t, docOf(makeTable([['A', 'B']], {}, (_, x) => ({ align: x ? 'right' : 'center' }))));
  f.selectCell(0, 1);
  const before = f.transactions.length;
  assert.equal(f.key('Tab'), true);
  assert.equal(f.transactions.length, before + 1);
  assert.deepEqual(values(f.view), [['A', 'B'], ['', '']]);
  assert.deepEqual(position(f.editor), [1, 0]);
  assert.equal(f.cell(1, 0).node.type, nodes.table_cell);
  assert.equal(f.cell(1, 0).node.attrs.align, 'center');
  assert.equal(f.cell(1, 1).node.attrs.align, 'right');
  assert.equal(undoDepth(f.view.state), 1);
  assert.equal(undo(f.view.state, f.view.dispatch), true);
  assert.deepEqual(values(f.view), [['A', 'B']]);
  assert.deepEqual(position(f.editor), [0, 1]);
  assert.equal(redo(f.view.state, f.view.dispatch), true);
  assert.deepEqual(values(f.view), [['A', 'B'], ['', '']]);
});

test('Enter and Shift/Option-Enter insert an inline hard break; Escape leaves the table', t => {
  const f = fixture(t, docOf(makeTable([['A'], ['old']]), paragraph('after')));
  f.selectCell(1, 0, true);
  assert.equal(f.key('Enter'), true);
  assert.equal(f.cell(1, 0).node.firstChild.type, nodes.hard_break);
  assert.equal(f.key('Enter', { shiftKey: true }), true);
  assert.equal(f.key('Enter', { altKey: true }), true);
  assert.equal(f.cell(1, 0).node.childCount, 3);
  assert.equal(f.key('Tab', { altKey: true }), false);
  assert.equal(f.key('Enter', { metaKey: true }), false);
  assert.equal(f.key('Enter', { isComposing: true }), false);
  const initial = f.view.state.doc;
  assert.equal(f.key('Escape'), true);
  assert.equal(f.view.state.selection.$from.parent.textContent, 'after');
  assert.equal(f.view.state.doc, initial);
  assert.equal(f.reports.at(-1), null);
});

test('row edits preserve the header, column alignment, original metadata, and focus', t => {
  const f = fixture(t, docOf(makeTable([['A', 'B'], ['r1', 'one'], ['r2', 'two']],
    { mdContext: 'source', mdBlockId: 'block' }, (_, x) => ({ align: x ? 'center' : null }))));
  f.selectCell(0, 1);
  const context = f.editor.context();
  assert.equal(context.inTable, true);
  assert.equal(context.rowCount, 3);
  assert.equal(context.colCount, 2);
  assert.equal(context.canAddRowBefore, false);
  assert.equal(context.canAddRowAfter, true);
  assert.equal(context.canDeleteRow, false);
  assert.equal(context.canMoveRowDown, false);
  assert.deepEqual(f.editor.execute('insertRowBefore'), reject('edge'));
  assert.deepEqual(f.editor.execute('deleteRow'), reject('edge'));
  assert.deepEqual(f.editor.execute('moveRowDown'), reject('edge'));
  assert.deepEqual(f.editor.command('rowAfter', '', context.token), ok);
  assert.deepEqual(position(f.editor), [1, 1]);
  assert.equal(f.cell(1, 1).node.attrs.align, 'center');
  assert.deepEqual(f.editor.execute('insertRowBefore'), ok);
  assert.deepEqual(values(f.view), [['A', 'B'], ['', ''], ['', ''], ['r1', 'one'], ['r2', 'two']]);
  assert.deepEqual(f.editor.execute('deleteRow'), ok);
  assert.deepEqual(position(f.editor), [1, 1]);
  assert.deepEqual(f.editor.execute('moveRowUp'), reject('edge'));
  f.selectCell(3, 1);
  assert.equal(f.editor.context().canMoveRowUp, true);
  assert.deepEqual(f.editor.execute('moveRowUp'), ok);
  assert.deepEqual(values(f.view), [['A', 'B'], ['', ''], ['r2', 'two'], ['r1', 'one']]);
  assert.deepEqual(position(f.editor), [2, 1]);
  assert.deepEqual(f.editor.execute('moveRowDown'), ok);
  assert.deepEqual(f.editor.execute('deleteRow'), ok);
  assert.deepEqual(position(f.editor), [2, 1]);
  assert.deepEqual(values(f.view), [['A', 'B'], ['', ''], ['r1', 'one']]);
  assert.equal(tableIn(f.view).attrs.mdContext, 'source');
  assert.equal(tableIn(f.view).attrs.mdBlockId, 'block');
});

test('column edits move intact cells and retain the last column', t => {
  const strong = schema.text('data', [schema.marks.strong.create()]);
  const f = fixture(t, docOf(makeTable([['A', 'B'], [strong, 'b']], {}, (_, x) => ({ align: x ? null : 'right' }))));
  f.selectCell(1, 0);
  assert.equal(f.editor.context().canMoveColLeft, false);
  assert.equal(f.editor.context().canMoveColRight, true);
  assert.deepEqual(f.editor.execute('moveColLeft'), reject('edge'));
  assert.deepEqual(f.editor.execute('insertColBefore'), ok);
  assert.equal(f.cell(0, 0).node.type, nodes.table_header);
  assert.equal(f.cell(1, 0).node.type, nodes.table_cell);
  assert.equal(f.cell(1, 0).node.attrs.align, 'right');
  assert.deepEqual(f.editor.execute('insertColAfter'), ok);
  assert.deepEqual(position(f.editor), [1, 1]);
  f.selectCell(1, 2);
  assert.deepEqual(f.editor.command('columnRight'), ok);
  assert.deepEqual(values(f.view), [['', '', 'B', 'A'], ['', '', 'b', 'data']]);
  assert.deepEqual(position(f.editor), [1, 3]);
  assert.equal(f.cell(1, 3).node.firstChild, strong);
  assert.deepEqual(f.editor.execute('moveColRight'), reject('edge'));
  assert.deepEqual(f.editor.execute('moveColLeft'), ok);
  assert.deepEqual(values(f.view), [['', '', 'A', 'B'], ['', '', 'data', 'b']]);
  assert.deepEqual(f.editor.execute('deleteCol'), ok);
  assert.deepEqual(position(f.editor), [1, 2]);
  assert.deepEqual(f.editor.command('deleteColumn'), ok);
  assert.deepEqual(f.editor.execute('deleteCol'), ok);
  assert.equal(f.editor.context().canDeleteCol, false);
  assert.deepEqual(f.editor.execute('deleteCol'), reject('edge'));
  assert.deepEqual(values(f.view), [[''], ['']]);
});

test('alignment cycles across a column and accepts explicit legacy and structured commands', t => {
  const f = fixture(t, docOf(makeTable([['L', 'R'], ['x', 'y']], {}, (_, x) => ({ align: x ? 'right' : null }))));
  f.selectCell(1, 0);
  for (const align of ['left', 'center', 'right', 'none']) {
    assert.deepEqual(f.editor.execute('align', { align: 'cycle' }), ok);
    assert.equal(f.editor.context().align, align);
    assert.equal(f.editor.context().alignment, align === 'none' ? 'default' : align);
    assert.equal(f.cell(0, 0).node.attrs.align, align === 'none' ? null : align);
    assert.equal(f.cell(1, 0).node.attrs.align, align === 'none' ? null : align);
    assert.equal(f.cell(1, 1).node.attrs.align, 'right');
  }
  assert.deepEqual(f.editor.command('alignLeft'), ok);
  assert.deepEqual(f.editor.execute('align', { align: 'center' }), ok);
  assert.deepEqual(f.editor.execute('align', { align: null }), ok);
  assert.deepEqual(f.editor.command('alignRight'), ok);
  assert.deepEqual(f.editor.command('alignDefault'), ok);
  assert.deepEqual(f.editor.execute('align', { align: 'middle' }), reject('command'));
});

test('deleteTable removes a table in one step and leaves a paragraph in an otherwise empty document', t => {
  const f = fixture(t, docOf(makeTable([['A'], ['last']])));
  f.selectCell(1, 0);
  assert.deepEqual(f.editor.execute('deleteTable'), ok);
  assert.equal(tableIn(f.view), undefined);
  assert.equal(f.view.state.doc.childCount, 1);
  assert.equal(f.view.state.doc.firstChild.type, nodes.paragraph);
  assert.equal(f.editor.context(), null);
  assert.equal(undo(f.view.state, f.view.dispatch), true);
  assert.deepEqual(values(f.view), [['A'], ['last']]);
  assert.deepEqual(position(f.editor), [1, 0]);
  assert.equal(redo(f.view.state, f.view.dispatch), true);
  assert.equal(tableIn(f.view), undefined);
});

test('TSV paste expands from the selected cell, normalizes line endings and preserves literal text', t => {
  const f = fixture(t, docOf(makeTable([['A', 'B'], ['x', 'y']], {}, (_, x) => ({ align: x ? 'right' : null }))));
  f.selectCell(1, 1);
  const pasted = f.clipboard('paste', { 'text/plain': ' *literal*  \t<em>x</em>\r\n$math$\rsecond\t\r' }, true);
  assert.equal(pasted.handled && pasted.prevented, true);
  assert.deepEqual(values(f.view), [['A', 'B', ''], ['x', ' *literal*  ', '<em>x</em>'], ['', '$math$', ''], ['', 'second', '']]);
  assert.equal(f.cell(1, 2).node.firstChild.marks.length, 0);
  assert.equal(f.cell(2, 1).node.attrs.align, 'right');
  assert.equal(f.cell(2, 2).node.attrs.align, null);
  assert.deepEqual(position(f.editor), [3, 2]);
  assert.equal(f.editor.execute('copyTSV').text, 'A\tB\t\nx\t *literal*  \t<em>x</em>\n\t$math$\t\n\tsecond\t');
});

test('ragged TSV lines leave unsupplied cells intact and focus the last supplied field', t => {
  const f = fixture(t, docOf(makeTable([['H1', 'H2', 'H3'], ['a', 'b', 'c'], ['d', 'e', 'f']])));
  f.selectCell(1, 0);
  assert.deepEqual(f.editor.command('pasteTSV', 'u\tv\t\nw\n'), ok);
  assert.deepEqual(values(f.view), [['H1', 'H2', 'H3'], ['u', 'v', ''], ['w', 'e', 'f']]);
  assert.deepEqual(position(f.editor), [2, 0]);
});

test('TSV export copies a reversed cell rectangle and flattens in-cell delimiters', t => {
  const multiline = [schema.text('a'), nodes.hard_break.create(), schema.text('b\tc')];
  const f = fixture(t, docOf(makeTable([['A', 'B', 'C'], [multiline, 'y', 'z'], ['d', 'e', 'f']])));
  f.select(f.cell(2, 0).end, f.cell(1, 1).start);
  const result = f.clipboard('copy', {}, true);
  assert.equal(result.handled && result.prevented, true);
  assert.equal(result.data['text/plain'], 'a b c\ty\nd\te');
  f.selectCell(1, 1, true);
  assert.equal(f.clipboard('copy').handled, false);
  assert.deepEqual(f.editor.execute('copyTSV'), { ...ok, text: 'A\tB\tC\na b c\ty\tz\nd\te\tf' });
});

test('a trailing empty row in a single-column TSV export survives import', t => {
  const f = fixture(t, docOf(makeTable([['A'], ['']]), makeTable([['B']])));
  f.selectCell(0, 0);
  const exported = f.editor.execute('copyTSV');
  assert.deepEqual(exported, { ...ok, text: 'A\n\n' });
  f.selectCell(0, 0, false, 1);
  assert.deepEqual(f.editor.execute('pasteTSV', exported), ok);
  assert.equal(f.editor.context().rowCount, 2);
  assert.equal(f.cell(0, 0, 1).node.textContent, 'A');
  assert.equal(f.cell(1, 0, 1).node.textContent, '');
});

test('TSV rejects rows, columns, rectangular cell counts and UTF-8 bytes over the limit atomically', t => {
  const f = fixture(t, docOf(makeTable([['original']])));
  f.selectCell(0, 0);
  const initial = f.view.state.doc;
  const before = f.transactions.length;
  const width100 = Array(100).fill('x').join('\t');
  for (const text of ['x\n'.repeat(1001), '\t'.repeat(100), `${width100}\n`.repeat(101),
    'x'.repeat(bytes + 1), 'é'.repeat(bytes / 2 + 1)]) {
    assert.deepEqual(f.editor.execute('pasteTSV', { text }), reject('size'));
    assert.equal(f.view.state.doc, initial);
  }
  const result = f.clipboard('paste', { 'text/plain': '\t'.repeat(100) });
  assert.equal(result.handled && result.prevented, true);
  assert.deepEqual(f.errors, ['size']);
  assert.equal(f.transactions.length, before);
});

test('TSV accepts exactly 1,000 rows and Tab at that limit leaves the contents unchanged', t => {
  const f = fixture(t, docOf(makeTable([['original']])));
  f.selectCell(0, 0);
  assert.deepEqual(f.editor.execute('pasteTSV', { text: 'x\n'.repeat(1000) }), ok);
  assert.equal(f.editor.context().rowCount, 1000);
  assert.deepEqual(position(f.editor), [999, 0]);
  const initial = f.view.state.doc;
  assert.equal(f.editor.context().canAddRowAfter, false);
  assert.deepEqual(f.editor.execute('pasteTSV', { text: 'x\ny' }), reject('size'));
  assert.equal(f.key('Tab'), true);
  assert.deepEqual(f.errors, ['size']);
  assert.equal(f.view.state.doc, initial);
});

test('TSV accepts exactly 100 columns and 10,000 cells and checks expansion from the current cell', t => {
  const f = fixture(t, docOf(makeTable([['original']])));
  f.selectCell(0, 0);
  const wideRow = Array(100).fill('x').join('\t');
  assert.deepEqual(f.editor.execute('pasteTSV', { text: `${wideRow}\n`.repeat(100) }), ok);
  assert.equal(f.editor.context().rowCount, 100);
  assert.equal(f.editor.context().colCount, 100);
  assert.deepEqual(position(f.editor), [99, 99]);
  const initial = f.view.state.doc;
  assert.equal(f.editor.context().canAddColAfter, false);
  assert.equal(f.editor.context().canAddRowBefore, false);
  assert.deepEqual(f.editor.execute('insertColBefore'), reject('size'));
  assert.deepEqual(f.editor.execute('insertRowBefore'), reject('size'));
  assert.deepEqual(f.editor.execute('pasteTSV', { text: 'x\ty' }), reject('size'));
  assert.deepEqual(f.editor.execute('pasteTSV', { text: 'x\ny' }), reject('size'));
  assert.equal(f.view.state.doc, initial);
});

test('TSV and pasteCell accept exactly 1 MiB of UTF-8 and reject an oversized export', t => {
  const f = fixture(t, docOf(makeTable([['A', 'B']])));
  f.selectCell(0, 0);
  const text = 'é'.repeat(bytes / 2);
  assert.deepEqual(f.editor.execute('pasteTSV', { text }), ok);
  assert.equal(f.cell(0, 0).node.textContent, text);
  assert.deepEqual(f.editor.execute('copyTSV'), reject('size'));
  f.selectCell(0, 1);
  assert.deepEqual(f.editor.execute('pasteCell', { text }), ok);
  assert.equal(f.cell(0, 1).node.textContent, text);
  assert.deepEqual(f.editor.execute('pasteCell', { text: `${text}!` }), reject('size'));
});

test('single-line pasteCell sanitizes HTML, keeps inline marks and adds no hard break on redo', t => {
  const f = fixture(t, docOf(makeTable([['old']])));
  f.selectCell(0, 0, true);
  const input = '\n<div><p><strong style="font-size:99px">new</strong><script>discard</script>' +
    '<a href="javascript:discard()" onclick="discard()">bad</a><img src="data:image/png;base64,abc">' +
    '<a href="https://example.test" title="Safe">safe</a></p></div>\n';
  assert.deepEqual(f.editor.command('pasteCell', input), ok);
  const cell = f.cell(0, 0).node;
  assert.equal(cell.textContent, 'newbadsafe');
  assert.deepEqual(cell.children.map(node => node.marks.map(mark => mark.type.name)), [['strong'], [], ['link']]);
  assert.equal(cell.lastChild.marks[0].attrs.href, 'https://example.test');
  assert.equal(f.view.dom.querySelector('strong').getAttribute('style'), null);
  assert.equal(f.view.dom.querySelector('br'), null);
  assert.equal(undo(f.view.state, f.view.dispatch), true);
  assert.equal(f.cell(0, 0).node.textContent, 'old');
  assert.equal(redo(f.view.state, f.view.dispatch), true);
  assert.ok(f.cell(0, 0).node.eq(cell));
  assert.equal(f.view.dom.querySelector('br'), null);
});

test('pasteCell rejects line and block breaks and keeps plain-text angle brackets literal', t => {
  const f = fixture(t, docOf(makeTable([['old']])));
  f.selectCell(0, 0, true);
  for (const html of ['a<br>b', '<p>a</p><div>b</div>', '<h1>a</h1>', '<table><tr><td>a</td></tr></table>', 'a\nb']) {
    assert.deepEqual(f.editor.execute('pasteCell', { html }), reject('format'));
  }
  assert.deepEqual(f.editor.execute('pasteCell', { text: 'a\r\nb' }), reject('format'));
  assert.equal(f.cell(0, 0).node.textContent, 'old');
  const result = f.clipboard('paste', { 'text/plain': ' <b>literal</b>  ' });
  assert.equal(result.handled && result.prevented, true);
  assert.equal(f.cell(0, 0).node.textContent, ' <b>literal</b>  ');
  assert.equal(f.cell(0, 0).node.firstChild.marks.length, 0);
  assert.deepEqual(f.editor.execute('pasteCell', { text: '' }), ok);
  assert.equal(f.cell(0, 0).node.childCount, 0);
});

test('inline paste into a partial selection preserves unselected content and defers the native Markdown clipboard', t => {
  const image = nodes.image.create({ src: 'local.png' });
  const f = fixture(t, docOf(makeTable([[[schema.text('before'), image, schema.text('after')]]])));
  const { start } = f.cell(0, 0);
  f.select(start, start + 6);
  const result = f.clipboard('paste', { 'text/plain': 'new ', 'text/html': '<p><em>new </em></p>' }, true);
  assert.equal(result.handled && result.prevented, true);
  assert.equal(f.cell(0, 0).node.textContent, 'new after');
  assert.equal(f.cell(0, 0).node.firstChild.marks[0].type, schema.marks.em);
  assert.equal(f.cell(0, 0).node.child(1), image);
  assert.equal(f.view.state.selection.from, start + 4);
  assert.equal(f.clipboard('paste', { 'text/plain': 'native', 'application/x-fastra-markdown': 'native' }).handled, false);
});

test('non-GFM, colspan, rowspan and structurally invalid tables reject changes and preserve the DOM', t => {
  const container = document.createElement('div');
  container.innerHTML = '<table><tr><th colspan="2">A</th></tr><tr><td rowspan="2">B</td><td>C</td></tr><tr><td>D</td></tr></table>';
  const html = DOMParser.fromSchema(schema).parse(container).firstChild;
  const colspan = makeTable([['A', 'B'], ['a', 'b']], {}, (y, x) => !y && !x ? { colspan: 2 } : null);
  const rowspan = makeTable([['A'], ['a']], {}, (y, x) => !y && !x ? { rowspan: 2 } : null);
  const htmlRectangular = makeTable([['A'], ['a']], { gfm: false });
  const ragged = makeTable([['A', 'B'], ['a']]);
  const wrongHeader = nodes.table.create(null, nodes.table_row.create(null, nodes.table_cell.create()));
  const f = fixture(t, docOf(paragraph('before'), html, colspan, rowspan, htmlRectangular, ragged, wrongHeader));
  const initial = f.view.state.doc;
  const sourceHTML = f.view.dom.innerHTML;
  for (let index = 0; index < 6; index++) {
    f.selectCell(0, 0, false, index);
    const context = f.editor.context();
    assert.equal(context.reason, 'html');
    assert.equal(context.protected, true);
    assert.equal(context.merged, index < 3);
    assert.equal(context.canAddRowAfter, false);
    assert.equal(context.canDeleteTable, false);
    for (const command of ['insertRowAfter', 'insertColBefore', 'moveRowUp', 'deleteRow', 'deleteCol', 'align', 'copyTSV', 'pasteTSV', 'pasteCell', 'deleteTable']) {
      assert.deepEqual(f.editor.execute(command, { text: 'new' }), reject('html'));
    }
    assert.equal(f.key('Tab'), false);
  }
  f.selectCell(0, 0);
  assert.equal(f.clipboard('paste', { 'text/plain': 'x\ty' }).handled, true);
  assert.deepEqual(f.errors, ['html']);
  assert.equal(f.view.state.doc, initial);
  assert.equal(f.view.dom.innerHTML, sourceHTML);
  assert.equal(f.view.dom.querySelector('th[colspan="2"]').textContent, 'A');
  assert.equal(f.view.dom.querySelector('td[rowspan="2"]').textContent, 'B');
});

test('cross-cell and cross-table selections cannot restructure or paste into a cell', t => {
  const same = makeTable([['A', 'B'], ['a', 'b']]);
  const f = fixture(t, docOf(paragraph('before'), same, same));
  const initial = f.view.state.doc;
  f.select(f.cell(1, 1).end, f.cell(0, 0).start);
  assert.equal(f.editor.context().reason, 'selection');
  assert.equal(f.editor.context().canDeleteCol, false);
  assert.deepEqual(position(f.editor), [0, 0]);
  assert.deepEqual(f.editor.execute('deleteTable'), reject('selection'));
  assert.equal(f.key('Enter'), true);
  assert.deepEqual(f.errors, ['selection']);
  f.select(f.cell(0, 0).start, f.cell(0, 0, 1).end);
  assert.deepEqual(f.editor.execute('copyTSV'), reject('selection'));
  assert.equal(f.clipboard('paste', { 'text/plain': 'a\tb' }).handled, true);
  f.select(1, f.cell(0, 0).start);
  assert.equal(f.editor.context().reason, 'selection');
  assert.deepEqual(f.editor.insertTable(2, 2), reject('format'));
  assert.equal(f.view.state.doc, initial);
});

test('table tokens reject stale locations and revisions, and transaction fences reach the toolbar', t => {
  const shared = makeTable([['A', 'B']]);
  const f = fixture(t, docOf(shared, shared));
  f.selectCell(0, 0);
  const first = f.editor.context().token;
  f.selectCell(0, 0, false, 1);
  const second = f.editor.context().token;
  assert.notEqual(first, second);
  assert.deepEqual(f.editor.command('rowAfter', '', first), reject('stale'));
  f.setBusy(true);
  assert.equal(f.editor.syncToolbar().reason, 'busy');
  assert.equal(f.reports.at(-1).canAddRowAfter, false);
  assert.deepEqual(f.editor.execute('pasteTSV', { text: 'x' }), reject('busy'));
  assert.equal(f.key('Tab'), false);
  f.setBusy(false);
  f.setTransactionAllowed(false);
  const initial = f.view.state.doc;
  assert.deepEqual(f.editor.command('alignCenter', '', second), reject('stale'));
  assert.equal(f.view.state.doc, initial);
  f.setTransactionAllowed(true);
  f.view.dispatch(f.view.state.tr.insertText('changed'));
  assert.deepEqual(f.editor.command('rowAfter', '', second), reject('stale'));
});

test('the toolbar freezes during mouse selection, inspects HTML on click and detaches on destroy', t => {
  const f = fixture(t, docOf(paragraph('before'), makeTable([['A', 'B']]), makeTable([['HTML']], { gfm: false })));
  f.view.posAtCoords = () => null;
  f.selectCell(0, 0);
  const initial = f.editor.syncToolbar();
  f.view.dom.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true, button: 0 }));
  assert.equal(f.editor.selectingWithMouse, true);
  f.selectCell(0, 1);
  const before = f.reports.length;
  assert.deepEqual(f.editor.syncToolbar(), initial);
  assert.equal(f.reports.length, before);
  document.dispatchEvent(new window.MouseEvent('mouseup', { bubbles: true }));
  assert.equal(f.editor.selectingWithMouse, false);
  assert.equal(f.reports.at(-1).column, 1);
  f.select(1);
  assert.equal(f.editor.handleClick(f.view, f.cell(0, 0, 1).start, new window.MouseEvent('click')), false);
  assert.equal(f.reports.at(-1).reason, 'html');
  f.editor.handleClick(f.view, 1, new window.MouseEvent('click'));
  assert.equal(f.reports.at(-1), null);
  f.editor.destroy();
  f.view.dom.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true, button: 0 }));
  assert.equal(f.editor.selectingWithMouse, false);
});

test('row, column, alignment and TSV edits are separate undo and redo events', t => {
  const f = fixture(t, docOf(makeTable([['A', 'B'], ['a', 'b']])));
  f.selectCell(1, 1);
  const snapshots = [f.view.state.doc];
  for (const [command, payload] of [['insertRowAfter'], ['insertColBefore'], ['alignLeft'], ['pasteTSV', { text: 'x\ty\nz' }]]) {
    assert.deepEqual(f.editor.execute(command, payload), ok);
    snapshots.push(f.view.state.doc);
  }
  assert.equal(undoDepth(f.view.state), 4);
  for (const expected of snapshots.slice(0, -1).reverse()) {
    assert.equal(undo(f.view.state, f.view.dispatch), true);
    assert.ok(f.view.state.doc.eq(expected));
  }
  assert.equal(undo(f.view.state, f.view.dispatch), false);
  assert.deepEqual(position(f.editor), [1, 1]);
  for (const expected of snapshots.slice(1)) {
    assert.equal(redo(f.view.state, f.view.dispatch), true);
    assert.ok(f.view.state.doc.eq(expected));
  }
  assert.equal(redo(f.view.state, f.view.dispatch), false);
});
