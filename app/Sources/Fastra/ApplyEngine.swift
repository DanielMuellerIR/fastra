// ApplyEngine.swift
//
// Apply-Sicherheits-Gate (v0.6) — Dry-Run-Stufe.
//
// Diese Datei beschreibt den Such/Ersetzen-Plan und berechnet ihn, OHNE
// auch nur ein Byte auf der Platte zu verändern. Die destruktive
// Apply-Stufe (echte Writes mit atomic-replace + Undo-Backup im zentralen
// Trash-Ordner) kommt erst, wenn diese Dry-Run-Tests grün sind. So ist
// das in AGENTS.md festgehalten („Hartes Gate für die Apply-Logik").
//
// Wichtige Entscheidungen:
//
// * **BOM vor Binär-Heuristik.** UTF-16/UTF-32-Text enthält Null-Bytes und
//   würde von `FileScanner.isBinary` fälschlich als binär gemeldet.
//   Deshalb wird ZUERST nach einer BOM gesucht; nur ohne BOM fällt die
//   Datei in die Null-Byte-Heuristik.
// * **Encoding bleibt erhalten.** Wir dekodieren die Datei in einen Swift-
//   String, ersetzen darauf, und kodieren das Ergebnis mit dem gleichen
//   Encoding + ggf. ursprünglicher BOM zurück. Bytes außerhalb der
//   Trefferregionen sollen sich nicht verändern.
// * **Pure Funktion.** `ApplyEngine.plan(...)` schreibt nichts und ist
//   damit voll testbar. Der einzige Seiteneffekt ist Datei-LESEN.

import Foundation

// MARK: - Such-Optionen

/// Such-/Ersetzen-Eingaben für die Engine. Bewusst frei vom Workspace-
/// Modell — die Engine soll auch aus Tests und CLI heraus aufrufbar sein.
struct SearchOptions: Equatable {
    /// Roh-Eingabe aus dem Find-Feld. Bei `isRegex == false` wird
    /// dieser String wie ein literaler Text behandelt.
    let find: String
    /// Roh-Eingabe aus dem Replace-Feld. Bei `isRegex == false` werden
    /// `$N`-Backrefs NICHT interpretiert (Plain-Text-Modus).
    let replace: String
    let isRegex: Bool
    let caseSensitive: Bool
    /// `\b…\b` um das Muster — funktioniert auch im Plain-Text-Modus,
    /// weil dort der escapte Find-String wieder in eine RegEx gepackt wird.
    let wholeWord: Bool

    /// Mini-Schalter „`*` wörtlich nehmen" (Feature J). Wenn `true`, wird der
    /// Stern im Plain-Text-Modus als gewöhnliches Zeichen gesucht (alter
    /// v0.5-Pfad) statt als Platzhalter. Nur im Plain-Modus relevant.
    let treatWildcardLiterally: Bool

    init(find: String,
         replace: String,
         isRegex: Bool = true,
         caseSensitive: Bool = false,
         wholeWord: Bool = false,
         treatWildcardLiterally: Bool = false) {
        self.find = find
        self.replace = replace
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.treatWildcardLiterally = treatWildcardLiterally
    }

    /// Ist gar nichts zu suchen (leerer Find-String) → kein Plan möglich.
    var isEmpty: Bool { find.isEmpty }

    /// `true`, wenn der Stern als Platzhalter wirken soll: Plain-Text-Modus,
    /// Mini-Schalter aus, und mindestens ein `*` im Suchausdruck. Single
    /// Source of Truth für Such- UND Ersetz-Seite (Feature J Schritt 2).
    var usesWildcard: Bool {
        !isRegex && !treatWildcardLiterally && WildcardPattern.containsWildcard(find)
    }
}

// MARK: - Plan-Datenmodell

/// Warum eine Datei nicht angefasst wurde. Skip-Gründe sind sichtbarer
/// Teil des Plans, damit der Nutzer SIEHT, dass etwas übersprungen wurde —
/// stilles Überspringen wäre eine Sicherheitslücke (Nutzer denkt, alles
/// ist erfasst, in Wahrheit liegt eine Binärdatei mit Treffer unverändert).
enum SkipReason: Equatable {
    /// Null-Byte in den ersten 8 KB ohne BOM → Binärdatei.
    case binary
    /// Datei nicht lesbar (Rechte, kaputter Symlink etc.).
    case unreadable
    /// Encoding ließ sich nicht erkennen ODER Re-Encoding scheitert
    /// (z.B. Latin-1-Datei, neuer Text enthält Zeichen außerhalb Latin-1).
    case undecodable
    /// RegEx ist syntaktisch ungültig — Plan würde unsinnig.
    case invalidPattern(String)
}

