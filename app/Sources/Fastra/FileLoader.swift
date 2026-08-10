// FileLoader.swift
//
// Reine, UI-unabhängige Lade-Logik: Encoding-Erkennung + Line-Ending-Erkennung.
// Diese Datei hat KEINE SwiftUI- oder AppKit-Abhängigkeit — sie lässt sich
// deshalb problemlos vom Hintergrund-Thread aufrufen, ohne die Main-Runloop
// zu blockieren.
//
// Entscheidung (v0.9): Das synchrone Lesen aus `Workspace.loadFile` wurde hier
// herausgezogen, damit `Workspace.loadFile` asynchron werden kann. Der eigentliche
// I/O (String(contentsOf:), Data(contentsOf:)) findet weiterhin synchron statt —
// aber jetzt auf einem Hintergrund-Thread via `Task.detached`.

import Darwin
import Foundation

/// Darstellungsart eines geöffneten Tabs. Text bleibt voll editierbar; große
/// Text- und Binärdateien werden abschnittsweise und read-only angezeigt, damit
/// Fastra niemals hunderte Megabyte ungefragt in einen Editor-String kopiert.
enum EditorDisplayMode: Equatable, Hashable {
    case text
    case chunkedText
    case hex
}

/// Lädt und dekodiert eine Datei von der Platte — OHNE UI-Interaktion.
///
/// Nutzung: Nur von einem Nicht-Main-Thread aufrufen (z.B. `Task.detached`).
/// Der Rückgabewert `LoadedFile` ist ein reiner Wert-Typ und thread-sicher.
enum FileLoader {

    // MARK: - Datentypen

    /// Ergebnis eines erfolgreichen Ladevorgangs.
    struct LoadedFile: Equatable {
        /// Dateiinhalt als Swift-String (bereits dekodiert).
        let content: String
        /// Erkanntes Encoding (z.B. `.utf8`, `.utf16LittleEndian`).
        let encoding: String.Encoding
        /// Ursprüngliche BOM-Bytes. Sie werden beim Speichern bytegenau
        /// wieder vorangestellt; eine BOM darf weder erfunden noch entfernt
        /// werden.
        let bom: Data
        /// Erkannte Zeilenende-Konvention der Datei.
        let lineEnding: LineEnding
        let displayMode: EditorDisplayMode
        let fileSize: UInt64
        /// Exakte Byte-/Identitätsbasis dieses Ladevorgangs. Nur editierbare,
        /// vollständig geladene Dateien besitzen einen Save-Snapshot.
        let diskSnapshot: FileSnapshot?
    }

    /// Fehler, den `load(url:)` werfen kann.
    enum LoadError: Error {
        /// Die Datei konnte weder mit automatischer Encoding-Erkennung
        /// noch als UTF-8 mit Lossy-Konvertierung gelesen werden. Gilt auch,
        /// wenn Typ oder Größe des Pfads gar nicht erst zu ermitteln waren.
        case unreadable
        /// Der Pfad ist keine reguläre Datei, sondern z. B. ein Verzeichnis,
        /// eine FIFO (benannte Pipe), ein Socket oder eine Gerätedatei.
        /// Solche Pfade werden bewusst gar nicht erst geöffnet.
        case notRegularFile
    }

    // MARK: - Kernfunktion

    /// Liest die Datei unter `url` synchron ein und gibt ein `LoadedFile` zurück.
    ///
    /// Ablauf:
    /// 1. `String(contentsOf:usedEncoding:)` — erkennt Encoding automatisch
    ///    (BOM, System-Heuristik). Klappt für die meisten Text-Encodings.
    /// 2. Fallback: `Data(contentsOf:)` + Lossy-UTF-8-Konvertierung —
    ///    fängt Dateien, die Apple's Heuristik nicht erkennt (z.B. Latin-1
    ///    ohne BOM, der als UTF-8 fehlschlägt).
    /// 3. Schlägt beides fehl (z.B. Binärdatei mit Null-Bytes, kein UTF-8):
    ///    `LoadError.unreadable` werfen.
    ///
    /// - Parameter url: Datei-URL; muss eine reguläre Datei sein.
    /// - Parameter forcedEncoding: Wenn gesetzt, wird die automatische
    ///   Erkennung übersprungen und die Datei MIT GENAU diesem Encoding
    ///   dekodiert („Neu öffnen mit Encoding", K6). Schlägt die Dekodierung
    ///   fehl (Bytes passen nicht), wird `LoadError.unreadable` geworfen —
    ///   bewusst KEIN Lossy-Fallback, sonst wäre die Encoding-Wahl wirkungslos.
    /// - Returns: `LoadedFile` mit Inhalt, Encoding und Line-Ending.
    /// - Throws: `LoadError.unreadable`, wenn keine Dekodierung gelang.
    static let largeFileThreshold: UInt64 = 32 * 1024 * 1024
    static let binaryProbeSize = 8 * 1024
    /// Obergrenze des zusätzlichen Binär-Scans für große BOM-lose Dateien.
    /// Der Scan hält immer nur diesen Abschnitt im Speicher und bricht beim
    /// ersten Nullbyte ab.
    static let binaryScanChunkSize = 256 * 1024

