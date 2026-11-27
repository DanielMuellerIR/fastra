import { Fragment, Slice } from 'prosemirror-model';
import { TextSelection, NodeSelection, Selection } from 'prosemirror-state';
import { findWrapping } from 'prosemirror-transform';
import { wrapIn, lift, chainCommands, newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock, toggleMark, baseKeymap, selectNodeBackward, selectNodeForward } from 'prosemirror-commands';
import { wrapInList, splitListItem, liftListItem, sinkListItem } from 'prosemirror-schema-list';
import { undo as pmUndo, redo as pmRedo, undoDepth, redoDepth, closeHistory } from 'prosemirror-history';
import { inputRules, InputRule } from 'prosemirror-inputrules';
import { keymap } from 'prosemirror-keymap';
import { schema as defaultSchema, INLINE_HTML_MARK_NAMES } from './schema.js';
import { parseHTMLToNodes, sanitizePasteHTML } from './parser.js';

function isMarkActive(state, markType) {
  const { from, $from, to, empty } = state.selection;
  if (empty) {
    return !!markType.isInSet(state.storedMarks || $from.marks());
  }
  return state.doc.rangeHasMark(from, to, markType);
}

function insideCellOrProtected(state, schema) {
  const { $from, $to, from, to } = state.selection;
  for (let d = $from.depth; d > 0; d--) {
    const n = $from.node(d);
    if (n.type === schema.nodes.math_block || n.type === schema.nodes.opaque_block) {
      return { protectedAtom: true, containsProtected: true, inTable: false, cell: null };
    }
  }
  if (state.selection instanceof NodeSelection) {
    const t = state.selection.node.type;
    if (t === schema.nodes.math_inline || t === schema.nodes.opaque_inline || t === schema.nodes.math_block || t === schema.nodes.opaque_block) {
      return { protectedAtom: true, containsProtected: true, inTable: false, cell: null };
    }
  }
  let containsProtected = false;
  let containsTable = false;
  if (from < to) {
    state.doc.nodesBetween(from, to, node => {
      if (node.type === schema.nodes.table || node.type === schema.nodes.table_cell || node.type === schema.nodes.table_header) {
        containsTable = true;
      }
      if (
        node.type === schema.nodes.math_inline ||
        node.type === schema.nodes.opaque_inline ||
        node.type === schema.nodes.math_block ||
        node.type === schema.nodes.opaque_block
      ) {
        containsProtected = true;
        return false;
      }
      return true;
    });
  }

  for (const $pos of [$from, $to]) {
    for (let d = $pos.depth; d > 0; d--) {
      const n = $pos.node(d);
      if (n.type === schema.nodes.table_cell || n.type === schema.nodes.table_header) {
        return { protectedAtom: false, containsProtected, inTable: true, cell: { node: n, pos: $pos.before(d) } };
      }
    }
  }
  return { protectedAtom: false, containsProtected, inTable: containsTable, cell: null };
}

function unwrapBlockquote(state, dispatch, schema) {
  const { $from, $to } = state.selection;
  const range = $from.blockRange($to, node => node.type === schema.nodes.blockquote);
  if (!range) return false;
  if (!dispatch) return true;
  return lift(state, dispatch);
}

function findAncestorOfType(pos, type) {
  for (let d = pos.depth; d >= 0; d--) {
    if (pos.node(d).type === type) return { depth: d, node: pos.node(d), pos: pos.before(d) };
  }
  return null;
}

/**
 * Sucht den nächstgelegenen umschließenden Listenknoten (egal ob `bullet_list`
 * oder `ordered_list`), damit verschachtelte geordnete Unterlisten nie die
 * äußere Aufzählungsliste überschreiben (Sol #12).
 */
function findNearestListAncestor(pos, schema) {
  for (let d = pos.depth; d > 0; d--) {
    const n = pos.node(d);
    if (n.type === schema.nodes.bullet_list || n.type === schema.nodes.ordered_list) {
      return { depth: d, node: n, pos: pos.before(d) };
    }
  }
  return null;
}

function inlineMarkTypesToStrip(schema) {
  const names = ['strong', 'em', 'code', 'highlight', 'strike', 'link', ...INLINE_HTML_MARK_NAMES];
  return names.map(name => schema.marks[name]).filter(Boolean);
}

function splitLeafByHardBreaksIfPartial(tr, schema, node, pos, selFrom, selTo, level) {
  if (!node.isTextblock) return false;
  const lines = [];
  let currentNodes = [];
  let lineStartOffset = 0;
  let cursorOffset = 0;

  node.content.forEach(child => {
    if (child.type === schema.nodes.hard_break) {
      lines.push({ nodes: currentNodes, start: lineStartOffset, end: cursorOffset });
      currentNodes = [];
      cursorOffset += child.nodeSize;
      lineStartOffset = cursorOffset;
    } else {
      currentNodes.push(child);
      cursorOffset += child.nodeSize;
    }
  });
  lines.push({ nodes: currentNodes, start: lineStartOffset, end: cursorOffset });

  if (lines.length <= 1) return false;

  const contentStart = pos + 1;
  const lineMatches = line => {
    const absStart = contentStart + line.start;
    const absEnd = contentStart + line.end;
    if (selFrom === selTo) return selFrom >= absStart && selFrom <= absEnd;
    return Math.max(absStart, selFrom) <= Math.min(absEnd, selTo) && !(selFrom === absEnd && selTo > absEnd) && !(selTo === absStart && selFrom < absStart);
  };

  const touched = lines.map(lineMatches);
  if (touched.every(Boolean) || !touched.some(Boolean)) return false;

  const replacementBlocks = [];
  let firstTouched = true;
  lines.forEach((line, index) => {
    const content = Fragment.fromArray(line.nodes);
    if (touched[index]) {
      replacementBlocks.push(schema.nodes.heading.create({
        level,
        outlineIgnore: false,
        mdContext: firstTouched ? (node.attrs.mdContext || '') : '',
        mdBlockId: firstTouched ? (node.attrs.mdBlockId || null) : null,
        mdBlockSub: node.attrs.mdBlockSub || 0,
        mdBlockTotal: node.attrs.mdBlockTotal || 1
      }, content));
      firstTouched = false;
    } else if (content.size > 0 || replacementBlocks.length > 0) {
      replacementBlocks.push(schema.nodes.paragraph.create({ mdEmpty: false }, content));
    }
  });

  if (!replacementBlocks.length) return false;
  tr.replaceWith(pos, pos + node.nodeSize, replacementBlocks);
  return true;
}

