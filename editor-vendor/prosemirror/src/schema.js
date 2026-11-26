import { Schema } from 'prosemirror-model';

export const INLINE_HTML_TAGS = ['u', 'ins', 'small', 'sub', 'sup', 'kbd', 'samp', 'var', 'q', 'cite', 'abbr', 'dfn'];
export const INLINE_HTML_ATTRS = ['title', 'dir', 'lang'];

const blockOriginAttrs = () => ({
  mdContext: { default: '' },
  mdBlockId: { default: null },
  mdBlockSub: { default: 0 },
  mdBlockTotal: { default: 1 }
});

function readBlockOrigin(dom) {
  return {
    mdContext: dom.getAttribute('data-fastra-md-context') || '',
    mdBlockId: dom.getAttribute('data-fastra-md-block-id') || null,
    mdBlockSub: Number(dom.getAttribute('data-fastra-md-block-sub') || 0),
    mdBlockTotal: Number(dom.getAttribute('data-fastra-md-block-total') || 1)
  };
}

function inlineHtmlMarkSpec(tag) {
  return {
    attrs: {
      title: { default: null },
      dir: { default: null },
      lang: { default: null }
    },
    excludes: '',
    parseDOM: [{
      tag,
      getAttrs(dom) {
        if (dom.closest?.('[data-md-opaque],[data-tex],pre')) return false;
        return {
          title: dom.getAttribute('title'),
          dir: dom.getAttribute('dir'),
          lang: dom.getAttribute('lang')
        };
      }
    }],
    toDOM(mark) {
      const attrs = {};
      for (const name of INLINE_HTML_ATTRS) {
        if (mark.attrs[name] != null && mark.attrs[name] !== '') {
          attrs[name] = mark.attrs[name];
        }
      }
      return [tag, attrs, 0];
    }
  };
}