/// Ein einzelner Treffer innerhalb einer Datei. NSRange ist hier praktisch,
/// weil NSRegularExpression auch NSRange liefert; UI/Tests können bei Bedarf
/// per `Range(_:, in:)` in Swift-String-Ranges umrechnen.
struct PlannedMatch: Equatable {
    /// Bereich im DEKODIERTEN String (NSString-Indizes, UTF-16-Code-Units).
    let range: NSRange
    /// Der Text, der ursprünglich an dieser Stelle stand.
    let before: String
    /// Der Text, der durch Apply dort stehen würde.
    let after: String
}

/// Plan für eine einzelne Datei. Entweder Treffer + neue Bytes, oder
/// `skipped` mit Grund — nie beides.
struct PlannedFileChange: Equatable {
    let url: URL
    /// Encoding, mit dem die Datei dekodiert wurde (nil bei Skip).
    let encoding: String.Encoding?
    /// Optionale BOM, die beim Re-Encoden wieder vorn drangehängt wird.
    let bom: Data
    /// Bytes vor Apply (= Datei-Inhalt zum Zeitpunkt des Planens).
    let originalBytes: Data
    /// Bytes nach Apply (mit derselben Encoding-/BOM-Strategie kodiert).
    let newBytes: Data
    /// Alle Treffer, in Reihenfolge ihres Auftretens im dekodierten String.
    let matches: [PlannedMatch]
    /// Wenn gesetzt, gibt es keine `matches`, keine `newBytes`.
    let skipped: SkipReason?

    var hasChanges: Bool { skipped == nil && originalBytes != newBytes }
}

/// Gesamt-Plan über alle gescannten Dateien.
struct ReplacePlan: Equatable {
    let files: [PlannedFileChange]

    var changedFiles: [PlannedFileChange] { files.filter { $0.hasChanges } }
    var skippedFiles: [PlannedFileChange] { files.filter { $0.skipped != nil } }
    var totalMatches: Int { files.reduce(0) { $0 + $1.matches.count } }
}

// MARK: - Engine

enum ApplyEngine {
    /// Erstellt einen Dry-Run-Plan über alle übergebenen Dateien. Liest die
    /// Dateien, BERÜHRT SIE ABER NICHT. Reihenfolge der Eingabe bleibt
    /// erhalten, damit Tests deterministisch arbeiten.
    static func plan(files: [URL], options: SearchOptions) -> ReplacePlan {
        guard !options.isEmpty else {
            return ReplacePlan(files: [])
        }
        let regex: NSRegularExpression
        do {
            regex = try buildRegex(options)
        } catch {
            // Ungültiges Pattern → alle Dateien als „skipped" mit Grund;
            // so steht es im Plan und kein Apply läuft je los.
            let invalid = files.map { url in
                PlannedFileChange(url: url, encoding: nil, bom: Data(),
                                  originalBytes: Data(), newBytes: Data(),
                                  matches: [],
                                  skipped: .invalidPattern("\(error)"))
            }
            return ReplacePlan(files: invalid)
        }

        let planned = files.map { url in planSingle(url: url, regex: regex, options: options) }
        return ReplacePlan(files: planned)
    }

    // MARK: - Einzeldatei