function liftSelectedListItemsWithOrder(state, schema) {
  const { $from, $to } = state.selection;
  const listAncestor = findNearestListAncestor($from, schema);
  if (!listAncestor || $to.depth < listAncestor.depth ||
      $to.before(listAncestor.depth) !== listAncestor.pos) return null;

  const { node: listNode, pos: listPos } = listAncestor;
  const isOrdered = listNode.type === schema.nodes.ordered_list;
  const baseOrder = isOrdered ? Math.max(0, Number(listNode.attrs.order ?? 1)) : 1;

  // Direkt betroffene Listenpunkte auf Ebene von `listNode` bestimmen.
  const firstIdx = $from.index(listAncestor.depth);
  const lastIdx = $to.index(listAncestor.depth);

  // Wenn tiefer verschachtelte Liste angehoben wird oder der einfache
  // Standardschritt reicht und kein nummerierter Nachlauf geändert werden muss:
  if (listNode.childCount === 1 || lastIdx === listNode.childCount - 1) {
    let liftTr = null;
    if (liftListItem(schema.nodes.list_item)(state, t => { liftTr = t; })) {
      return liftTr;
    }
    return null;
  }

  // Isolierter Teil-Lift mitten aus einer Liste heraus: Vorlauf, gehobene
  // Blöcke und Nachlauf (mit korrigiertem `order` bei `ordered_list`, Sol #12).
  const beforeItems = [];
  const liftedBlocks = [];
  const afterItems = [];

  for (let i = 0; i < listNode.childCount; i++) {
    const item = listNode.child(i);
    if (i < firstIdx) {
      beforeItems.push(item);
    } else if (i <= lastIdx) {
      item.content.forEach(block => {
        if (block.attrs && 'mdBlockId' in block.attrs) {
          liftedBlocks.push(block.type.create({ ...block.attrs, mdContext: '', mdBlockId: null }, block.content, block.marks));
        } else {
          liftedBlocks.push(block);
        }
      });
    } else {
      afterItems.push(item);
    }
  }

  const replacements = [];
  if (beforeItems.length) {
    replacements.push(listNode.type.create({ ...listNode.attrs }, beforeItems));
  }
  replacements.push(...liftedBlocks);
  if (afterItems.length) {
    const afterAttrs = isOrdered
      ? { ...listNode.attrs, mdContext: '', mdBlockId: null, order: baseOrder + lastIdx + 1 }
      : { ...listNode.attrs, mdContext: '', mdBlockId: null };
    replacements.push(listNode.type.create(afterAttrs, afterItems));
  }

  const tr = state.tr.replaceWith(listPos, listPos + listNode.nodeSize, replacements);
  let caretPos = listPos;
  if (beforeItems.length) caretPos += replacements[0].nodeSize;
  tr.setSelection(TextSelection.near(tr.doc.resolve(caretPos + 1)));
  return tr;
}

function convertCodeLineBreaks(tr, node, pos, schema) {
  if (node.type !== schema.nodes.code_block) return;
  const lines = node.textContent.split('\n');
  if (lines.length === 1) return;
  const content = [];
  lines.forEach((line, index) => {
    if (index) content.push(schema.nodes.hard_break.create());
    if (line) content.push(schema.text(line));
  });
  const selection = tr.selection.toJSON();
  tr.replaceWith(pos + 1, pos + node.nodeSize - 1, content);
  // Ein LF und ein Umbruchknoten belegen jeweils dieselbe Modellposition.
  tr.setSelection(Selection.fromJSON(tr.doc, selection));
}