    static func load(url: URL, forcedEncoding: String.Encoding? = nil,
                     largeFileThreshold: UInt64 = largeFileThreshold) throws -> LoadedFile {
        // Typ und Größe am GEÖFFNETEN Deskriptor klären — nicht vorab am
        // Pfad. Beides ist eine Sicherheitsbedingung, keine Bequemlichkeit:
        // 1. Nicht reguläre Pfade (FIFO, Socket, Gerätedatei, Verzeichnis)
        //    dürfen nie gelesen werden. `openRegularFile` öffnet mit
        //    O_NONBLOCK — schon `open(2)` auf eine FIFO ohne Schreiber würde
        //    sonst unbegrenzt blockieren — und weist alles Nicht-Reguläre am
        //    Deskriptor ab. Weil Typ, Größe, Probe UND der spätere Voll-Read
        //    am SELBEN geöffneten Dateiobjekt hängen, kann ein Symlink
        //    zwischen Prüfung und Lesen nicht mehr auf ein anderes Ziel
        //    umgebogen werden (TOCTOU, Review 2026-08-02 und 2026-08-10).
        // 2. Ein Fehler beim Ermitteln der Attribute darf NICHT als Größe 0
        //    durchgehen. Sonst gälte eine riesige Datei als winzig, umginge
        //    die Abschnitts-/Hex-Grenze und landete komplett im Speicher.
        //    `fstat` liefert die echte Größe des Zielobjekts; ein toter Link
        //    scheitert schon beim Öffnen und wird `unreadable`.
        // Die Null-Byte-Probe ist die verbindliche Binär-Erkennung aus der
        // Roadmap. Nur einen kleinen Anfang lesen — auch eine 20-GB-Datei
        // wird dadurch praktisch sofort als Hex-View geöffnet.
        let opened: (descriptor: Int32, stat: stat)
        do {
            opened = try FileSnapshot.openRegularFile(at: url)
        } catch FileSnapshotReadError.notRegularFile {
            throw LoadError.notRegularFile
        } catch {
            throw LoadError.unreadable
        }
        // Der Deskriptor bleibt bis zum Ende dieses Ladevorgangs offen: Probe,
        // Nachscan und Voll-Read hängen dadurch alle am SELBEN Dateiobjekt.
        // Ein zweites `open` desselben Pfades — etwa über
        // `FileSnapshot.read(from:)` — könnte nach einem umgebogenen Symlink
        // oder einem atomaren Austausch eine völlig andere und viel größere
        // Datei liefern. Die oben geprüfte Größe gälte dann für eine Datei,
        // die gar nicht gelesen wird, und die 32-MiB-Grenze für editierbare
        // Dateien wäre umgangen (Review 2026-08-10).
        defer { close(opened.descriptor) }
        let fileSize = UInt64(max(0, opened.stat.st_size))
        let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        let probe = (try? handle.read(upToCount: binaryProbeSize)) ?? Data()
        let (probeBOM, probeBOMEncoding) = ApplyEngine.detectBOM(in: probe)

        if let enc = forcedEncoding {
            let bodyEncoding = explicitBodyEncoding(enc, bomEncoding: probeBOMEncoding)
            // Eine große Datei bleibt auch nach ausdrücklicher Encoding-Wahl
            // abschnittsweise und read-only. Sonst würde „Neu öffnen mit
            // Encoding“ die 32-MiB-Sicherheitsgrenze umgehen und den gesamten
            // Inhalt in einen editierbaren String laden.
            if fileSize > largeFileThreshold {
                return LoadedFile(content: "", encoding: bodyEncoding, bom: probeBOM,
                                  lineEnding: .lf, displayMode: .chunkedText,
                                  fileSize: fileSize, diskSnapshot: nil)
            }
            guard let read = try? readAll(descriptor: opened.descriptor,
                                          openedAs: opened.stat,
                                          byteLimit: largeFileThreshold) else {
                throw LoadError.unreadable
            }
            let data = read.data
            let (bom, bomEncoding) = ApplyEngine.detectBOM(in: data)
            let payload = Data(data.dropFirst(bom.count))
            let exactEncoding = explicitBodyEncoding(enc, bomEncoding: bomEncoding)
            guard let s = String(data: payload, encoding: exactEncoding) else {
                throw LoadError.unreadable
            }
            return LoadedFile(content: s, encoding: exactEncoding, bom: bom,
                              lineEnding: LineEnding.detect(in: s),
                              displayMode: .text, fileSize: fileSize,
                              diskSnapshot: read.snapshot)
        }

        // Ohne BOM sind UTF-16-Text und beliebige 16-Bit-Binärdaten nicht
        // belastbar unterscheidbar: Beide können dieselbe Nullbyte-Parität und
        // ausschließlich druckbare Codeunits besitzen. Automatische Erkennung
        // würde PCM-/UInt16-Dateien als editierbaren Text öffnen. Deshalb gilt
        // fail-closed: Nullbyte ohne BOM → Hex. Wer die Herkunft kennt, kann
        // UTF-16 LE/BE ausdrücklich über „Neu öffnen mit Encoding“ wählen.
        if probe.contains(0) && !bomEncodingAllowsNUL(probeBOMEncoding) {
            return LoadedFile(content: "", encoding: .utf8, bom: Data(), lineEnding: .lf,
                              displayMode: .hex, fileSize: fileSize, diskSnapshot: nil)
        }
        if fileSize > largeFileThreshold {
            // Die 8-KiB-Probe allein reicht nicht: Binärdaten können erst weit
            // hinter dem Anfang ein Nullbyte enthalten. Ohne BOM scannen wir
            // deshalb den Rest abschnittsweise. BOM-markiertes UTF-16 bleibt
            // erlaubt; dort sind Nullbytes erwartbarer Bestandteil des Texts.
            if !bomEncodingAllowsNUL(probeBOMEncoding),
               try containsNUL(handle: handle, startingAt: UInt64(probe.count)) {
                return LoadedFile(content: "", encoding: .utf8, bom: Data(),
                                  lineEnding: .lf, displayMode: .hex,
                                  fileSize: fileSize, diskSnapshot: nil)
            }
            return LoadedFile(content: "",
                              encoding: probeBOMEncoding ?? .utf8,
                              bom: probeBOM, lineEnding: .lf,
                              displayMode: .chunkedText, fileSize: fileSize,
                              diskSnapshot: nil)
        }

        guard let read = try? readAll(descriptor: opened.descriptor,
                                      openedAs: opened.stat,
                                      byteLimit: largeFileThreshold) else {
            throw LoadError.unreadable
        }
        let data = read.data
        let (bom, bomEncoding) = ApplyEngine.detectBOM(in: data)
        // Kleine Dateien liegen hier ohnehin vollständig vor. Daher erneut
        // über alle Bytes prüfen, damit ein Nullbyte hinter der Anfangsprobe
        // nicht als editierbarer UTF-8-String durchrutscht.
        if !bomEncodingAllowsNUL(bomEncoding) && data.contains(0) {
            return LoadedFile(content: "", encoding: .utf8, bom: Data(),
                              lineEnding: .lf, displayMode: .hex,
                              fileSize: fileSize, diskSnapshot: nil)
        }
        let payload = Data(data.dropFirst(bom.count))
        let detected: (String, String.Encoding)?
        if let bomEncoding, let value = String(data: payload, encoding: bomEncoding) {
            detected = (value, bomEncoding)
        } else if let value = String(data: payload, encoding: .utf8) {
            detected = (value, .utf8)
        } else {
            // Dieselbe dokumentierte CP1252/Latin-1-Heuristik wie Folder-
            // Suche und Apply, ausschließlich auf den stabil gelesenen Bytes.
            detected = ApplyEngine.decode(payload: payload, bomEncoding: nil)
        }
        guard let (raw, detectedEncoding) = detected else { throw LoadError.unreadable }

        // Zeilenenden erkennen: CRLF vor CR prüfen (CRLF enthält auch CR,
        // daher Reihenfolge wichtig — `LineEnding.detect` macht das korrekt).
        let ending = LineEnding.detect(in: raw)

        return LoadedFile(content: raw, encoding: detectedEncoding, bom: bom,
                          lineEnding: ending, displayMode: .text,
                          fileSize: fileSize,
                          diskSnapshot: read.snapshot)
    }

