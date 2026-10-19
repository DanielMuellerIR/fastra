import Darwin
import Foundation

/// Prüft Mountgrenzen vor Dateimetadaten. Ein Symlink darf die lokale
/// Verweisprüfung nicht unbemerkt auf ein Netzwerkvolume umleiten.
struct LocalMarkdownPath {
    struct Mount {
        let path: String
        let isLocal: Bool
    }
    private let mounts: [Mount]

    init(mounts: [Mount]? = nil) {
        if let mounts { self.mounts = mounts; return }
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&entries, MNT_NOWAIT)
        guard let entries else { self.mounts = []; return }
        // Mehrere Fenster prüfen parallel: Der reentrante Aufruf liefert
        // einen eigenen Puffer statt getmntinfos gemeinsamem Speicher.
        defer { free(entries) }
        guard count > 0 else { self.mounts = []; return }
        self.mounts = (0..<Int(count)).compactMap { index in
            let entry = entries[index]
            let name = withUnsafeBytes(of: entry.f_mntonname) { Array($0.prefix { $0 != 0 }) }
            let type = withUnsafeBytes(of: entry.f_fstypename) { Array($0.prefix { $0 != 0 }) }
            guard let path = String(bytes: name, encoding: .utf8) else { return nil }
            return Mount(path: path, isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0
                && String(bytes: type, encoding: .utf8) != "autofs")
        }
    }

    func isLocal(_ path: String) -> Bool {
        let bytes = Data(path.utf8)
        let match = mounts.filter {
            let prefix = $0.path == "/" ? "/" : $0.path + "/"
            return bytes == Data($0.path.utf8) || bytes.starts(with: Data(prefix.utf8))
        }.max { $0.path.utf8.count < $1.path.utf8.count }
        return match?.isLocal == true
    }

    func resolve(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var pending = Self.components(url.path)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                current = current.deletingLastPathComponent()
                guard isLocal(current.path) else { throw CocoaError(.fileReadUnsupportedScheme) }
                continue
            }
            let next = current.appendingPathComponent(component, isDirectory: false)
            guard isLocal(next.path) else { throw CocoaError(.fileReadUnsupportedScheme) }
            var info = stat()
            if lstat(next.path, &info) != 0 {
                guard errno == ENOENT || errno == ENOTDIR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                current = next
                continue
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 40 else { throw POSIXError(.ELOOP) }
                var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = readlink(next.path, &bytes, bytes.count)
                guard count >= 0, count < bytes.count,
                      let target = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw CocoaError(.fileReadInvalidFileName) }
                let destination = target.hasPrefix("/") ? URL(fileURLWithPath: target, isDirectory: false) : current.appendingPathComponent(target, isDirectory: false)
                // Foundation standardisiert /private/var zurück zu /var.
                // Hier wäre das eine künstliche Schleife. Elternsprünge
                // erst hinter den zuvor aufgelösten Symlinks behandeln.
                pending = Self.components(destination.path) + pending
                current = URL(fileURLWithPath: "/", isDirectory: true)
            } else { current = next }
        }
        guard isLocal(current.path) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return current
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