function applyHeadingOrParagraph(state, dispatch, schema, { level = null }) {
  const ctx = insideCellOrProtected(state, schema);
  if (level === null && ctx.inTable && ctx.cell) {
    const from = ctx.cell.pos + 1;
    const to = ctx.cell.pos + ctx.cell.node.nodeSize - 1;
    const marksToRemove = inlineMarkTypesToStrip(schema);
    let anyMark = false;
    state.doc.nodesBetween(from, to, node => {
      if (node.marks?.some(m => marksToRemove.includes(m.type))) anyMark = true;
    });
    if (!anyMark) return { handled: true, changed: false, reason: 'idempotent' };
    if (dispatch) {
      const tr = state.tr;
      for (const m of marksToRemove) tr.removeMark(from, to, m);
      dispatch(tr.scrollIntoView());
    }
    return { handled: true, changed: anyMark };
  }

  const steps = [];
  let workState = state;
  if (findAncestorOfType(workState.selection.$from, schema.nodes.list_item)) {
    let safety = 0;
    while (findAncestorOfType(workState.selection.$from, schema.nodes.list_item) && safety < 16) {
      safety++;
      const liftTr = liftSelectedListItemsWithOrder(workState, schema);
      if (!liftTr) break;
      steps.push(liftTr);
      workState = workState.apply(liftTr);
    }
  }
  if (level === null) {
    let safety = 0;
    while (findAncestorOfType(workState.selection.$from, schema.nodes.blockquote) && safety < 16) {
      safety++;
      let bqTr = null;
      if (!lift(workState, t => { bqTr = t; })) break;
      steps.push(bqTr);
      workState = workState.apply(bqTr);
    }
  }

  const { $from, $to, from, to } = workState.selection;
  const range = $from.blockRange($to);
  if (!range) {
    if (!steps.length) return { handled: false, changed: false };
    if (dispatch) dispatchMerged(state, steps, dispatch);
    return { handled: true, changed: true };
  }

  const targets = [];
  workState.doc.nodesBetween(range.start, range.end, (node, pos) => {
    if (
      node.type === schema.nodes.paragraph ||
      node.type === schema.nodes.blank_line ||
      node.type === schema.nodes.heading ||
      node.type === schema.nodes.code_block
    ) {
      targets.push({ node, pos });
      return false;
    }
    if (node.type === schema.nodes.table || node.type === schema.nodes.math_block || node.type === schema.nodes.opaque_block) {
      return false;
    }
    return true;
  });

  if (!targets.length) {
    if (!steps.length) return { handled: false, changed: false };
    if (dispatch) dispatchMerged(state, steps, dispatch);
    return { handled: true, changed: true };
  }

  const editTr = workState.tr;
  let blockChanged = false;
  if (level != null) {
    for (let i = targets.length - 1; i >= 0; i--) {
      const { node, pos } = targets[i];
      if (splitLeafByHardBreaksIfPartial(editTr, schema, node, pos, from, to, level)) {
        blockChanged = true;
        continue;
      }
      if (node.type === schema.nodes.heading && node.attrs.level === level) {
        continue;
      }
      editTr.setNodeMarkup(pos, schema.nodes.heading, {
        level,
        outlineIgnore: false,
        mdContext: node.attrs.mdContext || '',
        mdBlockId: node.attrs.mdBlockId || null,
        mdBlockSub: node.attrs.mdBlockSub || 0,
        mdBlockTotal: node.attrs.mdBlockTotal || 1
      }, node.marks);
      convertCodeLineBreaks(editTr, node, pos, schema);
      blockChanged = true;
    }
  } else {
    const marksToRemove = inlineMarkTypesToStrip(schema);
    for (let i = targets.length - 1; i >= 0; i--) {
      const { node, pos } = targets[i];
      if (node.type !== schema.nodes.paragraph) {
        editTr.setNodeMarkup(pos, schema.nodes.paragraph, {
          mdEmpty: false,
          mdContext: node.attrs.mdContext || '',
          mdBlockId: node.attrs.mdBlockId || null,
          mdBlockSub: node.attrs.mdBlockSub || 0,
          mdBlockTotal: node.attrs.mdBlockTotal || 1
        }, node.marks);
        convertCodeLineBreaks(editTr, node, pos, schema);
        blockChanged = true;
      }
      const cFrom = pos + 1;
      const cTo = pos + node.nodeSize - 1;
      let hasMark = false;
      workState.doc.nodesBetween(cFrom, cTo, child => {
        if (child.marks?.some(m => marksToRemove.includes(m.type))) hasMark = true;
      });
      if (hasMark) {
        for (const m of marksToRemove) editTr.removeMark(cFrom, cTo, m);
        blockChanged = true;
      }
    }
  }

  if (blockChanged) steps.push(editTr);
  if (!steps.length) {
    return { handled: true, changed: false, reason: 'idempotent' };
  }
  if (dispatch) dispatchMerged(state, steps, dispatch);
  return { handled: true, changed: true };
}

function dispatchMerged(baseState, transactions, dispatch) {
  const combined = baseState.tr;
  for (const t of transactions) {
    for (const s of t.steps) combined.step(s);
  }
  const last = transactions.at(-1);
  if (last?.selectionSet) {
    combined.setSelection(Selection.fromJSON(combined.doc, last.selection.toJSON()));
  }
  dispatch(combined.scrollIntoView());
}

/**
 * Listen umschalten auf den nächstgelegenen Listenkontext mit Isolation
 * ausgewählter Teilbereiche, statt geschachtelte Listen zu verwechseln (Sol #12).
 */
