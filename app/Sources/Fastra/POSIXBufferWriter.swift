import Foundation
import Darwin

enum POSIXBufferWriter {
    // Der Aufrufer behält FD, Synchronisierung und Veröffentlichung. Bei einem
    // Fehler kann bereits ein Präfix geschrieben sein; der Helfer rollt nicht zurück.
    static func writeAll(
        _ bytes: UnsafeRawBufferPointer,
        to descriptor: Int32,
        makeError: (Int32) -> any Error = {
            POSIXError(POSIXErrorCode(rawValue: $0) ?? .EIO)
        },
        write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) throws {
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw makeError(code)
            }
            // write setzt errno bei Nullfortschritt nicht: ein alter Wert darf
            // weder einen Retry noch einen sachfremden Fehler verursachen.
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
    }
}