const nodes = {
  doc: {
    content: 'block+',
    attrs: {
      sourceContext: { default: '' }
    }
  },
  paragraph: {
    content: 'inline*',
    group: 'block',
    attrs: {
      ...blockOriginAttrs(),
      mdEmpty: { default: false },
      mdDeleted: { default: false }
    },
    parseDOM: [{
      tag: 'p',
      getAttrs(dom) {
        if (dom.hasAttribute('data-md-edit-boundary')) return false;
        return {
          ...readBlockOrigin(dom),
          mdEmpty: dom.hasAttribute('data-md-empty')
        };
      }
    }],
    toDOM(node) {
      const attrs = {};
      if (node.attrs.mdEmpty && node.content.size === 0) {
        attrs['data-md-empty'] = 'true';
      }
      return ['p', attrs, 0];
    }
  },
  blank_line: {
    content: 'inline*',
    group: 'block',
    attrs: blockOriginAttrs(),
    parseDOM: [{
      tag: 'div.fastra-visible-blank-line',
      getAttrs(dom) {
        return readBlockOrigin(dom);
      }
    }],
    toDOM() {
      return ['div', { class: 'fastra-visible-blank-line' }, 0];
    }
  },
  heading: {
    content: 'inline*',
    group: 'block',
    defining: true,
    attrs: {
      ...blockOriginAttrs(),
      level: { default: 1 },
      outlineIgnore: { default: false }
    },
    parseDOM: [1, 2, 3, 4, 5, 6].map(level => ({
      tag: `h${level}`,
      getAttrs(dom) {
        return {
          ...readBlockOrigin(dom),
          level,
          outlineIgnore: dom.hasAttribute('data-md-outline-ignore')
        };
      }
    })),
    toDOM(node) {
      const attrs = {};
      if (node.attrs.outlineIgnore) attrs['data-md-outline-ignore'] = 'true';
      return [`h${node.attrs.level}`, attrs, 0];
    }
  },
  blockquote: {
    content: 'block+',
    group: 'block',
    defining: true,
    attrs: blockOriginAttrs(),
    parseDOM: [{
      tag: 'blockquote',
      getAttrs(dom) {
        return readBlockOrigin(dom);
      }
    }],
    toDOM() {
      return ['blockquote', 0];
    }
  },
  bullet_list: {
    content: 'list_item+',
    group: 'block',
    attrs: {
      ...blockOriginAttrs(),
      tight: { default: true }
    },
    parseDOM: [{
      tag: 'ul',
      getAttrs(dom) {
        return {
          ...readBlockOrigin(dom),
          tight: !dom.querySelector(':scope > li > p')
        };
      }
    }],
    toDOM() {
      return ['ul', 0];
    }
  },
  ordered_list: {
    content: 'list_item+',
    group: 'block',
    attrs: {
      ...blockOriginAttrs(),
      order: { default: 1 },
      tight: { default: true }
    },
    parseDOM: [{
      tag: 'ol',
      getAttrs(dom) {
        return {
          ...readBlockOrigin(dom),
          order: dom.hasAttribute('start') ? Math.max(0, Number(dom.getAttribute('start')) || 1) : 1,
          tight: !dom.querySelector(':scope > li > p')
        };
      }
    }],
    toDOM(node) {
      return node.attrs.order === 1 ? ['ol', 0] : ['ol', { start: String(node.attrs.order) }, 0];
    }
  },
  list_item: {
    content: 'block+',
    defining: true,
    attrs: {
      task: { default: null }
    },
    parseDOM: [{
      tag: 'li',
      getAttrs(dom) {
        const cb = Array.from(dom.querySelectorAll('input[type=checkbox]')).find(n => n.closest('li') === dom);
        if (!cb) return { task: null };
        return { task: cb.hasAttribute('checked') || cb.checked === true };
      }
    }],
    toDOM(node) {
      if (node.attrs.task !== null) {
        return ['li', { 'data-task': node.attrs.task ? 'checked' : 'unchecked' }, 0];
      }
      return ['li', 0];
    }
  },
  code_block: {
    content: 'text*',
    marks: '',
    group: 'block',
    code: true,
    defining: true,
    attrs: {
      ...blockOriginAttrs(),
      language: { default: '' }
    },
    parseDOM: [{
      tag: 'pre',
      preserveWhitespace: 'full',
      getAttrs(dom) {
        if (dom.closest('[data-md-opaque]') || dom.classList.contains('mermaid-render')) return false;
        const code = dom.querySelector('code');
        const lang = code?.className.match(/(?:^|\s)language-([\w+-]+)/)?.[1] || '';
        return {
          ...readBlockOrigin(dom),
          language: lang
        };
      }
    }],
    toDOM(node) {
      const codeAttrs = node.attrs.language ? { class: `language-${node.attrs.language}` } : {};
      return ['pre', ['code', codeAttrs, 0]];
    }
  },
  horizontal_rule: {
    group: 'block',
    atom: true,
    attrs: blockOriginAttrs(),
    parseDOM: [{
      tag: 'hr',
      getAttrs(dom) {
        return readBlockOrigin(dom);
      }
    }],
    toDOM() {
      return ['hr'];
    }
  },
  table: {
    content: 'table_row+',
    group: 'block',
    isolating: true,
    attrs: {
      ...blockOriginAttrs(),
      gfm: { default: true }
    },
    parseDOM: [{
      tag: 'table',
      getAttrs(dom) {
        const hasMerged = !!dom.querySelector('[colspan],[rowspan],table');
        const gfm = dom.getAttribute('data-md-table') === 'gfm' && !hasMerged;
        return {
          ...readBlockOrigin(dom),
          gfm
        };
      }
    }],
    toDOM(node) {
      const attrs = node.attrs.gfm ? { 'data-md-table': 'gfm' } : {};
      return ['table', attrs, ['tbody', 0]];
    }
  },
  table_row: {
    content: '(table_header | table_cell)+',
    parseDOM: [{ tag: 'tr' }],
    toDOM() {
      return ['tr', 0];
    }
  },
  table_header: {
    content: 'inline*',
    isolating: true,
    attrs: {
      align: { default: null },
      colspan: { default: 1 },
      rowspan: { default: 1 }
    },
    parseDOM: [{
      tag: 'th',
      preserveWhitespace: 'full',
      getAttrs(dom) {
        return {
          align: dom.getAttribute('align') || null,
          colspan: Math.max(1, Number(dom.getAttribute('colspan') || 1)),
          rowspan: Math.max(1, Number(dom.getAttribute('rowspan') || 1))
        };
      }
    }],
    toDOM(node) {
      const attrs = {};
      if (node.attrs.align) attrs.align = node.attrs.align;
      if (node.attrs.colspan > 1) attrs.colspan = String(node.attrs.colspan);
      if (node.attrs.rowspan > 1) attrs.rowspan = String(node.attrs.rowspan);
      return ['th', attrs, 0];
    }
  },
  table_cell: {
    content: 'inline*',
    isolating: true,
    attrs: {
      align: { default: null },
      colspan: { default: 1 },
      rowspan: { default: 1 }
    },
    parseDOM: [{
      tag: 'td',
      preserveWhitespace: 'full',
      getAttrs(dom) {
        return {
          align: dom.getAttribute('align') || null,
          colspan: Math.max(1, Number(dom.getAttribute('colspan') || 1)),
          rowspan: Math.max(1, Number(dom.getAttribute('rowspan') || 1))
        };
      }
    }],
    toDOM(node) {
      const attrs = {};
      if (node.attrs.align) attrs.align = node.attrs.align;
      if (node.attrs.colspan > 1) attrs.colspan = String(node.attrs.colspan);
      if (node.attrs.rowspan > 1) attrs.rowspan = String(node.attrs.rowspan);
      return ['td', attrs, 0];
    }
  },
  math_block: {
    group: 'block',
    atom: true,
    selectable: true,
    attrs: {
      ...blockOriginAttrs(),
      tex: { default: '' },
      mathSourceKey: { default: null },
      rawHTML: { default: '' }
    },
    parseDOM: [{
      tag: 'div[data-tex]',
      priority: 60,
      getAttrs(dom) {
        return {
          ...readBlockOrigin(dom),
          tex: dom.getAttribute('data-tex') || '',
          mathSourceKey: dom.getAttribute('data-md-math-source') || null,
          rawHTML: dom.outerHTML
        };
      }
    }],
    toDOM(node) {
      const attrs = {
        class: 'math-block',
        'data-tex': node.attrs.tex,
        contenteditable: 'false'
      };
      if (node.attrs.mathSourceKey) attrs['data-md-math-source'] = node.attrs.mathSourceKey;
      return ['div', attrs, node.attrs.tex];
    }
  },
  opaque_block: {
    group: 'block',
    atom: true,
    selectable: true,
    attrs: {
      ...blockOriginAttrs(),
      opaqueKey: { default: '' },
      tag: { default: 'section' },
      className: { default: '' },
      mathSourceKey: { default: null },
      rawHTML: { default: '' }
    },
    parseDOM: [{
      tag: '[data-md-opaque]',
      priority: 65,
      getAttrs(dom) {
        if (!['DIV', 'SECTION', 'PRE'].includes(dom.tagName)) return false;
        return {
          ...readBlockOrigin(dom),
          opaqueKey: dom.getAttribute('data-md-opaque') || '',
          tag: dom.tagName.toLowerCase(),
          className: dom.getAttribute('class') || '',
          mathSourceKey: dom.getAttribute('data-md-math-source') || null,
          rawHTML: dom.innerHTML
        };
      }
    }],
    toDOM(node) {
      const attrs = {
        'data-md-opaque': node.attrs.opaqueKey,
        contenteditable: 'false'
      };
      if (node.attrs.className) attrs.class = node.attrs.className;
      if (node.attrs.mathSourceKey) attrs['data-md-math-source'] = node.attrs.mathSourceKey;
      return [node.attrs.tag || 'section', attrs];
    }
  },
  text: {
    group: 'inline'
  },
  hard_break: {
    inline: true,
    group: 'inline',
    selectable: false,
    parseDOM: [{
      tag: 'br',
      getAttrs(dom) {
        if (dom.closest('[data-md-opaque],[data-tex],pre')) return false;
        return {};
      }
    }],
    toDOM() {
      return ['br'];
    }
  },
  image: {
    inline: true,
    group: 'inline',
    draggable: true,
    attrs: {
      src: { default: '' },
      mdSrc: { default: null },
      alt: { default: '' },
      title: { default: null },
      width: { default: null },
      height: { default: null },
      imageTransaction: { default: null },
      imageEnding: { default: null }
    },
    parseDOM: [{
      tag: 'img',
      getAttrs(dom) {
        if (dom.closest('[data-md-opaque],[data-tex],pre')) return false;
        return {
          src: dom.getAttribute('src') || '',
          mdSrc: dom.getAttribute('data-md-src') || null,
          alt: dom.getAttribute('alt') || '',
          title: dom.getAttribute('title'),
          width: dom.getAttribute('width') || null,
          height: dom.getAttribute('height') || null,
          imageTransaction: dom.getAttribute('data-md-image-transaction') || null,
          imageEnding: dom.getAttribute('data-md-image-ending') || null
        };
      }
    }],
    toDOM(node) {
      const attrs = {
        src: node.attrs.src || '',
        alt: node.attrs.alt || ''
      };
      if (node.attrs.mdSrc != null) attrs['data-md-src'] = node.attrs.mdSrc;
      if (node.attrs.title != null && node.attrs.title !== '') attrs.title = node.attrs.title;
      if (node.attrs.width != null && node.attrs.width !== '') attrs.width = node.attrs.width;
      if (node.attrs.height != null && node.attrs.height !== '') attrs.height = node.attrs.height;
      if (node.attrs.imageTransaction) attrs['data-md-image-transaction'] = node.attrs.imageTransaction;
      if (node.attrs.imageEnding) attrs['data-md-image-ending'] = node.attrs.imageEnding;
      return ['img', attrs];
    }
  },
  math_inline: {
    inline: true,
    group: 'inline',
    atom: true,
    selectable: true,
    attrs: {
      tex: { default: '' },
      mathSourceKey: { default: null },
      displayMode: { default: false },
      rawHTML: { default: '' }
    },
    parseDOM: [{
      tag: 'span[data-tex]',
      priority: 60,
      getAttrs(dom) {
        return {
          tex: dom.getAttribute('data-tex') || '',
          mathSourceKey: dom.getAttribute('data-md-math-source') || null,
          displayMode: dom.classList.contains('math-block'),
          rawHTML: dom.outerHTML
        };
      }
    }],
    toDOM(node) {
      const attrs = {
        class: node.attrs.displayMode ? 'math-block' : 'math-inline',
        'data-tex': node.attrs.tex,
        contenteditable: 'false'
      };
      if (node.attrs.mathSourceKey) attrs['data-md-math-source'] = node.attrs.mathSourceKey;
      return ['span', attrs, node.attrs.tex];
    }
  },
  opaque_inline: {
    inline: true,
    group: 'inline',
    atom: true,
    selectable: true,
    attrs: {
      opaqueKey: { default: '' },
      tag: { default: 'span' },
      className: { default: '' },
      mathSourceKey: { default: null },
      rawHTML: { default: '' }
    },
    parseDOM: [{
      tag: 'span[data-md-opaque], mark[data-md-opaque]',
      priority: 65,
      getAttrs(dom) {
        return {
          opaqueKey: dom.getAttribute('data-md-opaque') || '',
          tag: dom.tagName.toLowerCase(),
          className: dom.getAttribute('class') || '',
          mathSourceKey: dom.getAttribute('data-md-math-source') || null,
          rawHTML: dom.innerHTML
        };
      }
    }],
    toDOM(node) {
      const attrs = {
        'data-md-opaque': node.attrs.opaqueKey,
        contenteditable: 'false'
      };
      if (node.attrs.className) attrs.class = node.attrs.className;
      if (node.attrs.mathSourceKey) attrs['data-md-math-source'] = node.attrs.mathSourceKey;
      return [node.attrs.tag || 'span', attrs];
    }
  }
};

