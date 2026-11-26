import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { EditorState, TextSelection, Selection } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { history, undo as pmUndo, redo as pmRedo } from 'prosemirror-history';

import { schema } from '../src/schema.js';
import { SourceContextStep } from '../src/context-step.js';
import { parseDocumentContainer, parseHTMLToNodes, inspectAndCleanClipboardHTML } from '../src/parser.js';
import { serializeDocument, serializeBlockNode } from '../src/serializer.js';
import { executeVisualCommand, buildKeymap, buildInputRules } from '../src/commands.js';
import { saveAppearance, diffAppearance, createDiagnosticsController } from '../src/diagnostics.js';
import { installFastraVisualBridge } from '../src/bridge.js';

function createDOMEnv(html = '') {
  const dom = new JSDOM(`<!DOCTYPE html><html><body><div id="fastra-visual">${html}</div></body></html>`, { pretendToBeVisual: true });
  const { window } = dom;
  const { document } = window;
  if (!window.Range.prototype.getClientRects) {
    window.Range.prototype.getClientRects = () => [];
    window.Range.prototype.getBoundingClientRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 });
  }
  if (!window.Element.prototype.getClientRects) {
    window.Element.prototype.getClientRects = () => [];
  }
  globalThis.window = window;
  globalThis.document = document;
  return { dom, window, document, root: document.getElementById('fastra-visual') };
}

function makeView(root, doc) {
  const km = buildKeymap({
    schema,
    isBlocked: () => false,
    onUndo: () => pmUndo(view.state, tr => view.dispatch(tr)),
    onRedo: () => pmRedo(view.state, tr => view.dispatch(tr))
  });
  const state = EditorState.create({
    schema,
    doc,
    plugins: [history(), buildInputRules(schema), km]
  });
  const view = new EditorView(root, { state });
  return view;
}

test('test_1.md: blank_line (.fastra-visible-blank-line) converts cleanly to H2 when collapsed or selected', () => {
  const { document, root } = createDOMEnv(
    '<div data-md-block="0"><h1>Kopf</h1></div>' +
    '<div data-md-block="1"><div class="fastra-visible-blank-line"><br></div></div>' +
    '<div data-md-block="2"><p>Danach</p></div>'
  );
  const blocks = [
    { id: 0, hidden: false, source: '# Kopf\n\n' },
    { id: 1, hidden: false, source: '  \n\n' },
    { id: 2, hidden: false, source: 'Danach\n' }
  ];
  const { doc, parsedGroups } = parseDocumentContainer(root, blocks, { schema, ownerDocument: document });
  assert.equal(doc.childCount, 3);
  assert.equal(doc.child(1).type.name, 'blank_line');

  const originals = new Map();
  const hiddenPrefixes = new Map();
  blocks.forEach(b => {
    const p = parsedGroups.get(String(b.id));
    originals.set(String(b.id), { source: b.source, ...p });
  });
  const contexts = new Map([['', { blocks, hiddenPrefixes, trailingHidden: new Set(), trailingOwner: '2' }]]);

  while (root.firstChild) root.firstChild.remove();
  const view = makeView(root, doc);

  // Cursor genau in die `blank_line` setzen (Block 1).
  const posInsideBlank = doc.child(0).nodeSize + 1;
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, posInsideBlank)));

  const res = executeVisualCommand(view, 'heading2', null, { schema });
  assert.equal(res.executed, true);
  assert.equal(res.changed, true);
  assert.equal(view.state.doc.child(1).type.name, 'heading');
  assert.equal(view.state.doc.child(1).attrs.level, 2);

  // Tippen nach H2-Umwandlung und Serialisieren prüfen.
  view.dispatch(view.state.tr.insertText('Neu'));
  const md = serializeDocument(view.state.doc, { contexts, originals });
  assert.equal(md, '# Kopf\n\n## Neu\n\nDanach\n');

  // Undo stellt die sichtbare Leerzeile & ursprüngliche Quelle verlustfrei wieder her.
  pmUndo(view.state, tr => view.dispatch(tr)); // Tippen rückgängig
  pmUndo(view.state, tr => view.dispatch(tr)); // H2 rückgängig
  assert.equal(view.state.doc.child(1).type.name, 'blank_line');
  assert.equal(serializeDocument(view.state.doc, { contexts, originals }), '# Kopf\n\n  \n\nDanach\n');
  view.destroy();
});

