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
    }

    /// Fehler, den `load(url:)` werfen kann.
    enum LoadError: Error {
        /// Die Datei konnte weder mit automatischer Encoding-Erkennung
        /// noch als UTF-8 mit Lossy-Konvertierung gelesen werden.
        case unreadable
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
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        // Null-Byte-Probe ist die verbindliche Binär-Erkennung aus der
        // Roadmap. Nur einen kleinen Anfang lesen — auch eine 20-GB-Datei wird
        // dadurch praktisch sofort als Hex-View geöffnet.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LoadError.unreadable
        }
        let probe = try handle.read(upToCount: binaryProbeSize) ?? Data()
        try? handle.close()
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
                                  fileSize: fileSize)
            }
            guard let data = try? Data(contentsOf: url) else {
                throw LoadError.unreadable
            }
            let (bom, bomEncoding) = ApplyEngine.detectBOM(in: data)
            let payload = Data(data.dropFirst(bom.count))
            let exactEncoding = explicitBodyEncoding(enc, bomEncoding: bomEncoding)
            guard let s = String(data: payload, encoding: exactEncoding) else {
                throw LoadError.unreadable
            }
            return LoadedFile(content: s, encoding: exactEncoding, bom: bom,
                              lineEnding: LineEnding.detect(in: s),
                              displayMode: .text, fileSize: fileSize)
        }

        // Ohne BOM sind UTF-16-Text und beliebige 16-Bit-Binärdaten nicht
        // belastbar unterscheidbar: Beide können dieselbe Nullbyte-Parität und
        // ausschließlich druckbare Codeunits besitzen. Automatische Erkennung
        // würde PCM-/UInt16-Dateien als editierbaren Text öffnen. Deshalb gilt
        // fail-closed: Nullbyte ohne BOM → Hex. Wer die Herkunft kennt, kann
        // UTF-16 LE/BE ausdrücklich über „Neu öffnen mit Encoding“ wählen.
        if probe.contains(0) && !bomEncodingAllowsNUL(probeBOMEncoding) {
            return LoadedFile(content: "", encoding: .utf8, bom: Data(), lineEnding: .lf,
                              displayMode: .hex, fileSize: fileSize)
        }
        if fileSize > largeFileThreshold {
            // Die 8-KiB-Probe allein reicht nicht: Binärdaten können erst weit
            // hinter dem Anfang ein Nullbyte enthalten. Ohne BOM scannen wir
            // deshalb den Rest abschnittsweise. BOM-markiertes UTF-16 bleibt
            // erlaubt; dort sind Nullbytes erwartbarer Bestandteil des Texts.
            if !bomEncodingAllowsNUL(probeBOMEncoding),
               try containsNUL(url: url, startingAt: UInt64(probe.count)) {
                return LoadedFile(content: "", encoding: .utf8, bom: Data(),
                                  lineEnding: .lf, displayMode: .hex,
                                  fileSize: fileSize)
            }
            return LoadedFile(content: "",
                              encoding: probeBOMEncoding ?? .utf8,
                              bom: probeBOM, lineEnding: .lf,
                              displayMode: .chunkedText, fileSize: fileSize)
        }

        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable }
        let (bom, bomEncoding) = ApplyEngine.detectBOM(in: data)
        // Kleine Dateien liegen hier ohnehin vollständig vor. Daher erneut
        // über alle Bytes prüfen, damit ein Nullbyte hinter der Anfangsprobe
        // nicht als editierbarer UTF-8-String durchrutscht.
        if !bomEncodingAllowsNUL(bomEncoding) && data.contains(0) {
            return LoadedFile(content: "", encoding: .utf8, bom: Data(),
                              lineEnding: .lf, displayMode: .hex,
                              fileSize: fileSize)
        }
        let payload = Data(data.dropFirst(bom.count))
        let detected: (String, String.Encoding)?
        if let bomEncoding, let value = String(data: payload, encoding: bomEncoding) {
            detected = (value, bomEncoding)
        } else if let value = String(data: payload, encoding: .utf8) {
            detected = (value, .utf8)
        } else {
            // Die bisherige Foundation-Heuristik bleibt für Legacy-Encodings
            // erhalten. Unicode-BOMs wurden vorher schon deterministisch
            // behandelt; BOM-freies UTF-16 bleibt absichtlich Hex, bis der
            // Nutzer ein Encoding ausdrücklich auswählt.
            var legacyEncoding: String.Encoding = .utf8
            if let value = try? String(contentsOf: url, usedEncoding: &legacyEncoding) {
                detected = (value, legacyEncoding)
            } else {
                detected = nil
            }
        }
        guard let (raw, detectedEncoding) = detected else { throw LoadError.unreadable }

        // Zeilenenden erkennen: CRLF vor CR prüfen (CRLF enthält auch CR,
        // daher Reihenfolge wichtig — `LineEnding.detect` macht das korrekt).
        let ending = LineEnding.detect(in: raw)

        return LoadedFile(content: raw, encoding: detectedEncoding, bom: bom,
                          lineEnding: ending, displayMode: .text,
                          fileSize: fileSize)
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
        return encoding
    }

    /// Nur automatisch erkannte UTF-16-BOMs erklären Nullbytes im Text.
    /// Eine UTF-8-BOM ist dagegen kein Freibrief für spätere Nullbytes.
    /// UTF-32 wird von `ApplyEngine.detectBOM` derzeit nicht erkannt und ist
    /// daher ausschließlich über die bewusste `forcedEncoding`-Route möglich.
    private static func bomEncodingAllowsNUL(_ encoding: String.Encoding?) -> Bool {
        encoding == .utf16LittleEndian || encoding == .utf16BigEndian
    }

    /// Sucht ab `offset` bis EOF nach einem Nullbyte, ohne die Datei komplett
    /// einzulesen. Diese synchrone Hilfsfunktion darf wie `load` nur aus dem
    /// Hintergrund aufgerufen werden.
    private static func containsNUL(url: URL, startingAt offset: UInt64) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LoadError.unreadable
        }
        defer { try? handle.close() }
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
