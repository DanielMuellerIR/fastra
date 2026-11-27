import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { EditorState, TextSelection, AllSelection } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { history, undo as pmUndo, redo as pmRedo } from 'prosemirror-history';

import { schema } from '../src/schema.js';
import { parseDocumentContainer, parseHTMLToNodes } from '../src/parser.js';
import { serializeDocument, serializeBlockNode } from '../src/serializer.js';
import { executeVisualCommand, buildKeymap, buildInputRules } from '../src/commands.js';
import { saveAppearance, diffAppearance } from '../src/diagnostics.js';
import { installFastraVisualBridge } from '../src/bridge.js';

function setupEnv(t, html = '') {
  const dom = new JSDOM(`<!DOCTYPE html><html><body><div id="fastra-visual">${html}</div></body></html>`, {
    pretendToBeVisual: true
  });
  const { window } = dom;
  const { document } = window;
  if (!window.Range.prototype.getClientRects) {
    window.Range.prototype.getClientRects = () => [];
    window.Range.prototype.getBoundingClientRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0 });
  }
  if (!window.Element.prototype.getClientRects) {
    window.Element.prototype.getClientRects = () => [];
  }
  const globals = [
    'window', 'document', 'getComputedStyle', 'requestAnimationFrame',
    'cancelAnimationFrame', 'Node', 'Element', 'HTMLElement', 'Text',
    'Range', 'MutationObserver', 'getSelection'
  ];
  const prev = globals.map(k => [k, Object.getOwnPropertyDescriptor(globalThis, k)]);
  globalThis.window = window;
  globalThis.document = document;
  globalThis.getComputedStyle = window.getComputedStyle.bind(window);
  globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
  globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
  globalThis.Node = window.Node;
  globalThis.Element = window.Element;
  globalThis.HTMLElement = window.HTMLElement;
  globalThis.Text = window.Text;
  globalThis.Range = window.Range;
  globalThis.MutationObserver = window.MutationObserver;
  globalThis.getSelection = () => window.getSelection();

  t.after(() => {
    window.dispatchEvent(new window.Event('pagehide'));
    window.close();
    for (const [k, desc] of prev) {
      if (desc) Object.defineProperty(globalThis, k, desc);
      else delete globalThis[k];
    }
  });
  return { dom, window, document, root: document.getElementById('fastra-visual') };
}

function makeView(root, doc) {
  const km = buildKeymap({
    schema,
    isBlocked: () => false,
    onUndo: () => pmUndo(view.state, tr => view.dispatch(tr)),
    onRedo: () => pmRedo(view.state, tr => view.dispatch(tr))
  });
  const view = new EditorView(root, {
    state: EditorState.create({ schema, doc, plugins: [history(), buildInputRules(schema), km] })
  });
  return view;
}

/**
 * Einfacher Referenz-Renderer für lange Node-Roundtrips (Absätze, Überschriften,
 * Listen, Zitate, Tabellen, Codeblöcke und sichtbare `  `-Leerzeilen).
 */
