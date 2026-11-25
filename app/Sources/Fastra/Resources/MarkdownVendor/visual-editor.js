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
    // Strukturelle Leerzeilen dürfen nicht als absichtliche ASCII-Leerzeilen erscheinen.
    content=content.replace(/^\n+/,'').replace(/\n+$/,'').replace(/\n(?=[^\n])/g,'\n'+indent);
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
  td.addRule('consecutiveBreaks',{filter:n=>n.hasAttribute('data-md-literal-break'),replacement:()=>'<br>'});
  function protectConsecutiveBreaks(holder) {
    for (const paragraph of holder.querySelectorAll('p,li,blockquote')) {
      if (paragraph.closest('td,th,pre,[data-md-opaque],[data-tex]')) continue;
      let breaks=[];
      function finishRun() {
        // Eine Leerzeile aus zwei Leerzeichen würde cmark aus dem Absatz lösen.
        if(breaks.length>1)for(const br of breaks)br.dataset.mdLiteralBreak='';
        breaks=[];
      }
      function visit(parent) {
        for(const n of parent.childNodes){
          if(n.nodeName==='BR')breaks.push(n);
          else if(n.nodeType===Node.TEXT_NODE){if(/[^ \t\r\n\f]/.test(n.data))finishRun();}
          else if(n.nodeType===Node.ELEMENT_NODE){
            if(n.matches('p,div,li,ul,ol,blockquote,h1,h2,h3,h4,h5,h6,pre,table,img,input,[data-tex],[data-md-opaque]'))finishRun();
            else visit(n);
          }
        }
      }
      visit(paragraph);
      finishRun();
    }
  }
  function randomToken(prefix) { return prefix+Array.from(crypto.getRandomValues(new Uint32Array(4)),n=>n.toString(16)).join('')+'END'; }
  function toMarkdown(html,lineEnding='\n') {
    const holder=document.createElement('div');holder.innerHTML=html;
    holder.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
    // Die Zeilenenden geschützter Originale bleiben auch bei einem Bildblock
    // mit neuen Absatzumbrüchen erhalten.
    const sources=[],mathNodes=holder.querySelectorAll('[data-md-math-source]');
    const protectOpaque=lineEnding!=='\n' && holder.querySelector('[data-md-opaque]');
    let namespace='';
    if(mathNodes.length || protectOpaque){
      const input=holder.innerHTML+'\0'+Object.values(opaqueSources).join('\0');namespace=randomToken('FASTRARICHSOURCE');
      for(let attempt=0;input.includes(namespace);attempt++){if(attempt===16)throw new Error('Rich source token collision limit');namespace=randomToken('FASTRARICHSOURCE');}
    }
    function protect(source){const token=namespace+sources.length+'END';sources.push(source);return token;}
    mathNodes.forEach(node=>{
      const source=opaqueSources[node.dataset.mdMathSource];if(typeof source!=='string')return;
      const token=protect(source);
      if(node.tagName==='DIV'){const block=document.createElement('div');block.textContent=token;node.replaceWith(block);}
      else node.replaceWith(document.createTextNode(token));
    });
    // WebKit-Inline-Stile vor der Markdown-Erzeugung in semantische Tags überführen.
    holder.querySelectorAll('span,font').forEach(node=>{
      if(node.closest('pre,code,[data-md-opaque],[data-tex]') || node.hasAttribute('data-md-spaces'))return;
      const css=node.style;
      const bold=css.fontWeight==='bold' || Number(css.fontWeight)>=600;
      const italic=css.fontStyle==='italic' || css.fontStyle==='oblique';
      const marked=css.backgroundColor && css.backgroundColor!=='transparent' && css.backgroundColor!=='rgba(0, 0, 0, 0)';
      const strike=css.textDecorationLine.includes('line-through');
      if(!bold && !italic && !marked && !strike)return;
      const fragment=document.createDocumentFragment();fragment.append(...node.childNodes);
      let wrapped=fragment;
      for(const tag of [marked?'mark':null,strike?'del':null,bold?'strong':null,italic?'em':null].filter(Boolean)){
        const el=document.createElement(tag);el.append(wrapped);wrapped=el;
      }
      node.replaceWith(wrapped);
    });
    // Gleichartige innere Formate sind bereits vom äußeren Format abgedeckt.
    // Getrennte Markdown-Delimiter würden den äußeren Bereich vorzeitig schließen.
    holder.querySelectorAll('strong,b,em,i').forEach(node=>{
      const kind=['STRONG','B'].includes(node.tagName)?'strong,b':'em,i';
      if(node.parentElement?.closest(kind))node.replaceWith(...node.childNodes);
    });
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
      if(text.data.includes('\u200b'))text.data=text.data.replace(/\u200b/g,'');
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
    // Am Absatzende gesammelte <br>-Läufe in saubere sichtbare Leerzeilen
    // statt <br><br>-HTML umwandeln; Listen, Tabellen und Inline-Überschriften ausnehmen.
    const peelTrailingBreaks=container=>{
      const removed=[];
      while(container.lastChild){
        const tail=container.lastChild;
        if(tail.nodeType===3 && !tail.data.replace(/[\u200b \t\r\n\f]/g,'').length){tail.remove();continue;}
        if(tail.nodeName==='BR'){tail.remove();removed.push(tail);continue;}
        if(tail.nodeType===1 && INLINE_WRAP_TAGS.has(tail.tagName) && !tail.hasAttribute('data-md-spaces')){
          const inner=peelTrailingBreaks(tail);
          if(!tail.childNodes.length){tail.remove();removed.push(...inner);continue;}
          if(inner.length){removed.push(...inner);}
        }
        break;
      }
      return removed;
    };
    holder.querySelectorAll('p').forEach(p=>{
      if(p.closest('li,td,th,pre,code,[data-md-opaque],[data-tex]')
          || p.querySelector('p,div,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,table,pre,hr'))return;
      if(!p.textContent.replace(/\u200b/g,'').length && !p.querySelector('img,input,[data-tex],[data-md-opaque]'))return;
      const clone=p.cloneNode(true), trailing=peelTrailingBreaks(clone);
      if(trailing.length<2)return;
      p.replaceWith(clone);
      const frag=document.createDocumentFragment();
      for(let i=0;i<trailing.length-1;i++){
        const blank=document.createElement('p');
        blank.append(document.createElement('br'));
        frag.append(blank);
      }
      clone.after(frag);
    });
    // Leere editierbare Absätze sind sichtbare Zeilen. Platzhalter schützen
    // sie vor Turndowns Leerraum-Kürzung, auch am Dokumentanfang und -ende.
    const blanks=[];
    holder.querySelectorAll('p,div').forEach(n=>{
      if(n.closest('pre,code,[data-md-opaque],[data-tex]'))return;
      if(n.textContent.replace(/\u200b/g,'').length || n.querySelector('p,div,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,table,pre,code,img,input,hr,[data-md-opaque],[data-tex]'))return;
      if(Array.from(n.querySelectorAll('*')).some(c=>!['BR','STRONG','B','EM','I','MARK','DEL','S','STRIKE','SPAN','FONT'].includes(c.tagName)))return;
      const count=n.querySelectorAll('br').length;
      if(!count){n.remove();return;}
      const lines=document.createDocumentFragment();
      // Eigene Absätze lassen Turndown für jede Zeile auch Zitat- und
      // Listenpräfixe ergänzen; nachträgliche Umbrüche verlören diesen Kontext.
      for(let i=0;i<count;i++) {
        const token=randomToken('FASTRAEMPTY');
        blanks.push(token);const line=n.cloneNode(false);line.textContent=token;lines.append(line);
      }
      n.replaceWith(lines);
    });
    protectConsecutiveBreaks(holder);
    let markdown;
    const previousOpaqueSourceToken=opaqueSourceToken;
    if(protectOpaque)opaqueSourceToken=protect;
    try { markdown=td.turndown(holder.innerHTML); }
    finally { opaqueSourceToken=previousOpaqueSourceToken; }
    if(lineEnding!=='\n')markdown=markdown.replace(/\r\n?|\n/g,lineEnding);
    for(const [token,spaces] of tableSpaces)markdown=markdown.replace(token,()=>spaces);
    for(const token of blanks)markdown=markdown.replace(token,'  ');
    if(sources.length)markdown=markdown.replace(new RegExp(namespace+'(\\d+)END','g'),(token,index)=>sources[Number(index)] ?? token);
    return markdown;
  }
  const commonEscape=td.escape.bind(td);
  // Einzelne = sind gewöhnlicher Text. Nur benachbarte = können Fastras
  // Textmarker auslösen; Turndown schützt bereits = am Textanfang.
  td.escape=text=>commonEscape(text.replace(/&/g,'&amp;').replace(/</g,'&lt;')).replace(/^(\d+)\) /,'$1\\) ').replace(/[$~]|(?<!\\)=(?==)|(?<==)=/g,'\\$&');
  let opaqueSources={},opaqueSourceToken=null;
  function opaqueMarkdown(node,tableCell=false) {
    const source=opaqueSources[node.dataset.mdOpaque] || '';
    const markdown=tableCell?source.replace(/\|/g,'\\|'):source;
    return markdown && opaqueSourceToken?opaqueSourceToken(markdown):markdown;
  }
  td.addRule('opaque',{filter:n=>n.hasAttribute('data-md-opaque'),replacement:(_,n)=>opaqueMarkdown(n)});
  function adjacentText(node,forward) {
    while(node && !/^(DIV|P|H[1-6]|LI|TD|TH|BLOCKQUOTE)$/.test(node.nodeName)) {
      const sibling=forward?node.nextSibling:node.previousSibling;
      if(sibling){
        if(sibling.nodeType===Node.TEXT_NODE && sibling.length)return sibling;
        const walker=document.createTreeWalker(sibling,NodeFilter.SHOW_TEXT);
        if(!forward)walker.currentNode=sibling;
        let text;
        if(forward){while((text=walker.nextNode()))if(text.length)return text;}
        else {
          while(walker.lastChild()){}
          const last=walker.currentNode;
          if(last!==sibling && last.length)return last;
          while((text=walker.previousNode()))if(text!==sibling && text.length)return text;
        }
        if(sibling.nodeName==='BR' || sibling.nodeName==='IMG')return null;
        node=sibling;
      } else node=node.parentNode;
    }
    return null;
  }
  function inlineFormat(content,node,tag,delimiter) {
    const edge=delimiter[0]==='*'?content.trim().replace(/^\*+|\*+$/g,''):content.trim();
    const text=Array.from(edge),first=text[0] || '',last=text.at(-1) || '';
    const punctuation=c=>/[\p{P}\p{S}]/u.test(c),space=c=>!c || /\s/u.test(c);
    const preceding=adjacentText(node,false),following=adjacentText(node,true);
    const before=Array.from(preceding?.data || '').at(-1),after=Array.from(following?.data || '')[0];
    // CommonMark erkennt z. B. a**!**b nicht als Auszeichnung. Inline-HTML
    // erhält solche Grenzen. Verschachtelte Sternchen gehören zum selben
    // Delimiterlauf und dürfen normale Markdown-Kombinationen nicht verhindern.
    const selector={'*':'strong,b,em,i','=':'mark','~':'del,s,strike'}[delimiter[0]];
    function touchesFormat(text,character) {
      const neighbor=text?.parentElement?.closest(selector);
      return !space(character) && neighbor && !node.contains(neighbor) && !neighbor.contains(node);
    }
    const joined=touchesFormat(preceding,before) || touchesFormat(following,after)
      || (delimiter==='==' && [before,after,first,last].includes('='));
    const unsafe=joined || (punctuation(first) && !space(before) && !punctuation(before))
      || (punctuation(last) && !space(after) && !punctuation(after));
    return unsafe?'<'+tag+'>'+content+'</'+tag+'>':delimiter+content+delimiter;
  }
  td.addRule('strong',{filter:['strong','b'],replacement:(c,n)=>inlineFormat(c,n,'strong','**')});
  td.addRule('emphasis',{filter:['em','i'],replacement:(c,n)=>inlineFormat(c,n,'em','*')});
  td.addRule('highlight', {filter:'mark', replacement:(c,n)=>n.parentElement?.closest('mark')?c:(c.trim()?inlineFormat(c.trim(),n,'mark','=='):'')});
  td.addRule('strike', {filter:['del','s','strike'], replacement:(c,n)=>inlineFormat(c,n,'del','~~')});
  // Entitäten zählen für CommonMarks Trennzeichen als Quellzeichen. HTML
  // bleibt nur nötig, wenn die tatsächlichen Nachbarzeichen Markdown verhindern.
  td.addRule('styledSpaces', {
    filter:n=>['STRONG','B','EM','I','MARK','DEL','S','STRIKE'].includes(n.nodeName)
      && !!n.querySelector('[data-md-spaces]'),
    replacement:(content,node)=>{
      const tag={B:'strong',I:'em',S:'del',STRIKE:'del'}[node.nodeName] || node.nodeName.toLowerCase();
      return inlineFormat(content,node,tag,{strong:'**',em:'*',mark:'==',del:'~~'}[tag]);
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
        atoms.push([token,opaqueMarkdown(atom)]);atom.replaceWith(document.createTextNode(token));
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
        const source=atom.hasAttribute('data-tex')?mathMarkdown(atom):opaqueMarkdown(atom,true);
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
  let root, originals=new Map(), blocks=[], hiddenPrefixes=new Map(), trailingHidden=new Set(), trailingOwner=null, selection=null, base='', session='', composing=false, revision=0, fenced=false, bookmarkID=0, bookmarks=new Map(), editingCommand=false, lastInputType='';
  // Eingebauter Flugschreiber (nur im RAM, strikt begrenzt).
  const diagnosticEvents=[], diagnosticAnomalies=[], DIAGNOSTIC_MAX_EVENTS=200, DIAGNOSTIC_MAX_BYTES=262144;
  let diagnosticBytes=0, lastAppearanceCheck=null, lastRenderedHTML=null;
  function visibleTextLength(container=root) {
    if(!container)return 0;
    const clone=container.cloneNode(true);
    clone.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
    return clone.textContent.replace(/[\u200b\s]+/g,'').length;
  }
  function selectionSummary() {
    const s=getSelection();
    if(!s || !s.rangeCount)return {hasRange:false};
    const r=s.getRangeAt(0);
    const path=[];
    let cur=r.startContainer?.nodeType===1?r.startContainer:r.startContainer?.parentElement;
    while(cur && cur!==root && path.length<5){path.unshift(cur.tagName.toLowerCase());cur=cur.parentElement;}
    return {hasRange:true,collapsed:r.collapsed,len:r.toString().replace(/\u200b/g,'').length,path:path.join('>')};
  }
  function domSkeleton(container=root,depth=0) {
    if(!container || depth>4)return [];
    const out=[];
    for(const n of container.childNodes){
      if(n.nodeType===3){const t=n.data.replace(/\u200b/g,'');if(t.length)out.push({t:'#text',len:t.length});continue;}
      if(n.nodeType!==1)continue;
      const item={t:n.tagName.toLowerCase()};
      if(n.hasAttribute('data-md-edit-boundary'))item.b=true;
      if(n.hasAttribute('data-md-empty'))item.e=true;
      if(n.hasAttribute('data-md-block'))item.id=n.dataset.mdBlock;
      if(n.hasAttribute('data-md-opaque'))item.o=true;
      if(n.hasAttribute('data-tex'))item.m=true;
      const txt=n.textContent.replace(/\u200b/g,'');
      if(n.children.length && depth<4)item.c=domSkeleton(n,depth+1);
      else if(txt.length)item.len=txt.length;
      out.push(item);
      if(out.length>=120){out.push({t:'...truncated'});break;}
    }
    return out;
  }
  function pushDiagnosticEvent(kind,details={}) {
    const entry={ts:new Date().toISOString(),rev:revision,kind,...details};
    const text=JSON.stringify(entry);
    // Aufeinanderfolgende Tippeingaben im gleichen Block kompakt zusammenfassen.
    const prev=diagnosticEvents.at(-1);
    if(kind==='input' && details.inputType==='insertText' && prev?.kind==='input' && prev.inputType==='insertText' && prev.path===details.path){
      prev.count=(prev.count || 1)+1;prev.rev=revision;prev.ts=entry.ts;prev.textLen=details.textLen;return;
    }
    diagnosticEvents.push(entry);diagnosticBytes+=text.length;
    while(diagnosticEvents.length>DIAGNOSTIC_MAX_EVENTS || diagnosticBytes>DIAGNOSTIC_MAX_BYTES){
      const removed=diagnosticEvents.shift();
      diagnosticBytes-=JSON.stringify(removed).length;
    }
  }
  function recordAnomaly(code,summary,extra={}) {
    const entry={ts:new Date().toISOString(),rev:revision,code,summary,...extra};
    diagnosticAnomalies.push(entry);
    if(diagnosticAnomalies.length>40)diagnosticAnomalies.shift();
    pushDiagnosticEvent('anomaly',{code,summary,...extra});
    try{window.webkit?.messageHandlers?.visualMarkdown?.postMessage({kind:'diagnosticAnomaly',session,revision,code,summary});}catch(_){}
  }
  const sourceContexts=new Map();let sourceReplacementEnabled=false,sourceContextBytes=0;
  function sourceContextCost(configuration,html){const encoder=new TextEncoder();return encoder.encode(configuration.markdown).length+encoder.encode(html).length+256;}
  function registerSourceContext(configuration,holder,prefix){
    const context={blocks:configuration.blocks.map(b=>({...b,id:prefix+String(b.id)})),hiddenPrefixes:new Map(),trailingHidden:new Set(),trailingOwner:null};
    const nodes=new Map(Array.from(holder.children,n=>[n.dataset.mdBlock,n]));
    let preceding=[];
    for(const block of context.blocks){
      if(block.hidden){preceding.push(block);continue;}
      context.hiddenPrefixes.set(block.id,preceding);preceding=[];context.trailingOwner=block.id;
      const originalID=block.id.slice(prefix.length),node=nodes.get(originalID);
      if(!node)continue;
      node.dataset.mdBlock=block.id;
      const snapshot=normalized(node);
      originals.set(block.id,{source:block.source,snapshot,structure:blockStructure(snapshot),context,
        ignoredHeadings:Array.from(node.querySelectorAll('h1,h2,h3,h4,h5,h6')).flatMap((heading,index)=>heading.hasAttribute('data-md-outline-ignore')?[index]:[])});
    }
    context.trailingHidden=new Set(preceding.map(b=>b.id));
    sourceContexts.set(prefix,context);Object.assign(opaqueSources,configuration.opaqueSources || {});
    sourceContextBytes+=sourceContextCost(configuration,holder.innerHTML);
    return context;
  }
  function activateSourceContext(context){
    blocks=context.blocks;hiddenPrefixes=context.hiddenPrefixes;trailingHidden=context.trailingHidden;trailingOwner=context.trailingOwner;
  }
  function ensureContextNode(holder,context,id){
    if(holder.children.length)return;
    // Auch reine Referenzdefinitionen brauchen eine native Undo-Identität.
    const node=document.createElement('div');node.dataset.mdBlock=id;node.innerHTML='<p data-md-empty="true"><br></p>';holder.append(node);
    const snapshot=normalized(node);originals.set(id,{source:'',snapshot,structure:blockStructure(snapshot),context,ignoredHeadings:[]});
    sourceContextBytes+=new TextEncoder().encode(node.outerHTML).length;
  }
  let copiedHTML=null;
  const nativeActionIDs=new Set();
  let initializing=false, actionFenced=false, clipboardBookmark=null, imageFenceRevision=null, lastImageTransactions="[]";
  let clipboardLimit=0, clipboardSelectionGeneration=0, observedClipboardSelection=null;
  function clipboardSelectionState(){
    const live=getSelection();
    return live.rangeCount?{anchor:live.anchorNode,anchorOffset:live.anchorOffset,focus:live.focusNode,focusOffset:live.focusOffset}:null;
  }
  function sameClipboardSelection(a,b){return a===b || !!(a && b && a.anchor===b.anchor && a.anchorOffset===b.anchorOffset && a.focus===b.focus && a.focusOffset===b.focusOffset);}
  function observeClipboardSelection(){
    const current=clipboardSelectionState();
    if(!sameClipboardSelection(current,observedClipboardSelection)){clipboardSelectionGeneration++;observedClipboardSelection=current;}
    return current;
  }
  function currentClipboardSelection(saved){
    if(saved.clipboardSelectionGeneration===undefined)return true;
    const current=observeClipboardSelection();
    return saved.clipboardSelectionGeneration===clipboardSelectionGeneration && sameClipboardSelection(saved.clipboardSelection,current);
  }
  let viewportRestoring=false, viewportGeneration=0, viewportPending=false;
  function viewportPosition(){return {x:Math.max(0,window.scrollX),y:Math.max(0,window.scrollY)};}
  function reportViewport(){if(!viewportRestoring)window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'viewport',session,revision,viewport:viewportPosition()});}
  async function restoreViewport(value){
    if(!value || ![value.x,value.y].every(n=>Number.isFinite(n) && n>=0 && n<=100000000))return;
    const request=++viewportGeneration;viewportRestoring=true;let settled=0;
    // Bilder und Schriften können die anfängliche Dokumenthöhe noch ändern.
    // Verdeckte WebViews besitzen keinen zuverlässigen Animationsframe.
    for(let attempt=0;attempt<60 && request===viewportGeneration;attempt++){
      window.scrollTo(value.x,value.y);
      const actual=viewportPosition();
      if(Math.abs(actual.x-value.x)<1 && Math.abs(actual.y-value.y)<1){if(++settled===2)break;}else settled=0;
      await new Promise(resolve=>setTimeout(resolve,16));
    }
    if(request===viewportGeneration){viewportRestoring=false;reportViewport();}
  }
  function outlineHeadings(){return Array.from(root.querySelectorAll('h1,h2,h3,h4,h5,h6')).filter(n=>!n.closest('[data-md-opaque],[data-tex]') && !n.hasAttribute('data-md-outline-ignore'));}
  function outlinePosition(){
    const node=getSelection().anchorNode,element=node?.nodeType===1?node:node?.parentElement;
    if(!element || !root.contains(element))return -1;
    let index=-1;
    outlineHeadings().forEach((heading,i)=>{if(heading.contains(element) || heading===element || (heading.compareDocumentPosition(element)&Node.DOCUMENT_POSITION_FOLLOWING))index=i;});
    return index;
  }
  function updateFence(){fenced=initializing || actionFenced || nativeActionIDs.size>0 || clipboardBookmark!==null || imageFenceRevision!==null;root.contentEditable=fenced?'false':'true';}
  function normalized(node) {
    const clone=node.cloneNode(true);
    clone.querySelectorAll('[contenteditable]').forEach(n=>n.removeAttribute('contenteditable'));
    clone.querySelectorAll('[data-md-selected-image]').forEach(n=>n.removeAttribute('data-md-selected-image'));
    clone.querySelectorAll('[data-md-outline-ignore]').forEach(n=>n.removeAttribute('data-md-outline-ignore'));
    // Interne Bildversionen sind Darstellung; nur der ursprüngliche Quellverweis zählt als Dokumentänderung.
    clone.querySelectorAll('img[data-md-src]').forEach(image=>image.removeAttribute('src'));
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
  function emptyDocumentPlaceholder(container) {
    const children=Array.from(container.children).filter(n=>!n.hasAttribute('data-md-edit-boundary'));
    if(children.length!==1)return null;
    const node=children[0];
    if(!node.hasAttribute('data-md-empty') || node.childNodes.length!==1 || node.firstChild.nodeName!=='BR'
       || Array.from(container.childNodes).some(n=>n.nodeType===Node.TEXT_NODE && n.data.trim()))return null;
    return node;
  }
  function deletedDocumentPlaceholder(container,inputType) {
    if(!inputType.startsWith('delete'))return null;
    const visible=Array.from(container.children).filter(n=>!n.hasAttribute('data-md-edit-boundary'));
    return visible.length===1 && !visible[0].textContent.length
      && !Array.from(container.childNodes).some(n=>n.nodeType===Node.TEXT_NODE && n.data.trim())
      && visible[0].querySelectorAll('br').length<=1
      && !visible[0].querySelector('img,input,hr,table,pre,code,[data-md-opaque],[data-tex]') ? visible[0] : null;
  }
  function saveAppearance(container,inputType='') {
    const placeholder=emptyDocumentPlaceholder(container) || deletedDocumentPlaceholder(container,inputType);
    const blocks=/^(DIV|P|SECTION|H[1-6]|UL|OL|LI|BLOCKQUOTE|TABLE|THEAD|TBODY|TFOOT|TR|TD|TH|PRE|HR)$/;
    const tags={B:1,STRONG:1,I:2,EM:2,MARK:4,DEL:8,S:8,STRIKE:8,CODE:16};
    let text='',space=false,pendingBreaks=0,totalBreaks=0;
    const formats=[],breaks=[];
    function recordBreaks(count) {
      if(!count)return;
      if(breaks.at(-1)?.[0]===text.length)breaks.at(-1)[1]+=count;
      else breaks.push([text.length,count]);
      totalBreaks+=count;
    }
    function boundary() {
      // WebKit hängt am Absatzende ein BR als Cursor-Platzhalter an.
      recordBreaks(Math.max(0,pendingBreaks-1));pendingBreaks=0;space=!!text;
    }
    function addText(value,style) {
      for(const word of value.replace(/\u200b/g,'').match(/[^ \t\r\n\f]+|[ \t\r\n\f]+/g) || []){
        if(/^[ \t\r\n\f]/.test(word)){space=!!text;continue;}
        if(pendingBreaks){recordBreaks(pendingBreaks);pendingBreaks=0;space=!!text;}
        if(space){text+=' ';space=false;}
        const start=text.length;
        text+=word;
        if(style){
          const previous=formats.at(-1);
          if(previous?.[1]===start && previous[2]===style)previous[1]=text.length;
          else formats.push([start,text.length,style]);
        }
      }
    }
    function visit(node,style,tableCell=false) {
      if(node.nodeType===Node.TEXT_NODE){
        // pre-wrap-Zellen zeigen WebKits Text-Newlines wie gerenderte BRs.
        if(tableCell)node.data.split(/\r\n?|\n/).forEach((part,index)=>{
          if(index)pendingBreaks++;
          addText(part,style);
        });
        else addText(node.data,style);
        return;
      }
      if(node.nodeType!==Node.ELEMENT_NODE || node===placeholder || node.hasAttribute('data-md-edit-boundary'))return;
      const tag=node.tagName,block=blocks.test(tag);
      if(tag==='BR'){pendingBreaks++;return;}
      if(block)boundary();
      const before=text.length,breakCount=totalBreaks;
      if(tag==='IMG' || node.hasAttribute('data-tex')
         || (node.hasAttribute('data-md-opaque') && (tag!=='SECTION' || node.matches(':has(.mermaid-render, code.language-mermaid)')))){
        addText('\ufffc',style);
      }else{
        style|=tags[tag] || 0;
        if(tag==='SPAN' || tag==='FONT'){
          const css=node.style;
          if(css.fontWeight==='bold' || Number(css.fontWeight)>=600)style|=1;
          if(css.fontStyle==='italic' || css.fontStyle==='oblique')style|=2;
          if(css.backgroundColor && css.backgroundColor!=='transparent' && css.backgroundColor!=='rgba(0, 0, 0, 0)')style|=4;
          if(css.textDecorationLine.includes('line-through'))style|=8;
        }
        const preWrap=tableCell || ((tag==='TD' || tag==='TH') && !!node.closest('table[data-md-table=gfm]'));
        for(const child of node.childNodes)visit(child,style,preWrap);
      }
      if(block){
        if(text.length===before && totalBreaks===breakCount && pendingBreaks){
          // Leere Überschriften/Listeneinträge tragen in WebKit ein einzelnes Platzhalter-BR,
          // während leere Absätze im Markdown als echte Leerzeilen gespeichert werden.
          const emptyLineBreaks=(/^H[1-6]$/.test(tag) || tag==='LI') ? Math.max(0,pendingBreaks-1) : pendingBreaks;
          recordBreaks(emptyLineBreaks);pendingBreaks=0;
        }
        boundary();
      }
    }
    for(const node of container.childNodes)visit(node,0);
    boundary();
    return {text,formats,breaks};
  }
  function diffAppearance(live,saved) {
    if(live.text!==saved.text){
      let at=0;
      const minLen=Math.min(live.text.length,saved.text.length);
      while(at<minLen && live.text[at]===saved.text[at])at++;
      return {outcome:'text',diff:{offset:at,liveLength:live.text.length,savedLength:saved.text.length,
        liveSnippet:live.text.slice(Math.max(0,at-20),at+40),savedSnippet:saved.text.slice(Math.max(0,at-20),at+40)}};
    }
    if(JSON.stringify(live.formats)!==JSON.stringify(saved.formats)){
      return {outcome:'format',diff:{liveCount:live.formats.length,savedCount:saved.formats.length,
        liveFormats:live.formats.slice(0,12),savedFormats:saved.formats.slice(0,12)}};
    }
    if(JSON.stringify(live.breaks)!==JSON.stringify(saved.breaks)){
      return {outcome:'breaks',diff:{liveCount:live.breaks.length,savedCount:saved.breaks.length,
        liveBreaks:live.breaks.slice(0,12),savedBreaks:saved.breaks.slice(0,12)}};
    }
    return {outcome:'ok',diff:null};
  }
  function serialize() {
    if(sourceContexts.size){
      const known=Array.from(root.children).map(n=>originals.get(n.dataset.mdBlock)).find(original=>original?.context);
      if(known)activateSourceContext(known.context);
    }
    const used=new Set();let output='';
    const imageEndings=new Map();
    for(const image of root.querySelectorAll('img[data-md-image-transaction][data-md-image-ending]')){
      let owner=image;
      while(owner.parentNode!==root)owner=owner.parentNode;
      imageEndings.set(owner.getAttribute('data-md-block') ?? owner,image.dataset.mdImageEnding==='crlf'?'\r\n':'\r');
    }
    const placeholder=emptyDocumentPlaceholder(root);
    // Nach Select-All/Delete bleibt WebKits einzelner Cursorabsatz übrig.
    // Verdeckte Referenzdefinitionen erhalten; gelöschte Leerzeilen nicht anhängen.
    if(deletedDocumentPlaceholder(root,lastInputType)) {
      return blocks.filter(b=>b.hidden && b.source.trim()).map(b=>b.source).join('');
    }
    function hiddenBefore(id) {
      for(const b of hiddenPrefixes.get(id) || []){output+=b.source;used.add('hidden:'+b.id);}
    }
    for(const node of root.childNodes) {
      if(node.nodeType===Node.ELEMENT_NODE && node.hasAttribute('data-md-edit-boundary'))continue;
      if(node.nodeType===Node.TEXT_NODE && !node.textContent.trim())continue;
      const id=node.nodeType===Node.ELEMENT_NODE ? node.getAttribute('data-md-block') : null;
      const original=id===null ? null : originals.get(id);
      const sourceEnding=original?.source.includes('\r\n')?'\r\n':original?.source.includes('\r')?'\r':'\n';
      const ending=imageEndings.get(id ?? node) ?? sourceEnding;
      if(original && !used.has(id)) {
        hiddenBefore(id);used.add(id);
        const snapshot=normalized(node);
        if(snapshot===original.snapshot)output+=original.source;
        else {
          // Text- und Inline-Änderungen behalten die vorhandenen Zeilenenden.
          // Neue Blockarten brauchen dagegen eine sichere Absatztrennung:
          // Eine Überschrift vor Fließtext darf nicht mit ihm verschmelzen.
          const suffix=blockStructure(snapshot)===original.structure ? original.source.match(/[\r\n]*$/)[0] : ending+ending;
          output+=toMarkdown(node.innerHTML,ending)+suffix;
        }
      } else if(node===placeholder) {
        continue;
      } else {
        const holder=document.createElement('div');holder.append(node.cloneNode(true));
        const value=toMarkdown(holder.innerHTML,ending);
        output+=value ? value+ending+ending : ending;
      }
    }
    // Verdeckte Definitionen müssen auch dann erhalten bleiben, wenn ihr
    // Nachbarabsatz gelöscht oder durch Auswahl über mehrere Blöcke ersetzt wurde.
    for(const b of blocks)if(b.hidden && !used.has('hidden:'+b.id) && (b.source.trim() || (trailingHidden.has(b.id) && (trailingOwner===null || used.has(trailingOwner)))))output+=b.source;
    return output;
  }
  function imageTransactions(){return Array.from(new Set(Array.from(root.querySelectorAll('img[data-md-image-transaction]'),n=>n.dataset.mdImageTransaction)));}
  function rescueCorruptedBoundaries() {
    if(!root)return false;
    let rescued=false;
    for(const boundaryNode of Array.from(root.querySelectorAll('[data-md-edit-boundary]'))){
      const hasRealContent=boundaryNode.textContent.replace(/\u200b/g,'').length>0
        || !!boundaryNode.querySelector('img,input,table,pre,code,[data-tex],[data-md-opaque]');
      if(hasRealContent){
        boundaryNode.removeAttribute('data-md-edit-boundary');
        boundaryNode.style.display='';
        const walker=document.createTreeWalker(boundaryNode,NodeFilter.SHOW_TEXT),texts=[];
        while(walker.nextNode())texts.push(walker.currentNode);
        for(const t of texts)if(t.data.includes('\u200b'))t.data=t.data.replace(/\u200b/g,'');
        rescued=true;
      }else if(boundaryNode.childNodes.length!==1 || boundaryNode.firstChild.nodeType!==3 || boundaryNode.firstChild.data!=='\u200b'){
        boundaryNode.textContent='\u200b';
      }
    }
    if(rescued)recordAnomaly('boundary-rescued','Rescued visible content from edit boundary');
    return rescued;
  }
  function changed(event) {
    if(event?.inputType)lastInputType=event.inputType;
    if(composing || editingCommand)return;
    rescueCorruptedBoundaries();
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
    if(event?.inputType){
      pushDiagnosticEvent('input',{inputType:event.inputType,textLen:visibleTextLength(),path:selectionSummary().path || ''});
    }
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
  const BLOCK_TAGS=new Set(['DIV','P','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','TABLE','THEAD','TBODY','TFOOT','TR','TD','TH','PRE','HR','SECTION']);
  const NESTED_BLOCK_RE=/^(DIV|P|H[1-6]|UL|OL|BLOCKQUOTE|TABLE|PRE|HR|SECTION)$/;
  const INLINE_WRAP_TAGS=new Set(['STRONG','B','EM','I','MARK','DEL','S','STRIKE','CODE','A','U','INS','SMALL','SUB','SUP','KBD','SAMP','VAR','Q','CITE','ABBR','DFN','SPAN','FONT']);
  function isProtectedAtom(node) {
    return node?.nodeType===1 && (node.hasAttribute('data-md-opaque') || node.hasAttribute('data-tex') || node.tagName==='PRE' || node.classList?.contains('mermaid-render'));
  }
  function hasSemanticContent(node) {
    if(!node)return false;
    if(node.nodeType===3)return node.data.replace(/\u200b/g,'').length>0;
    if(node.nodeType!==1)return false;
    if(node.tagName==='BR' || node.tagName==='IMG' || node.tagName==='INPUT' || node.tagName==='HR' || isProtectedAtom(node))return true;
    if(node.hasAttribute('data-md-selection-start') || node.hasAttribute('data-md-selection-end') || node.hasAttribute('data-md-spaces'))return true;
    if(node.textContent.replace(/\u200b/g,'').length>0)return true;
    return !!node.querySelector('br,img,input,hr,table,pre,code,[data-md-opaque],[data-tex],[data-md-selection-start],[data-md-selection-end],[data-md-spaces]');
  }
  function nodesHaveSemanticContent(nodes) {
    return nodes.some(hasSemanticContent);
  }
  function pushInlineIntoBlock(inlineTemplate,blockNode) {
    if(!blockNode || blockNode.nodeType!==1 || isProtectedAtom(blockNode))return;
    const tag=blockNode.tagName;
    if(/^(P|H[1-6]|LI|TD|TH)$/.test(tag)){
      let run=[];
      const result=document.createDocumentFragment();
      function flushRun(){
        if(!run.length)return;
        if(nodesHaveSemanticContent(run)){const w=inlineTemplate.cloneNode(false);w.append(...run);result.append(w);}
        else result.append(...run);
        run=[];
      }
      for(const child of Array.from(blockNode.childNodes)){
        if(child.nodeType===1 && (BLOCK_TAGS.has(child.tagName) || child.tagName==='BR' || isProtectedAtom(child))){
          flushRun();
          if(child.tagName==='UL' || child.tagName==='OL' || child.tagName==='BLOCKQUOTE' || child.tagName==='DIV')pushInlineIntoBlock(inlineTemplate,child);
          result.append(child);
        }else run.push(child);
      }
      flushRun();
      blockNode.append(result);
    }else if(tag==='UL' || tag==='OL' || tag==='BLOCKQUOTE' || tag==='DIV'){
      for(const child of Array.from(blockNode.children))pushInlineIntoBlock(inlineTemplate,child);
    }
  }
  function normalizeVisualFragment(container,options={wrapRootInlines:false}) {
    let changed=false;
    for(const b of Array.from(container.querySelectorAll('[data-md-edit-boundary]'))){
      const real=b.textContent.replace(/\u200b/g,'').length>0 || !!b.querySelector('img,input,table,pre,code,[data-tex],[data-md-opaque],[data-md-selection-start],[data-md-selection-end]');
      if(real){b.removeAttribute('data-md-edit-boundary');b.style.display='';}else b.remove();
      changed=true;
    }
    container.querySelectorAll('[data-md-empty]').forEach(n=>n.removeAttribute('data-md-empty'));
    for(let pass=0;pass<24;pass++){
      let passChanged=false;
      // 1. Inline-Elemente mit Block-Nachfahren aufteilen.
      const inlineWithBlock=Array.from(container.querySelectorAll('*')).find(el=>
        INLINE_WRAP_TAGS.has(el.tagName) && !el.closest('pre,[data-md-opaque],[data-tex]')
        && !el.hasAttribute('data-md-selection-start') && !el.hasAttribute('data-md-selection-end') && !el.hasAttribute('data-md-spaces')
        && Array.from(el.children).some(c=>BLOCK_TAGS.has(c.tagName) || !!c.querySelector?.('p,div,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,table,pre,hr,section'))
      );
      if(inlineWithBlock){
        const frag=document.createDocumentFragment();
        let buf=[];
        const keepInline=inlineWithBlock.tagName!=='SPAN' && inlineWithBlock.tagName!=='FONT';
        function flushBuf(){
          if(!buf.length)return;
          if(keepInline && nodesHaveSemanticContent(buf)){const w=inlineWithBlock.cloneNode(false);w.append(...buf);frag.append(w);}
          else frag.append(...buf);
          buf=[];
        }
        for(const child of Array.from(inlineWithBlock.childNodes)){
          if(child.nodeType===1 && (BLOCK_TAGS.has(child.tagName) || !!child.querySelector?.('p,div,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,table,pre,hr,section'))){
            flushBuf();
            if(keepInline && BLOCK_TAGS.has(child.tagName))pushInlineIntoBlock(inlineWithBlock,child);
            frag.append(child);
          }else buf.push(child);
        }
        flushBuf();
        inlineWithBlock.replaceWith(frag);
        passChanged=true;changed=true;continue;
      }
      // 2. Illegale Blockverschachtelung in <p> oder <h1..6> aufspalten (erlaubtes Inline-HTML mit data-md-outline-ignore ausnehmen).
      const badParent=Array.from(container.querySelectorAll('p,h1,h2,h3,h4,h5,h6')).find(el=>
        !el.closest('pre,[data-md-opaque],[data-tex]') && !el.hasAttribute('data-md-outline-ignore')
        && Array.from(el.children).some(c=>NESTED_BLOCK_RE.test(c.tagName) && !c.hasAttribute('data-md-outline-ignore'))
      );
      if(badParent){
        const frag=document.createDocumentFragment();
        let seg=[];
        function flushSeg(){
          if(!seg.length)return;
          if(nodesHaveSemanticContent(seg)){const p=badParent.cloneNode(false);p.append(...seg);frag.append(p);}
          seg=[];
        }
        for(const child of Array.from(badParent.childNodes)){
          if(child.nodeType===1 && NESTED_BLOCK_RE.test(child.tagName)){flushSeg();frag.append(child);}
          else seg.push(child);
        }
        flushSeg();
        badParent.replaceWith(frag);
        passChanged=true;changed=true;continue;
      }
      // 3. Leere Hüllen ohne Inhalt, <br> oder Auswahlmarker entfernen.
      for(const el of Array.from(container.querySelectorAll('p,div,h1,h2,h3,h4,h5,h6'))){
        if(el.closest('pre,[data-md-opaque],[data-tex]') || isProtectedAtom(el))continue;
        if(!hasSemanticContent(el)){el.remove();passChanged=true;changed=true;}
      }
      for(const el of Array.from(container.querySelectorAll('strong,b,em,i,mark,del,s,strike,code'))){
        if(el.closest('pre,[data-md-opaque],[data-tex]'))continue;
        if(!hasSemanticContent(el) && !el.hasAttribute('data-md-spaces')){el.remove();passChanged=true;changed=true;}
      }
      if(!passChanged)break;
    }
    // 4. Lose Top-Level-Inlineknoten neben Blöcken in <p> einpacken, damit WebKit sie nicht in Boundaries zieht.
    const hasBlockChild=Array.from(container.children).some(c=>BLOCK_TAGS.has(c.tagName));
    if(options.wrapRootInlines || hasBlockChild){
      const frag=document.createDocumentFragment();
      let run=[];
      function hasRealInlineContent(node) {
        if(!node)return false;
        if(node.nodeType===3)return node.data.replace(/\u200b/g,'').length>0;
        if(node.nodeType!==1)return false;
        if(node.hasAttribute('data-md-selection-start') || node.hasAttribute('data-md-selection-end'))return false;
        return node.tagName==='BR' || node.tagName==='IMG' || node.tagName==='INPUT' || node.tagName==='HR'
          || node.hasAttribute('data-md-spaces') || isProtectedAtom(node)
          || Array.from(node.childNodes).some(hasRealInlineContent);
      }
      function flushInlineRun(){
        if(!run.length)return;
        if(run.some(hasRealInlineContent)){const p=document.createElement('p');p.append(...run);frag.append(p);changed=true;}
        else{
          const markers=run.filter(n=>n.nodeType===1 && (n.hasAttribute('data-md-selection-start') || n.hasAttribute('data-md-selection-end')));
          if(markers.length)frag.append(...markers);
        }
        run=[];
      }
      for(const child of Array.from(container.childNodes)){
        if(child.nodeType===1 && BLOCK_TAGS.has(child.tagName)){flushInlineRun();frag.append(child);}
        else if(child.nodeType===3 && !child.data.trim() && !run.length){/* reinen Zwischenraum verwerfen */}
        else run.push(child);
      }
      flushInlineRun();
      container.append(frag);
    }
    return {changed};
  }
  function cloneIntervalWithMarkers(range) {
    const rawChildren=Array.from(root.childNodes);
    const nonBoundary=rawChildren.filter(n=>!(n.nodeType===1 && n.hasAttribute('data-md-edit-boundary')) && !(n.nodeType===3 && !n.data.trim()));
    const affected=nonBoundary.filter(n=>{try{return range.intersectsNode(n);}catch(_){return false;}});
    if(!affected.length)return null;
    const firstIdx=rawChildren.indexOf(affected[0]),lastIdx=rawChildren.indexOf(affected.at(-1));
    const interval=rawChildren.slice(firstIdx,lastIdx+1);
    const holder=document.createElement('div'),cloneMap=new Map(),cleanInterval=[];
    for(const n of interval){
      if((n.nodeType===1 && n.hasAttribute('data-md-edit-boundary')) || (n.nodeType===3 && !n.data.trim()))continue;
      const cloned=n.cloneNode(true);holder.append(cloned);cloneMap.set(n,cloned);cleanInterval.push(n);
    }
    if(!cleanInterval.length)return null;
    function resolveTop(node){
      if(!node || node===root)return null;
      let cur=node;while(cur && cur.parentNode!==root)cur=cur.parentNode;return cur;
    }
    function mapPoint(node,offset,isEnd){
      if(node===root){
        let count=0;for(let i=0;i<offset && i<rawChildren.length;i++)if(cloneMap.has(rawChildren[i]))count++;
        return [holder,Math.min(count,holder.childNodes.length)];
      }
      const top=resolveTop(node);
      if(top && cloneMap.has(top)){
        const path=[];let cur=node;
        while(cur!==top){path.unshift(Array.from(cur.parentNode.childNodes).indexOf(cur));cur=cur.parentNode;}
        let target=cloneMap.get(top);
        for(const idx of path){if(!target.childNodes[idx])break;target=target.childNodes[idx];}
        const maxOff=target.nodeType===3?target.length:target.childNodes.length;
        return [target,Math.max(0,Math.min(offset,maxOff))];
      }
      if(top){
        const pos=rawChildren.indexOf(top);
        if(pos>=0 && pos<firstIdx)return [holder,0];
        if(pos>lastIdx)return [holder,holder.childNodes.length];
        let mapped=0;for(let i=firstIdx;i<pos;i++)if(cloneMap.has(rawChildren[i]))mapped++;
        return [holder,Math.min(mapped,holder.childNodes.length)];
      }
      return [holder,isEnd?holder.childNodes.length:0];
    }
    const [sNode,sOff]=mapPoint(range.startContainer,range.startOffset,false);
    const [eNode,eOff]=mapPoint(range.endContainer,range.endOffset,true);
    const copied=document.createRange();copied.setStart(sNode,sOff);copied.setEnd(eNode,eOff);
    const start=document.createElement('span'),end=document.createElement('span');
    start.dataset.mdSelectionStart='';end.dataset.mdSelectionEnd='';start.textContent=end.textContent='\u200b';
    if(!copied.collapsed){const finish=copied.cloneRange();finish.collapse(false);finish.insertNode(end);}
    const begin=copied.cloneRange();begin.collapse(true);begin.insertNode(start);
    copied.setStartAfter(start);if(end.parentNode)copied.setEndBefore(end);else copied.collapse(true);
    return {interval,holder,copied,start,end};
  }
  function splitInlineBreaks(container) {
    // Zieht <br>-Elemente aus direkten/verschachtelten Inline-Tags heraus, damit
    // Zeilenumwandlungen (<p>A<br>B</p> -> <h2>A</h2><p>B</p>) Formatgrenzen wahren.
    for(let guard=0;guard<64;guard++){
      const br=Array.from(container.querySelectorAll('br')).find(node=>{
        const inline=node.parentElement;
        return inline && inline!==container && INLINE_WRAP_TAGS.has(inline.tagName) && !inline.closest('pre,[data-md-opaque],[data-tex]');
      });
      if(!br)break;
      const inline=br.parentElement,parent=inline.parentNode;
      const beforeRange=document.createRange();beforeRange.selectNodeContents(inline);beforeRange.setEndBefore(br);
      const afterRange=document.createRange();afterRange.selectNodeContents(inline);afterRange.setStartAfter(br);
      const beforeFrag=beforeRange.extractContents(),afterFrag=afterRange.extractContents();
      const out=document.createDocumentFragment();
      if(nodesHaveSemanticContent(Array.from(beforeFrag.childNodes))){const w=inline.cloneNode(false);w.append(beforeFrag);out.append(w);}
      out.append(br);
      if(nodesHaveSemanticContent(Array.from(afterFrag.childNodes))){const w=inline.cloneNode(false);w.append(afterFrag);out.append(w);}
      inline.replaceWith(out);
    }
  }
  function formatHeading(tag) {
    restoreSelection();const s=getSelection();if(!s.rangeCount)return;
    const ctx=cloneIntervalWithMarkers(s.getRangeAt(0));if(!ctx)return;
    const {interval,holder,copied,start,end}=ctx;
    function nodeIntersectsSelection(node){
      if(node===start || node===end)return true;
      if(node.nodeType===1 && (node.contains(start) || (end.parentNode && node.contains(end))))return true;
      if(copied.collapsed)return false;
      try{return copied.intersectsNode(node);}catch(_){return false;}
    }
    function stripFontSizeSpans(el){
      el.querySelectorAll('span,font').forEach(n=>{
        if(n.closest('pre,[data-md-opaque],[data-tex]'))return;
        if(n.tagName==='FONT' && !n.style.cssText){n.replaceWith(...n.childNodes);return;}
        if(n.style.fontSize){n.style.fontSize='';if(!n.getAttribute('style')?.trim() && n.attributes.length===1)n.replaceWith(...n.childNodes);}
      });
    }
    function splitLeafBlock(leaf){
      splitInlineBreaks(leaf);
      const raw=Array.from(leaf.childNodes);
      // Ein einzelnes abschließendes Cursor-BR im nicht-leeren Absatz ignorieren, wenn kein zweites BR folgt.
      const lines=[];let cur=[];
      for(const n of raw){if(n.nodeName==='BR'){lines.push(cur);cur=[];}else cur.push(n);}
      lines.push(cur);
      if(lines.length>1 && !nodesHaveSemanticContent(lines.at(-1)) && raw.at(-1)?.nodeName==='BR' && raw.at(-2)?.nodeName!=='BR'){
        lines.pop();
      }
      const isLineSelected=nodes=>nodes.some(nodeIntersectsSelection);
      const out=document.createDocumentFragment();
      let plainRun=[];
      function flushPlain(){
        if(!plainRun.length)return;
        const p=document.createElement(leaf.matches('h1,h2,h3,h4,h5,h6')?'p':leaf.tagName.toLowerCase());
        plainRun.forEach((nodes,idx)=>{if(idx)p.append(document.createElement('br'));p.append(...nodes);});
        if(nodesHaveSemanticContent(Array.from(p.childNodes)))out.append(p);
        plainRun=[];
      }
      for(const lineNodes of lines){
        if(isLineSelected(lineNodes)){
          flushPlain();
          const heading=document.createElement(tag);
          heading.append(...lineNodes);
          stripFontSizeSpans(heading);
          if(!heading.childNodes.length || (heading.textContent.replace(/\u200b/g,'').length===0 && !heading.querySelector('br,img,[data-tex],[data-md-opaque]')))heading.append(document.createElement('br'));
          out.append(heading);
        }else if(nodesHaveSemanticContent(lineNodes) || plainRun.length>0){
          plainRun.push(lineNodes);
        }
      }
      flushPlain();
      leaf.replaceWith(out);
    }
    function transformBlock(node){
      if(node.nodeType!==1 || isProtectedAtom(node))return;
      if(node.matches('p,h1,h2,h3,h4,h5,h6')){
        if(nodeIntersectsSelection(node))splitLeafBlock(node);
        return;
      }
      if(node.matches('ul,ol')){
        if(!nodeIntersectsSelection(node))return;
        const frag=document.createDocumentFragment();
        let listBuf=[];
        function flushList(){
          if(!listBuf.length)return;
          const list=node.cloneNode(false);list.append(...listBuf);frag.append(list);listBuf=[];
        }
        for(const item of Array.from(node.children)){
          if(item.tagName==='LI' && nodeIntersectsSelection(item)){
            flushList();
            item.querySelectorAll('input[type=checkbox]').forEach(cb=>{if(cb.closest('li')===item)cb.remove();});
            const p=document.createElement('p');p.append(...item.childNodes);frag.append(p);splitLeafBlock(p);
          }else listBuf.push(item);
        }
        flushList();
        node.replaceWith(frag);
        return;
      }
      if(node.matches('blockquote')){
        if(!nodeIntersectsSelection(node))return;
        if(!Array.from(node.children).some(c=>BLOCK_TAGS.has(c.tagName))){
          const p=document.createElement('p');p.append(...node.childNodes);node.append(p);
        }
        for(const child of Array.from(node.children))transformBlock(child);
        return;
      }
      if(node.matches('div')){
        for(const child of Array.from(node.children))transformBlock(child);
      }
    }
    for(const child of Array.from(holder.children))transformBlock(child);
    replaceVisualBlocks(interval,holder.innerHTML);
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
    const ctx=cloneIntervalWithMarkers(current);
    if(!ctx)return;
    const {interval,holder}=ctx;
    const protectedNode=n=>n.closest('[contenteditable=false],[data-tex],[data-md-opaque]');
    holder.querySelectorAll('input[type=checkbox]').forEach(n=>{if(!protectedNode(n))n.remove();});
    holder.querySelectorAll('mark,code,strong,b,em,i,del,s,strike,a,u,font,span').forEach(n=>{
      if(!protectedNode(n) && n.parentElement?.tagName!=='PRE' && !n.hasAttribute('data-md-selection-start') && !n.hasAttribute('data-md-selection-end') && !n.hasAttribute('data-md-spaces')){
        n.replaceWith(...n.childNodes);
      }
    });
    holder.querySelectorAll('h1,h2,h3,h4,h5,h6,li').forEach(n=>{
      if(protectedNode(n))return;const p=document.createElement('p');p.append(...n.childNodes);n.replaceWith(p);
    });
    holder.querySelectorAll('ul,ol,blockquote').forEach(n=>{if(!protectedNode(n))n.replaceWith(...n.childNodes);});
    replaceVisualBlocks(interval,holder.innerHTML);
  }
  function formatParagraphBlocks(tag) {
    restoreSelection();const range=getSelection().getRangeAt(0);
    const blocks=Array.from(root.children).filter(n=>!n.hasAttribute('data-md-edit-boundary') && range.intersectsNode(n));
    if(!blocks.length)return false;
    const paragraphs=[];
    for(const n of blocks){
      if(n.matches('p,h1,h2,h3,h4,h5,h6'))paragraphs.push(n);
      else if(n.tagName==='DIV' && n.children.length && Array.from(n.children).every(c=>c.matches('p,h1,h2,h3,h4,h5,h6')))paragraphs.push(...n.children);
      else return false;
    }
    if(!paragraphs.length)return false;
    const useDivWrapper=blocks[0].tagName==='DIV' && blocks[0].hasAttribute('data-md-block');
    const wrapper=useDivWrapper?blocks[0].cloneNode(false):null,formatted=document.createElement(tag);
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
    let outHTML;
    if(wrapper){wrapper.append(formatted);outHTML=wrapper.outerHTML;}
    else outHTML=formatted.outerHTML;
    replaceVisualBlocks(blocks,outHTML);return true;
  }
  function unwrapSelectedListItems(items,ordered) {
    const targetTag=ordered?'OL':'UL';
    editListBlocks(items,selected=>{
      const allSameType=selected.every(li=>li.parentElement?.tagName===targetTag);
      const lists=Array.from(new Set(selected.map(li=>li.parentElement)));
      if(allSameType){
        for(const list of lists){
          const frag=document.createDocumentFragment();
          let buf=[];
          function flush(){if(!buf.length)return;const l=list.cloneNode(false);l.append(...buf);frag.append(l);buf=[];}
          for(const child of Array.from(list.children)){
            if(selected.includes(child)){
              flush();
              const cb=taskCheckbox(child);cb?.remove();
              const p=document.createElement('p');p.append(...child.childNodes);frag.append(p);
            }else buf.push(child);
          }
          flush();
          list.replaceWith(frag);
        }
      }else{
        for(const list of lists){
          if(list.tagName===targetTag)continue;
          const replacement=document.createElement(targetTag.toLowerCase());
          replacement.append(...list.childNodes);
          list.replaceWith(replacement);
        }
      }
    });
  }
  function listCommand(ordered) {
    const items=selectedItems();
    if(!items.length && formatParagraphBlocks(ordered?'ol':'ul'))return;
    if(items.length){unwrapSelectedListItems(items,ordered);return;}
    exec(ordered?'insertOrderedList':'insertUnorderedList');
  }
  function quoteCommand() {
    if(formatParagraphBlocks('blockquote'))return;
    restoreSelection();const s=getSelection();if(!s.rangeCount)return;
    const ctx=cloneIntervalWithMarkers(s.getRangeAt(0));if(!ctx)return;
    const {interval,holder,start,end}=ctx;
    const blockquotes=Array.from(holder.querySelectorAll('blockquote')).filter(bq=>!bq.closest('[data-md-opaque],[data-tex]'));
    if(blockquotes.length && Array.from(holder.children).every(c=>c.tagName==='BLOCKQUOTE' || (c.tagName==='DIV' && Array.from(c.children).every(k=>k.tagName==='BLOCKQUOTE')))){
      blockquotes.forEach(bq=>bq.replaceWith(...bq.childNodes));
      replaceVisualBlocks(interval,holder.innerHTML);
      return;
    }
    const bq=document.createElement('blockquote');
    for(const child of Array.from(holder.childNodes)){
      if(child.nodeType===1 && child.tagName==='DIV' && child.hasAttribute('data-md-block'))bq.append(...child.childNodes);
      else bq.append(child);
    }
    holder.append(bq);
    replaceVisualBlocks(interval,holder.innerHTML);
  }
  function hardBreakCommand() {
    restoreSelection();const s=getSelection();if(!s.rangeCount)return;
    const r=s.getRangeAt(0);
    const anchorEl=r.startContainer.nodeType===1?r.startContainer:r.startContainer.parentElement;
    const p=anchorEl?.closest?.('p');
    if(!r.collapsed || !p || !root.contains(p)
        || p.closest('li,td,th,pre,code,[data-md-opaque],[data-tex]')
        || p.hasAttribute('data-md-edit-boundary') || p.hasAttribute('data-md-empty')
        || (!p.textContent.replace(/\u200b/g,'').length && !p.querySelector('img,input,[data-tex],[data-md-opaque]'))){
      exec('insertLineBreak');return;
    }
    const beforeRange=document.createRange();
    beforeRange.selectNodeContents(p);
    beforeRange.setEnd(r.startContainer,r.startOffset);
    function inspectEnd(container) {
      const children=Array.from(container.childNodes);
      for(let i=children.length-1;i>=0;i--){
        const n=children[i];
        if(n.nodeType===3 && !n.data.replace(/[\u200b \t\r\n\f]/g,'').length)continue;
        if(n.nodeType===1 && (n.hasAttribute('data-md-selection-start') || n.hasAttribute('data-md-selection-end')))continue;
        if(n.nodeName==='BR')return true;
        if(n.nodeType===1 && INLINE_WRAP_TAGS.has(n.tagName) && !n.hasAttribute('data-md-spaces')){
          const inner=inspectEnd(n);
          if(inner!==null)return inner;
          continue;
        }
        return false;
      }
      return null;
    }
    if(inspectEnd(beforeRange.cloneContents())!==true){exec('insertLineBreak');return;}
    // Zweiter weicher Umbruch direkt nach einem <br> im Fließtext: statt
    // <br><br>-HTML sauber in Absatz + sichtbare Leerzeile aufspalten.
    const ctx=cloneIntervalWithMarkers(r);
    if(!ctx){exec('insertLineBreak');return;}
    const clonedP=ctx.start.closest('p');
    if(!clonedP){exec('insertLineBreak');return;}
    splitInlineBreaks(clonedP);
    let topChild=ctx.start;
    while(topChild && topChild.parentNode!==clonedP)topChild=topChild.parentNode;
    if(topChild && topChild!==ctx.start){
      const preRange=document.createRange();
      preRange.setStartBefore(topChild);preRange.setEndBefore(ctx.start);
      const preFrag=preRange.extractContents();
      if(nodesHaveSemanticContent(Array.from(preFrag.childNodes)))topChild.before(preFrag);
    }
    const direct=Array.from(clonedP.childNodes), splitIdx=direct.indexOf(topChild);
    if(splitIdx<0){exec('insertLineBreak');return;}
    const beforeNodes=direct.slice(0,splitIdx), afterNodes=direct.slice(splitIdx);
    let poppedBreaks=0;
    while(beforeNodes.length){
      const tail=beforeNodes.at(-1);
      if(tail.nodeType===3 && !tail.data.replace(/[\u200b \t\r\n\f]/g,'').length){beforeNodes.pop();continue;}
      if(tail.nodeName==='BR'){beforeNodes.pop();poppedBreaks++;continue;}
      if(tail.nodeType===1 && INLINE_WRAP_TAGS.has(tail.tagName) && !tail.hasAttribute('data-md-spaces') && !nodesHaveSemanticContent([tail])){beforeNodes.pop();continue;}
      break;
    }
    const blankCount=Math.max(1,poppedBreaks);
    const frag=document.createDocumentFragment();
    if(nodesHaveSemanticContent(beforeNodes)){const first=document.createElement('p');first.append(...beforeNodes);frag.append(first);}
    for(let i=0;i<blankCount;i++){const blank=document.createElement('p');blank.append(document.createElement('br'));frag.append(blank);}
    const tailP=document.createElement('p');tailP.append(...afterNodes);
    const tailHasContent=tailP.textContent.replace(/\u200b/g,'').length>0 || !!tailP.querySelector('br,img,input,[data-tex],[data-md-opaque]');
    if(!tailHasContent)tailP.append(document.createElement('br'));
    frag.append(tailP);
    clonedP.replaceWith(frag);
    replaceVisualBlocks(ctx.interval,ctx.holder.innerHTML);
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
    const holder=document.createElement('div');holder.innerHTML=html;
    const hadBoundary=holder.querySelectorAll('[data-md-edit-boundary]').length>0;
    const normalizedResult=normalizeVisualFragment(holder,{wrapRootInlines:true});
    if(hadBoundary || normalizedResult.changed){
      pushDiagnosticEvent('normalized',{hadBoundary,changed:normalizedResult.changed});
    }
    const cleanHTML=holder.innerHTML;
    function isCleanBoundary(node){
      return !!node && node.nodeType===1 && node.hasAttribute('data-md-edit-boundary')
        && node.childNodes.length===1 && node.firstChild.nodeType===3 && node.firstChild.data==='\u200b';
    }
    function boundary(neighbor){
      if(isCleanBoundary(neighbor)){neighbor.style.display='';return neighbor;}
      const node=document.createElement('p');node.dataset.mdEditBoundary='';node.append(document.createTextNode('\u200b'));return node;
    }
    const before=boundary(affected[0].previousElementSibling),after=boundary(affected.at(-1).nextElementSibling);
    affected[0].before(before);affected.at(-1).after(after);
    const range=document.createRange();range.setStart(before.firstChild,0);range.setEnd(after.firstChild,after.firstChild.length);
    selection=range;getSelection().removeAllRanges();getSelection().addRange(range);
    // Die Grenzen gehören zu beiden Undo-Zuständen. Ihre Knoten bleiben
    // erhalten, weil WebKits Redo sie als Einfügeanker verwendet.
    exec('insertHTML',before.outerHTML+cleanHTML+after.outerHTML,restoreMarkers);
  }
  function replaceFormattedSelection(range,tag) {
    const ctx=cloneIntervalWithMarkers(range);
    if(!ctx)return;
    const {interval,holder,copied,start,end}=ctx;
    // Nur Inline-Gruppen innerhalb ihrer ursprünglichen Absätze ersetzen.
    // Teilweise geklonte äußere Blöcke würden Präfix und Suffix abtrennen
    // und dieselbe Block-ID mehrfach in das Dokument einsetzen.
    const parts=[];
    function collect(parent){
      let group=[];
      function flush(){
        if(!group.length)return;
        const part=document.createRange();part.setStartBefore(group[0]);part.setEndAfter(group.at(-1));group=[];
        const from=part.comparePoint(copied.startContainer,copied.startOffset),to=part.comparePoint(copied.endContainer,copied.endOffset);
        if(from>0 || to<0)return;
        if(from===0)part.setStart(copied.startContainer,copied.startOffset);
        if(to===0)part.setEnd(copied.endContainer,copied.endOffset);
        if(!part.collapsed)parts.push(part);
      }
      for(const child of Array.from(parent.childNodes)){
        if(child.nodeType===1 && /^(DIV|P|H[1-6]|LI|UL|OL|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|TD|TH|PRE|SECTION)$/.test(child.tagName)){
          flush();if(child.contentEditable!=='false')collect(child);
        }else if(child.nodeName==='BR' || child===start || child===end || (child.nodeType===3 && !child.data.trim() && /^(DIV|UL|OL|TABLE|THEAD|TBODY|TR|BLOCKQUOTE)$/.test(parent.nodeName))){
          flush();
        }else group.push(child);
      }
      flush();
    }
    collect(holder);
    if(!parts.length)return;
    const unwrapSelector=tag==='strong'?'strong,b':tag==='em'?'em,i':tag;
    for(const part of parts.reverse()){
      const extracted=part.extractContents();
      const wrapper=document.createElement(tag);wrapper.append(extracted);
      wrapper.querySelectorAll(unwrapSelector).forEach(n=>n.replaceWith(...n.childNodes));
      if(wrapper.textContent.replace(/\u200b/g,'').length>0 || wrapper.querySelector('img,input,[data-tex],[data-md-opaque]')){
        part.insertNode(wrapper);
      }else{
        const frag=document.createDocumentFragment();frag.append(...wrapper.childNodes);part.insertNode(frag);
      }
    }
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
  function clipboardHTML(html,collectImages=false){
    const images=[];
    if(new TextEncoder().encode(html).length>2097152)return {ok:false,reason:'size'};
    const template=document.createElement('template');template.innerHTML=html;
    const nodes=Array.from(template.content.querySelectorAll('*'));
    if(nodes.length>20000)return {ok:false,reason:'size'};
    const allowed=new Set(['P','DIV','BR','STRONG','B','EM','I','MARK','DEL','S','STRIKE','U','INS','SMALL','SUB','SUP','KBD','SAMP','VAR','Q','CITE','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE','CODE','A','TABLE','THEAD','TBODY','TFOOT','TR','TD','TH','SPAN','FONT']);
    for(const node of nodes){
      if(collectImages && node.tagName==='IMG'){
        const source=node.getAttribute('src') || '',match=source.match(/^data:image\/(png|jpeg|gif|webp|tiff);base64,([A-Za-z0-9+/]+={0,2})$/i);
        if(!match || images.length>=32 || match[2].length%4)return {ok:false,reason:'images'};
        const name='image'+images.length+'.'+({jpeg:'jpg'}[match[1].toLowerCase()] || match[1].toLowerCase()),alt=node.getAttribute('alt'),title=node.getAttribute('title');
        for(const attribute of Array.from(node.attributes))node.removeAttribute(attribute.name);
        node.dataset.mdSrc=name;if(alt)node.setAttribute('alt',alt);if(title)node.setAttribute('title',title);
        images.push({url:'file:///fastra-html-clipboard/'+name,base64:match[2]});continue;
      }
      if(['META','TITLE'].includes(node.tagName)){node.remove();continue;}
      if(!allowed.has(node.tagName))return {ok:false,reason:node.tagName==='IMG'?'images':'format'};
      if(node.hasAttribute('href') && !(/^(https?:\/\/|#)/i.test(node.getAttribute('href').trim()) && !/[\u0000-\u001f\u007f]/.test(node.getAttribute('href'))))return {ok:false,reason:'url'};
      const marked=['SPAN','FONT'].includes(node.tagName) && node.style.backgroundColor && !['transparent','rgba(0, 0, 0, 0)'].includes(node.style.backgroundColor);
      const bold=['SPAN','FONT'].includes(node.tagName) && /^(bold|[6-9]00)$/.test(node.style.fontWeight);
      const italic=['SPAN','FONT'].includes(node.tagName) && node.style.fontStyle==='italic';
      for(const attribute of Array.from(node.attributes)){
        const permitted=(node.tagName==='A' && ['href','title'].includes(attribute.name))
          || (node.tagName==='OL' && attribute.name==='start')
          || (['TH','TD'].includes(node.tagName) && ['align','colspan','rowspan'].includes(attribute.name));
        if(!permitted)node.removeAttribute(attribute.name);
      }
      if(['SPAN','FONT'].includes(node.tagName)){
        const fragment=document.createDocumentFragment();fragment.append(...node.childNodes);
        let content=fragment;
        for(const tag of [marked?'mark':null,bold?'strong':null,italic?'em':null].filter(Boolean)){const wrap=document.createElement(tag);wrap.append(content);content=wrap;}
        node.replaceWith(content);
      }
    }
    return {ok:true,html:template.innerHTML,images};
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
    outlineSnapshot(){
      const nodes=outlineHeadings();let bytes=0;
      if(nodes.length>10000)return {ok:false,reason:'limit'};
      const headings=[];
      for(const node of nodes){
        const title=node.textContent.trim(),length=new TextEncoder().encode(title).length;bytes+=length;
        if(length>16384 || bytes>2097152)return {ok:false,reason:'limit'};
        headings.push({level:Number(node.tagName.slice(1)),title});
      }
      return {ok:true,session,revision,index:outlinePosition(),headings};
    },
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
      // Erst nach Aufbau und verlustfreier Übernahme der Quelle darf WebKit Eingaben annehmen.
      initializing=true;
      if(session!==configuration.session)nativeActionIDs.clear();
      session=configuration.session;root=document.getElementById('fastra-visual');updateFence();
      const until=Date.now()+5000;
      while(!document.documentElement.hasAttribute('data-fastra-enhanced')){
        if(Date.now()>=until)return false;
        await new Promise(r=>setTimeout(r,10));
      }
      clipboardLimit=configuration.clipboardLimit || 0;
      root=document.getElementById('fastra-visual');blocks=configuration.blocks;base=configuration.markdown;session=configuration.session;opaqueSources=configuration.opaqueSources || {};
      // Verdeckte Definitionen einmal ihrem nächsten sichtbaren Block zuordnen.
      // Wiederholte Präfixsuchen würden jede Eingabe mit der Blockzahl quadratisch verteuern.
      hiddenPrefixes=new Map();trailingOwner=null;let preceding=[];
      for(const b of blocks) {
        if(b.hidden)preceding.push(b);
        else {if(preceding.length)hiddenPrefixes.set(String(b.id),preceding);preceding=[];trailingOwner=String(b.id);}
      }
      trailingHidden=new Set(preceding.map(b=>b.id));
      root.querySelectorAll('img').forEach(image=>{const token=image.getAttribute('src')?.split('/').pop(),id=configuration.imageTransactions?.[token];if(id)image.dataset.mdImageTransaction=id;});
      lastImageTransactions=JSON.stringify(imageTransactions().slice().sort());
      updateFence();root.setAttribute('role','textbox');root.setAttribute('aria-multiline','true');
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
      sourceReplacementEnabled=configuration.sourceReplacements===true;
      if(sourceReplacementEnabled){const context=registerSourceContext(configuration,root,'');ensureContextNode(root,context,'source-empty');activateSourceContext(context);}
      if(!root.children.length)root.innerHTML='<p data-md-empty="true"><br></p>';
      tables=window.fastraCreateTableEditor({root,range:tableRange,blocked:()=>fenced || composing,revision:()=>revision,apply:replaceTable,report:reportTableContext,
        fail:reason=>window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'tableError',session,reason})});
      document.execCommand('defaultParagraphSeparator',false,'p');
      root.addEventListener('input',changed);
      root.addEventListener('compositionstart',()=>composing=true);
      root.addEventListener('compositionend',()=>{composing=false;changed();});
      // Nur Linux-Clipboard-Bookmarks binden die aktive Auswahl. Bilddialoge behalten ihre gespeicherte Einfügestelle.
      root.addEventListener('mousedown',()=>{clipboardSelectionGeneration++;});
      root.addEventListener('keydown',event=>{
        if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','PageUp','PageDown'].includes(event.key) || ((event.ctrlKey || event.metaKey) && event.key.toLowerCase()==='a'))clipboardSelectionGeneration++;
        if(event.metaKey || event.ctrlKey || ['Enter','Backspace','Delete','Tab'].includes(event.key)){
          pushDiagnosticEvent('keydown',{key:event.key,meta:event.metaKey,ctrl:event.ctrlKey,shift:event.shiftKey,alt:event.altKey,sel:selectionSummary()});
        }
      });
      if(!window.__fastraDiagnosticErrorsInstalled){
        window.__fastraDiagnosticErrorsInstalled=true;
        window.addEventListener('error',ev=>{
          recordAnomaly('js-error',String(ev.message || 'Unknown JS error'),{lineno:ev.lineno,colno:ev.colno});
        });
        window.addEventListener('unhandledrejection',ev=>{
          recordAnomaly('js-rejection',String(ev.reason || 'Unhandled promise rejection'));
        });
      }
      pushDiagnosticEvent('start',{blockCount:blocks.length,markdownLen:base.length,empty:!base.length});
      document.addEventListener('selectionchange',()=>{
        observeClipboardSelection();
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
        const imageSources=Array.from(rich.querySelectorAll("img"),image=>image.getAttribute("src"));
        const html=rich.cloneNode(true);
        // Das Fragment verlässt das Dokument-CSS. Native HTML-/RTF-Ziele
        // benötigen die sichtbare Textmarkerfarbe direkt am kopierten Element.
        const markSource=Array.from(root.querySelectorAll('mark')).find(n=>range.intersectsNode(n));
        if(markSource){const style=getComputedStyle(markSource);html.querySelectorAll('mark').forEach(n=>{n.style.backgroundColor=style.backgroundColor;n.style.color=style.color;});}
        html.querySelectorAll('.fastra-visible-blank-line').forEach(n=>{
          if(!n.textContent.length && Array.from(n.querySelectorAll('*')).every(child=>child.tagName==='BR'))n.replaceWith(document.createElement('br'));
          else {n.classList.remove('fastra-visible-blank-line');if(!n.classList.length)n.removeAttribute('class');}
        });
        html.querySelectorAll('[data-srcline]').forEach(n=>n.removeAttribute('data-srcline'));
        html.querySelectorAll('[data-md-edit-boundary]').forEach(n=>n.remove());
        html.querySelectorAll('*').forEach(n=>{for(const a of Array.from(n.attributes))if(a.name.startsWith('data-md-') || a.name==='contenteditable')n.removeAttribute(a.name);});
        e.preventDefault();e.stopPropagation();
        if(clipboardLimit && [s.toString(),html.innerHTML,markdown].some(value=>new TextEncoder().encode(value).length>clipboardLimit)){
          window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'clipboardError',session,reason:'size'});return;
        }
        const bookmark=window.fastraVisual.bookmark();
        // Bildbytes müssen gesichert sein, bevor Ausschneiden die Undo-Datei verschiebt.
        copiedHTML=html;clipboardBookmark=bookmark;updateFence();
        window.webkit.messageHandlers.markdownCopy.postMessage({plain:s.toString(),html:html.innerHTML,markdown,imageSources,session,bookmark,cut:e.type==='cut'});
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
        if(e.key==='Enter' && (e.shiftKey || e.altKey) && !e.ctrlKey && !e.metaKey && !e.isComposing && !composing && !fenced){
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
      window.addEventListener('scroll',()=>{
        if(viewportRestoring || viewportPending)return;viewportPending=true;
        requestAnimationFrame(()=>{viewportPending=false;reportViewport();});
      },{passive:true});
      for(const type of ['wheel','pointerdown','keydown'])window.addEventListener(type,()=>{
        viewportGeneration++;viewportRestoring=false;
      },{passive:true});
      await restoreViewport(configuration.viewport);
      if(serialize()!==base)return false;
      initializing=false;updateFence();
      root.focus({preventScroll:true});
      return true;
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
      const beforeTextLen=visibleTextLength(),selBefore=selectionSummary();
      pushDiagnosticEvent('command',{command,beforeTextLen,sel:selBefore});
      try{
      switch(command){
        case 'deleteImage': {
          restoreSelection();const range=getSelection().rangeCount?getSelection().getRangeAt(0):null;
          if(range && range.startContainer===range.endContainer && range.endOffset===range.startOffset+1 && range.startContainer.childNodes[range.startOffset]?.nodeName==='IMG')exec('delete');
          break;
        }
        case 'heading1':formatHeading('h1');break;
        case 'heading2':formatHeading('h2');break;
        case 'heading3':formatHeading('h3');break;
        case 'plainParagraph':plainParagraph();break;
        case 'bulletList':listCommand(false);break;
        case 'orderedList':listCommand(true);break;
        case 'taskList':taskList();break;
        case 'quote':quoteCommand();break;
        case 'hardBreak':hardBreakCommand();break;
        case 'link':exec('createLink',value);break;
        case 'insertTable':exec('insertHTML',value);break;
        case 'insertHTML':exec('insertHTML',value);break;
        case 'bold':case 'italic':case 'code':case 'highlight': {
          restoreSelection();const s=getSelection();if(!s.rangeCount)return;
          const r=s.getRangeAt(0),tag={bold:'strong',italic:'em',code:'code',highlight:'mark'}[command];
          if(r.collapsed && (command==='bold' || command==='italic')){exec(command);break;}
          const ancestor=r.commonAncestorContainer.nodeType===1?r.commonAncestorContainer:r.commonAncestorContainer.parentElement;
          const selector=command==='bold'?'strong,b':command==='italic'?'em,i':tag;
          let marked=ancestor?.closest?.(selector) || null;
          if(!marked && !r.collapsed && ancestor){
            marked=Array.from(ancestor.querySelectorAll(selector)).find(node=>{
              const nodeRange=document.createRange();nodeRange.selectNode(node);
              return r.toString()===node.textContent && r.compareBoundaryPoints(Range.START_TO_START,nodeRange)<=0 && r.compareBoundaryPoints(Range.END_TO_END,nodeRange)>=0;
            });
          }
          if(marked){
            const full=document.createRange();full.selectNodeContents(marked);
            const before=full.cloneRange(),after=full.cloneRange();
            if(marked.contains(r.startContainer))before.setEnd(r.startContainer,r.startOffset);else before.collapse(true);
            if(marked.contains(r.endContainer))after.setStart(r.endContainer,r.endOffset);else after.collapse(false);
            const wrap=fragment=>{const element=document.createElement(tag);element.append(fragment);return element.textContent.replace(/\u200b/g,'').length || element.querySelector('img,input,[data-tex],[data-md-opaque]')?element.outerHTML:'';};
            const middle=document.createElement('span');middle.append(r.collapsed || !marked.contains(r.startContainer)?full.cloneContents():r.cloneContents());
            middle.querySelectorAll(selector).forEach(n=>n.replaceWith(...n.childNodes));
            const startMarker='<span data-md-selection-start="">\u200b</span>';
            const endMarker=r.collapsed?'':'<span data-md-selection-end="">\u200b</span>';
            const html=r.collapsed?(startMarker+middle.innerHTML):(wrap(before.cloneContents())+startMarker+middle.innerHTML+endMarker+wrap(after.cloneContents()));
            // WebKit übernimmt beim Ersetzen eines Inline-Knotens dessen
            // Schreibattribute. Der ganze Top-Level-Block ist ein neutraler Undo-Schritt.
            let block=marked;
            while(block && block.parentNode!==root)block=block.parentNode;
            if(!block)return;
            const path=[];let current=marked;while(current!==block){path.unshift(Array.from(current.parentNode.childNodes).indexOf(current));current=current.parentNode;}
            const clone=block.cloneNode(true);let target=clone;for(const index of path)target=target.childNodes[index];
            const template=document.createElement('template');template.innerHTML=html;target.replaceWith(template.content);
            replaceVisualBlocks([block],clone.outerHTML);
          }
          else {
            // Auch Inline-Auswahlen brauchen neutrale Absatzgrenzen: Am
            // Absatzende wandelt WebKit <mark> sonst in einen CSS-Span um,
            // dessen gelbe Farbe beim Markdown-Speichern verloren ginge.
            replaceFormattedSelection(r,tag);
          }
          break;
        }
      }
      const afterTextLen=visibleTextLength();
      const nonDeleting=['bold','italic','code','highlight','heading1','heading2','heading3','plainParagraph','bulletList','orderedList','taskList','quote','hardBreak','link'].includes(command);
      if(nonDeleting && afterTextLen<beforeTextLen){
        recordAnomaly('unexpected-text-loss',`Command ${command} reduced visible text (${beforeTextLen} -> ${afterTextLen})`,{command,beforeTextLen,afterTextLen});
      }
      }catch(err){
        recordAnomaly('command-exception',`Command ${command} threw: ${err?.message || err}`,{command,error:String(err)});
        throw err;
      }
    },
    exportClipboardHTML(key,replacements){
      if(key!==clipboardBookmark || !copiedHTML)return null;
      const copy=copiedHTML.cloneNode(true);
      for(const image of copy.querySelectorAll("img")){const data=replacements[image.getAttribute("src")];if(!data?.startsWith("data:image/"))return null;image.setAttribute("src",data);}
      return copy.innerHTML;
    },
    caretClipboard(x,y){const range=document.caretRangeFromPoint?.(x,y);if(!range || !root.contains(range.commonAncestorContainer))return null;selection=range;getSelection().removeAllRanges();getSelection().addRange(range);return window.fastraVisual.bookmarkClipboard();},
    caret(x,y){const r=document.caretRangeFromPoint?.(x,y);if(!r || !root.contains(r.commonAncestorContainer))return null;selection=r;getSelection().removeAllRanges();getSelection().addRange(r);return window.fastraVisual.bookmark();},
    bookmark(existing){if(existing)return bookmarks.has(existing)?existing:null;restoreSelection();const key=String(++bookmarkID);bookmarks.set(key,{range:selection.cloneRange(),base:serialize()});return key;},
    bookmarkClipboard(){
      const key=window.fastraVisual.bookmark(),saved=bookmarks.get(key);
      saved.clipboardSelection=observeClipboardSelection();saved.clipboardSelectionGeneration=clipboardSelectionGeneration;
      return key;
    },
    validateClipboardBookmark(key){const saved=bookmarks.get(key);return !!saved && saved.base===serialize() && root.contains(saved.range.commonAncestorContainer) && currentClipboardSelection(saved);},
    clipboardState(){return {markdown:serialize(),revision,imageTransactions:imageTransactions()};},
    discardBookmark(key){return bookmarks.delete(key);},
    insertBookmarked(key,html,atoms,transaction,imageSources,singleLine=false,imageEnding=null){
      if(fenced)return false;
      const saved=bookmarks.get(key);bookmarks.delete(key);
      if(!saved || saved.base!==serialize() || !root.contains(saved.range.commonAncestorContainer) || !currentClipboardSelection(saved))return false;
      Object.assign(opaqueSources,atoms || {});
      const template=document.createElement('template');template.innerHTML=html;
      if(transaction)template.content.querySelectorAll('img').forEach(n=>{
        if(!imageSources.includes(n.getAttribute('src')))return;
        n.dataset.mdImageTransaction=transaction;
        if(imageEnding==='crlf' || imageEnding==='cr')n.dataset.mdImageEnding=imageEnding;
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
    async replaceSource(expected,html,configuration,prefix){
      if(!sourceReplacementEnabled)return 'unsupported';
      if(composing || fenced)return 'busy';
      if(serialize()!==expected)return 'stale';
      if(sourceContexts.has(prefix) || sourceContextBytes+sourceContextCost(configuration,html)>33554432)return 'limit';
      const template=document.createElement('template');template.innerHTML=html;
      const holder=document.createElement('div');holder.append(template.content);
      const ownedImages=new Map(Array.from(root.querySelectorAll('img[data-md-image-transaction]'),n=>[n.dataset.mdSrc,n.dataset.mdImageTransaction]));
      holder.querySelectorAll('img[data-md-src]').forEach(n=>{const transaction=ownedImages.get(n.dataset.mdSrc);if(transaction)n.dataset.mdImageTransaction=transaction;});
      if(composing || fenced || serialize()!==expected)return 'stale';
      if(sourceContextBytes+sourceContextCost(configuration,holder.innerHTML)+prefix.length*holder.querySelectorAll('[data-md-block]').length>33554432)return 'limit';
      const context=registerSourceContext(configuration,holder,prefix);
      ensureContextNode(holder,context,prefix+'empty');
      if(sourceContextBytes>33554432)return 'limit';
      holder.querySelectorAll('[data-tex]').forEach(n=>{n.textContent=n.dataset.tex;n.removeAttribute('data-rendered');});
      holder.querySelectorAll('[contenteditable]').forEach(n=>n.removeAttribute('contenteditable'));
      const previousRoot=root,previousContext={blocks,hiddenPrefixes,trailingHidden,trailingOwner};
      root=holder;activateSourceContext(context);
      const complete=serialize()===configuration.markdown;
      root=previousRoot;activateSourceContext(previousContext);
      if(!complete)return 'incomplete';
      const affected=Array.from(root.children).filter(n=>!n.hasAttribute('data-md-edit-boundary'));
      function boundary(neighbor){const node=neighbor?.hasAttribute('data-md-edit-boundary')?neighbor:document.createElement('p');node.dataset.mdEditBoundary='';if(!node.firstChild)node.append(document.createTextNode('\u200b'));node.style.display='';return node;}
      const before=boundary(affected[0]?.previousElementSibling),after=boundary(affected.at(-1)?.nextElementSibling);
      if(affected.length){affected[0].before(before);affected.at(-1).after(after);}else{root.prepend(before);root.append(after);}
      const range=document.createRange();range.setStart(before.firstChild,0);range.setEnd(after.firstChild,1);root.focus();getSelection().removeAllRanges();getSelection().addRange(range);selection=range;
      activateSourceContext(context);
      const protectedNodes=Array.from(root.querySelectorAll('[contenteditable=false]'));
      protectedNodes.forEach(n=>n.removeAttribute('contenteditable'));
      let ok=false;
      try{
        editingCommand=true;lastInputType='';document.execCommand('insertHTML',false,before.outerHTML+holder.innerHTML+after.outerHTML);restoreMarkers();
        ok=serialize()===configuration.markdown;
        if(!ok && serialize()!==expected)document.execCommand('undo');
      }finally{
        editingCommand=false;
        protectedNodes.forEach(n=>{if(n.isConnected)n.contentEditable='false';});
        root.querySelectorAll('[data-tex],[data-md-opaque],.mermaid-render,input[type=checkbox]').forEach(n=>n.contentEditable='false');
      }
      if(!ok){if(serialize()!==expected){actionFenced=true;updateFence();}return 'insert';}
      window.fastraEnhanceMarkdown?.(root);changed();return true;
    },
    requestClipboardCopy(cut=false){restoreSelection();root.dispatchEvent(new Event(cut?'cut':'copy',{bubbles:true,cancelable:true}));},
    requestClipboardPaste(plain=false){if(!fenced)window.webkit.messageHandlers.visualMarkdown.postMessage({kind:'linuxPaste',session,bookmark:window.fastraVisual.bookmarkClipboard(),plain});},
    inspectClipboardHTML(html){const cleaned=clipboardHTML(html,true);return cleaned.ok && cleaned.images.length?{ok:true,markdown:toMarkdown(cleaned.html),url:"file:///fastra-html-clipboard/Clipboard.md",images:cleaned.images}:cleaned;},
    insertClipboardHTML(key,html){
      const cleaned=clipboardHTML(html);if(!cleaned.ok){bookmarks.delete(key);return cleaned;}
      return {ok:window.fastraVisual.insertBookmarked(key,cleaned.html,{},null,[],false),reason:'stale'};
    },
    insertClipboardText(key,text){
      const saved=bookmarks.get(key);bookmarks.delete(key);
      if(fenced || !saved || saved.base!==serialize() || !root.contains(saved.range.commonAncestorContainer) || !currentClipboardSelection(saved))return false;
      selection=saved.range;getSelection().removeAllRanges();getSelection().addRange(selection);exec('insertText',text);return true;
    },
    cancelClipboard(){if(clipboardBookmark!==null)window.fastraVisual.completeClipboard(clipboardBookmark,false,false);},
    completeClipboard(key,cut,succeeded){
      if(key!==clipboardBookmark)return false;
      const saved=bookmarks.get(key);bookmarks.delete(key);
      const unchanged=saved && saved.base===serialize() && root.contains(saved.range.commonAncestorContainer);
      copiedHTML=null;clipboardBookmark=null;updateFence();
      if(cut && succeeded && unchanged){selection=saved.range;getSelection().removeAllRanges();getSelection().addRange(selection);exec('insertHTML','');}
      return !!unchanged;
    },
    async updateStyle(font,size,dark){
      document.body.style.setProperty('--fastra-copy-border',dark?'#484848':'#D7D7D7');
      document.body.style.setProperty('--fastra-copy-background',dark?'#333333':'#ECECEC');
      let sheet=document.getElementById('fastra-visual-style');if(!sheet){sheet=document.createElement('style');sheet.id='fastra-visual-style';document.head.append(sheet);}
      const family=font==='System'?'-apple-system, BlinkMacSystemFont, sans-serif':JSON.stringify(font)+', -apple-system, sans-serif';
      sheet.textContent=`body{font-family:${family};font-size:${size}px;color:${dark?'#F2F2F2':'#363636'};background:${dark?'#171717':'#FFFFFF'}}h1,h2,h3,h4,h5,h6{color:inherit}blockquote,pre.mermaid-error::before{color:${dark?'#A8A8A8':'#737373'}}a{color:${dark?'#8BB7F2':'#3F69A8'}}code,pre{background:${dark?'#333333':'#ECECEC'}}td,th,blockquote,hr{border-color:${dark?'#484848':'#D7D7D7'}}mark{background:${dark?'#665200':'#FFEE9A'};color:inherit}`;
      window.fastraMarkdownPresentation?.update();
      await window.fastraUpdateMarkdownTheme?.(root,dark);
      window.fastraMarkdownPresentation?.update();
    },
    prepareAction(expectedSession,actionID){
      const native=arguments.length!==0;
      if(native && (arguments.length!==2 || expectedSession!==session || typeof actionID!=='string' || !actionID.length || nativeActionIDs.has(actionID)))return null;
      if(composing)return {composing:true};
      if(native)nativeActionIDs.add(actionID);else actionFenced=true;
      // Eine Dokumentaktion übernimmt den aktuellen Stand. Ein noch nicht
      // bestätigter Cut darf ihn danach nicht mehr verändern; die Kopie bleibt.
      if(clipboardBookmark!==null){bookmarks.delete(clipboardBookmark);clipboardBookmark=null;}
      updateFence();changed();
      const snapshot={markdown:serialize(),revision,imageTransactions:imageTransactions(),inputType:lastInputType,viewport:viewportPosition()};
      if(native){snapshot.session=session;snapshot.actionID=actionID;}
      return snapshot;
    },
    compareSaveAppearance(expectedSession,actionID,expectedRevision,html){
      if(expectedSession!==session || !nativeActionIDs.has(actionID) || revision!==expectedRevision)return null;
      // Vorschau-HTML im Template bleibt inert, auch bei lokalen Bildern.
      lastRenderedHTML=html;
      const candidate=document.createElement('template');candidate.innerHTML=html;
      const live=saveAppearance(root,lastInputType),saved=saveAppearance(candidate.content);
      const comparison=diffAppearance(live,saved);
      lastAppearanceCheck={revision,at:new Date().toISOString(),source:'save',...comparison};
      return comparison.outcome;
    },
    inspectAppearance(expectedSession,expectedRevision,html){
      if(expectedSession!==session || revision!==expectedRevision)return null;
      lastRenderedHTML=html;
      const candidate=document.createElement('template');candidate.innerHTML=html;
      const live=saveAppearance(root,lastInputType),saved=saveAppearance(candidate.content);
      const comparison=diffAppearance(live,saved);
      lastAppearanceCheck={revision,at:new Date().toISOString(),source:'live',...comparison};
      return {
        outcome:comparison.outcome,
        diff:comparison.diff,
        revision,
        anomalies:diagnosticAnomalies.slice(-10)
      };
    },
    diagnosticReport(includeContent=false){
      const markdown=serialize();
      const report={
        session,
        revision,
        fenced,
        composing,
        lastInputType,
        visibleTextLength:visibleTextLength(),
        markdownLength:markdown.length,
        lastAppearanceCheck,
        anomalies:diagnosticAnomalies.slice(),
        events:diagnosticEvents.slice(),
        domSkeleton:domSkeleton(root)
      };
      if(includeContent){
        report.liveHTML=root?.innerHTML || '';
        report.serializedMarkdown=markdown;
        report.lastRenderedHTML=lastRenderedHTML;
      }
      return report;
    },
    completeAction(expectedSession,actionID){
      if(expectedSession!==session)return;
      if(arguments.length===1)actionFenced=false;
      else {
        if(arguments.length!==2 || typeof actionID!=='string' || !actionID.length || !nativeActionIDs.delete(actionID))return;
      }
      updateFence();
    },
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
    viewport:()=>viewportPosition(),
    markdown:()=>serialize(),
    flush:()=>changed()
  };
})();
