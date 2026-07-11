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
    static func load(url: URL, forcedEncoding: String.Encoding? = nil) throws -> LoadedFile {
        if let enc = forcedEncoding {
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: enc) else {
                throw LoadError.unreadable
            }
            return LoadedFile(content: s, encoding: enc, lineEnding: LineEnding.detect(in: s))
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

        return LoadedFile(content: raw, encoding: detectedEncoding, lineEnding: ending)
    }
}
