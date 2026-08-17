// FileReadReviewFixTests.swift
//
// Regressionstests zum Nacht-Code-Review 2026-08-10. Alle drei Funde hatten
// dieselbe Wurzel: Geprüft wurde an einer Datei (Typ, Größe, Binärprobe),
// gelesen aber aus einer zweiten, weil derselbe PFAD ein zweites Mal geöffnet
// wurde. Zwischen beiden Öffnungen kann ein Symlink umgebogen oder die Datei
// atomar ersetzt werden.
//
// Fensterlos und ohne App-Abhängigkeit: FileLoader, ApplyEngine-Undo und die
// Vorschau-Bildquelle sind reine Datei-Logik. Alle Testdaten liegen in einem
// frischen Unterordner des Test-Tempverzeichnisses.

import Darwin
import Foundation
import Testing
@testable import Fastra

// MARK: - Hilfen

/// Legt ein frisches, leeres Testverzeichnis im Temp-Ordner an.
private func makeReviewFixDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-readfix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Biegt einen bestehenden Symlink ATOMAR auf ein neues Ziel um.
///
/// `rename(2)` tauscht nur den Verzeichniseintrag und folgt dem alten Link
/// nicht — genau der Ablauf, den die Review-Funde beschreiben. Ein Löschen
/// plus Neuanlegen hätte dagegen eine Lücke, in der der Pfad gar nicht
/// existiert, und würde die Tests mit unechten Fehlern verrauschen.
private func repointSymlink(_ link: URL, to target: URL) {
    let staging = link.deletingLastPathComponent()
        .appendingPathComponent("swap-\(UUID().uuidString)")
    guard (try? FileManager.default.createSymbolicLink(
        at: staging, withDestinationURL: target)) != nil else { return }
    if rename(staging.path, link.path) != 0 {
        try? FileManager.default.removeItem(at: staging)
    }
}

/// Erzeugt eine Datei, die die gewünschte Größe MELDET, ohne sie wirklich zu
/// schreiben. `truncate` legt ein Loch an: Die Datei liest sich als Nullbytes,
/// belegt aber kaum Platz. So lassen sich Größengrenzen jenseits von 32 MiB
/// prüfen, ohne hunderte Megabyte auf die Platte zu schreiben.
private func makeSparseFile(at url: URL, size: UInt64) throws {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: size)
}

/// Abbruchsignal für den Hintergrund-Thread, der Symlinks umbiegt.
private final class SwapStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

/// Nimmt das Ergebnis eines Aufrufs von einem fremden Thread entgegen.
private final class ThrownErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error??
    func store(_ error: Error?) { lock.lock(); value = .some(error); lock.unlock() }
    var thrown: Error? {
        lock.lock(); defer { lock.unlock() }
        return value ?? nil
    }
    var didFinish: Bool {
        lock.lock(); defer { lock.unlock() }
        return value != nil
    }
}

// MARK: - B1: FileLoader liest aus derselben Datei, die er geprüft hat

