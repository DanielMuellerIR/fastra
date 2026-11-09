// Als main.swift zusammen mit den tatsächlichen Produktdateien übersetzen.
// Ausgabeordner als einziges Argument; keine Ersatz-Transformationslogik.
import Foundation
enum L10n {static func string(_ value:String)->String{value}}
precondition(CommandLine.arguments.count == 2)
let output=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
struct Vector:Codable {let source:String;let selection:[Int];let detokenized:String?;let tokenized:String?;let detokenizeRejectedForSplitGrapheme:Bool?}
var cases:[Vector]=[]
func record(_ source:String,_ selection:NSRange=NSRange(location:0,length:0)) {
 let original=source as NSString
 let unsafe=FourDTokenizer.tokenize(source).contains {token in
  guard token.kind == .command || token.kind == .constant else{return false}
  let value=original.substring(with:token.range)
  guard let colon=value.firstIndex(of:":"),FourDTokenTransform.isTokenSuffix(String(value[colon...])) else{return false}
  return Range(token.range,in:source) == nil
 }
 cases.append(Vector(source:source,selection:[selection.location,selection.length],detokenized:FourDTokenTransform.detokenizeOperation(in:source,selection:selection)?.newText,tokenized:FourDTokenTransform.tokenizeCommandsOperation(in:source,selection:selection)?.newText,detokenizeRejectedForSplitGrapheme:unsafe ? true:nil))
}
let examples=["", "ALERT:C41(\"Hello\")\r\nRECEIVE PACKET:C104($vt;Into variable:K79:31)","// ALERT:C41\n$t:=\"ALERT:C41\"","ALERT(\"Hi\")\nOPEN URL(\"https://example.org\")","$o.Date:=\"x\"\n$o.Time()\n$o.ALERT()\n$o.FutureCommand()","var $d : Date\r\n#DECLARE($t : Time)\rvar $other : ALERT\nDate(\"2026-10-02\")","[Table]ALERT\n[Table:C1]Date\n[Date] Time()","Future Tail:C9999+Unknown:K99:1+Foo:K9+Foo:K:::1+Foo:C+Foo:X2", "obj. ALERT() obj. ALERT obj.\"x\" ALERT obj./*x*/ ALERT", "ALERṪ ALERT_ ALERTx éALERT ALERTé ALERT😀ALERT obj.😀ALERT", "Unknown:C١٢٣ Unknown:CⅢ Unknown:K١:٢ Foo:K1:2:3 Foo:C1x Foo:C1:C2", "\"open\nALERT:C41\r\nend\"\rALERT:C41", "Begin SQL\r\nSELECT Count(*) FROM [Table]\nALERT:C41\r\nEnd SQL", "// var $v : Date\rDate\n\"var\" : Time", "variety : Date\n#DECLAREX : Date\nvar $n : Time", "$ALERT date() <>ALERT Time()\nALERT  Time\nALERT\tTime"]
for sample in examples + ["😀\u{345}.5 ALERT", "var $x :\u{200B}Date", "ALERT:C41\u{307} Time", "ALERT:c41", "42.5 ALERT", "// ALERT:C41\u{2028}Date:C102\nTime", "#DECLARE($d : Date)\u{2029}Time", "😀\u{345}:C41"] {record(sample);let source="é😀 before\r\n"+sample+"\r\nAfter";record(source,NSRange(location:("é😀 before\r\n" as NSString).length,length:(sample as NSString).length))}
for name in FourDSymbols.commands {record(name+"()");record(name+":C9999")}
for name in FourDSymbols.constants {record(name+":K79:31");record(name)}
struct Catalog:Codable {let commands:[String];let constants:[String];let ids:[String:Int]}
let ids=FourDSymbols.commandDetails.compactMapValues(\.number)
struct Probe:Codable {let scalar:UInt32;let letter:Bool;let number:Bool;let whitespace:Bool;let decimal:Bool;let word:Bool}
let wordRegex=try! NSRegularExpression(pattern:#"^\w$"#)
let probes:[Probe]=(0...0xffff).compactMap {value in guard let scalar=Unicode.Scalar(value)else{return nil};let c=Character(scalar);return Probe(scalar:scalar.value,letter:c.isLetter,number:c.isNumber,whitespace:CharacterSet.whitespaces.contains(scalar),decimal:CharacterSet.decimalDigits.contains(scalar),word:wordRegex.firstMatch(in:String(scalar),range:NSRange(location:0,length:1)) != nil)}
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
try encoder.encode(cases).write(to:output.appendingPathComponent("four-d-transform-swift.json"))
try encoder.encode(Catalog(commands:FourDSymbols.commands,constants:FourDSymbols.constants,ids:ids)).write(to:output.appendingPathComponent("four-d-catalog-swift.json"))
try encoder.encode(probes).write(to:output.appendingPathComponent("four-d-character-swift.json"))
print("SWIFT_4D_TRANSFORMS_OK cases=\(cases.count) commands=\(FourDSymbols.commands.count) constants=\(FourDSymbols.constants.count) ids=\(ids.count) probes=\(probes.count)")
