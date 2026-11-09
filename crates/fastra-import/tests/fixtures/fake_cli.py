import os, sys, json, hashlib, pathlib, signal, time, socket
if '--help' in sys.argv:
    print('  --progress Report progress on stderr')
    sys.exit(0)
if '--formats' in sys.argv:
    print(json.dumps({'ok':True,'version':'fixture','formats':[{'format':'mbox','extensions':['mbox'],'container':'file','containers':['file','package'],'requires':[],'available':True,'unavailableReason':None},{'format':'docx','extensions':['docx'],'container':'file','available':False,'unavailableReason':'missing required tool: pandoc'}]}))
    sys.exit(0)
assert sys.argv[-2] == '--'
source = pathlib.Path(sys.argv[-1])
mode = source.read_text()
out = pathlib.Path(sys.argv[sys.argv.index('--output')+1])
assert not out.exists()
if '--progress' in sys.argv:
    line=('Progress: '+source.name+': converting message 1/2\n').encode()
    for byte in line:
        os.write(2,bytes([byte])); time.sleep(.0001)
    os.write(2,b'Unknown diagnostic retained\n')
    time.sleep(float(os.environ.get('FASTRA_FAKE_PROGRESS_DELAY','0')))
if mode in ('timeout','cancel'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pid = os.fork()
    if pid: source.with_suffix('.pids').write_text(str(os.getpid())+' '+str(pid))
    while True: time.sleep(1)
if mode == 'toolerror':
    print(json.dumps({'ok':False,'version':'fixture','error':'missing required tool: fixture'}))
    sys.stderr.buffer.write(b'exact failure\xff\n')
    sys.exit(69)
if mode == 'hugejson':
    print('x'*10000)
    sys.exit(0)
if mode == 'brokenjson':
    print('{broken')
    sys.exit(0)
if mode == 'stagingreplace':
    staging=out.parent
    staging.rename(str(staging)+'.moved')
    staging.mkdir()
    (staging/'foreign-marker').write_text('MUST REMAIN')
foreign = source.parent/'foreign'
if mode == 'rootlink':
    out.symlink_to(foreign, target_is_directory=True)
else:
    out.mkdir()
    (out/'docs').mkdir()
    (out/'images').mkdir()
    (out/'index.md').write_text('[One](docs/one.md)\n[Two](docs/two.md)\n![Image](images/pixel.bin)\n')
    (out/'docs'/'one.md').write_text('# One\n![pixel](../images/pixel.bin)\n')
    (out/'docs'/'two.md').write_text('é😀\n')
    (out/'images'/'pixel.bin').write_bytes(bytes(range(256)))
    (out/'report.json').write_text('{"schemaVersion":1,"fixture":true}')
    if mode == 'assetlink': (out/'hidden').symlink_to(foreign/'valuable.txt')
    if mode == 'directorylink': (out/'hidden').symlink_to(foreign, target_is_directory=True)
    if mode == 'hardlink': os.link(foreign/'valuable.txt',out/'hidden')
    if mode == 'fifo': os.mkfifo(out/'hidden')
    if mode == 'socket':
        sock=socket.socket(socket.AF_UNIX); sock.bind(str(out/'hidden')); sock.close()
    if mode == 'nonutf8':
        fd=os.open(os.fsencode(out)+b'/bad\xff',os.O_CREAT|os.O_WRONLY,0o600);os.close(fd)
    if mode == 'deep':
        p=out
        for _ in range(8): p=p/'deep';p.mkdir()
    if mode == 'many':
        for i in range(100): (out/('x'+str(i))).write_text('x')
    if mode == 'large': (out/'large').write_bytes(b'x'*2000)
if mode == 'rootlink':
    answer={'ok':True,'markdownFile':str(out/'valuable.txt'),'outputDirectory':str(out)}
else:
    files=[]
    for p in out.rglob('*'):
        if p.is_file() and not p.is_symlink():
            data=p.read_bytes();files.append({'path':str(p.relative_to(out)),'sha256':hashlib.sha256(data).hexdigest(),'byteCount':len(data)})
    answer={'ok':True,'version':'fixture','input':str(source),'outputDirectory':str(out),'markdownFile':str(out/'index.md'),
      'assets':[], # Sammlung bleibt auch ohne die historische Assets-Redundanz vollständig.
      'warnings':['A visible warning'],
      'diagnostics':[{'code':'fixture.loss','kind':'contentLoss','message':'Preserve this loss','future':'retained'}],
      'sourceIdentity':{'name':source.name,'unavailableReason':'fixture identity is unknown'},
      'sourceMappings':[{'source':{'kind':'fixture'},'output':{'file':'docs/two.md','utf8Offset':2,'utf8Length':4}}],
      'outputFiles':files,'reportFile':str(out/'report.json'),
      'documents':[{'sourceIndex':1,'title':'One','markdownFile':str(out/'docs'/'one.md'),'assets':[str(out/'images'/'pixel.bin')],'metadata':{}},{'sourceIndex':2,'title':'Two','markdownFile':str(out/'docs'/'two.md'),'assets':[],'metadata':{}}],
      'futureField':{'must':'survive'}}
    if mode in ('identity-member', 'identity-unknown-member'):
        answer['sourceIdentity']['memberPath']='TXT.rtf' if mode=='identity-member' else '../foreign/valuable.txt'
        answer['sourceIdentity']['futureIdentityField']={'preserve':True}
    if mode == 'outside': answer['markdownFile']=str(foreign/'valuable.txt')
    if mode == 'outdir': answer['outputDirectory']=str(foreign)
    if mode == 'missing': answer['markdownFile']=str(out/'missing.md')
    if mode == 'hash': answer['outputFiles'][0]['sha256']='0'*64
    if mode == 'mapping': answer['sourceMappings'][0]['output']['utf8Offset']=3
    if mode == 'mappingoverflow': answer['sourceMappings'][0]['output']['utf8Length']=2**64-1
    if mode == 'duplicateindex': answer['documents'][1]['sourceIndex']=1
    if mode == 'missingdoc': answer['documents'][1]['markdownFile']=str(out/'missing.md')
    if mode == 'false': answer={'ok':False,'error':'controlled false'}
    if mode == 'minimal': answer={'ok':True,'markdownFile':str(out/'index.md')}
    if mode == 'null':
        for key in ('assets','warnings','documents','sourceMappings','outputFiles','diagnostics'): answer[key]=None
print(json.dumps(answer))
if mode == 'nonzero': sys.exit(70)