    /// Kodiert den Editorinhalt mit exakt derselben BOM-Entscheidung wie beim
    /// Laden. Der allgemeine Save-Pfad und die Git-Konfliktprüfung verwenden
    /// dieselbe Funktion, damit beide dieselben Bytes meinen.
    static func encodedData(content: String, encoding: String.Encoding,
                            bom: Data, lineEnding: LineEnding) -> Data? {
        let normalized = lineEnding.converting(content)
        let bodyEncoding = explicitBodyEncoding(encoding,
                                                bomEncoding: ApplyEngine.detectBOM(in: bom).1)
        guard var body = normalized.data(using: bodyEncoding,
                                         allowLossyConversion: false) else { return nil }
        // Generische Foundation-Encodings dürfen keine zweite BOM einschleusen.
        let (generatedBOM, _) = ApplyEngine.detectBOM(in: body)
        if !generatedBOM.isEmpty { body.removeFirst(generatedBOM.count) }
        var result = Data()
        result.append(bom)
        result.append(body)
        return result
    }

    private static func explicitBodyEncoding(_ encoding: String.Encoding,
                                             bomEncoding: String.Encoding?)
        -> String.Encoding {
        if encoding == .utf16 {
            return bomEncoding == .utf16BigEndian ? .utf16BigEndian : .utf16LittleEndian
        }
        if encoding == .utf32 {
            return bomEncoding == .utf32BigEndian ? .utf32BigEndian : .utf32LittleEndian
        }
        return encoding
    }