function toggleListMode(state, dispatch, schema, mode /* 'bullet' | 'ordered' | 'task' */) {
  const { $from, $to, from, to } = state.selection;
  const fromList = findNearestListAncestor($from, schema);

  // Bereich über mehrere Top-Level-Blöcke / getrennte Listen (z. B. Aufgabe über Zwischenabsatz hinweg):
  const outerList = (() => {
    for (let d = 1; d <= $from.depth; d++) {
      const n = $from.node(d);
      if (n.type === schema.nodes.bullet_list || n.type === schema.nodes.ordered_list) {
        return { node: n, pos: $from.before(d) };
      }
    }
    return null;
  })();
  const spansMultipleLists = from < to && (
    !outerList ||
    from < outerList.pos ||
    to > outerList.pos + outerList.node.nodeSize
  );
  if (spansMultipleLists && mode === 'task') {
    const itemTargets = [];
    const listContainersToConvert = [];
    state.doc.nodesBetween(from, to, (node, pos) => {
      if (node.type === schema.nodes.ordered_list) {
        listContainersToConvert.push({ node, pos });
      }
      if (node.type === schema.nodes.list_item) {
        itemTargets.push({ node, pos });
      }
      return true;
    });
    if (itemTargets.length > 0) {
      const allAlreadyTask = itemTargets.every(it => it.node.attrs.task !== null) && !listContainersToConvert.length;
      if (!allAlreadyTask) {
        if (!dispatch) return true;
        const tr = state.tr;
        for (const { node, pos } of listContainersToConvert) {
          tr.setNodeMarkup(pos, schema.nodes.bullet_list, {
            mdContext: node.attrs.mdContext || '',
            mdBlockId: node.attrs.mdBlockId || null,
            mdBlockSub: node.attrs.mdBlockSub || 0,
            mdBlockTotal: node.attrs.mdBlockTotal || 1,
            tight: node.attrs.tight !== false
          });
        }
        for (const { node, pos } of itemTargets) {
          if (node.attrs.task === null) {
            tr.setNodeMarkup(pos, null, { ...node.attrs, task: false });
          }
        }
        dispatch(tr.scrollIntoView());
        return true;
      }
    }
  }

  if (fromList) {
    const parentList = fromList.node;
    const isOrdered = parentList.type === schema.nodes.ordered_list;
    const range = $from.blockRange($to);
    const touchedItems = [];
    const untouchedBefore = [];
    const untouchedAfter = [];
    let offset = fromList.pos + 1;
    let firstTouchedIdx = -1;
    let lastTouchedIdx = -1;

    for (let i = 0; i < parentList.childCount; i++) {
      const child = parentList.child(i);
      const childEnd = offset + child.nodeSize;
      const hits = !range || (childEnd > range.start && offset < range.end);
      if (hits) {
        if (firstTouchedIdx < 0) firstTouchedIdx = i;
        lastTouchedIdx = i;
        touchedItems.push({ child, pos: offset, index: i });
      } else if (firstTouchedIdx < 0) {
        untouchedBefore.push(child);
      } else {
        untouchedAfter.push(child);
      }
      offset = childEnd;
    }

    const matchesSame =
      touchedItems.length > 0 &&
      ((mode === 'ordered' && isOrdered) ||
        (mode === 'bullet' && !isOrdered && touchedItems.every(it => it.child.attrs.task === null)) ||
        (mode === 'task' && !isOrdered && touchedItems.every(it => it.child.attrs.task !== null)));

    if (matchesSame) {
      if (!dispatch) return true;
      const tr = liftSelectedListItemsWithOrder(state, schema);
      if (!tr) return false;
      dispatch(tr.scrollIntoView());
      return true;
    }

    if (!dispatch) return true;
    const targetListType = mode === 'ordered' ? schema.nodes.ordered_list : schema.nodes.bullet_list;
    const partialSplit = (untouchedBefore.length > 0 || untouchedAfter.length > 0) && parentList.type !== targetListType;

    if (partialSplit) {
      const convertedItems = touchedItems.map(({ child }) =>
        child.type.create({ ...child.attrs, task: mode === 'task' ? (child.attrs.task ?? false) : null }, child.content, child.marks)
      );
      const replacements = [];
      if (untouchedBefore.length) {
        replacements.push(parentList.type.create({ ...parentList.attrs }, untouchedBefore));
      }
      const midAttrs = mode === 'ordered'
        ? { mdContext: '', mdBlockId: null, order: 1, tight: parentList.attrs.tight !== false }
        : { mdContext: '', mdBlockId: null, tight: parentList.attrs.tight !== false };
      replacements.push(targetListType.create(midAttrs, convertedItems));
      if (untouchedAfter.length) {
        const afterAttrs = isOrdered
          ? { ...parentList.attrs, mdContext: '', mdBlockId: null, order: (parentList.attrs.order ?? 1) + lastTouchedIdx + 1 }
          : { ...parentList.attrs, mdContext: '', mdBlockId: null };
        replacements.push(parentList.type.create(afterAttrs, untouchedAfter));
      }
      const tr = state.tr.replaceWith(fromList.pos, fromList.pos + parentList.nodeSize, replacements);
      dispatch(tr.scrollIntoView());
      return true;
    }

    const tr = state.tr;
    const listAttrs = mode === 'ordered'
      ? {
          mdContext: parentList.attrs.mdContext || '',
          mdBlockId: parentList.attrs.mdBlockId || null,
          mdBlockSub: parentList.attrs.mdBlockSub || 0,
          mdBlockTotal: parentList.attrs.mdBlockTotal || 1,
          order: parentList.attrs.order ?? 1,
          tight: parentList.attrs.tight !== false
        }
      : {
          mdContext: parentList.attrs.mdContext || '',
          mdBlockId: parentList.attrs.mdBlockId || null,
          mdBlockSub: parentList.attrs.mdBlockSub || 0,
          mdBlockTotal: parentList.attrs.mdBlockTotal || 1,
          tight: parentList.attrs.tight !== false
        };

    if (parentList.type !== targetListType) {
      tr.setNodeMarkup(fromList.pos, targetListType, listAttrs);
    }
    for (const { child, pos } of touchedItems) {
      const nextTask = mode === 'task' ? (child.attrs.task ?? false) : null;
      if (child.attrs.task !== nextTask) {
        tr.setNodeMarkup(pos, null, { ...child.attrs, task: nextTask });
      }
    }
    dispatch(tr.scrollIntoView());
    return true;
  }

  const listType = mode === 'ordered' ? schema.nodes.ordered_list : schema.nodes.bullet_list;
  const range = $from.blockRange($to);
  if (!range) return false;

  const prepTr = state.tr;
  let convertedBlank = false;
  state.doc.nodesBetween(range.start, range.end, (node, pos) => {
    if (node.type === schema.nodes.blank_line) {
      prepTr.setNodeMarkup(pos, schema.nodes.paragraph, {
        mdContext: node.attrs.mdContext || '',
        mdBlockId: node.attrs.mdBlockId || null,
        mdBlockSub: node.attrs.mdBlockSub || 0,
        mdBlockTotal: node.attrs.mdBlockTotal || 1,
        mdEmpty: false
      });
      convertedBlank = true;
      return false;
    }
    return true;
  });

  if (convertedBlank) {
    const intermediateState = state.apply(prepTr);
    return wrapInList(listType, { tight: true })(intermediateState, tr2 => {
      if (!dispatch) return;
      if (mode === 'task') {
        const markFrom = Math.min(tr2.selection.from, tr2.doc.content.size);
        const markTo = Math.min(tr2.selection.to, tr2.doc.content.size);
        tr2.doc.nodesBetween(markFrom, markTo, (node, pos) => {
          if (node.type === schema.nodes.list_item && node.attrs.task === null) {
            tr2.setNodeMarkup(pos, null, { ...node.attrs, task: false });
          }
          return true;
        });
      }
      dispatchMerged(state, [prepTr, tr2], dispatch);
    });
  }

  return wrapInList(listType, { tight: true })(state, tr => {
    if (!dispatch) return;
    if (mode === 'task') {
      const markFrom = Math.min(tr.selection.from, tr.doc.content.size);
      const markTo = Math.min(tr.selection.to, tr.doc.content.size);
      tr.doc.nodesBetween(markFrom, markTo, (node, pos) => {
        if (node.type === schema.nodes.list_item && node.attrs.task === null) {
          tr.setNodeMarkup(pos, null, { ...node.attrs, task: false });
        }
        return true;
      });
    }
    dispatch(tr);
  });
}

