async function runReportCase(name) {
  const root=document.querySelector('#fastra-visual');
  const check=(value,message)=>{if(!value)throw new Error(message);};
  function select(node,collapse=false){const r=document.createRange();r.selectNodeContents(node);if(collapse)r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);root.focus();}
  async function start(source,html,blocks,viewport){root.innerHTML=html;await fastraVisual.start({markdown:source,session:'document-b',blocks:blocks || [{id:0,source,hidden:false}],opaqueSources:{0:'UNRELATED PRIVATE ORIGINAL'},viewport});}
  function copy(node){select(node);root.dispatchEvent(new Event('copy',{bubbles:true,cancelable:true}));const payload=window.__copy;check(!!payload,'copy payload');check(fastraVisual.completeClipboard(payload.bookmark,false,true),'copy owner');return payload;}
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  if(name==='plain-copy'){
    await start('<strong>Bold</strong>\n','<div data-md-block="0"><p><strong>Bold</strong></p></div>');
    const copied=copy(root.querySelector('strong'));check(copied.markdown==='**Bold**','copy adds no blank');
    select(root);check(fastraVisual.insertBookmarked(fastraVisual.bookmark(),'<p><strong>Bold</strong></p>',{},null,[],true),'bound paste');
    check(root.textContent==='Bold','paste adds no blank');check(!fastraVisual.markdown().includes('&nbsp;'),'identical rendered replacement introduces no protected blank');
  }else if(name==='spaces'){
    await start('','',[]);
    for(const [tag,delimiter] of [['strong','**'],['em','*'],['mark','=='],['del','~~']]){
      root.innerHTML='<p><'+tag+'>Bold&nbsp;</'+tag+'></p>';
      const copied=copy(root.querySelector(tag));check(copied.markdown===delimiter+'Bold&nbsp;'+delimiter,tag+' keeps Markdown and NBSP');
      check(copied.plain==='Bold\u00a0',tag+' keeps plain NBSP');
      root.innerHTML='<p>Before<'+tag+'>&nbsp;Bold&nbsp;</'+tag+'>after</p>';
      const unsafe=copy(root.querySelector('p'));check(unsafe.markdown.includes('<'+tag+'>'),tag+' unsafe boundary retains HTML');
      check(unsafe.markdown.includes('&nbsp;'),tag+' unsafe boundary keeps NBSP');
    }
  }else if(name==='return-delete' || name==='return-delete-nbsp'){
    await start('','',[]);select(root);
    const text=name.endsWith('nbsp')?'Bold&nbsp;':'Bold';
    check(fastraVisual.insertBookmarked(fastraVisual.bookmark(),'<p><strong>'+text+'</strong></p>',{},null,[],true),'bound paste');
    select(root.querySelector('strong'),true);document.execCommand('insertParagraph');
    const beforeDelete=fastraVisual.markdown();check(!beforeDelete.includes('**  '),'no empty strong delimiter lines');
    check(root.querySelectorAll('p').length===2,'Return retains an editable blank paragraph');
    select(root);document.execCommand('delete');check(fastraVisual.markdown()==='','Delete leaves one empty editor line');
    document.execCommand('undo');check(fastraVisual.markdown()===beforeDelete,'Undo restores complete source');
  }else if(name==='preserve-blocks'){
    const blocks=[{id:0,source:'Before\r\n',hidden:false},{id:1,source:'\r\n',hidden:true},{id:2,source:'**Bold**\r\n',hidden:false},{id:3,source:'\r\n\r\n',hidden:true}];
    const source=blocks.map(b=>b.source).join('');await start(source,'<div data-md-block="0"><p>Before</p></div><div data-md-block="2"><p><strong>Bold</strong></p></div>',blocks);
    check(fastraVisual.markdown()===source,'unchanged CRLF source exact');
    select(root.querySelector('strong'),true);document.execCommand('insertText',false,'!');
    check(fastraVisual.markdown()==='Before\r\n\r\n**Bold!**\r\n\r\n\r\n','edited block preserves neighbor and trailing bytes');
    document.execCommand('undo');check(fastraVisual.markdown()===source,'Undo exact source');
  }else if(name==='hidden-definitions'){
    const blocks=[{id:0,source:'Before\n',hidden:false},{id:1,source:'\n\n',hidden:true},{id:2,source:'[ref]: https://example.test\n',hidden:true}];
    await start(blocks.map(b=>b.source).join(''),'<div data-md-block="0"><p>Before</p></div>',blocks);
    select(root);document.execCommand('delete');check(fastraVisual.markdown()==='[ref]: https://example.test\n','Delete preserves definitions without orphan blanks');
  }else if(name==='highlight-copy'){
    await start('==Marked==\n','<div data-md-block="0"><p><mark>Marked</mark></p></div>');
    const copied=copy(root.querySelector('mark'));check(copied.markdown==='==Marked==','highlight remains Markdown');
    check(/background-color:\s*rgb\(255, 238, 154\)/.test(copied.html),'HTML/RTF targets receive highlight color');
    check(!/data-md-|document-b|UNRELATED PRIVATE ORIGINAL/.test(copied.html+copied.markdown),'private source metadata never copied');
  }else if(name==='foreign-metadata'){
    await start('Receiver\n','<div data-md-block="0"><p>Receiver</p></div>');select(root);
    const event=new Event('paste',{bubbles:true,cancelable:true});
    Object.defineProperty(event,'clipboardData',{value:{files:[],getData:type=>type==='text/html'?'<div data-md-block="0" data-md-origin="document-a"><p><mark data-md-opaque="0">Marked</mark> <strong>Bold&nbsp;</strong></p></div>':type==='text/plain'?'Marked Bold\u00a0':''}});root.dispatchEvent(event);
    const source=fastraVisual.markdown();check(!source.includes('UNRELATED PRIVATE ORIGINAL'),'foreign atom ID cannot address receiver map');
    check(source.includes('Marked') && source.includes('Bold'),'foreign text remains copied text');
    check(!root.querySelector('[data-md-origin],[data-md-opaque]'),'foreign metadata stripped');
  }else if(name==='nested-formatting'){
    await start('','',[]);root.innerHTML='<p><strong><mark>Marked</mark></strong></p>';
    check(copy(root.querySelector('p')).markdown==='**==Marked==**','nested highlight uses Markdown');
    root.innerHTML='<p>a<strong><em>Bold</em></strong>b</p>';
    check(copy(root.querySelector('p')).markdown==='a***Bold***b','nested emphasis uses one delimiter run');
    for(const [tag,delimiter] of [['strong','**'],['em','*']]){
      root.innerHTML='<p><'+tag+'>outer<'+tag+'>inner</'+tag+'>end</'+tag+'></p>';
      check(copy(root.querySelector('p')).markdown===delimiter+'outerinnerend'+delimiter,'same-kind nested '+tag+' remains one formatted range');
    }
  }else if(name==='clipboard-policy'){
    await start('Receiver\n','<div data-md-block="0"><p>Receiver</p></div>');
    select(root.querySelector('p'));
    let result=fastraVisual.insertClipboardHTML(fastraVisual.bookmark(),'<p><span style="font-weight:700;background-color:yellow" data-md-opaque="0">Marked</span> <a href="https://example.test/path">Link</a></p>');
    check(result.ok,'strict formatted HTML accepted');check(root.querySelector('strong mark,mark strong'),'safe style converted to semantic formatting');
    check(!root.querySelector('[style],[data-md-opaque]'),'styles and foreign atoms removed');
    result=fastraVisual.insertClipboardHTML(fastraVisual.bookmark(),'<!doctype html><html><head><meta charset="utf-8"><title>Clipboard</title></head><body><p><strong>Envelope</strong></p></body></html>');check(result.ok,'HTML document envelope accepted');check(root.querySelector('strong')?.textContent.includes('Envelope') || Array.from(root.querySelectorAll('strong')).some(n=>n.textContent==='Envelope'),'envelope semantic formatting');
    const before=fastraVisual.markdown();
    for(const html of ['<script>bad()</script>','<img src="https://example.test/private">','<a href="javascript:bad()">Bad</a>','<a href="relative/private">Bad</a>']){
      select(root.querySelector('p'));result=fastraVisual.insertClipboardHTML(fastraVisual.bookmark(),html);
      check(!result.ok,'unsafe/unimplemented clipboard format refused');check(fastraVisual.markdown()===before,'refusal has no output');
    }
    select(root.querySelector('p'));const bookmark=fastraVisual.bookmark();document.execCommand('insertText',false,'Changed');
    result=fastraVisual.insertClipboardHTML(bookmark,'<p>STALE</p>');check(!result.ok && !root.textContent.includes('STALE'),'stale bookmark refuses output');
  }else if(name==='clipboard-selection'){
    await start('Receiver\n','<div data-md-block="0"><p>Receiver</p></div>');
    const text=root.querySelector('p').firstChild;
    function caret(at){const r=document.createRange();r.setStart(text,at);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);}
    caret(1);const moved=fastraVisual.bookmarkClipboard();caret(2);
    check(!fastraVisual.insertClipboardHTML(moved,'<strong>STALE</strong>').ok,'live selection checked before formatted insert');
    caret(1);const aba=fastraVisual.bookmarkClipboard();caret(2);document.dispatchEvent(new Event('selectionchange'));caret(1);
    check(!fastraVisual.insertClipboardText(aba,'STALE'),'selection ABA rejects plain insert');
    caret(1);const gesture=fastraVisual.bookmarkClipboard();root.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));root.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}));
    check(!fastraVisual.insertBookmarked(gesture,'<strong>STALE</strong>',{}),'coalesced navigation ABA rejects generic insert');
    caret(1);const unchanged=fastraVisual.bookmarkClipboard();document.dispatchEvent(new Event('selectionchange'));
    check(fastraVisual.insertClipboardText(unchanged,'Valid'),'unchanged delayed selection remains usable');
    const original=root.querySelector('p').firstChild,r=document.createRange();r.selectNodeContents(root.querySelector('p'));r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);
    const legacy=fastraVisual.bookmark();r.setStart(original,0);r.collapse(true);getSelection().removeAllRanges();getSelection().addRange(r);document.dispatchEvent(new Event('selectionchange'));
    check(fastraVisual.insertBookmarked(legacy,'<strong>Legacy</strong>',{}),'legacy image/dialog bookmark keeps its saved insertion point');
    check(!root.textContent.includes('STALE') && root.textContent.includes('Valid') && root.textContent.endsWith('Legacy'),'no stale output and legacy destination retained');
  }else if(name==='viewport'){
    const html=Array.from({length:150},(_,i)=>'<p>Line '+i+'</p>').join('');
    const source=Array.from({length:150},(_,i)=>'Line '+i+'\n\n').join('');
    await start(source,'<div data-md-block="0">'+html+'</div>',undefined,{x:0,y:1500});
    check(Math.abs(window.scrollY-1500)<1,'viewport restored after loaded layout');
    window.scrollTo(0,1800);await pause(100);const snapshot=fastraVisual.prepareAction();
    check(snapshot.viewport.y>1700,'action snapshot captures actual viewport');fastraVisual.completeAction('document-b');
    check(window.__messages.some(m=>m.name==='visualMarkdown' && m.value.kind==='viewport' && m.value.viewport.y>1700),'live viewport message');
  }else throw new Error('Unknown report case '+name);
  return {name,pass:true,source:fastraVisual.markdown(),html:root.innerHTML};
}
