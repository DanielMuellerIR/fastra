import { DOMParser, Fragment } from 'prosemirror-model';
import { schema as defaultSchema } from './schema.js';

const INLINE_WRAP_TAGS = new Set(['STRONG', 'B', 'EM', 'I', 'MARK', 'DEL', 'S', 'STRIKE', 'SPAN', 'FONT']);
const ALLOWED_PASTE_ATTRS = new Set(['href', 'src', 'alt', 'title', 'align', 'colspan', 'rowspan', 'start', 'type', 'checked', 'data-md-table', 'data-task']);
const ALLOWED_CLIPBOARD_TAGS = new Set([
  'P', 'DIV', 'BR', 'STRONG', 'B', 'EM', 'I', 'MARK', 'DEL', 'S', 'STRIKE',
  'U', 'INS', 'SMALL', 'SUB', 'SUP', 'KBD', 'SAMP', 'VAR', 'Q', 'CITE',
  'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI', 'BLOCKQUOTE',
  'PRE', 'CODE', 'A', 'TABLE', 'THEAD', 'TBODY', 'TFOOT', 'TR', 'TD', 'TH',
  'SPAN', 'FONT'
]);

/**
 * Entfernt rein interne Bearbeitungsartefakte vor dem Parsen in ProseMirror:
 * WebKit-/Renderer-Platzhalter-<br> in leeren Zeilen, Editiergrenzen,
 * Hervorhebungen innerhalb von Codeblöcken sowie überzählige UI-Attribute.
 */
export function preprocessDOMForParse(container, { stripBlockOrigin = false } = {}) {
  if (!container) return;
  const doc = container.ownerDocument;
  container.querySelectorAll('[data-md-edit-boundary]').forEach(n => n.remove());

  if (stripBlockOrigin) {
    container.querySelectorAll('[data-fastra-md-block-id],[data-fastra-md-context]').forEach(n => {
      n.removeAttribute('data-fastra-md-context');
      n.removeAttribute('data-fastra-md-block-id');
      n.removeAttribute('data-fastra-md-block-sub');
      n.removeAttribute('data-fastra-md-block-total');
    });
  }

  // Gerenderte Mermaid-Blöcke / KaTeX-Blöcke zurück auf ihre atomare Hülle reduzieren,
  // damit ProseMirror beim Parsen keine inneren SVGs/Spans als bearbeitbaren Text einliest.
  container.querySelectorAll('[data-md-opaque]').forEach(node => {
    if (node.dataset.mdOpaqueHTML === undefined) {
      node.dataset.mdOpaqueHTML = node.innerHTML;
    }
  });
  container.querySelectorAll('[data-tex]').forEach(node => {
    if (node.dataset.mdMathHTML === undefined) {
      node.dataset.mdMathHTML = node.outerHTML;
    }
  });

  // Einzelne leere Checkbox-Spans / Render-Hilfstexte in Codeblöcken normalisieren.
  container.querySelectorAll('pre code').forEach(code => {
    code.textContent = code.textContent;
  });

  // In sichtbaren Leerzeilen (.fastra-visible-blank-line) und leeren Absätzen
  // (p[data-md-empty]) dient ein einzelnes <br> nur der Browser-Darstellung.
  container.querySelectorAll('div.fastra-visible-blank-line, p[data-md-empty]').forEach(el => {
    const children = Array.from(el.childNodes);
    if (children.length === 1 && children[0].nodeName === 'BR') {
      children[0].remove();
    } else {
      const meaning = Array.from(el.childNodes).filter(n => !(n.nodeType === 3 && !n.data.replace(/\u200b/g, '').length));
      if (meaning.length === 1 && meaning[0].nodeName === 'BR') {
        meaning[0].remove();
      }
    }
  });

  // Geschützte Leerzeichen-Spans (data-md-spaces) für die Modellrepräsentation
  // in echte NBSP-Textknoten (\u00a0) überführen.
  container.querySelectorAll('span[data-md-spaces]').forEach(span => {
    const count = Math.max(1, Number(span.getAttribute('data-md-spaces') || 1));
    span.replaceWith(doc.createTextNode('\u00a0'.repeat(count)));
  });

  // Ineinander geschachtelte <p> innerhalb eines <td>/<th> (falls fremdes HTML
  // eingefügt wird) flachziehen, da table_cell inline* verlangt.
  container.querySelectorAll('td, th').forEach(cell => {
    const blocks = Array.from(cell.querySelectorAll('p, div'));
    if (!blocks.length) return;
    // Nur echte direkte/innere Absatzcontainer außerhalb von Atomen flachziehen.
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (!cell.contains(b) || b.closest('[data-md-opaque],[data-tex]')) continue;
      const frag = doc.createDocumentFragment();
      while (b.firstChild) frag.appendChild(b.firstChild);
      if (i + 1 < blocks.length && blocks[i + 1].parentNode === b.parentNode) {
        frag.appendChild(doc.createElement('br'));
      }
      b.replaceWith(frag);
    }
  });

  // Textknoten bereinigen: Nullbreiten-Platzhalter (\u200b) entfernen.
  const walker = doc.createTreeWalker(container, 4 /* NodeFilter.SHOW_TEXT */);
  const texts = [];
  while (walker.nextNode()) texts.push(walker.currentNode);
  for (const t of texts) {
    if (t.parentElement?.closest('pre,code,[data-md-opaque],[data-tex]')) continue;
    if (t.data.includes('\u200b')) t.data = t.data.replace(/\u200b/g, '');
  }
}