/**
 * Harter Zeilenumbruch (`hard_break`):
 * - In `blank_line`: erzeugt eine weitere sichtbare Leerzeile.
 * - In `heading`: verhindert doppeltes `<br><br>` (Sol #15).
 * - In `paragraph` (außerhalb von Listen/Tabellen): spaltet beim wiederholten
 *   harten Umbruch sauber in Absatz + `blank_line` auf, auch nach Selektion.
 */
function insertHardBreakCommand(state, dispatch, schema) {
  let workState = state;
  const prepTr = workState.tr;
  if (!workState.selection.empty) {
    prepTr.deleteSelection();
    workState = workState.apply(prepTr);
  }
  const { $from } = workState.selection;
  if ($from.parent.type === schema.nodes.code_block) {
    if (dispatch) {
      const tr = prepTr.steps.length ? prepTr : state.tr;
      dispatch(tr.insertText('\n').scrollIntoView());
    }
    return true;
  }
  const ctx = insideCellOrProtected(workState, schema);
  if (ctx.protectedAtom) return false;

  if (!ctx.inTable && $from.parent.type === schema.nodes.heading) {
    // Im ATX-Heading nie doppelte <br><br> erzeugen (Sol #15).
    if ($from.nodeBefore?.type === schema.nodes.hard_break || $from.nodeAfter?.type === schema.nodes.hard_break) {
      if (!dispatch) return true;
      const tr = prepTr.steps.length ? prepTr : state.tr;
      dispatch(tr.split($from.pos, 1, [{ type: schema.nodes.paragraph, attrs: { mdEmpty: false } }]).scrollIntoView());
      return true;
    }
  }

  if (!ctx.inTable && $from.parent.type === schema.nodes.blank_line) {
    if (!dispatch) return true;
    const pos = $from.pos;
    const splitTr = workState.tr.split(pos, 1, [{ type: schema.nodes.blank_line }]);
    if (prepTr.steps.length) dispatchMerged(state, [prepTr, splitTr], dispatch);
    else dispatch(splitTr.scrollIntoView());
    return true;
  }

  const inList = !!findAncestorOfType($from, schema.nodes.list_item);
  if (!ctx.inTable && !inList && $from.parent.type === schema.nodes.paragraph && $from.nodeBefore?.type === schema.nodes.hard_break) {
    let poppedBreaks = 0;
    let scanPos = $from.pos;
    while (scanPos > $from.start() && workState.doc.resolve(scanPos).nodeBefore?.type === schema.nodes.hard_break) {
      poppedBreaks++;
      scanPos -= workState.doc.resolve(scanPos).nodeBefore.nodeSize;
    }
    if (poppedBreaks >= 1) {
      if (!dispatch) return true;
      const splitTr = workState.tr;
      const parent = $from.parent;
      const blockStart = $from.start();
      const blockEnd = $from.end();
      const beforeSlice = scanPos > blockStart ? workState.doc.slice(blockStart, scanPos).content : Fragment.empty;
      const afterSlice = $from.pos < blockEnd ? workState.doc.slice($from.pos, blockEnd).content : Fragment.empty;
      const blocks = [];
      if (beforeSlice.size > 0) {
        blocks.push(schema.nodes.paragraph.create({
          mdContext: parent.attrs.mdContext || '',
          mdBlockId: parent.attrs.mdBlockId || null,
          mdBlockSub: parent.attrs.mdBlockSub || 0,
          mdBlockTotal: parent.attrs.mdBlockTotal || 1,
          mdEmpty: false
        }, beforeSlice));
      }
      for (let b = 0; b < (afterSlice.size > 0 ? poppedBreaks : poppedBreaks + 1); b++) {
        blocks.push(schema.nodes.blank_line.create());
      }
      if (afterSlice.size > 0) {
        blocks.push(schema.nodes.paragraph.create({ mdEmpty: false }, afterSlice));
      }
      splitTr.replaceWith($from.before(), $from.after(), blocks);
      let tailOffset = $from.before();
      for (let b = 0; b < blocks.length - 1; b++) tailOffset += blocks[b].nodeSize;
      splitTr.setSelection(TextSelection.near(splitTr.doc.resolve(tailOffset + 1)));
      if (prepTr.steps.length) dispatchMerged(state, [prepTr, splitTr], dispatch);
      else dispatch(splitTr.scrollIntoView());
      return true;
    }
  }

  if (!dispatch) return true;
  const finalTr = prepTr.steps.length ? workState.tr.replaceSelectionWith(schema.nodes.hard_break.create()) : state.tr.replaceSelectionWith(schema.nodes.hard_break.create());
  if (prepTr.steps.length) dispatchMerged(state, [prepTr, finalTr], dispatch);
  else dispatch(finalTr.scrollIntoView());
  return true;
}

/**
 * Entfernt vererbte Block-Herkunfts-IDs auf dem zweiten Abschnitt einer Teilung,
 * damit zwei geteilte Blöcke niemals denselben Original-Suffix beanspruchen (Astra #7).
 */