test('partial multi-subblock survival: editing subblock 1 forces clean full re-serialization without stale original source', () => {
  const { document, root } = createDOMEnv('<div data-md-block="0"><p>Eins</p><p>Zwei</p></div>');
  const blocks = [{ id: 0, hidden: false, source: 'Eins\n\nZwei\n' }];
  const { doc, parsedGroups } = parseDocumentContainer(root, blocks, { schema, ownerDocument: document });
  assert.equal(doc.childCount, 2);
  assert.equal(doc.child(0).attrs.mdBlockTotal, 2);

  const originals = new Map([['0', { source: blocks[0].source, ...parsedGroups.get('0') }]]);
  const contexts = new Map([['', { blocks, hiddenPrefixes: new Map(), trailingHidden: new Set(), trailingOwner: '0' }]]);

  assert.equal(serializeDocument(doc, { contexts, originals }), 'Eins\n\nZwei\n');

  // Zweiten Unterblock ändern -> Original darf nicht wiederverwendet werden.
  while (root.firstChild) root.firstChild.remove();
  const view = makeView(root, doc);
  const posInSecond = doc.child(0).nodeSize + 1 + doc.child(1).content.size;
  view.dispatch(view.state.tr.insertText('!!', posInSecond));
  assert.equal(serializeDocument(view.state.doc, { contexts, originals }), 'Eins\n\nZwei!!\n');

  // Ersten Unterblock löschen -> nur verbliebener zweiter Teil (Sub 1 != 0) -> kein Stale-Source-Reuse.
  pmUndo(view.state, tr => view.dispatch(tr));
  view.dispatch(view.state.tr.delete(0, doc.child(0).nodeSize));
  assert.equal(serializeDocument(view.state.doc, { contexts, originals }), 'Zwei\n\n');
  view.destroy();
});

test('Finding #7: heading & list commands work cleanly on loose and nested lists', () => {
  const { document, root } = createDOMEnv(
    '<div data-md-block="0"><ul>' +
    '<li><p>Oberpunkt</p><ul><li><p>Unterpunkt</p></li></ul></li>' +
    '<li><p>Zweiter</p></li>' +
    '</ul></div>'
  );
  const { doc } = parseDocumentContainer(root, [{ id: 0, hidden: false, source: '' }], { schema, ownerDocument: document });
  while (root.firstChild) root.firstChild.remove();
  const view = makeView(root, doc);

  // Cursor in verschachtelten Unterpunkt ("Unterpunkt").
  let targetPos = null;
  view.state.doc.descendants((node, pos) => {
    if (node.isText && node.text === 'Unterpunkt') {
      targetPos = pos + 2;
      return false;
    }
    return true;
  });
  assert.ok(targetPos !== null);
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, targetPos)));

  const hRes = executeVisualCommand(view, 'heading2', null, { schema });
  assert.equal(hRes.executed, true);
  assert.equal(hRes.changed, true);

  const md = serializeDocument(view.state.doc, {});
  assert.ok(md.includes('## Unterpunkt'), `Expected heading2 in serialized output, got: ${md}`);
  assert.ok(md.includes('Oberpunkt'), 'Outer list item must survive');
  assert.ok(md.includes('Zweiter'), 'Sibling list item must survive');
  view.destroy();
});

