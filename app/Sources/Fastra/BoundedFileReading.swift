// BoundedFileReading.swift
//
// Gemeinsamer, absichtlich vorsichtiger Lesepfad für FREMDE Dateien: Die
// 4D-Makro-Discovery und die tool4d-Suche öffnen Dateien aus Projekt- und
// Programme-Ordnern, deren Inhalt und Typ Fastra nicht kontrolliert. Zwei
// Gefahren fängt dieser Pfad zentral ab:
//
// 1. Eine als Datei getarnte FIFO (benannte Pipe): Ein gewöhnliches,
//    blockierendes `open` wartet dort auf einen Schreiber — noch bevor
//    irgendeine Typ- oder Größenprüfung laufen kann. Der aufrufende Task
//    hinge dann dauerhaft fest.
// 2. Eine übergroße Datei: `Data(contentsOf:)` lüde sie vollständig in den
//    Speicher, bevor eine Grenze greifen könnte.
//
// Deshalb: nicht blockierend öffnen, per `fstat` ausschließlich reguläre
// Dateien zulassen und höchstens `maximumBytes` lesen.

import Foundation

enum BoundedFileReading {

    /// Eine erfolgreich geöffnete, bestätigte reguläre Datei.
    struct RegularFile {
        /// Der gelesene Inhalt; nur gefüllt, wenn `readData` angefordert war.
        let data: Data?
        /// Ergebnis von `fstat` über den geöffneten Deskriptor — Aufrufer
        /// bauen daraus z. B. einen Cache-Fingerabdruck (Gerät, Inode, Größe,
        /// Änderungszeit).
        let info: stat
        /// Der symlink-aufgelöste Pfad, der tatsächlich geöffnet wurde.
        let resolvedPath: String
    }

    /// Öffnet `url` nicht blockierend, akzeptiert ausschließlich eine
    /// reguläre Datei bis `maximumBytes` und liest sie auf Wunsch begrenzt.
    /// Jede Abweichung (FIFO, Gerät, Ordner, zu groß, unlesbar) liefert
    /// `nil` — „hier gibt es nichts Brauchbares", kein Fehler.
    static func openRegularFile(at url: URL, maximumBytes: Int,
                                readData: Bool) -> RegularFile? {
        guard maximumBytes >= 0, maximumBytes < Int.max else { return nil }
        // Symlinks bewusst VOR dem Öffnen auflösen und dann mit O_NOFOLLOW
        // öffnen: Ein regulärer Verweis auf eine Datei funktioniert damit
        // weiterhin, nur ein zwischen Auflösung und Öffnen untergeschobener
        // neuer Link wird abgewiesen.
        let resolved = url.resolvingSymlinksInPath()
        // O_NONBLOCK: siehe Dateikopf — eine FIFO darf schon das Öffnen nicht
        // festhalten. Auf das Lesen regulärer Dateien hat das Flag keine
        // Wirkung.
        let descriptor = Darwin.open(
            resolved.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Int64(maximumBytes) else { return nil }
        guard readData else {
            return RegularFile(data: nil, info: info, resolvedPath: resolved.path)
        }
        // In kleinen Blöcken bis höchstens Grenze + 1 lesen. `read(upToCount:)`
        // darf weniger als angefordert liefern; ein einzelner Read wäre daher
        // kein harter Beleg, dass hinter einem gültigen Präfix nichts mehr
        // folgt. Die Grenze bleibt so auch erhalten, wenn die Datei nach dem
        // ersten Größencheck noch wächst.
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard data.count <= maximumBytes else { return nil }
        return RegularFile(data: data, info: info, resolvedPath: resolved.path)
    }
}