    private static func planSingle(url: URL,
                                   regex: NSRegularExpression,
                                   options: SearchOptions) -> PlannedFileChange {
        guard let data = try? Data(contentsOf: url) else {
            return PlannedFileChange(url: url, encoding: nil, bom: Data(),
                                     originalBytes: Data(), newBytes: Data(),
                                     matches: [], skipped: .unreadable)
        }

        // 1. BOM zuerst — UTF-16/32 enthält Null-Bytes, die die Binär-
        //    Heuristik sonst falsch alarmieren würden.
        let (bom, bomEncoding) = detectBOM(in: data)
        let payload = data.dropFirst(bom.count)

        // 2. Nur ohne BOM die Null-Byte-Heuristik anwenden.
        if bom.isEmpty && FileScanner.isBinary(data) {
            return PlannedFileChange(url: url, encoding: nil, bom: Data(),
                                     originalBytes: data, newBytes: data,
                                     matches: [], skipped: .binary)
        }

        // 3. Encoding ermitteln + dekodieren.
        guard let (text, encoding) = decode(payload: Data(payload), bomEncoding: bomEncoding) else {
            return PlannedFileChange(url: url, encoding: nil, bom: bom,
                                     originalBytes: data, newBytes: data,
                                     matches: [], skipped: .undecodable)
        }

        // 4. Treffer sammeln (alle Treffer einer NSRange-basierten Suche).
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let raw = regex.matches(in: text, options: [], range: full)

        var matches: [PlannedMatch] = []
        matches.reserveCapacity(raw.count)
        // Wir bauen den neuen String inkrementell, damit die `after`-
        // Strings exakt das enthalten, was NSRegularExpression wirklich
        // einsetzt (Backrefs etc.). Gleichzeitig erhalten wir alle Zeichen
        // außerhalb der Treffer 1:1.
        var assembled = String()
        assembled.reserveCapacity(text.count)
        var cursor = 0
        // Template einmal bestimmen (Plain-Text-Modus escapt `$`/`\`).
        let template = replacementTemplate(for: options)
        for result in raw {
            let r = result.range
            // Stück vor dem Treffer unverändert übernehmen.
            if r.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                assembled.append(chunk)
            }
            let before = ns.substring(with: r)
            // Über CaseTemplate statt direkt: unterstützt BBEdits
            // \U/\L/\u/\l/\E im Ersetzungsmuster (Fast Path ohne
            // Operatoren = unverändert NSRegularExpression).
            let after = CaseTemplate.replacement(for: result, in: text,
                                                 regex: regex, template: template)
            assembled.append(after)
            matches.append(PlannedMatch(range: r, before: before, after: after))
            cursor = r.location + r.length
        }
        // Rest hinter dem letzten Treffer.
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            assembled.append(tail)
        }

        // 5. Re-Encoding. Wenn das fehlschlägt (z.B. neuer Text enthält
        //    Umlaute, die im Original-Encoding nicht darstellbar sind),
        //    melden wir das ehrlich — kein stiller Datenverlust.
        guard let body = assembled.data(using: encoding) else {
            return PlannedFileChange(url: url, encoding: encoding, bom: bom,
                                     originalBytes: data, newBytes: data,
                                     matches: matches, skipped: .undecodable)
        }
        var rebuilt = Data()
        rebuilt.append(bom)
        rebuilt.append(body)

        return PlannedFileChange(url: url, encoding: encoding, bom: bom,
                                 originalBytes: data, newBytes: rebuilt,
                                 matches: matches, skipped: nil)
    }

    // MARK: - Pattern-Bau

    /// Übersetzt `SearchOptions` in eine fertige `NSRegularExpression`.
    /// `wholeWord` und der Plain-Text-Modus werden auf RegEx-Ebene umgesetzt,
    /// damit es nur einen Matching-Pfad gibt.
    static func buildRegex(_ options: SearchOptions) throws -> NSRegularExpression {
        var pattern: String
        if options.isRegex {
            pattern = options.find
        } else if options.usesWildcard {
            // Platzhalter-Modus (Feature J): jeder Stern-Lauf → gierige Gruppe
            // (`*` → `(.+)`, `**` → `([\s\S]+)`), der Rest wörtlich escapt.
            // `.dotMatchesLineSeparators` setzen wir BEWUSST NICHT → `.` matcht
            // kein `\n`, der Einzelstern bleibt zeilenweise; nur der
            // Doppelstern fängt über Zeilenumbrüche (via \s\S-Klasse).
            pattern = WildcardPattern.compileFind(options.find).regexPattern
        } else {
            // Plain-Text → vollständig escapen, sodass Sonderzeichen
            // wie `.` `*` `(` literal gemeint sind.
            pattern = NSRegularExpression.escapedPattern(for: options.find)
        }
        if options.wholeWord {
            pattern = "\\b" + pattern + "\\b"
        }
        var opts: NSRegularExpression.Options = []
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: opts)
    }

    /// Liefert den Template-String, der an `regex.replacementString(...)`
    /// geht. Im RegEx-Modus wird die Roh-Eingabe durchgereicht — `$1`,
    /// `$0`, `\n` etc. sind dort gewollte Backref-/Escape-Syntax. Im
    /// Plain-Text-Modus (`isRegex == false`) werden `$` und `\` via
    /// `escapedTemplate` neutralisiert, damit sie LITERAL eingesetzt
    /// werden. Ohne das würde z.B. ein Ersetzungstext „$5.00" als
    /// (leerer) Backref auf Gruppe 5 gedeutet — der Vertrag in
    /// `SearchOptions.replace` verlangt aber literale Ersetzung.
    static func replacementTemplate(for options: SearchOptions) -> String {
        if options.isRegex { return options.replace }
        // Platzhalter-Modus (Feature J): N-tes `*` im Ersetzen → `$N`. Greift
        // NUR, wenn die Such-Seite Platzhalter nutzt (gleiche Bedingung), damit
        // ein `*` ohne zugehörige Fanggruppe nicht ins Leere referenziert.
        if options.usesWildcard {
            // Die Zahl der Such-Sterne grenzt gültige Pillen-Verweise ein:
            // `$1` bis `$N` bleiben Rückreferenzen, andere Dollar-Texte literal.
            let wildcard = WildcardPattern.compileFind(options.find)
            return WildcardPattern.compileReplace(
                options.replace,
                captureCount: wildcard.starCount
            )
        }
        return NSRegularExpression.escapedTemplate(for: options.replace)
    }

    // MARK: - BOM / Encoding

    /// Erkennt eine BOM am Daten-Anfang. Gibt die BOM-Bytes selbst und das
    /// dazugehörige Encoding zurück (nil/leer, wenn keine BOM gefunden).
    static func detectBOM(in data: Data) -> (Data, String.Encoding?) {
        let bytes = [UInt8](data.prefix(4))
        // UTF-8-BOM
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (Data([0xEF, 0xBB, 0xBF]), .utf8)
        }
        // UTF-16 BE / LE
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return (Data([0xFE, 0xFF]), .utf16BigEndian)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return (Data([0xFF, 0xFE]), .utf16LittleEndian)
        }
        return (Data(), nil)
    }

    /// Versucht, die Nutzdaten in einen String zu dekodieren. Wenn eine
    /// BOM bekannt ist, hat deren Encoding Vorrang. Sonst wird in fester
    /// Reihenfolge probiert: UTF-8, Latin-1 (verlustfrei für Single-Byte),
    /// Windows-1252.
    static func decode(payload: Data, bomEncoding: String.Encoding?) -> (String, String.Encoding)? {
        if let enc = bomEncoding, let s = String(data: payload, encoding: enc) {
            return (s, enc)
        }
        let order: [String.Encoding] = [.utf8, .isoLatin1, .windowsCP1252]
        for enc in order {
            if let s = String(data: payload, encoding: enc) {
                return (s, enc)
            }
        }
        return nil
    }
}