test('Finding #2: diagnosticReport redacts snippets/summaries when includeContent=false', () => {
  const { document, root } = createDOMEnv('<p>Geheimer Text im Absatz</p>');
  const sent = [];
  const diag = createDiagnosticsController({
    postMessage: msg => sent.push(msg),
    getSession: () => 'sess-1',
    getRevision: () => 3,
    getRoot: () => root,
    isFenced: () => false,
    isComposing: () => false,
    getLastInputType: () => 'insertText',
    serializeMarkdown: () => 'Geheimer Text im Absatz\n'
  });

  diag.inspect('<p>Abweichender Geheimtext</p>');
  diag.recordAnomaly('command-exception', 'Geheimer Text im Absatz: Fehler', { command: 'bold', rawSecret: 'LEAK' });

  const redacted = diag.report(false);
  const jsonRedacted = JSON.stringify(redacted);
  assert.ok(!jsonRedacted.includes('Geheimer Text'), 'Redacted report must not contain live document text');
  assert.ok(!jsonRedacted.includes('Abweichender'), 'Redacted report must not contain saved snippet text');
  assert.ok(!jsonRedacted.includes('LEAK'), 'Redacted report must strip unknown anomaly keys');
  assert.ok(sent.every(m => !String(m.summary || '').includes('Geheimer Text')));

  const full = diag.report(true);
  assert.ok(JSON.stringify(full).includes('Geheimer Text'));
});

test('diagnostics track block-type mismatches (paragraph vs heading2 / list) as format diff', () => {
  const { document } = createDOMEnv('');
  const live = document.createElement('div');
  live.innerHTML = '<h2>Titel</h2>';
  const saved = document.createElement('div');
  saved.innerHTML = '<p>Titel</p>';

  const diff = diffAppearance(saveAppearance(live), saveAppearance(saved), { includeContent: false });
  assert.equal(diff.outcome, 'format');
});

test('CommonMark flanking, &nbsp;, code span backticks, and HTML inline marks roundtrip cleanly', () => {
  const html = '<p><strong>!</strong>A&nbsp;B <code>x`y</code> <mark>==z==</mark> <u title="hint">Unter</u></p>';
  const nodes = parseHTMLToNodes(html, { schema, ownerDocument: document });
  const doc = schema.nodes.doc.create(null, nodes);
  const md = serializeBlockNode(doc.firstChild, {});
  assert.ok(md.includes('<strong>!</strong>'), `Expected HTML fallback for flanking punctuation: ${md}`);
  assert.ok(md.includes('A&nbsp;B'), `Expected &nbsp; preserved: ${md}`);
  assert.ok(md.includes('`` x`y ``') || md.includes('``x`y``'), `Expected multi-backtick fence for code span: ${md}`);
  assert.ok(md.includes('<mark>\\=\\=z\\=\\=</mark>'), `Expected <mark> fallback when = touches highlight: ${md}`);
  assert.ok(md.includes('<u title="hint">Unter</u>'), `Expected inline html attribute preservation: ${md}`);
});

test('SourceContextStep makes definitions-only replaceSource cleanly undoable and redoable', () => {
  const { document, root } = createDOMEnv('<div data-md-block="0"><p data-md-empty="true"><br></p></div>');
  const { doc } = parseDocumentContainer(root, [{ id: 0, hidden: false, source: '' }], { schema, ownerDocument: document });
  while (root.firstChild) root.firstChild.remove();
  const view = makeView(root, doc);

  const ctx0 = { blocks: [{ id: '0', hidden: true, source: '[a]: /eins\n' }], hiddenPrefixes: new Map(), trailingHidden: new Set(), trailingOwner: null };
  const ctx1 = { blocks: [{ id: 'r0', hidden: true, source: '[a]: /zwei\n' }], hiddenPrefixes: new Map(), trailingHidden: new Set(), trailingOwner: null };
  const contexts = new Map([['', ctx0], ['r:', ctx1]]);

  assert.equal(serializeDocument(view.state.doc, { contexts }), '[a]: /eins\n');

  const tr = view.state.tr;
  tr.step(new SourceContextStep('r:', ''));
  view.dispatch(tr);
  assert.equal(view.state.doc.attrs.sourceContext, 'r:');
  assert.equal(serializeDocument(view.state.doc, { contexts }), '[a]: /zwei\n');

  assert.equal(pmUndo(view.state, t => view.dispatch(t)), true);
  assert.equal(serializeDocument(view.state.doc, { contexts }), '[a]: /eins\n');

  assert.equal(pmRedo(view.state, t => view.dispatch(t)), true);
  assert.equal(serializeDocument(view.state.doc, { contexts }), '[a]: /zwei\n');
  view.destroy();
});

