import { GapCursor } from 'prosemirror-gapcursor';
import { closeHistory } from 'prosemirror-history';
import { DOMParser, Fragment } from 'prosemirror-model';
import { Selection, TextSelection } from 'prosemirror-state';
import { sanitizePasteHTML } from './parser.js';

const maxRows = 1000;
const maxColumns = 100;
const maxCells = 10000;
const maxBytes = 1048576;
const encoder = new TextEncoder();
const alignments = ['none', 'left', 'center', 'right'];
const hostCommands = new Map([
  ['rowBefore', 'insertRowBefore'], ['rowAfter', 'insertRowAfter'],
  ['rowUp', 'moveRowUp'], ['rowDown', 'moveRowDown'],
  ['columnBefore', 'insertColBefore'], ['columnAfter', 'insertColAfter'],
  ['deleteColumn', 'deleteCol'], ['columnLeft', 'moveColLeft'], ['columnRight', 'moveColRight']
]);
const controls = new Map([
  ['insertRowBefore', 'canAddRowBefore'], ['insertRowAfter', 'canAddRowAfter'],
  ['deleteRow', 'canDeleteRow'], ['moveRowUp', 'canMoveRowUp'], ['moveRowDown', 'canMoveRowDown'],
  ['insertColBefore', 'canAddColBefore'], ['insertColAfter', 'canAddColAfter'],
  ['deleteCol', 'canDeleteCol'], ['moveColLeft', 'canMoveColLeft'], ['moveColRight', 'canMoveColRight']
]);

const success = () => ({ ok: true, reason: '' });
const failure = reason => ({ ok: false, reason });
const fits = (rows, columns) => rows <= maxRows && columns <= maxColumns && rows * columns <= maxCells;
const fitsBytes = value => value.length <= maxBytes && encoder.encode(value).length <= maxBytes;

function parseTSV(text, row, column, rowCount, colCount) {
  if (!fitsBytes(text)) return null;
  const lines = text.replace(/\r\n?/g, '\n').split('\n', maxRows + 2);
  if (lines.length > 1 && lines.at(-1) === '') lines.pop();
  if (lines.length > maxRows) return null;
  const fields = lines.map(line => line.split('\t', maxColumns + 1));
  const height = Math.max(rowCount, row + fields.length);
  const width = Math.max(colCount, column + Math.max(...fields.map(line => line.length)));
  return fits(height, width) ? { fields, height, width } : null;
}

function singleLineHTML(html, document, parser, cellType, { allowLineBreak = false } = {}) {
  const template = document.createElement('template');
  template.innerHTML = sanitizePasteHTML(html, document);
  const fragment = template.content;
  const blocks = [...fragment.querySelectorAll('p,div')];
  const forbidden = allowLineBreak
    ? 'table,pre,ul,ol,li,blockquote,h1,h2,h3,h4,h5,h6,hr'
    : 'br,table,pre,ul,ol,li,blockquote,h1,h2,h3,h4,h5,h6,hr';
  if (fragment.querySelector(forbidden) ||
      blocks.filter(node => !node.querySelector('p,div')).length > 1) return null;

  // Leerraum zwischen Renderer-Blöcken gehört nicht zum kopierten Zellinhalt.
  for (const node of [...fragment.childNodes]) {
    if (node.nodeType === 3 && /[\r\n]/.test(node.data) && !node.data.trim()) node.remove();
  }
  for (const node of blocks) node.replaceWith(...node.childNodes);
  if (/[\r\n]/.test(fragment.textContent)) return null;

  for (const node of fragment.querySelectorAll('*')) {
    for (const { name } of [...node.attributes]) {
      if (!['href', 'src', 'title', 'alt', 'data-md-src'].includes(name)) node.removeAttribute(name);
    }
  }
  return parser.parse(fragment, { topNode: cellType.create(), preserveWhitespace: true }).content;
}