/**
 * Stellt fest, ob ein gerendertes <div> nur mehrere leere Zeilen (<br>) enthält
 * (z. B. nach WebKit/Linux-Imports) und wandelt es ggf. in `blank_line`-Elemente um.
 */
function normalizeLooseBlankDivs(container) {
  const doc = container.ownerDocument;
  container.querySelectorAll('div:not([data-md-block]):not([data-md-opaque]):not([data-tex]), p').forEach(el => {
    if (el.classList.contains('fastra-visible-blank-line')) return;
    if (el.closest('[data-md-opaque],[data-tex],pre,table')) return;
    if (el.textContent.replace(/\u200b/g, '').length) return;
    if (el.querySelector('p,div,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,table,pre,code,img,input,hr,[data-md-opaque],[data-tex]')) return;
    const onlyInline = Array.from(el.querySelectorAll('*')).every(c => c.tagName === 'BR' || INLINE_WRAP_TAGS.has(c.tagName));
    if (!onlyInline) return;
    const rawBrCount = el.querySelectorAll('br').length;
    if (el.tagName === 'P' && rawBrCount < 2) return;
    const brCount = Math.max(1, rawBrCount);
    const frag = doc.createDocumentFragment();
    for (let i = 0; i < brCount; i++) {
      const blank = doc.createElement('div');
      blank.className = 'fastra-visible-blank-line';
      frag.appendChild(blank);
    }
    el.replaceWith(frag);
  });
}

/**
 * Überträgt die ursprüngliche `<div data-md-block="ID">` Blockzuordnung auf alle
 * Top-Level-Knoten, die aus diesem Gerüstblock entstehen.
 */
export function stampBlockOriginOnNode(node, mdContext, mdBlockId, mdBlockSub, mdBlockTotal) {
  if (!node.type.spec.attrs || !('mdBlockId' in node.type.spec.attrs)) return node;
  return node.type.create(
    {
      ...node.attrs,
      mdContext,
      mdBlockId,
      mdBlockSub,
      mdBlockTotal
    },
    node.content,
    node.marks
  );
}

/**
 * Entfernt Block-Herkunftsattribute rekursiv (z. B. beim externen Einfügen, damit
 * eingefügte Blöcke nie fremde Originalquellen aus dem Dokument kapern).
 */
export function stripOriginFromNode(node) {
  let attrs = node.attrs;
  if (attrs && ('mdBlockId' in attrs || 'mdContext' in attrs)) {
    attrs = { ...attrs, mdContext: '', mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 };
  }
  if (!node.content.size) {
    return attrs === node.attrs ? node : node.type.create(attrs, node.content, node.marks);
  }
  const children = [];
  let changed = attrs !== node.attrs;
  node.content.forEach(child => {
    const cleaned = stripOriginFromNode(child);
    if (cleaned !== child) changed = true;
    children.push(cleaned);
  });
  return changed ? node.type.create(attrs, Fragment.fromArray(children), node.marks) : node;
}