test('clipboard inspection validates and preserves safe formatting and rejects unsafe protocols', () => {
  const { document } = createDOMEnv('');
  const bad = inspectAndCleanClipboardHTML('<a href="javascript:alert(1)">bad</a>', false, document);
  assert.equal(bad.ok, false);
  assert.equal(bad.reason, 'url');

  const good = inspectAndCleanClipboardHTML('<p><span style="font-weight:bold;background-color:#ffee9a">Hi</span></p>', false, document);
  assert.equal(good.ok, true);
  assert.ok(good.html.includes('<strong>'));
  assert.ok(good.html.includes('<mark>'));
});

test('blank_line promotes to paragraph on typing and repeated trailing hard breaks serialize cleanly without <br><br>', () => {
  const { document, root } = createDOMEnv(
    '<div data-md-block="0"><div class="fastra-visible-blank-line"><br></div></div>'
  );
  const { doc } = parseDocumentContainer(root, [{ id: 0, hidden: false, source: '  \n\n' }], { schema, ownerDocument: document });
  assert.equal(doc.firstChild.type.name, 'blank_line');

  // Text direkt in `blank_line` serialisiert als Text (auch vor Plugin-Umwandlung).
  const typedDoc = doc.type.create(doc.attrs, doc.firstChild.type.create(doc.firstChild.attrs, schema.text('Eingabe')));
  assert.equal(serializeBlockNode(typedDoc.firstChild, {}), 'Eingabe');

  // Absatz mit zwei abschließenden `hard_break`-Knoten -> zwei sichtbare `  `-Leerzeilen ohne `<br><br>`.
  const p = schema.nodes.paragraph.create(null, [
    schema.text('Zeile 1'),
    schema.nodes.hard_break.create(),
    schema.nodes.hard_break.create()
  ]);
  const md = serializeBlockNode(p, {});
  assert.equal(md, 'Zeile 1\n\n  \n\n  ');
});

test('ordered list start order, tight/loose separation, dynamic code fences, and opaque atoms roundtrip cleanly', () => {
  const html =
    '<ol start="3"><li>Drei</li><li>Vier<ul><li>Unter</li></ul></li></ol>' +
    '<pre><code class="language-js">const x = ```fence```;</code></pre>' +
    '<div data-md-opaque="k1"><svg><g></g></svg></div>';
  const nodes = parseHTMLToNodes(html, { schema, ownerDocument: document });
  const doc = schema.nodes.doc.create(null, nodes);

  const listMd = serializeBlockNode(doc.child(0), {});
  assert.ok(listMd.startsWith('3. Drei\n'), `Expected start="3": ${listMd}`);
  assert.ok(listMd.includes('4. Vier\n'), `Expected sequential index 4: ${listMd}`);
  assert.ok(listMd.includes('   - Unter'), `Expected nested bullet indent: ${listMd}`);

  const codeMd = serializeBlockNode(doc.child(1), {});
  assert.ok(codeMd.startsWith('````js\n'), `Expected 4-backtick fence around triple backticks: ${codeMd}`);

  const opaqueMd = serializeBlockNode(doc.child(2), {
    opaqueSources: { k1: '```mermaid\ngraph LR; A-->B\n```' }
  });
  assert.equal(opaqueMd, '```mermaid\ngraph LR; A-->B\n```');
});

