
const DIAGNOSTIC_MAX_EVENTS = 200;
const DIAGNOSTIC_MAX_BYTES = 262144;

const ALLOWED_ANOMALY_FIELDS = new Set([
  'command',
  'beforeTextLen',
  'afterTextLen',
  'lineno',
  'colno',
  'reason',
  'outcome',
  'offset'
]);

const ALLOWED_EVENT_FIELDS = new Set([
  'command',
  'beforeTextLen',
  'afterTextLen',
  'key',
  'meta',
  'ctrl',
  'shift',
  'alt',
  'blockCount',
  'markdownLen',
  'empty',
  'code',
  'lineno',
  'colno',
  'sel'
]);

/**
 * Normalisiert den semantischen Blocktyp eines ProseMirror- oder DOM-Knotens
 * für Live- und Speicherprüfungen (Finding: auch H1-H6, Listen, Zitate prüfen).
 */
const ALLOWED_KEY_NAMES = new Set([
  'Enter', 'Backspace', 'Delete', 'Tab', 'Escape',
  'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
  'Home', 'End', 'PageUp', 'PageDown',
  'Shift', 'Control', 'Alt', 'Meta'
]);
const ALLOWED_SHORTCUT_KEYS = new Set(['a', 'b', 'c', 'i', 'k', 'u', 'v', 'x', 'y', 'z']);

export function sanitizeDiagnosticKey(key, hasModifier) {
  if (typeof key !== 'string' || !key.length) return 'unknown';
  if (ALLOWED_KEY_NAMES.has(key)) return key;
  if (hasModifier && ALLOWED_SHORTCUT_KEYS.has(key.toLowerCase())) return key.toLowerCase();
  return 'char';
}

export function semanticBlockTag(tagName) {
  switch (tagName) {
    case 'H1':
    case 'H2':
    case 'H3':
    case 'H4':
    case 'H5':
    case 'H6':
    case 'UL':
    case 'OL':
    case 'LI':
    case 'BLOCKQUOTE':
    case 'PRE':
    case 'TABLE':
    case 'HR':
      return tagName;
    case 'P':
    case 'DIV':
      return 'P';
    default:
      return null;
  }
}

function emptyPMOrDOMPlaceholder(container) {
  if (!container) return null;
  const children = Array.from(container.children).filter(
    n => !n.hasAttribute('data-md-edit-boundary') && !n.classList.contains('ProseMirror-separator')
  );
  if (children.length !== 1) return null;
  const node = children[0];
  if (
    !node.hasAttribute('data-md-empty') ||
    node.textContent.replace(/\u200b/g, '').length > 0 ||
    node.querySelector('img:not(.ProseMirror-separator),input,hr,table,pre,code,[data-md-opaque],[data-tex]') ||
    Array.from(container.childNodes).some(n => n.nodeType === 3 && n.data.trim())
  ) {
    return null;
  }
  return node;
}

function deletedDocumentPlaceholder(container, _inputType) {
  const visible = Array.from(container.children).filter(
    n => !n.hasAttribute('data-md-edit-boundary') && !n.classList.contains('ProseMirror-separator')
  );
  return visible.length === 1 &&
    visible[0].tagName === 'P' &&
    !visible[0].textContent.replace(/\u200b/g, '').length &&
    !Array.from(container.childNodes).some(n => n.nodeType === 3 && n.data.trim()) &&
    visible[0].querySelectorAll('br').length <= 1 &&
    !visible[0].querySelector('img:not(.ProseMirror-separator),input,hr,table,pre,code,[data-md-opaque],[data-tex]')
    ? visible[0]
    : null;
}

/**
 * Extrahiert das sichtbare Erscheinungsbild (Text, Inline-Formate, Umbrüche und
 * semantische Blocktypen) eines gerenderten DOM-Baums oder Template-Fragments.
 */
