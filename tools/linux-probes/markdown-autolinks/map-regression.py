#!/usr/bin/env python3
"""Prüft tatsächliche native Maparbeit, Originalranges und späten Map-Abbruch."""
import argparse,hashlib,json,subprocess,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
repo=Path(__file__).resolve().parents[3];native=repo/'crates/fastra-linux/native';vendor=native/'cmark/vendor';binding=json.loads((args.archive.parent/'binding.json').read_text())
for key,file in [('manifest_sha256',native/'cmark/UPSTREAM.json'),('bridge_sha256',native/'markdown_autolinks.c'),('header_sha256',native/'markdown_autolinks.h')]:assert binding[key]==hashlib.sha256(file.read_bytes()).hexdigest(),key
assert binding['threading'] is True
with tempfile.TemporaryDirectory(prefix='fastra-map-regression-') as temp:
 binary=Path(temp)/'probe';command=['cc','-std=c11','-O2','-pthread','-DCMARK_THREADING=1']
 for include in [native,vendor/'src/include',vendor/'extensions/include']:command+=['-I',str(include)]
 subprocess.run(command+[str(Path(__file__).with_name('native-probe.c')),str(args.archive),'-o',str(binary)],check=True)
 rows=[]
 for n in [8000,16000,32000]:
  start=time.monotonic();result=subprocess.run([str(binary),'0'],input=('a&#64;example.com '*n).encode(),capture_output=True,timeout=3);row=json.loads(result.stdout);row.update(n=n,seconds=time.monotonic()-start);assert result.returncode==0 and not result.stderr and row['status']==0 and row['links']==n and row['valid']==1 and row['mail_map_steps']<=20*n,row;rows.append(row)
 result=subprocess.run([str(binary),'1000'],input=('a&#64;example.com '*32000).encode(),capture_output=True,timeout=3);row=json.loads(result.stdout);assert result.returncode==0 and not result.stderr and row['status']==1 and row['mail_map_steps']==1000 and row['links']==0,row;rows.append(dict(row,cancel=True))
 args.output.write_text(json.dumps({'binding':binding,'results':rows},indent=2)+'\n');print('PASS native map regression: linear segment work, original ranges, mid-map cancellation and owned-plan cleanup')
