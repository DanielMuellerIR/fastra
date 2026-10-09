/* Fastras lokale WYSIWYG-Schicht. Originalquellen liegen ausschließlich in
   diesem geschlossenen Zustand, niemals in kopiertem HTML oder DOM-Attributen. */
(() => {
  'use strict';
  const td = new TurndownService({headingStyle:'atx', bulletListMarker:'-',
    codeBlockStyle:'fenced', emDelimiter:'*', strongDelimiter:'**', preformattedCode:true,
    blankReplacement:(content,node)=>node.nodeName==='LI'?listItem(content,node):
      content.trim() ? (node.isBlock?'\n\n'+content+'\n\n':content) : (node.isBlock?'\n\n':'')});
  // Turndowns Blank-Regel läuft vor benutzerdefinierten Regeln. Auch ein
  // vollständig leerer Listenpunkt ist hier absichtlicher Dokumentinhalt.
  function listItem(content,node) {
    const parent=node.parentNode;
    const index=Array.from(parent.children).indexOf(node);
    const prefix=parent.nodeName==='OL' ? (Number(parent.getAttribute('start') || 1)+index)+'. ' : '- ';
    const indent=' '.repeat(Math.max(4,prefix.length));
    content=content.replace(/^\n+/,'').replace(/\n+$/,'').replace(/\n/g,'\n'+indent);
    return prefix+content+'\n';
  }
  td.addRule('listItem',{filter:'li',replacement:listItem});
  td.addRule('spaces',{filter:n=>n.hasAttribute('data-md-spaces'),replacement:(_,n)=>'&nbsp;'.repeat(Number(n.dataset.mdSpaces))});
  function randomToken(prefix) { return prefix+Array.from(crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16)).join('')+'END'; }
  function toMarkdown(html) {
    const holder=document.createElement('div');holder.innerHTML=html;
    holder.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
    // Geschützte Leerzeichen bleiben nach Speichern und erneutem Öffnen
    // sichtbar. Turndown würde gewöhnliche Leerzeichen zusammenziehen.
    const walker=document.createTreeWalker(holder,NodeFilter.SHOW_TEXT), texts=[];
    while(walker.nextNode())texts.push(walker.currentNode);
    for(const text of texts) {
      if(text.parentElement.closest('pre,code,[data-md-opaque],[data-tex]') || !text.data.includes('\u00a0'))continue;
      const fragment=document.createDocumentFragment();
      for(const part of text.data.split(/(\u00a0+)/)) {
        if(part.startsWith('\u00a0')){const span=document.createElement('span');span.dataset.mdSpaces=String(part.length);span.textContent='\u2060';fragment.append(span);}
        else fragment.append(document.createTextNode(part));
      }
      text.replaceWith(fragment);
    }
    // Leere editierbare Absätze sind sichtbare Zeilen. Platzhalter schützen
    // sie vor Turndowns Leerraum-Kürzung, auch am Dokumentanfang und -ende.
    const blanks=[];
    holder.querySelectorAll('p,div').forEach(n=>{
      if(n.closest('pre,code,[data-md-opaque],[data-tex]'))return;
      if(n.textContent.length || Array.from(n.children).some(c=>c.tagName!=='BR'))return;
      const count=Math.max(1,n.children.length);
      const lines=document.createDocumentFragment();
      // Eigene Absätze lassen Turndown für jede Zeile auch Zitat- und
      // Listenpräfixe ergänzen; nachträgliche Umbrüche verlören diesen Kontext.
      for(let i=0;i<count;i++) {
        const token=randomToken('FASTRAEMPTY');
        blanks.push(token);const line=n.cloneNode(false);line.textContent=token;lines.append(line);
      }
      n.replaceWith(lines);
    });
    let markdown=td.turndown(holder.innerHTML);
    for(const token of blanks)markdown=markdown.replace(token,'  ');
    return markdown;
  }
  const commonEscape=td.escape.bind(td);
  // Einzelne = sind gewöhnlicher Text. Nur benachbarte = können Fastras
  // Textmarker auslösen; Turndown schützt bereits = am Textanfang.
  td.escape=text=>commonEscape(text.replace(/&/g,'&amp;').replace(/</g,'&lt;')).replace(/^(\d+)\) /,'$1\\) ').replace(/[$~]|(?<!\\)=(?==)|(?<==)=/g,'\\$&');
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
    // Markdown-Tabellen haben keine verbundenen Zellen. Sicheres HTML bewahrt deren Position.
    if(n.querySelector('[colspan],[rowspan]')) {
      const clone=n.cloneNode(true), atoms=[];
      clone.querySelectorAll('img[data-md-src]').forEach(image=>image.setAttribute('src',image.dataset.mdSrc));
      clone.querySelectorAll('[data-md-opaque]').forEach(atom=>{
        const token=randomToken('FASTRATABLEATOM');
        atoms.push([token,opaqueSources[atom.dataset.mdOpaque] || '']);atom.replaceWith(document.createTextNode(token));
      });
      clone.querySelectorAll('[data-tex]').forEach(math=>{
        const token=randomToken('FASTRATABLEMATH');
        const source=math.classList.contains('math-block')?'\n$$\n'+math.dataset.tex+'\n$$\n':'$'+math.dataset.tex+'$';
        atoms.push([token,source]);math.replaceWith(document.createTextNode(token));
      });
      let html=sanitizePaste(clone.outerHTML);
      for(const [token,source] of atoms)html=html.replace(token,source);
      return '\n\n'+html+'\n\n';
    }
    const rows=Array.from(n.rows), width=Math.max(1,...rows.map(r=>r.cells.length));
    const lines=rows.map(r=>'| '+Array.from({length:width},(_,i)=>{
      const cell=r.cells[i];
      return cell ? toMarkdown(cell.innerHTML).replace(/\n+/g,'<br>').replace(/\|/g,'\\|') : '';
    }).join(' | ')+' |');
    if(!lines.length) return '';
    if(!Array.from(rows[0].cells).some(c=>c.tagName==='TH')) lines.unshift('| '+Array(width).fill(' ').join(' | ')+' |');
    lines.splice(1,0,'| '+Array.from({length:width},(_,i)=>{
      const align=rows[0].cells[i]?.getAttribute('align');
      return align==='center'?':---:':align==='right'?'---:':align==='left'?':---':'---';
    }).join(' | ')+' |');
    return '\n\n'+lines.join('\n')+'\n\n';
  }});
  let root, originals=new Map(), blocks=[], selection=null, base='', session='', composing=false, revision=0, fenced=false, bookmarkID=0, bookmarks=new Map(), editingCommand=false, lastInputType='';
  function normalized(node) {
    const clone=node.cloneNode(true);
    clone.querySelectorAll('[contenteditable]').forEach(n=>n.removeAttribute('contenteditable'));
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
      if(node.nodeType===Node.ELEMENT_NODE && node.hasAttribute('data-md-edit-boundary'))continue;
      if(node.nodeType===Node.TEXT_NODE && !node.textContent.trim())continue;
      const id=node.nodeType===Node.ELEMENT_NODE ? node.getAttribute('data-md-block') : null;
      const original=id===null ? null : originals.get(id);
      if(original && !used.has(id)) {
        hiddenBefore(id);used.add(id);
        output+=normalized(node)===original.snapshot ? original.source : toMarkdown(node.innerHTML)+'\n\n';
      } else if(node.nodeType===Node.ELEMENT_NODE && node.hasAttribute('data-md-empty') && !node.textContent.length && !node.querySelector('img')) {
        continue;
      } else {
        const holder=document.createElement('div');holder.append(node.cloneNode(true));
        const value=toMarkdown(holder.innerHTML);
        output+=value ? value+'\n\n' : '\n';
      }
    }
    // Verdeckte Definitionen müssen auch dann erhalten bleiben, wenn ihr
    // Nachbarabsatz gelöscht oder durch Auswahl über mehrere Blöcke ersetzt wurde.
    for(const b of blocks)if(b.hidden && !used.has('hidden:'+b.id))output+=b.source;
    return output;
  }
  function imageTransactions(){return Array.from(new Set(Array.from(root.querySelectorAll('img[data-md-image-transaction]'),n=>n.dataset.mdImageTransaction)));}
  function changed(event) {
    if(event?.inputType)lastInputType=event.inputType;
    if(composing || editingCommand)return;
    if(event?.inputType==='insertParagraph'){
      const node=getSelection().anchorNode,element=node?.nodeType===1?node:node?.parentElement,item=element?.closest('li');
      if(item && !taskCheckbox(item) && item.previousElementSibling?.tagName==='LI' && taskCheckbox(item.previousElementSibling)){
        // Den nativen Return-Schritt zuerst abschließen; verschachtelte
        // execCommand-Aufrufe innerhalb seines Input-Events sind unzuverlässig.
        queueMicrotask(()=>{if(item.isConnected && !fenced && !taskCheckbox(item))replaceListBlocks([item],addTaskCheckbox);});
      }
    }
    restoreMarkers();
    root.querySelectorAll('[data-tex],[data-md-opaque],.mermaid-render').forEach(n=>n.contentEditable='false');
    root.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.style.display='none');
    root.querySelectorAll('input[type=checkbox]').forEach(n=>{n.removeAttribute('disabled');n.contentEditable='false';});
    const markdown=serialize();
    if(markdown===base)return;
    window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'change',session,base,markdown,revision:++revision,imageTransactions:imageTransactions(),inputType:lastInputType});
    base=markdown;
  }
  function exec(name,value=null,after=null) {
    if(fenced)return;
    // WebKit ersetzt eine Auswahl über geschützte Atome sonst nur teilweise
    // und dupliziert den Block. Nur während des atomaren HTML-Ersatzes freigeben.
    const protectedNodes=name==='insertHTML'?Array.from(root.querySelectorAll('[contenteditable=false]')):[];
    protectedNodes.forEach(n=>n.removeAttribute('contenteditable'));
    try { restoreSelection();editingCommand=true;lastInputType='';document.execCommand(name,false,value); }
    finally {
      editingCommand=false;
      protectedNodes.forEach(n=>{if(n.isConnected)n.contentEditable='false';});
      root.querySelectorAll('[data-tex],[data-md-opaque],.mermaid-render').forEach(n=>n.contentEditable='false');
      root.querySelectorAll('input[type=checkbox]').forEach(n=>{n.removeAttribute('disabled');n.contentEditable='false';});
    }
    after?.();
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
  function selectedItems() {
    restoreSelection();const range=getSelection().getRangeAt(0);
    const element=range.startContainer.nodeType===1?range.startContainer:range.startContainer.parentElement;
    if(range.collapsed){const item=element.closest('li');return item && root.contains(item)?[item]:[];}
    return Array.from(root.querySelectorAll('li')).filter(n=>range.intersectsNode(n) &&
      (!n.childNodes.length || Array.from(n.childNodes).some(child=>
        !(child.nodeType===1 && child.matches('ul,ol')) && range.intersectsNode(child))));
  }
  function editListBlocks(items,transform) {
    const children=Array.from(root.children), affected=children.filter(n=>items.some(item=>n.contains(item)));
    if(!affected.length)return;
    // Der Ersatz umfasst auch Absätze zwischen zwei ausgewählten Listen.
    const interval=children.slice(children.indexOf(affected[0]),children.indexOf(affected.at(-1))+1);
    const holder=document.createElement('div'), originals=interval.flatMap(n=>Array.from(n.querySelectorAll('li')));
    interval.forEach(n=>holder.append(n.cloneNode(true)));
    const clones=Array.from(holder.querySelectorAll('li')), selected=items.map(n=>clones[originals.indexOf(n)]);
    const live=getSelection().rangeCount?getSelection().getRangeAt(0):null;
    function point(item,clone,node,offset,end) {
      if(!node || !item.contains(node))return [clone,end?clone.childNodes.length:0];
      const path=[];while(node!==item){path.unshift(Array.from(node.parentNode.childNodes).indexOf(node));node=node.parentNode;}
      for(const index of path)clone=clone.childNodes[index];return [clone,offset];
    }
    const first=selected[0],last=selected.at(-1), collapsed=live?.collapsed ?? true;
    const start=point(items[0],first,live?.startContainer,live?.startOffset,false);
    const end=point(items.at(-1),last,live?.endContainer,live?.endOffset,true);
    function marker(position,name) {
      const span=document.createElement('span');span.setAttribute(name,'');span.textContent='\u200b';
      const r=document.createRange();r.setStart(...position);r.collapse(true);r.insertNode(span);
    }
    if(!collapsed)marker(end,'data-md-selection-end');
    marker(start,'data-md-selection-start');
    if(transform(selected)===false)return;
    // WebKit behält beim Ersetzen einer Liste sonst leere Unterlisten zurück
    // oder zieht benachbarte Absätze hinein. Neutrale Grenzen verhindern dies.
    // Auch vor dem Ersatz markieren: Undo stellt so die ursprüngliche Auswahl her.
    if(live){
      if(!collapsed)marker(point(items.at(-1),items.at(-1),live.endContainer,live.endOffset,true),'data-md-selection-end');
      marker(point(items[0],items[0],live.startContainer,live.startOffset,false),'data-md-selection-start');
    }
    function boundary(neighbor){
      const node=neighbor?.hasAttribute('data-md-edit-boundary')?neighbor:document.createElement('p');
      node.dataset.mdEditBoundary='';if(!node.firstChild)node.append(document.createTextNode('\u200b'));node.style.display='';return node;
    }
    const before=boundary(affected[0].previousElementSibling),after=boundary(affected.at(-1).nextElementSibling);
    affected[0].before(before);affected.at(-1).after(after);
    const range=document.createRange();range.setStart(before.firstChild,0);range.setEnd(after.firstChild,1);
    selection=range;getSelection().removeAllRanges();getSelection().addRange(range);
    // Die Grenzen gehören zu beiden Undo-Zuständen. Ihre Knoten bleiben
    // erhalten, weil WebKits Redo sie als Einfügeanker verwendet.
    exec('insertHTML',before.outerHTML+holder.innerHTML+after.outerHTML,restoreMarkers);
  }
  function restoreMarkers() {
    if(!root)return;
    const start=root.querySelector('span[data-md-selection-start]'),end=root.querySelector('span[data-md-selection-end]');
    if(!start)return;
    const range=document.createRange();range.setStartBefore(start);
    if(end)range.setEndBefore(end);else range.collapse(true);
    start.remove();end?.remove();getSelection().removeAllRanges();getSelection().addRange(range);selection=range.cloneRange();
  }
  function replaceListBlocks(items,transform) {
    editListBlocks(items,selected=>selected.forEach(transform));
  }
  function nestItems(items,outdent) {
    editListBlocks(items,selected=>{
      const top=selected.filter(n=>!selected.some(parent=>parent!==n && parent.contains(n)));
      const groups=[];
      for(const item of top){const group=groups.at(-1);if(group && group.at(-1).nextElementSibling===item)group.push(item);else groups.push([item]);}
      let changed=false;
      for(const group of groups){
        const first=group[0],last=group.at(-1),list=first.parentElement;
        if(outdent){
          const owner=list.parentElement;if(owner.tagName!=='LI')continue;
          // Nachfolgende Geschwister bleiben unter dem ausgerückten Punkt.
          const following=[];let next=last.nextElementSibling;while(next){following.push(next);next=next.nextElementSibling;}
          if(following.length){const tail=document.createElement(list.tagName);tail.append(...following);last.append(tail);}
          let previous=owner;for(const item of group){previous.after(item);previous=item;}
          if(!list.children.length)list.remove();
        }else{
          const previous=first.previousElementSibling;if(!previous || previous.tagName!=='LI')continue;
          let nested=previous.lastElementChild;
          if(nested?.tagName!==list.tagName){nested=document.createElement(list.tagName);previous.append(nested);}
          nested.append(...group);
        }
        changed=true;
      }
      return changed;
    });
  }
  function taskCheckbox(item) {
    return Array.from(item.querySelectorAll('input[type=checkbox]')).find(n=>n.closest('li')===item);
  }
  function addTaskCheckbox(item) {
    const input=document.createElement('input');input.type='checkbox';input.contentEditable='false';item.prepend(input,document.createTextNode(' '));
  }
  function taskList() {
    let items=selectedItems();
    if(!items.length){exec('insertUnorderedList');items=selectedItems();}
    const remove=items.length>0 && items.every(taskCheckbox);
    replaceListBlocks(items,item=>{
      const existing=taskCheckbox(item);
      if(remove){existing?.remove();return;}
      if(!existing)addTaskCheckbox(item);
    });
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
      root.querySelectorAll('input[type=checkbox]').forEach(n=>{n.removeAttribute('disabled');n.contentEditable='false';});
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
      const copySelection=e=>{
        const s=getSelection();if(!s.rangeCount || s.isCollapsed)return;
        const rich=document.createElement('div');rich.append(s.getRangeAt(0).cloneContents());
        const markdown=toMarkdown(rich.innerHTML);
        const html=rich.cloneNode(true);
        html.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
        html.querySelectorAll('*').forEach(n=>{for(const a of Array.from(n.attributes))if(a.name.startsWith('data-md-') || a.name==='contenteditable')n.removeAttribute(a.name);});
        e.preventDefault();e.stopPropagation();
        window.webkit.messageHandlers.markdownCopy.postMessage({plain:s.toString(),html:html.innerHTML,markdown,session});
        if(e.type==='cut')exec('insertHTML','');
      };
      root.addEventListener('copy',copySelection);
      root.addEventListener('cut',copySelection);
      root.addEventListener('paste',e=>{
        e.preventDefault();
        if(e.clipboardData.getData('application/x-fastra-markdown')){window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'pasteMarkdown',session,bookmark:window.fastraVisual.bookmark()});return;}
        if(e.clipboardData.files.length){window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'pasteImage',session,bookmark:window.fastraVisual.bookmark()});return;}
        const html=e.clipboardData.getData('text/html');
        exec(html ? 'insertHTML' : 'insertText',html ? sanitizePaste(html) : e.clipboardData.getData('text/plain'));
      });
      root.addEventListener('drop',e=>{
        e.preventDefault();
        const r=document.caretRangeFromPoint?.(e.clientX,e.clientY);
        if(r && root.contains(r.commonAncestorContainer)){selection=r;getSelection().removeAllRanges();getSelection().addRange(r);}
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'drop',session,paths:Array.from(e.dataTransfer.files,f=>f.name)});
      });
      root.addEventListener('dragover',e=>e.preventDefault());
      root.addEventListener('keydown',e=>{
        if(e.key!=='Tab' || e.altKey || e.ctrlKey || e.metaKey || e.isComposing || composing || fenced)return;
        e.preventDefault();
        const items=selectedItems();
        if(items.length)nestItems(items,e.shiftKey);
        else if(!e.shiftKey){
          const node=getSelection().anchorNode, element=node?.nodeType===1?node:node?.parentElement;
          if(element?.closest('pre'))exec('insertText','\t');
          else exec('insertHTML','<span style="white-space:pre">&nbsp;&nbsp;&nbsp;&nbsp;</span>');
        }
      });
      root.addEventListener('click',e=>{
        if(fenced){e.preventDefault();return;}
        if(e.target.closest('a'))e.preventDefault();
        if(e.target.matches('input[type=checkbox]') && !fenced){
          e.preventDefault();const input=e.target, item=input.closest('li');
          if(item)replaceListBlocks([item],clone=>{
            const checkbox=taskCheckbox(clone);
            // Beim click ist WebKits checked-Property bereits umgeschaltet;
            // das Attribut enthält noch den Zustand vor diesem Undo-Schritt.
            checkbox.toggleAttribute('checked',!input.hasAttribute('checked'));
          });
        }
      });
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
        case 'taskList':taskList();break;
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
    caret(x,y){const r=document.caretRangeFromPoint?.(x,y);if(!r || !root.contains(r.commonAncestorContainer))return null;selection=r;getSelection().removeAllRanges();getSelection().addRange(r);return window.fastraVisual.bookmark();},
    bookmark(existing){if(existing)return bookmarks.has(existing)?existing:null;restoreSelection();const key=String(++bookmarkID);bookmarks.set(key,{range:selection.cloneRange(),base:serialize()});return key;},
    insertBookmarked(key,html,atoms,transaction,imageSources){if(fenced)return false;const saved=bookmarks.get(key);bookmarks.delete(key);if(!saved || saved.base!==serialize() || !root.contains(saved.range.commonAncestorContainer))return false;Object.assign(opaqueSources,atoms || {});const template=document.createElement('template');template.innerHTML=html;if(transaction)template.content.querySelectorAll('img').forEach(n=>{if(imageSources.includes(n.getAttribute('src')))n.dataset.mdImageTransaction=transaction;});template.content.querySelectorAll('[data-tex]').forEach(n=>n.textContent=n.dataset.tex);html=template.innerHTML;selection=saved.range;getSelection().removeAllRanges();getSelection().addRange(selection);exec('insertHTML',html);window.fastraEnhanceMarkdown?.(root).then(()=>{root.querySelectorAll('[data-tex],.mermaid-render').forEach(n=>n.contentEditable='false');});return true;},
    async updateStyle(font,size,dark){
      let sheet=document.getElementById('fastra-visual-style');if(!sheet){sheet=document.createElement('style');sheet.id='fastra-visual-style';document.head.append(sheet);}
      const family=font==='System'?'-apple-system, BlinkMacSystemFont, sans-serif':JSON.stringify(font)+', -apple-system, sans-serif';
      sheet.textContent=`body{font-family:${family};font-size:${size}px;color:${dark?'#F2F2F2':'#363636'};background:${dark?'#171717':'#FFFFFF'}}h1,h2,h3,h4,h5,h6{color:inherit}blockquote,pre.mermaid-error::before{color:${dark?'#A8A8A8':'#737373'}}a{color:${dark?'#8BB7F2':'#3F69A8'}}code,pre,blockquote,th{background:${dark?'#333333':'#ECECEC'}}td,th,blockquote,hr{border-color:${dark?'#484848':'#D7D7D7'}}mark{background:${dark?'#665200':'#FFEE9A'};color:inherit}`;
      await window.fastraUpdateMarkdownTheme?.(root,dark);
    },
    prepareAction(){if(composing)return {composing:true};fenced=true;root.contentEditable='false';changed();return {markdown:serialize(),revision,imageTransactions:imageTransactions(),inputType:lastInputType};},
    completeAction(expectedSession){if(expectedSession!==session)return;fenced=false;root.contentEditable='true';},
    rollbackImageChange(inputType,previous){
      editingCommand=true;
      try{document.execCommand(inputType==='historyUndo'?'redo':'undo');}finally{editingCommand=false;}
      base=previous;
    },
    markdown:()=>serialize(),
    flush:()=>changed()
  };
})();