export function saveAppearance(container, inputType = '') {
  const placeholder = emptyPMOrDOMPlaceholder(container) || deletedDocumentPlaceholder(container, inputType);
  const blockSet = /^(DIV|P|SECTION|H[1-6]|UL|OL|LI|BLOCKQUOTE|TABLE|THEAD|TBODY|TFOOT|TR|TD|TH|PRE|HR)$/;
  const tags = { B: 1, STRONG: 1, I: 2, EM: 2, MARK: 4, DEL: 8, S: 8, STRIKE: 8, CODE: 16 };
  let text = '';
  let space = false;
  let pendingBreaks = 0;
  let totalBreaks = 0;
  const formats = [];
  const breaks = [];
  const blockTypes = [];
  const links = [];
  const tasks = [];
  const listStarts = [];

  function recordBreaks(count) {
    if (!count) return;
    if (breaks.at(-1)?.[0] === text.length) breaks.at(-1)[1] += count;
    else breaks.push([text.length, count]);
    totalBreaks += count;
  }

  function boundary() {
    if (pendingBreaks > 0) {
      recordBreaks(pendingBreaks);
    }
    pendingBreaks = 0;
    space = !!text;
  }

  function addText(value, style) {
    for (const word of String(value || '').replace(/\u200b/g, '').match(/[^ \t\r\n\f]+|[ \t\r\n\f]+/g) || []) {
      if (/^[ \t\r\n\f]/.test(word)) {
        space = !!text;
        continue;
      }
      if (pendingBreaks) {
        recordBreaks(pendingBreaks);
        pendingBreaks = 0;
        space = !!text;
      }
      if (space) {
        text += ' ';
        space = false;
      }
      const start = text.length;
      text += word;
      if (style) {
        const previous = formats.at(-1);
        if (previous?.[1] === start && previous[2] === style) previous[1] = text.length;
        else formats.push([start, text.length, style]);
      }
    }
  }

  function visit(node, style, tableCell = false) {
    if (node.nodeType === 3) {
      if (tableCell) {
        node.data.split(/\r\n?|\n/).forEach((part, index) => {
          if (index) pendingBreaks++;
          addText(part, style);
        });
      } else {
        addText(node.data, style);
      }
      return;
    }
    if (
      node.nodeType !== 1 ||
      node === placeholder ||
      node.hasAttribute('data-md-edit-boundary') ||
      node.classList?.contains('ProseMirror-separator') ||
      node.classList?.contains('ProseMirror-trailingBreak')
    ) {
      return;
    }
    const tag = node.tagName;
    const isBlock = blockSet.test(tag);
    if (tag === 'INPUT' && node.type === 'checkbox') {
      tasks.push(!!(node.checked || node.hasAttribute('checked')));
      return;
    }
    if (tag === 'OL') {
      const startAttr = node.getAttribute('start')?.trim();
      listStarts.push(startAttr && /^[+-]?\d+$/.test(startAttr) ? Number(startAttr) : 1);
    }
    if (tag === 'A' && node.hasAttribute('href')) {
      links.push(node.getAttribute('href') || '');
    }
    if (node.classList?.contains('fastra-pm-li-content') || (tag === 'DIV' && node.classList?.contains('ProseMirror'))) {
      for (const child of node.childNodes) visit(child, style, tableCell);
      return;
    }

    if (node.hasAttribute('data-tex') || node.hasAttribute('data-md-opaque')) {
      if (isBlock) boundary();
      addText('\ufffc', style);
      if (isBlock) boundary();
      return;
    }
    if (tag === 'DIV' && node.classList?.contains('fastra-visible-blank-line')) {
      boundary();
      const emptyBlank = !node.textContent.replace(/\u200b/g, '').length &&
        !node.querySelector('img:not(.ProseMirror-separator),[data-tex],[data-md-opaque],hr,table,pre,input');
      if (emptyBlank) {
        recordBreaks(1);
        boundary();
        return;
      }
    }
    if (tag === 'BR') {
      pendingBreaks++;
      return;
    }
    if (isBlock) {
      boundary();
      const semantic = semanticBlockTag(tag);
      const liParent = tag === 'P' ? node.closest?.('li') : null;
      const cellParent = tag === 'P' ? node.closest?.('td,th') : null;
      const emptyTopParagraph = tag === 'P' &&
        !liParent &&
        !cellParent &&
        !node.textContent.replace(/[\u200b \t\r\n\f]/g, '').length &&
        !node.querySelector('img:not(.ProseMirror-separator),[data-tex],[data-md-opaque],hr,table,pre,input,br:not(.ProseMirror-trailingBreak)');
      if (emptyTopParagraph) {
        // Ein leerer Top-Level-Absatz außerhalb von Platzhaltern wirkt visuell wie eine
        // sichtbare Leerzeile und darf nie still gegen eine gespeicherte Leerzeile verschwinden.
        recordBreaks(1);
        boundary();
        return;
      }
      if (
        semantic &&
        !liParent &&
        !(tag === 'DIV' && (node.classList.contains('fastra-visible-blank-line') || node.hasAttribute('data-md-block')))
      ) {
        blockTypes.push(semantic);
      }
    }

    const before = text.length;
    const breakCount = totalBreaks;
    if (tag === 'IMG') {
      addText('\ufffc', style);
    } else {
      let nextStyle = style | (tags[tag] || 0);
      if (tag === 'SPAN' || tag === 'FONT') {
        const css = node.style;
        if (css?.fontWeight === 'bold' || Number(css?.fontWeight) >= 600) nextStyle |= 1;
        if (css?.fontStyle === 'italic' || css?.fontStyle === 'oblique') nextStyle |= 2;
        if (css?.backgroundColor && css.backgroundColor !== 'transparent' && css.backgroundColor !== 'rgba(0, 0, 0, 0)') nextStyle |= 4;
        if (css?.textDecorationLine?.includes('line-through')) nextStyle |= 8;
      }
      const preWrap = tableCell || ((tag === 'TD' || tag === 'TH') && !!node.closest('table[data-md-table=gfm]'));
      for (const child of node.childNodes) visit(child, nextStyle, preWrap);
    }

    if (isBlock) {
      if (text.length === before && totalBreaks === breakCount && pendingBreaks) {
        const emptyLineBreaks = (/^H[1-6]$/.test(tag) || tag === 'LI') ? Math.max(0, pendingBreaks - 1) : pendingBreaks;
        recordBreaks(emptyLineBreaks);
        pendingBreaks = 0;
      }
      boundary();
    }
  }

  for (const node of container.childNodes) visit(node, 0, false);
  boundary();
  return { text, formats, breaks, blockTypes, links, tasks, listStarts };
}

