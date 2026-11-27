import { EditorState, Plugin, Selection, TextSelection, NodeSelection, AllSelection } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { history, undo as pmUndo, redo as pmRedo, closeHistory } from 'prosemirror-history';
import { gapCursor } from 'prosemirror-gapcursor';
import { Fragment, Slice, DOMSerializer } from 'prosemirror-model';
import { schema } from './schema.js';
import {
  parseDocumentContainer,
  parseHTMLToNodes,
  sanitizePasteHTML,
  inspectAndCleanClipboardHTML
} from './parser.js';
import { serializeDocument, serializeBlockNode, serializeInline } from './serializer.js';
import { createNodeViews } from './nodeviews.js';
import {
  buildInputRules,
  buildKeymap,
  executeVisualCommand,
  getHistoryState
} from './commands.js';
import { createDiagnosticsController, sanitizeDiagnosticKey } from './diagnostics.js';
import { createTableEditor } from './tables.js';

const MAX_SOURCE_CONTEXT_BYTES = 33554432;

function postVisualMessage(payload) {
  try {
    window.webkit?.messageHandlers?.visualMarkdown?.postMessage(payload);
  } catch (_) {}
}

function postCopyMessage(payload) {
  try {
    window.webkit?.messageHandlers?.markdownCopy?.postMessage(payload);
  } catch (_) {}
}

function collectImageTransactions(doc) {
  const seen = new Set();
  doc.descendants(node => {
    if (node.type.name === 'image' && node.attrs.imageTransaction) {
      seen.add(node.attrs.imageTransaction);
    }
    return true;
  });
  return Array.from(seen);
}

function collectOrderedImageTransactions(doc) {
  return collectImageTransactions(doc).slice().sort();
}