/**
 * Berechnet eine kanonische JSON-Darstellung eines Knotens für den Vergleich mit
 * dem Originalblock. Interne Zuordnungsattribute, temporäre Asset-URLs (wenn
 * `mdSrc` gesetzt ist), UI-Flags und bereits gesondert gesicherte Rohquellen
 * werden dabei ignoriert.
 */
export function canonicalNodeSnapshot(node) {
  if (node.isText) {
    return {
      type: 'text',
      text: node.text,
      marks: node.marks.map(m => ({ type: m.type.name, attrs: m.attrs }))
    };
  }
  const attrs = {};
  for (const [key, value] of Object.entries(node.attrs || {})) {
    if (
      key === 'mdContext' ||
      key === 'mdBlockId' ||
      key === 'mdBlockSub' ||
      key === 'mdBlockTotal' ||
      key === 'outlineIgnore' ||
      key === 'rawHTML'
    ) {
      continue;
    }
    if (node.type.name === 'image' && key === 'src' && node.attrs.mdSrc != null) {
      continue;
    }
    attrs[key] = value;
  }
  const children = [];
  node.content.forEach(child => children.push(canonicalNodeSnapshot(child)));
  return {
    type: node.type.name,
    attrs,
    marks: node.marks.map(m => ({ type: m.type.name, attrs: m.attrs })),
    content: children
  };
}

export function canonicalGroupStructure(nodes) {
  function nodeSignature(node) {
    if (node.isText) return '';
    if (node.type.name === 'hard_break') return '(BR)';
    if (node.isLeaf) return `(${node.type.name})`;
    const inner = [];
    node.content.forEach(child => inner.push(nodeSignature(child)));
    return `(${node.type.name}${inner.join('')})`;
  }
  return nodes.map(nodeSignature).join('');
}

function findUnusedSentinel(text) {
  for (const ch of ['\uE001', '\uE002', '\uF001', '\uF002']) {
    if (!text.includes(ch)) return ch;
  }
  return '\uE003FASTRACODESPACE\uE004';
}