/**
 * Vergleicht zwei Erscheinungsbilder. Abweichende Blocktypen (H1-H6, Listen,
 * Zitate, Codeblöcke) liefern wie vom Schema/Vertrag gefordert `outcome: 'format'`.
 */
export function diffAppearance(live, saved, { includeContent = true } = {}) {
  if (live.text !== saved.text) {
    let at = 0;
    const minLen = Math.min(live.text.length, saved.text.length);
    while (at < minLen && live.text[at] === saved.text[at]) at++;
    const diff = {
      offset: at,
      liveLength: live.text.length,
      savedLength: saved.text.length
    };
    if (includeContent) {
      diff.liveSnippet = live.text.slice(Math.max(0, at - 20), at + 40);
      diff.savedSnippet = saved.text.slice(Math.max(0, at - 20), at + 40);
    }
    return { outcome: 'text', diff };
  }
  if (JSON.stringify(live.formats) !== JSON.stringify(saved.formats)) {
    return {
      outcome: 'format',
      diff: {
        liveCount: live.formats.length,
        savedCount: saved.formats.length,
        liveFormats: live.formats.slice(0, 12),
        savedFormats: saved.formats.slice(0, 12)
      }
    };
  }
  if (JSON.stringify(live.blockTypes) !== JSON.stringify(saved.blockTypes)) {
    return {
      outcome: 'format',
      diff: {
        liveBlockCount: live.blockTypes.length,
        savedBlockCount: saved.blockTypes.length,
        liveBlocks: live.blockTypes.slice(0, 24),
        savedBlocks: saved.blockTypes.slice(0, 24)
      }
    };
  }
  if (JSON.stringify(live.links || []) !== JSON.stringify(saved.links || [])) {
    return {
      outcome: 'format',
      diff: {
        kind: 'links',
        liveCount: (live.links || []).length,
        savedCount: (saved.links || []).length
      }
    };
  }
  if (JSON.stringify(live.tasks || []) !== JSON.stringify(saved.tasks || [])) {
    return {
      outcome: 'format',
      diff: {
        kind: 'tasks',
        liveCount: (live.tasks || []).length,
        savedCount: (saved.tasks || []).length,
        liveTasks: (live.tasks || []).slice(0, 24),
        savedTasks: (saved.tasks || []).slice(0, 24)
      }
    };
  }
  if (JSON.stringify(live.listStarts || []) !== JSON.stringify(saved.listStarts || [])) {
    return {
      outcome: 'format',
      diff: {
        kind: 'listStarts',
        liveStarts: (live.listStarts || []).slice(0, 24),
        savedStarts: (saved.listStarts || []).slice(0, 24)
      }
    };
  }
  if (JSON.stringify(live.breaks) !== JSON.stringify(saved.breaks)) {
    return {
      outcome: 'breaks',
      diff: {
        liveCount: live.breaks.length,
        savedCount: saved.breaks.length,
        liveBreaks: live.breaks.slice(0, 12),
        savedBreaks: saved.breaks.slice(0, 12)
      }
    };
  }
  return { outcome: 'ok', diff: null };
}

