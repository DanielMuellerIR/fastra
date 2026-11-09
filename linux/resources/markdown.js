// Klickpositionen sind ausschließlich Navigation innerhalb der gebundenen Vorschau.
(()=>{
  let revealGeneration=0;
  for(const name of ['pointerdown','wheel','keydown'])addEventListener(name,()=>{revealGeneration++;},{passive:true,capture:true});
  window.fastraCancelSourceReveal=()=>{revealGeneration++;};
  window.fastraRevealSourceLine=async(line,token,epoch)=>{
    const generation=++revealGeneration;
    for(let attempt=0;attempt<400;attempt++){
      if(generation!==revealGeneration || (document.documentElement.dataset.fastraRender!==token || document.documentElement.dataset.fastraPositionEpoch!==epoch))return false;
      if(window.fastraPreviewReady===true)break;
      await new Promise(resolve=>setTimeout(resolve,25));
    }
    if(generation!==revealGeneration || (document.documentElement.dataset.fastraRender!==token || document.documentElement.dataset.fastraPositionEpoch!==epoch) || !window.fastraPreviewReady)return false;
    let best=null,bestLine=-1;
    for(const element of document.querySelectorAll('[data-srcline]')){
      const current=Number(element.dataset.srcline);
      if(Number.isInteger(current)&&current<=line&&current>bestLine){best=element;bestLine=current;}
    }
    if(!best)return false;
    best.scrollIntoView({block:'center'});return true;
  };
  document.addEventListener('click',event=>{
    const selection=getSelection();
    if(selection && !selection.isCollapsed)return;
    const target=event.target instanceof Element?event.target:event.target?.parentElement;
    if(!target || target.closest('a,.blocked-link,button,[role=button]'))return;
    const math=target.closest('[data-tex],.math-source,code[data-srccol],img[data-srccol]');
    const block=math??target.closest('[data-srcline]');
    if(!block)return;
    let line=Number(block.dataset.srcline),column=Number(block.dataset.srccol??1);
    if(!Number.isSafeInteger(line)||line<1)return;
    const caret=document.caretRangeFromPoint?.(event.clientX,event.clientY);
    const standard=!caret?document.caretPositionFromPoint?.(event.clientX,event.clientY):null;
    const node=caret?.endContainer??standard?.offsetNode;
    const offset=caret?.endOffset??standard?.offset;
    if(!math && node && block.contains(node)){
      const range=document.createRange();range.selectNodeContents(block);
      try{range.setEnd(node,offset);const before=range.toString();const last=before.lastIndexOf('\n');line+=(before.match(/\n/g)||[]).length;column=last<0?column+before.length:before.length-last;}catch{}
    }
    window.webkit?.messageHandlers?.markdownPosition?.postMessage({token:document.documentElement.dataset.fastraRender,epoch:document.documentElement.dataset.fastraPositionEpoch,line,column});
  });
})();
// Optionen entsprechen dem bestehenden nativen Markdown-Host; Bibliotheken kommen aus MarkdownVendor.
(async()=>{
  // Nur die ergänzten Leerzeilen brauchen einen eigenen Exportpfad. Interne
  // Klassen/Quellpositionen und das Seitenskript gehören nicht ins Clipboard.
  document.addEventListener('copy',event=>{
    const selection=getSelection();
    if(!selection?.rangeCount || selection.isCollapsed || !event.clipboardData)return;
    const rich=document.createElement('div');
    for(let index=0;index<selection.rangeCount;index++)rich.append(selection.getRangeAt(index).cloneContents());
    if(!rich.querySelector('.fastra-visible-blank-line,#fastra-code-controls,[data-fastra-code],[data-srcline]'))return;
    rich.querySelectorAll('#fastra-code-controls').forEach(node=>node.remove());
    rich.querySelectorAll('[data-fastra-code]').forEach(node=>node.removeAttribute('data-fastra-code'));
    rich.querySelectorAll('.fastra-visible-blank-line').forEach(node=>node.replaceWith(document.createElement('br')));
    rich.querySelectorAll('[data-srcline],[data-srccol]').forEach(node=>{node.removeAttribute('data-srcline');node.removeAttribute('data-srccol');});
    rich.querySelectorAll('script').forEach(node=>node.remove());
    const palette=getComputedStyle(document.documentElement),foreground=getComputedStyle(document.body).color;
    rich.querySelectorAll('mark').forEach(node=>{node.style.backgroundColor=palette.getPropertyValue('--mark');node.style.color=foreground;});
    event.clipboardData.setData('text/plain',selection.toString());
    event.clipboardData.setData('text/html',rich.innerHTML);
    event.preventDefault();
  });
  const violations=[];
  addEventListener('securitypolicyviolation',event=>violations.push({blocked:event.blockedURI,directive:event.violatedDirective}));
  window.fastraPreviewViolations=violations;
  for(const element of document.querySelectorAll('[data-tex]')) {
    katex.render(element.dataset.tex,element,{displayMode:element.classList.contains('math-block'),output:'mathml',throwOnError:false,trust:false});
    element.dataset.rendered='1';
  }
  for(const code of document.querySelectorAll('pre>code:not(.language-mermaid)')) {try{hljs.highlightElement(code)}catch{}}
  const diagrams=[];let serial=0,generation=0,lastTheme=null,rendering=Promise.resolve();
  window.fastraPreviewTheme=dark=>{
    document.documentElement.dataset.dark=String(dark);
    if(lastTheme===dark)return rendering;
    const changed=lastTheme!==null;lastTheme=dark;const current=++generation;
    if(changed)window.fastraCancelSourceReveal?.();
    rendering=rendering.catch(()=>{}).then(async()=>{
      if(current!==generation)return;
      mermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,maxTextSize:100000,maxEdges:500,theme:dark?'dark':'default'});
      for(const entry of diagrams){
        if(!entry.current.isConnected)continue;
        try{
          const result=await mermaid.render('fastraDiagram'+(++serial),entry.source);
          if(current!==generation)return;
          entry.diagram.innerHTML=result.svg;
          if(entry.current!==entry.diagram){entry.current.replaceWith(entry.diagram);entry.current=entry.diagram;}
          entry.current.classList.remove('mermaid-error');delete entry.current.dataset.error;
        }catch{
          entry.current.classList.add('mermaid-error');entry.current.dataset.error=document.documentElement.lang==='de'?'Diagramm konnte nicht gerendert werden.':'Diagram could not be rendered.';
        }
      }
    });return rendering;
  };
  for(const code of document.querySelectorAll('pre>code.language-mermaid')){
    const pre=code.parentElement,diagram=document.createElement('div');diagram.className='mermaid-render';
    if(pre.hasAttribute('data-srcline'))diagram.dataset.srcline=pre.dataset.srcline;
    diagrams.push({current:pre,diagram,source:code.textContent});
  }
  await window.fastraPreviewTheme(document.documentElement.dataset.dark==='true');
  await document.fonts.ready;
  window.fastraPreviewReady=true;
})();