test('mounted bridge sends base in change, mounts directly on #fastra-visual, keeps Undo on same-session restart, and redacts printable keys', async () => {
  const { window, document, root } = createDOMEnv('<div data-md-block="0"><p>abc</p></div>');
  document.documentElement.setAttribute('data-fastra-enhanced', 'true');

  const messages = [];
  window.webkit = {
    messageHandlers: {
      visualMarkdown: { postMessage: m => messages.push(m) },
      markdownCopy: { postMessage: m => messages.push({ handler: 'copy', ...m }) }
    }
  };

  const api = installFastraVisualBridge();
  const ok = await api.start({
    session: 's1',
    markdown: 'abc',
    blocks: [{ id: 0, hidden: false, source: 'abc' }],
    opaqueSources: {}
  });
  assert.equal(ok, true);
  assert.equal(root.classList.contains('ProseMirror'), true);
  assert.equal(root.isContentEditable || root.contentEditable === 'true', true);
  assert.equal(root.querySelector('.ProseMirror'), null);

  // Tippen / Einfügen sendet `change` MIT `base`.
  api.command('insertText', 'X');
  const change = messages.findLast(m => m.kind === 'change');
  assert.ok(change);
  assert.equal(change.base, 'abc');
  assert.equal(change.markdown, 'Xabc');

  // Same-session restart mit identischem Markdown behält Undo-Verlauf!
  const restarted = await api.start({
    session: 's1',
    markdown: 'Xabc',
    blocks: [{ id: 0, hidden: false, source: 'Xabc' }],
    opaqueSources: {}
  });
  assert.equal(restarted, true);
  assert.equal(api.canUndo(), true);

  // Druckbare Zeichen in keydown-Diagnose werden redigiert.
  root.dispatchEvent(new window.KeyboardEvent('keydown', { key: '文', metaKey: true, bubbles: true }));
  const redacted = api.diagnosticReport(false);
  assert.ok(!JSON.stringify(redacted).includes('文'));
});

test('inline formatting protects math atoms, space-padding flanking preserves spaces, NBSP avoids token collision, and link titles stay escaped', () => {
  const { document, root } = createDOMEnv('<p>before <span data-tex="x">x</span> after</p>');
  const nodes = parseHTMLToNodes(root.innerHTML, { schema, ownerDocument: document });
  const view = makeView(root, schema.nodes.doc.create(null, nodes));
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 2, view.state.doc.content.size - 2)));

  let rejected = false;
  const res = executeVisualCommand(view, 'code', null, {
    schema,
    postMessage: msg => { if (msg.kind === 'protectedFormat') rejected = true; }
  });
  assert.equal(res.executed, false);
  assert.equal(rejected, true);
  view.destroy();

  // Astra #9 & #10 & Sol #16
  const mdNodes = parseHTMLToNodes(
    '<p>a<strong> b </strong>c <mark> d </mark>e FASTRANBSPTOKEN0X\u00a0 <a href="https://example.com/a b" title="Co &amp; copy: &amp;copy;">link</a></p>',
    { schema, ownerDocument: document }
  );
  const md = serializeBlockNode(mdNodes[0], {});
  assert.ok(md.includes('a **b** c'), `Spaces lost around bold: ${md}`);
  assert.ok(md.includes('==d== e'), `Highlight should preserve spaces around marks: ${md}`);
  assert.ok(md.includes('FASTRANBSPTOKEN0X&nbsp;'), `Literal token overwritten: ${md}`);
  assert.ok(md.includes('<https://example.com/a b>'), `Space URL must use angle delimiters: ${md}`);
  assert.ok(md.includes('\\&copy;'), `Entity-like sequence in title must be escaped: ${md}`);

  // Nested mark ordering (**==Marked==**) + code preserveWhitespace
  const nestedDoc = schema.nodes.doc.create(null, parseHTMLToNodes('<p><strong><mark>Marked</mark></strong></p><p><code>A<br>  <br>B</code></p>', { schema, ownerDocument: document }));
  assert.equal(serializeBlockNode(nestedDoc.child(0), {}), '**==Marked==**');
  const codeBlankMd = serializeBlockNode(nestedDoc.child(1), {});
  assert.ok(codeBlankMd.includes('`A`  \n`  `  \n`B`'), `Expected blank code span preserved: ${codeBlankMd}`);
});

