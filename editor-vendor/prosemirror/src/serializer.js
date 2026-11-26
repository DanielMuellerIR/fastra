import { canonicalNodeSnapshot, canonicalGroupStructure } from './parser.js';

function escapeAttrValue(v) {
  return String(v || '')
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function randomToken(prefix) {
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    return prefix + Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('') + 'END';
  }
  return prefix + Math.random().toString(16).slice(2) + Math.random().toString(16).slice(2) + 'END';
}

function makeProtector(opaqueSources) {
  const sources = [];
  let namespace = randomToken('FASTRARICHSOURCE');
  const existing = Object.values(opaqueSources || {}).join('\0');
  for (let attempt = 0; existing.includes(namespace) && attempt < 16; attempt++) {
    namespace = randomToken('FASTRARICHSOURCE');
  }
  return {
    protect(source) {
      const token = `${namespace}${sources.length}END`;
      sources.push(source);
      return token;
    },
    restore(text) {
      if (!sources.length) return text;
      return text.replace(new RegExp(`${namespace}(\\d+)END`, 'g'), (tok, idx) => sources[Number(idx)] ?? tok);
    }
  };
}

function escapePlainSegment(segment, { atBlockStart = false, tableCell = false } = {}) {
  let out = segment
    .replace(/\\/g, '\\\\')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/\*/g, '\\*')
    .replace(/_/g, '\\_')
    .replace(/`/g, '\\`')
    .replace(/\[/g, '\\[')
    .replace(/\]/g, '\\]')
    .replace(/[$~]|(?<!\\)=(?==)|(?<==)=/g, '\\$&');

  if (atBlockStart) {
    out = out
      .replace(/^(#{1,6})(\s|$)/, '\\$1$2')
      .replace(/^>/, '\\>')
      .replace(/^(\s*[-+*])(\s|$)/, (_, m, ws) => m.replace(/([-+*])$/, '\\$1') + ws)
      .replace(/^(\d+)([.)]) /, '$1\\$2 ');
  }

  if (tableCell) {
    out = out.replace(/\|/g, '\\|').replace(/ {2,}/g, s => '&#32;'.repeat(s.length));
  }
  return out;
}

/**
 * Maskiert Fließtext gemäß CommonMark + Fastras `==Marker==`-Regeln außerhalb
 * von Inline-Code und geschützten Atomen; teilt an NBSP-Läufen direkt ohne
 * kollisionsfähige Platzhalter (Astra #10).
 */
function escapeMarkdownText(text, { atBlockStart = false, tableCell = false } = {}) {
  const clean = String(text || '').replace(/\u200b/g, '');
  if (!clean) return '';
  if (!clean.includes('\u00a0')) {
    return escapePlainSegment(clean, { atBlockStart, tableCell });
  }
  const parts = clean.split(/(\u00a0+)/);
  return parts
    .map((part, idx) => {
      if (!part) return '';
      if (part.startsWith('\u00a0')) return '&nbsp;'.repeat(part.length);
      return escapePlainSegment(part, { atBlockStart: atBlockStart && idx === 0, tableCell });
    })
    .join('');
}

function escapeHTMLText(text) {
  return String(text || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function markKey(mark) {
  return `${mark.type.name}:${JSON.stringify(mark.attrs)}`;
}

const MARK_ORDER = {
  link: 1,
  html_u: 2,
  html_ins: 2,
  html_small: 2,
  html_sub: 2,
  html_sup: 2,
  html_kbd: 2,
  html_samp: 2,
  html_var: 2,
  html_q: 2,
  html_cite: 2,
  html_abbr: 2,
  html_dfn: 2,
  strong: 3,
  em: 4,
  strike: 5,
  highlight: 6,
  code: 7
};

function sortMarks(marks) {
  return [...marks].sort((a, b) => (MARK_ORDER[a.type.name] || 10) - (MARK_ORDER[b.type.name] || 10));
}

function isPunctuation(c) {
  return !!c && /[\p{P}\p{S}]/u.test(c);
}

function isSpaceOrEmpty(c) {
  return !c || /\s/u.test(c);
}

/**
 * CommonMark-kompatible Flankierungsprüfung für `**`, `*`, `==`, `~~` (Astra #9):
 * Ränder aus Leerzeichen wandern vor bzw. hinter die Begrenzer, damit CommonMark
 * z. B. ` **b** ` nicht als ungültig abweist und keine Leerzeichen verliert.
 */
function wrapDelimiterMark(rawInner, tag, delimiter, prevChar, nextChar, prevMarks, nextMarks, familyNames) {
  if (!rawInner) return '';
  const lead = rawInner.match(/^\s+/)?.[0] || '';
  const trail = rawInner.match(/\s+$/)?.[0] || '';
  const inner = rawInner.slice(lead.length, rawInner.length - trail.length);
  if (!inner) return rawInner;

  const effectivePrev = lead ? Array.from(lead).at(-1) : prevChar;
  const effectiveNext = trail ? Array.from(trail)[0] : nextChar;
  const effectivePrevMarks = lead ? [] : prevMarks;
  const effectiveNextMarks = trail ? [] : nextMarks;

  const edge = delimiter[0] === '*' ? inner.replace(/^\*+|\*+$/g, '') : inner;
  const chars = Array.from(edge);
  const first = chars[0] || '';
  const last = chars.at(-1) || '';

  const touchesNeighbor = (marks, ch) =>
    !isSpaceOrEmpty(ch) && marks.some(m => familyNames.includes(m.type.name));

  const joined =
    touchesNeighbor(effectivePrevMarks, effectivePrev) ||
    touchesNeighbor(effectiveNextMarks, effectiveNext) ||
    (delimiter === '==' && [effectivePrev, effectiveNext, first, last].includes('='));

  const unsafe =
    joined ||
    (isPunctuation(first) && !isSpaceOrEmpty(effectivePrev) && !isPunctuation(effectivePrev)) ||
    (isPunctuation(last) && !isSpaceOrEmpty(effectiveNext) && !isPunctuation(effectiveNext));

  const wrapped = unsafe ? `<${tag}>${inner}</${tag}>` : `${delimiter}${inner}${delimiter}`;
  return `${lead}${wrapped}${trail}`;
}

function extractInlineRuns(fragment) {
  const runs = [];
  fragment.forEach(node => {
    runs.push(node);
  });
  return runs;
}

function firstCharOfNode(node) {
  if (!node) return '';
  if (node.isText) return Array.from(node.text.replace(/\u200b/g, ''))[0] || '';
  if (node.type.name === 'image' || node.type.name === 'math_inline' || node.type.name === 'opaque_inline') return '\ufffc';
  return '';
}

function lastCharOfNode(node) {
  if (!node) return '';
  if (node.isText) return Array.from(node.text.replace(/\u200b/g, '')).at(-1) || '';
  if (node.type.name === 'image' || node.type.name === 'math_inline' || node.type.name === 'opaque_inline') return '\ufffc';
  return '';
}

function serializeCodeSpan(rawText, { tableCell = false } = {}) {
  const clean = String(rawText || '').replace(/\u200b/g, '');
  const lines = clean.split(/\r\n?|\n/);
  return lines
    .map(part => {
      if (!part) return '';
      const runs = part.match(/`+/g) || [];
      const fenceLen = runs.length ? Math.max(...runs.map(r => r.length)) + 1 : 1;
      const fence = '`'.repeat(fenceLen);
      const needsPad = /^`/.test(part) || /`$/.test(part) || (/^ /.test(part) && / $/.test(part) && /[^ ]/.test(part));
      let out = needsPad ? `${fence} ${part} ${fence}` : `${fence}${part}${fence}`;
      if (tableCell) out = out.replace(/\|/g, '\\|');
      return out;
    })
    .join(tableCell ? '<br>' : '  \n');
}

function formatLinkDestination(rawHref) {
  const href = String(rawHref || '');
  if (!href) return '';
  if (/[\s()<>[\]\u0000-\u001f]/.test(href)) {
    return `<${href.replace(/</g, '%3C').replace(/>/g, '%3E')}>`;
  }
  return href;
}

function formatLinkTitle(rawTitle) {
  if (rawTitle == null || rawTitle === '') return '';
  // Backslash, Anführungszeichen und HTML-Entity-ähnliche Sequenzen maskieren,
  // damit z. B. `title="&copy;"` beim Wiederöffnen wörtlich bleibt (Sol #16).
  const escaped = String(rawTitle)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/&(?=[A-Za-z0-9#]+;)/g, '\\&');
  return ` "${escaped}"`;
}

export function serializeInline(fragment, { opaqueSources = {}, protect = null, tableCell = false, inHeading = false } = {}) {
  const children = extractInlineRuns(fragment);
  if (!children.length) return '';

  const consecutiveBreaks = new Set();
  for (let idx = 0; idx < children.length; idx++) {
    if (children[idx].type.name === 'hard_break') {
      let runEnd = idx + 1;
      while (runEnd < children.length && children[runEnd].type.name === 'hard_break') runEnd++;
      if (runEnd - idx > 1) {
        for (let k = idx; k < runEnd; k++) consecutiveBreaks.add(children[k]);
      }
      idx = runEnd - 1;
    }
  }

  function renderSlice(nodes, activeMarkKeys, atBlockStart) {
    let out = '';
    let i = 0;
    while (i < nodes.length) {
      const node = nodes[i];
      const sorted = sortMarks(node.marks || []).filter(m => !activeMarkKeys.has(m.type.name === 'link' ? markKey(m) : m.type.name));

      if (sorted.length > 0) {
        const outer = sorted[0];
        const key = outer.type.name === 'link' ? markKey(outer) : outer.type.name;
        const matchFn = m => (m.type.name === 'link' ? markKey(m) === key : m.type.name === outer.type.name);
        let j = i + 1;
        while (j < nodes.length && nodes[j].marks.some(matchFn)) j++;

        const subNodes = nodes.slice(i, j);
        const nextActive = new Set(activeMarkKeys);
        nextActive.add(key);

        if (outer.type.name === 'code') {
          const parts = [];
          for (const sn of subNodes) {
            if (sn.isText) parts.push(sn.text);
            else if (sn.type.name === 'hard_break') parts.push('\n');
            else if (sn.type.name === 'image') parts.push(renderLeafInline(sn));
            else if (sn.type.name === 'math_inline' || sn.type.name === 'opaque_inline') parts.push(renderLeafInline(sn));
          }
          out += serializeCodeSpan(parts.join(''), { tableCell });
        } else {
          const inner = renderSlice(subNodes, nextActive, false);
          const prevNode = i > 0 ? nodes[i - 1] : null;
          const nextNode = j < nodes.length ? nodes[j] : null;
          const prevChar = lastCharOfNode(prevNode);
          const nextChar = firstCharOfNode(nextNode);
          const prevMarks = (prevNode?.marks || []).filter(m => !activeMarkKeys.has(m.type.name));
          const nextMarks = (nextNode?.marks || []).filter(m => !activeMarkKeys.has(m.type.name));

          if (outer.type.name === 'strong') {
            out += wrapDelimiterMark(inner, 'strong', '**', prevChar, nextChar, prevMarks, nextMarks, ['strong', 'em']);
          } else if (outer.type.name === 'em') {
            out += wrapDelimiterMark(inner, 'em', '*', prevChar, nextChar, prevMarks, nextMarks, ['strong', 'em']);
          } else if (outer.type.name === 'highlight') {
            out += wrapDelimiterMark(inner, 'mark', '==', prevChar, nextChar, prevMarks, nextMarks, ['highlight']);
          } else if (outer.type.name === 'strike') {
            out += wrapDelimiterMark(inner, 'del', '~~', prevChar, nextChar, prevMarks, nextMarks, ['strike']);
          } else if (outer.type.name === 'link') {
            const dest = formatLinkDestination(outer.attrs.href);
            const title = formatLinkTitle(outer.attrs.title);
            out += `[${inner}](${dest}${title})`;
          } else if (outer.type.name.startsWith('html_')) {
            const tag = outer.type.name.slice(5);
            const attrs = ['title', 'dir', 'lang']
              .filter(a => outer.attrs[a] != null && outer.attrs[a] !== '')
              .map(a => ` ${a}="${escapeAttrValue(outer.attrs[a])}"`)
              .join('');
            out += `<${tag}${attrs}>${inner}</${tag}>`;
          } else {
            out += inner;
          }
        }
        i = j;
        continue;
      }

      out += renderLeafInline(node, atBlockStart && i === 0);
      i++;
    }
    return out;
  }

  function renderLeafInline(node, isStart) {
    if (node.isText) {
      return escapeMarkdownText(node.text, { atBlockStart: isStart, tableCell });
    }
    if (node.type.name === 'hard_break') {
      return (tableCell || inHeading || consecutiveBreaks.has(node)) ? '<br>' : '  \n';
    }
    if (node.type.name === 'image') {
      const mdSrc = node.attrs.mdSrc ?? node.attrs.src ?? '';
      if (!mdSrc) return '';
      const alt = String(node.attrs.alt || '').replace(/[\\[\]]/g, '\\$&');
      const wrappedSrc = `<${String(mdSrc).replace(/</g, '%3C').replace(/>/g, '%3E')}>`;
      const title = node.attrs.title ? ` "${String(node.attrs.title).replace(/[\\"]/g, '\\$&')}"` : '';
      return `![${alt}](${wrappedSrc}${title})`;
    }
    if (node.type.name === 'math_inline') {
      if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === 'string') {
        const src = opaqueSources[node.attrs.mathSourceKey];
        return protect ? protect(src) : src;
      }
      return `$${node.attrs.tex || ''}$`;
    }
    if (node.type.name === 'opaque_inline') {
      if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === 'string') {
        const src = opaqueSources[node.attrs.mathSourceKey];
        return protect ? protect(src) : src;
      }
      const raw = opaqueSources[node.attrs.opaqueKey] || '';
      const val = tableCell ? raw.replace(/\|/g, '\\|') : raw;
      return val && protect ? protect(val) : val;
    }
    return '';
  }

  return renderSlice(children, new Set(), true);
}

function serializeCellInnerHTML(cellNode, opaqueSources, protect) {
  let out = '';
  cellNode.content.forEach(child => {
    let chunk = '';
    if (child.isText) {
      chunk = escapeHTMLText(child.text.replace(/\u200b/g, ''));
    } else if (child.type.name === 'hard_break') {
      chunk = '<br>';
    } else if (child.type.name === 'image') {
      const src = escapeAttrValue(child.attrs.mdSrc ?? child.attrs.src ?? '');
      const alt = child.attrs.alt ? ` alt="${escapeAttrValue(child.attrs.alt)}"` : '';
      const title = child.attrs.title ? ` title="${escapeAttrValue(child.attrs.title)}"` : '';
      chunk = `<img src="${src}"${alt}${title}>`;
    } else if (child.type.name === 'math_inline') {
      const src = child.attrs.mathSourceKey && typeof opaqueSources[child.attrs.mathSourceKey] === 'string'
        ? opaqueSources[child.attrs.mathSourceKey]
        : `$${child.attrs.tex || ''}$`;
      chunk = protect ? protect(src) : src;
    } else if (child.type.name === 'opaque_inline') {
      const src = child.attrs.mathSourceKey && typeof opaqueSources[child.attrs.mathSourceKey] === 'string'
        ? opaqueSources[child.attrs.mathSourceKey]
        : (opaqueSources[child.attrs.opaqueKey] || '');
      chunk = src && protect ? protect(src) : src;
    }
    for (const m of [...(child.marks || [])].reverse()) {
      if (m.type.name === 'strong') chunk = `<strong>${chunk}</strong>`;
      else if (m.type.name === 'em') chunk = `<em>${chunk}</em>`;
      else if (m.type.name === 'code') chunk = `<code>${chunk}</code>`;
      else if (m.type.name === 'highlight') chunk = `<mark>${chunk}</mark>`;
      else if (m.type.name === 'strike') chunk = `<del>${chunk}</del>`;
      else if (m.type.name === 'link') {
        const href = escapeAttrValue(m.attrs.href || '');
        const title = m.attrs.title ? ` title="${escapeAttrValue(m.attrs.title)}"` : '';
        chunk = `<a href="${href}"${title}>${chunk}</a>`;
      } else if (m.type.name.startsWith('html_')) {
        const tag = m.type.name.slice(5);
        const attrs = ['title', 'dir', 'lang']
          .filter(a => m.attrs[a] != null && m.attrs[a] !== '')
          .map(a => ` ${a}="${escapeAttrValue(m.attrs[a])}"`)
          .join('');
        chunk = `<${tag}${attrs}>${chunk}</${tag}>`;
      }
    }
    out += chunk;
  });
  return out;
}

function serializeHTMLTable(tableNode, opaqueSources, protect) {
  const rowsHTML = [];
  const headRows = [];
  const bodyRows = [];

  tableNode.content.forEach(row => {
    const cells = [];
    let isHeaderRow = true;
    row.content.forEach(cell => {
      const isTH = cell.type.name === 'table_header';
      if (!isTH) isHeaderRow = false;
      const tag = isTH ? 'th' : 'td';
      const attrs = [];
      if (cell.attrs.align) attrs.push(` align="${escapeAttrValue(cell.attrs.align)}"`);
      if (cell.attrs.colspan > 1) attrs.push(` colspan="${cell.attrs.colspan}"`);
      if (cell.attrs.rowspan > 1) attrs.push(` rowspan="${cell.attrs.rowspan}"`);
      const cellWithMarks = serializeCellInnerHTML(cell, opaqueSources, protect);
      cells.push(`<${tag}${attrs.join('')}>${cellWithMarks}</${tag}>`);
    });
    const tr = `<tr>${cells.join('')}</tr>`;
    if (isHeaderRow && bodyRows.length === 0) headRows.push(tr);
    else bodyRows.push(tr);
  });

  if (headRows.length) rowsHTML.push(`<thead>${headRows.join('')}</thead>`);
  if (bodyRows.length) rowsHTML.push(`<tbody>${bodyRows.join('')}</tbody>`);
  return `<table>${rowsHTML.join('')}</table>`;
}

function serializeTable(tableNode, opaqueSources, protect) {
  let hasMerged = !tableNode.attrs.gfm;
  tableNode.content.forEach(row => {
    row.content.forEach(cell => {
      if (cell.attrs.colspan > 1 || cell.attrs.rowspan > 1) hasMerged = true;
    });
  });
  if (hasMerged) {
    return serializeHTMLTable(tableNode, opaqueSources, protect);
  }

  const rows = [];
  tableNode.content.forEach(row => rows.push(row));
  if (!rows.length) return '';

  const width = Math.max(1, ...rows.map(r => r.childCount));
  const lines = rows.map(row => {
    const renderedCells = [];
    for (let i = 0; i < width; i++) {
      const cell = i < row.childCount ? row.child(i) : null;
      if (!cell) {
        renderedCells.push('');
        continue;
      }
      const val = serializeInline(cell.content, { opaqueSources, protect, tableCell: true })
        .replace(/\r\n?|\n/g, '<br>')
        .replace(/^ +| +$/g, s => '&#32;'.repeat(s.length));
      renderedCells.push(val);
    }
    return `| ${renderedCells.join(' | ')} |`;
  });

  const firstRowHasTH = [];
  rows[0].content.forEach(c => firstRowHasTH.push(c.type.name === 'table_header'));
  if (!firstRowHasTH.some(Boolean)) {
    lines.unshift(`| ${Array(width).fill(' ').join(' | ')} |`);
  }

  const sepCells = Array.from({ length: width }, (_, i) => {
    const align = i < rows[0].childCount ? rows[0].child(i).attrs.align : null;
    if (align === 'center') return ':---:';
    if (align === 'right') return '---:';
    if (align === 'left') return ':---';
    return '---';
  });
  lines.splice(1, 0, `| ${sepCells.join(' | ')} |`);
  return lines.join('\n');
}

/**
 * Serialisiert einen einzelnen ProseMirror-Block knotenrein zu Markdown.
 */
export function serializeBlockNode(node, { opaqueSources = {}, protect = null, insideContainer = false } = {}) {
  switch (node.type.name) {
    case 'blank_line':
      return node.content.size > 0
        ? serializeInline(node.content, { opaqueSources, protect })
        : '  ';
    case 'paragraph': {
      const items = extractInlineRuns(node.content);
      let trailingBreaks = 0;
      while (items.length && items.at(-1).type.name === 'hard_break') {
        items.pop();
        trailingBreaks++;
      }
      if (!insideContainer && trailingBreaks >= 1) {
        // Im Fließtext verwandelt sich jeder abschließende harte Umbruch in eine
        // eigene sichtbare Leerzeile (`Alpha\n\n  `), statt HTML oder tote Spaces
        // am Blockende zu lassen (Astra #8).
        const mainText = items.length
          ? serializeInline({ forEach: fn => items.forEach((n, i) => fn(n, i)) }, { opaqueSources, protect })
          : '';
        const blanks = Array(trailingBreaks).fill('  ').join('\n\n');
        return mainText ? `${mainText}\n\n${blanks}` : blanks;
      }
      if (insideContainer) {
        for (let k = 0; k < trailingBreaks; k++) {
          items.push(node.type.schema.nodes.hard_break.create());
        }
      }
      return items.length
        ? serializeInline({ forEach: fn => items.forEach((n, i) => fn(n, i)) }, { opaqueSources, protect })
        : '';
    }
    case 'heading': {
      const hashes = '#'.repeat(Math.min(6, Math.max(1, node.attrs.level || 1)));
      const text = serializeInline(node.content, { opaqueSources, protect, inHeading: true });
      return text ? `${hashes} ${text}` : `${hashes} `;
    }
    case 'horizontal_rule':
      return '---';
    case 'code_block': {
      const raw = node.textContent.replace(/\n$/, '');
      const runs = raw.match(/`+/g) || [];
      const fence = '`'.repeat(Math.max(3, ...runs.map(r => r.length + 1)));
      const lang = node.attrs.language || '';
      return `${fence}${lang}\n${raw}\n${fence}`;
    }
    case 'blockquote': {
      const childStrings = [];
      node.content.forEach(child => {
        childStrings.push(serializeBlockNode(child, { opaqueSources, protect, insideContainer: true }));
      });
      const joined = childStrings.join('\n\n');
      return joined
        .split('\n')
        .map(line => (line ? `> ${line}` : '>'))
        .join('\n');
    }
    case 'bullet_list':
    case 'ordered_list': {
      const isOrdered = node.type.name === 'ordered_list';
      const start = isOrdered ? Math.max(0, Number(node.attrs.order ?? 1)) : 1;
      const isLoose = !node.attrs.tight;
      const renderedItems = [];

      node.content.forEach((item, _offset, index) => {
        const marker = isOrdered ? `${start + index}. ` : '- ';
        const taskPrefix = item.attrs.task !== null ? (item.attrs.task ? '[x] ' : '[ ] ') : '';
        const pad = ' '.repeat(marker.length);
        const childParts = [];

        item.content.forEach((child, _cOffset, cIdx) => {
          const text = serializeBlockNode(child, { opaqueSources, protect, insideContainer: true });
          const prefix = cIdx === 0 ? taskPrefix : '';
          const prefixed = prefix + text;
          const lines = prefixed.split('\n');
          childParts.push(
            lines
              .map((line, lIdx) => (cIdx === 0 && lIdx === 0 ? marker + line : (line ? pad + line : '')))
              .join('\n')
          );
        });

        renderedItems.push(childParts.join(isLoose ? '\n\n' : '\n'));
      });

      return renderedItems.join(isLoose ? '\n\n' : '\n');
    }
    case 'table':
      return serializeTable(node, opaqueSources, protect);
    case 'math_block': {
      if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === 'string') {
        const src = opaqueSources[node.attrs.mathSourceKey];
        return protect ? protect(src) : src;
      }
      return `$$\n${node.attrs.tex || ''}\n$$`;
    }
    case 'opaque_block': {
      if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === 'string') {
        const src = opaqueSources[node.attrs.mathSourceKey];
        return protect ? protect(src) : src;
      }
      const src = opaqueSources[node.attrs.opaqueKey] || '';
      return src && protect ? protect(src) : src;
    }
    default:
      return '';
  }
}

function findImageEnding(node) {
  let found = null;
  node.descendants(child => {
    if (!found && child.type.name === 'image' && child.attrs.imageEnding) {
      found = child.attrs.imageEnding === 'crlf' ? '\r\n' : '\r';
      return false;
    }
    return true;
  });
  return found;
}

export function serializeDocument(doc, {
  contexts,
  originals,
  opaqueSources = {},
  lastInputType = ''
} = {}) {
  const emptyDocPlaceholder =
    doc.childCount === 1 &&
    doc.firstChild.type.name === 'paragraph' &&
    doc.firstChild.attrs.mdEmpty &&
    doc.firstChild.content.size === 0;

  const deletedPlaceholder =
    !emptyDocPlaceholder &&
    (doc.firstChild.attrs.mdDeleted || String(lastInputType || '').startsWith('delete')) &&
    doc.childCount === 1 &&
    doc.firstChild.type.name === 'paragraph' &&
    doc.firstChild.content.size === 0;

  let contextKey = doc.attrs.sourceContext || '';
  if (!contextKey) {
    for (let i = 0; i < doc.childCount; i++) {
      const child = doc.child(i);
      if (child.attrs?.mdBlockId != null && child.attrs.mdContext) {
        contextKey = child.attrs.mdContext;
        break;
      }
    }
  }
  const ctx = contexts?.get(contextKey) || contexts?.get('') || {
    blocks: [],
    hiddenPrefixes: new Map(),
    trailingHidden: new Set(),
    trailingOwner: null
  };

  if (emptyDocPlaceholder) {
    // Reine Referenzdokumente mit eigenen Leerzeilen bytegenau erhalten (Astra #12).
    return (ctx.blocks || []).filter(b => b.hidden).map(b => b.source).join('');
  }
  if (deletedPlaceholder) {
    return (ctx.blocks || []).filter(b => b.hidden && b.source.trim()).map(b => b.source).join('');
  }

  const protector = makeProtector(opaqueSources);
  const usedOrigins = new Set();
  const emittedHidden = new Set();
  const topNodes = [];
  doc.content.forEach(child => topNodes.push(child));

  // Mehrfaches Vorkommen derselben Single-Block-ID (z. B. nach Enter-Teilung eines
  // Absatzes ohne Zeilenumbruch am Ende) vorab erkennen, damit zwischen den
  // Teilabsätzen immer ein gültiger Absatz-Trenner entsteht (Astra #7).
  const singleOriginCounts = new Map();
  for (const n of topNodes) {
    if (n.attrs?.mdBlockId != null && Number(n.attrs?.mdBlockTotal || 1) === 1) {
      const k = `${n.attrs.mdContext || ''}${n.attrs.mdBlockId}`;
      singleOriginCounts.set(k, (singleOriginCounts.get(k) || 0) + 1);
    }
  }

  let output = '';
  let prevBlockWasVerbatim = true;

  function emitHiddenForBlock(fullId) {
    if (emittedHidden.has(fullId)) return;
    emittedHidden.add(fullId);
    for (const h of ctx.hiddenPrefixes?.get(fullId) || []) {
      emittedHidden.add('hidden:' + h.id);
      if (!prevBlockWasVerbatim && !h.source.trim() && /(\r\n|\r|\n){2}$/.test(output)) {
        continue;
      }
      output += h.source;
    }
  }

  const docEnding = (ctx.blocks || []).some(b => b.source?.includes('\r\n'))
    ? '\r\n'
    : (ctx.blocks || []).some(b => b.source?.includes('\r'))
      ? '\r'
      : '\n';

  let idx = 0;
  while (idx < topNodes.length) {
    const node = topNodes[idx];
    const mdCtx = node.attrs?.mdContext || '';
    const mdBlockId = node.attrs?.mdBlockId || null;
    const total = Math.max(1, Number(node.attrs?.mdBlockTotal || 1));
    const sub = Number(node.attrs?.mdBlockSub || 0);
    const fullId = mdBlockId != null ? `${mdCtx}${mdBlockId}` : null;
    const original = fullId != null ? originals?.get(fullId) : null;
    const isSplitSingleOrigin = fullId != null && total === 1 && (singleOriginCounts.get(fullId) || 0) > 1;

    if (original && !isSplitSingleOrigin && !usedOrigins.has(fullId) && sub === 0 && idx + total <= topNodes.length) {
      const group = topNodes.slice(idx, idx + total);
      const completeOrder = group.every(
        (cand, k) =>
          (cand.attrs?.mdContext || '') === mdCtx &&
          cand.attrs?.mdBlockId === mdBlockId &&
          Number(cand.attrs?.mdBlockSub || 0) === k &&
          Number(cand.attrs?.mdBlockTotal || 1) === total
      );
      if (completeOrder) {
        const snap = JSON.stringify(group.map(canonicalNodeSnapshot));
        if (snap === original.canonicalSnapshot) {
          usedOrigins.add(fullId);
          emitHiddenForBlock(fullId);
          output += original.source;
          prevBlockWasVerbatim = true;
          idx += total;
          continue;
        }
      }
    }

    if (fullId != null) {
      usedOrigins.add(fullId);
      emitHiddenForBlock(fullId);
    }

    const sourceEnding = original?.source?.includes('\r\n')
      ? '\r\n'
      : original?.source?.includes('\r')
        ? '\r'
        : docEnding;
    const imgEnding = findImageEnding(node);
    const ending = imgEnding || sourceEnding;

    // Vorheriger unveränderter Block mit nur einem Zeilenende vor einem geänderten
    // oder neu eingefügten Block braucht eine Trennzeile, damit kein Titel o. Ä. verklebt.
    if (idx > 0 && output.length > 0 && !/(\r\n|\r|\n){2}$/.test(output)) {
      if (/(\r\n|\r|\n)$/.test(output)) {
        output += ending;
      } else {
        output += ending + ending;
      }
    }

    if (original && sub === 0 && total > 1 && idx + total <= topNodes.length) {
      const group = topNodes.slice(idx, idx + total);
      const sameGroup = group.every(
        (cand, k) =>
          (cand.attrs?.mdContext || '') === mdCtx &&
          cand.attrs?.mdBlockId === mdBlockId &&
          Number(cand.attrs?.mdBlockSub || 0) === k &&
          Number(cand.attrs?.mdBlockTotal || 1) === total
      );
      if (sameGroup) {
        const rendered = group.map(n => serializeBlockNode(n, { opaqueSources, protect: protector.protect })).join('\n\n');
        let text = ending !== '\n' ? rendered.replace(/\r\n?|\n/g, ending) : rendered;
        text = protector.restore(text);
        const suffix = canonicalGroupStructure(group) === original.structure
          ? (original.source.match(/[\r\n]*$/)?.[0] ?? ending + ending)
          : ending + ending;
        output += text + suffix;
        prevBlockWasVerbatim = false;
        idx += total;
        continue;
      }
    }

    const rendered = serializeBlockNode(node, { opaqueSources, protect: protector.protect });
    let text = ending !== '\n' ? rendered.replace(/\r\n?|\n/g, ending) : rendered;
    text = protector.restore(text);

    const hasNext = idx + 1 < topNodes.length;
    const rawTail = original?.source?.match(/[\r\n]*$/)?.[0] ?? '';
    const rawLineCount = (rawTail.match(/\r\n|\r|\n/g) || []).length;
    const safeTail = (hasNext && rawLineCount < 2) ? (ending + ending) : rawTail;

    if (original && total === 1 && !isSplitSingleOrigin) {
      const suffix = canonicalGroupStructure([node]) === original.structure
        ? safeTail
        : ending + ending;
      output += text + suffix;
    } else if (isSplitSingleOrigin && !hasNext && original) {
      // Nur das letzte Stück eines geteilten Originals darf den ursprünglichen
      // Dateiendungs-Suffix (z. B. `""` oder `"\n"`) übernehmen; zwischen den
      // geteilten Absätzen erzwingen wir `ending + ending` (Astra #7).
      const tailSuffix = canonicalGroupStructure([node]) === original.structure
        ? rawTail
        : ending + ending;
      output += text + tailSuffix;
    } else if (node.type.name === 'blank_line' && !node.content.size) {
      output += `  ${ending}${ending}`;
    } else {
      output += text ? `${text}${ending}${ending}` : ending;
    }
    prevBlockWasVerbatim = false;
    idx += 1;
  }

  for (const b of ctx.blocks || []) {
    if (
      b.hidden &&
      !emittedHidden.has('hidden:' + b.id) &&
      (b.source.trim() || (ctx.trailingHidden?.has(b.id) && (ctx.trailingOwner === null || usedOrigins.has(ctx.trailingOwner))))
    ) {
      output += b.source;
    }
  }

  return output;
}