const marks = {
  strong: {
    parseDOM: [
      { tag: 'strong', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') ? false : null) },
      { tag: 'b', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') || d.style?.fontWeight === 'normal' ? false : null) },
      {
        style: 'font-weight',
        getAttrs: value => (/^(bold(er)?|[6-9]\d{2})$/.test(String(value)) ? null : false)
      }
    ],
    toDOM() {
      return ['strong', 0];
    }
  },
  em: {
    parseDOM: [
      { tag: 'em', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') ? false : null) },
      { tag: 'i', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') ? false : null) },
      { style: 'font-style=italic' },
      { style: 'font-style=oblique' }
    ],
    toDOM() {
      return ['em', 0];
    }
  },
  code: {
    excludes: '',
    parseDOM: [{
      tag: 'code',
      preserveWhitespace: 'full',
      getAttrs(dom) {
        if (dom.closest('pre,[data-md-opaque],[data-tex]')) return false;
        return null;
      }
    }],
    toDOM() {
      return ['code', 0];
    }
  },
  highlight: {
    parseDOM: [
      {
        tag: 'mark',
        getAttrs(dom) {
          if (dom.closest('[data-md-opaque],[data-tex],pre') || dom.hasAttribute('data-md-opaque')) return false;
          return null;
        }
      },
      {
        style: 'background-color',
        getAttrs(value) {
          if (!value || value === 'transparent' || value === 'rgba(0, 0, 0, 0)') return false;
          return null;
        }
      }
    ],
    toDOM() {
      return ['mark', 0];
    }
  },
  strike: {
    parseDOM: [
      { tag: 'del', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') ? false : null) },
      { tag: 's', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') ? false : null) },
      { tag: 'strike', getAttrs: d => (d.closest('[data-md-opaque],[data-tex],pre') ? false : null) },
      {
        style: 'text-decoration-line',
        getAttrs: value => (String(value).includes('line-through') ? null : false)
      }
    ],
    toDOM() {
      return ['del', 0];
    }
  },
  link: {
    attrs: {
      href: { default: '' },
      title: { default: null }
    },
    inclusive: false,
    parseDOM: [{
      tag: 'a[href]',
      getAttrs(dom) {
        if (dom.closest('[data-md-opaque],[data-tex],pre')) return false;
        return {
          href: dom.getAttribute('href') || '',
          title: dom.getAttribute('title')
        };
      }
    }],
    toDOM(mark) {
      const attrs = { href: mark.attrs.href };
      if (mark.attrs.title != null && mark.attrs.title !== '') attrs.title = mark.attrs.title;
      return ['a', attrs, 0];
    }
  }
};

for (const tag of INLINE_HTML_TAGS) {
  marks[`html_${tag}`] = inlineHtmlMarkSpec(tag);
}

export const schema = new Schema({ nodes, marks });
export const INLINE_HTML_MARK_NAMES = INLINE_HTML_TAGS.map(t => `html_${t}`);
