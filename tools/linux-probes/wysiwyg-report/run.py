import gi,json,sys,time,pathlib,os
for name,version in [('Gtk','4.0'),('WebKit','6.0')]:gi.require_version(name,version)
from gi.repository import Gtk,WebKit,GLib
repo=pathlib.Path(sys.argv[1]);vendor=pathlib.Path(os.environ.get('FASTRA_WYSIWYG_VENDOR',str(repo/'app/Sources/Fastra/Resources/MarkdownVendor')))
scripts='\n'.join((vendor/name).read_text() for name in ['turndown-7.2.0.js','visual-tables.js','visual-editor.js'])
cases=(pathlib.Path(__file__).parent/'cases.js').read_text();names=sys.argv[2:] or ['plain-copy','spaces','return-delete','return-delete-nbsp','preserve-blocks','hidden-definitions','highlight-copy','foreign-metadata','nested-formatting','clipboard-policy','clipboard-selection','viewport']
bootstrap='window.__messages=[];window.webkit={messageHandlers:new Proxy({}, {get:(_,name)=>({postMessage:value=>{window.__messages.push({name,value});if(name==="markdownCopy")window.__copy=value;}})})};'
loop=GLib.MainLoop();window=Gtk.Window();window.set_default_size(800,650);view=WebKit.WebView();window.set_child(view);window.present();position=0;started=0;pending=False;failed=False;results=[]
def load():
 global started,pending
 started=time.monotonic();pending=False
 name=names[position]
 body=bootstrap+scripts+'\n'+cases+'\nrunReportCase('+json.dumps(name)+').then(v=>window.__result=v).catch(e=>window.__result={name:'+json.dumps(name)+',error:String(e),stack:e.stack});'
 body=body.replace('</script','<\\/script')
 html='<!doctype html><html data-fastra-enhanced="true"><meta charset="utf-8"><style>body{font:16px sans-serif}p{margin:16px 0}mark{background:rgb(255,238,154)}#fastra-visual{min-height:200px}</style><div id="fastra-visual"></div><script>'+body+'</script></html>'
 view.load_html(html,'file:///src/')
def result(view,res,expected):
 global pending,position,failed
 if expected!=position:return
 pending=False
 try:
  raw=view.evaluate_javascript_finish(res).to_string()
  if not raw or raw=='null':return
  value=json.loads(raw);results.append(value);print(json.dumps(value,ensure_ascii=False),flush=True)
  failed |= not value.get('pass',False);position+=1
  if position==len(names):loop.quit()
  else:GLib.idle_add(load)
 except Exception as error:print(str(error),file=sys.stderr)
def poll():
 global pending,failed
 if position>=len(names):return False
 if time.monotonic()-started>20:failed=True;print('Timeout '+names[position],file=sys.stderr);loop.quit();return False
 if not pending:
  pending=True;view.evaluate_javascript('JSON.stringify(window.__result || null)',-1,None,None,None,result,position)
 return True
load();GLib.timeout_add(50,poll);loop.run();window.destroy();sys.exit(1 if failed else 0)
