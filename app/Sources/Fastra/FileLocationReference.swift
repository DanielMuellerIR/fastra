import Darwin
import Foundation

/// Flüchtige Bindung an ein Dateiobjekt, auch wenn dessen Name oder Elternordner
/// wechselt. Sie wird nicht gespeichert: Dateireferenzen gelten nur bis zum
/// Neustart beziehungsweise erneuten Einhängen des Datenträgers.
struct FileLocationReference: Equatable, Hashable, Sendable {
    private let reference: String
    let identity: FileIdentity
    private let birthSeconds: Int64
    private let birthNanoseconds: Int64

    init?(url: URL, expectedIdentity: FileIdentity? = nil) {
        // Eine scheinbare Inode genügt etwa auf FAT-/Netzwerk-Dateisystemen
        // nicht. Nur Volumes mit ausdrücklich bestätigten persistenten IDs
        // dürfen automatisch einen anderen Pfad liefern.
        guard (try? url.resourceValues(forKeys: [.volumeSupportsPersistentIDsKey]))?
            .volumeSupportsPersistentIDs == true else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR,
              info.st_ino != 0,
              info.st_birthtimespec.tv_sec != 0 || info.st_birthtimespec.tv_nsec != 0,
              // Mehrere Hardlinks besitzen dieselbe Identität, aber keinen eindeutigen neuen Namen.
              info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1,
              expectedIdentity == nil || FileIdentity(stat: info) == expectedIdentity,
              let created = CFURLCreateFileReferenceURL(kCFAllocatorDefault, url as CFURL, nil)?.takeRetainedValue(),
              CFURLIsFileReferenceURL(created) else { return nil }
        // NSURL.fileReferenceURL() liefert in Swift URL und verliert beim
        // Bridging sofort die Referenz. Deshalb ihre CF-Darstellung erhalten.
        reference = CFURLGetString(created) as String
        identity = FileIdentity(stat: info)
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        guard resolvedURL() != nil else { return nil }
    }

    init?(descriptor: Int32, fileStat: stat) {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return nil }
        self.init(url: URL(fileURLWithPath: String(cString: path)),
                  expectedIdentity: FileIdentity(stat: fileStat))
    }

    func resolvedURL() -> URL? {
        guard let resolved = NSURL(string: reference)?.filePathURL else { return nil }
        let url = resolved.canonicalFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0,
              FileIdentity(stat: info) == identity,
              info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1,
              Int64(info.st_birthtimespec.tv_sec) == birthSeconds,
              Int64(info.st_birthtimespec.tv_nsec) == birthNanoseconds else { return nil }
        // Löschen im Finder soll weiterhin den Schutz des letzten Inhalts
        // auslösen, keine unbemerkte Bindung an eine Datei im Papierkorb.
        if url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes") { return nil }
        return url
    }

    static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }
}