test('DOM range selection syncs highlight and copy events, and taskList marks newly wrapped items', async () => {
  const { window, document, root } = createDOMEnv('<div data-md-block="0"><p>Textmarker Punkt</p></div>');
  document.documentElement.setAttribute('data-fastra-enhanced', 'true');
  const copied = [];
  window.webkit = {
    messageHandlers: {
      visualMarkdown: { postMessage: () => {} },
      markdownCopy: { postMessage: m => copied.push(m) }
    }
  };
  const api = installFastraVisualBridge();
  await api.start({
    session: 'sel-test',
    markdown: 'Textmarker Punkt\n',
    blocks: [{ id: 0, hidden: false, source: 'Textmarker Punkt\n' }],
    opaqueSources: {}
  });

  const textNode = root.querySelector('p').firstChild;
  const r = document.createRange();
  r.setStart(textNode, 0);
  r.setEnd(textNode, 10);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(r);
  assert.equal(api.command('highlight'), true);
  assert.equal(root.querySelector('mark')?.textContent, 'Textmarker');

  const markText = root.querySelector('mark').firstChild;
  const copyRange = document.createRange();
  copyRange.setStart(markText, 0);
  copyRange.setEnd(markText, 10);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(copyRange);
  root.dispatchEvent(new window.Event('copy', { bubbles: true, cancelable: true }));
  assert.equal(copied.length, 1);
  assert.equal(copied[0].markdown, '==Textmarker==');

  api.completeClipboard(copied[0].bookmark, false, true);
  assert.equal(api.command('taskList'), true);
  assert.ok(root.querySelector('li[data-task="unchecked"] input[type="checkbox"]'));
});

test('Astra #7, #8 & Sol #12, #13, #14: Enter split without merge, trailing hard break blank lines, list numbering, input rules, checkbox state', () => {
  const { document, root } = createDOMEnv('<div data-md-block="0"><p>abc</p></div>');
  const { doc, parsedGroups } = parseDocumentContainer(root, [{ id: 0, hidden: false, source: 'abc' }], { schema, ownerDocument: document });
  const originals = new Map([['0', { source: 'abc', ...parsedGroups.get('0') }]]);
  while (root.firstChild) root.firstChild.remove();
  const view = makeView(root, doc);

  // Enter mitten in `abc` nach `a` -> zwei getrennte Absätze (`a\n\nbc...`), nie wieder zu `abc` verklebt!
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 2)));
  executeVisualCommand(view, 'insertParagraph', null, { schema });
  const splitMd = serializeDocument(view.state.doc, { originals });
  assert.ok(splitMd.startsWith('a\n\nbc'), `Expected split paragraphs, got: ${splitMd}`);

  // Harter Umbruch am Absatzende -> `Alpha\n\n  `
  const pNode = schema.nodes.paragraph.create(null, [schema.text('Alpha')]);
  const hbView = makeView(document.createElement('div'), schema.nodes.doc.create(null, [pNode]));
  hbView.dispatch(hbView.state.tr.setSelection(TextSelection.create(hbView.state.doc, 6)));
  executeVisualCommand(hbView, 'hardBreak', null, { schema });
  assert.equal(serializeDocument(hbView.state.doc, {}), 'Alpha\n\n  \n\n');
  hbView.destroy();

  // Ordered list start preservation (`4. First`, `5. Second`, `6. Third` -> lift `5.` -> `6. Third`)
  const olNodes = parseHTMLToNodes('<ol start="4"><li>First</li><li>Second</li><li>Third</li></ol>', { schema, ownerDocument: document });
  const olView = makeView(document.createElement('div'), schema.nodes.doc.create(null, olNodes));
  let secondPos = null;
  olView.state.doc.descendants((n, pos) => {
    if (n.isText && n.text === 'Second') { secondPos = pos + 1; return false; }
    return true;
  });
  olView.dispatch(olView.state.tr.setSelection(TextSelection.create(olView.state.doc, secondPos)));
  executeVisualCommand(olView, 'plainParagraph', null, { schema });
  const olMd = serializeDocument(olView.state.doc, {});
  assert.ok(olMd.includes('4. First'), olMd);
  assert.ok(olMd.includes('6. Third'), `Expected 6. Third preserved after middle lift: ${olMd}`);
  olView.destroy();
  view.destroy();
});

