# Synthetischer Test: tatsächliche Mountwechsel müssen vor Fremdcode-Laden scheitern.
import os,pathlib,tempfile,json,subprocess,hashlib,shutil
root=pathlib.Path(tempfile.mkdtemp(prefix='runtime-swaps-',dir='/test'))
def proof(path):
 s=path.stat();return dict(device=s.st_dev,inode=s.st_ino,mode=s.st_mode,bytes=s.st_size,ctime=s.st_ctime_ns//10**9,ctime_ns=s.st_ctime_ns%10**9)
def run_case(name,link):
 case=root/(name+('-symlink' if link else '-replacement'));case.mkdir();runtime=case/'runtime';runtime.mkdir()
 (runtime/'tool4d').write_text('#!/bin/sh\necho UNSAFE_RUNTIME_EXECUTED\n');(runtime/'tool4d').chmod(0o755)
 for d in ['Resources','lib']:(runtime/d).mkdir()
 held=[os.open(runtime/n,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK) for n in ['tool4d','Resources','lib']]
 expected=dict(executable=proof(runtime/'tool4d'),resources=proof(runtime/'Resources'),lib=proof(runtime/'lib'))
 (runtime/name).rename(runtime/(name+'.held'))
 foreign=case/'foreign-private'
 if name=='tool4d':foreign.write_text('unsafe executable')
 else:foreign.mkdir();(foreign/'HOME_SECRET').write_text('MUST_NOT_BE_READ')
 if link:(runtime/name).symlink_to(foreign)
 elif name=='tool4d':(runtime/name).write_text('replacement')
 else:(runtime/name).mkdir()
 workspace=case/'workspace';workspace.mkdir();r=workspace.stat()
 request=dict(runtime=expected,root_identity=[r.st_dev,r.st_ino],source_identity=[0,0],source_bytes=0,source_hash=list(hashlib.sha256(b'').digest()),token='binding-test',parent_net=os.readlink('/proc/self/ns/net'),source='',relative='Project/Sources/Methods/Probe.4dm',operation='diagnostics',cursor={'line':0,'character':0})
 args=['/usr/bin/bwrap','--unshare-all','--die-with-parent','--new-session','--cap-drop','ALL','--clearenv']
 for p in ['/usr/lib','/usr/lib64','/lib','/lib64','/etc/ld.so.cache','/usr/share/zoneinfo']:
  if os.path.exists(p):args+=['--ro-bind',p,p]
 for p,d in [('/app/libexec/fastra-linux','/app/libexec/fastra-linux'),('/app/lib','/app/lib'),(str(runtime/'tool4d'),'/runtime/tool4d'),(str(runtime/'Resources'),'/runtime/Resources'),(str(runtime/'lib'),'/runtime/lib'),(str(workspace),'/workspace')]:args+=['--ro-bind',p,d]
 args+=['--proc','/proc','--dev','/dev','--tmpfs','/tmp','--remount-ro','/tmp','--setenv','LD_LIBRARY_PATH','/app/lib','--setenv','HOME','/nonexistent','--','/app/libexec/fastra-linux','--fastra-4d-worker']
 result=subprocess.run(args,input=json.dumps(request).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8)
 assert result.returncode==0,(name,result.returncode,result.stderr)
 data=json.loads(result.stdout);err=data['result']['Err'];assert err['kind']=='stale' and 'Mounted runtime binding changed: '+name in err['detail'],(name,data)
 assert b'UNSAFE_RUNTIME_EXECUTED' not in result.stdout+result.stderr
 print(name,'symlink' if link else 'replacement','PASS',err['detail'],flush=True)
 for fd in held:os.close(fd)
for name in ['tool4d','Resources','lib']:
 for link in [True,False]:run_case(name,link)
print('ALL SIX ACTUAL BWRAP MOUNT SWAPS REJECTED BEFORE TOOL FORK/LOAD',flush=True)
shutil.rmtree(root)
