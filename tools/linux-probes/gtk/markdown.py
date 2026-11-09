#!/usr/bin/env python3
import gi,json,pathlib,sys,struct,zlib
for n,v in [('Gtk','4.0'),('WebKit','6.0')]:gi.require_version(n,v)
from gi.repository import Gtk,WebKit,GLib,Gio
Gtk.init();root=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);out.mkdir(exist_ok=True)
loop=GLib.MainLoop();requests=[];messages=[];results=[];failure=[];phase=0
context=WebKit.WebContext.new()
files={'katex.js':'katex-0.17.0.min.js','mermaid.js':'mermaid-11.16.0.min.js','turndown.js':'turndown-7.2.0.js','tables.js':'visual-tables.js','editor.js':'visual-editor.js'}
def png(width):
    def chunk(kind,payload):return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+b'\xff\0\0\xff'*width))+chunk(b'IEND',b'')

def serve(request,*_):
    uri=request.get_uri();requests.append(uri);name=uri.rsplit('/',1)[-1]
    if name in ('pixel.png','pixel-new.png'):data=png(1 if name=='pixel.png' else 2);mime='image/png'
    elif name in files:data=(root/files[name]).read_bytes();mime='text/javascript'
    else:
        request.finish_error(GLib.Error('unlisted local resource'));return
    request.finish(Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(data)),len(data),mime)
context.register_uri_scheme('fastra-preview',serve,None)
security=context.get_security_manager();security.register_uri_scheme_as_secure('fastra-preview');security.register_uri_scheme_as_local('fastra-preview')
manager=WebKit.UserContentManager()
def message(_,value):
    try:messages.append(json.loads(value.to_string()))
    except Exception:messages.append(value.to_string())
manager.register_script_message_handler('visualMarkdown',None);manager.connect('script-message-received::visualMarkdown',message)
for name in ['markdownCopy','markdownCodeCopy']:
    manager.register_script_message_handler(name,None)
view=WebKit.WebView(web_context=context,user_content_manager=manager,network_session=WebKit.NetworkSession.new_ephemeral());win=Gtk.Window(default_width=800,default_height=600);win.set_child(view);win.present()
original='Original ä 😀\n\n';saved=original
reopen='--reopen' in sys.argv
if reopen:
    saved=(out/'saved.md').read_text();phase=1
scripts=''.join(f'<script src="fastra-preview://local/{x}"></script>' for x in files)
def document(text):
    import html
    return '<!doctype html><html data-fastra-enhanced="true"><head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src fastra-preview:; img-src fastra-preview:; style-src \'unsafe-inline\'; font-src fastra-preview:"></head><body><div id="formula"></div><pre class="mermaid">graph TD; A-->B;</pre><img id="pixel" src="fastra-preview://local/pixel.png"><main id="fastra-visual"><p data-md-block="0">'+html.escape(text.strip())+'</p></main>'+scripts+'</body></html>'
def onload(_,event):
    global phase
    if event!=WebKit.LoadEvent.FINISHED:return
    config={'blocks':[{'id':0,'source':saved,'html':'','hidden':False}],'markdown':saved,'session':'probe','opaqueSources':{}}
    if phase==0:
        evaluate("(async()=>{katex.render('x^2',document.getElementById('formula'));mermaid.initialize({startOnLoad:false,securityLevel:'strict'});await mermaid.run({nodes:document.querySelectorAll('.mermaid')});await fastraVisual.start("+json.dumps(config)+");const image=document.getElementById('pixel');const first=image.naturalWidth;image.src='fastra-preview://local/pixel-new.png';await image.decode();let blocked=false;document.addEventListener('securitypolicyviolation',e=>{if(e.blockedURI.startsWith('https://'))blocked=true;});try{await fetch('https://example.invalid/probe');}catch{}await new Promise(r=>setTimeout(r,50));return JSON.stringify({imageBefore:first,imageAfter:image.naturalWidth,networkBlocked:blocked,formula:!!document.querySelector('.katex'),mermaid:!!document.querySelector('svg'),image:document.getElementById('pixel').naturalWidth,markdown:fastraVisual.markdown()});})()",preview_done)
    else:
        evaluate("(async()=>{await fastraVisual.start("+json.dumps(config)+");return fastraVisual.markdown();})()",reopened)
# evaluate_javascript gibt Promises als Objekt zurück. call_async_javascript_function
# wartet auf das tatsächliche Ergebnis; beide Wege bleiben native WebKit-Aufrufe.
def evaluate(script,done):
    def finished(v,result,*_):
        try:done(v.call_async_javascript_function_finish(result).to_string())
        except Exception as e:failure.append(str(e));loop.quit()
    view.call_async_javascript_function('return await ('+script+');',-1,None,None,None,None,finished,None)
def preview_done(value):
    result=json.loads(value);results.append(result)
    if not(result['formula'] and result['mermaid'] and result['imageBefore']==1 and result['imageAfter']==2 and result['networkBlocked'] and result['markdown']==original):failure.append('preview/source mismatch');loop.quit();return
    evaluate("(()=>{const p=document.querySelector('[data-md-block]');const r=document.createRange();r.selectNodeContents(p);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);document.execCommand('insertText',false,' edited');return fastraVisual.markdown();})()",edited)
def edited(value):
    global saved
    saved=value
    if 'edited' not in value:failure.append('edit lost');loop.quit();return
    (out/'saved.md').write_text(value)
    evaluate("(()=>{document.execCommand('undo');return fastraVisual.markdown();})()",undone)
def undone(value):
    global phase,saved
    if value!=original:failure.append('undo differs: '+repr(value));loop.quit();return
    results.append({'undo':True,'bridge_messages':len(messages)})
    saved=(out/'saved.md').read_text();phase=1
    view.load_html(document(saved),'fastra-preview://local/document')
def reopened(value):
    if value!=saved:failure.append('fresh document differs')
    results.append({'fresh_document':value==saved,'saved_utf8':list(saved.encode())})
    loop.quit()
view.connect('load-changed',onload)
GLib.timeout_add_seconds(35,lambda:(failure.append('deadline'),loop.quit(),False)[-1])
view.load_html(document(saved),'fastra-preview://local/document');loop.run();win.destroy()
print(json.dumps({'webkit':f'{WebKit.get_major_version()}.{WebKit.get_minor_version()}.{WebKit.get_micro_version()}','results':results,'requests':requests,'errors':failure,'fresh_process':reopen,'boundary':'small local bridge only; full malicious bridge corpus and production resource policy not accepted'},ensure_ascii=False,indent=2))
sys.exit(bool(failure))
