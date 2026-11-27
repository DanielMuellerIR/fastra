/**
 * ProseMirror-NodeViews für Task-Checkboxen, Bilder, Formeln (KaTeX) und
 * opake Originalblöcke (z. B. Mermaid-SVGs oder eingebettetes Roh-HTML).
 * Wichtig: Render-Ergebnisse (KaTeX, Mermaid) leben innerhalb geschützter DOM-Hüllen,
 * sodass ProseMirrors Textmodell sauber auf den ursprünglichen Attributen beruht.
 */

function applyImageNodeAttrs(img, node, imageUrlOverrides) {
  const mdSrc = node.attrs.mdSrc;
  const resolvedSrc =
    (node.attrs.src && imageUrlOverrides.get(node.attrs.src)) ||
    node.attrs.src ||
    (mdSrc && imageUrlOverrides.get(mdSrc)) ||
    '';
  img.setAttribute('src', resolvedSrc);
  img.setAttribute('alt', node.attrs.alt || '');
  if (mdSrc != null) img.setAttribute('data-md-src', mdSrc);
  else img.removeAttribute('data-md-src');

  if (node.attrs.title != null && node.attrs.title !== '') img.setAttribute('title', node.attrs.title);
  else img.removeAttribute('title');

  if (node.attrs.width != null && node.attrs.width !== '') img.setAttribute('width', String(node.attrs.width));
  else img.removeAttribute('width');

  if (node.attrs.height != null && node.attrs.height !== '') img.setAttribute('height', String(node.attrs.height));
  else img.removeAttribute('height');

  if (node.attrs.imageTransaction) img.setAttribute('data-md-image-transaction', node.attrs.imageTransaction);
  else img.removeAttribute('data-md-image-transaction');

  if (node.attrs.imageEnding) img.setAttribute('data-md-image-ending', node.attrs.imageEnding);
  else img.removeAttribute('data-md-image-ending');
}

function setMathSource(dom, key) {
  if (key) dom.setAttribute('data-md-math-source', key);
  else dom.removeAttribute('data-md-math-source');
}

function mathNodeView(node, view) {
  let current = node;
  const document = view.dom.ownerDocument;
  const inline = node.isInline;
  const dom = document.createElement(inline ? 'span' : 'div');
  dom.setAttribute('contenteditable', 'false');

  function render(target) {
    const { tex, mathSourceKey, displayMode } = target.attrs;
    const display = !inline || !!displayMode;
    dom.className = display ? 'math-block' : 'math-inline';
    dom.setAttribute('data-tex', tex || '');
    setMathSource(dom, mathSourceKey);
    const katex = document.defaultView?.katex;
    if (katex) {
      try {
        katex.render(tex || '', dom, { displayMode: display, throwOnError: false, trust: false });
        dom.setAttribute('data-rendered', 'true');
        return;
      } catch (_) {
        // Bei einem Renderfehler bleibt die TeX-Quelle sichtbar.
      }
    }
    dom.removeAttribute('data-rendered');
    dom.textContent = tex || '';
  }

  render(node);
  return {
    dom,
    update(updated) {
      if (updated.type !== current.type) return false;
      if (updated.attrs.tex !== current.attrs.tex ||
          updated.attrs.mathSourceKey !== current.attrs.mathSourceKey ||
          updated.attrs.displayMode !== current.attrs.displayMode) render(updated);
      current = updated;
      return true;
    },
    ignoreMutation() { return true; }
  };
}

function opaqueNodeView(node, view) {
  let current = node;
  const dom = view.dom.ownerDocument.createElement(node.attrs.tag || (node.isInline ? 'span' : 'section'));
  dom.setAttribute('contenteditable', 'false');

  function render(target) {
    if (target.attrs.className) dom.className = target.attrs.className;
    else dom.removeAttribute('class');
    dom.setAttribute('data-md-opaque', target.attrs.opaqueKey || '');
    setMathSource(dom, target.attrs.mathSourceKey);
    // Geschützte Renderer-Fragmente umgehen den Clipboard-Parser, der interne Attribute entfernt.
    const html = target.attrs.rawHTML || '';
    if (dom.innerHTML !== html) dom.innerHTML = html;
  }

  render(node);
  return {
    dom,
    update(updated) {
      if (updated.type !== current.type || updated.attrs.tag !== current.attrs.tag) return false;
      render(updated);
      current = updated;
      return true;
    },
    ignoreMutation() { return true; }
  };
}

export function createNodeViews({
  getImageOverrides,
  isBlocked,
  onSelectImage,
  onToggleTask
}) {
  return {
    list_item(node, view, getPos) {
      let current = node;
      const doc = view.dom.ownerDocument;
      const dom = doc.createElement('li');
      const isInitialTask = node.attrs.task !== null;

      if (!isInitialTask) {
        return {
          dom,
          contentDOM: dom,
          update(updated) {
            if (updated.type !== current.type) return false;
            if (updated.attrs.task !== null) return false;
            current = updated;
            return true;
          },
          ignoreMutation(mutation) {
            return mutation.target === dom && mutation.type === 'attributes';
          }
        };
      }

      const checkbox = doc.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.contentEditable = 'false';

      const contentDOM = doc.createElement('div');
      contentDOM.className = 'fastra-pm-li-content';

      function sync(target) {
        current = target;
        dom.setAttribute('data-task', target.attrs.task ? 'checked' : 'unchecked');
        checkbox.toggleAttribute('checked', !!target.attrs.task);
        checkbox.checked = !!target.attrs.task;
        if (checkbox.parentNode !== dom) dom.prepend(checkbox);
        dom.insertBefore(contentDOM, checkbox.nextSibling);
      }

      checkbox.addEventListener('mousedown', e => {
        e.preventDefault();
      });
      checkbox.addEventListener('click', e => {
        e.preventDefault();
        e.stopPropagation();
        if (isBlocked()) {
          checkbox.checked = !!current.attrs.task;
          return;
        }
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos == null || current.attrs.task === null) {
          checkbox.checked = !!current.attrs.task;
          return;
        }
        onToggleTask?.(pos, !current.attrs.task);
        // Browser-Klickaktivierung setzt checkbox.checked teils verzögert zurück;
        // DOM-Status am Ende der Mikro-Aufgabe strikt auf ProseMirror abgleichen.
        queueMicrotask(() => {
          checkbox.checked = !!current.attrs.task;
        });
      });

      sync(node);

      return {
        dom,
        contentDOM,
        update(updated) {
          if (updated.type !== current.type) return false;
          if (updated.attrs.task === null) return false;
          sync(updated);
          return true;
        },
        ignoreMutation(mutation) {
          return mutation.target === checkbox || mutation.target === dom && mutation.type === 'attributes';
        },
        stopEvent(event) {
          return event.target === checkbox;
        }
      };
    },

    image(node, view, getPos) {
      let current = node;
      const dom = view.dom.ownerDocument.createElement('img');
      applyImageNodeAttrs(dom, current, getImageOverrides());

      return {
        dom,
        update(updated) {
          if (updated.type !== current.type) return false;
          current = updated;
          applyImageNodeAttrs(dom, current, getImageOverrides());
          return true;
        },
        selectNode() {
          dom.setAttribute('data-md-selected-image', '');
          onSelectImage?.(dom, getPos);
        },
        deselectNode() {
          dom.removeAttribute('data-md-selected-image');
        },
        ignoreMutation() {
          return true;
        }
      };
    },

    math_block: mathNodeView,
    math_inline: mathNodeView,
    opaque_block: opaqueNodeView,
    opaque_inline: opaqueNodeView
  };
}
