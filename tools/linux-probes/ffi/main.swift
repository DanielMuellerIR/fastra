import Foundation
func check(_ ok: Bool, _ label: String) { precondition(ok, label); print("PASS \(label)") }
for input in [Data(), Data("Grüße e\u{301} 😀\r\n".utf8), Data(repeating: 65, count: 1024*1024)] {
    let result = input.withUnsafeBytes { fastra_probe_copy($0.bindMemory(to: UInt8.self).baseAddress, input.count, 0) }
    check(result.status == 0 && Data(bytes: result.data, count: result.length) == input, "owned UTF8 bytes \(input.count)")
    fastra_probe_free(result.data, result.length)
}
for (input, mode, status) in [(Data([255]), Int32(0), Int32(3)),(Data([65]),1,2),(Data([65]),2,4),(Data(repeating:65,count:1024*1024+1),0,1)] {
    let result = input.withUnsafeBytes { fastra_probe_copy($0.bindMemory(to: UInt8.self).baseAddress, input.count, mode) }
    check(result.status == status && result.data == nil, "error/cancel/panic \(status)")
}