// MARK: - APPLY-Stufe (destruktiv)
//
// Die Schreibseite des Gates. Drei harte Garantien:
//
//  1. **Pro Datei atomar.** Wir schreiben zuerst eine Temp-Datei und
//     ersetzen die Original-Datei über `FileManager.replaceItemAt(_:withItemAt:)`.
//     Stirbt der Prozess mittendrin, ist die Original-Datei entweder
//     vollständig alt oder vollständig neu. Niemals halb beschrieben.
//  2. **Vor jedem Apply ein Backup.** Die Original-Bytes jeder zu
//     verändernden Datei wandern VOR dem Schreibvorgang in einen
//     zentralen Backup-Ordner (default: `~/Library/Application Support/Fastra/undo/<session>/`).
//     Schlägt der Backup-Schritt fehl, wird nichts geschrieben.
//  3. **Bit-exaktes Undo.** Eine `ApplySession` weiß, welche Original-Datei
//     wohin gesichert wurde. `undo(_:)` spielt die Backups bit-genau über
//     `replaceItemAt` zurück (ebenfalls atomar pro Datei).
//
// Was NICHT garantiert wird: dass eine Folge-Datei-Schreibung in einem
// Multi-File-Apply scheitert, nachdem frühere bereits durch sind. Das ist
// ein Ordner-Gesamt-Rollback und braucht denselben Undo-Mechanismus —
// der Aufrufer kann den nach einem partiellen Fehler explizit auslösen.

import CryptoKit

