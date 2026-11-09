#!/usr/bin/env python3
import hashlib,json,pathlib,re,sys,urllib.parse
root=pathlib.Path(sys.argv[1]);expected=json.loads((root/'source-hashes.json').read_text());png=(root/'asset.sha256').read_text().strip()
def tree(folder):return {str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.rglob('*') if p.is_file()}
records=[]
for source,digest in expected.items():
    assert hashlib.sha256((root/source).read_bytes()).hexdigest()==digest,'changed source'
    stem=pathlib.Path(source).stem
    imported=root/(stem+'-2');gui=root/'pmt-output'/(stem+'-markdown')
    # Beide realen Apps müssen denselben vollständigen Baum liefern.
    left,right=tree(imported),tree(gui)
    assert left==right,(stem,left,right)
    md=list(imported.rglob('*.md'));assert len(md)==3
    content='\n'.join(p.read_text() for p in md)
    for marker in (['Message 1','Message 2'] if stem=='mail' else ['Note 1','Note 2']):assert marker in content
    assert png in left.values(),'original PNG bytes missing'
    checked=0
    for p in md:
        for raw in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)',p.read_text()):
            if urllib.parse.urlsplit(raw).scheme:continue
            path=urllib.parse.unquote(raw.split('#',1)[0])
            assert (p.parent/path).is_file(),(p,raw)
            checked+=1
    assert (root/stem/'index.md').read_text()=='Unverändert\n','collision overwritten'
    assert not list(root.glob('.fastra-markdown-*'))
    records.append({'source':source,'files':len(left),'markdown':len(md),'links':checked,'tree':left})
print(json.dumps({'passed':True,'collections':records},ensure_ascii=False,indent=2))
