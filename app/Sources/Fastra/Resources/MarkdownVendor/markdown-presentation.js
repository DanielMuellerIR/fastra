(() => {
  const copyIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2"/><path d="M13 5V3H3v10h2"/></svg>';
  const copiedIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m4 10 4 4 8-9"/></svg>';
  let controls, scheduled = false, serial = 0;
  const buttons = new Map(), requests = new Map();
  const labels = () => window.fastraMarkdownCopyLabels;

  function refresh() {
    scheduled = false;
    if (!controls?.isConnected) {
      controls = document.createElement('div'); controls.id = 'fastra-code-controls';
      controls.contentEditable = 'false'; document.body.append(controls);
    }
    const live = new Set(document.querySelectorAll('pre:has(> code)'));
    for (const [pre, button] of buttons) {
      if (!live.has(pre)) { button.remove(); buttons.delete(pre); }
    }
    for (const pre of live) {
      let button = buttons.get(pre);
      if (!button) {
        button = document.createElement('button');
        button.type = 'button'; button.className = 'fastra-code-copy';
        button.title = labels().copy; button.setAttribute('aria-label', labels().copy);
        button.innerHTML = copyIcon;
        // Der Knopf gehört zur Ansicht, niemals zum bearbeitbaren Markdown-DOM.
        button.addEventListener('mousedown', event => event.preventDefault());
        button.addEventListener('click', event => {
          event.preventDefault(); event.stopPropagation();
          const code = pre.querySelector(':scope > code');
          const bridge = window.webkit?.messageHandlers?.markdownCodeCopy;
          if (!pre.isConnected || !code || !bridge) return;
          const request = ++serial;
          requests.set(request, button);
          bridge.postMessage({ text: code.textContent, request });
        });
        buttons.set(pre, button); controls.append(button);
      }
      const rect = pre.getBoundingClientRect();
      const tableRect = pre.closest('table')?.getBoundingClientRect();
      const right = Math.min(rect.right, tableRect?.right ?? innerWidth, innerWidth);
      const left = Math.max(rect.left, tableRect?.left ?? 0, 0);
      button.hidden = rect.bottom < 0 || rect.top > innerHeight || right - left < 48;
      button.style.left = (scrollX + right - 36) + 'px';
      button.style.top = (scrollY + rect.top + 8) + 'px';
    }
  }
  function update() {
    if (scheduled) return;
    // requestAnimationFrame pausiert in ausgeblendeten Fenstern. Auch dort
    // muss eine neue Dokumentfassung ihre eigenen Bedienelemente erhalten.
    scheduled = true; setTimeout(refresh, 0);
  }
  function didCopy(request, copied) {
    const button = requests.get(request); requests.delete(request);
    if (!button?.isConnected) return;
    button.innerHTML = copied ? copiedIcon : copyIcon;
    button.title = copied ? labels().copied : labels().failed;
    button.setAttribute('aria-label', button.title);
    const revision = String(request); button.dataset.copyRevision = revision;
    setTimeout(() => {
      if (!button.isConnected || button.dataset.copyRevision !== revision) return;
      button.innerHTML = copyIcon; button.title = labels().copy;
      button.setAttribute('aria-label', labels().copy);
    }, 1800);
  }
  window.fastraMarkdownPresentation = { update, didCopy,
    focusedCode: () => Array.from(buttons).find(([, button]) => button === document.activeElement)?.[0],
    focusCode: pre => { refresh(); buttons.get(pre)?.focus({ preventScroll: true }); }
  };
  addEventListener('DOMContentLoaded', () => {
    controls = document.createElement('div'); controls.id = 'fastra-code-controls';
    controls.contentEditable = 'false'; document.body.append(controls);
    new MutationObserver(records => {
      if (records.some(record => !controls.contains(record.target))) update();
    }).observe(document.body, { childList: true, subtree: true, characterData: true });
    new ResizeObserver(update).observe(document.body);
    addEventListener('resize', update); addEventListener('scroll', update, true);
    update();
  });
})();