@Test("FileLoader: Größe, Snapshot und Inhalt stammen aus derselben Datei")
func fileReadFix_loaderSnapshotMatchesContent() throws {
    // Deterministische Grundzusage: Über einen Symlink geladen, muss alles —
    // gemeldete Größe, Bytezahl des Snapshots und der dekodierte Inhalt — zum
    // ZIEL des Links gehören, nicht zum Link-Eintrag und nicht zu einer
    // zweiten, später geöffneten Datei.
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("ziel.txt")
    let text = "Inhalt der Zieldatei\n"
    try text.write(to: target, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("verweis.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let loaded = try FileLoader.load(url: link)

    #expect(loaded.content == text)
    #expect(loaded.fileSize == UInt64(text.utf8.count))
    let snapshot = try #require(loaded.diskSnapshot)
    #expect(snapshot.byteCount == text.utf8.count)
    #expect(snapshot.sha256 == FileSnapshot.sha256Hex(Data(text.utf8)))
    // Die Identität ist die des Ziels — ein Snapshot des Link-Eintrags würde
    // beim Speichern gegen die falsche Inode vergleichen.
    #expect(snapshot.identity == FileIdentity(url: target))
}

@Test("FileLoader: umgebogener Symlink kann die Editiergrenze nicht umgehen")
func fileReadFix_loaderSymlinkSwapCannotBypassSizeLimit() throws {
    // Der eigentliche Fund. Früher wurden Typ, Größe und Binärprobe an einem
    // Deskriptor geprüft, der Voll-Read öffnete den Pfad danach ERNEUT. Zeigte
    // der Link inzwischen auf eine große Datei, meldete `LoadedFile` die
    // winzige Größe der ersten Datei und trug trotzdem den vollständigen
    // Inhalt der zweiten — die Grenze für editierbare Dateien war umgangen.
    //
    // Ehrlich zur Aussagekraft: Der Test biegt den Link nebenläufig um und ist
    // damit auf Zufall angewiesen, um den alten Fehler zu TREFFEN. Er kann
    // aber nie falsch rot werden: Geprüft werden nur Invarianten, die für
    // jedes einzelne Ergebnis gelten müssen — egal welche der beiden Dateien
    // der Ladevorgang erwischt hat.
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let threshold: UInt64 = 64 * 1024

    let small = directory.appendingPathComponent("klein.txt")
    try "klein".write(to: small, atomically: true, encoding: .utf8)
    let large = directory.appendingPathComponent("gross.txt")
    // Bewusst nullbytefrei und echt geschrieben: Nur so hätte der alte Pfad
    // daraus einen editierbaren Text-String gemacht statt einer Hex-Ansicht.
    try Data(repeating: 0x41, count: 256 * 1024).write(to: large)
    let link = directory.appendingPathComponent("verweis.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: small)

    let stop = SwapStopFlag()
    let swapperFinished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var pointToLarge = true
        while !stop.isStopped {
            repointSymlink(link, to: pointToLarge ? large : small)
            pointToLarge.toggle()
        }
        swapperFinished.signal()
    }
    defer {
        stop.stop()
        _ = swapperFinished.wait(timeout: .now() + 10)
    }

    for _ in 0..<400 {
        // Fehler sind hier erlaubt: Der Link wird gerade ausgetauscht.
        guard let loaded = try? FileLoader.load(url: link,
                                                largeFileThreshold: threshold) else { continue }
        switch loaded.displayMode {
        case .text:
            #expect(loaded.fileSize <= threshold)
            // Der dekodierte Inhalt muss byteweise zu der Größe passen, an der
            // die Entscheidung „editierbar" getroffen wurde. Beide Testdateien
            // sind BOM-frei und reines ASCII.
            #expect(loaded.content.utf8.count == Int(loaded.fileSize))
            #expect(loaded.diskSnapshot?.byteCount == Int(loaded.fileSize))
        case .chunkedText:
            #expect(loaded.fileSize > threshold)
            #expect(loaded.content.isEmpty)
        case .hex:
            #expect(loaded.content.isEmpty)
        }
    }
}

@Test("FileLoader: Datei über der Grenze bleibt auch mit Encoding-Wahl abschnittsweise")
func fileReadFix_loaderKeepsThresholdForForcedEncoding() throws {
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("mittel.txt")
    try Data(repeating: 0x42, count: 4096).write(to: file)

    for forced in [nil, String.Encoding.utf8] {
        let loaded = try FileLoader.load(url: file, forcedEncoding: forced,
                                         largeFileThreshold: 1024)
        #expect(loaded.displayMode == .chunkedText)
        #expect(loaded.content.isEmpty)
        #expect(loaded.fileSize == 4096)
        #expect(loaded.diskSnapshot == nil)
    }
}

// MARK: - B2: Undo liest Backups gebremst

/// Baut eine echte Apply-Session in einem eigenen Temp-Ordner und liefert
/// Session, Zieldatei und den Pfad der Backup-Datei.
private func makeUndoFixture(in directory: URL) throws
    -> (session: ApplySession, target: URL, backup: URL) {
    let target = directory.appendingPathComponent("text.txt")
    try "foo bar\n".write(to: target, atomically: true, encoding: .utf8)
    let backupRoot = directory.appendingPathComponent("undo", isDirectory: true)
    try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    let plan = ApplyEngine.plan(files: [target],
                                options: SearchOptions(find: "foo", replace: "FOO",
                                                       isRegex: false, caseSensitive: true))
    let session = try ApplyEngine.apply(plan: plan, backupRoot: backupRoot,
                                        cleanupOlderThan: nil)
    let entry = try #require(session.entries.first)
    let backup = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
    return (session, target, backup)
}

@Test("Undo: übergroßes Backup wird abgewiesen, statt in den Speicher zu laufen")
func fileReadFix_undoRejectsOversizedBackup() throws {
    // Früher las Undo jedes Backup mit unbeschränktem `Data(contentsOf:)` —
    // und zwar VOR der Hashprüfung. Ein ausgetauschtes Riesen-Backup war
    // damit längst vollständig im Speicher, bevor der Hash es verwarf. Am
    // Fehlertyp lässt sich das genau unterscheiden: Der alte Pfad las die
    // ganze Datei und meldete danach „Backup-Hash stimmt nicht", der neue
    // weist sie schon beim Öffnen wegen ihrer Größe ab.
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try makeUndoFixture(in: directory)
    let applied = try Data(contentsOf: fixture.target)

    try FileManager.default.removeItem(at: fixture.backup)
    try makeSparseFile(at: fixture.backup,
                       size: FileSnapshot.maximumReadBytes + 1024 * 1024)

    var thrown: Error?
    do { _ = try ApplyEngine.undo(fixture.session) } catch { thrown = error }

    let error = try #require(thrown)
    #expect((error as? CocoaError)?.code == CocoaError.Code.fileReadTooLarge)
    // Und nichts wurde zurückgeschrieben: Die Zieldatei trägt weiter den
    // angewendeten Stand.
    #expect(try Data(contentsOf: fixture.target) == applied)
}

@Test("Undo: FIFO als Backup blockiert den Lauf nicht", .timeLimit(.minutes(1)))
func fileReadFix_undoRejectsFIFOBackupWithoutBlocking() throws {
    // `Data(contentsOf:)` öffnet eine benannte Pipe ohne Schreiber und wartet
    // dort unbegrenzt — der Rückgängig-Lauf wäre nicht mehr abbrechbar. Der
    // Deskriptor-Pfad öffnet mit `O_NONBLOCK` und weist alles Nicht-Reguläre
    // sofort ab. Der Aufruf läuft deshalb auf einem eigenen Thread mit Frist:
    // Ein im Kernel steckender Systemaufruf ließe sich sonst nicht abbrechen
    // und würde die GANZE Suite aufhängen.
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try makeUndoFixture(in: directory)

    try FileManager.default.removeItem(at: fixture.backup)
    #expect(mkfifo(fixture.backup.path, 0o600) == 0, "FIFO konnte nicht angelegt werden")

    let outcome = ThrownErrorBox()
    let finished = DispatchSemaphore(value: 0)
    let session = fixture.session
    Thread.detachNewThread {
        do { _ = try ApplyEngine.undo(session); outcome.store(nil) }
        catch { outcome.store(error) }
        finished.signal()
    }
    guard finished.wait(timeout: .now() + 10) == .success else {
        Issue.record("undo() blockiert auf dem FIFO-Backup")
        return
    }
    #expect(outcome.didFinish)
    #expect(outcome.thrown != nil, "Ein FIFO ist kein gültiges Backup")
}

// MARK: - B3: Vorschaubilder werden aus dem geprüften Deskriptor gelesen

@Test("Vorschau: Bilddaten kommen über einen Symlink vollständig an")
func fileReadFix_previewImageFollowsSymlink() throws {
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appendingPathComponent("original.png")
    let contents = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    try contents.write(to: image)
    let link = directory.appendingPathComponent("verweis.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)

    #expect(try MarkdownPreviewAssets.readImageData(link) == contents)
}

@Test("Vorschau: zu großes Bild wird abgewiesen")
func fileReadFix_previewImageRejectsOversizedFile() throws {
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appendingPathComponent("riesig.png")
    try makeSparseFile(at: image, size: UInt64(MarkdownPreviewAssets.maximumImageBytes) + 1)

    var thrown: Error?
    do { _ = try MarkdownPreviewAssets.readImageData(image) } catch { thrown = error }
    let error = try #require(thrown)
    #expect((error as? CocoaError)?.code == CocoaError.Code.fileReadTooLarge)
}

@Test("Vorschau: umgebogener Symlink liefert nie mehr als die erlaubten Bytes")
func fileReadFix_previewImageSwapCannotExceedLimit() throws {
    // Derselbe Fund wie bei FileLoader, nur in der Bildquelle der Vorschau:
    // Typ und Größe wurden am Pfad geprüft, `Data(contentsOf:)` öffnete ihn
    // danach erneut. Auch hier prüft der Test nur Invarianten und kann deshalb
    // nicht falsch rot werden.
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let small = directory.appendingPathComponent("klein.png")
    let contents = Data([0x89, 0x50, 0x4E, 0x47])
    try contents.write(to: small)
    let large = directory.appendingPathComponent("gross.png")
    try makeSparseFile(at: large,
                       size: UInt64(MarkdownPreviewAssets.maximumImageBytes) + 8 * 1024 * 1024)
    let link = directory.appendingPathComponent("verweis.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: small)

    let stop = SwapStopFlag()
    let swapperFinished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var pointToLarge = true
        while !stop.isStopped {
            repointSymlink(link, to: pointToLarge ? large : small)
            pointToLarge.toggle()
        }
        swapperFinished.signal()
    }
    defer {
        stop.stop()
        _ = swapperFinished.wait(timeout: .now() + 10)
    }

    for _ in 0..<400 {
        guard let data = try? MarkdownPreviewAssets.readImageData(link) else { continue }
        #expect(data.count <= MarkdownPreviewAssets.maximumImageBytes)
        // Gelesen werden darf nur eine der beiden echten Dateien; die große
        // fällt vorher durch die Größenprüfung.
        #expect(data == contents)
    }
}

// MARK: - Streamender Vergleichs-Snapshot (Nacht-Review-Fund 2026-08-17)

@Test("readSnapshotOnly liefert denselben Snapshot wie der Voll-Read")
func fileReadFix_streamingSnapshotMatchesFullRead() throws {
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("inhalt.txt")
    // Mehr als ein 4-MiB-Chunk, damit der Hasher wirklich mehrfach gefüttert
    // wird und nicht nur der Ein-Chunk-Sonderfall besteht.
    var content = Data()
    for index in 0..<5_000 {
        content.append(Data("Zeile \(index): Inhalt für den Hash\n".utf8))
    }
    content.append(Data(repeating: 0x41, count: 5 * 1024 * 1024))
    try content.write(to: url)

    let full = try FileSnapshot.read(from: url).snapshot
    let streamed = try FileSnapshot.readSnapshotOnly(from: url)

    #expect(streamed == full,
            "Hash, Bytezahl und Identität müssen unabhängig vom Leseweg gleich sein")
}

@Test("readSnapshotOnly weist übergroße Dateien ab, statt sie zu hashen")
func fileReadFix_streamingSnapshotRejectsOversizedFile() throws {
    let directory = try makeReviewFixDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("riesig.bin")
    try makeSparseFile(at: url, size: 8 * 1024 * 1024)

    var thrown: Error?
    do { _ = try FileSnapshot.readSnapshotOnly(from: url, byteLimit: 1024) }
    catch { thrown = error }

    guard case .some(FileSnapshotReadError.tooLarge) = thrown else {
        Issue.record("erwartet tooLarge, war \(String(describing: thrown))")
        return
    }
}
