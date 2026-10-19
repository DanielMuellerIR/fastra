(() => {
  let records = [], serial = 0;
  const sourceAttribute = 'data-srcline', positionAttribute = 'data-fastra-position';
  const controls = node => node.nodeType === 1 && node.id === 'fastra-code-controls';
  function elements(node, attribute) {
    if (node.nodeType !== 1) return [];
    return (node.hasAttribute(attribute) ? [node] : []).concat(Array.from(node.querySelectorAll('[' + attribute + ']')));
  }
  function describe(group) {
    const markers = group.flatMap(node => elements(node, sourceAttribute));
    const positions = markers.map(element => element.getAttribute(sourceAttribute));
    markers.forEach(element => element.removeAttribute(sourceAttribute));
    const signature = JSON.stringify(group.map(node => [node.nodeType, node.nodeType === 1 ? node.outerHTML : node.textContent]));
    markers.forEach((element, index) => element.setAttribute(sourceAttribute, positions[index]));
    const root = group[0];
    return { nodes: group, positions, markers, tag: root.nodeType === 1 ? root.tagName : String(root.nodeType), signature };
  }
  function descriptions(nodes) {
    const groups = [];
    // cmarks Trenn-Newlines gehören zum vorherigen Block. Eigene Identitäten
    // und Grenzknoten für jedes Leerraum-Textobjekt verdoppelten den DOM-Aufwand.
    for (const node of nodes) {
      if (node.nodeType === 1 || !groups.length) groups.push([node]);
      else groups[groups.length - 1].push(node);
    }
    return groups.map(describe);
  }
  function mark(description) {
    description.markers.forEach((element, index) => element.setAttribute(positionAttribute, String(index)));
  }
  function create(description) {
    const id = ++serial, start = document.createComment('fastra-block-' + id), end = document.createComment('/fastra-block-' + id);
    const fragment = document.createDocumentFragment();
    mark(description); fragment.append(start);
    description.nodes.forEach(node => fragment.appendChild(node)); fragment.append(end);
    return { id, start, end, signature: description.signature, tag: description.tag };
  }
  function nodes(record) {
    const result = [];
    for (let node = record.start.nextSibling; node && node !== record.end; node = node.nextSibling) result.push(node);
    return result;
  }
  function textOf(record) {
    return nodes(record).filter(node => node.nodeType !== 8).map(node => node.textContent).join('');
  }
  function rect(record) {
    const element = nodes(record).find(node => node.nodeType === 1);
    return element?.getBoundingClientRect();
  }
  function setPositions(record, description) {
    const marked = nodes(record).flatMap(node => elements(node, positionAttribute));
    const indexes = marked.map(element => Number(element.getAttribute(positionAttribute)));
    // Während Mermaid arbeitet, existieren Original und Ersatz kurz gemeinsam.
    // Beide gehören zu derselben Quellposition und müssen erhalten bleiben.
    if (new Set(indexes).size !== description.positions.length || indexes.some(index => {
      return !Number.isInteger(index) || index < 0 || index >= description.positions.length;
    })) return false;
    marked.forEach(element => {
      const line = description.positions[Number(element.getAttribute(positionAttribute))];
      if (element.getAttribute(sourceAttribute) !== line) element.setAttribute(sourceAttribute, line);
    });
    return true;
  }
  function replace(record, description) {
    nodes(record).forEach(node => node.remove());
    const fragment = document.createDocumentFragment();
    mark(description); description.nodes.forEach(node => fragment.appendChild(node)); record.end.before(fragment);
    record.signature = description.signature; record.tag = description.tag;
  }
  function remove(record) {
    let node = record.start;
    while (node) {
      const next = node.nextSibling; node.remove();
      if (node === record.end) break;
      node = next;
    }
  }
  function move(record, before) {
    if (record.start === before) return;
    const fragment = document.createDocumentFragment();
    for (let node = record.start; node;) {
      const next = node.nextSibling; fragment.append(node);
      if (node === record.end) break;
      node = next;
    }
    document.body.insertBefore(fragment, before);
  }
  function initialize() {
    if (records.length && records.every(record => record.start.parentNode === document.body && record.end.parentNode === document.body)) return;
    records = [];
    Array.from(document.body.childNodes).filter(node => node.nodeType === 8 && /^\/?fastra-block-[0-9]+$/.test(node.data)).forEach(node => node.remove());
    const original = Array.from(document.body.childNodes).filter(node => !controls(node));
    records = descriptions(original).map(description => {
      const after = description.nodes[description.nodes.length - 1].nextSibling, record = create(description);
      move(record, after); return record;
    });
  }
  function bookmark(node, offset, texts) {
    if (!node) return null;
    if (node === document.body) {
      if (offset === 0) return { boundary: 'start' };
      if (offset >= node.childNodes.length) return { boundary: 'end' };
      const child = node.childNodes[offset];
      const at = records.find(record => child === record.start || child === record.end || nodes(record).includes(child));
      if (at) {
        const range = document.createRange(); range.setStartAfter(at.start);
        if (!texts.has(at.id)) texts.set(at.id, textOf(at));
        if (child === at.start) return { id: at.id, textOffset: 0, text: texts.get(at.id) };
        range.setEnd(node, offset);
        return { id: at.id, textOffset: range.toString().length, text: texts.get(at.id) };
      }
      return { boundary: 'end' };
    }
    const record = records.find(record => nodes(record).some(root => root === node || root.contains(node)));
    if (!record) return { node, offset };
    const range = document.createRange(); range.setStartAfter(record.start);
    try { range.setEnd(node, offset); } catch (_) { return null; }
    if (!texts.has(record.id)) texts.set(record.id, textOf(record));
    return { node, offset, id: record.id, textOffset: range.toString().length, text: texts.get(record.id) };
  }
  function changedOffset(before, after, offset) {
    let prefix = 0, suffix = 0;
    while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix++;
    while (suffix < before.length - prefix && suffix < after.length - prefix
      && before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix++;
    if (offset <= prefix) return offset;
    if (offset >= before.length - suffix) return offset + after.length - before.length;
    return prefix + Math.min(offset - prefix, after.length - prefix - suffix);
  }
  function locate(bookmark, texts) {
    if (!bookmark) return null;
    if (bookmark.boundary) return { node: document.body, offset: bookmark.boundary === 'start' ? 0 : document.body.childNodes.length };
    if (bookmark.node?.isConnected) return bookmark;
    const record = records.find(record => record.id === bookmark.id);
    if (!record) return null;
    if (!texts.has(record.id)) texts.set(record.id, textOf(record));
    let remaining = changedOffset(bookmark.text, texts.get(record.id), bookmark.textOffset), last;
    for (const root of nodes(record)) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let text = root.nodeType === 3 ? root : walker.nextNode();
      while (text) {
        last = text;
        if (remaining <= text.length) return { node: text, offset: remaining };
        remaining -= text.length; text = walker.nextNode();
      }
    }
    return last ? { node: last, offset: last.length } : { node: record.end.parentNode, offset: Array.from(record.end.parentNode.childNodes).indexOf(record.end) };
  }
  function restoreSelection(saved) {
    if (!saved) return;
    const texts = new Map(), anchor = locate(saved.anchor, texts), focus = locate(saved.focus, texts);
    if (!anchor || !focus) return;
    try { getSelection().setBaseAndExtent(anchor.node, anchor.offset, focus.node, focus.offset); } catch (_) {}
  }
  function rememberScroll() {
    const anchors = [];
    const visible = records.filter(record => /^[A-Z]/.test(record.tag));
    let low = 0, high = visible.length;
    while (low < high) {
      const middle = (low + high) >>> 1, bounds = rect(visible[middle]);
      if (!bounds || bounds.bottom <= 0) low = middle + 1;
      else high = middle;
    }
    for (let index = low; index < visible.length && anchors.length < 4; index++) {
      const record = visible[index], bounds = rect(record);
      if (bounds && bounds.top >= innerHeight) break;
      if (bounds && bounds.bottom > 0) anchors.push({ id: record.id, top: bounds.top });
    }
    return { x: scrollX, y: scrollY, anchors };
  }
  function restoreScroll(saved) {
    for (const anchor of saved.anchors) {
      const record = records.find(record => record.id === anchor.id), bounds = record && rect(record);
      if (bounds) { scrollTo(saved.x, scrollY + bounds.top - anchor.top); return; }
    }
    scrollTo(saved.x, saved.y);
  }
  function reconcile(descriptions) {
    const pools = new Map(), used = new Set();
    records.forEach((record, index) => {
      record.oldIndex = index;
      const queue = pools.get(record.signature) || { items: [], index: 0 }; queue.items.push(record); pools.set(record.signature, queue);
    });
    const next = descriptions.map(description => {
      const pool = pools.get(description.signature), record = pool?.items[pool.index++];
      if (record) used.add(record);
      return record || null;
    });
    // Gleiche Nachbarn begrenzen eine eindeutige lokale Bearbeitung. Bei
    // mehrdeutigen Einfügungen/Löschungen wird keine alte Identität geraten.
    for (let index = 0; index < next.length;) {
      if (next[index]) { index++; continue; }
      const begin = index;
      while (index < next.length && !next[index]) index++;
      const oldBegin = begin > 0 ? next[begin - 1].oldIndex + 1 : 0;
      const oldEnd = index < next.length ? next[index].oldIndex : records.length;
      const candidates = oldEnd - oldBegin === index - begin ? records.slice(oldBegin, oldEnd) : [];
      if (candidates.length === index - begin && candidates.every((record, offset) => !used.has(record) && record.tag === descriptions[begin + offset].tag)) {
        candidates.forEach((record, offset) => { next[begin + offset] = record; used.add(record); });
      }
    }
    let changed = 0, reused = 0;
    next.forEach((record, index) => {
      const description = descriptions[index];
      if (!record) { next[index] = create(description); changed++; }
      else if (record.signature !== description.signature || !setPositions(record, description)) { replace(record, description); changed++; }
      else reused++;
    });
    let cursor = document.body.firstChild;
    for (const record of next) { move(record, cursor); cursor = record.end.nextSibling; }
    records.filter(record => !used.has(record)).forEach(remove);
    records = next;
    return { changed, reused, blocks: records.length };
  }
  async function update(html) {
    initialize();
    const selection = getSelection(), texts = new Map();
    let savedSelection = selection?.rangeCount ? { anchor: bookmark(selection.anchorNode, selection.anchorOffset, texts), focus: bookmark(selection.focusNode, selection.focusOffset, texts) } : null;
    let focusedCode = window.fastraMarkdownPresentation?.focusedCode();
    const focusedID = focusedCode && records.find(record => nodes(record).some(root => root === focusedCode || root.contains(focusedCode)))?.id;
    const savedScroll = rememberScroll();
    const generation = window.markdownGeneration = (window.markdownGeneration || 0) + 1;
    const template = document.createElement('template'); template.innerHTML = html;
    const incoming = descriptions(Array.from(template.content.childNodes));
    const metrics = reconcile(incoming);
    // KaTeX und Syntaxfarben verändern Textknoten synchron. Erst danach lässt
    // sich die alte Auswahl auf unveränderte Textteile des neuen Blocks legen.
    const enhancing = window.fastraEnhanceMarkdown(document.body);
    restoreSelection(savedSelection); restoreScroll(savedScroll);
    if (focusedID && !focusedCode.isConnected) {
      const current = records.find(record => record.id === focusedID);
      const pre = current && nodes(current).flatMap(root => root.nodeType === 1
        ? (root.matches('pre:has(> code)') ? [root] : []).concat(Array.from(root.querySelectorAll('pre:has(> code)'))) : [])[0];
      if (pre) window.fastraMarkdownPresentation?.focusCode(pre);
    }
    const immediate = { x: scrollX, y: scrollY };
    // Ein langsames Diagramm darf weder den vollständigen HTML-Zwischenstand
    // noch alte Auswahltexte und entfernte Codeblöcke am Leben halten.
    template.content.replaceChildren(); incoming.length = 0; texts.clear();
    html = null; savedSelection = null; focusedCode = null;
    await enhancing;
    if (generation !== window.markdownGeneration) return metrics;
    // Während Mermaid arbeitet, dürfen ein neuer Sprung oder echtes Scrollen
    // den gemerkten Ausschnitt ablösen.
    if (scrollX === immediate.x && scrollY === immediate.y) restoreScroll(savedScroll);
    window.fastraMarkdownPresentation?.update();
    return metrics;
  }
  window.fastraPreviewBlocks = { initialize, update,
    identities: () => records.map(record => ({ id: record.id, tag: record.tag, text: nodes(record).map(node => node.textContent).join('') })) };
})();