test('Regression: blank_line delete collapses to empty markdown and table cells preserve outer spaces', () => {
  const { document } = createDOMEnv('');
  const boldAndBlank = [
    schema.nodes.paragraph.create(null, [schema.text('Bold', [schema.marks.strong.create()])]),
    schema.nodes.blank_line.create()
  ];
  const delView = makeView(document.createElement('div'), schema.nodes.doc.create(null, boldAndBlank));
  const textNodePos = 1;
  const blankEndPos = boldAndBlank[0].nodeSize + boldAndBlank[1].nodeSize - 1;
  delView.dispatch(delView.state.tr.setSelection(TextSelection.create(delView.state.doc, textNodePos, blankEndPos)));
  executeVisualCommand(delView, 'delete', null, { schema });
  assert.equal(serializeDocument(delView.state.doc, { lastInputType: 'deleteContentBackward' }), '');
  delView.destroy();

  const tableNodes = parseHTMLToNodes(
    '<table data-md-table="gfm"><thead><tr><th>  A  B  </th><th>C</th></tr></thead><tbody><tr><td> </td><td>  D  </td></tr></tbody></table>',
    { schema, ownerDocument: document }
  );
  const cells = [];
  tableNodes[0].descendants(n => {
    if (n.type.name === 'table_header' || n.type.name === 'table_cell') cells.push(n.textContent);
    return true;
  });
  assert.deepEqual(cells, ['  A  B  ', 'C', ' ', '  D  ']);

  // 1) Gelöschtes Dokument mit trailing verstecktem Whitespace-Block (`"\n\n"`) -> `""`
  const boldCtxBlocks = [
    { id: 0, hidden: false, source: '**Bold**\n\n' },
    { id: 1, hidden: true, source: '\n\n' }
  ];
  const { document: d2, root: r2 } = createDOMEnv('<div data-md-block="0"><p><strong>Bold</strong></p></div>');
  const { doc: d2Doc, parsedGroups: d2Groups } = parseDocumentContainer(r2, boldCtxBlocks, { schema, ownerDocument: d2 });
  const d2Contexts = new Map([['', { blocks: boldCtxBlocks, hiddenPrefixes: new Map(), trailingHidden: new Set([1]), trailingOwner: '0' }]]);
  const d2View = makeView(d2.createElement('div'), d2Doc);
  d2View.dispatch(d2View.state.tr.setSelection(TextSelection.create(d2View.state.doc, 1, d2View.state.doc.content.size - 1)));
  executeVisualCommand(d2View, 'delete', null, { schema });
  assert.equal(serializeDocument(d2View.state.doc, { contexts: d2Contexts, originals: new Map([['0', { source: '**Bold**\n\n', ...d2Groups.get('0') }]]), lastInputType: '' }), '');
  d2View.destroy();

  // 2) `blank_line` (`"  \n"`) + versteckte Trennzeile `"\n"` vor Folgeblock -> nach H2 genau `"\n\n"`
  const t1Blocks = [
    { id: 0, hidden: false, source: '# Titel\n\n' },
    { id: 1, hidden: false, source: '  \n' },
    { id: 2, hidden: true, source: '\n' },
    { id: 3, hidden: false, source: 'Absatz danach\n' }
  ];
  const { document: d3, root: r3 } = createDOMEnv('<div data-md-block="0"><h1>Titel</h1></div><div data-md-block="1"><div class="fastra-visible-blank-line"><br></div></div><div data-md-block="3"><p>Absatz danach</p></div>');
  const { doc: d3Doc, parsedGroups: d3Groups } = parseDocumentContainer(r3, t1Blocks, { schema, ownerDocument: d3 });
  const d3Origins = new Map();
  for (const b of t1Blocks) {
    if (!b.hidden) d3Origins.set(String(b.id), { source: b.source, ...d3Groups.get(String(b.id)) });
  }
  const d3Contexts = new Map([['', { blocks: t1Blocks, hiddenPrefixes: new Map([['3', [t1Blocks[2]]]]), trailingHidden: new Set(), trailingOwner: '3' }]]);
  const d3View = makeView(d3.createElement('div'), d3Doc);
  const blankStart = d3Doc.firstChild.nodeSize + 1;
  d3View.dispatch(d3View.state.tr.setSelection(TextSelection.create(d3Doc, blankStart)));
  executeVisualCommand(d3View, 'heading2', null, { schema });
  executeVisualCommand(d3View, 'insertText', 'Zwischen', { schema });
  assert.equal(serializeDocument(d3View.state.doc, { contexts: d3Contexts, originals: d3Origins }), '# Titel\n\n## Zwischen\n\nAbsatz danach\n');
  d3View.destroy();

  // 3) Tabellenzellen mit Rand- und Mehrfachleerzeichen erhalten `&#32;`
  const tNode = parseHTMLToNodes('<table data-md-table="gfm"><thead><tr><th>  A  B  </th><th>C</th></tr></thead><tbody><tr><td> </td><td>  D  </td></tr></tbody></table>', { schema, ownerDocument: d3 })[0];
  const tMd = serializeBlockNode(tNode, {});
  assert.ok(tMd.includes('&#32;&#32;A&#32;&#32;B&#32;&#32;'), tMd);
  assert.ok(tMd.includes('| &#32; | &#32;&#32;D&#32;&#32; |'), tMd);
});