function clearOriginOnSplitBlock(state, dispatch, baseCommand) {
  return baseCommand(state, tr => {
    const newDoc = tr.doc;
    const seen = new Set();
    let fix = tr;
    let offset = 0;
    newDoc.forEach(n => {
      if (n.attrs?.mdBlockId != null && Number(n.attrs?.mdBlockTotal || 1) === 1) {
        const k = `${n.attrs.mdContext || ''}${n.attrs.mdBlockId}`;
        if (seen.has(k)) {
          fix.setNodeMarkup(offset, null, { ...n.attrs, mdContext: '', mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 });
        } else {
          seen.add(k);
        }
      }
      offset += n.nodeSize;
    });
    dispatch(fix);
  });
}

function splitListItemResetTask(schema) {
  const baseSplit = splitListItem(schema.nodes.list_item);
  return (state, dispatch) => {
    const $from = state.selection.$from;
    const itemAnc = findAncestorOfType($from, schema.nodes.list_item);
    if (!itemAnc || itemAnc.node.attrs.task !== true) {
      return baseSplit(state, dispatch);
    }
    return baseSplit(state, tr => {
      if (!dispatch) return;
      // Neu entstandener zweiter Aufgaben-Punkt startet immer unerledigt (`task: false`, Sol #14).
      const { $from: nextFrom } = tr.selection;
      const newAnc = findAncestorOfType(nextFrom, schema.nodes.list_item);
      if (newAnc && newAnc.node.attrs.task === true) {
        tr.setNodeMarkup(newAnc.pos, null, { ...newAnc.node.attrs, task: false });
      }
      dispatch(tr);
    });
  };
}

export function buildEnterCommand(schema = defaultSchema) {
  return chainCommands(
    newlineInCode,
    splitListItemResetTask(schema),
    (state, dispatch) => {
      const { $from, empty } = state.selection;
      if (!empty) return false;
      const parent = $from.parent;
      if (parent.type === schema.nodes.blank_line) {
        if (!dispatch) return true;
        const pos = $from.before();
        const tr = state.tr.insert($from.after(), schema.nodes.blank_line.create());
        tr.setSelection(TextSelection.near(tr.doc.resolve(pos + parent.nodeSize + 1)));
        dispatch(tr.scrollIntoView());
        return true;
      }
      if (parent.type === schema.nodes.paragraph && parent.content.size === 0 && $from.depth === 1) {
        if (!dispatch) return true;
        const pos = $from.before();
        const tr = state.tr;
        tr.setNodeMarkup(pos, schema.nodes.blank_line, {
          mdContext: parent.attrs.mdContext || '',
          mdBlockId: parent.attrs.mdBlockId || null,
          mdBlockSub: parent.attrs.mdBlockSub || 0,
          mdBlockTotal: parent.attrs.mdBlockTotal || 1
        });
        tr.insert(pos + parent.nodeSize, schema.nodes.paragraph.create({ mdEmpty: false }));
        tr.setSelection(TextSelection.near(tr.doc.resolve(pos + parent.nodeSize + 1)));
        dispatch(tr.scrollIntoView());
        return true;
      }
      return false;
    },
    (s, d) => d ? clearOriginOnSplitBlock(s, d, createParagraphNear) : createParagraphNear(s),
    liftEmptyBlock,
    (s, d) => d ? clearOriginOnSplitBlock(s, d, splitBlock) : splitBlock(s)
  );
}

/**
 * Input-Rules (Sol #13): wandeln `- `, `* `, `+ `, `1. ` / `3. ` nur außerhalb
 * passender Listen in echte Listen um und übernehmen die eingegebene Startnummer,
 * ohne bestehende Listen unerwartet umzuschalten/auszuhängen.
 */
export function buildInputRules(schema = defaultSchema) {
  const wrapParagraphAsList = (state, start, end, listType, listAttrs, itemAttrs) => {
    const $start = state.doc.resolve(start);
    if ($start.parent.type !== schema.nodes.paragraph && $start.parent.type !== schema.nodes.blank_line) return null;
    if ($start.start() !== start) return null;
    if (findAncestorOfType($start, schema.nodes.list_item)) return null;

    const tr = state.tr.delete(start, end);
    const blockPos = tr.mapping.map($start.before());
    if (tr.doc.nodeAt(blockPos)?.type === schema.nodes.blank_line) {
      const bn = tr.doc.nodeAt(blockPos);
      tr.setNodeMarkup(blockPos, schema.nodes.paragraph, {
        mdContext: bn.attrs.mdContext || '',
        mdBlockId: bn.attrs.mdBlockId || null,
        mdBlockSub: bn.attrs.mdBlockSub || 0,
        mdBlockTotal: bn.attrs.mdBlockTotal || 1,
        mdEmpty: false
      });
    }
    const $resolved = tr.doc.resolve(blockPos + 1);
    const range = $resolved.blockRange();
    if (!range) return null;
    const wrappers = findWrapping(range, listType, listAttrs);
    if (!wrappers) return null;
    tr.wrap(range, wrappers);
    // Wenn Task-Attribut nötig, hier ohne Einfluss auf bestehende Listen.
    return tr;
  };

  const rules = [
    new InputRule(/^([-+*])\s$/, (state, _match, start, end) =>
      wrapParagraphAsList(state, start, end, schema.nodes.bullet_list, { tight: true }, { task: null })
    ),
    new InputRule(/^(\d{1,9})\.\s$/, (state, match, start, end) =>
      wrapParagraphAsList(
        state,
        start,
        end,
        schema.nodes.ordered_list,
        { order: Number(match[1]), tight: true },
        { task: null }
      )
    ),
    new InputRule(/^(#{1,6})\s$/, (state, match, start, end) => {
      const $start = state.doc.resolve(start);
      if ($start.parent.type !== schema.nodes.paragraph && $start.parent.type !== schema.nodes.blank_line) return null;
      if ($start.start() !== start) return null;
      const level = match[1].length;
      const tr = state.tr.delete(start, end);
      tr.setNodeMarkup($start.before(), schema.nodes.heading, {
        ...$start.parent.attrs,
        level,
        outlineIgnore: false
      });
      return tr;
    }),
    new InputRule(/^>\s$/, (state, _match, start, end) => {
      const $start = state.doc.resolve(start);
      if ($start.parent.type !== schema.nodes.paragraph && $start.parent.type !== schema.nodes.blank_line) return null;
      if ($start.start() !== start) return null;
      const tr = state.tr.delete(start, end);
      const mappedState = state.apply(tr);
      let wrapTr = null;
      wrapIn(schema.nodes.blockquote)(mappedState, t => { wrapTr = t; });
      if (!wrapTr) return null;
      const combined = state.tr;
      for (const s of tr.steps) combined.step(s);
      for (const s of wrapTr.steps) combined.step(s);
      if (wrapTr.selectionSet) combined.setSelection(Selection.fromJSON(combined.doc, wrapTr.selection.toJSON()));
      return combined;
    })
  ];
  return inputRules({ rules });
}

