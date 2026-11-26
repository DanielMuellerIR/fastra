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

    math_block(node, view) {
      let current = node;
      const doc = view.dom.ownerDocument;
      const win = doc.defaultView;
      const dom = doc.createElement('div');
      function sync(target) {
        current = target;
        dom.className = 'math-block';
        dom.setAttribute('data-tex', target.attrs.tex || '');
        dom.setAttribute('contenteditable', 'false');
        if (target.attrs.mathSourceKey) dom.setAttribute('data-md-math-source', target.attrs.mathSourceKey);
        else dom.removeAttribute('data-md-math-source');

        if (win?.katex?.render) {
          try {
            win.katex.render(target.attrs.tex || '', dom, { displayMode: true, throwOnError: false });
            dom.setAttribute('data-rendered', 'true');
            return;
          } catch (_) {
            // Fallback auf unveränderte Textquelle bei Syntaxfehler.
          }
        }
        dom.textContent = target.attrs.tex || '';
      }
      sync(node);
      return {
        dom,
        update(updated) {
          if (updated.type !== current.type) return false;
          if (
            updated.attrs.tex === current.attrs.tex &&
            updated.attrs.mathSourceKey === current.attrs.mathSourceKey
          ) {
            current = updated;
            return true;
          }
          sync(updated);
          return true;
        },
        ignoreMutation() {
          return true;
        }
      };
    },

    math_inline(node, view) {
      let current = node;
      const doc = view.dom.ownerDocument;
      const win = doc.defaultView;
      const dom = doc.createElement('span');
      function sync(target) {
        current = target;
        dom.className = target.attrs.displayMode ? 'math-block' : 'math-inline';
        dom.setAttribute('data-tex', target.attrs.tex || '');
        dom.setAttribute('contenteditable', 'false');
        if (target.attrs.mathSourceKey) dom.setAttribute('data-md-math-source', target.attrs.mathSourceKey);
        else dom.removeAttribute('data-md-math-source');

        if (win?.katex?.render) {
          try {
            win.katex.render(target.attrs.tex || '', dom, {
              displayMode: !!target.attrs.displayMode,
              throwOnError: false
            });
            dom.setAttribute('data-rendered', 'true');
            return;
          } catch (_) {
            // Fallback auf unveränderte Textquelle.
          }
        }
        dom.textContent = target.attrs.tex || '';
      }
      sync(node);
      return {
        dom,
        update(updated) {
          if (updated.type !== current.type) return false;
          if (
            updated.attrs.tex === current.attrs.tex &&
            updated.attrs.mathSourceKey === current.attrs.mathSourceKey &&
            updated.attrs.displayMode === current.attrs.displayMode
          ) {
            current = updated;
            return true;
          }
          sync(updated);
          return true;
        },
        ignoreMutation() {
          return true;
        }
      };
    },

    opaque_block(node, view) {
      let current = node;
      const dom = view.dom.ownerDocument.createElement(node.attrs.tag || 'section');
      function sync(target) {
        current = target;
        if (target.attrs.className) dom.className = target.attrs.className;
        else dom.removeAttribute('class');
        dom.setAttribute('data-md-opaque', target.attrs.opaqueKey || '');
        dom.setAttribute('contenteditable', 'false');
        if (target.attrs.mathSourceKey) dom.setAttribute('data-md-math-source', target.attrs.mathSourceKey);
        else dom.removeAttribute('data-md-math-source');
        if (target.attrs.rawHTML && dom.innerHTML !== target.attrs.rawHTML) {
          dom.innerHTML = target.attrs.rawHTML;
        }
      }
      sync(node);
      return {
        dom,
        update(updated) {
          if (updated.type !== current.type || updated.attrs.tag !== current.attrs.tag) return false;
          sync(updated);
          return true;
        },
        ignoreMutation() {
          return true;
        }
      };
    },

    opaque_inline(node, view) {
      let current = node;
      const dom = view.dom.ownerDocument.createElement(node.attrs.tag || 'span');
      function sync(target) {
        current = target;
        if (target.attrs.className) dom.className = target.attrs.className;
        else dom.removeAttribute('class');
        dom.setAttribute('data-md-opaque', target.attrs.opaqueKey || '');
        dom.setAttribute('contenteditable', 'false');
        if (target.attrs.mathSourceKey) dom.setAttribute('data-md-math-source', target.attrs.mathSourceKey);
        else dom.removeAttribute('data-md-math-source');
        if (target.attrs.rawHTML && dom.innerHTML !== target.attrs.rawHTML) {
          dom.innerHTML = target.attrs.rawHTML;
        }
      }
      sync(node);
      return {
        dom,
        update(updated) {
          if (updated.type !== current.type) return false;
          sync(updated);
          return true;
        },
        ignoreMutation() {
          return true;
        }
      };
    }
  };
}