    /// Nur automatisch erkannte UTF-16-/UTF-32-BOMs erklären Nullbytes im Text.
    /// Eine UTF-8-BOM ist dagegen kein Freibrief für spätere Nullbytes.
    private static func bomEncodingAllowsNUL(_ encoding: String.Encoding?) -> Bool {
        encoding == .utf16LittleEndian || encoding == .utf16BigEndian
            || encoding == .utf32LittleEndian || encoding == .utf32BigEndian
    }

    /// Liest die Datei vollständig aus einem BEREITS geöffneten Deskriptor und
    /// baut daraus den Save-Snapshot.
    ///
    /// Warum nicht `FileSnapshot.read(from:)`? Das öffnet den Pfad erneut. Ein
    /// Symlink oder ein atomarer Austausch kann in genau diesem Moment auf eine
    /// andere Datei zeigen — die Entscheidung „klein genug zum Editieren" wäre
    /// dann an der einen, der Inhalt aus der anderen Datei gemessen.
    ///
    /// `byteLimit` ist hart und gilt zusätzlich WÄHREND des Lesens: Wächst die
    /// Datei nach dem Öffnen über die Grenze, bricht der Lauf ab, statt den
    /// Speicher zu füllen. Die anschließende String-Dekodierung kann ein
    /// Vielfaches der Bytezahl belegen.
    private static func readAll(descriptor: Int32, openedAs before: stat,
                                byteLimit: UInt64) throws
        -> (data: Data, snapshot: FileSnapshot) {
        let limit = min(byteLimit, FileSnapshot.maximumReadBytes)
        guard before.st_size >= 0, UInt64(before.st_size) <= limit else {
            throw FileSnapshotReadError.tooLarge(byteCount: UInt64(max(0, before.st_size)))
        }
        // Zurück auf Position 0: Die Binärprobe hat den Lesezeiger schon
        // bewegt, der Voll-Read braucht aber die Datei ab dem ersten Byte.
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard UInt64(data.count) <= limit else {
                throw FileSnapshotReadError.tooLarge(byteCount: UInt64(data.count))
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Volume und Inode können sich am offenen Deskriptor nicht mehr ändern.
        // Größe und Zeitstempel schon: Wurde IN die Datei geschrieben, während
        // wir lasen, passen Probe, Inhalt und Snapshot zu keinem einzigen
        // Plattenstand — dann lieber gar kein Ergebnis.
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FileSnapshotReadError.changedDuringRead
        }
        return (data, FileSnapshot(data: data, identity: FileIdentity(stat: after)))
    }

    /// Sucht ab `offset` bis EOF nach einem Nullbyte, ohne die Datei komplett
    /// einzulesen. Diese synchrone Hilfsfunktion darf wie `load` nur aus dem
    /// Hintergrund aufgerufen werden.
    ///
    /// `handle` ist bewusst der bereits offene Deskriptor des Ladevorgangs und
    /// kein Pfad: Nur so urteilt der Nachscan über dieselbe Datei, deren Typ
    /// und Größe vorher geprüft wurden. Ein zweites Öffnen könnte inzwischen
    /// auf ein anderes Ziel zeigen.
    private static func containsNUL(handle: FileHandle, startingAt offset: UInt64) throws -> Bool {
        do {
            try handle.seek(toOffset: offset)
            while true {
                let chunk = try handle.read(upToCount: binaryScanChunkSize) ?? Data()
                if chunk.isEmpty { return false }
                if chunk.contains(0) { return true }
            }
        } catch {
            throw LoadError.unreadable
        }
    }

}
