import Foundation
struct Signed: Decodable { let value: Int64 }
struct Unsigned: Decodable { let value: UInt64 }
struct Small: Decodable { let value: UInt32 }
let values = ["0", "-0", "-0.0", "-0e0", "1", "1.0", "1e0", "1E+0", "10e-1", "100.00e-2", "0e999999", "0e-999999", "1.1", "1e-1", "1.00000000000000000000000000001", "true", "\"1\"", "4294967295", "4294967295.0", "4294967296", "4294967296.0", "9007199254740991", "9007199254740991.0", "9007199254740992.0", "9007199254740993", "9007199254740993.0", "9.007199254740993e15", "9223372036854775807", "9223372036854775807.0", "9.223372036854775807e18", "9223372036854775808", "9223372036854775808.0", "-9223372036854775808", "-9223372036854775808.0", "-9.223372036854775808e18", "-9223372036854775809", "-9223372036854775809.0", "18446744073709551615", "18446744073709551615.0", "1.8446744073709551615e19", "18446744073709551616", "18446744073709551616.0", "-1", "-1.0", "1e100000", "1e-100000", "1000000000000000000000000000000000000000e-37"]
let rows: [[String: Any]] = values.map { raw in
 let data = Data(("{\"value\":" + raw + "}").utf8)
 let signed = try? JSONDecoder().decode(Signed.self, from: data)
 let unsigned = try? JSONDecoder().decode(Unsigned.self, from: data)
 let small = try? JSONDecoder().decode(Small.self, from: data)
 return ["raw": raw, "int64": signed.map { String($0.value) } as Any? ?? NSNull(), "uint64": unsigned.map { String($0.value) } as Any? ?? NSNull(), "uint32": small.map { String($0.value) } as Any? ?? NSNull()]
}
print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), encoding: .utf8)!)