export function buildKeymap({
  schema = defaultSchema,
  getTableEditor,
  isBlocked,
  onHardBreak,
  onTabFallback,
  onUndo,
  onRedo
}) {
  function deleteInDirection(key, direction) {
    return (state, dispatch, view) => {
      if (isBlocked()) return true;
      const { $from, $to, empty } = state.selection;
      const table = insideCellOrProtected(state, schema);
      if (table.inTable && !$from.sameParent($to)) return true;
      if (empty) {
        const adjacent = $pos => direction < 0 ? $pos.nodeBefore : $pos.nodeAfter;
        const atEdge = direction < 0 ? $from.parentOffset === 0 : $from.parentOffset === $from.parent.content.size;
        if (atEdge && table.inTable) return true;
        if (!$from.parent.isTextblock && adjacent($from)?.isAtom && NodeSelection.isSelectable(adjacent($from))) {
          const pos = direction < 0 ? $from.pos - adjacent($from).nodeSize : $from.pos;
          if (dispatch) dispatch(state.tr.setSelection(NodeSelection.create(state.doc, pos)));
          return true;
        }
        if (atEdge && $from.depth > 0) {
          const boundary = state.doc.resolve(direction < 0 ? $from.before() : $from.after());
          const type = adjacent(boundary)?.type;
          if (type === schema.nodes.math_block || type === schema.nodes.opaque_block) {
            return (direction < 0 ? selectNodeBackward : selectNodeForward)(state, dispatch, view);
          }
        }
      }
      return baseKeymap[key](state, dispatch, view);
    };
  }
  const backspace = deleteInDirection('Backspace', -1);
  const deleteForward = deleteInDirection('Delete', 1);
  return keymap({
    Enter: buildEnterCommand(schema),
    Backspace: backspace,
    'Mod-Backspace': backspace,
    'Shift-Backspace': backspace,
    Delete: deleteForward,
    'Mod-Delete': deleteForward,
    'Shift-Enter': (state, dispatch) => {
      if (isBlocked()) return true;
      if (onHardBreak) return onHardBreak(state, dispatch);
      return insertHardBreakCommand(state, dispatch ? tr => dispatch(closeHistory(tr)) : null, schema);
    },
    'Alt-Enter': (state, dispatch) => {
      if (isBlocked()) return true;
      if (onHardBreak) return onHardBreak(state, dispatch);
      return insertHardBreakCommand(state, dispatch ? tr => dispatch(closeHistory(tr)) : null, schema);
    },
    'Shift-Alt-Enter': (state, dispatch) => {
      if (isBlocked()) return true;
      if (onHardBreak) return onHardBreak(state, dispatch);
      return insertHardBreakCommand(state, dispatch ? tr => dispatch(closeHistory(tr)) : null, schema);
    },
    Tab: (state, dispatch) => {
      if (isBlocked()) return true;
      const tables = getTableEditor?.();
      if (tables?.context?.() && tables.navigate?.(false)) return true;
      if (sinkListItem(schema.nodes.list_item)(state, dispatch)) return true;
      if (findAncestorOfType(state.selection.$from, schema.nodes.list_item)) return true;
      if (state.selection.$from.parent.type === schema.nodes.code_block) {
        if (dispatch) dispatch(state.tr.insertText('\t').scrollIntoView());
        return true;
      }
      if (onTabFallback) return onTabFallback(state, dispatch);
      if (dispatch) dispatch(state.tr.insertText('\u00a0\u00a0\u00a0\u00a0').scrollIntoView());
      return true;
    },
    'Shift-Tab': (state, dispatch) => {
      if (isBlocked()) return true;
      const tables = getTableEditor?.();
      if (tables?.context?.() && tables.navigate?.(true)) return true;
      return liftListItem(schema.nodes.list_item)(state, dispatch);
    },
    'Mod-z': () => {
      if (isBlocked()) return true;
      return onUndo ? onUndo() : false;
    },
    'Mod-Shift-z': () => {
      if (isBlocked()) return true;
      return onRedo ? onRedo() : false;
    },
    'Mod-y': () => {
      if (isBlocked()) return true;
      return onRedo ? onRedo() : false;
    }
  });
}

