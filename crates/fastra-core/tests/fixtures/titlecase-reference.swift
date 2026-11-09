// Echte Foundation-Ergebnisse; explizite Locales sind die Goldenwerte, localized dient nur der Diagnose.
import Foundation
import Glibc
let localeSetResult=setlocale(LC_ALL, "")
struct Case:Codable {let input:String;let localized:String;let explicit:[String:String]}
struct Result:Codable {let environment:[String:String];let locale:String;let ctype:String;let cases:[Case]}
let initial=["max mustermann","istanbul izmir IĞDIR ı i İ I","IJSELMEER ijsselmeer","o'NEILL DON'T l’amour rock’n’ROLL","123abc abc123def foo_bar foo-bar foo.bar", "ǳURO ßTRAẞE ﬃle ÆTHER", "σΟΣ ΣΙΓΜΑ ΟΔΥΣΣΕΥΣ", "i\u{307} I\u{307} j\u{301}", "hello\nWORLD\r\nnext\tWORD", "👨‍👩‍👧‍👦hello a\u{301}BC"]
let separators=[" ",".","..",",",":",";","!","?","/","\\","-","–","—","_","@","#","$","%","&","+","=","*","(",")","[","]","{","}","<",">","\"","'","’","‘","ʼ","＇","·","•","…","\t","\n","\r\n","\u{85}","\u{a0}","\u{2028}","\u{2029}","\u{200d}","\u{200c}","\u{0301}","😀"]
var inputs=initial
for s in separators { inputs.append("FOO"+s+"BAR");inputs.append("istanbul"+s+"İZMİR");inputs.append("o"+s+"NEILL");inputs.append("123"+s+"abc") }
inputs += ["ǰUNG ǲURO ǅUNG ǆUNG", "I\u{307} J\u{301} Į\u{301}", "ijsselmeer IJMUIDEN", "ΜΆΙΟΣ άι ΑΫΛΟΣ ΟΣ", "straße ß ﬃ ﬁ ﬄ", "a🇹🇷b 👩🏽‍💻WORLD", "a\u{0345}BC ᾳ Σ\u{0301}ΟΣ"]
let locales=["de_DE","en_US","tr_TR","C","en_US_POSIX","nl_NL","lt_LT","el_GR"]
let cases=inputs.map {value in Case(input:value,localized:value.localizedCapitalized,explicit:Dictionary(uniqueKeysWithValues:locales.map{($0,value.capitalized(with:Locale(identifier:$0)))}))}
let keys=["LANG","LC_ALL","LC_CTYPE","LC_MESSAGES","LANGUAGE"]
let env=Dictionary(uniqueKeysWithValues:keys.compactMap {key in ProcessInfo.processInfo.environment[key].map{(key,$0)}})
let result=Result(environment:env,locale:Locale.current.identifier,ctype:String(cString:setlocale(LC_CTYPE,nil)),cases:cases)
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
print(String(data:try encoder.encode(result),encoding:.utf8)!)
