#!/usr/bin/env python3
"""Führt die unveränderten Foundation-Provider aus; benötigt Swift auf dem Referenz-Mac."""
from pathlib import Path
import json, subprocess, tempfile
repo = Path(__file__).resolve().parents[4]
app = repo / 'app/Sources/Fastra'
cases = []
def add(op, source='', **kw):
    cases.append(dict(op=op,source=source,**kw))
for name in ['a.4dm','README.md','A.MARKDOWN','x.swift','no-extension','dir.with.dot/file','x.MD']:
    add('format',name=name)
for text in ['Meine Methode($x)','x:=(1)','🙂Grüße Methode($x)','Function zwei($x)','exposed local Function Grüße($x)','a  b(x)','a\tb','a_b 12x','e\u0301cho(foo)','𐐀name(test)','']:
    for offset in range(len(text.encode('utf-16-le'))//2+2):
        add('phrase',text,location=offset)
links=['[Doku](docs/anleitung.md "Titel")','![Bild](bilder/foto%23x.png)','<https://example.org/pfad>','https://example.com/x.,!?…','[leer]( )','[leer](\t)','[leer]( "title")','[x](https://example.org/a b)','🙂 [ä](../docs/ziel.md#part)','[x](#abschnitt)\r\n[ref][id]\n\n[id]: target.md','<mailto:a@example.org>','[nested](a(b)c)','[multiline\ntext](target.md)','plain text']
for text in links:
    for offset in range(len(text.encode('utf-16-le'))//2+1):
        add('link',text,location=offset)
for text in ['# Einleitung\n\n## Zweiter Abschnitt\n','# ÄÖ æß & e\u0301x 漢字🙂 42\n','# **bold** #\n','```md\n# fenced\n```\n','Title\n====\n','# one\r## two\r\n### three\n','# same\n# same\n','### Text\u2028# Last']:
    for anchor in ['einleitung','zweiter-abschnitt','äö-æß-e\u0301x-漢字-42','bold','fenced','title','one','two','three','same','last']:
        add('heading',text,anchor=anchor)
def resolve(fmt,text,marker=None,document=None,project=False):
    offset=len(text[:text.index(marker)].encode('utf-16-le'))//2 if marker else 0
    add('resolve',text,format=fmt,location=offset,document=document,project=project)
resolve('4d','Ziel Methode($p)','Methode','Project/Sources/Methods/Aufrufer.4dm')
resolve('4d','$k:=cs.Kunde.new()','Kunde',project=True)
resolve('4d','Function eins()\n return 1\n\nFunction zwei($x : Integer)\n return $x','zwei')
resolve('4d','exposed local Function Grüße()\n return 1','Grüße')
resolve('4d','Function same()\nFunction same()\nsame()','same()')
resolve('4d','Function get title()\nFunction set title($x)\ntitle()','title()')
resolve('4d','// Function hidden()\n/* Function hidden() */\nBegin SQL\nFunction hidden()\nEnd SQL\nhidden()','hidden()',project=True)
for word in ['ALERT("x")','If (True)','Get text($x)','True','GibtsNicht($x)','_private()','123test()','Class constructor()','shared Class constructor()']:
    resolve('4d',word,project=True)
resolve('4d','GibtsNicht($x)')
for name,call in [('Straße','STRASSE'),('Σ','ς'),('I','ı'),('İ','i'),('ﬃ','FFI')]:
    resolve('4d',f'Function {name}()\n return 1\n\n{call}()',call+'()')
resolve('4d','OtherClass()','OtherClass',document='Sources/Methods/Caller.4dm',project=True)
for target in ['docs/ziel.md#part','docs/fehlt.md','../docs/ziel.md','docs/space%23name.md','docs/malformed%ZZ.md','https://example.org','https://example.org/a b','mailto:a@example.org','#zweiter-abschnitt','#missing',' ','\t',' "title"','$ROOT/docs/ziel.md']:
    resolve('md','# First\n\n## Zweiter Abschnitt\n\n[Hin]('+target+')','Hin','start.md')
resolve('md','[x](docs/ziel.md)','x')
resolve('md','[x](#first)\n# First','x')

def body(text, marker):
    start=text.index(marker); opening=text.index('{',start); depth=0
    for end in range(opening,len(text)):
        if text[end]=='{':depth+=1
        elif text[end]=='}':
            depth-=1
            if depth==0:return text[start:end+1]
    raise ValueError(marker)
provider=(app/'GoToTarget.swift').read_text().split('// MARK: - Geste')[0]
provider=provider.replace('import AppKit','import Foundation').replace('import CodeEditTextView','').replace('import CodeEditSourceEditor','')
anchor=body((app/'HelpContent.swift').read_text(),'static func anchor(forHeading')
stubs='import Foundation\nenum L10n { static func string(_ s:String)->String{s}; static func format(_ s:String,_ args:CVarArg...)->String{String(format:s,arguments:args)} }\nenum HelpContent { '+anchor+' }\n'
main=r'''
import Foundation
let inputs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let root=URL(fileURLWithPath:CommandLine.arguments[2])
func normalized(_ path:String)->String{path.replacingOccurrences(of:root.path,with:"$ROOT")}
var output:[[String:Any]]=[]
for input in inputs {
 let source=(input["source"] as! String).replacingOccurrences(of:"$ROOT",with:root.path)
 let location=input["location"] as? Int ?? 0
 var expected:Any=NSNull()
 switch input["op"] as! String {
 case "format": if let provider=GoToTarget.provider(forFileName:input["name"] as! String){expected=provider==FourDGoToTarget.self ? "4d":"md"}
 case "phrase": if let range=GoToTarget.phraseRange(in:source,at:location){expected=[range.location,range.length]}
 case "link": expected=MarkdownGoToTarget.linkTarget(in:source,at:location) as Any? ?? NSNull()
 case "heading": if let range=MarkdownGoToTarget.headingRange(forAnchor:input["anchor"] as! String,in:source){expected=[range.location,range.length]}
 default:
  let document=(input["document"] as? String).map{root.appendingPathComponent($0)}
  let context=GoToTargetContext(text:source,location:location,documentURL:document,projectURL:(input["project"] as? Bool == true) ? root:nil)
  let action=(input["format"] as! String)=="4d" ? FourDGoToTarget.resolve(context):MarkdownGoToTarget.resolve(context)
  if let action {switch action {
   case .openFile(let url):expected=["file":normalized(url.path)]
   case .jumpToRange(let range):expected=["range":[range.location,range.length]]
   case .openURL(let url):expected=["url":url.absoluteString,"literal":MarkdownGoToTarget.linkTarget(in:source,at:location) ?? ""]
   case .searchProject(let text):expected=["search":text]
   case .notFound(let text):
    let issue=text.hasPrefix("Mehrere Funktionen") ? "multiple-functions" : text.hasPrefix("Kein Ziel") ? "missing-target" : text.hasPrefix("Keine Überschrift") ? "missing-heading" : text.hasPrefix("Relative Ziele") ? "relative-needs-file" : text.hasPrefix("Datei") ? "missing-file" : text.contains("keine gültige") ? "invalid-address":"limit"
    let quoted=text.range(of:"„").flatMap{start in text.range(of:"“",range:start.upperBound..<text.endIndex).map{String(text[start.upperBound..<$0.lowerBound])}}
    expected=["issue":issue,"message":normalized(text),"argument":quoted as Any? ?? NSNull()]
  }}
 }
 output.append(["input":input,"expected":expected])
}
let result=try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes])
FileHandle.standardOutput.write(result)
'''
with tempfile.TemporaryDirectory(prefix='fastra-target-reference-',dir='/var/tmp') as tmp:
    tmp=Path(tmp)
    for path in ['Project/Sources/Methods','Project/Sources/Classes','Sources/Classes','Sources/Methods','docs']:(tmp/'root'/path).mkdir(parents=True,exist_ok=True)
    for path in ['Project/Sources/Methods/Ziel Methode.4dm','Project/Sources/Classes/Kunde.4dm','Sources/Classes/OtherClass.4dm','docs/ziel.md','docs/space#name.md','docs/malformed%ZZ.md']:(tmp/'root'/path).write_text('Function fixture()\n')
    (tmp/'provider.swift').write_text(stubs+provider)
    (tmp/'main.swift').write_text(main)
    (tmp/'inputs.json').write_text(json.dumps(cases,ensure_ascii=False))
    subprocess.run(['swiftc',str(app/'FourDSymbols.swift'),str(app/'FourDTokenizer.swift'),str(app/'FourDDefinitions.swift'),str(tmp/'provider.swift'),str(tmp/'main.swift'),'-o',str(tmp/'reference')],check=True)
    result=subprocess.check_output([str(tmp/'reference'),str(tmp/'inputs.json'),str(tmp/'root')])
    Path(__file__).with_name('swift-go-to-target.json').write_bytes(result+b'\n')
    print(f'{len(cases)} actual Swift provider cases')
