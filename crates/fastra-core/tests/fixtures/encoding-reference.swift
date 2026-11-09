import Foundation

var output = [String: [Int?]]()
for (name, encoding) in [
    ("Windows1252", String.Encoding.windowsCP1252),
    ("Latin1", .isoLatin1),
    ("MacRoman", .macOSRoman),
] {
    // Einzelne undefinierte CP1252-Werte dürfen den übrigen Referenzsatz nicht verwerfen.
    output[name] = (0...255).map { value in
        String(data: Data([UInt8(value)]), encoding: encoding)?
            .unicodeScalars.first.map { Int($0.value) }
    }
}
let json = output.mapValues { values in values.map { $0 as Any? ?? NSNull() } }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
