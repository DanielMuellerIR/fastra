#!/usr/bin/env python3
"""Bündelt nur Symbolfakten; keine Beschreibungen oder fremde Grammatik.

Die Präfixkontexte halten jede GtkSourceView-Transition unter dem Regex-Limit.
"""
from pathlib import Path
import re, html, json, argparse
parser=argparse.ArgumentParser()
parser.add_argument("--character-oracle",type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[3]
s=(root/'app/Sources/Fastra/FourDSymbols.swift').read_text()
def values(name):
 m=re.search(r'static let '+name+r': \[String\] = \[(.*?)\n    \]',s,re.S)
 return re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"',m[1])
commands=values('commands'); constants=values('constants')
keywords=['if','else','end if','case of','end case','for each','end for each','for','end for','while','end while','repeat','until','use','end use','begin sql','end sql','return','break','continue','function','class constructor','class extends','property','var','try','catch','end try','throw','true','false','null','this','super','exposed','local','server','shared','onHTTPGet','singleton','session']
def symbol_contexts():
 groups={}
 for style,vals in [('command',commands),('constant',constants),('keyword',keywords)]:
  for v in vals:
   key=''.join(v.lower().split())[:3]
   groups.setdefault(key,{}).setdefault(style,[]).append(v)
 by_first={}
 result=''
 for n,(key,styles) in enumerate(sorted(groups.items(),key=lambda kv:(-len(kv[0]),kv[0]))):
  id='symbols'+str(n);by_first.setdefault(key[0],[]).append(id)
  prefix=r'[ \t]*'.join(re.escape(c) for c in key)
  result+='<context id="'+id+'" end-parent="true" end-at-line-end="true"><start>(?i)(?='+html.escape(prefix,quote=False)+')</start><include>'
  all_symbols=[(style,v) for style,vals in styles.items() for v in vals]
  for style,v in sorted(all_symbols,key=lambda pair:-len(pair[1])):
   pattern=re.escape(v.lower()).replace(r'\ ',r'[ \t]+')
   result+='<context style-ref="'+style+'" end-parent="true"><match>(?i)'+html.escape(pattern,quote=False)+'(?![\\p{L}\\p{N}_])</match></context>'
  result+='<context end-parent="true"><match>[\\p{L}\\p{N}_]+|.</match></context></include></context>'
 refs=[]
 for n,(first,ids) in enumerate(sorted(by_first.items())):
  id='letter'+str(n);refs.append(id)
  result+='<context id="'+id+'" end-at-line-end="true"><start>(?i)(?&lt;![\\p{L}\\p{N}_])(?='+html.escape(re.escape(first),quote=False)+')</start><include>'+''.join('<context ref="'+sub+'"/>' for sub in ids)+'<context end-parent="true"><match>[\\p{L}\\p{N}_]+|.</match></context></include></context>'
 return result+'<context id="symbols"><include>'+''.join('<context ref="'+id+'"/>' for id in refs)+'</include></context>'
lang='''<?xml version="1.0" encoding="UTF-8"?>
<!-- Eigene GtkSourceView-Grammatik. Befehls-/Konstantennamen aus FourDSymbols.swift;
     Fakten aus 4D-Dokumentation, CC BY 4.0, siehe THIRD-PARTY-NOTICES.md. -->
<language id="fastra-4d" name="4D" version="2.0" _section="Source">
<metadata><property name="globs">*.4dm;*.4DM;*.4qs;*.4QS</property><property name="line-comment-start">//</property><property name="block-comment-start">/*</property><property name="block-comment-end">*/</property></metadata>
<styles><style id="comment" map-to="def:comment"/><style id="string" map-to="def:string"/><style id="keyword" map-to="def:keyword"/><style id="command" map-to="def:function"/><style id="constant" map-to="def:constant"/><style id="variable" map-to="def:identifier"/><style id="table" map-to="def:type"/><style id="number" map-to="def:number"/></styles>
<definitions>
<context id="comment" style-ref="comment" end-at-line-end="true"><start>//</start></context>
<context id="block" style-ref="comment"><start>/\\*</start><end>\\*/</end></context>
<context id="string" style-ref="string"><start>"</start><end>"</end><include><context id="escape"><match>\\\\.</match></context></include></context>
<context id="variable" style-ref="variable"><match>(?:\\$|&lt;&gt;)[\\p{L}\\p{N}_]+</match></context>
<context id="table" style-ref="table"><match>\\[[^\\]\\r\\n]+\\]</match></context>
<context id="number" style-ref="number"><match>\\b[0-9]+(?:\\.[0-9]+)?\\b</match></context>
<context id="token-command" style-ref="command"><match>:C[0-9]+\\b</match></context>
<context id="token-constant" style-ref="constant"><match>:K[0-9]+(?::[0-9]+)?\\b</match></context>
'''+symbol_contexts()+'''
<context id="fastra-4d"><include><context ref="comment"/><context ref="block"/><context ref="string"/><context ref="variable"/><context ref="table"/><context ref="symbols"/><context ref="token-command"/><context ref="token-constant"/><context ref="number"/></include></context>
</definitions></language>'''
lang=re.sub(r'<style id="([^"]+)"',lambda m:m[0]+' name="'+m[1].title()+'"',lang)
(root/'crates/fastra-linux/resources/language-specs/fastra-4d.lang').write_text(lang)
(root/'crates/fastra-linux/resources/four-d-symbols-test.json').write_text(json.dumps(commands+constants,ensure_ascii=False))
print(f'{len(commands)} commands, {len(constants)} constants')

# Gemeinsame Transformationsfakten: IDs stammen aus derselben generierten Swift-Tabelle.
m=re.search(r'static let commandDetailLines: \[String\] = \[(.*?)\n    \]',s,re.S)
ids={}
for literal in re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"',m[1]):
 parts=json.loads('"'+literal+'"').split('\t')
 if len(parts)==3 and parts[1].isdigit(): ids[parts[0].lower()]=parts[1]
core=root/'crates/fastra-core/src/four_d/catalog.tsv'
core.parent.mkdir(exist_ok=True)
records=['# Generated from FourDSymbols.swift; facts from 4D SAS / 4d/docs, CC BY 4.0.', '# https://github.com/4d/docs — https://creativecommons.org/licenses/by/4.0/']
for name in commands: records.append('C\t'+name.lower()+'\t'+ids.get(name.lower(),''))
for name in constants: records.append('K\t'+name.lower()+'\t')
# Die Transformationsschlüsselwörter folgen FourDTokenizer, ohne UI-Zusatzwörter.
tokenizer=(root/'app/Sources/Fastra/FourDTokenizer.swift').read_text()
section=re.search(r'static let keywords: \[String\] = \[(.*?)\n    \]',tokenizer,re.S)[1]
for name in re.findall(r'"([^"\\]*)"',section): records.append('W\t'+name+'\t')
core.write_text('\n'.join(line.rstrip('\t') for line in records)+'\n')
print(f'{len(ids)} command IDs for core transformations')

if args.character_oracle:
 ranges=[]
 for value in json.loads(args.character_oracle.read_text()):
  scalar=value['scalar']
  flags=int(value['letter']) | int(value['number'])<<1 | int(value['whitespace'])<<2 | int(value['decimal'])<<3
  if not flags: continue
  if ranges and ranges[-1][1]+1==scalar and ranges[-1][2]==flags: ranges[-1][1]=scalar
  else: ranges.append([scalar,scalar,flags])
 target=root/'crates/fastra-core/src/four_d/tokens/classes.rs'
 target.parent.mkdir(exist_ok=True)
 target.write_text('// Aus Swift 6.2.1 Character / Foundation für alle BMP-Skalare abgeleitete Fakten.\n'
  '// FourDTokenizer scannt UTF-16-Zellen; Surrogate bleiben deshalb keine Namenszeichen.\n'
  'pub(super) fn properties(c: char) -> u8 {\n'
  '    if c.is_ascii() { return if c.is_ascii_alphabetic() { 1 } else if c.is_ascii_digit() { 10 } else if matches!(c, \' \' | \'\\t\') { 4 } else { 0 }; }\n'
  '    let value = c as u32;\n'
  '    let i = RANGES.partition_point(|&(_, end, _)| end < value);\n'
  '    RANGES.get(i).filter(|&&(start, _, _)| start <= value).map_or(0, |&(_, _, flags)| flags)\n'
  '}\n#[rustfmt::skip]\nconst RANGES: &[(u32, u32, u8)] = &[\n'
  + ''.join(f'    (0x{a:X},0x{b:X},{flags}),\n' for a,b,flags in ranges)+'];\n')
 print(f'{len(ranges)} Swift BMP character ranges')