function parseWithInlineCodeSpaces(wrapper, pmParser) {
  const inlineCodes = Array.from(wrapper.querySelectorAll('code')).filter(
    c => !c.closest('pre,[data-md-opaque],[data-tex]')
  );
  const inlineTextContainers = Array.from(wrapper.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,td,th,blockquote'));
  const doc = wrapper.ownerDocument;
  const rawText = wrapper.textContent || '';
  const hasDoubleSpaces = inlineTextContainers.some(el => / {2,}/.test(el.textContent || ''));
  let sentinel = null;
  if (inlineCodes.length || hasDoubleSpaces) {
    sentinel = findUnusedSentinel(rawText);
    for (const code of inlineCodes) {
      const walker = doc.createTreeWalker(code, 4 /* NodeFilter.SHOW_TEXT */);
      while (walker.nextNode()) {
        if (walker.currentNode.data.includes(' ')) {
          walker.currentNode.data = walker.currentNode.data.replace(/ /g, sentinel);
        }
      }
    }
    if (hasDoubleSpaces) {
      const walker = doc.createTreeWalker(wrapper, 4 /* NodeFilter.SHOW_TEXT */);
      while (walker.nextNode()) {
        const tn = walker.currentNode;
        if (tn.parentElement?.closest('pre,code,[data-md-opaque],[data-tex]')) continue;
        if (/(?<=\S)( {2,})(?=\S)/.test(tn.data)) {
          tn.data = tn.data.replace(/(?<=\S)( {2,})(?=\S)/g, m => sentinel.repeat(m.length));
        }
      }
    }
  }
  const parsed = pmParser.parse(wrapper);
  if (!sentinel) return parsed;

  function restoreNode(node) {
    if (node.isText) {
      return node.text.includes(sentinel) ? node.withText(node.text.replaceAll(sentinel, ' ')) : node;
    }
    if (!node.content.size) return node;
    const kids = [];
    let changed = false;
    node.content.forEach(child => {
      const next = restoreNode(child);
      if (next !== child) changed = true;
      kids.push(next);
    });
    return changed ? node.type.create(node.attrs, Fragment.fromArray(kids), node.marks) : node;
  }
  return restoreNode(parsed);
}

/**
 * Parst die gerenderte HTML-Containerstruktur (`#fastra-visual` oder einen
 * ReplaceSource-Holder) in ein ProseMirror-`doc` und baut gleichzeitig die
 * erwarteten Original-Snapshots pro `(context, blockId)` für verlustfreie
 * Serialisierung zurück.
 */
export function parseDocumentContainer(container, blocks, {
  schema = defaultSchema,
  mdContext = '',
  ownerDocument = container.ownerDocument
} = {}) {
  const pmParser = DOMParser.fromSchema(schema);
  const work = container.cloneNode(true);
  preprocessDOMForParse(work);
  normalizeLooseBlankDivs(work);

  const blockMap = new Map();
  for (const b of blocks || []) {
    if (!b.hidden) blockMap.set(String(b.id), b);
  }

  const topNodes = [];
  const parsedGroups = new Map();

  for (const child of Array.from(work.childNodes)) {
    if (child.nodeType === 3) {
      if (!child.data.trim()) continue;
      const p = ownerDocument.createElement('p');
      p.textContent = child.data;
      const parsed = pmParser.parse(p);
      parsed.content.forEach(n => topNodes.push(n));
      continue;
    }
    if (child.nodeType !== 1) continue;

    const blockId = child.getAttribute('data-md-block');
    if (blockId != null) {
      // Wrapper <div data-md-block="ID"> in seine Kinder zerlegen und parsen.
      const subHolder = ownerDocument.createElement('div');
      while (child.firstChild) subHolder.appendChild(child.firstChild);
      normalizeLooseBlankDivs(subHolder);

      // Leeren Block als leeren Absatz bewahren (z. B. reine Referenz-Dokumente).
      const parsedSub = subHolder.childNodes.length
        ? parseWithInlineCodeSpaces(subHolder, pmParser)
        : schema.nodes.doc.create(null, schema.nodes.paragraph.create({ mdEmpty: true }));

      const group = [];
      const total = parsedSub.content.childCount;
      parsedSub.content.forEach((n, _offset, idx) => {
        const stamped = stampBlockOriginOnNode(n, mdContext, blockId, idx, total);
        group.push(stamped);
        topNodes.push(stamped);
      });

      const original = blockMap.get(blockId);
      if (original) {
        // Ignored Headings wie in visual-editor.js erfassen (am ursprünglichen DOM).
        const escapeSelector = (typeof CSS !== 'undefined' && CSS.escape)
          ? CSS.escape(blockId)
          : blockId.replace(/([^\w-])/g, '\\$1');
        const origDomNode = container.querySelector(`[data-md-block="${escapeSelector}"]`);
        const ignoredHeadings = origDomNode
          ? Array.from(origDomNode.querySelectorAll('h1,h2,h3,h4,h5,h6')).flatMap((h, i) => h.hasAttribute('data-md-outline-ignore') ? [i] : [])
          : [];
        parsedGroups.set(blockId, {
          nodes: group,
          canonicalSnapshot: JSON.stringify(group.map(canonicalNodeSnapshot)),
          structure: canonicalGroupStructure(group),
          ignoredHeadings
        });
      }
    } else {
      const subHolder = ownerDocument.createElement('div');
      subHolder.appendChild(child.cloneNode(true));
      const parsed = parseWithInlineCodeSpaces(subHolder, pmParser);
      parsed.content.forEach(n => topNodes.push(n));
    }
  }

  if (!topNodes.length) {
    topNodes.push(schema.nodes.paragraph.create({ mdEmpty: true }));
  }

  // Falls die Start-DOM bereits ohne `<div data-md-block>`-Hüllen neu eingelesen
  // wurde (z. B. geklontes ProseMirror-Root beim Same-Session-Start), sichtbare
  // Top-Level-Knoten positionell wieder ihren Originalblöcken zuordnen.
  if (!parsedGroups.size) {
    const visibleBlocks = (blocks || []).filter(b => !b.hidden);
    if (visibleBlocks.length && visibleBlocks.length === topNodes.length) {
      topNodes.forEach((node, idx) => {
        const b = visibleBlocks[idx];
        const bid = String(b.id);
        const stamped = stampBlockOriginOnNode(node, mdContext, bid, 0, 1);
        topNodes[idx] = stamped;
        parsedGroups.set(bid, {
          nodes: [stamped],
          canonicalSnapshot: JSON.stringify([canonicalNodeSnapshot(stamped)]),
          structure: canonicalGroupStructure([stamped]),
          ignoredHeadings: []
        });
      });
    }
  }

  // Bei der initialen Anlage über `data-md-opaque` ggf. innerHTML retten, falls `innerHTML`
  // im parseDOM-Schritt schon vorab abgelegt wurde.
  const doc = schema.nodes.doc.create({ sourceContext: mdContext }, topNodes);
  return { doc, parsedGroups };
}

/**
 * Parst ein beliebiges HTML-Fragment (z. B. aus insertBookmarked oder Paste)
 * in eine ProseMirror-`Slice` bzw. Knotenliste ohne Block-Herkunftsbindung.
 */
export function parseHTMLToNodes(html, { schema = defaultSchema, ownerDocument = document } = {}) {
  const template = ownerDocument.createElement('template');
  template.innerHTML = html || '';
  preprocessDOMForParse(template.content, { stripBlockOrigin: true });
  normalizeLooseBlankDivs(template.content);
  const wrapper = ownerDocument.createElement('div');
  wrapper.appendChild(template.content.cloneNode(true));
  const parsed = parseWithInlineCodeSpaces(wrapper, DOMParser.fromSchema(schema));
  const nodes = [];
  parsed.content.forEach(n => nodes.push(stripOriginFromNode(n)));
  return nodes;
}

/**
 * Bereinigt eingefügtes HTML aus der System-Zwischenablage (Fremdquellen).
 */
export function sanitizePasteHTML(html, ownerDocument = document) {
  const template = ownerDocument.createElement('template');
  template.innerHTML = html || '';
  template.content.querySelectorAll('script,style,iframe,object,embed,svg,math,link,meta').forEach(n => n.remove());
  template.content.querySelectorAll('*').forEach(n => {
    const language = n.tagName === 'CODE' ? n.className.match(/(?:^|\s)language-([\w+-]+)(?=\s|$)/)?.[1] : null;
    const isStyledInline = (n.tagName === 'SPAN' || n.tagName === 'FONT') &&
      !n.closest('pre,code,[data-md-opaque],[data-tex]') &&
      !n.hasAttribute('data-md-spaces');
    const marked = isStyledInline && n.style?.backgroundColor && !['transparent', 'rgba(0, 0, 0, 0)'].includes(n.style.backgroundColor);
    const bold = isStyledInline && (n.style?.fontWeight === 'bold' || Number(n.style?.fontWeight) >= 600);
    const italic = isStyledInline && (n.style?.fontStyle === 'italic' || n.style?.fontStyle === 'oblique');
    const strike = isStyledInline && n.style?.textDecorationLine?.includes('line-through');

    for (const a of Array.from(n.attributes)) {
      if (!ALLOWED_PASTE_ATTRS.has(a.name)) n.removeAttribute(a.name);
    }
    if (language) n.className = 'language-' + language;
    if (n.tagName === 'IMG') {
      const src = n.getAttribute('src') || '';
      if (/^(https?:|[^:/]+(?:\/|$))/i.test(src)) n.dataset.mdSrc = src;
      else n.remove();
    }
    if (n.hasAttribute('href') && !/^(https?:|mailto:|#|[^:/]+(?:\/|$))/i.test(n.getAttribute('href') || '')) {
      n.removeAttribute('href');
    }
    if (marked || bold || italic || strike) {
      const frag = ownerDocument.createDocumentFragment();
      while (n.firstChild) frag.appendChild(n.firstChild);
      let wrapped = frag;
      for (const tag of [marked ? 'mark' : null, strike ? 'del' : null, bold ? 'strong' : null, italic ? 'em' : null].filter(Boolean)) {
        const el = ownerDocument.createElement(tag);
        el.append(wrapped);
        wrapped = el;
      }
      n.replaceWith(wrapped);
    }
  });
  return template.innerHTML;
}

/**
 * Prüft und bereinigt HTML für Fastras Linux-/native Clipboard-Brücke
 * inklusive eingebetteter Data-URL-Bilder.
 */
export function inspectAndCleanClipboardHTML(html, collectImages = false, ownerDocument = document) {
  const images = [];
  if (new TextEncoder().encode(html || '').length > 2097152) return { ok: false, reason: 'size' };
  const template = ownerDocument.createElement('template');
  template.innerHTML = html || '';
  const nodes = Array.from(template.content.querySelectorAll('*'));
  if (nodes.length > 20000) return { ok: false, reason: 'size' };

  for (const node of nodes) {
    if (collectImages && node.tagName === 'IMG') {
      const source = node.getAttribute('src') || '';
      const match = source.match(/^data:image\/(png|jpeg|gif|webp|tiff);base64,([A-Za-z0-9+/]+={0,2})$/i);
      if (!match || images.length >= 32 || match[2].length % 4) return { ok: false, reason: 'images' };
      const ext = ({ jpeg: 'jpg' }[match[1].toLowerCase()]) || match[1].toLowerCase();
      const name = `image${images.length}.${ext}`;
      const alt = node.getAttribute('alt');
      const title = node.getAttribute('title');
      for (const attr of Array.from(node.attributes)) node.removeAttribute(attr.name);
      node.dataset.mdSrc = name;
      if (alt) node.setAttribute('alt', alt);
      if (title) node.setAttribute('title', title);
      images.push({ url: `file:///fastra-html-clipboard/${name}`, base64: match[2] });
      continue;
    }
    if (node.tagName === 'META' || node.tagName === 'TITLE') {
      node.remove();
      continue;
    }
    if (!ALLOWED_CLIPBOARD_TAGS.has(node.tagName)) {
      return { ok: false, reason: node.tagName === 'IMG' ? 'images' : 'format' };
    }
    if (node.hasAttribute('href')) {
      const href = node.getAttribute('href') || '';
      if (!(/^(https?:\/\/|#)/i.test(href.trim()) && !/[\u0000-\u001f\u007f]/.test(href))) {
        return { ok: false, reason: 'url' };
      }
    }
    const marked = (node.tagName === 'SPAN' || node.tagName === 'FONT')
      && node.style?.backgroundColor
      && !['transparent', 'rgba(0, 0, 0, 0)'].includes(node.style.backgroundColor);
    const bold = (node.tagName === 'SPAN' || node.tagName === 'FONT')
      && /^(bold|[6-9]00)$/.test(node.style?.fontWeight || '');
    const italic = (node.tagName === 'SPAN' || node.tagName === 'FONT')
      && node.style?.fontStyle === 'italic';

    for (const attr of Array.from(node.attributes)) {
      const permitted = (node.tagName === 'A' && (attr.name === 'href' || attr.name === 'title'))
        || (node.tagName === 'OL' && attr.name === 'start')
        || ((node.tagName === 'TH' || node.tagName === 'TD') && (attr.name === 'align' || attr.name === 'colspan' || attr.name === 'rowspan'));
      if (!permitted) node.removeAttribute(attr.name);
    }

    if (node.tagName === 'SPAN' || node.tagName === 'FONT') {
      const fragment = ownerDocument.createDocumentFragment();
      fragment.append(...node.childNodes);
      let content = fragment;
      for (const tag of [marked ? 'mark' : null, bold ? 'strong' : null, italic ? 'em' : null].filter(Boolean)) {
        const wrap = ownerDocument.createElement(tag);
        wrap.append(content);
        content = wrap;
      }
      node.replaceWith(content);
    }
  }

  return { ok: true, html: template.innerHTML, images };
}
