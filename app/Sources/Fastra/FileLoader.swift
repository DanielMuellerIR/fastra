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

    static func load(url: URL, forcedEncoding: String.Encoding? = nil,
                     largeFileThreshold: UInt64 = largeFileThreshold) throws -> LoadedFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        if let enc = forcedEncoding {
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: enc) else {
                throw LoadError.unreadable
            }
            return LoadedFile(content: s, encoding: enc,
                              lineEnding: LineEnding.detect(in: s),
                              displayMode: .text, fileSize: fileSize)
        }

        // Null-Byte-Probe ist die verbindliche Binär-Erkennung aus der
        // Roadmap. Nur einen kleinen Anfang lesen — auch eine 20-GB-Datei wird
        // dadurch praktisch sofort als Hex-View geöffnet.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LoadError.unreadable
        }
        let probe = try handle.read(upToCount: binaryProbeSize) ?? Data()
        try? handle.close()
        let hasUnicodeBOM = probe.starts(with: [0xFF, 0xFE])
            || probe.starts(with: [0xFE, 0xFF])
            || probe.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || probe.starts(with: [0xFF, 0xFE, 0x00, 0x00])
        if probe.contains(0) && !hasUnicodeBOM {
            return LoadedFile(content: "", encoding: .utf8, lineEnding: .lf,
                              displayMode: .hex, fileSize: fileSize)
        }
        if fileSize > largeFileThreshold {
            return LoadedFile(content: "", encoding: .utf8, lineEnding: .lf,
                              displayMode: .chunkedText, fileSize: fileSize)
        }

        var detectedEncoding: String.Encoding = .utf8
        let raw: String

        do {
            // Erster Versuch: Foundation erkennt das Encoding automatisch
            // (z.B. BOM bei UTF-16, oder Systemstandard bei fehlender BOM).
            raw = try String(contentsOf: url, usedEncoding: &detectedEncoding)
        } catch {
            // Fallback: rohe Bytes lesen und als UTF-8 interpretieren.
            // `String(data:encoding:)` ohne `.allowLossyConversion` schlägt
            // fehl, wenn die Bytes kein gültiges UTF-8 sind (z.B. Latin-1-
            // Sonderzeichen). In dem Fall ist die Datei wirklich unlesbar.
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) else {
                throw LoadError.unreadable
            }
            // Foundation gab kein Encoding zurück → UTF-8 als Default setzen.
            detectedEncoding = .utf8
            raw = s
        }

        // Zeilenenden erkennen: CRLF vor CR prüfen (CRLF enthält auch CR,
        // daher Reihenfolge wichtig — `LineEnding.detect` macht das korrekt).
        let ending = LineEnding.detect(in: raw)

        return LoadedFile(content: raw, encoding: detectedEncoding,
                          lineEnding: ending, displayMode: .text,
                          fileSize: fileSize)
    }
}