function redactDiff(diff, includeContent) {
  if (!diff || includeContent) return diff;
  const copy = { ...diff };
  delete copy.liveSnippet;
  delete copy.savedSnippet;
  return copy;
}

function sanitizeFields(source, allowedSet) {
  const out = {};
  for (const [k, v] of Object.entries(source || {})) {
    if (allowedSet.has(k)) out[k] = v;
  }
  return out;
}

export function createDiagnosticsController({
  postMessage,
  getSession,
  getRevision,
  getRoot,
  isFenced,
  isComposing,
  getLastInputType,
  serializeMarkdown
}) {
  const diagnosticEvents = [];
  const diagnosticAnomalies = [];
  let diagnosticBytes = 0;
  let lastAppearanceCheck = null;
  let lastRenderedHTML = null;

  function visibleTextLength(container = getRoot()) {
    if (!container) return 0;
    const clone = container.cloneNode(true);
    clone.querySelectorAll('[data-md-edit-boundary]').forEach(n => n.remove());
    // Zeilenumbrüche (\r/\n, z. B. in Codeblöcken) wie <br> behandeln, damit Umformatieren
    // zwischen Codeblock und Absatz/Überschrift keinen falschen Textverlust meldet.
    return (clone.textContent || '').replace(/[\u200b\u2060\r\n]/g, '').length;
  }

  function selectionSummary(view) {
    if (!view) return null;
    const { from, to, empty } = view.state.selection;
    return { collapsed: empty, from, to };
  }

  function domSkeleton(container = getRoot(), depth = 0) {
    if (!container || depth > 5) return null;
    const children = [];
    for (const child of Array.from(container.children).slice(0, 40)) {
      if (child.hasAttribute('data-md-edit-boundary')) continue;
      const entry = { tag: child.tagName.toLowerCase() };
      if (child.classList.contains('fastra-visible-blank-line')) entry.blank = true;
      if (child.hasAttribute('data-md-empty')) entry.empty = true;
      if (child.hasAttribute('data-md-opaque')) entry.opaque = true;
      if (child.hasAttribute('data-tex')) entry.math = true;
      if (child.tagName === 'INPUT' && child.type === 'checkbox') entry.checkbox = !!child.checked;
      if (child.children.length && !entry.opaque && !entry.math) {
        entry.children = domSkeleton(child, depth + 1);
      }
      children.push(entry);
    }
    return children;
  }

  function pushDiagnosticEvent(kind, details = {}) {
    const entry = { t: new Date().toISOString(), kind, rev: getRevision(), ...details };
    const size = JSON.stringify(entry).length + 2;
    diagnosticEvents.push(entry);
    diagnosticBytes += size;
    while (diagnosticEvents.length > DIAGNOSTIC_MAX_EVENTS || diagnosticBytes > DIAGNOSTIC_MAX_BYTES) {
      const removed = diagnosticEvents.shift();
      diagnosticBytes -= removed ? JSON.stringify(removed).length + 2 : 0;
    }
  }

  function recordAnomaly(code, summary, extra = {}) {
    const sanitizedExtra = sanitizeFields(extra, ALLOWED_ANOMALY_FIELDS);
    const entry = {
      t: new Date().toISOString(),
      code,
      rev: getRevision(),
      ...sanitizedExtra
    };
    const redactionSafeSummary = `${code}${sanitizedExtra.command ? `:${sanitizedExtra.command}` : ''}`;
    // Dokumenttexte oder rohe Fehlermeldungen nie in den unredigierten Flugschreiber übernehmen,
    // um Finding #2 (kein Text-Leak in redacted Diagnostics) verlässlich einzuhalten.
    entry._fullSummary = String(summary || redactionSafeSummary);
    entry.summary = redactionSafeSummary;
    diagnosticAnomalies.push(entry);
    if (diagnosticAnomalies.length > 50) diagnosticAnomalies.shift();
    pushDiagnosticEvent('anomaly', { code, ...sanitizedExtra });
    try {
      postMessage({
        kind: 'diagnosticAnomaly',
        session: getSession(),
        revision: getRevision(),
        code,
        summary: redactionSafeSummary
      });
    } catch (_) {}
  }

  function compareSave(html) {
    lastRenderedHTML = html;
    const candidate = document.createElement('template');
    candidate.innerHTML = html;
    const live = saveAppearance(getRoot(), getLastInputType());
    const saved = saveAppearance(candidate.content);
    const comparison = diffAppearance(live, saved, { includeContent: true });
    lastAppearanceCheck = {
      revision: getRevision(),
      at: new Date().toISOString(),
      source: 'save',
      ...comparison
    };
    return comparison.outcome;
  }

  function inspect(html) {
    lastRenderedHTML = html;
    const candidate = document.createElement('template');
    candidate.innerHTML = html;
    const live = saveAppearance(getRoot(), getLastInputType());
    const saved = saveAppearance(candidate.content);
    const comparison = diffAppearance(live, saved, { includeContent: false });
    lastAppearanceCheck = {
      revision: getRevision(),
      at: new Date().toISOString(),
      source: 'live',
      ...diffAppearance(live, saved, { includeContent: true })
    };
    return {
      outcome: comparison.outcome,
      diff: comparison.diff,
      revision: getRevision(),
      anomalies: diagnosticAnomalies.slice(-10).map(a => formatAnomaly(a, false))
    };
  }

  function formatAnomaly(a, includeContent) {
    const base = {
      t: a.t,
      code: a.code,
      rev: a.rev,
      summary: includeContent ? (a._fullSummary || a.summary) : a.summary,
      ...sanitizeFields(a, ALLOWED_ANOMALY_FIELDS)
    };
    return base;
  }

  function formatEvent(e, includeContent) {
    const out = { t: e.t, kind: e.kind, rev: e.rev };
    for (const [k, v] of Object.entries(e)) {
      if (k === 't' || k === 'kind' || k === 'rev') continue;
      if (includeContent || ALLOWED_EVENT_FIELDS.has(k)) {
        if (!includeContent && e.kind === 'keydown' && k === 'key') {
          out[k] = sanitizeDiagnosticKey(v, !!(e.meta || e.ctrl));
        } else {
          out[k] = v;
        }
      }
    }
    return out;
  }

  function report(includeContent = false) {
    const markdown = serializeMarkdown();
    const out = {
      session: getSession(),
      revision: getRevision(),
      fenced: isFenced(),
      composing: isComposing(),
      lastInputType: getLastInputType(),
      visibleTextLength: visibleTextLength(),
      markdownLength: markdown.length,
      lastAppearanceCheck: lastAppearanceCheck
        ? {
            revision: lastAppearanceCheck.revision,
            at: lastAppearanceCheck.at,
            source: lastAppearanceCheck.source,
            outcome: lastAppearanceCheck.outcome,
            diff: redactDiff(lastAppearanceCheck.diff, includeContent)
          }
        : null,
      anomalies: diagnosticAnomalies.map(a => formatAnomaly(a, includeContent)),
      events: diagnosticEvents.map(e => formatEvent(e, includeContent)),
      domSkeleton: domSkeleton(getRoot())
    };
    if (includeContent) {
      out.liveHTML = getRoot()?.innerHTML || '';
      out.serializedMarkdown = markdown;
      out.lastRenderedHTML = lastRenderedHTML;
    }
    return out;
  }

  return {
    visibleTextLength,
    selectionSummary,
    domSkeleton,
    pushDiagnosticEvent,
    recordAnomaly,
    compareSave,
    inspect,
    report,
  };
}