/// Eintrag im Manifest: welche Original-Datei wohin gesichert wurde.
struct UndoEntry: Codable, Equatable {
    /// Absoluter Pfad der Original-Datei zum Zeitpunkt des Apply.
    let originalPath: String
    /// Pfad der Backup-Datei RELATIV zum Session-Ordner.
    let backupRelativePath: String
    /// SHA-256 der Original-Bytes (Sanity-Check beim Undo).
    let originalSHA256: String
}

/// Eine abgeschlossene Apply-Operation. Enthält alle Infos zum vollen Undo.
struct ApplySession: Codable, Equatable {
    /// Zeitpunkt des Apply (ISO-8601-Sekunden, im Ordnernamen kodiert).
    let timestamp: Date
    /// Ordner, in dem alle Backup-Dateien + `manifest.json` liegen.
    let sessionDirectory: URL
    /// Reihenfolge wie geschrieben — Undo läuft in derselben Reihenfolge.
    let entries: [UndoEntry]

    enum CodingKeys: String, CodingKey { case timestamp, sessionDirectory, entries }
}

enum ApplyError: Error, Equatable {
    /// Plan enthält invalide Patterns ODER Skip-Gründe in CHANGED-Dateien.
    case planNotApplyable(String)
    /// Backup-Schritt fehlgeschlagen — es wurde NICHTS geschrieben.
    case backupFailed(String)
    /// Schreibschritt fehlgeschlagen, partieller Apply. Aufrufer sollte
    /// `undo(_:)` mit der zurückgegebenen Session aufrufen.
    case writeFailed(partial: ApplySession, message: String)
}

