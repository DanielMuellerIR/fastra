(() => {
  const token = document.documentElement.dataset.fastraRender;
  const de = document.documentElement.lang === 'de';
  const labels = de ? ['Code kopieren','Code kopiert','Code konnte nicht kopiert werden.'] : ['Copy code','Code copied','Code could not be copied.'];
  const copyIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2"/><path d="M13 5V3H3v10h2"/></svg>';
  const copiedIcon = '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m4 10 4 4 8-9"/></svg>';
  const controls = document.createElement('div'); controls.id = 'fastra-code-controls';
  controls.contentEditable = 'false'; controls.setAttribute('aria-label', labels[0]);
  document.body.append(controls);
  const buttons = new Map(), requests = new Map();
  let serial = 0, scheduled = false;
  function update() {
    scheduled = false;
    for (const [pre,button] of buttons) if (!pre.isConnected) { button.remove(); buttons.delete(pre); }
    for (const pre of document.querySelectorAll('pre[data-fastra-code]')) {
      if (!pre.querySelector(':scope > code')) continue;
      let button = buttons.get(pre);
      if (!button) {
        button = document.createElement('button'); button.type='button'; button.className='fastra-code-copy';
        button.title=labels[0]; button.setAttribute('aria-label',labels[0]); button.innerHTML=copyIcon;
        button.addEventListener('mousedown',event=>event.preventDefault());
        button.addEventListener('click',event=>{
          event.preventDefault(); event.stopPropagation();
          if (!event.isTrusted || !pre.isConnected || document.documentElement.dataset.fastraRender!==token || serial>=Number.MAX_SAFE_INTEGER) return;
          const bridge=window.webkit?.messageHandlers?.markdownCodeCopy;
          if (!bridge) return;
          const epoch=document.documentElement.dataset.fastraPositionEpoch;
          if(!epoch)return;
          const request=++serial; requests.set(request,button);
          bridge.postMessage({token:token+':'+epoch,block:Number(pre.dataset.fastraCode),request});
        });
        buttons.set(pre,button); controls.append(button);
      }
      const rect=pre.getBoundingClientRect(), table=pre.closest('table')?.getBoundingClientRect();
      const right=Math.min(rect.right,table?.right??innerWidth,innerWidth), left=Math.max(rect.left,table?.left??0,0);
      button.hidden=rect.bottom<0 || rect.top>innerHeight || right-left<48;
      button.style.left=(scrollX+right-40)+'px'; button.style.top=(scrollY+rect.top+8)+'px';
    }
  }
  function schedule() { if (!scheduled) {scheduled=true;setTimeout(update,0);} }
  window.fastraCodeCopy={complete(page,request,ok){
    if(page!==token+':'+document.documentElement.dataset.fastraPositionEpoch || document.documentElement.dataset.fastraRender!==token)return;
    const button=requests.get(request);requests.delete(request);if(!button?.isConnected)return;
    button.innerHTML=ok?copiedIcon:copyIcon;button.title=labels[ok?1:2];button.setAttribute('aria-label',button.title);
    button.dataset.copyRequest=String(request);
    setTimeout(()=>{if(button.isConnected && button.dataset.copyRequest===String(request)){button.innerHTML=copyIcon;button.title=labels[0];button.setAttribute('aria-label',labels[0]);}},1800);
  }};
  new MutationObserver(records=>{if(records.some(record=>!controls.contains(record.target)))schedule();}).observe(document.body,{subtree:true,childList:true});
  new ResizeObserver(schedule).observe(document.body);
  addEventListener('resize',schedule);addEventListener('scroll',schedule,true);
  schedule();
})();
