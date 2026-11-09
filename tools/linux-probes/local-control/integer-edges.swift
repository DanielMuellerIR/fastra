import Foundation
struct Signed: Decodable { let value: Int64 }
struct Unsigned: Decodable { let value: UInt64 }
struct Small: Decodable { let value: UInt32 }
let values = ["9223372036854775807.0", "9223372036854775806.0", "9223372036854775805.0", "9223372036854775552.0", "9223372036854775296.0", "9223372036854775295.0", "9223372036854775294.0", "9223372036854774784.0", "9223372036854774783.0", "9223372036854774782.0", "-9223372036854775808.0", "-9223372036854775807.0", "-9223372036854775806.0", "-9223372036854775553.0", "-9223372036854775297.0", "-9223372036854775296.0", "-9223372036854775295.0", "-9223372036854774785.0", "-9223372036854774784.0", "-9223372036854774783.0", "18446744073709551615.0", "18446744073709551614.0", "18446744073709551613.0", "18446744073709551104.0", "18446744073709550592.0", "18446744073709550591.0", "18446744073709550590.0", "18446744073709549568.0", "18446744073709549567.0", "18446744073709549566.0", "1e19", "10e18", "9007199254740993.1"]
let rows: [[String: Any]] = values.map { raw in
 let data = Data(("{\"value\":" + raw + "}").utf8)
 let signed = try? JSONDecoder().decode(Signed.self, from: data)
 let unsigned = try? JSONDecoder().decode(Unsigned.self, from: data)
 let small = try? JSONDecoder().decode(Small.self, from: data)
 return ["raw": raw, "int64": signed.map { String($0.value) } as Any? ?? NSNull(), "uint64": unsigned.map { String($0.value) } as Any? ?? NSNull(), "uint32": small.map { String($0.value) } as Any? ?? NSNull()]
}
print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), encoding: .utf8)!)