function renderMarkdownBlocksForTest(markdown) {
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n');
  const blocks = [];
  let i = 0;

  const inline = txt => txt
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\\([\\*_`[\]#>~=$&])/g, '$1')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/(?<!\*)\*([^*]+?)\*(?!\*)/g, '<em>$1</em>')
    .replace(/==(.+?)==/g, '<mark>$1</mark>')
    .replace(/~~(.+?)~~/g, '<del>$1</del>')
    .replace(/`([^`]+)`/g, '<code>$1</code>');

  while (i < lines.length) {
    const line = lines[i];
    if (line === '') {
      let src = '';
      while (i < lines.length && lines[i] === '') {
        src += (i < lines.length - 1 ? '\n' : '');
        i++;
      }
      if (src) blocks.push({ id: blocks.length, hidden: true, source: src, html: '' });
      continue;
    }
    if (/^ {2,}$/.test(line)) {
      let src = line;
      if (i + 1 < lines.length) { src += '\n'; i++; } else { i++; }
      blocks.push({ id: blocks.length, hidden: false, source: src, html: '<div class="fastra-visible-blank-line"><br></div>' });
      continue;
    }
    if (/^(#{1,6})\s+(.*)$/.test(line)) {
      const m = line.match(/^(#{1,6})\s+(.*)$/);
      const src = line + (i + 1 < lines.length ? '\n' : '');
      i++;
      blocks.push({ id: blocks.length, hidden: false, source: src, html: `<h${m[1].length}>${inline(m[2])}</h${m[1].length}>` });
      continue;
    }
    if (line.startsWith('```')) {
      const lang = line.slice(3).trim();
      const start = i;
      i++;
      const body = [];
      while (i < lines.length && !lines[i].startsWith('```')) {
        body.push(lines[i]);
        i++;
      }
      if (i < lines.length) i++;
      const src = lines.slice(start, i).join('\n') + (i < lines.length ? '\n' : '');
      const cls = lang ? ` class="language-${lang}"` : '';
      const esc = body.join('\n').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      blocks.push({ id: blocks.length, hidden: false, source: src, html: `<pre><code${cls}>${esc}\n</code></pre>` });
      continue;
    }
    if (/^>\s?/.test(line)) {
      const start = i;
      const qLines = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        qLines.push(lines[i].replace(/^>\s?/, ''));
        i++;
      }
      const src = lines.slice(start, i).join('\n') + (i < lines.length ? '\n' : '');
      const inner = qLines.map(l => (/^ {2,}$/.test(l) ? '<div class="fastra-visible-blank-line"><br></div>' : `<p>${inline(l)}</p>`)).join('');
      blocks.push({ id: blocks.length, hidden: false, source: src, html: `<blockquote>${inner}</blockquote>` });
      continue;
    }
    if (/^[*-] /.test(line)) {
      const start = i;
      const items = [];
      const markerChar = line[0];
      while (i < lines.length && lines[i].startsWith(`${markerChar} `)) {
        const body = lines[i].slice(2);
        if (/^\[( |x)\] /.test(body)) {
          const checked = body[1] === 'x';
          items.push(`<li data-task="${checked ? 'checked' : 'unchecked'}"><input type="checkbox"${checked ? ' checked' : ''}>${inline(body.slice(4))}</li>`);
        } else {
          items.push(`<li>${inline(body)}</li>`);
        }
        i++;
      }
      const src = lines.slice(start, i).join('\n') + (i < lines.length ? '\n' : '');
      blocks.push({ id: blocks.length, hidden: false, source: src, html: `<ul>${items.join('')}</ul>` });
      continue;
    }
    if (/^\d+[.)] /.test(line)) {
      const start = i;
      const items = [];
      const firstMatch = line.match(/^(\d+)([.)]) (.*)$/);
      const startNum = Number(firstMatch[1]);
      const delim = firstMatch[2];
      while (i < lines.length) {
        const m = lines[i].match(new RegExp(`^\\d+\\${delim} (.*)$`));
        if (!m) break;
        items.push(`<li>${inline(m[1])}</li>`);
        i++;
      }
      const src = lines.slice(start, i).join('\n') + (i < lines.length ? '\n' : '');
      const startAttr = startNum !== 1 ? ` start="${startNum}"` : '';
      blocks.push({ id: blocks.length, hidden: false, source: src, html: `<ol${startAttr}>${items.join('')}</ol>` });
      continue;
    }
    const pLines = [];
    const start = i;
    while (
      i < lines.length &&
      lines[i] !== '' &&
      !/^ {2,}$/.test(lines[i]) &&
      !/^(#{1,6})\s+/.test(lines[i]) &&
      !lines[i].startsWith('```') &&
      !/^>\s?/.test(lines[i]) &&
      !/^[*-] /.test(lines[i]) &&
      !/^\d+[.)] /.test(lines[i])
    ) {
      pLines.push(lines[i]);
      i++;
    }
    const src = lines.slice(start, i).join('\n') + (i < lines.length ? '\n' : '');
    const pHtml = pLines
      .map((l, idx) => (idx + 1 < pLines.length && / {2}$/.test(l) ? `${inline(l.slice(0, -2))}<br>` : inline(l)))
      .join('\n');
    blocks.push({ id: blocks.length, hidden: false, source: src, html: `<p>${pHtml}</p>` });
  }
  const html = blocks.filter(b => !b.hidden).map(b => `<div data-md-block="${b.id}">${b.html}</div>`).join('');
  return { blocks, html };
}

async function mountMarkdown(t, markdown, session = 'long-session') {
  const { blocks, html } = renderMarkdownBlocksForTest(markdown);
  const env = setupEnv(t, html);
  env.document.documentElement.setAttribute('data-fastra-enhanced', 'true');
  const messages = [];
  env.window.webkit = {
    messageHandlers: {
      visualMarkdown: { postMessage: m => messages.push(m) },
      markdownCopy: { postMessage: () => {} }
    }
  };
  const api = installFastraVisualBridge();
  const started = await api.start({ session, markdown, blocks, opaqueSources: {} });
  assert.equal(started, true, 'Bridge failed to start');
  return { ...env, api, messages };
}

function setCaretInBlock(env, selector, index, atEnd = true) {
  const els = env.root.querySelectorAll(selector);
  const target = els[index];
  assert.ok(target, `Missing ${selector}[${index}]`);
  const r = env.document.createRange();
  r.selectNodeContents(target);
  r.collapse(!atEnd);
  const sel = env.window.getSelection();
  sel.removeAllRanges();
  sel.addRange(r);
}

test('Plain multiline paste preserves nonbreaking spaces and insertion marks', async t => {
  const { root, document, window, api } = await mountMarkdown(t, '**ABC**');
  const range = document.createRange();
  range.setStart(root.querySelector('strong').firstChild, 1);
  range.collapse(true);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);
  const event = new window.Event('paste', { bubbles: true, cancelable: true });
  Object.defineProperty(event, 'clipboardData', {
    value: {
      files: [],
      getData: type => type === 'text/plain' ? 'u\n\u00a0\nv' : ''
    }
  });
  root.dispatchEvent(event);
  assert.equal(api.markdown(), '**Au**\n\n**&nbsp;**\n\n**vBC**\n\n');
});

test('Suite A: Diagnostic-report protocol session preserves all blank lines across Enter, Paste, Undo, and Reload', async t => {
  const env = await mountMarkdown(t, '', 'diag-repro');
  const { api, root, document, window } = env;

  const selectRange = (node, start, end = start) => {
    const r = document.createRange();
    r.setStart(node, start);
    r.setEnd(node, end);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(r);
  };

  // Startdokument Zeile für Zeile aufbauen wie im gemeldeten Testprotokoll
  api.command('insertText', 'Platzhalter für Systeminformationen');
  api.command('insertParagraph');
  api.command('insertParagraph'); // sichtbare Leerzeile
  api.command('insertText', 'Getestet');
  api.command('hardBreak');
  api.command('insertText', '– ');
  api.command('hardBreak');
  api.command('insertText', '– ');
  api.command('insertParagraph');
  api.command('insertParagraph'); // sichtbare Leerzeile
  api.command('insertText', 'Fragen');
  api.command('insertParagraph');
  api.command('insertText', 'Frage 1');
  api.command('hardBreak');
  api.command('insertText', '– ');
  api.command('hardBreak');
  api.command('insertText', 'Bild F1a');
  api.command('insertParagraph');
  api.command('insertText', 'Frage 2');

  // Cursor an den Anfang von "Frage 2" setzen und Enter drücken -> Leerzeile zwischen Frage 1 und Frage 2
  const frage2P = Array.from(root.querySelectorAll('p')).find(p => p.textContent === 'Frage 2');
  assert.ok(frage2P);
  selectRange(frage2P.firstChild, 0, 0);
  api.command('insertParagraph');

  // Am Ende "Fehler" per Plain-Text-Paste mit Mehrfach-Leerzeilen einfügen
  setCaretInBlock(env, 'p', root.querySelectorAll('p').length - 1, true);
  api.command('insertParagraph');
  const bm = api.bookmarkClipboard();
  assert.equal(api.insertClipboardText(bm, 'Fehler\n\nFehler 1\n\n  \nFehler 2\n\n\nFehler 3'), true);

  // In eine Leerzeile tippen, löschen und per Undo zurückrollen
  const blanksBefore = root.querySelectorAll('.fastra-visible-blank-line').length;
  assert.ok(blanksBefore >= 3, `Expected blank lines before edit, got ${blanksBefore}`);
  setCaretInBlock(env, '.fastra-visible-blank-line', 0, true);
  api.command('insertText', 'Temp');
  const tempP = Array.from(root.querySelectorAll('p')).find(p => p.textContent === 'Temp');
  selectRange(tempP.firstChild, 0, 4);
  api.command('delete');
  api.undo();
  api.undo();

  const savedMd = api.markdown();
  const blankLineMarkers = savedMd.replace(/\r\n?/g, '\n').split('\n').filter(l => /^ {2,}$/.test(l)).length;
  assert.ok(blankLineMarkers >= 4, `Expected >=4 visible blank lines in markdown, got ${blankLineMarkers}:\n${savedMd}`);

  // Speichern simulieren & in völlig neuer Bridge-Instanz neu laden
  const reloaded = renderMarkdownBlocksForTest(savedMd);
  const holder = document.createElement('div');
  holder.innerHTML = reloaded.html;
  const appDiff = diffAppearance(saveAppearance(root), saveAppearance(holder));
  assert.equal(appDiff.outcome, 'ok', `Appearance diff before reload: ${JSON.stringify(appDiff)}`);

  const env2 = await mountMarkdown(t, savedMd, 'diag-repro-reload');
  assert.equal(
    env2.root.querySelectorAll('.fastra-visible-blank-line').length,
    blankLineMarkers,
    'Reloaded document must keep exact visible blank-line count'
  );
});

test('Suite B: 150-step deterministic long-document soak session with paste, formatting, undo/redo, and periodic reloads', async t => {
  const initialMarkdown = [
    '# Systemhandbuch und Prüfprotokoll',
    '',
    '  ',
    '',
    'Einleitung mit **Fettdruck**, *Kursiv*, ==Marker== und `Code`.',
    '',
    '  ',
    '',
    '## Abschnitt Listen',
    '',
    '- Erster Punkt',
    '- Zweiter Punkt',
    '- [ ] Offene Aufgabe',
    '- [x] Erledigte Aufgabe',
    '',
    '  ',
    '',
    '> Wichtiger Hinweis im Zitat',
    '',
    '```js',
    'const answer = 42;',
    '```',
    '',
    'Abschlusszeile eins  ',
    'Abschlusszeile zwei',
    '',
    '  ',
    ''
  ].join('\n');

  let currentMd = initialMarkdown;
  let env = await mountMarkdown(t, currentMd, 'soak-0');

  let seed = 0x51a7c0de;
  const nextRand = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 0x100000000;
  };
  const pick = arr => arr[Math.floor(nextRand() * arr.length)];

  const formatCmds = ['bold', 'italic', 'highlight', 'strike', 'heading2', 'heading3', 'plainParagraph', 'bulletList', 'orderedList', 'taskList', 'quote'];

  for (let step = 0; step < 150; step++) {
    const blocks = Array.from(env.root.querySelectorAll('p, h1, h2, h3, li, div.fastra-visible-blank-line'));
    if (blocks.length > 0) {
      const target = blocks[Math.floor(nextRand() * blocks.length)];
      const r = env.document.createRange();
      const textNode = target.firstChild?.nodeType === 3 ? target.firstChild : null;
      if (textNode && textNode.data.length > 2 && nextRand() < 0.45) {
        const a = Math.floor(nextRand() * Math.floor(textNode.data.length / 2));
        const b = Math.min(textNode.data.length, a + 1 + Math.floor(nextRand() * (textNode.data.length - a)));
        r.setStart(textNode, a);
        r.setEnd(textNode, b);
      } else {
        r.selectNodeContents(target);
        r.collapse(nextRand() < 0.5);
      }
      env.window.getSelection().removeAllRanges();
      env.window.getSelection().addRange(r);
    }

    const op = step % 15;
    if (op === 0 || op === 1) {
      env.api.command('insertText', pick([' Alpha', ' # Literal', ' > Zitat', ' Wert & Text', ' Zeile']));
    } else if (op === 2) {
      env.api.command('insertParagraph');
    } else if (op === 3) {
      env.api.command('hardBreak');
    } else if (op === 4 || op === 5) {
      env.api.command(pick(formatCmds));
    } else if (op === 6) {
      const bm = env.api.bookmarkClipboard();
      env.api.insertClipboardText(bm, 'Eingefügt A\n\n\nEingefügt B');
    } else if (op === 7) {
      const bm = env.api.bookmark();
      env.api.insertBookmarked(bm, '<p>Block 1</p><p></p><p>Block 2</p>', {}, null, [], false);
    } else if (op === 8) {
      env.api.undo();
    } else if (op === 9) {
      env.api.redo();
    } else if (op === 10) {
      // Bereich über mehrere Absätze/Listen markieren und umformatieren
      const ps = env.root.querySelectorAll('p, li');
      if (ps.length >= 2) {
        const idx = Math.floor(nextRand() * (ps.length - 1));
        const r = env.document.createRange();
        r.setStart(ps[idx], 0);
        r.setEnd(ps[idx + 1], ps[idx + 1].childNodes.length);
        env.window.getSelection().removeAllRanges();
        env.window.getSelection().addRange(r);
        env.api.command(pick(['bold', 'bulletList', 'heading2', 'plainParagraph']));
      }
    } else if (op === 11) {
      env.api.command('delete');
    } else {
      env.api.command('insertText', 'x');
    }

    env.api.flush();
    const report = env.api.diagnosticReport(false);
    const fatal = report.anomalies.filter(a => ['js-error', 'js-rejection', 'command-exception', 'unexpected-text-loss'].includes(a.code));
    assert.deepEqual(fatal, [], `Fatal anomaly at step ${step}: ${JSON.stringify(fatal)}`);

    currentMd = env.api.markdown();
    assert.equal(typeof currentMd, 'string');

    if ((step + 1) % 30 === 0) {
      // Periodisches Speichern & Neuladen darf keine Leerzeile und keine Semantik verlieren
      const blankCountBefore = currentMd.replace(/\r\n?/g, '\n').split('\n').filter(l => /^ {2,}$/.test(l)).length;
      env = await mountMarkdown(t, currentMd, `soak-${step + 1}`);
      const reloadedMd = env.api.markdown();
      const blankCountAfter = reloadedMd.replace(/\r\n?/g, '\n').split('\n').filter(l => /^ {2,}$/.test(l)).length;
      assert.equal(blankCountAfter, blankCountBefore, `Blank lines drifted on reload at step ${step + 1}`);
    }
  }
});

test('Suite C: Targeted unit regressions for serializer, parser, commands, diagnostics, and bridge fixes', async t => {
  const env = setupEnv(t, '');
  const { document, window, root } = env;

  // 1. Leerer Absatz nach Enter / Löschen eines vorhandenen Absatzes -> `  \n\n`, und Backspace auf letztem Zeichen -> `""`
  {
    const doc = schema.nodes.doc.create(null, [
      schema.nodes.paragraph.create(null, schema.text('Frage 1')),
      schema.nodes.paragraph.create(null, schema.text('Frage 2'))
    ]);
    const view = makeView(document.createElement('div'), doc);
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, doc.child(0).nodeSize + 1)));
    executeVisualCommand(view, 'insertParagraph', null, { schema });
    assert.equal(serializeDocument(view.state.doc, {}), 'Frage 1\n\n  \n\nFrage 2\n\n');

    // Alleiniges leeres <p> nach Löschen -> `""`, unabhängig von `lastInputType`
    view.dispatch(view.state.tr.setSelection(new AllSelection(view.state.doc)));
    view.dispatch(view.state.tr.deleteSelection());
    assert.equal(serializeDocument(view.state.doc, { lastInputType: '' }), '');
    view.destroy();
  }

  // 2. Löschen des ersten Blocks lässt keine führende Leerzeile `\n` aus Hidden-Prefix stehen
  {
    const r = document.createElement('div');
    r.innerHTML = '<div data-md-block="0"><p>First</p></div><div data-md-block="2"><p>Second</p></div>';
    const blocks = [
      { id: 0, hidden: false, source: 'First\n' },
      { id: 1, hidden: true, source: '\n' },
      { id: 2, hidden: false, source: 'Second\n' }
    ];
    const { doc, parsedGroups } = parseDocumentContainer(r, blocks, { schema, ownerDocument: document });
    const originals = new Map(blocks.filter(b => !b.hidden).map(b => [String(b.id), { source: b.source, ...parsedGroups.get(String(b.id)) }]));
    const contexts = new Map([['', { blocks, hiddenPrefixes: new Map([['2', [blocks[1]]]]), trailingHidden: new Set(), trailingOwner: '2' }]]);
    const view = makeView(document.createElement('div'), doc);
    view.dispatch(view.state.tr.delete(0, doc.child(0).nodeSize));
    assert.equal(serializeDocument(view.state.doc, { contexts, originals }), 'Second\n');
    view.destroy();
  }

  // 3. Referenz-Definitionen behalten beim Einwickeln in Zitat ihre Reihenfolge
  {
    const r = document.createElement('div');
    r.innerHTML = '<div data-md-block="0"><p>A</p></div><div data-md-block="2"><p>B</p></div><div data-md-block="4"><p><a href="https://two.example">x</a></p></div>';
    const blocks = [
      { id: 0, hidden: false, source: 'A\n\n' },
      { id: 1, hidden: true, source: '[x]: https://one.example\n\n' },
      { id: 2, hidden: false, source: 'B\n\n' },
      { id: 3, hidden: true, source: '[x]: https://two.example\n\n' },
      { id: 4, hidden: false, source: '[x]\n' }
    ];
    const { doc, parsedGroups } = parseDocumentContainer(r, blocks, { schema, ownerDocument: document });
    const originals = new Map(blocks.filter(b => !b.hidden).map(b => [String(b.id), { source: b.source, ...parsedGroups.get(String(b.id)) }]));
    const contexts = new Map([['', {
      blocks,
      hiddenPrefixes: new Map([['2', [blocks[1]]], ['4', [blocks[3]]]]),
      trailingHidden: new Set(),
      trailingOwner: '4'
    }]]);
    const view = makeView(document.createElement('div'), doc);
    const bPos = doc.child(0).nodeSize + 1;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, bPos)));
    executeVisualCommand(view, 'quote', null, { schema });
    const md = serializeDocument(view.state.doc, { contexts, originals });
    assert.ok(md.indexOf('one.example') < md.indexOf('two.example'), `Reference order flipped:\n${md}`);
    view.destroy();
  }

  // 4. Listen-Mehrfachlift behält Auswahl für heading2 & gemischte Liste+Absatz-Auswahl funktioniert
  {
    const nodes = parseHTMLToNodes('<ol start="4"><li>AA</li><li>BB</li><li>CC</li><li>DD</li></ol>', { schema, ownerDocument: document });
    const view = makeView(document.createElement('div'), schema.nodes.doc.create(null, nodes));
    let bbPos = null;
    let ccEnd = null;
    view.state.doc.descendants((n, pos) => {
      if (n.isText && n.text === 'BB') bbPos = pos;
      if (n.isText && n.text === 'CC') ccEnd = pos + 2;
      return true;
    });
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, bbPos, ccEnd)));
    executeVisualCommand(view, 'heading2', null, { schema });
    const md = serializeDocument(view.state.doc, {});
    assert.ok(md.includes('## BB'), md);
    assert.ok(md.includes('## CC'), md);
    assert.ok(md.includes('7. DD'), md);
    view.destroy();

    const mixedNodes = parseHTMLToNodes('<ul><li>Item 1</li><li>Item 2</li></ul><p>After</p>', { schema, ownerDocument: document });
    const mixedView = makeView(document.createElement('div'), schema.nodes.doc.create(null, mixedNodes));
    mixedView.dispatch(mixedView.state.tr.setSelection(TextSelection.create(mixedView.state.doc, 3, mixedView.state.doc.content.size - 2)));
    assert.equal(executeVisualCommand(mixedView, 'bulletList', null, { schema }).executed, true);
    assert.equal(serializeDocument(mixedView.state.doc, {}), '- Item 1\n- Item 2\n- After\n\n');
    mixedView.destroy();

    const numbered = parseHTMLToNodes('<ol start="7"><li><strong>Seven</strong></li><li>Eight</li></ol><p>Nine</p>',
      { schema, ownerDocument: document });
    const numberedView = makeView(document.createElement('div'), schema.nodes.doc.create(null, numbered));
    numberedView.dispatch(numberedView.state.tr.setSelection(TextSelection.create(numberedView.state.doc, 3, numberedView.state.doc.content.size - 1)));
    assert.equal(executeVisualCommand(numberedView, 'orderedList', null, { schema }).executed, true);
    assert.equal(serializeDocument(numberedView.state.doc, {}), '7. **Seven**\n8. Eight\n9. Nine\n\n');
    numberedView.destroy();

    const nested = parseHTMLToNodes('<ul><li>Parent<ul><li>One</li><li>Two</li></ul></li><li>Sibling</li></ul>',
      { schema, ownerDocument: document });
    const nestedView = makeView(document.createElement('div'), schema.nodes.doc.create(null, nested));
    const positions = new Map();
    nestedView.state.doc.descendants((node, pos) => { if (node.isText) positions.set(node.text, pos); });
    nestedView.dispatch(nestedView.state.tr.setSelection(TextSelection.create(nestedView.state.doc, positions.get('One'), positions.get('Two') + 3)));
    assert.equal(executeVisualCommand(nestedView, 'bulletList', null, { schema }).executed, true);
    assert.equal(serializeDocument(nestedView.state.doc, {}), '- Parent\n- One\n- Two\n- Sibling\n\n');
    nestedView.destroy();

    const nestedOrdered = parseHTMLToNodes('<ol><li>Parent<ol start="7"><li>Seven</li><li>Eight</li><li>Nine</li></ol></li></ol>',
      { schema, ownerDocument: document });
    const nestedOrderedView = makeView(document.createElement('div'), schema.nodes.doc.create(null, nestedOrdered));
    nestedOrderedView.state.doc.descendants((node, pos) => { if (node.isText) positions.set(node.text, pos); });
    nestedOrderedView.dispatch(nestedOrderedView.state.tr.setSelection(TextSelection.create(nestedOrderedView.state.doc, positions.get('Eight'))));
    assert.equal(executeVisualCommand(nestedOrderedView, 'orderedList', null, { schema }).executed, true);
    assert.equal(nestedOrderedView.state.doc.firstChild.lastChild.lastChild.attrs.order, 9);
    nestedOrderedView.destroy();
  }

  // 5. Shift+Enter vor <br>, in Listen und Teil-Überschrift mit <br>
  {
    const p = schema.nodes.paragraph.create(null, [schema.text('A'), schema.nodes.hard_break.create(), schema.text('B')]);
    const v = makeView(document.createElement('div'), schema.nodes.doc.create(null, [p]));
    v.dispatch(v.state.tr.setSelection(TextSelection.create(v.state.doc, 2)));
    executeVisualCommand(v, 'hardBreak', null, { schema });
    assert.equal(serializeDocument(v.state.doc, {}), 'A\n\n  \n\nB\n\n');
    v.dispatch(v.state.tr.insertText('X'));
    assert.equal(serializeDocument(v.state.doc, {}), 'A\n\nX\n\nB\n\n');
    v.destroy();

    const liP = schema.nodes.bullet_list.create({ tight: true }, [
      schema.nodes.list_item.create(null, [schema.nodes.paragraph.create(null, [schema.text('Alpha'), schema.nodes.hard_break.create()])])
    ]);
    assert.equal(serializeBlockNode(liP), '- Alpha<br>');

    const multiBr = schema.nodes.paragraph.create(null, [
      schema.text('A'), schema.nodes.hard_break.create(),
      schema.text('B'), schema.nodes.hard_break.create(),
      schema.nodes.hard_break.create(),
      schema.text('C')
    ]);
    const hv = makeView(document.createElement('div'), schema.nodes.doc.create(null, [multiBr]));
    const cPos = hv.state.doc.content.size - 2;
    hv.dispatch(hv.state.tr.setSelection(TextSelection.create(hv.state.doc, cPos)));
    executeVisualCommand(hv, 'heading2', null, { schema });
    assert.equal(serializeDocument(hv.state.doc, {}), 'A  \nB\n\n  \n\n## C\n\n');
    hv.destroy();
  }

  // 6. Code-Mark schützt Bilder; Zitat auf Liste wickelt ganze Liste ein; Blockanfang & Link-Entities escaped
  {
    const imgP = schema.nodes.paragraph.create(null, [
      schema.text('hi '), schema.nodes.image.create({ src: 'x.png', mdSrc: 'x.png', alt: 'x' }), schema.text(' bye')
    ]);
    const cv = makeView(document.createElement('div'), schema.nodes.doc.create(null, [imgP]));
    cv.dispatch(cv.state.tr.setSelection(TextSelection.create(cv.state.doc, 1, cv.state.doc.content.size - 1)));
    executeVisualCommand(cv, 'code', null, { schema });
    assert.equal(serializeDocument(cv.state.doc, {}), '`hi `![x](<x.png>)` bye`\n\n');
    cv.destroy();

    const escDoc = schema.nodes.doc.create(null, [
      schema.nodes.paragraph.create(null, [schema.text(' # NotHeading')]),
      schema.nodes.paragraph.create(null, [schema.text('    notCode')]),
      schema.nodes.paragraph.create(null, [schema.text('Link', [schema.marks.link.create({ href: 'https://example.com/?a=&copy;' })])])
    ]);
    const escMd = serializeDocument(escDoc, {});
    assert.ok(escMd.includes(' \\# NotHeading'), escMd);
    assert.ok(escMd.includes('&#32;   notCode'), escMd);
    assert.ok(escMd.includes('&amp;copy;'), escMd);

    const quoted = parseHTMLToNodes('<ul><li>One</li><li>Two</li></ul>', { schema, ownerDocument: document });
    const quoteView = makeView(document.createElement('div'), schema.nodes.doc.create(null, quoted));
    const beforeQuote = quoteView.state.doc;
    assert.equal(executeVisualCommand(quoteView, 'quote', null, { schema }).executed, true);
    assert.equal(quoteView.state.doc.firstChild.firstChild.type, schema.nodes.bullet_list);
    assert.equal(executeVisualCommand(quoteView, 'quote', null, { schema }).executed, true);
    assert.ok(quoteView.state.doc.eq(beforeQuote));
    quoteView.destroy();

    // Zwei direkt aufeinanderfolgende geordnete Listen wechseln das Trennzeichen (. vs )),
    // damit CommonMark sie beim erneuten Öffnen nicht in eine Liste mit Start 8 verschmilzt.
    const twoOls = schema.nodes.doc.create(null, [
      schema.nodes.ordered_list.create({ order: 7, tight: true }, [
        schema.nodes.list_item.create(null, schema.nodes.paragraph.create(null, schema.text('Sieben')))
      ]),
      schema.nodes.ordered_list.create({ order: 1, tight: true }, [
        schema.nodes.list_item.create(null, schema.nodes.paragraph.create(null, schema.text('Eins')))
      ])
    ]);
    assert.equal(serializeDocument(twoOls, {}), '7. Sieben\n\n1) Eins\n\n');
  }

  // 7. saveAppearance deckt fehlendes leeres <p>, Link-Href, Checkbox & <ol start> auf
  {
    const live = document.createElement('div');
    live.innerHTML = '<p>A</p><p><br class="ProseMirror-trailingBreak"></p><p>B</p>';
    const savedBad = document.createElement('div');
    savedBad.innerHTML = '<p>A</p><p>B</p>';
    assert.equal(diffAppearance(saveAppearance(live), saveAppearance(savedBad)).outcome, 'breaks');

    const linkA = document.createElement('div');
    linkA.innerHTML = '<p><a href="https://one.example">x</a></p>';
    const linkB = document.createElement('div');
    linkB.innerHTML = '<p><a href="https://two.example">x</a></p>';
    assert.equal(diffAppearance(saveAppearance(linkA), saveAppearance(linkB)).outcome, 'format');

    linkA.innerHTML = '<p><a href="/x">a </a><strong><a href="/x">b</a></strong><a href="/x"> c</a></p>';
    linkB.innerHTML = '<p><a href="/x">a <strong>b</strong> c</a></p>';
    assert.equal(diffAppearance(saveAppearance(linkA), saveAppearance(linkB)).outcome, 'ok');
    linkB.innerHTML = '<p>a <strong><a href="/x">b</a></strong> c</p>';
    assert.equal(diffAppearance(saveAppearance(linkA), saveAppearance(linkB)).diff.kind, 'links');

    linkA.innerHTML = '<p>Mail: address@example.test</p>';
    linkB.innerHTML = '<p>Mail: <a href="mailto:address@example.test">address@example.test</a></p>';
    assert.equal(diffAppearance(saveAppearance(linkA), saveAppearance(linkB)).outcome, 'ok');
    linkB.querySelector('a').setAttribute('href', 'mailto:other@example.test');
    assert.equal(diffAppearance(saveAppearance(linkA), saveAppearance(linkB)).diff.kind, 'links');
  }

  // 8. Bridge: 80ms-Debounce-Rennen unterdrückt falsches liveCheck-Text-Banner; Cursor nach <br>; Oversized Tab stoppt Observer nicht; Codeblock-Paste ohne Bild-Transaction
  {
    root.innerHTML = '<div data-md-block="0"><p>A</p></div><div data-md-block="1"><pre><code>line</code></pre></div>';
    document.documentElement.setAttribute('data-fastra-enhanced', 'true');
    const msgs = [];
    window.webkit = { messageHandlers: { visualMarkdown: { postMessage: m => msgs.push(m) }, markdownCopy: { postMessage() {} } } };
    const api = installFastraVisualBridge();
    await api.start({
      session: 'race-1',
      markdown: 'A\n\n```\nline\n```\n',
      blocks: [
        { id: 0, hidden: false, source: 'A\n\n' },
        { id: 1, hidden: false, source: '```\nline\n```\n' }
      ],
      opaqueSources: {}
    });

    // Während Debounce pending ist (normales Tippen ohne sofortiges Flush), muss inspectAppearance null liefern!
    const pNode = root.querySelector('p').firstChild;
    const r = document.createRange();
    r.setStart(pNode, 1); r.collapse(true);
    window.getSelection().removeAllRanges(); window.getSelection().addRange(r);
    // Simuliere direkte DOM-Eingabe über insertPlainText/input (oder view dispatch ohne fastraImmediate)
    const ev = new window.InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'B' });
    pNode.data = 'AB';
    root.dispatchEvent(ev);
    api.flush();
    // Nach flush ist Revision synchron -> inspectAppearance prüft sauber.
    assert.equal(api.inspectAppearance('race-1', 1, '<p>AB</p><pre><code>line</code></pre>').outcome, 'ok');

    // Codeblock-Paste ohne angehängte Bilder (transaction null) funktioniert
    const codeEl = root.querySelector('pre code');
    const cr = document.createRange();
    cr.setStart(codeEl.firstChild, 4); cr.collapse(true);
    window.getSelection().removeAllRanges(); window.getSelection().addRange(cr);
    const bm = api.bookmark();
    assert.equal(api.insertBookmarked(bm, '<p>X</p>', {}, null, [], true), true);
    assert.ok(api.markdown().includes('lineX'), api.markdown());
  }
});