export function executeVisualCommand(view, command, value, {
  schema = defaultSchema,
  tableEditor,
  postMessage,
  session,
  onHistoryCommand
} = {}) {
  if (command === 'undo' || command === 'redo') {
    const ok = onHistoryCommand
      ? onHistoryCommand(command)
      : (command === 'undo' ? pmUndo : pmRedo)(view.state, tr => view.dispatch(tr));
    return { executed: !!ok, changed: !!ok, reason: ok ? undefined : 'empty-history' };
  }

  const { state } = view;
  const ctx = insideCellOrProtected(state, schema);
  if ((ctx.protectedAtom || ctx.containsProtected) && command !== 'deleteImage' && command !== 'delete') {
    postMessage?.({ kind: 'protectedFormat', session });
    return { executed: false, changed: false, reason: 'protected' };
  }
  const blockLevelCommands = new Set([
    'heading1', 'heading2', 'heading3', 'heading4', 'heading5', 'heading6',
    'bulletList', 'orderedList', 'taskList', 'quote', 'insertTable'
  ]);
  if (ctx.inTable && blockLevelCommands.has(command)) {
    tableEditor?.syncToolbar?.();
    postMessage?.({ kind: 'tableError', session, reason: 'format' });
    return { executed: false, changed: false, reason: 'table' };
  }

  let didChange = false;
  const dispatch = tr => {
    const withBoundary = command === 'insertText' ? tr : closeHistory(tr);
    if (withBoundary.docChanged || withBoundary.storedMarksSet) didChange = true;
    view.dispatch(withBoundary);
  };

  let handled = false;
  switch (command) {
    case 'deleteImage': {
      const sel = state.selection;
      if (sel instanceof NodeSelection && sel.node.type === schema.nodes.image) {
        dispatch(state.tr.deleteSelection().scrollIntoView());
        handled = true;
      } else {
        const after = sel.$from.nodeAfter;
        if (after && after.type === schema.nodes.image) {
          dispatch(state.tr.delete(sel.from, sel.from + after.nodeSize).scrollIntoView());
          handled = true;
        }
      }
      break;
    }
    case 'heading1':
    case 'heading2':
    case 'heading3':
    case 'heading4':
    case 'heading5':
    case 'heading6': {
      const res = applyHeadingOrParagraph(state, dispatch, schema, { level: Number(command.slice(7)) });
      return { executed: res.handled, changed: res.changed, reason: res.reason };
    }
    case 'plainParagraph': {
      const res = applyHeadingOrParagraph(state, dispatch, schema, { level: null });
      return { executed: res.handled, changed: res.changed, reason: res.reason };
    }
    case 'bulletList':
      handled = toggleListMode(state, dispatch, schema, 'bullet');
      break;
    case 'orderedList':
      handled = toggleListMode(state, dispatch, schema, 'ordered');
      break;
    case 'taskList':
      handled = toggleListMode(state, dispatch, schema, 'task');
      break;
    case 'quote':
      handled = unwrapBlockquote(state, dispatch, schema) || wrapIn(schema.nodes.blockquote)(state, dispatch);
      break;
    case 'hardBreak':
      handled = insertHardBreakCommand(state, dispatch, schema);
      break;
    case 'insertParagraph':
      handled = buildEnterCommand(schema)(state, dispatch);
      break;
    case 'delete':
      if (!state.selection.empty) {
        const tr = state.tr.deleteSelection().scrollIntoView();
        if (
          tr.doc.childCount === 1 &&
          (tr.doc.firstChild.type === schema.nodes.paragraph || tr.doc.firstChild.type === schema.nodes.blank_line) &&
          tr.doc.firstChild.content.size === 0
        ) {
          tr.setNodeMarkup(0, schema.nodes.paragraph, {
            ...tr.doc.firstChild.attrs,
            mdContext: '',
            mdBlockId: null,
            mdBlockSub: 0,
            mdBlockTotal: 1,
            mdEmpty: false,
            mdDeleted: true
          });
        }
        dispatch(tr);
        handled = true;
      }
      break;
    case 'insertText': {
      const text = String(value ?? '');
      dispatch(state.tr.insertText(text).scrollIntoView());
      handled = true;
      break;
    }
    case 'bold':
      handled = toggleMark(schema.marks.strong)(state, dispatch);
      break;
    case 'italic':
      handled = toggleMark(schema.marks.em)(state, dispatch);
      break;
    case 'code':
      handled = toggleMark(schema.marks.code)(state, dispatch);
      break;
    case 'highlight':
      handled = toggleMark(schema.marks.highlight)(state, dispatch);
      break;
    case 'strike':
      handled = toggleMark(schema.marks.strike)(state, dispatch);
      break;
    case 'link': {
      const href = typeof value === 'string' ? value.trim() : '';
      if (!href) {
        if (isMarkActive(state, schema.marks.link)) {
          const { from, to, empty } = state.selection;
          if (!empty) dispatch(state.tr.removeMark(from, to, schema.marks.link));
          else dispatch(state.tr.removeStoredMark(schema.marks.link));
          handled = true;
        }
      } else {
        const { from, to, empty } = state.selection;
        const mark = schema.marks.link.create({ href, title: null });
        if (empty) {
          dispatch(state.tr.addStoredMark(mark));
          handled = true;
        } else {
          dispatch(state.tr.addMark(from, to, mark));
          handled = true;
        }
      }
      break;
    }
    case 'insertTable': {
      const result = tableEditor?.insertTable(value?.rows, value?.columns);
      if (result && !result.ok) postMessage?.({ kind: 'tableError', session, reason: result.reason });
      return { executed: result?.ok === true, changed: result?.ok === true, reason: 'table' };
    }
    case 'insertHTML': {
      const ownerDocument = view.dom.ownerDocument;
      const html = sanitizePasteHTML(String(value || ''), ownerDocument);
      const nodes = parseHTMLToNodes(html, { schema, ownerDocument });
      if (nodes.length) {
        const slice = new Slice(Fragment.fromArray(nodes), 0, 0);
        dispatch(state.tr.replaceSelection(slice).scrollIntoView());
        handled = true;
      }
      break;
    }
    default:
      handled = false;
      break;
  }

  return { executed: handled, changed: didChange };
}

export function getHistoryState(state) {
  const uDepth = undoDepth(state);
  const rDepth = redoDepth(state);
  return {
    canUndo: uDepth > 0,
    canRedo: rDepth > 0,
    undoDepth: uDepth,
    redoDepth: rDepth
  };
}

export { closeHistory, pmUndo, pmRedo };
