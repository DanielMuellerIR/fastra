import Foundation
import CodeEditLanguages
struct Fixture: Codable {let name:String;let language:String;let text:String}
let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let fixtures=try JSONDecoder().decode([Fixture].self,from:input)
var output:[[String:Any]]=[]
for fixture in fixtures {
 let language=(CodeLanguage.allLanguages+[CodeLanguage.default]).first{String(describing:$0.id)==fixture.language}
 let regions=fixture.language=="fourD" ? FourDFolding.regions(in:fixture.text) : SyntaxFolding.regions(in:fixture.text,language:language!)
 let ranges=regions.map { region -> [String:Any] in
  let range=Range(region.range,in:fixture.text)!
  let prefix=fixture.text[..<range.lowerBound],body=fixture.text[range]
  return ["bytes":[prefix.utf8.count,prefix.utf8.count+body.utf8.count],"characters":[prefix.unicodeScalars.count,prefix.unicodeScalars.count+body.unicodeScalars.count],"utf16":[region.range.location,region.range.upperBound],"depth":region.depth]
 }
 output.append(["name":fixture.name,"language":fixture.language,"text":fixture.text,"regions":ranges])
}
let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