extension ApplyEngine {
    /// Standard-Backup-Ordner: `~/Library/Application Support/Fastra/undo/`.
    static var defaultBackupRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Fastra/undo", isDirectory: true)
    }

    /// Wendet einen Plan an. Schreibt Backups, dann atomar die neuen Bytes.
    /// Reine Skip-Dateien (binary/undecodable) werden NICHT angefasst.
    ///
    /// - Parameters:
    ///   - plan: vorher per `plan(...)` berechnet.
    ///   - backupRoot: Wurzel für Backups (Tests übergeben einen Temp-Pfad).
    ///   - cleanupOlderThan: räumt Sessions im Backup-Root auf, die älter
    ///     sind als dieser Wert (Default: 30 Tage). `nil` = kein Cleanup.
    @discardableResult
    static func apply(plan: ReplacePlan,
                      backupRoot: URL? = nil,
                      cleanupOlderThan: TimeInterval? = 30 * 24 * 60 * 60) throws -> ApplySession {
        // Plan-Validierung: keine ungültigen Patterns, keine widersprüchlichen
        // Files (skipped UND changed gleichzeitig kann nicht passieren laut
        // Datenmodell, aber Skip-Reasons wie `.invalidPattern` müssen draußen
        // bleiben — die signalisieren „auch NICHT versuchen").
        for file in plan.files {
            if case .invalidPattern(let msg) = file.skipped {
                throw ApplyError.planNotApplyable("ungültige RegEx: \(msg)")
            }
        }

        let root = backupRoot ?? defaultBackupRoot

        // Cleanup VOR neuem Session-Aufbau, damit alte Snapshots nicht ewig
        // herumliegen. Stirbt Cleanup, ist das nicht fatal — wir loggen
        // nicht (App ist offline) und machen weiter.
        if let maxAge = cleanupOlderThan {
            try? cleanupBackups(maxAge: maxAge, in: root)
        }

        // Session-Ordner mit ISO-Timestamp + UUID-Präfix für Eindeutigkeit
        // (zwei Apply-Aufrufe in derselben Sekunde sollen nicht kollidieren).
        let now = Date()
        let dirName = "session-\(iso8601Compact(now))-\(UUID().uuidString.prefix(8))"
        let sessionDir = root.appendingPathComponent(dirName, isDirectory: true)
        let filesDir = sessionDir.appendingPathComponent("files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        } catch {
            throw ApplyError.backupFailed("Backup-Ordner anlegen: \(error)")
        }

        // 1. Backup-Phase: ALLE Originale zuerst sichern. Erst wenn das
        //    komplett ist, wird auch nur eine Datei verändert.
        var entries: [UndoEntry] = []
        let toChange = plan.files.enumerated().filter { $0.element.hasChanges }
        for (i, file) in toChange {
            let backupName = "files/\(i).bin"
            let backupURL = sessionDir.appendingPathComponent(backupName)
            do {
                try file.originalBytes.write(to: backupURL, options: .atomic)
            } catch {
                // Aufräumen: angefangene Session-Ordner wieder weg.
                try? FileManager.default.removeItem(at: sessionDir)
                throw ApplyError.backupFailed("Backup schreiben (\(file.url.lastPathComponent)): \(error)")
            }
            let hash = sha256Hex(file.originalBytes)
            entries.append(UndoEntry(originalPath: file.url.path,
                                     backupRelativePath: backupName,
                                     originalSHA256: hash))
        }

        // 2. Manifest schreiben — bewusst VOR der Schreibphase, damit das
        //    Undo auch bei einem Crash zwischen Datei n und n+1 funktioniert.
        let session = ApplySession(timestamp: now, sessionDirectory: sessionDir, entries: entries)
        do {
            try writeManifest(session)
        } catch {
            try? FileManager.default.removeItem(at: sessionDir)
            throw ApplyError.backupFailed("Manifest schreiben: \(error)")
        }

        // 3. Schreibphase: pro Datei atomar via replaceItemAt.
        for (i, file) in toChange {
            let tmpURL = sessionDir.appendingPathComponent("tmp-\(i).bin")
            do {
                try file.newBytes.write(to: tmpURL, options: .atomic)
                _ = try FileManager.default.replaceItemAt(file.url, withItemAt: tmpURL)
            } catch {
                // Halbfertige Tmp-Datei nicht liegen lassen (nach erfolgreichem
                // replaceItemAt existiert sie nicht mehr — dann schlägt das
                // Löschen still fehl, ist ok). Review 2026-07-03.
                try? FileManager.default.removeItem(at: tmpURL)
                // Partieller Apply. Wir liefern die bisher gültige Session
                // zurück, damit der Aufrufer per undo(_:) zurückrollen kann.
                throw ApplyError.writeFailed(partial: session,
                                             message: "\(file.url.lastPathComponent): \(error)")
            }
        }

        return session
    }

    /// Spielt eine Apply-Session bit-genau zurück. Atomar pro Datei.
    /// Hash-Check warnt, wenn das Backup beschädigt ist.
    static func undo(_ session: ApplySession) throws {
        for entry in session.entries {
            let backup = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
            let backupBytes = try Data(contentsOf: backup)
            // Sanity: stimmt der Hash noch? Wenn nicht, wurde der Backup-
            // Ordner manipuliert — wir brechen ab, statt potenziell
            // falsche Bytes zurückzuspielen.
            guard sha256Hex(backupBytes) == entry.originalSHA256 else {
                throw ApplyError.backupFailed("Backup-Hash stimmt nicht: \(entry.backupRelativePath)")
            }
            // Über eine separate Tmp-Datei, damit replaceItemAt
            // unsere Backup-Datei nicht verschiebt (Backup soll
            // wiederverwendbar bleiben).
            let tmp = session.sessionDirectory.appendingPathComponent("undo-tmp-\(UUID().uuidString).bin")
            // Tmp auch im Fehlerpfad entsorgen — nach erfolgreichem
            // replaceItemAt ist sie schon weg (Löschen schlägt still fehl).
            // Review 2026-07-03.
            defer { try? FileManager.default.removeItem(at: tmp) }
            try backupBytes.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: entry.originalPath),
                                                     withItemAt: tmp)
        }
    }

    /// Räumt Session-Ordner auf, die älter sind als `maxAge` Sekunden.
    /// Nur Verzeichnisse mit dem Präfix `session-` werden betrachtet —
    /// fremde Dateien im Backup-Root bleiben unangetastet.
    static func cleanupBackups(maxAge: TimeInterval, in backupRoot: URL? = nil) throws {
        let root = backupRoot ?? defaultBackupRoot
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries where url.lastPathComponent.hasPrefix("session-") {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = values?.contentModificationDate ?? .distantFuture
            if mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Internas

    /// `2026-05-28T09-30-15` — kollisionsarm, ordnersicher (keine `:`).
    private static func iso8601Compact(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeManifest(_ session: ApplySession) throws {
        let url = session.sessionDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
    }

    /// Lädt eine zuvor gespeicherte Session aus ihrem Manifest. Nützlich,
    /// um nach App-Neustart ein Undo zu bauen.
    static func loadSession(at directory: URL) throws -> ApplySession {
        let url = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ApplySession.self, from: data)
    }
}