export function createTableEditor({
  view, schema, blocked = () => false, revision = () => 0, applyTransaction,
  report = () => {}, fail = () => {}
}) {
  const { table, table_row: rowType, table_header: headerType, table_cell: cellType, paragraph, hard_break: hardBreak } = schema.nodes;
  const parser = DOMParser.fromSchema(schema);
  const dom = view.dom;
  const document = dom?.ownerDocument;
  const tables = new WeakMap();
  let nextID = 0;
  let inspecting = null;
  let mouseSelection = false;
  let lastContext = null;

  function tableInfo(node) {
    let info = tables.get(node);
    if (info) return info;
    const rowCount = node.childCount;
    const colCount = node.firstChild.childCount;
    const merged = node.children.some(row => row.children.some(cell => cell.attrs.colspan > 1 || cell.attrs.rowspan > 1));
    const protectedTable = !node.attrs.gfm || merged || node.children.some(row =>
      row.childCount !== colCount || row.children.some(cell => cell.attrs.colspan !== 1 || cell.attrs.rowspan !== 1)) ||
      node.firstChild.children.some(cell => cell.type !== headerType);
    info = { id: ++nextID, rowCount, colCount, merged, protected: protectedTable };
    tables.set(node, info);
    return info;
  }

  function cellAt($pos) {
    const cell = $pos.parent;
    if (cell.type !== cellType && cell.type !== headerType) return null;
    const tableDepth = $pos.depth - 2;
    return {
      node: $pos.node(tableDepth), pos: $pos.before(tableDepth), cell,
      row: $pos.index(tableDepth), column: $pos.index(tableDepth + 1), start: $pos.start()
    };
  }

  function locate() {
    const { doc, selection } = view.state;
    const from = cellAt(selection.$from);
    const to = cellAt(selection.$to);
    const inspected = inspecting?.doc === doc && inspecting.selection === selection ? inspecting.cell : null;
    let current = inspected || from || to;
    if (!current && !selection.empty) {
      doc.nodesBetween(selection.from, selection.to, (node, pos) => {
        if (current) return false;
        if (node.type !== table) return undefined;
        current = { node, pos, row: 0, column: 0, cell: node.firstChild.firstChild };
        return false;
      });
    }
    if (!current) return null;
    const info = tableInfo(current.node);
    let tableDOM = typeof view.nodeDOM === 'function' ? view.nodeDOM(current.pos) : null;
    if ((!tableDOM || tableDOM.tagName !== 'TABLE') && typeof view.domAtPos === 'function') {
      try {
        const domPos = view.domAtPos(current.pos + 1);
        const domEl = domPos?.node?.nodeType === 1 ? domPos.node : domPos?.node?.parentElement;
        tableDOM = domEl?.closest?.('table') || tableDOM;
      } catch (_) {}
    }
    const domProtected = !!(
      tableDOM?.tagName === 'TABLE' &&
      (tableDOM.getAttribute('data-md-table') !== 'gfm' || tableDOM.querySelector('[colspan],[rowspan],table'))
    );
    const isProtected = info.protected || domProtected;
    const winSel = document?.getSelection?.();
    let domCrossCell = false;
    if (winSel && winSel.rangeCount && !winSel.isCollapsed && dom?.contains(winSel.anchorNode) && dom?.contains(winSel.focusNode)) {
      const aCell = (winSel.anchorNode?.nodeType === 1 ? winSel.anchorNode : winSel.anchorNode?.parentElement)?.closest?.('td,th');
      const fCell = (winSel.focusNode?.nodeType === 1 ? winSel.focusNode : winSel.focusNode?.parentElement)?.closest?.('td,th');
      if (aCell && fCell && aCell !== fCell) domCrossCell = true;
    }
    const sameCell = !domCrossCell && from && to && from.start === to.start;
    const reason = blocked() ? 'busy' : isProtected ? 'html' : sameCell ? '' : 'selection';
    return { ...current, ...info, protected: isProtected, from, to, reason,
      token: `${info.id}:${revision()}:${current.row}:${current.column}:${current.pos}` };
  }

  function context() {
    // Eine wechselnde Werkzeugleistenhöhe würde die Auswahl unter der Maus verschieben.
    if (mouseSelection) return lastContext;
    const found = locate();
    if (!found) return lastContext = null;
    const { row, column, rowCount, colCount, reason, token, cell, merged } = found;
    const enabled = !reason;
    const align = cell.attrs.align || 'none';
    return lastContext = {
      inTable: true, row, column, rows: rowCount, columns: colCount, rowCount, colCount,
      reason, token, align, alignment: align === 'none' ? 'default' : align,
      gfm: found.node.attrs.gfm, merged, protected: found.protected,
      ...Object.fromEntries([...controls].map(([command, key]) => [key, enabled && !edgeReason(found, command)])),
      canDeleteTable: enabled
    };
  }

  function syncToolbar() {
    if (!mouseSelection) report(context());
    return lastContext;
  }

  function setMouseSelection(active) {
    if (mouseSelection === active) return;
    if (active) context();
    mouseSelection = active;
    if (!active) syncToolbar();
  }

  function commit(tr) {
    const applied = applyTransaction ? applyTransaction(tr) : view.dispatch(tr);
    if (applied === false) return failure('stale');
    view.focus?.();
    syncToolbar();
    return success();
  }

  function cellSelection(doc, node, pos, row, column, select = false) {
    let start = pos + 3;
    for (let i = 0; i < row; i++) start += node.child(i).nodeSize;
    const targetRow = node.child(row);
    for (let i = 0; i < column; i++) start += targetRow.child(i).nodeSize;
    return TextSelection.create(doc, start, start + (select ? targetRow.child(column).content.size : 0));
  }

  function selectCell(found, row, column, select = true) {
    const tr = view.state.tr;
    const selection = cellSelection(tr.doc, found.node, found.pos, row, column, select);
    return commit(tr.setSelection(selection).scrollIntoView());
  }

  function emptyCell(row, align = null) {
    return (row === 0 ? headerType : cellType).create({ align });
  }

  function makeRow(index, width, alignment) {
    return rowType.create(null, Array.from({ length: width }, (_, column) => emptyCell(index, alignment(column))));
  }

  function insertTable(rows, cols) {
    if (blocked()) return failure('busy');
    if (locate()) return failure('format');
    if (!Number.isInteger(rows) || !Number.isInteger(cols) || rows < 1 || cols < 1 || !fits(rows, cols)) return failure('size');
    const node = table.create(null, Array.from({ length: rows }, (_, index) => makeRow(index, cols, () => null)));
    const tr = closeHistory(view.state.tr).replaceSelectionWith(node, false);
    let tablePos;
    tr.doc.descendants((child, pos) => {
      if (child !== node) return undefined;
      tablePos = pos;
      return false;
    });
    if (tablePos === undefined) return failure('format');
    const $after = tr.doc.resolve(tablePos + node.nodeSize);
    // Am Dokumentende bleibt wie im bisherigen Editor ein Absatz zum Weiterschreiben.
    if ($after.pos === tr.doc.content.size) tr.insert($after.pos, paragraph.create());
    return commit(tr.setSelection(cellSelection(tr.doc, node, tablePos, 0, 0)).scrollIntoView());
  }

  function pasteCell(found, payload, selectionOnly = false) {
    const html = payload.html ?? (payload.text === undefined ? payload.value : undefined);
    const value = html ?? payload.text ?? '';
    if (typeof value !== 'string') return failure('format');
    if (!fitsBytes(value)) return failure('size');
    const { selection, storedMarks } = view.state;
    const marks = selectionOnly ? storedMarks ?? selection.$from.marks() : undefined;
    const content = html !== undefined
      ? singleLineHTML(value, document, parser, found.cell.type, { allowLineBreak: Boolean(payload.allowLineBreak) })
      : !/[\r\n]/.test(value) && (value ? schema.text(value, marks) : []);
    if (!content) return failure('format');
    const tr = closeHistory(view.state.tr);
    if (selectionOnly) {
      const from = selection.from;
      tr.replaceWith(from, selection.to, content);
      tr.setSelection(TextSelection.create(tr.doc, from + Fragment.from(content).size));
    } else {
      tr.replaceWith(found.start, found.start + found.cell.content.size, content);
      tr.setSelection(TextSelection.create(tr.doc, found.start));
    }
    return commit(tr.scrollIntoView());
  }

  function copyTSV(found) {
    if (found.reason && found.reason !== 'selection') return failure(found.reason);
    const { from, to, pos, rowCount, colCount } = found;
    if (from?.pos !== pos || to?.pos !== pos) return failure('selection');
    const single = from.start === to.start;
    const top = single ? 0 : from.row;
    const bottom = single ? rowCount - 1 : to.row;
    const left = single ? 0 : Math.min(from.column, to.column);
    const right = single ? colCount - 1 : Math.max(from.column, to.column);
    if (!fits(bottom - top + 1, right - left + 1)) return failure('size');
    let bytes = 0;
    const lines = [];
    for (let row = top; row <= bottom; row++) {
      const fields = [];
      for (let column = left; column <= right; column++) {
        const cell = found.node.child(row).child(column);
        const text = cell.textBetween(0, cell.content.size, '', node => node.type === hardBreak ? ' ' : node.attrs.alt || '')
          .replace(/[\t\r\n]/g, ' ');
        if (text.length > maxBytes) return failure('size');
        bytes += encoder.encode(text).length + Number(row !== top || column !== left);
        if (bytes > maxBytes) return failure('size');
        fields.push(text);
      }
      lines.push(fields.join('\t'));
    }
    // Ein leerer letzter TSV-Datensatz braucht einen eigenen abschließenden Zeilenumbruch.
    const ending = lines.length > 1 && lines.at(-1) === '' ? '\n' : '';
    if (bytes + ending.length > maxBytes) return failure('size');
    return { ...success(), text: lines.join('\n') + ending };
  }

  function deleteTable(found) {
    const tr = closeHistory(view.state.tr);
    const $pos = tr.doc.resolve(found.pos);
    const end = found.pos + found.node.nodeSize;
    if ($pos.parent.canReplace($pos.index(), $pos.index() + 1)) tr.delete(found.pos, end);
    else tr.replaceWith(found.pos, end, paragraph.create());
    return commit(tr.setSelection(Selection.near(tr.doc.resolve(found.pos))).scrollIntoView());
  }

  function execute(command, payload = {}) {
    if (typeof payload === 'string') payload = { value: payload };
    payload ??= {};
    if (command === 'insertTable') return insertTable(payload.rows, payload.cols ?? payload.columns);
    const found = locate();
    if (!found) return failure('selection');
    if (payload.token != null && payload.token !== found.token) return failure('stale');
    if (command === 'copyTSV') return copyTSV(found);
    if (found.reason) return failure(found.reason);
    if (command === 'deleteTable') return deleteTable(found);
    if (command === 'pasteCell') return pasteCell(found, payload);

    let align = payload.align === undefined ? payload.value : payload.align;
    if (['alignDefault', 'alignLeft', 'alignCenter', 'alignRight'].includes(command)) {
      align = command.slice(5).toLowerCase();
      command = 'align';
    }
    if (command === 'align') {
      if (align === undefined || align === 'cycle') {
        const currentAlign = found.cell.attrs.align || 'none';
        align = alignments[(alignments.indexOf(currentAlign) + 1) % alignments.length];
      }
      if (align === 'default' || align === null) align = 'none';
      if (!alignments.includes(align)) return failure('command');
    }
    return editTable(found, hostCommands.get(command) || command, payload, align);
  }

  function editTable(found, command, payload, align, tabAppend = false) {
    const { node, pos, row, column, rowCount, colCount } = found;
    const reason = edgeReason(found, command);
    if (reason) return failure(reason);

    // Zell- und Zeilenknoten behalten beim Verschieben ihre Marken und Attribute.
    const rows = [...node.children];
    const alignment = index => rows[0].child(index).attrs.align;
    let targetRow = row;
    let targetColumn = column;
    switch (command) {
      case 'insertRowBefore':
      case 'insertRowAfter':
        targetRow = row + Number(command === 'insertRowAfter');
        rows.splice(targetRow, 0, makeRow(targetRow, colCount, alignment));
        if (tabAppend) targetColumn = 0;
        break;
      case 'deleteRow':
        rows.splice(row, 1);
        targetRow = Math.min(row, rows.length - 1);
        break;
      case 'moveRowUp':
      case 'moveRowDown':
        targetRow = row + (command === 'moveRowUp' ? -1 : 1);
        [rows[row], rows[targetRow]] = [rows[targetRow], rows[row]];
        break;
      case 'insertColBefore':
      case 'insertColAfter': {
        targetColumn = column + Number(command === 'insertColAfter');
        const align = alignment(column);
        changeColumns(rows, (cells, index) => cells.splice(targetColumn, 0, emptyCell(index, align)));
        break;
      }
      case 'deleteCol':
        changeColumns(rows, cells => cells.splice(column, 1));
        targetColumn = Math.min(column, colCount - 2);
        break;
      case 'moveColLeft':
      case 'moveColRight':
        targetColumn = column + (command === 'moveColLeft' ? -1 : 1);
        changeColumns(rows, cells => { [cells[column], cells[targetColumn]] = [cells[targetColumn], cells[column]]; });
        break;
      case 'align':
        changeColumns(rows, cells => {
          const cell = cells[column];
          cells[column] = cell.type.create({ ...cell.attrs, align: align === 'none' ? null : align }, cell.content, cell.marks);
        });
        break;
      case 'pasteTSV': {
        const text = payload.text ?? payload.value ?? '';
        if (typeof text !== 'string') return failure('format');
        const parsed = parseTSV(text, row, column, rowCount, colCount);
        if (!parsed) return failure('size');
        const { fields, height, width } = parsed;
        for (let index = 0; index < height; index++) {
          if (index >= rows.length) rows.push(makeRow(index, width, alignment));
          const values = fields[index - row];
          if (!values && rows[index].childCount === width) continue;
          const cells = [...rows[index].children];
          while (cells.length < width) cells.push(emptyCell(index));
          values?.forEach((value, offset) => {
            const cell = cells[column + offset];
            cells[column + offset] = cell.type.create(cell.attrs, value ? schema.text(value) : null, cell.marks);
          });
          rows[index] = rows[index].type.create(rows[index].attrs, cells, rows[index].marks);
        }
        targetRow = row + fields.length - 1;
        targetColumn = column + fields.at(-1).length - 1;
        break;
      }
      default:
        return failure('command');
    }
    const replacement = node.type.create(node.attrs, rows, node.marks);
    const tr = closeHistory(view.state.tr);
    if (!node.eq(replacement)) tr.replaceWith(pos, pos + node.nodeSize, replacement);
    return commit(tr.setSelection(cellSelection(tr.doc, replacement, pos, targetRow, targetColumn)).scrollIntoView());
  }

  function leaveTable(found, direction) {
    const tr = view.state.tr;
    const boundary = found.pos + (direction > 0 ? found.node.nodeSize : 0);
    const $boundary = tr.doc.resolve(boundary);
    const selection = GapCursor.valid($boundary) ? new GapCursor($boundary) : Selection.findFrom($boundary, direction, true);
    if (!selection || cellAt(selection.$from)?.pos === found.pos) return false;
    return commit(tr.setSelection(selection).scrollIntoView()).ok;
  }

  function navigate(backwards) {
    const found = locate();
    if (!found || found.reason) return false;
    const { row, column, rowCount, colCount } = found;
    const index = row * colCount + column + (backwards ? -1 : 1);
    if (index < 0) return leaveTable(found, -1);
    if (index >= rowCount * colCount) {
      const result = editTable(found, 'insertRowAfter', {}, undefined, true);
      if (!result.ok) fail(result.reason);
      return true;
    }
    return selectCell(found, Math.floor(index / colCount), index % colCount).ok;
  }

  function rejectOversizedTabAtDOM(event) {
    if (event.key !== 'Tab' || event.shiftKey || event.altKey || event.metaKey ||
        event.ctrlKey || event.isComposing || blocked()) return false;
    const anchor = document?.getSelection?.()?.anchorNode;
    const cell = (anchor?.nodeType === 1 ? anchor : anchor?.parentElement)?.closest?.('td,th');
    const row = cell?.closest('tr');
    const tableDOM = row?.closest('table');
    if (!tableDOM || !dom?.contains(tableDOM) || tableDOM.getAttribute('data-md-table') !== 'gfm' ||
        tableDOM.querySelector('[colspan],[rowspan],table')) return false;
    if (row.rowIndex !== tableDOM.rows.length - 1 || cell.cellIndex !== row.cells.length - 1 ||
        fits(tableDOM.rows.length + 1, row.cells.length)) return false;
    fail('size');
    return true;
  }

  function handleKeyDown(viewOrEvent, maybeEvent) {
    const event = maybeEvent ?? viewOrEvent;
    if (!['Shift', 'Alt', 'Control', 'Meta'].includes(event.key)) setMouseSelection(false);
    if (inspecting) {
      inspecting = null;
      syncToolbar();
    }
    if (event.isComposing || event.ctrlKey || event.metaKey) return false;
    if (event.key === 'Tab') {
      if (event.altKey) return false;
      return navigate(event.shiftKey);
    }
    if (event.key !== 'Enter' && event.key !== 'Escape') return false;
    const found = locate();
    if (!found || found.reason === 'busy') return false;
    if (event.key === 'Escape') return leaveTable(found, 1);
    const result = found.reason ? failure(found.reason) : commit(view.state.tr.replaceSelectionWith(hardBreak.create(), false).scrollIntoView());
    if (!result.ok) fail(result.reason);
    return true;
  }

  function handlePaste(viewOrEvent, maybeEvent) {
    const event = maybeEvent ?? viewOrEvent;
    const clipboard = event.clipboardData;
    const found = locate();
    if (!clipboard || !found) return false;
    const text = clipboard.getData('text/plain');
    const html = clipboard.getData('text/html');
    let result;
    if (found.reason) {
      result = failure(found.reason);
    } else if (text.includes('\t') || (/[\r\n]/.test(text) && (!html || /<table(?=[\s>])/i.test(html)))) {
      result = execute('pasteTSV', { text });
    } else {
      if (clipboard.getData('application/x-fastra-markdown') || clipboard.files?.length) return false;
      if (!text && !html) return false;
      if (!fitsBytes(text)) result = failure('size');
      else {
        const selection = view.state.selection;
        const fullCell = !selection.empty && selection.from === found.start && selection.to === found.start + found.cell.content.size;
        result = pasteCell(found, html ? { html, allowLineBreak: true } : { text }, !fullCell);
      }
    }
    event.preventDefault?.();
    if (!result.ok) fail(result.reason);
    return true;
  }

  function pasteText(text) {
    const found = locate();
    if (!found) return null;
    const result = found.reason ? failure(found.reason)
      : /[\t\r\n]/.test(text) ? execute('pasteTSV', { text })
        : pasteCell(found, { text }, true);
    if (!result.ok) fail(result.reason);
    return result.ok;
  }

  function handleCopy(viewOrEvent, maybeEvent) {
    const event = maybeEvent ?? viewOrEvent;
    const found = locate();
    if (!event.clipboardData || !found?.from || !found.to || found.from.start === found.to.start || found.protected) return false;
    const result = copyTSV(found);
    if (!result.ok && result.reason !== 'size') return false;
    event.preventDefault();
    if (result.ok) event.clipboardData.setData('text/plain', result.text);
    else fail(result.reason);
    return true;
  }

  function handleClick(viewOrEvent, position, maybeEvent) {
    const event = maybeEvent ?? viewOrEvent;
    const { doc, selection } = view.state;
    if (typeof position !== 'number') {
      const cell = event.target?.closest?.('td,th');
      if (cell && dom?.contains(cell)) position = view.posAtDOM(cell, 0);
    }
    const cell = typeof position === 'number' && position >= 0 && position <= doc.content.size ? cellAt(doc.resolve(position)) : null;
    inspecting = cell && tableInfo(cell.node).protected ? { doc, selection, cell } : null;
    syncToolbar();
    return false;
  }

  const startMouseSelection = event => { if (event.button === 0) setMouseSelection(true); };
  const finishMouseSelection = () => setMouseSelection(false);
  dom?.addEventListener('mousedown', startMouseSelection, true);
  document?.addEventListener('mouseup', finishMouseSelection, true);
  document?.defaultView?.addEventListener('blur', finishMouseSelection);

  return {
    context, execute, insertTable, handleKeyDown, rejectOversizedTabAtDOM,
    handlePaste, handleCopy, handleClick, navigate, pasteText, syncToolbar,
    command: (name, value, token) => execute(name, { value, token }),
    get selectingWithMouse() { return mouseSelection; },
    set selectingWithMouse(active) { setMouseSelection(Boolean(active)); },
    destroy() {
      dom?.removeEventListener('mousedown', startMouseSelection, true);
      document?.removeEventListener('mouseup', finishMouseSelection, true);
      document?.defaultView?.removeEventListener('blur', finishMouseSelection);
      inspecting = null;
      mouseSelection = false;
      lastContext = null;
    }
  };
}

function changeColumns(rows, edit) {
  rows.forEach((row, index) => {
    const cells = [...row.children];
    edit(cells, index);
    rows[index] = row.type.create(row.attrs, cells, row.marks);
  });
}

function edgeReason({ row, column, rowCount, colCount }, command) {
  if (['insertRowBefore', 'insertRowAfter'].includes(command) && !fits(rowCount + 1, colCount) ||
      ['insertColBefore', 'insertColAfter'].includes(command) && !fits(rowCount, colCount + 1)) return 'size';
  switch (command) {
    case 'insertRowBefore': case 'deleteRow': return row === 0 ? 'edge' : '';
    case 'moveRowUp': return row <= 1 ? 'edge' : '';
    case 'moveRowDown': return row === 0 || row === rowCount - 1 ? 'edge' : '';
    case 'deleteCol': return colCount === 1 ? 'edge' : '';
    case 'moveColLeft': return column === 0 ? 'edge' : '';
    case 'moveColRight': return column === colCount - 1 ? 'edge' : '';
    default: return '';
  }
}
