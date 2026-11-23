import Darwin
import Foundation

/// Dieselbe macOS-Policy wie beim zentralen Commit: nur fehlende Unterstützung
/// erlaubt fsync statt Fullsync. Auch Fullsync ist keine Zusage gegen Hardwarefehler.
enum FileDurability {
    static func synchronizeFile(_ descriptor: Int32,
                                fullSync: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) },
                                sync: (Int32) -> Int32 = Darwin.fsync) throws {
        if fullSync(descriptor) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL || code == ENOTTY else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard sync(descriptor) == 0 else { throw posixError() }
    }

    static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