test('Selection preservation on fence unlock and table selectionchange context update', async () => {
  const { document, window, root } = createDOMEnv(
    '<div data-md-block="0"><p>Hello world</p></div>' +
    '<div data-md-block="1"><table data-md-table="gfm"><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table></div>'
  );
  globalThis.Node = window.Node;
  globalThis.Element = window.Element;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.Text = window.Text;
  globalThis.Range = window.Range;
  globalThis.MutationObserver = window.MutationObserver;
  globalThis.getSelection = () => window.getSelection();
  document.documentElement.setAttribute('data-fastra-enhanced', 'true');
  const messages = [];
  window.webkit = { messageHandlers: { visualMarkdown: { postMessage: m => messages.push(m) }, markdownCopy: { postMessage() {} } } };
  const api = installFastraVisualBridge();
  await api.start({
    session: 's-sel',
    markdown: 'Hello world\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n',
    blocks: [
      { id: 0, hidden: false, source: 'Hello world\n\n' },
      { id: 1, hidden: false, source: '| A | B |\n| --- | --- |\n| 1 | 2 |\n' }
    ],
    opaqueSources: {},
    imageTransactions: {}
  });
  const snap = api.prepareAction('s-sel', 'act-1');
  assert.ok(snap);
  const p = root.querySelector('p');
  const r = document.createRange();
  r.selectNodeContents(p);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(r);
  api.completeAction('s-sel', 'act-1');
  assert.equal(api.command('bold'), true);
  assert.ok(api.markdown().startsWith('**Hello world**'));

  const cells = root.querySelectorAll('td');
  const rCross = document.createRange();
  rCross.setStart(cells[0].firstChild, 0);
  rCross.setEnd(cells[1].firstChild, 1);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(rCross);
  document.dispatchEvent(new window.Event('selectionchange'));
  const tableCtxMsgs = messages.filter(m => m.kind === 'tableContext');
  assert.equal(tableCtxMsgs.at(-1)?.context?.reason, 'selection');
});

test('NodeSelection on image survives selectionchange event', async () => {
  const { document, window, root } = createDOMEnv(
    '<div data-md-block="0"><p><img src="img.png" alt="alt"></p></div>'
  );
  globalThis.Node = window.Node;
  globalThis.Element = window.Element;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.Text = window.Text;
  globalThis.Range = window.Range;
  globalThis.MutationObserver = window.MutationObserver;
  globalThis.getSelection = () => window.getSelection();
  document.documentElement.setAttribute('data-fastra-enhanced', 'true');
  window.webkit = { messageHandlers: { visualMarkdown: { postMessage() {} }, markdownCopy: { postMessage() {} } } };
  const api = installFastraVisualBridge();
  await api.start({
    session: 's-img',
    markdown: '![alt](img.png)\n',
    blocks: [{ id: 0, hidden: false, source: '![alt](img.png)\n' }],
    opaqueSources: {},
    imageTransactions: {}
  });
  const img = root.querySelector('img[src="img.png"]');
  assert.ok(img);
  const p = img.parentNode;
  document.elementFromPoint = () => img;
  globalThis.requestAnimationFrame = () => 0;
  img.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
  assert.equal(img.hasAttribute('data-md-selected-image'), true);

  // WebKit fires a collapsed selectionchange right after img selection; NodeSelection must remain intact.
  const rCollapsed = document.createRange();
  rCollapsed.setStart(p, 0);
  rCollapsed.collapse(true);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(rCollapsed);
  document.dispatchEvent(new window.Event('selectionchange'));
  assert.equal(img.hasAttribute('data-md-selected-image'), true);
});



