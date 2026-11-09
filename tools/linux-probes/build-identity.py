#!/usr/bin/env python3
"""Quell- und Bundleidentität ohne lokale Rechner-, Zertifikats- oder Profilnamen."""
import argparse,hashlib,json,pathlib,plistlib,subprocess
parser=argparse.ArgumentParser();parser.add_argument('--repo',type=pathlib.Path,required=True);parser.add_argument('--app',type=pathlib.Path,required=True);parser.add_argument('--kind',choices=['fastra','pmt'],required=True);parser.add_argument('--source-base',required=True);args=parser.parse_args()
paths=['app/Sources','app/Patches','app/Package.swift','app/Package.resolved','app/Info.plist','app/build.sh','app/sign-bundle.sh'] if args.kind=='fastra' else ['Sources','App','Assets','Package.swift','Package.resolved','scripts/build_app.sh','scripts/sign_bundle.sh','scripts/build_icon.sh','scripts/build_app_intents.py']
files=[]
for name in paths:
    p=args.repo/name
    files.extend([p] if p.is_file() else [f for f in p.rglob('*') if f.is_file()])
records=[]
for p in sorted(set(files)):
    if '__pycache__' in p.parts or p.suffix=='.pyc':continue
    records.append((str(p.relative_to(args.repo)),hashlib.sha256(p.read_bytes()).hexdigest()))
manifest=''.join(f'{digest}  {name}\n' for name,digest in records)
info=plistlib.loads((args.app/'Contents/Info.plist').read_bytes());binary=args.app/'Contents/MacOS'/info['CFBundleExecutable']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
identity={'product':args.kind,'sourceBase':args.source_base,'sourceInputCount':len(records),'sourceInputsSHA256':hashlib.sha256(manifest.encode()).hexdigest(),'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'executableSHA256':sha(binary),'architectures':subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip().split()}
cli=args.app/'Contents/Resources/poormans-text'
if cli.is_file():identity['embeddedCLISHA256']=sha(cli)
for key,command in [('signature',['codesign','--verify','--deep','--strict',str(args.app)]),('ticket',['xcrun','stapler','validate',str(args.app)]),('gatekeeper',['spctl','--assess','--type','execute',str(args.app)])]:
    identity[key]=subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
print(json.dumps(identity,indent=2))
