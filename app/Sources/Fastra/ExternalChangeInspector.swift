// ExternalChangeInspector.swift
//
// Gekapselte Plattenprüfung für Dateien, die sich außerhalb von Fastra
// geändert haben. Der Inspector kennt weder Workspace noch Editor: Er liest
// bei Bedarf einen stabilen Inhalts-Snapshot im Hintergrund und liefert das
// Ergebnis auf dem Main-Thread an den besitzenden Workspace zurück.

import Darwin
import Foundation

/// Leichter Platten-Fingerabdruck für die Erkennung externer Änderungen.
/// Anders als ein Änderungsdatum allein erkennt er auch atomar ersetzte
/// Dateien mit beibehaltenem Datum sowie gleich große In-place-Schreibvorgänge.
/// Die eigentlichen Bytes werden erst im Hintergrund gelesen, wenn sich dieser
/// Fingerabdruck unterscheidet.
struct ExternalFileObservation: Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init?(url: URL) {
        guard let opened = try? FileSnapshot.openRegularFile(at: url) else { return nil }
        defer { Darwin.close(opened.descriptor) }
        let info = opened.stat
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        byteCount = Int64(info.st_size)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(info.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

/// Pure Entscheidungs-Logik der Extern-Änderungs-Erkennung (BBEdit
/// „Automatically refresh documents" / „Reload from Disk", Handbuch 16.0.1
/// Kap. 3 S. 59): Was passiert mit einem Tab, dessen Datei sich auf der
/// Platte geändert hat? Sauberer Tab → still neu laden (kein Datenverlust
/// möglich). Dirty Tab → Nutzer fragen (lokale Änderungen stehen gegen die
/// externen). Unbenannt/kein Vergleichsdatum/Datei weg → nichts tun.
enum ExternalChange {
    enum Action: Equatable {
        case none
        case reloadSilently
        case askUser
    }

    static func action(isDirty: Bool, knownDate: Date?, diskDate: Date?) -> Action {
        guard let known = knownDate, let disk = diskDate else { return .none }
        // Werkzeuge wie `cp -p`, Restore und Versionskontrollsysteme können
        // einen älteren Zeitstempel einspielen. Jede Abweichung ist deshalb
        // eine Änderung; der Workspace-Pfad prüft zusätzlich Identität,
        // Größe, ctime und bei Bedarf die echten Bytes.
        guard disk != known else { return .none }
        return isDirty ? .askUser : .reloadSilently
    }

    /// Aktuelles Änderungsdatum der Datei auf der Platte (`nil`, wenn die
    /// Datei nicht erreichbar ist — gelöscht, Volume weg, keine Rechte).
    static func diskModificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Liest den möglichen Fremdstand einer Datei, ohne Tab- oder Fensterzustand
/// zu besitzen. Pro Tab läuft höchstens eine Prüfung; ein wiederholter Check
/// kann deshalb keine zweite parallele Voll-Lektüre derselben Datei starten.
final class ExternalChangeInspector: @unchecked Sendable {
    struct Request: Sendable {
        let tabID: UUID
        let documentID: UUID
        let url: URL
        let shouldReadContent: Bool
    }

    struct Inspection: Sendable {
        let tabID: UUID
        let documentID: UUID
        let url: URL
        let observation: ExternalFileObservation?
        let stableSnapshot: FileSnapshot?
    }

    typealias SnapshotReader = @Sendable (URL) -> FileSnapshot?

    private let snapshotReader: SnapshotReader
    private let lock = NSLock()
    private var requestIDs: [UUID: UUID] = [:]

    init(snapshotReader: @escaping SnapshotReader = {
        try? FileSnapshot.read(from: $0).snapshot
    }) {
        self.snapshotReader = snapshotReader
    }

    func isInspecting(tabID: UUID) -> Bool {
        lock.withLock { requestIDs[tabID] != nil }
    }

    /// Startet die Prüfung nur, wenn für diesen Tab noch keine läuft.
    /// `completion` kommt stets auf dem Main-Actor zurück. Dort entscheidet
    /// der Workspace anhand seines aktuellen Dokumentzustands über Reload,
    /// Rückfrage oder das Verwerfen eines veralteten Ergebnisses.
    @discardableResult
    func inspect(
        _ request: Request,
        completion: @escaping @MainActor (Inspection) -> Void
    ) -> Bool {
        let requestID = UUID()
        let accepted = lock.withLock {
            guard requestIDs[request.tabID] == nil else { return false }
            requestIDs[request.tabID] = requestID
            return true
        }
        guard accepted else { return false }

        let snapshotReader = snapshotReader
        Task.detached(priority: .utility) { [weak self] in
            // Vorher/Nachher-Fingerabdruck ergänzt die bereits interne
            // Konsistenzprüfung von FileSnapshot um die kleine Lücke
            // zwischen dessen Rückgabe und unserer Beobachtung.
            let before = ExternalFileObservation(url: request.url)
            let snapshot = request.shouldReadContent
                ? snapshotReader(request.url)
                : nil
            let after = ExternalFileObservation(url: request.url)
            let inspection = Inspection(
                tabID: request.tabID,
                documentID: request.documentID,
                url: request.url,
                observation: after,
                stableSnapshot: before == after ? snapshot : nil
            )

            await MainActor.run { [weak self] in
                guard let self,
                      self.finish(requestID: requestID, for: request.tabID) else {
                    return
                }
                completion(inspection)
            }
        }
        return true
    }

    private func finish(requestID: UUID, for tabID: UUID) -> Bool {
        lock.withLock {
            guard requestIDs[tabID] == requestID else { return false }
            requestIDs.removeValue(forKey: tabID)
            return true
        }
    }
}