export function installFastraVisualBridge() {
  let view = null;
  let root = null;
  let session = '';
  let base = '';
  let revision = 0;
  let composing = false;
  let notifyCompositionEnd = false;
  let fenced = false;
  let failed = false;
  let initializing = false;
  let actionFenced = false;
  let lastEditableProp = null;
  let domObserverPausedForOversizedTable = false;
  let flushingDom = false;
  let clipboardBookmark = null;
  let imageFenceRevision = null;
  let lastImageTransactions = '[]';
  let lastInputType = '';
  let emittedInputType = '';
  let pendingInputType = '';
  let emittedEditorState = null;
  let clipboardLimit = 0;
  let copiedHTML = null;
  let lastTableContext = null;
  let lastReportedTableKey = null;
  let selectingWithMouse = false;
  let mouseDragAnchor = null;
  let mouseDragStart = null;
  let mouseDragMoved = false;
  let mouseDragHadButtons = false;
  let sourceReplacementEnabled = false;
  let sourceContextBytes = 0;
  let bookmarkID = 0;
  let clipboardSelectionGeneration = 0;
  let observedClipboardSel = null;
  let viewportRestoring = false;
  let viewportGeneration = 0;
  let viewportPending = false;
  let listenersInstalledOnRoot = new WeakSet();
  let globalListenersInstalled = false;
  let tables = null;
  let lastPreOpSnapshot = null;

  const nativeActionIDs = new Set();
  const bookmarks = new Map();
  const opaqueSources = Object.create(null);
  const imageUrlOverrides = new Map();
  const originals = new Map();
  const contexts = new Map();

  function postMessage(payload) {
    postVisualMessage(payload);
  }

  function viewportPosition() {
    return { x: Math.max(0, window.scrollX || 0), y: Math.max(0, window.scrollY || 0) };
  }

  function reportViewport() {
    if (!viewportRestoring && session) {
      postMessage({ kind: 'viewport', session, revision, viewport: viewportPosition() });
    }
  }

  async function restoreViewport(value) {
    if (!value || ![value.x, value.y].every(n => Number.isFinite(n) && n >= 0 && n <= 100000000)) return;
    const req = ++viewportGeneration;
    viewportRestoring = true;
    let settled = 0;
    for (let attempt = 0; attempt < 60 && req === viewportGeneration; attempt++) {
      window.scrollTo?.(value.x, value.y);
      const actual = viewportPosition();
      if (Math.abs(actual.x - value.x) < 1 && Math.abs(actual.y - value.y) < 1) {
        if (++settled === 2) break;
      } else {
        settled = 0;
      }
      await new Promise(resolve => setTimeout(resolve, 16));
    }
    if (req === viewportGeneration) {
      viewportRestoring = false;
      reportViewport();
    }
  }

  function serialize() {
    if (!view) return base;
    return serializeDocument(view.state.doc, {
      contexts,
      originals,
      opaqueSources,
      lastInputType
    });
  }

  const diagnostics = createDiagnosticsController({
    postMessage,
    getSession: () => session,
    getRevision: () => revision,
    getRoot: () => root,
    isFenced: () => fenced,
    isComposing: () => composing,
    getLastInputType: () => lastInputType,
    serializeMarkdown: serialize
  });

  function updateFence() {
    fenced =
      failed ||
      initializing ||
      actionFenced ||
      nativeActionIDs.size > 0 ||
      clipboardBookmark !== null ||
      imageFenceRevision !== null;
    const nextEditable = !fenced && !failed;
    if (view && lastEditableProp !== nextEditable) {
      if (nextEditable && !(view.state.selection instanceof NodeSelection)) syncDOMSelectionToProseMirror();
      lastEditableProp = nextEditable;
      // Editierbarkeit direkt an der gemounteten ProseMirror-View nachführen (Astra #2, Sol #2).
      view.setProps({ editable: () => !fenced && !failed });
    }
    if (root) {
      const desired = (fenced || failed) ? 'false' : 'true';
      if (root.contentEditable !== desired) {
        root.contentEditable = desired;
      }
    }
  }

  function notifyHistoryAndOutline() {
    if (!view || !session) return;
    const hist = getHistoryState(view.state);
    postMessage({
      kind: 'historyState',
      session,
      revision,
      historyState: hist,
      ...hist
    });
    postMessage({
      kind: 'outlinePosition',
      session,
      revision,
      index: outlinePosition()
    });
    reportTableContext();
  }

  let pendingEmitTimer = null;

  function clearPendingEmitTimer() {
    if (pendingEmitTimer !== null) {
      clearTimeout(pendingEmitTimer);
      pendingEmitTimer = null;
    }
  }

  function flushDOMObserver() {
    try {
      view?.domObserver?.flush?.();
    } catch (_) {}
  }

  function captureDOMSelectionSnapshot() {
    if (!root) return null;
    const winSel = document.getSelection?.();
    if (!winSel || !winSel.rangeCount) return null;
    const range = winSel.getRangeAt(0);
    if (!root.contains(range.commonAncestorContainer)) return null;
    return {
      startContainer: range.startContainer,
      startOffset: range.startOffset,
      endContainer: range.endContainer,
      endOffset: range.endOffset,
      collapsed: range.collapsed,
      anchorNode: winSel.anchorNode || range.startContainer,
      anchorOffset: winSel.anchorNode ? winSel.anchorOffset : range.startOffset,
      focusNode: winSel.focusNode || range.endContainer,
      focusOffset: winSel.focusNode ? winSel.focusOffset : range.endOffset
    };
  }

  /**
   * Übernimmt eine direkt im DOM gesetzte Auswahl (z. B. durch Tests oder
   * WebKit-Drag) synchron in `view.state.selection`, bevor ein Befehl darauf läuft.
   */
  function syncDOMSelectionToProseMirror(snapshot = null) {
    if (!view || !root) return;
    const active =
      snapshot && root.contains(snapshot.startContainer) && root.contains(snapshot.endContainer)
        ? snapshot
        : captureDOMSelectionSnapshot();
    if (!active) return;
    if (view.state.selection instanceof NodeSelection && active.collapsed) return;

    try {
      const doc = view.state.doc;

      // Komplettauswahl über das Wurzelelement als AllSelection binden, damit auch
      // führende/abschließende Atome (Mermaid, Formelblöcke, Bilder) vollständig greifen.
      if (
        active.startContainer === root &&
        active.startOffset === 0 &&
        active.endContainer === root &&
        active.endOffset === root.childNodes.length &&
        !active.collapsed
      ) {
        const allSel = new AllSelection(doc);
        if (!(view.state.selection instanceof AllSelection)) {
          view.dispatch(view.state.tr.setSelection(allSel).setMeta('addToHistory', false).setMeta('fastraAllowFenced', true));
        }
        return;
      }

      // Einzelnes ausgewähltes Atom-Element (`img`, KaTeX, Opaque) als NodeSelection binden.
      if (
        active.startContainer === active.endContainer &&
        active.endOffset === active.startOffset + 1 &&
        active.startContainer.nodeType === 1
      ) {
        const selectedNode = active.startContainer.childNodes[active.startOffset];
        if (selectedNode?.nodeType === 1 && (selectedNode.tagName === 'IMG' || selectedNode.hasAttribute?.('data-tex') || selectedNode.hasAttribute?.('data-md-opaque'))) {
          const candidates = [];
          try {
            candidates.push(view.posAtDOM(active.startContainer, active.startOffset));
          } catch (_) {}
          try {
            const domPos = view.posAtDOM(selectedNode, 0);
            candidates.push(domPos - 1, domPos);
          } catch (_) {}
          for (const rawPos of candidates) {
            const pos = Math.max(0, Math.min(rawPos, doc.content.size));
            const atNode = doc.nodeAt(pos);
            if (atNode && (atNode.type.name === 'image' || atNode.type.name === 'math_inline' || atNode.type.name === 'opaque_inline' || atNode.type.name === 'math_block' || atNode.type.name === 'opaque_block')) {
              const nodeSel = NodeSelection.create(doc, pos);
              if (!(view.state.selection instanceof NodeSelection) || view.state.selection.from !== nodeSel.from) {
                view.dispatch(view.state.tr.setSelection(nodeSel).setMeta('addToHistory', false).setMeta('fastraAllowFenced', true));
              }
              return;
            }
          }
        }
      }

      const anchorPos = Math.max(0, Math.min(view.posAtDOM(active.anchorNode, active.anchorOffset), doc.content.size));
      const focusPos = Math.max(0, Math.min(view.posAtDOM(active.focusNode, active.focusOffset), doc.content.size));

      let nextSel;
      if (active.collapsed && active.startContainer.nodeType === 1) {
        const el = active.startContainer;
        const offset = active.startOffset;
        if (offset === el.childNodes.length && offset > 0) {
          if (el === root) {
            nextSel = Selection.near(doc.resolve(doc.content.size), -1);
          } else {
            // Am Ende eines Blockelements (`r.selectNodeContents(li); r.collapse(false)`)
            // innerhalb des Elements bleiben, statt in das nächste Element (`table` / `li`) zu springen.
            let targetNode = el;
            while (targetNode.nodeType === 1) {
              let child = targetNode.lastChild;
              while (child && child.nodeType === 1 && (child.classList?.contains('ProseMirror-trailingBreak') || child.classList?.contains('ProseMirror-separator'))) {
                child = child.previousSibling;
              }
              if (!child) break;
              targetNode = child;
            }
            const innerPos = targetNode.nodeType === 3
              ? view.posAtDOM(targetNode, targetNode.data.length)
              : view.posAtDOM(targetNode, targetNode.childNodes?.length || 0);
            nextSel = Selection.near(doc.resolve(Math.max(0, Math.min(innerPos, doc.content.size))), -1);
          }
        } else if (offset === 0) {
          nextSel = Selection.near(doc.resolve(anchorPos), 1);
        } else {
          nextSel = TextSelection.between(doc.resolve(anchorPos), doc.resolve(focusPos));
        }
      } else {
        nextSel = TextSelection.between(doc.resolve(anchorPos), doc.resolve(focusPos));
      }

      if (
        view.state.selection.anchor !== nextSel.anchor ||
        view.state.selection.head !== nextSel.head ||
        view.state.selection instanceof NodeSelection ||
        view.state.selection instanceof AllSelection
      ) {
        view.dispatch(view.state.tr.setSelection(nextSel).setMeta('addToHistory', false).setMeta('fastraAllowFenced', true));
      }
    } catch (_) {
      // Unvollständige DOM-Ranges außerhalb des PM-Textbaums still ignorieren.
    }
  }

  function syncProseMirrorSelectionToDOM({ force = false } = {}) {
    if (!view || !root || (!force && view.hasFocus?.())) return;
    try {
      const sel = view.state.selection;
      const winSel = document.getSelection?.();
      if (!winSel) return;
      const anchorDOM = view.domAtPos(sel.anchor);
      const headDOM = sel.empty ? anchorDOM : view.domAtPos(sel.head);
      if (anchorDOM?.node && headDOM?.node) {
        if (
          winSel.rangeCount &&
          winSel.anchorNode === anchorDOM.node &&
          winSel.anchorOffset === anchorDOM.offset &&
          winSel.focusNode === headDOM.node &&
          winSel.focusOffset === headDOM.offset
        ) {
          return;
        }
        if (sel.anchor <= sel.head && winSel.removeAllRanges && winSel.addRange) {
          const range = document.createRange();
          range.setStart(anchorDOM.node, anchorDOM.offset);
          range.setEnd(headDOM.node, headDOM.offset);
          winSel.removeAllRanges();
          winSel.addRange(range);
        } else {
          winSel.setBaseAndExtent?.(anchorDOM.node, anchorDOM.offset, headDOM.node, headDOM.offset);
        }
      }
    } catch (_) {}
  }

  function syncFromDOM() {
    const snap = captureDOMSelectionSnapshot();
    flushDOMObserver();
    syncDOMSelectionToProseMirror(snap);
  }

  function observeClipboardSelection() {
    if (!view) return null;
    const { from, to, anchor, head } = view.state.selection;
    const current = { from, to, anchor, head };
    if (
      !observedClipboardSel ||
      observedClipboardSel.from !== current.from ||
      observedClipboardSel.to !== current.to ||
      observedClipboardSel.anchor !== current.anchor ||
      observedClipboardSel.head !== current.head
    ) {
      clipboardSelectionGeneration++;
      observedClipboardSel = current;
    }
    return current;
  }

  function currentClipboardSelection(saved) {
    if (saved.clipboardSelectionGeneration === undefined) return true;
    const current = observeClipboardSelection();
    return (
      !!current &&
      saved.clipboardSelectionGeneration === clipboardSelectionGeneration &&
      saved.clipboardSelection?.from === current.from &&
      saved.clipboardSelection?.to === current.to
    );
  }

  function toolbarTableContext() {
    if (!selectingWithMouse) {
      lastTableContext = tables?.context?.() || null;
    }
    return lastTableContext;
  }

  function reportTableContext() {
    if (selectingWithMouse || domObserverPausedForOversizedTable || !session) return;
    const context = toolbarTableContext();
    const key = JSON.stringify({ session, revision, context });
    if (key === lastReportedTableKey) return;
    lastReportedTableKey = key;
    postMessage({
      kind: 'tableContext',
      session,
      revision,
      context
    });
  }

  function outlineHeadings() {
    if (!root) return [];
    return Array.from(root.querySelectorAll('h1,h2,h3,h4,h5,h6')).filter(
      n => !n.closest('[data-md-opaque],[data-tex]') && !n.hasAttribute('data-md-outline-ignore')
    );
  }

  function outlinePosition() {
    if (!view || !root) return -1;
    const headings = outlineHeadings();
    if (!headings.length) return -1;
    let anchorDOM = null;
    try {
      const domPos = view.domAtPos(view.state.selection.anchor);
      anchorDOM = domPos.node?.nodeType === 1 ? domPos.node : domPos.node?.parentElement;
    } catch (_) {
      return -1;
    }
    if (!anchorDOM || !root.contains(anchorDOM)) return -1;
    let index = -1;
    headings.forEach((heading, i) => {
      if (heading.contains(anchorDOM) || heading === anchorDOM || (heading.compareDocumentPosition(anchorDOM) & 4 /* FOLLOWING */)) {
        index = i;
      }
    });
    return index;
  }

  function buildContextEntry(cfg, prefix, parsedGroups, targetOriginals, targetContexts, targetOpaque) {
    const context = {
      blocks: (cfg.blocks || []).map(b => ({ ...b, id: prefix + String(b.id) })),
      hiddenPrefixes: new Map(),
      trailingHidden: new Set(),
      trailingOwner: null
    };
    let preceding = [];
    for (const block of context.blocks) {
      if (block.hidden) {
        preceding.push(block);
        continue;
      }
      context.hiddenPrefixes.set(block.id, preceding);
      preceding = [];
      context.trailingOwner = block.id;
      const originalID = block.id.slice(prefix.length);
      const parsed = parsedGroups.get(originalID);
      if (parsed) {
        targetOriginals.set(block.id, {
          source: block.source,
          canonicalSnapshot: parsed.canonicalSnapshot,
          structure: parsed.structure,
          context,
          ignoredHeadings: parsed.ignoredHeadings
        });
      }
    }
    context.trailingHidden = new Set(preceding.map(b => b.id));
    Object.assign(targetOpaque, cfg.opaqueSources || {});
    targetContexts.set(prefix, context);
    return context;
  }

  function emitChangeIfNeeded(forceImageTransactions = null) {
    clearPendingEmitTimer();
    if (!view || initializing || failed || composing) return;
    const previousBase = base;
    const current = serialize();
    const currentImageTx = forceImageTransactions || collectOrderedImageTransactions(view.state.doc);
    const currentImageState = JSON.stringify(currentImageTx);
    if (currentImageState === lastImageTransactions && imageFenceRevision === null) lastPreOpSnapshot = null;
    if (current === previousBase && currentImageState === lastImageTransactions) {
      notifyHistoryAndOutline();
      return;
    }

    const imageChanged = currentImageState !== lastImageTransactions;
    if (imageChanged) {
      imageFenceRevision = revision + 1;
      updateFence();
    }
    revision += 1;
    base = current;
    lastImageTransactions = currentImageState;
    emittedEditorState = view.state;

    const hist = getHistoryState(view.state);
    emittedInputType = lastInputType;
    postMessage({
      kind: 'change',
      session,
      base: previousBase,
      markdown: current,
      revision,
      imageTransactions: currentImageTx,
      inputType: emittedInputType,
      viewport: viewportPosition(),
      historyState: hist,
      ...hist
    });
    // Nach dem Übermitteln des Events einen einmaligen History-/Edit-Typ zurücksetzen (Sol #6).
    lastInputType = '';
    lastReportedTableKey = null;
    notifyHistoryAndOutline();
  }

  function scheduleEmitChange() {
    clearPendingEmitTimer();
    pendingInputType = lastInputType;
    pendingEmitTimer = setTimeout(() => {
      pendingEmitTimer = null;
      emitChangeIfNeeded();
    }, 80);
  }

  function createBridgePlugin() {
    return new Plugin({
      appendTransaction(transactions, oldState, newState) {
        if (!transactions.some(tr => tr.docChanged)) return null;
        let fixTr = null;
        newState.doc.descendants((node, pos) => {
          if (node.type === schema.nodes.blank_line && node.content.size > 0) {
            if (!fixTr) fixTr = newState.tr;
            fixTr.setNodeMarkup(pos, schema.nodes.paragraph, {
              mdContext: node.attrs.mdContext || '',
              mdBlockId: node.attrs.mdBlockId || null,
              mdBlockSub: node.attrs.mdBlockSub || 0,
              mdBlockTotal: node.attrs.mdBlockTotal || 1,
              mdEmpty: false
            }, node.marks);
            return false;
          }
          return true;
        });

        const oldImages = JSON.stringify(collectOrderedImageTransactions(oldState.doc));
        const newImages = JSON.stringify(collectOrderedImageTransactions(newState.doc));
        if (oldImages !== newImages) {
          fixTr = closeHistory(fixTr || newState.tr);
        }
        return fixTr;
      }
    });
  }

  function applyTransaction(tr, { allowFenced = false, inputType = '' } = {}) {
    if (!view) return false;
    if (fenced && !allowFenced && tr.docChanged) return false;
    if (inputType) lastInputType = inputType;
    if (allowFenced) tr.setMeta('fastraAllowFenced', true);
    tr.setMeta('fastraImmediate', true);
    view.dispatch(tr);
    return true;
  }

  function toggleTaskAtPos(pos, checked) {
    if (!view || fenced) return;
    const node = view.state.doc.nodeAt(pos);
    if (!node || node.type !== schema.nodes.list_item || node.attrs.task === null) return;
    const tr = closeHistory(view.state.tr.setNodeMarkup(pos, null, { ...node.attrs, task: checked }));
    applyTransaction(tr, { inputType: 'taskToggle' });
  }

  function extractUriToken(src) {
    if (!src) return '';
    const withoutQuery = String(src).split(/[?#]/)[0];
    return withoutQuery.split('/').pop() || '';
  }

  function applyDomImageOverridesOnImages(doc) {
    if (!view) return;
    const tr = view.state.tr.setMeta('addToHistory', false).setMeta('fastraAllowFenced', true);
    doc.descendants((node, pos) => {
      if (node.type === schema.nodes.image) {
        const mapped = node.attrs.src ? imageUrlOverrides.get(node.attrs.src) : null;
        if (mapped && mapped !== node.attrs.src) {
          tr.setNodeMarkup(pos, null, { ...node.attrs, src: mapped });
        }
      }
      return true;
    });
    if (tr.docChanged) view.dispatch(tr);
  }

  function imageNodePosition(target) {
    const img = target?.closest?.('img');
    if (!img || img.closest('[data-md-opaque],[data-tex]')) return null;
    try {
      const pos = view.posAtDOM(img, 0);
      if (view.state.doc.nodeAt(pos)?.type === schema.nodes.image && view.nodeDOM(pos) === img) return pos;
    } catch (_) {}
    return null;
  }

  function createEditorView(doc, rawContainer) {
    domObserverPausedForOversizedTable = false;
    lastEditableProp = null;
    lastReportedTableKey = null;
    mouseDragAnchor = null;
    mouseDragStart = null;
    mouseDragMoved = false;
    if (view) {
      tables?.destroy?.();
      view.destroy();
      view = null;
    }

    while (rawContainer.firstChild) rawContainer.firstChild.remove();

    let tableEditorInstance = null;
    const km = buildKeymap({
      schema,
      getTableEditor: () => tableEditorInstance,
      isBlocked: () => fenced || composing,
      onUndo: () => runHistory('undo'),
      onRedo: () => runHistory('redo')
    });

    const state = EditorState.create({
      schema,
      doc,
      plugins: [
        history(),
        buildInputRules(schema),
        km,
        gapCursor(),
        createBridgePlugin()
      ]
    });

    // ProseMirror direkt auf `#fastra-visual` mounten (`mount: rawContainer`), damit
    // kein inneres `.ProseMirror`-Div entsteht und `contentEditable`/`class` stabil bleiben (Astra #2, Sol #2).
    view = new EditorView({ mount: rawContainer }, {
      state,
      editable: () => !fenced && !failed,
      nodeViews: createNodeViews({
        getImageOverrides: () => imageUrlOverrides,
        isBlocked: () => fenced || composing || failed,
        onToggleTask: toggleTaskAtPos
      }),
      handleKeyDown(v, event) {
        if (event.isComposing) return false;
        syncDOMSelectionToProseMirror();
        if (tableEditorInstance?.handleKeyDown?.(v, event)) return true;
        return false;
      },
      handleClick(v, pos, event) {
        tableEditorInstance?.handleClick?.(v, pos, event);
        return false;
      },
      handleDOMEvents: {
        keydown(_view, event) {
          if (event.isComposing) return true;
          return false;
        },
        beforeinput(_view, event) {
          if (fenced || failed) {
            event.preventDefault();
            return true;
          }
          lastInputType = event.inputType || '';
          if (event.inputType === 'historyUndo') {
            event.preventDefault();
            runHistory('undo');
            return true;
          }
          if (event.inputType === 'historyRedo') {
            event.preventDefault();
            runHistory('redo');
            return true;
          }
          return false;
        },
        compositionstart() {
          composing = true;
          return false;
        },
        compositionend() {
          composing = false;
          emitChangeIfNeeded();
          if (notifyCompositionEnd) {
            notifyCompositionEnd = false;
            postMessage({ kind: 'retryExternalCheck', session });
          }
          return false;
        },
        paste(_view, event) {
          if (fenced || failed) {
            event.preventDefault();
            return true;
          }
          syncDOMSelectionToProseMirror();
          const plain = event.clipboardData?.getData('text/plain') || '';
          const html = event.clipboardData?.getData('text/html') || '';
          if (tableEditorInstance?.handlePaste?.(_view, event)) {
            return true;
          }
          if (event.clipboardData?.getData('application/x-fastra-markdown')) {
            event.preventDefault();
            postMessage({ kind: 'pasteMarkdown', session, bookmark: window.fastraVisual.bookmark() });
            return true;
          }
          if (event.clipboardData?.files?.length) {
            event.preventDefault();
            postMessage({ kind: 'pasteImage', session, bookmark: window.fastraVisual.bookmark() });
            return true;
          }
          if (html) {
            event.preventDefault();
            if (isCodeSelection(view.state.selection)) {
              insertPlainText(view.state.selection, plain || clipboardPlainText(html));
              return true;
            }
            const cleaned = sanitizePasteHTML(html, root.ownerDocument);
            const slice = buildPasteSlice(cleaned);
            if (slice) {
              applyTransaction(closeHistory(view.state.tr).replaceSelection(slice).scrollIntoView(), { inputType: 'insertFromPaste' });
            }
            return true;
          }
          return false;
        },
        drop(_view, event) {
          event.preventDefault();
          const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
          if (coords) {
            applyTransaction(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(coords.pos))), { allowFenced: true });
          }
          return true;
        },
        dragover(_view, event) {
          event.preventDefault();
          return false;
        },
        contextmenu(_view, event) {
          const pos = imageNodePosition(event.target);
          if (pos === null || fenced) return false;
          event.preventDefault();
          applyTransaction(view.state.tr.setSelection(NodeSelection.create(view.state.doc, pos)));
          postMessage({ kind: 'imageMenu', session, x: event.clientX, y: event.clientY });
          return true;
        },
        click(_view, event) {
          if (fenced) {
            event.preventDefault();
            return true;
          }
          const pos = imageNodePosition(event.target);
          if (pos !== null) {
            event.preventDefault();
            applyTransaction(view.state.tr.setSelection(NodeSelection.create(view.state.doc, pos)));
            return true;
          }
          if (event.target?.closest?.('a')) {
            event.preventDefault();
            return true;
          }
          return false;
        },
        copy(_view, event) {
          if (tableEditorInstance?.handleCopy?.(_view, event)) return true;
          return handleCopyOrCut(event, false);
        },
        cut(_view, event) {
          return handleCopyOrCut(event, true);
        }
      },
      dispatchTransaction(tr) {
        const allowFenced = tr.getMeta('fastraAllowFenced') === true || flushingDom;
        if (tr.docChanged && (fenced || failed) && !allowFenced) {
          return;
        }
        const prevState = view.state;
        let candidateState = prevState.apply(tr);
        const imageChanged = tr.docChanged &&
          JSON.stringify(collectOrderedImageTransactions(prevState.doc)) !== JSON.stringify(collectOrderedImageTransactions(candidateState.doc));
        if (imageChanged) {
          const inputType = lastInputType;
          if (imageFenceRevision === null && lastPreOpSnapshot === null) {
            if (!composing && serialize() !== base) {
              lastInputType = pendingInputType;
              emitChangeIfNeeded();
              lastInputType = inputType;
            }
            // Eine laufende Komposition hat noch keine veröffentlichte Teilrevision.
            const editorState = composing ? emittedEditorState : prevState;
            lastPreOpSnapshot = { revision: revision + 1, markdown: base, editorState };
          }
          if (!inputType.startsWith('history') && tr.getMeta('addToHistory') !== false) {
            // History-Gruppe vor der Bildänderung trennen (Astra #13).
            const sepState = prevState.apply(closeHistory(prevState.tr));
            candidateState = sepState.apply(tr);
          }
        }

        view.updateState(candidateState);
        observeClipboardSelection();

        if (tr.docChanged) {
          if (!composing) {
            if (flushingDom || imageChanged || tr.getMeta('fastraImmediate') === true) {
              emitChangeIfNeeded();
            } else {
              scheduleEmitChange();
            }
          }
        } else if (tr.selectionSet) {
          notifyHistoryAndOutline();
        }
      }
    });

    tableEditorInstance = createTableEditor({
      view,
      schema,
      blocked: () => fenced || composing || failed,
      revision: () => revision,
      applyTransaction: tr => applyTransaction(tr, { inputType: 'editTable' }),
      report: () => reportTableContext(),
      fail: reason => postMessage({ kind: 'tableError', session, reason })
    });
    tables = tableEditorInstance;
    return view;
  }

  function wrapAncestorChain(innerFragment, $pos, startDepth) {
    let current = innerFragment;
    const parent = $pos.parent;
    const leafAttrs = parent.attrs && 'mdBlockId' in parent.attrs
      ? { ...parent.attrs, mdContext: '', mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 }
      : parent.attrs;
    current = parent.type.create(leafAttrs, current);
    for (let d = startDepth; d >= 1; d--) {
      const anc = $pos.node(d);
      if (anc.type === schema.nodes.list_item) {
        current = anc.type.create({ ...anc.attrs }, current);
      } else if (anc.type === schema.nodes.bullet_list) {
        current = anc.type.create({ ...anc.attrs, mdContext: '', mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 }, current);
      } else if (anc.type === schema.nodes.ordered_list) {
        const startOrder = Math.max(0, Number(anc.attrs.order ?? 1)) + $pos.index(d);
        current = anc.type.create({ ...anc.attrs, mdContext: '', mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1, order: startOrder }, current);
      } else if (anc.type === schema.nodes.blockquote) {
        current = anc.type.create({ ...anc.attrs, mdContext: '', mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 }, current);
      }
    }
    return Fragment.from(current);
  }

  function buildCopyFragment(slice, selection) {
    if (!slice.content.childCount) return slice.content;
    const { $from, $to } = selection;
    const findCell = $pos => {
      for (let d = $pos.depth; d > 0; d--) {
        const t = $pos.node(d).type;
        if (t === schema.nodes.table_cell || t === schema.nodes.table_header) return $pos.before(d);
      }
      return null;
    };
    const fromCell = findCell($from);
    if (fromCell !== null && fromCell === findCell($to)) {
      if (slice.content.childCount === 1 && (slice.content.firstChild.type === schema.nodes.table_cell || slice.content.firstChild.type === schema.nodes.table_header)) {
        return slice.content.firstChild.content;
      }
      if (slice.content.childCount === 1 && slice.content.firstChild.type === schema.nodes.table_row) {
        const cell = slice.content.firstChild.firstChild;
        if (cell) return cell.content;
      }
      if (slice.content.childCount === 1 && slice.content.firstChild.type === schema.nodes.table) {
        const cell = slice.content.firstChild.firstChild?.firstChild;
        if (cell) return cell.content;
      }
      return slice.content;
    }

    if ($from.sameParent($to)) {
      const parent = $from.parent;
      let hasContainerAncestor = false;
      for (let d = $from.depth - 1; d >= 1; d--) {
        const t = $from.node(d).type;
        if (t === schema.nodes.blockquote || t === schema.nodes.list_item || t === schema.nodes.bullet_list || t === schema.nodes.ordered_list) {
          hasContainerAncestor = true;
          break;
        }
      }
      const inlineContent = slice.content.childCount === 1 && slice.content.firstChild.isTextblock
        ? slice.content.firstChild.content
        : slice.content;
      if (parent.type === schema.nodes.heading || parent.type === schema.nodes.code_block || hasContainerAncestor) {
        return wrapAncestorChain(inlineContent, $from, $from.depth - 1);
      }
      if (slice.openStart > 0 && slice.openEnd > 0 && slice.content.childCount === 1 && slice.content.firstChild.type === schema.nodes.paragraph) {
        return inlineContent;
      }
      return slice.content;
    }

    if (slice.openStart > 0 && slice.content.firstChild?.type === schema.nodes.ordered_list) {
      const children = [];
      slice.content.forEach((child, _offset, idx) => {
        if (idx === 0 && child.type === schema.nodes.ordered_list) {
          let listAncestor = null;
          for (let d = 1; d < $from.depth; d++) {
            if ($from.node(d).type === schema.nodes.ordered_list) {
              listAncestor = { node: $from.node(d), index: $from.index(d) };
              break;
            }
          }
          if (listAncestor) {
            const startOrder = Math.max(0, Number(listAncestor.node.attrs.order ?? 1)) + listAncestor.index;
            children.push(child.type.create({ ...child.attrs, order: startOrder }, child.content, child.marks));
            return;
          }
        }
        children.push(child);
      });
      return Fragment.fromArray(children);
    }

    return slice.content;
  }

  /**
   * Serialisiert kopierte oder ausgeschnittene Slices einschließlich umgebendem
   * Block-Kontext (Überschrift, Zitat, Liste/Aufgabe, Codeblock) (Astra #6, Sol #7).
   */
  function serializeSliceMarkdown(contextFragment) {
    if (!contextFragment.childCount) return '';
    if (contextFragment.firstChild?.isInline) {
      return serializeInline(contextFragment, { opaqueSources });
    }
    const parts = [];
    contextFragment.forEach(child => {
      if (child.isBlock) parts.push(serializeBlockNode(child, { opaqueSources }));
    });
    return parts.filter(Boolean).join('\n\n');
  }

  function handleCopyOrCut(event, isCut) {
    if (!view || fenced) return false;
    syncFromDOM();
    if (view.state.selection.empty) return false;

    const { from, to } = view.state.selection;
    const slice = view.state.doc.slice(from, to);
    const copyFragment = buildCopyFragment(slice, view.state.selection);
    const holder = document.createElement('div');
    const domFrag = DOMSerializer.fromSchema(schema).serializeFragment(copyFragment, { document });
    holder.appendChild(domFrag);
    holder.querySelectorAll('li[data-task]').forEach(li => {
      if (!li.querySelector(':scope > input[type="checkbox"]')) {
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        if (li.getAttribute('data-task') === 'checked') cb.setAttribute('checked', '');
        li.prepend(cb);
      }
    });

    const markdown = serializeSliceMarkdown(copyFragment);
    const imageSources = Array.from(holder.querySelectorAll('img'), im => im.getAttribute('src'));

    const markEl = root?.querySelector('mark');
    if (markEl && typeof getComputedStyle === 'function') {
      const style = getComputedStyle(markEl);
      holder.querySelectorAll('mark').forEach(m => {
        m.style.backgroundColor = style.backgroundColor;
        m.style.color = style.color;
      });
    }
    holder.querySelectorAll('.fastra-visible-blank-line').forEach(n => {
      if (!n.textContent.length) n.replaceWith(document.createElement('br'));
      else {
        n.classList.remove('fastra-visible-blank-line');
        if (!n.classList.length) n.removeAttribute('class');
      }
    });
    holder.querySelectorAll('*').forEach(n => {
      for (const a of Array.from(n.attributes)) {
        if (a.name.startsWith('data-md-') || a.name.startsWith('data-fastra-') || a.name === 'contenteditable') {
          n.removeAttribute(a.name);
        }
      }
    });

    event.preventDefault();
    event.stopPropagation();

    const first = slice.content.childCount === 1 ? slice.content.firstChild : null;
    const singleImage = first?.type === schema.nodes.image ||
      (first?.type === schema.nodes.paragraph && first.childCount === 1 && first.firstChild.type === schema.nodes.image);
    const plain = view.state.doc.textBetween(from, to, '\n', '\n');
    const htmlStr = holder.innerHTML;
    const enc = new TextEncoder();
    if (clipboardLimit && [plain, htmlStr, markdown].some(v => enc.encode(v).length > clipboardLimit)) {
      postMessage({ kind: 'clipboardError', session, reason: 'size' });
      return true;
    }

    const key = window.fastraVisual.bookmark();
    copiedHTML = holder;
    clipboardBookmark = key;
    updateFence();
    postCopyMessage({
      plain,
      html: htmlStr,
      markdown,
      imageSources,
      singleImage,
      session,
      bookmark: key,
      cut: isCut
    });
    return true;
  }

  /**
   * Baut aus HTML-Markup ein passendes Inline- oder Block-Slice ohne unnötige
   * Absatz-Aufspaltung bei einzeiligen Inhalten (Sol #8, Bildeinfügung).
   */
  function buildPasteSlice(htmlString) {
    const doc = root?.ownerDocument || document;
    const tpl = doc.createElement('template');
    tpl.innerHTML = htmlString || '';
    const hasBlocks = !!tpl.content.querySelector('h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,pre,hr,table,div');
    const pCount = tpl.content.querySelectorAll('p').length;
    const onlyMultiBreakParagraph = pCount === 1 && (() => {
      const p = tpl.content.querySelector('p');
      return p.querySelectorAll('br').length >= 2 &&
        !p.textContent.replace(/\u200b/g, '').length &&
        !p.querySelector('img,[data-tex],[data-md-opaque]');
    })();
    if (!hasBlocks && pCount <= 1 && !onlyMultiBreakParagraph) {
      if (pCount === 1) {
        const p = tpl.content.querySelector('p');
        p.replaceWith(...p.childNodes);
      }
      const parsedInlineNodes = parseHTMLToNodes(tpl.innerHTML, { schema, ownerDocument: doc });
      const inlineRuns = [];
      for (const b of parsedInlineNodes) {
        if (b.type === schema.nodes.paragraph || b.isTextblock) {
          b.content.forEach(c => inlineRuns.push(c));
        } else {
          inlineRuns.push(b);
        }
      }
      if (inlineRuns.length) {
        return new Slice(Fragment.fromArray(inlineRuns), 0, 0);
      }
    }
    const nodes = parseHTMLToNodes(htmlString, { schema, ownerDocument: doc });
    return nodes.length ? new Slice(Fragment.fromArray(nodes), 0, 0) : null;
  }

  function isCodeSelection({ $from, $to }) {
    return $from.sameParent($to) && $from.parent.type === schema.nodes.code_block;
  }

  function clipboardPlainText(html) {
    const nodes = parseHTMLToNodes(sanitizePasteHTML(html, document), { schema, ownerDocument: document });
    const fragment = Fragment.fromArray(nodes);
    return fragment.textBetween(0, fragment.size, '\n', node => node.type === schema.nodes.hard_break ? '\n' : '');
  }

  function insertPlainText(selection, value) {
    const text = value.replace(/\r\n?|\n/g, '\n');
    if (!text) return false;
    const tr = closeHistory(view.state.tr.setSelection(selection));
    if (isCodeSelection(selection)) {
      tr.insertText(text);
    } else if (!text.includes('\n')) {
      tr.insertText(text.replaceAll('\t', '\u00a0\u00a0\u00a0\u00a0'));
    } else {
      const paragraphs = text.split('\n').map(line => line
        ? schema.nodes.paragraph.create(null, schema.text(line.replaceAll('\t', '\u00a0\u00a0\u00a0\u00a0')))
        : schema.nodes.blank_line.create());
      tr.replaceSelection(Slice.maxOpen(Fragment.fromArray(paragraphs)));
    }
    if (!tr.docChanged) return false;
    applyTransaction(tr.scrollIntoView(), { inputType: 'insertFromPaste' });
    return true;
  }

  function runHistory(dir) {
    if (!view || fenced || failed) return false;
    lastInputType = dir === 'undo' ? 'historyUndo' : 'historyRedo';
    const fn = dir === 'undo' ? pmUndo : pmRedo;
    const ok = fn(view.state, tr => applyTransaction(tr, { inputType: lastInputType }));
    if (ok) emitChangeIfNeeded();
    else lastInputType = '';
    return ok;
  }

  function installDOMListeners(targetRoot) {
    if (!listenersInstalledOnRoot.has(targetRoot)) {
      listenersInstalledOnRoot.add(targetRoot);
      targetRoot.addEventListener(
        'keydown',
        event => {
          if (event.isComposing) return;
          if (tables?.rejectOversizedTabAtDOM(event)) {
            event.preventDefault();
            event.stopImmediatePropagation();
            try {
              view?.domObserver?.observer?.takeRecords?.();
              if (Array.isArray(view?.domObserver?.queue)) view.domObserver.queue.length = 0;
              view?.domObserver?.stop?.();
              domObserverPausedForOversizedTable = true;
            } catch (_) {}
            return;
          }
          if (domObserverPausedForOversizedTable) {
            try { view?.domObserver?.start?.(); } catch (_) {}
            domObserverPausedForOversizedTable = false;
          }
          // DOM-Mutationen und -Auswahl VOR ProseMirrors `domObserver.forceFlush()`
          // auflösen, damit Caret und synthetische `<br>`-Änderungen konsistent bleiben (`4178`, `6510`).
          syncFromDOM();
          syncProseMirrorSelectionToDOM({ force: true });
        },
        true
      );
      targetRoot.addEventListener('pointerdown', () => {
        if (domObserverPausedForOversizedTable) {
          try { view?.domObserver?.start?.(); } catch (_) {}
          domObserverPausedForOversizedTable = false;
        }
      });
      targetRoot.addEventListener('mousedown', e => {
        if (e.button === 0) {
          selectingWithMouse = true;
          mouseDragStart = { x: e.clientX, y: e.clientY };
          mouseDragMoved = false;
          mouseDragHadButtons = false;
          try {
            const coords = view?.posAtCoords?.({ left: e.clientX, top: e.clientY });
            mouseDragAnchor = coords && typeof coords.pos === 'number' ? coords.pos : null;
          } catch (_) {
            mouseDragAnchor = null;
          }
        }
        clipboardSelectionGeneration++;
      });
      targetRoot.addEventListener('keydown', event => {
        if (
          ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown'].includes(event.key) ||
          ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a')
        ) {
          clipboardSelectionGeneration++;
        }
        if (event.metaKey || event.ctrlKey || ['Enter', 'Backspace', 'Delete', 'Tab'].includes(event.key)) {
          diagnostics.pushDiagnosticEvent('keydown', {
            key: sanitizeDiagnosticKey(event.key, !!(event.metaKey || event.ctrlKey)),
            meta: event.metaKey,
            ctrl: event.ctrlKey,
            shift: event.shiftKey,
            alt: event.altKey,
            sel: diagnostics.selectionSummary(view)
          });
        }
        if (!['Shift', 'Alt', 'Control', 'Meta'].includes(event.key)) {
          if (selectingWithMouse) {
            selectingWithMouse = false;
            reportTableContext();
          }
        }
      });
    }

    if (!globalListenersInstalled) {
      globalListenersInstalled = true;
      window.addEventListener('pagehide', event => {
        if (event.persisted) return;
        clearPendingEmitTimer();
        tables?.destroy();
        view?.destroy();
        tables = null;
        view = null;
      });
      // Synthetische AppKit-Drag-Events kommen in WebKit oft mit `buttons === 0` an;
      // ProseMirror bricht `MouseDown.move` dann sofort ab, deshalb hier nachführen.
      document.addEventListener(
        'mousemove',
        e => {
          if (!selectingWithMouse || fenced || composing || domObserverPausedForOversizedTable || !view || !root) return;
          if (e.buttons !== 0) {
            mouseDragHadButtons = true;
            return;
          }
          if (mouseDragHadButtons) {
            finishMouseSelection();
            return;
          }
          if (mouseDragAnchor === null || !mouseDragStart) return;
          if (!mouseDragMoved && Math.hypot(e.clientX - mouseDragStart.x, e.clientY - mouseDragStart.y) < 4) return;
          mouseDragMoved = true;
          try {
            const head = view.posAtCoords({ left: e.clientX, top: e.clientY });
            if (!head || typeof head.pos !== 'number') return;
            const doc = view.state.doc;
            const $anchor = doc.resolve(Math.max(0, Math.min(mouseDragAnchor, doc.content.size)));
            const $head = doc.resolve(Math.max(0, Math.min(head.pos, doc.content.size)));
            const sel = TextSelection.between($anchor, $head);
            if (!view.state.selection.eq(sel)) {
              view.dispatch(view.state.tr.setSelection(sel).setMeta('addToHistory', false));
              syncProseMirrorSelectionToDOM({ force: true });
              reportTableContext();
            }
          } catch (_) {}
        },
        true
      );
      const finishMouseSelection = () => {
        if (selectingWithMouse) {
          const didSyntheticDrag = mouseDragMoved;
          selectingWithMouse = false;
          mouseDragAnchor = null;
          mouseDragStart = null;
          mouseDragMoved = false;
          if (tables) tables.selectingWithMouse = false;
          if (didSyntheticDrag) {
            syncProseMirrorSelectionToDOM({ force: true });
          } else if (!(view?.state?.selection instanceof NodeSelection)) {
            syncDOMSelectionToProseMirror();
          }
          reportTableContext();
          requestAnimationFrame(() => {
            if (!selectingWithMouse && !fenced && !composing && !domObserverPausedForOversizedTable) {
              if (didSyntheticDrag) {
                syncProseMirrorSelectionToDOM({ force: true });
              } else if (!(view?.state?.selection instanceof NodeSelection)) {
                syncDOMSelectionToProseMirror();
              }
              reportTableContext();
            }
          });
        }
      };
      document.addEventListener('mouseup', finishMouseSelection, true);
      document.addEventListener('pointercancel', finishMouseSelection, true);
      document.documentElement.addEventListener('mouseleave', finishMouseSelection);
      document.addEventListener('selectionchange', () => {
        if (initializing || fenced || composing || selectingWithMouse || domObserverPausedForOversizedTable || !view || !root) return;
        if (view.state.selection instanceof NodeSelection) return;
        const winSel = document.getSelection?.();
        if (!winSel || !winSel.rangeCount || !root.contains(winSel.anchorNode)) return;
        syncDOMSelectionToProseMirror();
        reportTableContext();
      });
      window.addEventListener('blur', finishMouseSelection);
      window.addEventListener(
        'scroll',
        () => {
          if (viewportRestoring || viewportPending) return;
          viewportPending = true;
          requestAnimationFrame(() => {
            viewportPending = false;
            reportViewport();
          });
        },
        { passive: true }
      );
      for (const t of ['wheel', 'pointerdown', 'keydown']) {
        window.addEventListener(
          t,
          () => {
            viewportGeneration++;
            viewportRestoring = false;
          },
          { passive: true }
        );
      }
      if (!window.__fastraDiagnosticErrorsInstalled) {
        window.__fastraDiagnosticErrorsInstalled = true;
        window.addEventListener('error', ev => {
          diagnostics.recordAnomaly('js-error', String(ev.message || 'Unknown JS error'), {
            lineno: ev.lineno,
            colno: ev.colno
          });
        });
        window.addEventListener('unhandledrejection', ev => {
          diagnostics.recordAnomaly('js-rejection', String(ev.reason || 'Unhandled promise rejection'));
        });
      }
    }
  }

  window.fastraVisual = {
    tableContext() {
      return tables?.context?.() || null;
    },
    tableState() {
      return { revision, context: toolbarTableContext() };
    },
    tableCommand(name, value, token) {
      if (name !== 'insertTable') {
        const winSel = document.getSelection?.();
        const aNode = winSel?.anchorNode;
        const tableEl = (aNode?.nodeType === 1 ? aNode : aNode?.parentElement)?.closest?.('table');
        if (tableEl && root?.contains(tableEl) && (tableEl.getAttribute('data-md-table') !== 'gfm' || tableEl.querySelector('[colspan],[rowspan],table'))) {
          return { ok: false, reason: 'html' };
        }
      }
      syncFromDOM();
      view?.focus?.();
      const res = tables?.command?.(name, value, token);
      emitChangeIfNeeded();
      return res;
    },
    canUndo() {
      return view ? getHistoryState(view.state).canUndo : false;
    },
    canRedo() {
      return view ? getHistoryState(view.state).canRedo : false;
    },
    historyState() {
      return view ? getHistoryState(view.state) : { canUndo: false, canRedo: false, undoDepth: 0, redoDepth: 0 };
    },
    undo() {
      return runHistory('undo');
    },
    redo() {
      return runHistory('redo');
    },
    setFailed() {
      failed = true;
      updateFence();
    },
    outlinePosition,
    outlineSnapshot() {
      const nodes = outlineHeadings();
      if (nodes.length > 10000) return { ok: false, reason: 'limit' };
      const enc = new TextEncoder();
      let bytes = 0;
      const headings = [];
      for (const node of nodes) {
        const title = node.textContent.trim();
        const len = enc.encode(title).length;
        bytes += len;
        if (len > 16384 || bytes > 2097152) return { ok: false, reason: 'limit' };
        headings.push({ level: Number(node.tagName.slice(1)), title });
      }
      return { ok: true, session, revision, index: outlinePosition(), headings };
    },
    revealHeading(index) {
      if (composing || !view) return false;
      const headings = outlineHeadings();
      const heading = index >= 0 ? headings[index] : null;
      if (index >= 0 && !heading) return false;
      view.focus();
      if (heading) {
        try {
          const pos = view.posAtDOM(heading, 0);
          applyTransaction(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))), { allowFenced: true });
        } catch (_) {}
        heading.scrollIntoView?.({ block: 'center' });
      } else {
        applyTransaction(view.state.tr.setSelection(Selection.atStart(view.state.doc)), { allowFenced: true });
        window.scrollTo?.(0, 0);
      }
      return true;
    },
    async start(configuration) {
      if (failed) return false;
      initializing = true;
      const nextRoot = document.getElementById('fastra-visual');
      if (session !== configuration.session) {
        nativeActionIDs.clear();
        originals.clear();
        contexts.clear();
      }
      const sameMountedSession =
        !!view &&
        view.dom === nextRoot &&
        root === nextRoot &&
        session === configuration.session &&
        nextRoot?.classList?.contains('ProseMirror');

      session = configuration.session;
      root = nextRoot;
      lastReportedTableKey = null;
      updateFence();

      const until = Date.now() + 5000;
      while (!document.documentElement.hasAttribute('data-fastra-enhanced')) {
        if (Date.now() >= until) {
          failed = true;
          initializing = false;
          updateFence();
          return false;
        }
        await new Promise(r => setTimeout(r, 10));
      }

      clipboardLimit = configuration.clipboardLimit || 0;
      sourceReplacementEnabled = configuration.sourceReplacements === true;
      if (sourceReplacementEnabled) {
        sourceContextBytes = new TextEncoder().encode(configuration.markdown).length + root.innerHTML.length + 256;
      }

      if (sameMountedSession && serialize() === configuration.markdown) {
        await restoreViewport(configuration.viewport);
        initializing = false;
        updateFence();
        notifyHistoryAndOutline();
        return true;
      }

      base = configuration.markdown;
      originals.clear();
      contexts.clear();
      Object.keys(opaqueSources).forEach(k => delete opaqueSources[k]);
      Object.assign(opaqueSources, configuration.opaqueSources || {});

      root.querySelectorAll('img').forEach(img => {
        const token = img.getAttribute('src')?.split('/').pop();
        const tx = configuration.imageTransactions?.[token];
        if (tx) img.dataset.mdImageTransaction = tx;
      });

      const { doc, parsedGroups } = parseDocumentContainer(root, configuration.blocks, {
        schema,
        mdContext: '',
        ownerDocument: document
      });
      buildContextEntry(configuration, '', parsedGroups, originals, contexts, opaqueSources);

      createEditorView(doc, root);
      root.setAttribute('role', 'textbox');
      root.setAttribute('aria-multiline', 'true');
      installDOMListeners(root);

      lastImageTransactions = JSON.stringify(collectOrderedImageTransactions(view.state.doc));
      emittedEditorState = view.state;
      diagnostics.pushDiagnosticEvent('start', {
        blockCount: (configuration.blocks || []).length,
        markdownLen: base.length,
        empty: !base.length
      });

      if (serialize() !== base) {
        failed = true;
        initializing = false;
        updateFence();
        return false;
      }

      await restoreViewport(configuration.viewport);
      initializing = false;
      updateFence();
      root.focus({ preventScroll: true });
      notifyHistoryAndOutline();
      return true;
    },
    command(command, value) {
      if (fenced || !view) return false;
      if (domObserverPausedForOversizedTable) {
        try { view?.domObserver?.start?.(); } catch (_) {}
        domObserverPausedForOversizedTable = false;
      }
      if (command === 'delete') {
        lastInputType = 'deleteContentBackward';
      } else if (command !== 'undo' && command !== 'redo') {
        lastInputType = '';
      }
      syncFromDOM();
      const beforeTextLen = diagnostics.visibleTextLength();
      const selBefore = diagnostics.selectionSummary(view);
      const hadNonEmptySelection = !view.state.selection.empty;
      diagnostics.pushDiagnosticEvent('command', { command, beforeTextLen, sel: selBefore });

      try {
        const res = executeVisualCommand(view, command, value, {
          schema,
          tableEditor: tables,
          postMessage,
          session,
          onHistoryCommand: dir => runHistory(dir)
        });
        if (!res.executed) {
          if (!['protected', 'table', 'idempotent', 'empty-history'].includes(res.reason)) {
            diagnostics.recordAnomaly('command-noop', `Command ${command} had no effect`, { command });
          }
          return false;
        }
        syncProseMirrorSelectionToDOM({ force: true });
        const afterTextLen = diagnostics.visibleTextLength();
        const checkTextLoss = [
          'bold', 'italic', 'code', 'highlight', 'strike',
          'heading1', 'heading2', 'heading3', 'heading4', 'heading5', 'heading6',
          'plainParagraph', 'bulletList', 'orderedList', 'taskList', 'quote', 'link'
        ].includes(command) || (command === 'hardBreak' && !hadNonEmptySelection);
        emitChangeIfNeeded();
        if (checkTextLoss && afterTextLen < beforeTextLen) {
          diagnostics.recordAnomaly(
            'unexpected-text-loss',
            `Command ${command} reduced visible text (${beforeTextLen} -> ${afterTextLen})`,
            { command, beforeTextLen, afterTextLen }
          );
        }
        return true;
      } catch (err) {
        diagnostics.recordAnomaly('command-exception', `Command ${command} threw: ${err?.message || err}`, { command });
        throw err;
      }
    },
    refreshImageSources(addresses, transactions) {
      if (!view) return;
      for (const [srcKey, url] of Object.entries(addresses || {})) {
        if (typeof url === 'string' && url) imageUrlOverrides.set(srcKey, url);
      }
      const txMap = transactions && !Array.isArray(transactions) && typeof transactions === 'object' ? transactions : null;
      const txSet = Array.isArray(transactions) ? new Set(transactions) : null;
      const tr = view.state.tr.setMeta('addToHistory', false).setMeta('fastraAllowFenced', true);
      view.state.doc.descendants((node, pos) => {
        if (node.type.name === 'image') {
          const mdSrc = node.attrs.mdSrc;
          const oldSrc = node.attrs.src;
          const allowedBySet = !txSet || (node.attrs.imageTransaction && txSet.has(node.attrs.imageTransaction));
          const nextTx = (mdSrc && txMap?.[mdSrc]) || node.attrs.imageTransaction;
          const mappedSrc = allowedBySet
            ? (addresses?.[oldSrc] || (mdSrc && addresses?.[mdSrc]) || oldSrc)
            : oldSrc;
          if (oldSrc && mappedSrc && mappedSrc !== oldSrc) {
            imageUrlOverrides.set(oldSrc, mappedSrc);
          }
          if (nextTx !== node.attrs.imageTransaction || mappedSrc !== oldSrc) {
            tr.setNodeMarkup(pos, null, {
              ...node.attrs,
              src: mappedSrc,
              imageTransaction: nextTx
            });
          }
        }
        return true;
      });
      if (tr.docChanged) view.dispatch(tr);
      else applyDomImageOverridesOnImages(view.state.doc);
    },
    updateLocalImages(mapping) {
      if (!view || !mapping) return;
      const tr = view.state.tr.setMeta('addToHistory', false).setMeta('fastraAllowFenced', true);
      view.state.doc.descendants((node, pos) => {
        if (node.type.name !== 'image') return true;
        // Token im aktuellen Knoten-URI zuerst prüfen, Rohpfad nur als sekundäre
        // Gegenprobe nutzen, damit Undo alte Bildversionen nicht überschreibt (Sol #5).
        const token = extractUriToken(node.attrs.src);
        let entry = token ? mapping[token] : null;
        if (entry && typeof entry === 'object' && entry.raw && node.attrs.mdSrc && entry.raw !== node.attrs.mdSrc) {
          entry = null;
        }
        const nextUri = typeof entry === 'string' ? entry : entry?.uri;
        if (nextUri && nextUri !== node.attrs.src) {
          tr.setNodeMarkup(pos, null, { ...node.attrs, src: nextUri });
        }
        return true;
      });
      if (tr.docChanged) view.dispatch(tr);
    },
    exportClipboardHTML(key, replacements) {
      if (key !== clipboardBookmark || !copiedHTML) return null;
      const copy = copiedHTML.cloneNode(true);
      for (const img of copy.querySelectorAll('img')) {
        const data = replacements?.[img.getAttribute('src')];
        if (!data?.startsWith('data:image/')) return null;
        img.setAttribute('src', data);
      }
      return copy.innerHTML;
    },
    caretClipboard(x, y) {
      if (!view) return null;
      const coords = view.posAtCoords({ left: x, top: y });
      if (!coords) return null;
      applyTransaction(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(coords.pos))), { allowFenced: true });
      return window.fastraVisual.bookmarkClipboard();
    },
    caret(x, y) {
      if (!view) return null;
      const coords = view.posAtCoords({ left: x, top: y });
      if (!coords) return null;
      applyTransaction(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(coords.pos))), { allowFenced: true });
      return window.fastraVisual.bookmark();
    },
    bookmark(existing) {
      if (!view) return null;
      if (existing) return bookmarks.has(existing) ? existing : null;
      syncFromDOM();
      const key = String(++bookmarkID);
      bookmarks.set(key, {
        selectionJSON: view.state.selection.toJSON(),
        base: serialize()
      });
      return key;
    },
    bookmarkClipboard() {
      const key = window.fastraVisual.bookmark();
      const saved = bookmarks.get(key);
      if (saved) {
        saved.clipboardSelection = observeClipboardSelection();
        saved.clipboardSelectionGeneration = clipboardSelectionGeneration;
      }
      return key;
    },
    validateClipboardBookmark(key) {
      const saved = bookmarks.get(key);
      return !!saved && saved.base === serialize() && currentClipboardSelection(saved);
    },
    clipboardState() {
      const imageTransactions = view ? collectImageTransactions(view.state.doc) : [];
      return { markdown: serialize(), revision, imageTransactions };
    },
    discardBookmark(key) {
      return bookmarks.delete(key);
    },
    insertBookmarked(key, html, atoms, transaction, imageSources, singleLine = false, imageEnding = null) {
      if (fenced || !view) return false;
      const saved = bookmarks.get(key);
      bookmarks.delete(key);
      if (!saved || saved.base !== serialize() || !currentClipboardSelection(saved)) return false;

      const template = document.createElement('template');
      template.innerHTML = html;
      if (transaction) {
        template.content.querySelectorAll('img').forEach(n => {
          const src = n.getAttribute('src');
          if (!imageSources?.includes(src)) return;
          n.dataset.mdSrc = n.dataset.mdSrc || src;
          n.dataset.mdImageTransaction = transaction;
          if (imageEnding === 'crlf' || imageEnding === 'cr') n.dataset.mdImageEnding = imageEnding;
        });
      }

      const sel = Selection.fromJSON(view.state.doc, saved.selectionJSON);
      if (isCodeSelection(sel)) {
        if (transaction) return false;
        return insertPlainText(sel, clipboardPlainText(html));
      }
      const slice = buildPasteSlice(template.innerHTML);
      if (!slice) return false;
      const tr = closeHistory(view.state.tr.setSelection(sel));
      if (singleLine && tables?.context?.()) {
        const { $from, $to } = sel;
        if (tables.context().reason || !$from.sameParent($to) ||
            ![schema.nodes.table_cell, schema.nodes.table_header].includes($from.parent.type) ||
            !$from.parent.type.validContent(slice.content)) return false;
      }
      tr.replaceSelection(slice).scrollIntoView();
      if (!tr.docChanged) return false;
      Object.assign(opaqueSources, atoms || {});
      applyTransaction(tr, { inputType: 'insertFromPaste' });
      return true;
    },
    async replaceSource(expected, html, configuration, prefix) {
      if (!sourceReplacementEnabled || !view) return 'unsupported';
      if (composing || fenced) return 'busy';
      if (serialize() !== expected) return 'stale';
      const cost = new TextEncoder().encode(configuration.markdown).length + new TextEncoder().encode(html).length + 256;
      if (contexts.has(prefix) || sourceContextBytes + cost > MAX_SOURCE_CONTEXT_BYTES) return 'limit';

      const holder = document.createElement('div');
      holder.innerHTML = html;
      const ownedImages = new Map();
      view.state.doc.descendants(n => {
        if (n.type === schema.nodes.image && n.attrs.mdSrc && n.attrs.imageTransaction) {
          ownedImages.set(n.attrs.mdSrc, n.attrs.imageTransaction);
        }
        return true;
      });
      holder.querySelectorAll('img[data-md-src]').forEach(n => {
        const tx = ownedImages.get(n.getAttribute('data-md-src'));
        if (tx) n.dataset.mdImageTransaction = tx;
      });

      if (holder.querySelector('pre > code.language-mermaid') && window.fastraEnhanceMarkdown) {
        // Der Renderer benötigt verbundene DOM-Knoten, bevor ProseMirror sie als Atom übernimmt.
        const owner = view;
        const ownerSession = session;
        holder.style.cssText = 'position:fixed;left:-100000px;visibility:hidden;pointer-events:none';
        document.body.append(holder);
        try {
          await window.fastraEnhanceMarkdown(holder);
        } finally {
          holder.remove();
        }
        if (owner !== view || ownerSession !== session || composing || fenced ||
            serialize() !== expected || contexts.has(prefix) || sourceContextBytes + cost > MAX_SOURCE_CONTEXT_BYTES) return 'stale';
      }

      const { doc: parsedDoc, parsedGroups } = parseDocumentContainer(holder, configuration.blocks, {
        schema,
        mdContext: prefix,
        ownerDocument: document
      });

      // Probe in isolierten Hilfsmengen ausführen, damit ein fehlgeschlagenes
      // `replaceSource` weder `originals`, `opaqueSources` noch das Bytebudget belastet (Astra #12).
      const trialContexts = new Map(contexts);
      const trialOriginals = new Map(originals);
      const trialOpaque = Object.assign(Object.create(null), opaqueSources);
      buildContextEntry(configuration, prefix, parsedGroups, trialOriginals, trialContexts, trialOpaque);

      const trial = serializeDocument(parsedDoc, {
        contexts: trialContexts,
        originals: trialOriginals,
        opaqueSources: trialOpaque
      });
      if (trial !== configuration.markdown) {
        return 'incomplete';
      }

      const confirmedContext = trialContexts.get(prefix);
      contexts.set(prefix, confirmedContext);
      for (const [k, v] of trialOriginals.entries()) originals.set(k, v);
      Object.assign(opaqueSources, trialOpaque);
      sourceContextBytes += cost;

      const prevDoc = view.state.doc;
      const tr = view.state.tr;
      tr.replaceWith(0, prevDoc.content.size, parsedDoc.content);
      tr.setDocAttribute('sourceContext', prefix);
      tr.setSelection(Selection.atStart(tr.doc));
      applyTransaction(closeHistory(tr), { inputType: 'replaceSource' });

      if (serialize() !== configuration.markdown) {
        actionFenced = true;
        updateFence();
        return 'insert';
      }
      return true;
    },
    requestClipboardCopy(cut = false) {
      if (!view) return;
      syncDOMSelectionToProseMirror();
      view.focus();
      (view.dom || root)?.dispatchEvent(new Event(cut ? 'cut' : 'copy', { bubbles: true, cancelable: true }));
    },
    requestClipboardPaste(plain = false) {
      if (!fenced) {
        postMessage({
          kind: 'linuxPaste',
          session,
          bookmark: window.fastraVisual.bookmarkClipboard(),
          plain
        });
      }
    },
    inspectClipboardHTML(html) {
      const cleaned = inspectAndCleanClipboardHTML(html, true, document);
      if (cleaned.ok && cleaned.images.length) {
        const nodes = parseHTMLToNodes(cleaned.html, { schema, ownerDocument: document });
        const doc = schema.nodes.doc.create(null, nodes.length ? nodes : undefined);
        const markdown = serializeDocument(doc, { contexts: new Map(), originals: new Map(), opaqueSources });
        return {
          ok: true,
          markdown,
          url: 'file:///fastra-html-clipboard/Clipboard.md',
          images: cleaned.images
        };
      }
      return cleaned;
    },
    insertClipboardHTML(key, html) {
      const cleaned = inspectAndCleanClipboardHTML(html, false, document);
      if (!cleaned.ok) {
        bookmarks.delete(key);
        return cleaned;
      }
      return {
        ok: window.fastraVisual.insertBookmarked(key, cleaned.html, {}, null, [], false),
        reason: 'stale'
      };
    },
    insertClipboardText(key, text) {
      const saved = bookmarks.get(key);
      bookmarks.delete(key);
      if (fenced || !view || !saved || saved.base !== serialize() || !currentClipboardSelection(saved)) return false;
      const sel = Selection.fromJSON(view.state.doc, saved.selectionJSON);
      if (!text) return false;
      if (!view.state.selection.eq(sel)) view.dispatch(view.state.tr.setSelection(sel));
      const tableResult = tables?.pasteText(text);
      return tableResult ?? insertPlainText(sel, text);
    },
    cancelClipboard() {
      if (clipboardBookmark !== null) {
        window.fastraVisual.completeClipboard(clipboardBookmark, false, false);
      }
    },
    completeClipboard(key, cut, succeeded) {
      if (key !== clipboardBookmark || !view) return false;
      const saved = bookmarks.get(key);
      bookmarks.delete(key);
      const unchanged = saved && saved.base === serialize();
      copiedHTML = null;
      clipboardBookmark = null;
      updateFence();
      if (cut && succeeded && unchanged) {
        const sel = Selection.fromJSON(view.state.doc, saved.selectionJSON);
        if (!sel.empty) {
          applyTransaction(view.state.tr.setSelection(sel).deleteSelection().scrollIntoView(), { inputType: 'deleteByCut' });
        }
      }
      return !!unchanged;
    },
    async updateStyle(font, size, dark) {
      document.body.style.setProperty('--fastra-copy-border', dark ? '#484848' : '#D7D7D7');
      document.body.style.setProperty('--fastra-copy-background', dark ? '#333333' : '#ECECEC');
      let sheet = document.getElementById('fastra-visual-style');
      if (!sheet) {
        sheet = document.createElement('style');
        sheet.id = 'fastra-visual-style';
        document.head.append(sheet);
      }
      const family = font === 'System'
        ? '-apple-system, BlinkMacSystemFont, sans-serif'
        : `${JSON.stringify(font)}, -apple-system, sans-serif`;
      sheet.textContent =
        `body{font-family:${family};font-size:${size}px;color:${dark ? '#F2F2F2' : '#363636'};background:${dark ? '#171717' : '#FFFFFF'}}` +
        `h1,h2,h3,h4,h5,h6{color:inherit}` +
        `blockquote,pre.mermaid-error::before{color:${dark ? '#A8A8A8' : '#737373'}}` +
        `a{color:${dark ? '#8BB7F2' : '#3F69A8'}}` +
        `code,pre{background:${dark ? '#333333' : '#ECECEC'}}` +
        `td,th,blockquote,hr{border-color:${dark ? '#484848' : '#D7D7D7'}}` +
        `mark{background:${dark ? '#665200' : '#FFEE9A'};color:inherit}`;
      window.fastraMarkdownPresentation?.update?.();
      await window.fastraUpdateMarkdownTheme?.(root, dark);
      window.fastraMarkdownPresentation?.update?.();
    },
    prepareAction(expectedSession, actionID, retryAfterComposition = false) {
      const isNative = arguments.length !== 0;
      if (isNative && (arguments.length < 2 || arguments.length > 3 || expectedSession !== session || typeof actionID !== 'string' || !actionID.length || nativeActionIDs.has(actionID))) {
        return null;
      }
      if (initializing || failed) return null;
      if (composing) {
        if (retryAfterComposition) notifyCompositionEnd = true;
        return { composing: true };
      }
      // Ausstehende DOM-Eingaben synchron einlesen, BEVOR die Sperre aktiviert wird (Astra #4).
      syncFromDOM();
      emitChangeIfNeeded();

      if (isNative) nativeActionIDs.add(actionID);
      else actionFenced = true;
      if (clipboardBookmark !== null) {
        bookmarks.delete(clipboardBookmark);
        clipboardBookmark = null;
      }
      updateFence();

      const imageTransactions = view ? collectImageTransactions(view.state.doc) : [];
      const snapshot = {
        markdown: serialize(),
        revision,
        imageTransactions,
        inputType: emittedInputType,
        imageFenceRevision,
        viewport: viewportPosition(),
        historyState: view ? getHistoryState(view.state) : { canUndo: false, canRedo: false, undoDepth: 0, redoDepth: 0 }
      };
      if (isNative) {
        snapshot.session = session;
        snapshot.actionID = actionID;
      }
      return snapshot;
    },
    compareSaveAppearance(expectedSession, actionID, expectedRevision, html) {
      if (expectedSession !== session || !nativeActionIDs.has(actionID) || revision !== expectedRevision) return null;
      return diagnostics.compareSave(html);
    },
    inspectAppearance(expectedSession, expectedRevision, html) {
      if (expectedSession !== session || revision !== expectedRevision) return null;
      return diagnostics.inspect(html);
    },
    diagnosticReport(includeContent = false) {
      return diagnostics.report(includeContent);
    },
    completeAction(expectedSession, actionID) {
      if (expectedSession !== session) return;
      if (arguments.length === 1) {
        actionFenced = false;
      } else {
        if (arguments.length !== 2 || typeof actionID !== 'string' || !actionID.length || !nativeActionIDs.delete(actionID)) {
          return;
        }
      }
      updateFence();
    },
    completeImageAction(expectedSession, expectedRevision) {
      if (expectedSession !== session || expectedRevision !== imageFenceRevision) return;
      imageFenceRevision = null;
      lastPreOpSnapshot = null;
      updateFence();
    },
    rollbackImageChange(expectedRevision, previous) {
      if (!view || expectedRevision !== imageFenceRevision) return false;
      if (lastPreOpSnapshot?.revision === expectedRevision && lastPreOpSnapshot.markdown === previous) {
        // Exakten EditorState inkl. Doc, Selection & History atomar wiederherstellen (Astra #14).
        view.updateState(lastPreOpSnapshot.editorState);
        emittedEditorState = view.state;
        base = previous;
        lastImageTransactions = JSON.stringify(collectOrderedImageTransactions(view.state.doc));
        lastPreOpSnapshot = null;
        lastInputType = '';
        updateFence();
        notifyHistoryAndOutline();
        return true;
      }
      return false;
    },
    viewport: viewportPosition,
    markdown: serialize,
    flush: () => {
      flushingDom = true;
      try {
        syncFromDOM();
        if (view && root && (fenced || !view.editable)) {
          // Während aktiver Sperre (`editable: false`) stoppt ProseMirror den DOMObserver;
          // direkte DOM-Bildentfernungen vor `flush()` gezielt nachsynchronisieren (`5334`).
          const liveTx = new Set(
            Array.from(root.querySelectorAll('img[data-md-image-transaction]'), n => n.dataset.mdImageTransaction)
          );
          const missingRanges = [];
          view.state.doc.descendants((node, pos) => {
            if (node.type === schema.nodes.image && node.attrs.imageTransaction && !liveTx.has(node.attrs.imageTransaction)) {
              missingRanges.push([pos, pos + node.nodeSize]);
            }
            return true;
          });
          if (missingRanges.length) {
            const tr = view.state.tr;
            for (let i = missingRanges.length - 1; i >= 0; i--) {
              tr.delete(missingRanges[i][0], missingRanges[i][1]);
            }
            applyTransaction(tr, { allowFenced: true });
          }
        }
      } finally {
        flushingDom = false;
      }
      emitChangeIfNeeded();
    }
  };

  return window.fastraVisual;
}
