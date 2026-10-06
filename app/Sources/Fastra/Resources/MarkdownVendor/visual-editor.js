/* Fastras lokale WYSIWYG-Schicht. Originalquellen liegen ausschließlich in
   diesem geschlossenen Zustand, niemals in kopiertem HTML oder DOM-Attributen. */
(() => {
  'use strict';
  const td = new TurndownService({headingStyle:'atx', bulletListMarker:'-',
    codeBlockStyle:'fenced', emDelimiter:'*', strongDelimiter:'**', preformattedCode:true});
  const commonEscape=td.escape.bind(td);
  td.escape=text=>commonEscape(text).replace(/[$~=]/g,'\\$&');
  let opaqueSources={};
  td.addRule('opaque',{filter:n=>n.hasAttribute('data-md-opaque'),replacement:(_,n)=>opaqueSources[n.dataset.mdOpaque] || ''});
  td.addRule('highlight', {filter:'mark', replacement:(c,n)=>n.parentElement?.closest('mark')?c:(c.trim()?'=='+c.trim()+'==':'')});
  td.addRule('strike', {filter:['del','s','strike'], replacement:c => '~~'+c+'~~'});
  td.addRule('images', {filter:'img', replacement:(_,n) => {
    const src=n.getAttribute('data-md-src');
    const title=n.getAttribute('title');
    return src ? '!['+(n.alt || '').replace(/[\\[\]]/g,'\\$&')+'](<'+src.replace(/</g,'%3C').replace(/>/g,'%3E')+'>'+(title?' "'+title.replace(/[\\"]/g,'\\$&')+'"':'')+')' : '';
  }});
  td.addRule('math', {filter:n => n.hasAttribute('data-tex'), replacement:(_,n) =>
    n.classList.contains('math-block') ? '\n\n$$\n'+n.dataset.tex+'\n$$\n\n' : '$'+n.dataset.tex+'$'});
  td.addRule('task', {filter:n => n.nodeName==='INPUT' && n.type==='checkbox',
    replacement:(_,n) => n.checked ? '[x] ' : '[ ] '});
  td.addRule('fence', {filter:'pre', replacement:(_,n) => {
    const code=n.querySelector('code'), text=(code || n).textContent.replace(/\n$/,'');
    const runs=text.match(/`+/g) || [], fence='`'.repeat(Math.max(3,...runs.map(x=>x.length+1)));
    const language=code?.className.match(/(?:^|\s)language-([\w+-]+)/)?.[1] || '';
    return '\n\n'+fence+language+'\n'+text+'\n'+fence+'\n\n';
  }});
  td.addRule('table', {filter:'table', replacement:(_,n) => {
    const rows=Array.from(n.rows), width=Math.max(1,...rows.map(r=>r.cells.length));
    const lines=rows.map(r=>'| '+Array.from({length:width},(_,i)=>{
      const cell=r.cells[i];
      return cell ? td.turndown(cell.innerHTML).replace(/\n+/g,'<br>').replace(/\|/g,'\\|') : '';
    }).join(' | ')+' |');
    if(!lines.length) return '';
    if(!Array.from(rows[0].cells).some(c=>c.tagName==='TH')) lines.unshift('| '+Array(width).fill(' ').join(' | ')+' |');
    lines.splice(1,0,'| '+Array.from({length:width},(_,i)=>{
      const align=rows[0].cells[i]?.getAttribute('align');
      return align==='center'?':---:':align==='right'?'---:':align==='left'?':---':'---';
    }).join(' | ')+' |');
    return '\n\n'+lines.join('\n')+'\n\n';
  }});
  let root, originals=new Map(), blocks=[], selection=null, base='', session='', composing=false, revision=0, fenced=false, bookmarkID=0, bookmarks=new Map();
  function normalized(node) {
    const clone=node.cloneNode(true);
    clone.querySelectorAll('[data-md-opaque]').forEach(n=>n.textContent='');
    clone.querySelectorAll('[data-tex]').forEach(n=>{n.textContent='';n.removeAttribute('data-rendered');});
    clone.querySelectorAll('pre code').forEach(n=>{n.textContent=n.textContent;n.removeAttribute('data-highlighted');n.classList.remove('hljs');});
    return clone.innerHTML;
  }
  function restoreSelection() {
    const live=getSelection();
    if(live.rangeCount && root.contains(live.getRangeAt(0).commonAncestorContainer))selection=live.getRangeAt(0).cloneRange();
    root.focus();
    if(selection && root.contains(selection.commonAncestorContainer)) {
      getSelection().removeAllRanges();getSelection().addRange(selection);
    } else {
      const r=document.createRange();r.selectNodeContents(root);r.collapse(false);
      getSelection().removeAllRanges();getSelection().addRange(r);
    }
  }
  function serialize() {
    const used=new Set(), hidden=new Set();let output='';
    function hiddenBefore(id) {
      const index=blocks.findIndex(b=>String(b.id)===id);
      if(index<0)return;
      for(let i=index-1;i>=0 && blocks[i].hidden;i--) hidden.add(blocks[i].id);
      const preceding=blocks.slice(0,index).filter(b=>b.hidden && hidden.has(b.id));
      for(const b of preceding){output+=b.source;hidden.delete(b.id);used.add('hidden:'+b.id);}
    }
    for(const node of root.childNodes) {
      if(node.nodeType===Node.TEXT_NODE && !node.textContent.trim())continue;
      const id=node.nodeType===Node.ELEMENT_NODE ? node.getAttribute('data-md-block') : null;
      const original=id===null ? null : originals.get(id);
      if(original && !used.has(id)) {
        hiddenBefore(id);used.add(id);
        output+=normalized(node)===original.snapshot ? original.source : td.turndown(node.innerHTML)+'\n\n';
      } else if(node.nodeType===Node.ELEMENT_NODE && node.hasAttribute('data-md-empty') && !node.textContent.trim() && !node.querySelector('img')) {
        continue;
      } else {
        const holder=document.createElement('div');holder.append(node.cloneNode(true));
        const value=td.turndown(holder.innerHTML);
        output+=value ? value+'\n\n' : '\n';
      }
    }
    // Verdeckte Definitionen müssen auch dann erhalten bleiben, wenn ihr
    // Nachbarabsatz gelöscht oder durch Auswahl über mehrere Blöcke ersetzt wurde.
    for(const b of blocks)if(b.hidden && !used.has('hidden:'+b.id))output+=b.source;
    return output;
  }
  function changed() {
    if(composing)return;
    const markdown=serialize();
    if(markdown===base)return;
    window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'change',session,base,markdown,revision:++revision});
    base=markdown;
  }
  function exec(name,value=null) {
    // WebKit ersetzt eine Auswahl über geschützte Atome sonst nur teilweise
    // und dupliziert den Block. Nur während des atomaren HTML-Ersatzes freigeben.
    const protectedNodes=name==='insertHTML'?Array.from(root.querySelectorAll('[contenteditable=false]')):[];
    protectedNodes.forEach(n=>n.removeAttribute('contenteditable'));
    try { restoreSelection();document.execCommand(name,false,value); }
    finally {
      protectedNodes.forEach(n=>{if(n.isConnected)n.contentEditable='false';});
      root.querySelectorAll('[data-tex],[data-md-opaque],.mermaid-render').forEach(n=>n.contentEditable='false');
    }
    const live=getSelection();if(live.rangeCount)selection=live.getRangeAt(0).cloneRange();
    changed();
  }
  function plainParagraph() {
    exec('formatBlock','p');
    restoreSelection();const r=getSelection().getRangeAt(0);
    const selected=Array.from(root.children).filter(n=>r.intersectsNode(n));
    if(!selected.length)return;
    const html=selected.map(node=>{
      const clone=node.cloneNode(true);
      const protectedNode=n=>n.closest('[contenteditable=false],[data-tex],[data-md-opaque]');
      clone.querySelectorAll('mark,code,strong,b,em,i,del,s,strike,a,u,font,span').forEach(n=>{
        if(!protectedNode(n) && n.parentElement?.tagName!=='PRE')n.replaceWith(...n.childNodes);
      });
      clone.querySelectorAll('h1,h2,h3,h4,h5,h6,li').forEach(n=>{
        if(protectedNode(n))return;const p=document.createElement('p');p.append(...n.childNodes);n.replaceWith(p);
      });
      clone.querySelectorAll('ul,ol,blockquote').forEach(n=>{if(!protectedNode(n))n.replaceWith(...n.childNodes);});
      return clone.outerHTML;
    }).join('');
    const outer=document.createRange();outer.setStartBefore(selected[0]);outer.setEndAfter(selected[selected.length-1]);
    getSelection().removeAllRanges();getSelection().addRange(outer);selection=outer;exec('insertHTML',html);
  }
  function sanitizePaste(html) {
    const template=document.createElement('template');template.innerHTML=html;
    template.content.querySelectorAll('script,style,iframe,object,embed,svg,math,link,meta').forEach(n=>n.remove());
    template.content.querySelectorAll('*').forEach(n=>{
      for(const a of Array.from(n.attributes))if(!['href','src','alt','title','align','colspan','rowspan','start','type','checked'].includes(a.name))n.removeAttribute(a.name);
      if(n.tagName==='IMG'){const src=n.getAttribute('src') || '';if(/^(https?:|[^:\/]+(?:\/|$))/i.test(src))n.dataset.mdSrc=src;else n.remove();}
      if(n.hasAttribute('href') && !/^(https?:|mailto:|#|[^:\/]+(?:\/|$))/i.test(n.getAttribute('href')))n.removeAttribute('href');
    });
    return template.innerHTML;
  }
  window.fastraVisual={
    async start(configuration) {
      const until=Date.now()+5000;
      while(!document.documentElement.hasAttribute('data-fastra-enhanced') && Date.now()<until)await new Promise(r=>setTimeout(r,10));
      root=document.getElementById('fastra-visual');blocks=configuration.blocks;base=configuration.markdown;session=configuration.session;opaqueSources=configuration.opaqueSources || {};
      root.contentEditable='true';root.setAttribute('role','textbox');root.setAttribute('aria-multiline','true');
      root.querySelectorAll('[data-tex],.mermaid-render').forEach(n=>n.contentEditable='false');
      for(const b of blocks)if(!b.hidden){const n=root.querySelector('[data-md-block="'+b.id+'"]');if(n)originals.set(String(b.id),{source:b.source,snapshot:normalized(n)});}
      if(!root.children.length)root.innerHTML='<p data-md-empty="true"><br></p>';
      document.execCommand('defaultParagraphSeparator',false,'p');
      root.addEventListener('input',changed);
      root.addEventListener('compositionstart',()=>composing=true);
      root.addEventListener('compositionend',()=>{composing=false;changed();});
      document.addEventListener('selectionchange',()=>{
        const s=getSelection();if(s.rangeCount && root.contains(s.getRangeAt(0).commonAncestorContainer))selection=s.getRangeAt(0).cloneRange();
      });
      root.addEventListener('copy',e=>{
        const s=getSelection();if(!s.rangeCount || s.isCollapsed)return;
        const rich=document.createElement('div');rich.append(s.getRangeAt(0).cloneContents());
        const markdown=td.turndown(rich.innerHTML);
        const html=rich.cloneNode(true);
        html.querySelectorAll('*').forEach(n=>{for(const a of Array.from(n.attributes))if(a.name.startsWith('data-md-') || a.name==='contenteditable')n.removeAttribute(a.name);});
        e.preventDefault();e.stopPropagation();
        window.webkit.messageHandlers.markdownCopy.postMessage({plain:s.toString(),html:html.innerHTML,markdown,session});
      });
      root.addEventListener('paste',e=>{
        e.preventDefault();
        if(e.clipboardData.getData('application/x-fastra-markdown')){window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'pasteMarkdown',session});return;}
        if(e.clipboardData.files.length){window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'pasteImage',session});return;}
        const html=e.clipboardData.getData('text/html');
        exec(html ? 'insertHTML' : 'insertText',html ? sanitizePaste(html) : e.clipboardData.getData('text/plain'));
      });
      root.addEventListener('drop',e=>{
        e.preventDefault();
        const r=document.caretRangeFromPoint?.(e.clientX,e.clientY);
        if(r && root.contains(r.commonAncestorContainer))selection=r;
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'drop',session,paths:Array.from(e.dataTransfer.files,f=>f.name)});
      });
      root.addEventListener('dragover',e=>e.preventDefault());
      root.addEventListener('click',e=>{if(e.target.closest('a'))e.preventDefault();});
      root.focus();
      return serialize()===base;
    },
    command(command,value) {
      if(fenced)return false;
      switch(command){
        case 'bold':exec('bold');break;
        case 'italic':exec('italic');break;
        case 'heading1':exec('formatBlock','h1');break;
        case 'heading2':exec('formatBlock','h2');break;
        case 'heading3':exec('formatBlock','h3');break;
        case 'plainParagraph':plainParagraph();break;
        case 'bulletList':exec('insertUnorderedList');break;
        case 'orderedList':exec('insertOrderedList');break;
        case 'quote':exec('formatBlock','blockquote');break;
        case 'hardBreak':exec('insertLineBreak');break;
        case 'link':exec('createLink',value);break;
        case 'insertTable':exec('insertHTML',value);break;
        case 'insertHTML':exec('insertHTML',value);break;
        case 'code':case 'highlight': {
          restoreSelection();const s=getSelection();if(!s.rangeCount)return;
          const r=s.getRangeAt(0),tag=command==='code'?'code':'mark';
          const ancestor=r.commonAncestorContainer.nodeType===1?r.commonAncestorContainer:r.commonAncestorContainer.parentElement;
          const marked=ancestor.closest(tag);
          if(marked){
            const full=document.createRange();full.selectNodeContents(marked);
            const before=full.cloneRange(),after=full.cloneRange();
            before.setEnd(r.startContainer,r.startOffset);after.setStart(r.endContainer,r.endOffset);
            const wrap=fragment=>{const element=document.createElement(tag);element.append(fragment);return element.innerHTML?element.outerHTML:'';};
            const middle=document.createElement('span');middle.append(r.collapsed?full.cloneContents():r.cloneContents());
            middle.querySelectorAll(tag).forEach(n=>n.replaceWith(...n.childNodes));
            const html=r.collapsed?middle.innerHTML:wrap(before.cloneContents())+middle.innerHTML+wrap(after.cloneContents());
            // WebKit übernimmt beim Ersetzen eines Inline-Knotens dessen
            // Schreibattribute. Der ganze Absatz ist ein neutraler Undo-Schritt.
            const block=marked.closest('[data-md-block]') || marked.closest('p,h1,h2,h3,li,blockquote');
            if(!block)return;
            const path=[];let current=marked;while(current!==block){path.unshift(Array.from(current.parentNode.childNodes).indexOf(current));current=current.parentNode;}
            const clone=block.cloneNode(true);let target=clone;for(const index of path)target=target.childNodes[index];
            const template=document.createElement('template');template.innerHTML=html;target.replaceWith(template.content);
            const outer=document.createRange();outer.selectNode(block);s.removeAllRanges();s.addRange(outer);selection=outer;
            exec('insertHTML',clone.outerHTML);
          }
          else {
            const holder=document.createElement('div');holder.append(r.cloneContents());
            function wrap(parent){
              let group=[];
              function flush(){if(!group.length)return;const wrapper=document.createElement(tag);group[0].before(wrapper);wrapper.append(...group);wrapper.querySelectorAll(tag).forEach(n=>n.replaceWith(...n.childNodes));group=[];}
              for(const child of Array.from(parent.childNodes)){
                if(child.nodeType===1 && /^(DIV|P|H[1-6]|LI|UL|OL|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|TD|TH|PRE|SECTION)$/.test(child.tagName)){
                  flush();if(child.contentEditable!=='false')wrap(child);
                }else group.push(child);
              }
              flush();
            }
            wrap(holder);exec('insertHTML',holder.innerHTML);
          }
          break;
        }
      }
    },
    caret(x,y){const r=document.caretRangeFromPoint?.(x,y);if(r && root.contains(r.commonAncestorContainer)){selection=r;getSelection().removeAllRanges();getSelection().addRange(r);}},
    bookmark(){restoreSelection();const key=String(++bookmarkID);bookmarks.set(key,{range:selection.cloneRange(),base:serialize()});return key;},
    insertBookmarked(key,html,atoms){if(fenced)return false;const saved=bookmarks.get(key);bookmarks.delete(key);if(!saved || saved.base!==serialize() || !root.contains(saved.range.commonAncestorContainer))return false;Object.assign(opaqueSources,atoms || {});const template=document.createElement('template');template.innerHTML=html;template.content.querySelectorAll('[data-tex]').forEach(n=>n.textContent=n.dataset.tex);html=template.innerHTML;selection=saved.range;getSelection().removeAllRanges();getSelection().addRange(selection);exec('insertHTML',html);window.fastraEnhanceMarkdown?.(root).then(()=>{root.querySelectorAll('[data-tex],.mermaid-render').forEach(n=>n.contentEditable='false');});return true;},
    async updateStyle(font,size,dark){
      let sheet=document.getElementById('fastra-visual-style');if(!sheet){sheet=document.createElement('style');sheet.id='fastra-visual-style';document.head.append(sheet);}
      const family=font==='System'?'-apple-system, BlinkMacSystemFont, sans-serif':JSON.stringify(font)+', -apple-system, sans-serif';
      sheet.textContent=`body{font-family:${family};font-size:${size}px;color:${dark?'#F2F2F2':'#363636'};background:${dark?'#171717':'#FFFFFF'}}h1,h2,h3,h4,h5,h6{color:inherit}blockquote,pre.mermaid-error::before{color:${dark?'#A8A8A8':'#737373'}}a{color:${dark?'#8BB7F2':'#3F69A8'}}code,pre,blockquote,th{background:${dark?'#333333':'#ECECEC'}}td,th,blockquote,hr{border-color:${dark?'#484848':'#D7D7D7'}}mark{background:${dark?'#665200':'#FFEE9A'};color:inherit}`;
      await window.fastraUpdateMarkdownTheme?.(root,dark);
    },
    prepareAction(){if(composing)return {composing:true};fenced=true;root.contentEditable='false';changed();return {markdown:serialize(),revision};},
    completeAction(expectedSession){if(expectedSession!==session)return;fenced=false;root.contentEditable='true';},
    markdown:()=>serialize(),
    flush:()=>changed()
  };
})();
