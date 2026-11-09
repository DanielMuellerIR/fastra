import Foundation
struct CaseVector: Codable { let locale: String; let input: String; let uppercase: Bool; let output: String }
let locales = ["en_US_POSIX", "de_DE", "tr_TR", "az_AZ", "lt_LT", "el_GR"]
let inputs = ["istanbul I İ ı i", "I\u{0307} i\u{0307}\u{0301} J\u{0301}", "ΟΣ ΟΣΑ ΟΣ. Σ Σ\u{0301}", "Straße ß ﬃ", "CAFÉ cafe\u{0301}", "😀 𐐀 𐐨 中文", "a\r\nb\rc\n", "I\u{0301} J\u{0300} Į\u{0301} i\u{0307}\u{0301}", "ά έ ή ί ό ύ ώ ΐ ΰ ΑΣ", ""]
var vectors: [CaseVector] = []
for id in locales {
 let locale = Locale(identifier: id)
 for input in inputs { for uppercase in [false, true] {
  vectors.append(CaseVector(locale:id,input:input,uppercase:uppercase,output:uppercase ? input.uppercased(with:locale) : input.lowercased(with:locale)))
 } }
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(vectors))
