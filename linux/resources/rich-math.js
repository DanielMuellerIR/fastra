(() => {
  'use strict';
  let dark=document.documentElement.dataset.dark==='true',revision=0,serial=0,rendering=Promise.resolve();
  const sources=new Map();
  function enqueue(root) {
    const current=++revision;
    rendering=rendering.catch(()=>{}).then(async()=>{
      if(current!==revision)return;
      mermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,maxTextSize:100000,maxEdges:500,theme:dark?'dark':'default'});
      for(const element of root.querySelectorAll('[data-fastra-diagram]')){
        const source=sources.get(element.dataset.fastraDiagram);if(source===undefined)continue;
        const holder=document.createElement('div'),id='fastraRichDiagram'+(++serial);
        holder.style.cssText='position:absolute;left:-100000px;top:0;visibility:hidden';document.body.append(holder);
        try {
          const result=await mermaid.render(id,source,holder);
          if(current!==revision)return;
          if(!element.isConnected)continue;
          const diagram=element.tagName==='PRE'?document.createElement('div'):element;
          diagram.className='mermaid-render';diagram.contentEditable='false';
          diagram.dataset.fastraDiagram=element.dataset.fastraDiagram;diagram.dataset.fastraDiagramDark=String(dark);diagram.innerHTML=result.svg;
          delete diagram.dataset.error;if(diagram!==element)element.replaceWith(diagram);
        } catch (_) {
          if(current!==revision)return;
          element.classList.add('mermaid-error');element.dataset.error=document.documentElement.lang==='de'?'Diagramm konnte nicht gerendert werden.':'Diagram could not be rendered.';
        } finally { holder.remove(); }
      }
    });return rendering;
  }
  window.fastraUpdateMarkdownTheme=(root,value)=>{
    if(dark===value)return rendering;dark=value;return enqueue(root);
  };
  window.fastraEnhanceMarkdown=async root=>{
    root.querySelectorAll('[data-tex]:not([data-rendered])').forEach(element=>{
      try { katex.render(element.dataset.tex,element,{displayMode:element.classList.contains('math-block'),output:'mathml',throwOnError:false,trust:false}); }
      catch (_) { element.textContent=element.dataset.tex; }
      element.dataset.rendered='1';
    });
    root.querySelectorAll('pre>code:not(.language-mermaid):not([data-highlighted])').forEach(code=>{try{hljs.highlightElement(code);}catch{}});
    let added=false;
    for(const code of root.querySelectorAll('pre>code.language-mermaid')){
      const pre=code.parentElement;if(pre.dataset.fastraDiagram)continue;
      const id=String(++serial);pre.dataset.fastraDiagram=id;sources.set(id,code.textContent);added=true;
    }
    const stale=[...root.querySelectorAll('.mermaid-render[data-fastra-diagram]')].some(node=>node.dataset.fastraDiagramDark!==String(dark));
    if(added||stale)await enqueue(root);
  };
  // Undo kann einen früheren SVG-Knoten samt damaliger Palette zurückbringen.
  document.addEventListener('input',event=>{
    if(event.inputType!=='historyUndo'&&event.inputType!=='historyRedo')return;
    queueMicrotask(()=>{const root=document.getElementById('fastra-visual');if(root)void window.fastraEnhanceMarkdown(root);});
  },true);
})();
