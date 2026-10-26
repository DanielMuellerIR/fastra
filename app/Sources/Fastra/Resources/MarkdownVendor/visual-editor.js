/* Fastras lokale WYSIWYG-Schicht. Originalquellen liegen ausschließlich in
   diesem geschlossenen Zustand, niemals in kopiertem HTML oder DOM-Attributen. */
(() => {
  'use strict';
  // Turndowns Blank-Regel darf absichtliche Leerzeichen in Code nicht verwerfen.
  const td = new TurndownService({headingStyle:'atx', bulletListMarker:'-',
    codeBlockStyle:'fenced', emDelimiter:'*', strongDelimiter:'**', preformattedCode:true,
    blankReplacement:(content,node)=>node.nodeName==='CODE' && node.textContent.length?'`'+node.textContent+'`':node.nodeName==='TABLE'?tableMarkdown(node):node.nodeName==='LI'?listItem(content,node):
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
  // Eine ATX-Überschrift endet am Quellzeilenende; ihr sichtbarer Umbruch
  // braucht deshalb ein Inline-HTML-Element statt eines Markdown-Zeilenendes.
  td.addRule('headingLineBreak',{
    filter:n=>n.nodeName==='BR' && !!n.closest('h1,h2,h3,h4,h5,h6'),
    replacement:(_,node)=>{
      const heading=node.closest('h1,h2,h3,h4,h5,h6'),tail=document.createRange();
      tail.setStartAfter(node);tail.setEnd(heading,heading.childNodes.length);
      // Ein einzelnes abschließendes BR ist WebKits Cursor-Platzhalter.
      if(heading.querySelectorAll('br').length===1 && !tail.toString() && !tail.cloneContents().querySelector('img,[data-tex]'))return '';
      return '<br>';
    }
  });
  td.addRule('spaces',{filter:n=>n.hasAttribute('data-md-spaces'),replacement:(_,n)=>'&nbsp;'.repeat(Number(n.dataset.mdSpaces))});
  function randomToken(prefix) { return prefix+Array.from(crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16)).join('')+'END'; }
  function toMarkdown(html) {
    const holder=document.createElement('div');holder.innerHTML=html;
    holder.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
    // Markdown-Code-Spannen normalisieren Zeilenenden zu Leerzeichen.
    // Getrennte Spannen erhalten den sichtbaren Umbruch und die Codeformatierung.
    holder.querySelectorAll('code').forEach(code=>{
      if(code.closest('pre') || !code.querySelector('br'))return;
      code.querySelectorAll('br').forEach(br=>br.replaceWith(document.createTextNode('\n')));
      const fragment=document.createDocumentFragment(),parts=code.textContent.split('\n');
      parts.forEach((part,index)=>{
        if(index)fragment.append(document.createElement('br'));
        if(part){const span=document.createElement('code');span.textContent=part;fragment.append(span);}
      });
      code.replaceWith(fragment);
    });
    // Geschützte Leerzeichen bleiben nach Speichern und erneutem Öffnen
    // sichtbar. Turndown würde gewöhnliche Leerzeichen zusammenziehen.
    const walker=document.createTreeWalker(holder,NodeFilter.SHOW_TEXT), texts=[],tableSpaces=[];
    while(walker.nextNode())texts.push(walker.currentNode);
    for(const text of texts) {
      if(text.parentElement.closest('pre,code,[data-md-opaque],[data-tex]'))continue;
      if(text.parentElement.closest('td,th') && /[\r\n]/.test(text.data))text.data=text.data.replace(/\r\n?|\n/g,()=>{
        const token=randomToken('FASTRATABLEBREAK');tableSpaces.push([token,'<br>']);return token;
      });
      // Der äußere Turndown-Durchlauf normalisiert Tabellen bereits vor
      // tableMarkdown. Zell-Leerzeichen deshalb vorher als Tokens schützen.
      if(text.parentElement.closest('table') && text.data.includes(' '))text.data=text.data.replace(/ +/g,spaces=>{
        const token=randomToken('FASTRATABLESPACES');tableSpaces.push([token,'&#32;'.repeat(spaces.length)]);return token;
      });
      if(!text.data.includes('\u00a0'))continue;
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
    for(const [token,spaces] of tableSpaces)markdown=markdown.replace(token,()=>spaces);
    for(const token of blanks)markdown=markdown.replace(token,'  ');
    return markdown;
  }
  const commonEscape=td.escape.bind(td);
  // Einzelne = sind gewöhnlicher Text. Nur benachbarte = können Fastras
  // Textmarker auslösen; Turndown schützt bereits = am Textanfang.
  td.escape=text=>commonEscape(text.replace(/&/g,'&amp;').replace(/</g,'&lt;')).replace(/^(\d+)\) /,'$1\\) ').replace(/[$~]|(?<!\\)=(?==)|(?<==)=/g,'\\$&');
  let opaqueSources={};
  td.addRule('opaque',{filter:n=>n.hasAttribute('data-md-opaque'),replacement:(_,n)=>opaqueSources[n.dataset.mdOpaque] || ''});
  function adjacentCharacter(node,forward) {
    while(node && !/^(DIV|P|H[1-6]|LI|TD|TH|BLOCKQUOTE)$/.test(node.nodeName)) {
      const sibling=forward?node.nextSibling:node.previousSibling;
      if(sibling){const text=Array.from(sibling.textContent);if(text.length)return forward?text[0]:text.at(-1);node=sibling;}
      else node=node.parentNode;
    }
    return '';
  }
  function inlineFormat(content,node,tag,delimiter) {
    const text=Array.from(node.textContent.trim()),first=text[0] || '',last=text.at(-1) || '';
    const punctuation=c=>/[\p{P}\p{S}]/u.test(c),space=c=>!c || /\s/u.test(c);
    const before=adjacentCharacter(node,false),after=adjacentCharacter(node,true);
    // CommonMark erkennt z. B. a**!**b nicht als Auszeichnung. Inline-HTML
    // erhält solche Grenzen und verschachtelte Auszeichnungen verlustfrei.
    const unsafe=(punctuation(first) && !space(before) && !punctuation(before))
      || (punctuation(last) && !space(after) && !punctuation(after))
      || !!node.querySelector('strong,b,em,i,mark,del,s,strike');
    return unsafe?'<'+tag+'>'+content+'</'+tag+'>':delimiter+content+delimiter;
  }
  td.addRule('strong',{filter:['strong','b'],replacement:(c,n)=>inlineFormat(c,n,'strong','**')});
  td.addRule('emphasis',{filter:['em','i'],replacement:(c,n)=>inlineFormat(c,n,'em','*')});
  td.addRule('highlight', {filter:'mark', replacement:(c,n)=>n.parentElement?.closest('mark')?c:(c.trim()?inlineFormat(c.trim(),n,'mark','=='):'')});
  td.addRule('strike', {filter:['del','s','strike'], replacement:c => '~~'+c+'~~'});
  // Entitäten an Formatgrenzen ändern CommonMarks Trennzeichen-Erkennung:
  // **Text&nbsp;**danach wird als Klartext gelesen. Inline-HTML bewahrt in
  // diesem Fall sowohl die Auszeichnung als auch ihre geschützten Leerzeichen.
  td.addRule('styledSpaces', {
    filter:n=>['STRONG','B','EM','I','MARK','DEL','S','STRIKE'].includes(n.nodeName)
      && !!n.querySelector('[data-md-spaces]'),
    replacement:(content,node)=>{
      const tag={B:'strong',I:'em',S:'del',STRIKE:'del'}[node.nodeName] || node.nodeName.toLowerCase();
      return '<'+tag+'>'+content+'</'+tag+'>';
    }
  });
  // Diese erlaubten HTML-Auszeichnungen haben kein Markdown-Gegenstück.
  td.addRule('inlineHTML',{
    filter:['u','ins','small','sub','sup','kbd','samp','var','q','cite','abbr','dfn'],
    replacement:(content,node)=>{
      const tag=node.nodeName.toLowerCase(),attributes=Array.from(node.attributes)
        .filter(a=>['title','dir','lang'].includes(a.name))
        .map(a=>' '+a.name+'="'+a.value.replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;')+'"').join('');
      return '<'+tag+attributes+'>'+content+'</'+tag+'>';
    }
  });
  td.addRule('images', {filter:'img', replacement:(_,n) => {
    const src=n.getAttribute('data-md-src');
    const title=n.getAttribute('title');
    return src ? '!['+(n.alt || '').replace(/[\\[\]]/g,'\\$&')+'](<'+src.replace(/</g,'%3C').replace(/>/g,'%3E')+'>'+(title?' "'+title.replace(/[\\"]/g,'\\$&')+'"':'')+')' : '';
  }});
  function mathMarkdown(n) {return n.classList.contains('math-block') ? '\n\n$$\n'+n.dataset.tex+'\n$$\n\n' : '$'+n.dataset.tex+'$';}
  td.addRule('math', {filter:n => n.hasAttribute('data-tex'), replacement:(_,n) => mathMarkdown(n)});
  td.addRule('task', {filter:n => n.nodeName==='INPUT' && n.type==='checkbox',
    replacement:(_,n) => n.checked ? '[x] ' : '[ ] '});
  td.addRule('fence', {filter:'pre', replacement:(_,n) => {
    const code=n.querySelector('code'), text=(code || n).textContent.replace(/\n$/,'');
    const runs=text.match(/`+/g) || [], fence='`'.repeat(Math.max(3,...runs.map(x=>x.length+1)));
    const language=code?.className.match(/(?:^|\s)language-([\w+-]+)/)?.[1] || '';
    return '\n\n'+fence+language+'\n'+text+'\n'+fence+'\n\n';
  }});
  function tableMarkdown(n) {
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
      for(const [token,source] of atoms)html=html.replace(token,()=>source);
      return '\n\n'+html+'\n\n';
    }
    const rows=Array.from(n.rows), width=Math.max(1,...rows.map(r=>r.cells.length));
    const lines=rows.map(r=>'| '+Array.from({length:width},(_,i)=>{
      const cell=r.cells[i];
      if(!cell)return '';
      const clone=cell.cloneNode(true),atoms=[];
      // WebKit schreibt Umbrüche in pre-wrap-Zellen als Text-Newlines.
      // Vor Turndowns Leerraum-Normalisierung in echte Umbrüche überführen.
      const walker=document.createTreeWalker(clone,NodeFilter.SHOW_TEXT),texts=[];
      while(walker.nextNode())texts.push(walker.currentNode);
      for(const text of texts){
        if(!text.data.includes('\n') || text.parentElement.closest('pre,code,[data-tex],[data-md-opaque]'))continue;
        const fragment=document.createDocumentFragment();text.data.split('\n').forEach((part,index)=>{
          if(index)fragment.append(document.createElement('br'));fragment.append(document.createTextNode(part));
        });text.replaceWith(fragment);
      }
      clone.querySelectorAll('br').forEach(br=>{
        if(br.closest('pre,code,[data-tex],[data-md-opaque]'))return;
        const token=randomToken('FASTRATABLEBREAK');atoms.push([token,'<br>']);br.replaceWith(document.createTextNode(token));
      });
      // Formeln werden vor dem GFM-Parser ausgeblendet: zusätzliche Pipe-
      // Escapes würden ihre TeX-Bedeutung ändern. Opaque HTML dagegen braucht
      // den vom Tabellenparser entfernten Pipe-Escape wieder genau einmal.
      clone.querySelectorAll('[data-tex],[data-md-opaque]').forEach(atom=>{
        if(!clone.contains(atom))return;
        const token=randomToken('FASTRATABLECELL');
        const source=atom.hasAttribute('data-tex')?mathMarkdown(atom):(opaqueSources[atom.dataset.mdOpaque] || '').replace(/\|/g,'\\|');
        atoms.push([token,source]);atom.replaceWith(document.createTextNode(token));
      });
      let source=toMarkdown(clone.innerHTML).replace(/\n+/g,'<br>').replace(/\|/g,'\\|');
      for(const [token,original] of atoms)source=source.replace(token,()=>original);
      return source;
    }).join(' | ')+' |');
    if(!lines.length) return '';
    if(!Array.from(rows[0].cells).some(c=>c.tagName==='TH')) lines.unshift('| '+Array(width).fill(' ').join(' | ')+' |');
    lines.splice(1,0,'| '+Array.from({length:width},(_,i)=>{
      const align=rows[0].cells[i]?.getAttribute('align');
      return align==='center'?':---:':align==='right'?'---:':align==='left'?':---':'---';
    }).join(' | ')+' |');
    return '\n\n'+lines.join('\n')+'\n\n';
  }
  td.addRule('table', {filter:'table', replacement:(_,n) => tableMarkdown(n)});
  let root, originals=new Map(), blocks=[], hiddenPrefixes=new Map(), selection=null, base='', session='', composing=false, revision=0, fenced=false, bookmarkID=0, bookmarks=new Map(), editingCommand=false, lastInputType='';
  let actionFenced=false, clipboardBookmark=null, imageFenceRevision=null, lastImageTransactions="[]";
  function outlineHeadings(){return Array.from(root.querySelectorAll('h1,h2,h3,h4,h5,h6')).filter(n=>!n.closest('[data-md-opaque],[data-tex]') && !n.hasAttribute('data-md-outline-ignore'));}
  function outlinePosition(){
    const node=getSelection().anchorNode,element=node?.nodeType===1?node:node?.parentElement;
    if(!element || !root.contains(element))return -1;
    let index=-1;
    outlineHeadings().forEach((heading,i)=>{if(heading.contains(element) || heading===element || (heading.compareDocumentPosition(element)&Node.DOCUMENT_POSITION_FOLLOWING))index=i;});
    return index;
  }
  function updateFence(){fenced=actionFenced || clipboardBookmark!==null || imageFenceRevision!==null;root.contentEditable=fenced?'false':'true';}
  function normalized(node) {
    const clone=node.cloneNode(true);
    clone.querySelectorAll('[contenteditable]').forEach(n=>n.removeAttribute('contenteditable'));
    clone.querySelectorAll('[data-md-selected-image]').forEach(n=>n.removeAttribute('data-md-selected-image'));
    clone.querySelectorAll('[data-md-outline-ignore]').forEach(n=>n.removeAttribute('data-md-outline-ignore'));
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
  function blockStructure(html) {
    const holder=document.createElement('div');holder.innerHTML=html;
    function signature(node) {
      if(node.nodeType!==Node.ELEMENT_NODE)return '';
      const children=Array.from(node.childNodes,signature).join('');
      return /^(DIV|P|H[1-6]|LI|UL|OL|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|TD|TH|PRE|HR|BR)$/.test(node.nodeName)
        ? '('+node.nodeName+children+')' : children;
    }
    return Array.from(holder.childNodes,signature).join('');
  }
  function serialize() {
    const used=new Set();let output='';
    function hiddenBefore(id) {
      for(const b of hiddenPrefixes.get(id) || []){output+=b.source;used.add('hidden:'+b.id);}
    }
    for(const node of root.childNodes) {
      if(node.nodeType===Node.ELEMENT_NODE && node.hasAttribute('data-md-edit-boundary'))continue;
      if(node.nodeType===Node.TEXT_NODE && !node.textContent.trim())continue;
      const id=node.nodeType===Node.ELEMENT_NODE ? node.getAttribute('data-md-block') : null;
      const original=id===null ? null : originals.get(id);
      if(original && !used.has(id)) {
        hiddenBefore(id);used.add(id);
        const snapshot=normalized(node);
        if(snapshot===original.snapshot)output+=original.source;
        else {
          // Text- und Inline-Änderungen behalten die vorhandenen Zeilenenden.
          // Neue Blockarten brauchen dagegen eine sichere Absatztrennung:
          // Eine Überschrift vor Fließtext darf nicht mit ihm verschmelzen.
          const suffix=blockStructure(snapshot)===original.structure ? original.source.match(/[\r\n]*$/)[0] : '\n\n';
          output+=toMarkdown(node.innerHTML)+suffix;
        }
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
    root.querySelectorAll('[data-md-block]').forEach(block=>{
      const original=originals.get(block.dataset.mdBlock);
      if(!original?.ignoredHeadings.length && !block.querySelector('[data-md-outline-ignore]'))return;
      const unchanged=original && normalized(block)===original.snapshot;
      const headings=Array.from(block.querySelectorAll('h1,h2,h3,h4,h5,h6'));
      headings.forEach((heading,index)=>{
        if(unchanged && original.ignoredHeadings.includes(index))heading.setAttribute('data-md-outline-ignore','true');
        else heading.removeAttribute('data-md-outline-ignore');
      });
    });
    if(event?.inputType==='insertParagraph'){
      const node=getSelection().anchorNode,element=node?.nodeType===1?node:node?.parentElement,item=element?.closest('li');
      if(item && !taskCheckbox(item) && item.previousElementSibling?.tagName==='LI' && taskCheckbox(item.previousElementSibling)){
        // Den nativen Return-Schritt zuerst abschließen; verschachtelte
        // execCommand-Aufrufe innerhalb seines Input-Events sind unzuverlässig.
        queueMicrotask(()=>{if(item.isConnected && !fenced && !taskCheckbox(item))replaceListBlocks([item],addTaskCheckbox);});
      }
    }
    if(event?.inputType==='insertText') {
      const node=getSelection().anchorNode,element=node?.nodeType===1?node:node?.parentElement;
      const paragraph=element?.closest('p');
      if(paragraph && !paragraph.closest('li,pre,code') && /^[-+*][ \u00a0]$/.test(paragraph.textContent)) {
        // Erst den Tastendruck abschließen, dann einen nativen Undo-Schritt
        // für die Listenstruktur anlegen; kein execCommand im Input-Event.
        queueMicrotask(()=>{
          if(!paragraph.isConnected || fenced || !/^[-+*][ \u00a0]$/.test(paragraph.textContent))return;
          const range=document.createRange();range.selectNode(paragraph);
          getSelection().removeAllRanges();getSelection().addRange(range);selection=range;
          exec('insertHTML','<ul><li><br></li></ul>');
        });
      }
    }
    restoreMarkers();
    root.querySelectorAll('[data-tex],[data-md-opaque],.mermaid-render').forEach(n=>n.contentEditable='false');
    root.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.style.display='none');
    root.querySelectorAll('input[type=checkbox]').forEach(n=>{n.removeAttribute('disabled');n.contentEditable='false';});
    const markdown=serialize();
    if(markdown===base)return;
    const imageIDs=imageTransactions(), imageState=JSON.stringify(imageIDs.slice().sort());
    if(imageState!==lastImageTransactions){imageFenceRevision=revision+1;lastImageTransactions=imageState;updateFence();}
    window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'change',session,base,markdown,revision:++revision,imageTransactions:imageIDs,inputType:lastInputType});
    base=markdown;
  }
  function selectImage(image) {
    root.focus();const range=document.createRange();range.selectNode(image);
    getSelection().removeAllRanges();getSelection().addRange(range);selection=range.cloneRange();
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
    restoreSelection();const current=getSelection().getRangeAt(0),element=current.startContainer.nodeType===1?current.startContainer:current.startContainer.parentElement;
    const cell=element.closest('td,th');
    if(cell && cell.contains(current.endContainer)){
      const clone=cell.cloneNode(true);
      clone.querySelectorAll('mark,code,strong,b,em,i,del,s,strike,a,u,font,span').forEach(n=>{
        if(!n.closest('[data-tex],[data-md-opaque]'))n.replaceWith(...n.childNodes);
      });
      tables.command('pasteCell',clone.innerHTML);return;
    }
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
    replaceVisualBlocks(selected,html);
  }
  function formatParagraphBlocks(tag) {
    restoreSelection();const range=getSelection().getRangeAt(0);
    const blocks=Array.from(root.children).filter(n=>!n.hasAttribute('data-md-edit-boundary') && range.intersectsNode(n));
    const paragraphs=blocks.map(n=>n.children.length===1 && n.firstElementChild.matches('p,h1,h2,h3,h4,h5,h6')?n.firstElementChild:null);
    if(!blocks.length || paragraphs.some(n=>!n))return false;
    const wrapper=blocks[0].cloneNode(false),formatted=document.createElement(tag);
    for(const paragraph of paragraphs){
      const item=document.createElement(tag==='blockquote'?'p':'li');
      item.append(...paragraph.cloneNode(true).childNodes);formatted.append(item);
    }
    function position(node,offset,end) {
      const index=paragraphs.findIndex(p=>p.contains(node));
      if(index<0){const item=end?formatted.lastChild:formatted.firstChild;return [item,end?item.childNodes.length:0];}
      const path=[];while(node!==paragraphs[index]){path.unshift(Array.from(node.parentNode.childNodes).indexOf(node));node=node.parentNode;}
      let clone=formatted.children[index];for(const part of path)clone=clone.childNodes[part];return [clone,offset];
    }
    const start=position(range.startContainer,range.startOffset,false),end=position(range.endContainer,range.endOffset,true);
    function marker(point,name){const span=document.createElement('span');span.setAttribute(name,'');span.textContent='\u200b';const r=document.createRange();r.setStart(...point);r.collapse(true);r.insertNode(span);}
    if(!range.collapsed)marker(end,'data-md-selection-end');
    marker(start,'data-md-selection-start');
    wrapper.append(formatted);replaceVisualBlocks(blocks,wrapper.outerHTML);return true;
  }
  function listCommand(ordered) {
    if(!selectedItems().length && formatParagraphBlocks(ordered?'ol':'ul'))return;
    exec(ordered?'insertOrderedList':'insertUnorderedList');
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
    replaceVisualBlocks(affected,holder.innerHTML);
  }
  function replaceVisualBlocks(affected,html) {
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
    exec('insertHTML',before.outerHTML+html+after.outerHTML,restoreMarkers);
  }
  function replaceFormattedSelection(range,fragment) {
    const children=Array.from(root.children),affected=children.filter(n=>!n.hasAttribute('data-md-edit-boundary') && range.intersectsNode(n));
    if(!affected.length)return;
    const interval=children.slice(children.indexOf(affected[0]),children.indexOf(affected.at(-1))+1),holder=document.createElement('div');
    interval.forEach(n=>holder.append(n.cloneNode(true)));
    function position(node,offset) {
      if(node===root)return [holder,interval.filter(n=>Array.from(root.childNodes).indexOf(n)<offset).length];
      const path=[];let top=node;
      while(top.parentNode!==root){path.unshift(Array.from(top.parentNode.childNodes).indexOf(top));top=top.parentNode;}
      let clone=holder.childNodes[interval.indexOf(top)];for(const index of path)clone=clone.childNodes[index];
      return [clone,offset];
    }
    const copied=document.createRange();copied.setStart(...position(range.startContainer,range.startOffset));copied.setEnd(...position(range.endContainer,range.endOffset));
    copied.deleteContents();
    const start=document.createElement('span'),end=document.createElement('span');
    start.dataset.mdSelectionStart='';end.dataset.mdSelectionEnd='';start.textContent=end.textContent='\u200b';
    fragment.prepend(start);fragment.append(end);copied.insertNode(fragment);
    // WebKit fügt ganze Listen/Tabellen sonst in den ersten ausgewählten
    // Absatz oder die erste Zelle ein. Neutrale Blockgrenzen verhindern dies.
    replaceVisualBlocks(interval,holder.innerHTML);
  }
  function replaceTable(table,transform) {
    const block=Array.from(root.children).find(n=>n.contains(table));
    if(!block)return false;
    const clone=block.cloneNode(true),index=Array.from(block.querySelectorAll('table')).indexOf(table);
    const copied=clone.querySelectorAll('table')[index],target=transform(copied);
    const cell=copied.rows[target.row]?.cells[target.column];if(!cell)return false;
    const marker=document.createElement('span');marker.dataset.mdSelectionStart='';marker.textContent='\u200b';cell.prepend(marker);
    const live=getSelection().rangeCount?getSelection().getRangeAt(0):null;
    if(live){
      if(!live.collapsed){const end=marker.cloneNode(true);end.removeAttribute('data-md-selection-start');end.dataset.mdSelectionEnd='';const r=live.cloneRange();r.collapse(false);r.insertNode(end);}
      const r=live.cloneRange();r.collapse(true);r.insertNode(marker.cloneNode(true));
    }
    replaceVisualBlocks([block],clone.outerHTML);return true;
  }
  function restoreMarkers() {
    if(!root)return;
    const start=root.querySelector('span[data-md-selection-start]'),end=root.querySelector('span[data-md-selection-end]');
    if(!start)return;
    const range=document.createRange();range.setStartBefore(start);
    if(end)range.setEndBefore(end);else range.collapse(true);
    const startParent=start.parentNode,endParent=end?.parentNode;
    // Marker teilen Textknoten. Nach ihrer Entfernung wieder zusammenführen,
    // damit die native Schriftformung dieselben Textläufe wie beim Öffnen sieht.
    start.remove();end?.remove();startParent.normalize();if(endParent && endParent!==startParent)endParent.normalize();
    getSelection().removeAllRanges();getSelection().addRange(range);selection=range.cloneRange();
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
    if(!items.length){listCommand(false);items=selectedItems();}
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
      const language=n.tagName==='CODE'?n.className.match(/(?:^|\s)language-([\w+-]+)(?=\s|$)/)?.[1]:null;
      for(const a of Array.from(n.attributes))if(!['href','src','alt','title','align','colspan','rowspan','start','type','checked'].includes(a.name))n.removeAttribute(a.name);
      // Nur die Codesprache trägt Formatsemantik; fremde CSS-Klassen bleiben entfernt.
      if(language)n.className='language-'+language;
      if(n.tagName==='IMG'){const src=n.getAttribute('src') || '';if(/^(https?:|[^:\/]+(?:\/|$))/i.test(src))n.dataset.mdSrc=src;else n.remove();}
      if(n.hasAttribute('href') && !/^(https?:|mailto:|#|[^:\/]+(?:\/|$))/i.test(n.getAttribute('href')))n.removeAttribute('href');
    });
    return template.innerHTML;
  }
  let tables, selectingWithMouse=false, lastTableContext=null;
  function tableRange(){const s=getSelection();return s.rangeCount && root.contains(s.getRangeAt(0).commonAncestorContainer)?s.getRangeAt(0):selection;}
  function toolbarTableContext(){
    // Auch native Rückfragen nach Tippen oder Undo dürfen während eines
    // Mauszuges keinen neuen Kontext und damit kein anderes Layout liefern.
    if(!selectingWithMouse)lastTableContext=tables?.context() || null;
    return lastTableContext;
  }
  function reportTableContext(){if(selectingWithMouse)return;window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'tableContext',session,revision,context:toolbarTableContext()});}
  function insertCellHTML(html,singleLine) {
    const range=tableRange(),start=range?.startContainer,cell=(start?.nodeType===1?start:start?.parentElement)?.closest('td,th');
    if(!singleLine || !cell || !cell.contains(range.endContainer) || range.collapsed || range.toString()!==cell.textContent || tables.context()?.reason)return null;
    // Sichtbarer Zelltext allein beweist keine vollständige Auswahl:
    // Bilder und geschützte Atome können außerhalb der Auswahl liegen.
    for(const atom of cell.querySelectorAll('img,input,[data-tex],[data-md-opaque]')){
      const boundary=document.createRange();boundary.selectNode(atom);
      if(range.compareBoundaryPoints(Range.START_TO_START,boundary)>0 || range.compareBoundaryPoints(Range.END_TO_END,boundary)<0)return null;
    }
    const fragment=document.createElement('template');fragment.innerHTML=html;
    if(fragment.content.querySelector('br,table,pre,ul,ol,blockquote,h1,h2,h3,h4,h5,h6') ||
       Array.from(fragment.content.querySelectorAll('p,div')).filter(n=>!n.querySelector('p,div')).length>1)return null;
    // Renderer-Zeilenenden zwischen HTML-Blöcken sind kein Clipboard-Text.
    Array.from(fragment.content.childNodes).filter(n=>n.nodeType===Node.TEXT_NODE && /[\r\n]/.test(n.data) && !n.data.trim()).forEach(n=>n.remove());
    fragment.content.querySelectorAll('p,div').forEach(n=>n.replaceWith(...n.childNodes));
    // Der direkte native HTML-Ersatz ergänzt in einer geleerten Zelle einen
    // Umbruch, auch beim Redo. Der Tabellen-Undo-Pfad vermeidet ihn und gilt
    // ebenso für Fastras eigenes Markdown-Clipboard.
    const result=tables.command('pasteCell',fragment.innerHTML);
    if(!result.ok)window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'tableError',session,reason:result.reason});
    return result.ok;
  }
  window.fastraVisual={
    tableContext(){return tables?.context() || null;},
    tableState(){return {revision,context:toolbarTableContext()};},
    tableCommand(name,value,token){restoreSelection();return tables.command(name,value,token);},
    outlinePosition,
    revealHeading(index){
      if(composing)return false;
      const heading=outlineHeadings()[index],node=index<0?root:heading;
      if(!node)return false;
      const range=document.createRange();range.selectNodeContents(node);range.collapse(true);
      root.focus();getSelection().removeAllRanges();getSelection().addRange(range);selection=range.cloneRange();
      if(heading)heading.scrollIntoView({block:'center'});else window.scrollTo(0,0);
      return true;
    },
    async start(configuration) {
      const until=Date.now()+5000;
      while(!document.documentElement.hasAttribute('data-fastra-enhanced') && Date.now()<until)await new Promise(r=>setTimeout(r,10));
      root=document.getElementById('fastra-visual');blocks=configuration.blocks;base=configuration.markdown;session=configuration.session;opaqueSources=configuration.opaqueSources || {};
      // Verdeckte Definitionen einmal ihrem nächsten sichtbaren Block zuordnen.
      // Wiederholte Präfixsuchen würden jede Eingabe mit der Blockzahl quadratisch verteuern.
      hiddenPrefixes=new Map();let preceding=[];
      for(const b of blocks) {
        if(b.hidden)preceding.push(b);
        else {if(preceding.length)hiddenPrefixes.set(String(b.id),preceding);preceding=[];}
      }
      root.querySelectorAll('img').forEach(image=>{const token=image.getAttribute('src')?.split('/').pop(),id=configuration.imageTransactions?.[token];if(id)image.dataset.mdImageTransaction=id;});
      lastImageTransactions=JSON.stringify(imageTransactions().slice().sort());
      root.contentEditable='true';root.setAttribute('role','textbox');root.setAttribute('aria-multiline','true');
      root.querySelectorAll('input[type=checkbox]').forEach(n=>{n.removeAttribute('disabled');n.contentEditable='false';});
      root.querySelectorAll('[data-tex],.mermaid-render').forEach(n=>n.contentEditable='false');
      for(const b of blocks) {
        if(b.hidden)continue;
        const n=root.querySelector('[data-md-block="'+b.id+'"]');if(!n)continue;
        const snapshot=normalized(n);
        originals.set(String(b.id),{
          source:b.source,snapshot,structure:blockStructure(snapshot),
          ignoredHeadings:Array.from(n.querySelectorAll('h1,h2,h3,h4,h5,h6')).flatMap((heading,index)=>heading.hasAttribute('data-md-outline-ignore')?[index]:[])
        });
      }
      if(!root.children.length)root.innerHTML='<p data-md-empty="true"><br></p>';
      tables=window.fastraCreateTableEditor({root,range:tableRange,blocked:()=>fenced || composing,revision:()=>revision,apply:replaceTable,report:reportTableContext,
        fail:reason=>window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'tableError',session,reason})});
      document.execCommand('defaultParagraphSeparator',false,'p');
      root.addEventListener('input',changed);
      root.addEventListener('compositionstart',()=>composing=true);
      root.addEventListener('compositionend',()=>{composing=false;changed();});
      document.addEventListener('selectionchange',()=>{
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'outlinePosition',session,revision,index:outlinePosition()});
        const s=getSelection();if(s.rangeCount && root.contains(s.getRangeAt(0).commonAncestorContainer))selection=s.getRangeAt(0).cloneRange();
        reportTableContext();
      });
      const copySelection=e=>{
        const s=getSelection();if(fenced || !s.rangeCount || s.isCollapsed)return;
        const range=s.getRangeAt(0);if(!root.contains(range.commonAncestorContainer))return;
        const rich=document.createElement('div');rich.append(range.cloneContents());
        function preserveListContext(original,clone){
          if(original.tagName==='OL'){
            const items=Array.from(original.children),first=items.findIndex(n=>range.intersectsNode(n));
            if(first>=0)clone.setAttribute('start',String(Number(original.getAttribute('start') || 1)+first));
          }
          const checkbox=original.tagName==='LI'?taskCheckbox(original):null;
          if(checkbox && !taskCheckbox(clone))clone.prepend(checkbox.cloneNode(true),document.createTextNode(' '));
        }
        // Auch beim Start mitten in einer Liste und Ende im Folgeabsatz
        // fehlen im ersten geklonten Eintrag Nummer bzw. Aufgaben-Kästchen.
        const common=range.commonAncestorContainer;
        const listSources=common.querySelectorAll?Array.from(common.querySelectorAll('ol,li')).filter(n=>range.intersectsNode(n)):[];
        rich.querySelectorAll('ol,li').forEach((clone,index)=>preserveListContext(listSources[index],clone));
        // cloneContents lässt den gemeinsamen Vorfahren weg: Eine Auswahl
        // innerhalb von <strong> wäre sonst nur noch unformatierter Text.
        // Zelltext bleibt inline; die übrigen Container erhalten Überschrift,
        // Zitat, Listenebene und Codeblock, ohne Nachbartext mitzukopieren.
        for(let node=range.commonAncestorContainer.nodeType===1?range.commonAncestorContainer:range.commonAncestorContainer.parentElement;
            node && node!==root && !node.matches('td,th');node=node.parentElement){
          const wrapper=node.cloneNode(false);
          // Eine Teilauswahl in geschütztem HTML ist nicht dessen volle Quelle.
          wrapper.removeAttribute('data-md-opaque');
          wrapper.append(...rich.childNodes);
          preserveListContext(node,wrapper);
          rich.append(wrapper);
        }
        const markdown=toMarkdown(rich.innerHTML);
        const html=rich.cloneNode(true);
        html.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
        html.querySelectorAll('*').forEach(n=>{for(const a of Array.from(n.attributes))if(a.name.startsWith('data-md-') || a.name==='contenteditable')n.removeAttribute(a.name);});
        e.preventDefault();e.stopPropagation();
        const bookmark=window.fastraVisual.bookmark();
        // Bildbytes müssen gesichert sein, bevor Ausschneiden die Undo-Datei verschiebt.
        clipboardBookmark=bookmark;updateFence();
        window.webkit.messageHandlers.markdownCopy.postMessage({plain:s.toString(),html:html.innerHTML,markdown,session,bookmark,cut:e.type==='cut'});
      };
      root.addEventListener('copy',copySelection);
      root.addEventListener('cut',copySelection);
      // Eine wechselnde Werkzeugleistenhöhe verschiebt sonst während des
      // Ziehens den Text unter der Maus und verändert die Auswahl erneut.
      root.addEventListener('mousedown',e=>{if(e.button===0)selectingWithMouse=true;});
      const finishMouseSelection=()=>{if(selectingWithMouse){selectingWithMouse=false;reportTableContext();}};
      document.addEventListener('mouseup',finishMouseSelection,true);
      root.addEventListener('keydown',e=>{if(!['Shift','Alt','Control','Meta'].includes(e.key))finishMouseSelection();});
      window.addEventListener('blur',finishMouseSelection);
      root.addEventListener('paste',e=>{
        e.preventDefault();
        const plain=e.clipboardData.getData('text/plain'), html=e.clipboardData.getData('text/html');
        if(tables.context() && (plain.includes('\t') || (/[\r\n]/.test(plain) && (!html || /<table(?=[\s>])/i.test(html))))){
          const result=tables.command('pasteTSV',plain);
          if(!result.ok)window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'tableError',session,reason:result.reason});
          return;
        }
        if(e.clipboardData.getData('application/x-fastra-markdown')){window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'pasteMarkdown',session,bookmark:window.fastraVisual.bookmark()});return;}
        if(e.clipboardData.files.length){window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'pasteImage',session,bookmark:window.fastraVisual.bookmark()});return;}
        const cleaned=html?sanitizePaste(html):'';
        if(html && insertCellHTML(cleaned,!/[\r\n]/.test(plain))!==null)return;
        exec(html ? 'insertHTML' : 'insertText',html ? cleaned : plain);
      });
      root.addEventListener('drop',e=>{
        e.preventDefault();
        const r=document.caretRangeFromPoint?.(e.clientX,e.clientY);
        if(r && root.contains(r.commonAncestorContainer)){selection=r;getSelection().removeAllRanges();getSelection().addRange(r);}
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'drop',session,paths:Array.from(e.dataTransfer.files,f=>f.name)});
      });
      root.addEventListener('dragover',e=>e.preventDefault());
      root.addEventListener('keydown',e=>{
        tables.inspect(null);
        if(e.key==='Enter' && e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey && !e.isComposing && !composing && !fenced){
          e.preventDefault();
          window.fastraVisual.command('hardBreak');
          return;
        }
        if(e.key!=='Tab' || e.altKey || e.ctrlKey || e.metaKey || e.isComposing || composing || fenced)return;
        if(tables.context()){
          if(tables.navigate(e.shiftKey))e.preventDefault();
          return;
        }
        e.preventDefault();
        const items=selectedItems();
        if(items.length)nestItems(items,e.shiftKey);
        else if(!e.shiftKey){
          const node=getSelection().anchorNode, element=node?.nodeType===1?node:node?.parentElement;
          if(element?.closest('pre'))exec('insertText','\t');
          else exec('insertHTML','<span style="white-space:pre">&nbsp;&nbsp;&nbsp;&nbsp;</span>');
        }
      });
      document.addEventListener('selectionchange',()=>{
        root.querySelectorAll('[data-md-selected-image]').forEach(n=>n.removeAttribute('data-md-selected-image'));
        const range=getSelection().rangeCount?getSelection().getRangeAt(0):null;
        if(range && range.startContainer===range.endContainer && range.endOffset===range.startOffset+1){
          const image=range.startContainer.childNodes[range.startOffset];
          if(image?.nodeName==='IMG' && root.contains(image))image.setAttribute('data-md-selected-image','');
        }
      });
      root.addEventListener('contextmenu',e=>{
        const image=e.target.closest('img');if(!image || fenced)return;
        e.preventDefault();selectImage(image);
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'imageMenu',session,x:e.clientX,y:e.clientY});
      });
      root.addEventListener('click',e=>{
        tables.inspect(e.target.closest('td,th'));
        if(fenced){e.preventDefault();return;}
        if(e.target.closest('img')){e.preventDefault();selectImage(e.target.closest('img'));return;}
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
      const range=tableRange(),element=node=>node?.nodeType===1?node:node?.parentElement;
      if(element(range?.startContainer)?.closest('[data-md-opaque],[data-tex],.mermaid-render')
          || element(range?.endContainer)?.closest('[data-md-opaque],[data-tex],.mermaid-render')){
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'protectedFormat',session});return false;
      }
      if((element(range?.startContainer)?.closest('td,th') || element(range?.endContainer)?.closest('td,th'))
          && ['heading1','heading2','heading3','bulletList','orderedList','taskList','quote','insertTable'].includes(command)){
        reportTableContext();
        window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'tableError',session,reason:'format'});return false;
      }
      switch(command){
        case 'deleteImage': {
          restoreSelection();const range=getSelection().rangeCount?getSelection().getRangeAt(0):null;
          if(range && range.startContainer===range.endContainer && range.endOffset===range.startOffset+1 && range.startContainer.childNodes[range.startOffset]?.nodeName==='IMG')exec('delete');
          break;
        }
        case 'heading1':exec('formatBlock','h1');break;
        case 'heading2':exec('formatBlock','h2');break;
        case 'heading3':exec('formatBlock','h3');break;
        case 'plainParagraph':plainParagraph();break;
        case 'bulletList':listCommand(false);break;
        case 'orderedList':listCommand(true);break;
        case 'taskList':taskList();break;
        case 'quote':if(!formatParagraphBlocks('blockquote'))exec('formatBlock','blockquote');break;
        case 'hardBreak':exec('insertLineBreak');break;
        case 'link':exec('createLink',value);break;
        case 'insertTable':exec('insertHTML',value);break;
        case 'insertHTML':exec('insertHTML',value);break;
        case 'bold':case 'italic':case 'code':case 'highlight': {
          restoreSelection();const s=getSelection();if(!s.rangeCount)return;
          const r=s.getRangeAt(0),tag={bold:'strong',italic:'em',code:'code',highlight:'mark'}[command];
          if(r.collapsed && (command==='bold' || command==='italic')){exec(command);break;}
          const ancestor=r.commonAncestorContainer.nodeType===1?r.commonAncestorContainer:r.commonAncestorContainer.parentElement;
          const selector=command==='bold'?'strong,b':command==='italic'?'em,i':tag;
          let marked=ancestor.closest(selector);
          if(!marked && !r.collapsed){
            marked=Array.from(ancestor.querySelectorAll(selector)).find(node=>{
              const nodeRange=document.createRange();nodeRange.selectNode(node);
              return r.toString()===node.textContent && r.compareBoundaryPoints(Range.START_TO_START,nodeRange)<=0 && r.compareBoundaryPoints(Range.END_TO_END,nodeRange)>=0;
            });
          }
          if(marked && (command==='bold' || command==='italic')){exec(command);break;}
          if(marked){
            const full=document.createRange();full.selectNodeContents(marked);
            const before=full.cloneRange(),after=full.cloneRange();
            if(marked.contains(r.startContainer))before.setEnd(r.startContainer,r.startOffset);else before.collapse(true);
            if(marked.contains(r.endContainer))after.setStart(r.endContainer,r.endOffset);else after.collapse(false);
            const wrap=fragment=>{const element=document.createElement(tag);element.append(fragment);return element.innerHTML?element.outerHTML:'';};
            const middle=document.createElement('span');middle.append(r.collapsed || !marked.contains(r.startContainer)?full.cloneContents():r.cloneContents());
            middle.querySelectorAll(tag).forEach(n=>n.replaceWith(...n.childNodes));
            const html=r.collapsed?middle.innerHTML:wrap(before.cloneContents())+middle.innerHTML+wrap(after.cloneContents());
            // WebKit übernimmt beim Ersetzen eines Inline-Knotens dessen
            // Schreibattribute. Der ganze Absatz ist ein neutraler Undo-Schritt.
            const block=marked.closest('[data-md-block]') || marked.closest('p,h1,h2,h3,li,blockquote');
            if(!block)return;
            const path=[];let current=marked;while(current!==block){path.unshift(Array.from(current.parentNode.childNodes).indexOf(current));current=current.parentNode;}
            const clone=block.cloneNode(true);let target=clone;for(const index of path)target=target.childNodes[index];
            const template=document.createElement('template');template.innerHTML=html;target.replaceWith(template.content);
            replaceVisualBlocks([block],clone.outerHTML);
          }
          else {
            const holder=document.createElement('div');holder.append(r.cloneContents());
            function wrap(parent){
              let group=[];
              function flush(){if(!group.length)return;const wrapper=document.createElement(tag);group[0].before(wrapper);wrapper.append(...group);wrapper.querySelectorAll(tag).forEach(n=>n.replaceWith(...n.childNodes));group=[];}
              for(const child of Array.from(parent.childNodes)){
                if(child.nodeType===1 && /^(DIV|P|H[1-6]|LI|UL|OL|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|TD|TH|PRE|SECTION)$/.test(child.tagName)){
                  flush();if(child.contentEditable!=='false')wrap(child);
                }else if(!(child.nodeType===3 && !child.data.trim() && /^(DIV|UL|OL|TABLE|THEAD|TBODY|TR|BLOCKQUOTE)$/.test(parent.nodeName)))group.push(child);
              }
              flush();
            }
            wrap(holder);
            // Auch Inline-Auswahlen brauchen neutrale Absatzgrenzen: Am
            // Absatzende wandelt WebKit <mark> sonst in einen CSS-Span um,
            // dessen gelbe Farbe beim Markdown-Speichern verloren ginge.
            const fragment=document.createDocumentFragment();fragment.append(...holder.childNodes);replaceFormattedSelection(r,fragment);
          }
          break;
        }
      }
    },
    caret(x,y){const r=document.caretRangeFromPoint?.(x,y);if(!r || !root.contains(r.commonAncestorContainer))return null;selection=r;getSelection().removeAllRanges();getSelection().addRange(r);return window.fastraVisual.bookmark();},
    bookmark(existing){if(existing)return bookmarks.has(existing)?existing:null;restoreSelection();const key=String(++bookmarkID);bookmarks.set(key,{range:selection.cloneRange(),base:serialize()});return key;},
    discardBookmark(key){return bookmarks.delete(key);},
    insertBookmarked(key,html,atoms,transaction,imageSources,singleLine=false){
      if(fenced)return false;
      const saved=bookmarks.get(key);bookmarks.delete(key);
      if(!saved || saved.base!==serialize() || !root.contains(saved.range.commonAncestorContainer))return false;
      Object.assign(opaqueSources,atoms || {});
      const template=document.createElement('template');template.innerHTML=html;
      if(transaction)template.content.querySelectorAll('img').forEach(n=>{
        if(imageSources.includes(n.getAttribute('src')))n.dataset.mdImageTransaction=transaction;
      });
      template.content.querySelectorAll('[data-tex]').forEach(n=>n.textContent=n.dataset.tex);
      // WebKit muss neue Atome zunächst als editierbare Einfügung verbuchen,
      // sonst lässt Undo Teile davon stehen. exec schützt sie danach wieder.
      template.content.querySelectorAll('[contenteditable]').forEach(n=>n.removeAttribute('contenteditable'));
      selection=saved.range;getSelection().removeAllRanges();getSelection().addRange(selection);
      const cellResult=insertCellHTML(template.innerHTML,singleLine);
      if(cellResult===null)exec('insertHTML',template.innerHTML);else if(!cellResult)return false;
      window.fastraEnhanceMarkdown?.(root).then(()=>{
        root.querySelectorAll('[data-tex],.mermaid-render').forEach(n=>n.contentEditable='false');
      });
      return true;
    },
    completeClipboard(key,cut,succeeded){
      if(key!==clipboardBookmark)return false;
      const saved=bookmarks.get(key);bookmarks.delete(key);
      const unchanged=saved && saved.base===serialize() && root.contains(saved.range.commonAncestorContainer);
      clipboardBookmark=null;updateFence();
      if(cut && succeeded && unchanged){selection=saved.range;getSelection().removeAllRanges();getSelection().addRange(selection);exec('insertHTML','');}
      return !!unchanged;
    },
    async updateStyle(font,size,dark){
      document.body.style.setProperty('--fastra-copy-border',dark?'#484848':'#D7D7D7');
      document.body.style.setProperty('--fastra-copy-background',dark?'#333333':'#ECECEC');
      let sheet=document.getElementById('fastra-visual-style');if(!sheet){sheet=document.createElement('style');sheet.id='fastra-visual-style';document.head.append(sheet);}
      const family=font==='System'?'-apple-system, BlinkMacSystemFont, sans-serif':JSON.stringify(font)+', -apple-system, sans-serif';
      sheet.textContent=`body{font-family:${family};font-size:${size}px;color:${dark?'#F2F2F2':'#363636'};background:${dark?'#171717':'#FFFFFF'}}h1,h2,h3,h4,h5,h6{color:inherit}blockquote,pre.mermaid-error::before{color:${dark?'#A8A8A8':'#737373'}}a{color:${dark?'#8BB7F2':'#3F69A8'}}code,pre,blockquote,th{background:${dark?'#333333':'#ECECEC'}}td,th,blockquote,hr{border-color:${dark?'#484848':'#D7D7D7'}}mark{background:${dark?'#665200':'#FFEE9A'};color:inherit}`;
      window.fastraMarkdownPresentation?.update();
      await window.fastraUpdateMarkdownTheme?.(root,dark);
      window.fastraMarkdownPresentation?.update();
    },
    prepareAction(){
      if(composing)return {composing:true};
      actionFenced=true;
      // Eine Dokumentaktion übernimmt den aktuellen Stand. Ein noch nicht
      // bestätigter Cut darf ihn danach nicht mehr verändern; die Kopie bleibt.
      if(clipboardBookmark!==null){bookmarks.delete(clipboardBookmark);clipboardBookmark=null;}
      updateFence();changed();return {markdown:serialize(),revision,imageTransactions:imageTransactions(),inputType:lastInputType};
    },
    completeAction(expectedSession){if(expectedSession!==session)return;actionFenced=false;updateFence();},
    completeImageAction(expectedSession,expectedRevision){
      if(expectedSession!==session || expectedRevision!==imageFenceRevision)return;
      imageFenceRevision=null;updateFence();
    },
    rollbackImageChange(inputType,previous){
      editingCommand=true;root.contentEditable='true';root.focus();
      let reverted=false;
      try{reverted=document.execCommand(inputType==='historyUndo'?'redo':'undo');}finally{editingCommand=false;updateFence();}
      if(!reverted || serialize()!==previous)return false;
      base=previous;lastImageTransactions=JSON.stringify(imageTransactions().slice().sort());
      return true;
    },
    markdown:()=>serialize(),
    flush:()=>changed()
  };
})();
