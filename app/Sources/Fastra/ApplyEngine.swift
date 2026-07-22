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

import CryptoKit
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
    /// Exakte Datei-Basis des Plans. Apply darf nur schreiben, solange Inhalt
    /// UND Dateiidentität noch genau diesem Snapshot entsprechen.
    let originalSnapshot: FileSnapshot?
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

/// Bereits stabil gelesene Dateibasis. Die Ordner-Vorschau kann damit aus
/// exakt den Bytes planen, deren Snapshot der Nutzer gesehen hat, ohne das
/// Ziel zwischen Vorschauprüfung und Planbildung ein zweites Mal zu öffnen.
struct ReplacePlanInput {
    let url: URL
    let data: Data
    let snapshot: FileSnapshot
}

/// Unveränderlicher Vertrag zwischen sichtbarer Ordner-Vorschau und dem
/// schreibenden Hintergrundlauf. Die Vorschau liefert Snapshot + exakte
/// Treffer; `execute` liest und plant immer nur eine Datei gleichzeitig und
/// legt Original/Nachher zunächst dateibasiert ab. So hängt der Spitzen-
/// speicher von der größten Datei ab, nicht vom gesamten Trefferkorpus.
struct ApplyTransaction {
    struct Input {
        let url: URL
        let snapshot: FileSnapshot
        let matches: [PlannedMatch]
    }

    enum Phase: Equatable {
        case planned
        case backedUp
        case applied
    }

    struct Progress: Equatable {
        let phase: Phase
        let completedFiles: Int
        let totalFiles: Int
        let fileName: String
    }

    let inputs: [Input]
    let options: SearchOptions
    /// Hash über Suchsemantik, Zielpfade, Vorschau-Snapshots und sichtbare
    /// Treffer. Nach dem Start kann kein UI-Zustand den Auftrag verändern.
    let planSHA256: String

    init(inputs: [Input], options: SearchOptions) {
        self.inputs = inputs
        self.options = options
        var digest = SHA256()
        func add(_ value: String) {
            digest.update(data: Data(value.utf8))
            digest.update(data: Data([0]))
        }
        add(options.find)
        add(options.replace)
        add(String(options.isRegex))
        add(String(options.caseSensitive))
        add(String(options.wholeWord))
        add(String(options.treatWildcardLiterally))
        for input in inputs {
            add(input.url.standardizedFileURL.path)
            add(input.snapshot.sha256)
            add(String(input.snapshot.byteCount))
            add(String(input.snapshot.identity?.volumeNumber ?? 0))
            add(String(input.snapshot.identity?.fileNumber ?? 0))
            for match in input.matches {
                add(String(match.range.location))
                add(String(match.range.length))
                add(match.before)
                add(match.after)
            }
        }
        planSHA256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func execute(
        backupRoot: URL? = nil,
        cleanupOlderThan: TimeInterval? = 30 * 24 * 60 * 60,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        progress: (Progress) -> Void = { _ in },
        beforePreflight: (() throws -> Void)? = nil,
        atomicReplace: ((URL, URL) throws -> Void)? = nil
    ) throws -> ApplySession {
        try ApplyEngine.execute(
            transaction: self, backupRoot: backupRoot,
            cleanupOlderThan: cleanupOlderThan,
            shouldCancel: shouldCancel, progress: progress,
            beforePreflight: beforePreflight, atomicReplace: atomicReplace)
    }
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
                PlannedFileChange(url: url, originalSnapshot: nil,
                                  encoding: nil, bom: Data(),
                                  originalBytes: Data(), newBytes: Data(),
                                  matches: [],
                                  skipped: .invalidPattern("\(error)"))
            }
            return ReplacePlan(files: invalid)
        }

        let planned = files.map { url in
            guard let read = try? FileSnapshot.read(from: url) else {
                return PlannedFileChange(url: url, originalSnapshot: nil,
                                         encoding: nil, bom: Data(),
                                         originalBytes: Data(), newBytes: Data(),
                                         matches: [], skipped: .unreadable)
            }
            return planSingle(url: url, data: read.data, snapshot: read.snapshot,
                              regex: regex, options: options)
        }
        return ReplacePlan(files: planned)
    }

    /// Plan aus einer bereits stabil gelesenen Vorschau-Basis. Dieser Pfad
    /// ist die Sicherheitsbrücke zwischen sichtbarer Ordnersuche und Apply.
    static func plan(inputs: [ReplacePlanInput], options: SearchOptions) -> ReplacePlan {
        guard !options.isEmpty else { return ReplacePlan(files: []) }
        let regex: NSRegularExpression
        do {
            regex = try buildRegex(options)
        } catch {
            return ReplacePlan(files: inputs.map { input in
                PlannedFileChange(url: input.url, originalSnapshot: input.snapshot,
                                  encoding: nil, bom: Data(),
                                  originalBytes: input.data, newBytes: input.data,
                                  matches: [], skipped: .invalidPattern("\(error)"))
            })
        }
        return ReplacePlan(files: inputs.map {
            planSingle(url: $0.url, data: $0.data, snapshot: $0.snapshot,
                       regex: regex, options: options)
        })
    }

    // MARK: - Einzeldatei

    private static func planSingle(url: URL,
                                   data: Data,
                                   snapshot: FileSnapshot,
                                   regex: NSRegularExpression,
                                   options: SearchOptions) -> PlannedFileChange {
        // Der normale Dry-Run besitzt kein Abbruchsignal. Der transaktionale
        // Pfad darunter verwendet dieselbe Logik mit einem echten Signal.
        planSingleCancellable(url: url, data: data, snapshot: snapshot,
                              regex: regex, options: options,
                              shouldCancel: { false })!
    }

    /// Abbrechbare Einzeldatei-Planung für `ApplyTransaction`. `nil` bedeutet
    /// ausschließlich Cancellation; fachliche Skip-Gründe bleiben weiterhin
    /// als vollständiger `PlannedFileChange` sichtbar.
    private static func planSingleCancellable(
        url: URL,
        data: Data,
        snapshot: FileSnapshot,
        regex: NSRegularExpression,
        options: SearchOptions,
        shouldCancel: @escaping () -> Bool
    ) -> PlannedFileChange? {
        if shouldCancel() { return nil }
        let originalSnapshot = snapshot

        // 1. BOM zuerst — UTF-16/32 enthält Null-Bytes, die die Binär-
        //    Heuristik sonst falsch alarmieren würden.
        let (bom, bomEncoding) = detectBOM(in: data)
        let payload = data.dropFirst(bom.count)

        // 2. Nur ohne BOM die Null-Byte-Heuristik anwenden.
        if bom.isEmpty && FileScanner.isBinary(data) {
            return PlannedFileChange(url: url, originalSnapshot: originalSnapshot,
                                     encoding: nil, bom: Data(),
                                     originalBytes: data, newBytes: data,
                                     matches: [], skipped: .binary)
        }

        // 3. Encoding ermitteln + dekodieren.
        guard let (text, encoding) = decode(payload: Data(payload), bomEncoding: bomEncoding) else {
            return PlannedFileChange(url: url, originalSnapshot: originalSnapshot,
                                     encoding: nil, bom: bom,
                                     originalBytes: data, newBytes: data,
                                     matches: [], skipped: .undecodable)
        }

        // 4. Treffer sammeln und Ergebnis zusammensetzen. `.reportProgress`
        // liefert auch bei langen Bereichen ohne Treffer regelmäßige
        // Callbacks, damit der Apply-Abbruch in einer großen Einzeldatei
        // nicht bis zum vollständigen RegEx-Lauf warten muss.
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var matches: [PlannedMatch] = []
        // Wir bauen den neuen String inkrementell, damit die `after`-
        // Strings exakt das enthalten, was NSRegularExpression wirklich
        // einsetzt (Backrefs etc.). Gleichzeitig erhalten wir alle Zeichen
        // außerhalb der Treffer 1:1.
        var assembled = String()
        assembled.reserveCapacity(text.count)
        var cursor = 0
        var cancelled = false
        // Template einmal bestimmen (Plain-Text-Modus escapt `$`/`\`).
        let template = replacementTemplate(for: options)
        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: full) { result, _, stop in
            if shouldCancel() {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let result else { return }
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
        if cancelled { return nil }
        // Rest hinter dem letzten Treffer.
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            assembled.append(tail)
        }

        // 5. Re-Encoding. Wenn das fehlschlägt (z.B. neuer Text enthält
        //    Umlaute, die im Original-Encoding nicht darstellbar sind),
        //    melden wir das ehrlich — kein stiller Datenverlust.
        guard let body = assembled.data(using: encoding) else {
            return PlannedFileChange(url: url, originalSnapshot: originalSnapshot,
                                     encoding: encoding, bom: bom,
                                     originalBytes: data, newBytes: data,
                                     matches: matches, skipped: .undecodable)
        }
        var rebuilt = Data()
        rebuilt.append(bom)
        rebuilt.append(body)

        return PlannedFileChange(url: url, originalSnapshot: originalSnapshot,
                                 encoding: encoding, bom: bom,
                                 originalBytes: data, newBytes: rebuilt,
                                 matches: matches, skipped: nil)
    }

    /// Plant genau die stabil gelesene sichtbare Basis einer Transaktions-
    /// Datei und reicht Cancellation bis in die RegEx-Enumeration durch.
    private static func planTransactionInput(
        _ input: ReplacePlanInput,
        options: SearchOptions,
        shouldCancel: @escaping () -> Bool
    ) throws -> PlannedFileChange {
        if shouldCancel() { throw ApplyError.cancelled }
        let regex: NSRegularExpression
        do {
            regex = try buildRegex(options)
        } catch {
            throw ApplyError.planNotApplyable((error as NSError).localizedDescription)
        }
        guard let file = planSingleCancellable(
            url: input.url, data: input.data, snapshot: input.snapshot,
            regex: regex, options: options, shouldCancel: shouldCancel
        ) else {
            throw ApplyError.cancelled
        }
        return file
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
        // UTF-32 MUSS vor UTF-16 geprüft werden: FF FE 00 00 beginnt sonst
        // scheinbar mit einer UTF-16LE-BOM und würde falsch ausgerichtet.
        if bytes.count >= 4,
           bytes[0] == 0x00, bytes[1] == 0x00,
           bytes[2] == 0xFE, bytes[3] == 0xFF {
            return (Data([0x00, 0x00, 0xFE, 0xFF]), .utf32BigEndian)
        }
        if bytes.count >= 4,
           bytes[0] == 0xFF, bytes[1] == 0xFE,
           bytes[2] == 0x00, bytes[3] == 0x00 {
            return (Data([0xFF, 0xFE, 0x00, 0x00]), .utf32LittleEndian)
        }
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
    /// BOM bekannt ist, hat deren Encoding Vorrang. Sonst gilt UTF-8 zuerst;
    /// definierte druckbare C1-Bytes wählen Windows-1252, alle übrigen
    /// Single-Byte-Daten fallen konservativ auf Latin-1 zurück.
    static func decode(payload: Data, bomEncoding: String.Encoding?) -> (String, String.Encoding)? {
        if let enc = bomEncoding {
            guard let s = String(data: payload, encoding: enc) else { return nil }
            return (s, enc)
        }
        if let utf8 = String(data: payload, encoding: .utf8) {
            return (utf8, .utf8)
        }
        // ISO-8859-1 dekodiert jede Bytefolge und machte den bisherigen
        // nachgeordneten Windows-1252-Pfad unerreichbar. Definierte Bytes im
        // C1-Bereich sind in realen Textdateien ein belastbares CP1252-Signal;
        // unzugeordnete C1-Bytes bleiben dagegen konservativ Latin-1.
        let cp1252PrintableC1: Set<UInt8> = [
            0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88,
            0x89, 0x8A, 0x8B, 0x8C, 0x8E, 0x91, 0x92, 0x93,
            0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B,
            0x9C, 0x9E, 0x9F,
        ]
        if payload.contains(where: cp1252PrintableC1.contains),
           let cp1252 = String(data: payload, encoding: .windowsCP1252) {
            return (cp1252, .windowsCP1252)
        }
        if let latin1 = String(data: payload, encoding: .isoLatin1) {
            return (latin1, .isoLatin1)
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

/// Eintrag im Manifest: welche Original-Datei wohin gesichert wurde.
struct UndoEntry: Codable, Equatable {
    enum State: String, Codable, Equatable {
        /// Backup und erwarteter neuer Hash sind persistiert; der Prozess kann
        /// vor oder nach dem eigentlichen Replace beendet worden sein.
        case pending
        /// Ziel wurde erfolgreich durch den geplanten Zustand ersetzt.
        case applied
        /// Backup wurde bereits wiederhergestellt; ein erneutes Undo lässt
        /// diesen Eintrag aus und kann mit späteren Dateien fortfahren.
        case restored
        /// Manifest einer älteren Fastra-Version ohne sicheren Applied-Hash.
        /// Automatisches Undo muss dafür sichtbar fail-closed bleiben.
        case legacy
    }
    /// Absoluter Pfad der Original-Datei zum Zeitpunkt des Apply.
    let originalPath: String
    /// Pfad der Backup-Datei RELATIV zum Session-Ordner.
    let backupRelativePath: String
    /// SHA-256 der Original-Bytes (Sanity-Check beim Undo).
    let originalSHA256: String
    /// Stabile Foundation-Encoding-ID und exakte BOM der Planbasis. Undo
    /// bleibt bytebasiert; die Metadaten machen den Vertrag im Journal
    /// trotzdem vollständig und diagnostizierbar.
    let encodingRawValue: UInt?
    let bom: Data
    /// SHA-256 und Identität des erfolgreich geschriebenen Zustands. Ein Undo
    /// darf ausschließlich genau diesen Zustand zurücksetzen.
    let appliedSnapshot: FileSnapshot?
    /// `pending` wird VOR dem Replace persistiert. So kann ein Crash keine
    /// bereits geänderte Datei aus dem Undo-Journal verschwinden lassen.
    let state: State

    enum CodingKeys: String, CodingKey {
        case originalPath, backupRelativePath, originalSHA256, encodingRawValue, bom,
             appliedSnapshot, state
    }

    init(originalPath: String, backupRelativePath: String, originalSHA256: String,
         encodingRawValue: UInt? = nil, bom: Data = Data(),
         appliedSnapshot: FileSnapshot?, state: State) {
        self.originalPath = originalPath
        self.backupRelativePath = backupRelativePath
        self.originalSHA256 = originalSHA256
        self.encodingRawValue = encodingRawValue
        self.bom = bom
        self.appliedSnapshot = appliedSnapshot
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        originalPath = try values.decode(String.self, forKey: .originalPath)
        backupRelativePath = try values.decode(String.self, forKey: .backupRelativePath)
        originalSHA256 = try values.decode(String.self, forKey: .originalSHA256)
        encodingRawValue = try values.decodeIfPresent(UInt.self, forKey: .encodingRawValue)
        bom = try values.decodeIfPresent(Data.self, forKey: .bom) ?? Data()
        appliedSnapshot = try values.decodeIfPresent(FileSnapshot.self, forKey: .appliedSnapshot)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .legacy
    }
}

/// Eine abgeschlossene Apply-Operation. Enthält alle Infos zum vollen Undo.
struct ApplySession: Codable, Equatable {
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    /// Zeitpunkt des Apply (ISO-8601-Sekunden, im Ordnernamen kodiert).
    let timestamp: Date
    /// Ordner, in dem alle Backup-Dateien + `manifest.json` liegen.
    let sessionDirectory: URL
    /// Reihenfolge wie geschrieben — Undo läuft in derselben Reihenfolge.
    let entries: [UndoEntry]

    enum CodingKeys: String, CodingKey { case schemaVersion, timestamp, sessionDirectory, entries }

    init(timestamp: Date, sessionDirectory: URL, entries: [UndoEntry],
         schemaVersion: Int = ApplySession.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.sessionDirectory = sessionDirectory
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        sessionDirectory = try values.decode(URL.self, forKey: .sessionDirectory)
        entries = try values.decode([UndoEntry].self, forKey: .entries)
    }
}

enum ApplyError: Error, Equatable {
    /// Plan enthält invalide Patterns ODER Skip-Gründe in CHANGED-Dateien.
    case planNotApplyable(String)
    /// Backup-Schritt fehlgeschlagen — es wurde NICHTS geschrieben.
    case backupFailed(String)
    /// Ein Ziel stimmt nicht mehr mit der sichtbaren Plan-/Apply-Basis überein.
    case conflict(String)
    /// Ein Undo-Ziel wurde seit dem Apply erneut verändert.
    case undoConflict(String)
    /// Älteres Manifest enthält keinen verlässlichen Zustand nach Apply.
    case legacySession(String)
    /// Schreibschritt fehlgeschlagen, partieller Apply. Aufrufer sollte
    /// `undo(_:)` mit der zurückgegebenen Session aufrufen.
    case writeFailed(partial: ApplySession, message: String)
    /// Undo hat mindestens einen Eintrag restauriert und kann mit der
    /// zurückgegebenen, bereits persistierten Session fortgesetzt werden.
    case undoFailed(partial: ApplySession, message: String)
    /// Abbruch war noch vor dem ersten Ziel-Write möglich; kein Ziel wurde
    /// verändert und die vorbereitete Session wurde entfernt.
    case cancelled
}

extension ApplyEngine {
    /// Standard-Backup-Ordner: `~/Library/Application Support/Fastra/undo/`.
    static var defaultBackupRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Fastra/undo", isDirectory: true)
    }

    /// Führt einen aus der sichtbaren Vorschau eingefrorenen Ordner-Auftrag
    /// dateiweise aus. Bis der globale Preflight abgeschlossen ist, darf ein
    /// Abbruch die vorbereitete Session vollständig entfernen. Ab dem ersten
    /// Ziel-Write wird der kurze Journal-/Replace-Abschnitt bewusst zu Ende
    /// geführt, damit nie ein unjournalierter Zwischenzustand entsteht.
    @discardableResult
    static func execute(
        transaction: ApplyTransaction,
        backupRoot: URL? = nil,
        cleanupOlderThan: TimeInterval? = 30 * 24 * 60 * 60,
        shouldCancel: @escaping @Sendable () -> Bool,
        progress: (ApplyTransaction.Progress) -> Void,
        beforePreflight: (() throws -> Void)? = nil,
        atomicReplace: ((URL, URL) throws -> Void)? = nil
    ) throws -> ApplySession {
        guard !transaction.inputs.isEmpty, !transaction.options.isEmpty else {
            throw ApplyError.planNotApplyable(L10n.string("Der Apply-Auftrag ist leer."))
        }
        if shouldCancel() { throw ApplyError.cancelled }

        let root = backupRoot ?? defaultBackupRoot
        if let maxAge = cleanupOlderThan {
            try? cleanupBackups(maxAge: maxAge, in: root)
        }
        let now = Date()
        let dirName = "session-\(iso8601Compact(now))-\(UUID().uuidString.prefix(8))"
        let sessionDir = root.appendingPathComponent(dirName, isDirectory: true)
        let filesDir = sessionDir.appendingPathComponent("files", isDirectory: true)
        let stagedDir = sessionDir.appendingPathComponent("staged", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: filesDir,
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stagedDir,
                                                    withIntermediateDirectories: true)
        } catch {
            throw ApplyError.backupFailed(L10n.format(
                "Backup-Ordner anlegen: %@", error.localizedDescription))
        }

        struct StagedFile {
            let url: URL
            let expectedSnapshot: FileSnapshot
            let backupRelativePath: String
            let stagedNewURL: URL
            let originalSHA256: String
            let encodingRawValue: UInt?
            let bom: Data
        }

        var keepSession = false
        defer {
            try? FileManager.default.removeItem(at: stagedDir)
            if !keepSession { try? FileManager.default.removeItem(at: sessionDir) }
        }

        var staged: [StagedFile] = []
        staged.reserveCapacity(transaction.inputs.count)
        let total = transaction.inputs.count

        // Planung + Backup halten immer nur die aktuelle Datei im Speicher.
        // Die Vorschau-Matches werden noch einmal byte-/rangegenau verglichen.
        for (index, input) in transaction.inputs.enumerated() {
            if shouldCancel() { throw ApplyError.cancelled }
            guard let current = try? FileSnapshot.read(from: input.url),
                  current.snapshot == input.snapshot else {
                throw ApplyError.conflict(L10n.format(
                    "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
                    input.url.lastPathComponent))
            }
            let file = try planTransactionInput(
                ReplacePlanInput(url: input.url, data: current.data,
                                 snapshot: current.snapshot),
                options: transaction.options, shouldCancel: shouldCancel)
            guard file.skipped == nil, file.hasChanges else {
                throw ApplyError.planNotApplyable(L10n.format(
                    "„%@“ kann nicht auf der sichtbaren Vorschau-Basis ersetzt werden.",
                    input.url.lastPathComponent))
            }
            guard file.matches == input.matches else {
                throw ApplyError.conflict(L10n.string(
                    "Die berechnete Änderung stimmt nicht mehr mit der sichtbaren Vorschau überein. Starte die Suche erneut; es wurde nichts verändert."))
            }
            progress(ApplyTransaction.Progress(
                phase: .planned, completedFiles: index + 1,
                totalFiles: total, fileName: input.url.lastPathComponent))

            let backupRelativePath = "files/\(index).bin"
            let backupURL = sessionDir.appendingPathComponent(backupRelativePath)
            let stagedNewURL = stagedDir.appendingPathComponent("\(index).bin")
            do {
                try file.originalBytes.write(to: backupURL, options: .atomic)
                try file.newBytes.write(to: stagedNewURL, options: .atomic)
            } catch {
                throw ApplyError.backupFailed(L10n.format(
                    "Backup vorbereiten (%@): %@", input.url.lastPathComponent,
                    error.localizedDescription))
            }
            staged.append(StagedFile(
                url: input.url, expectedSnapshot: current.snapshot,
                backupRelativePath: backupRelativePath,
                stagedNewURL: stagedNewURL,
                originalSHA256: current.snapshot.sha256,
                encodingRawValue: file.encoding?.rawValue, bom: file.bom))
            progress(ApplyTransaction.Progress(
                phase: .backedUp, completedFiles: index + 1,
                totalFiles: total, fileName: input.url.lastPathComponent))
        }

        try beforePreflight?()

        // Alle Ziele noch einmal prüfen, bevor auch nur ein Ziel verändert
        // wird. Der Durchlauf liest weiterhin nur eine Datei gleichzeitig.
        for item in staged {
            if shouldCancel() { throw ApplyError.cancelled }
            guard let current = try? FileSnapshot.read(from: item.url),
                  current.snapshot == item.expectedSnapshot else {
                throw ApplyError.conflict(L10n.format(
                    "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
                    item.url.lastPathComponent))
            }
        }
        if shouldCancel() { throw ApplyError.cancelled }

        var session = ApplySession(timestamp: now,
                                   sessionDirectory: sessionDir, entries: [])
        do {
            try writeManifest(session)
        } catch {
            throw ApplyError.backupFailed(L10n.format(
                "Manifest schreiben: %@", error.localizedDescription))
        }

        for (index, item) in staged.enumerated() {
            let newBytes: Data
            do {
                newBytes = try Data(contentsOf: item.stagedNewURL,
                                    options: [.mappedIfSafe])
            } catch {
                keepSession = !session.entries.isEmpty
                if keepSession {
                    throw ApplyError.writeFailed(
                        partial: session,
                        message: L10n.format("%@: %@", item.url.lastPathComponent,
                                             error.localizedDescription))
                }
                throw ApplyError.backupFailed(L10n.format(
                    "Temporäre Datei lesen (%@): %@", item.url.lastPathComponent,
                    error.localizedDescription))
            }
            let expectedApplied = FileSnapshot(data: newBytes, identity: nil)
            let pending = UndoEntry(
                originalPath: item.url.path,
                backupRelativePath: item.backupRelativePath,
                originalSHA256: item.originalSHA256,
                encodingRawValue: item.encodingRawValue,
                bom: item.bom,
                appliedSnapshot: expectedApplied,
                state: .pending)
            let beforePending = session
            let withPending = ApplySession(
                timestamp: now, sessionDirectory: sessionDir,
                entries: session.entries + [pending])
            do {
                try writeManifest(withPending)
                session = withPending
            } catch {
                keepSession = !session.entries.isEmpty
                if keepSession {
                    throw ApplyError.writeFailed(
                        partial: session,
                        message: L10n.format("Manifest schreiben: %@",
                                             error.localizedDescription))
                }
                throw ApplyError.backupFailed(L10n.format(
                    "Manifest schreiben: %@", error.localizedDescription))
            }

            let temporaryURL = temporarySiblingURL(for: item.url, purpose: "apply")
            var replacementAttempted = false
            do {
                try newBytes.write(to: temporaryURL, options: .atomic)
                let applied = try coordinateReplacing(item.url) { coordinatedURL in
                    let current = try FileSnapshot.read(from: coordinatedURL)
                    guard current.snapshot == item.expectedSnapshot else {
                        throw ApplyError.conflict(L10n.format(
                            "„%@“ wurde während des Apply geändert.",
                            item.url.lastPathComponent))
                    }
                    // Ab hier kann ein Fehler nicht beweisen, dass das Ziel
                    // unverändert blieb: Ein Replace darf schreiben und erst
                    // danach fehlschlagen. Das pending-Journal bleibt dann
                    // zwingend für Recovery/Undo erhalten.
                    replacementAttempted = true
                    if let atomicReplace {
                        try atomicReplace(coordinatedURL, temporaryURL)
                    } else {
                        try replacePreparedTemporaryFile(at: coordinatedURL,
                                                         temporaryURL: temporaryURL)
                    }
                    let verified = try FileSnapshot.read(from: coordinatedURL)
                    guard verified.data == newBytes else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    return verified.snapshot
                }
                let appliedEntry = UndoEntry(
                    originalPath: pending.originalPath,
                    backupRelativePath: pending.backupRelativePath,
                    originalSHA256: pending.originalSHA256,
                    encodingRawValue: pending.encodingRawValue,
                    bom: pending.bom, appliedSnapshot: applied, state: .applied)
                let appliedSession = ApplySession(
                    timestamp: now, sessionDirectory: sessionDir,
                    entries: Array(session.entries.dropLast()) + [appliedEntry])
                try writeManifest(appliedSession)
                session = appliedSession
                progress(ApplyTransaction.Progress(
                    phase: .applied, completedFiles: index + 1,
                    totalFiles: total, fileName: item.url.lastPathComponent))
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                if !replacementAttempted {
                    session = beforePending
                    try? writeManifest(session)
                }
                keepSession = !session.entries.isEmpty || replacementAttempted
                if case ApplyError.conflict(let message) = error {
                    if !keepSession { throw ApplyError.conflict(message) }
                    throw ApplyError.writeFailed(partial: session, message: message)
                }
                throw ApplyError.writeFailed(
                    partial: session,
                    message: L10n.format("%@: %@", item.url.lastPathComponent,
                                         error.localizedDescription))
            }
        }

        keepSession = true
        return session
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
                      cleanupOlderThan: TimeInterval? = 30 * 24 * 60 * 60,
                      atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
                      manifestWriter: ((ApplySession) throws -> Void)? = nil) throws -> ApplySession {
        // Plan-Validierung: keine ungültigen Patterns, keine widersprüchlichen
        // Files (skipped UND changed gleichzeitig kann nicht passieren laut
        // Datenmodell, aber Skip-Reasons wie `.invalidPattern` müssen draußen
        // bleiben — die signalisieren „auch NICHT versuchen").
        for file in plan.files {
            if case .invalidPattern(let msg) = file.skipped {
                throw ApplyError.planNotApplyable(L10n.format("ungültige RegEx: %@", msg))
            }
        }

        let root = backupRoot ?? defaultBackupRoot
        let toChange = plan.files.enumerated().filter { $0.element.hasChanges }

        // Transaktions-Preflight: ALLE Ziele prüfen, bevor Backup-Ordner oder
        // Writes entstehen. So kann ein bereits sichtbarer Konflikt niemals zu
        // einem halb begonnenen neuen Apply führen.
        for (_, file) in toChange {
            guard let expected = file.originalSnapshot,
                  let current = try? FileSnapshot.read(from: file.url),
                  current.data == file.originalBytes,
                  current.snapshot == expected else {
                throw ApplyError.conflict(L10n.format(
                    "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
                    file.url.lastPathComponent))
            }
        }

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
            throw ApplyError.backupFailed(L10n.format("Backup-Ordner anlegen: %@", error.localizedDescription))
        }

        // 1. Backup-Phase: ALLE Originale zuerst sichern. Erst wenn das
        //    komplett ist, wird auch nur eine Datei verändert.
        var preparedEntries: [(index: Int, file: PlannedFileChange,
                               backupName: String, originalSHA256: String)] = []
        for (i, file) in toChange {
            let backupName = "files/\(i).bin"
            let backupURL = sessionDir.appendingPathComponent(backupName)
            do {
                try file.originalBytes.write(to: backupURL, options: .atomic)
            } catch {
                // Aufräumen: angefangene Session-Ordner wieder weg.
                try? FileManager.default.removeItem(at: sessionDir)
                throw ApplyError.backupFailed(L10n.format("Backup schreiben (%@): %@",
                                                          file.url.lastPathComponent,
                                                          error.localizedDescription))
            }
            preparedEntries.append((index: i, file: file,
                                    backupName: backupName,
                                    originalSHA256: FileSnapshot.sha256Hex(file.originalBytes)))
        }

        func persist(_ candidate: ApplySession) throws {
            if let manifestWriter {
                try manifestWriter(candidate)
            } else {
                try writeManifest(candidate)
            }
        }

        // 2. Leeres Journal anlegen. Vor JEDEM Replace kommt ein pending-
        // Eintrag hinein; nach Erfolg wird derselbe Eintrag auf applied
        // fortgeschrieben. So bleibt auch das Crash-Fenster zwischen Replace
        // und zweitem Manifest-Write sicher rekonstruierbar.
        var session = ApplySession(timestamp: now, sessionDirectory: sessionDir, entries: [])
        do {
            try persist(session)
        } catch {
            try? FileManager.default.removeItem(at: sessionDir)
            throw ApplyError.backupFailed(L10n.format("Manifest schreiben: %@", error.localizedDescription))
        }

        // 3. Schreibphase: pro Datei atomar via replaceItemAt.
        for prepared in preparedEntries {
            let i = prepared.index
            let file = prepared.file
            // Temp und Ziel müssen auf demselben Volume liegen, sonst ist
            // `replaceItemAt` kein belastbarer atomarer Austausch.
            let tmpURL = temporarySiblingURL(for: file.url, purpose: "apply-\(i)")

            let expectedApplied = FileSnapshot(data: file.newBytes, identity: nil)
            let pending = UndoEntry(originalPath: file.url.path,
                                    backupRelativePath: prepared.backupName,
                                    originalSHA256: prepared.originalSHA256,
                                    encodingRawValue: file.encoding?.rawValue,
                                    bom: file.bom,
                                    appliedSnapshot: expectedApplied,
                                    state: .pending)
            let beforePending = session
            let withPending = ApplySession(timestamp: now, sessionDirectory: sessionDir,
                                           entries: session.entries + [pending])
            do {
                try persist(withPending)
                session = withPending
            } catch {
                if session.entries.contains(where: { $0.state == .applied || $0.state == .pending }) {
                    throw ApplyError.writeFailed(partial: session,
                                                 message: L10n.format("Manifest schreiben: %@",
                                                                      error.localizedDescription))
                }
                try? FileManager.default.removeItem(at: sessionDir)
                throw ApplyError.backupFailed(L10n.format("Manifest schreiben: %@",
                                                          error.localizedDescription))
            }

            // Die potenziell große Temp-Datei entsteht VOR der letzten
            // Zielprüfung. Innerhalb der koordinierten Sektion bleiben danach
            // nur noch descriptorgebundener Snapshot und atomarer Austausch.
            do {
                try file.newBytes.write(to: tmpURL, options: .atomic)
            } catch {
                session = beforePending
                try? persist(session)
                try? FileManager.default.removeItem(at: tmpURL)
                if session.entries.isEmpty {
                    throw ApplyError.backupFailed(L10n.format("Temporäre Datei schreiben (%@): %@",
                                                              file.url.lastPathComponent,
                                                              error.localizedDescription))
                }
                throw ApplyError.writeFailed(partial: session,
                                             message: L10n.format("%@: %@",
                                                                  file.url.lastPathComponent,
                                                                  error.localizedDescription))
            }

            var replacementAttempted = false
            do {
                let applied = try coordinateReplacing(file.url) { coordinatedURL in
                    // Zweite Prüfung unmittelbar vor jedem einzelnen Replace.
                    // NSFileCoordinator koppelt sie für kooperierende Writer an
                    // dieselbe Schreibsektion wie den atomaren Austausch.
                    let current = try FileSnapshot.read(from: coordinatedURL)
                    guard let expected = file.originalSnapshot,
                          current.data == file.originalBytes,
                          current.snapshot == expected else {
                        throw ApplyError.conflict(L10n.format(
                            "„%@“ wurde während des Apply geändert.",
                            file.url.lastPathComponent))
                    }
                    replacementAttempted = true
                    if let atomicReplace {
                        try atomicReplace(file.newBytes, coordinatedURL, tmpURL)
                    } else {
                        try replacePreparedTemporaryFile(at: coordinatedURL,
                                                         temporaryURL: tmpURL)
                    }
                    return FileSnapshot(data: file.newBytes, at: coordinatedURL)
                }
                let entry = UndoEntry(originalPath: pending.originalPath,
                                      backupRelativePath: pending.backupRelativePath,
                                      originalSHA256: pending.originalSHA256,
                                      encodingRawValue: pending.encodingRawValue,
                                      bom: pending.bom,
                                      appliedSnapshot: applied, state: .applied)
                let appliedSession = ApplySession(
                    timestamp: now, sessionDirectory: sessionDir,
                    entries: Array(session.entries.dropLast()) + [entry])
                // Schlägt dieser Write fehl, bleibt das persistierte pending-
                // Journal erhalten. Undo löst es anhand des Zielhashes auf.
                try persist(appliedSession)
                session = appliedSession
            } catch {
                // Halbfertige Tmp-Datei nicht liegen lassen (nach erfolgreichem
                // replaceItemAt existiert sie nicht mehr — dann schlägt das
                // Löschen still fehl, ist ok). Review 2026-07-03.
                try? FileManager.default.removeItem(at: tmpURL)
                // Partieller Apply. Wir liefern die bisher gültige Session
                // zurück, damit der Aufrufer per undo(_:) zurückrollen kann.
                if !replacementAttempted {
                    // Ein definitiv nicht ausgeführter Replace gehört nicht in
                    // eine normale Partial-Session. Crash-Recovery bleibt über
                    // den vorher persistierten pending-Zustand abgedeckt; hier
                    // können wir ihn kontrolliert wieder entfernen.
                    session = beforePending
                    try? persist(session)
                }
                if case ApplyError.conflict(let message) = error {
                    if session.entries.isEmpty { throw ApplyError.conflict(message) }
                    throw ApplyError.writeFailed(partial: session, message: message)
                }
                throw ApplyError.writeFailed(partial: session,
                                             message: L10n.format("%@: %@",
                                                                  file.url.lastPathComponent,
                                                                  error.localizedDescription))
            }
        }

        return session
    }

    /// Spielt eine Apply-Session bit-genau zurück. Atomar pro Datei.
    /// Hash-Check warnt, wenn das Backup beschädigt ist.
    @discardableResult
    static func undo(_ session: ApplySession,
                     atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
                     manifestWriter: ((ApplySession) throws -> Void)? = nil) throws -> ApplySession {
        guard session.schemaVersion == ApplySession.currentSchemaVersion,
              !session.entries.contains(where: { $0.state == .legacy || $0.appliedSnapshot == nil }) else {
            throw ApplyError.legacySession(L10n.string(
                "Diese Rückgängig-Session verwendet ein nicht kompatibles Sicherheitsformat und wird deshalb nicht automatisch angewendet."))
        }

        func persist(_ candidate: ApplySession) throws {
            if let manifestWriter { try manifestWriter(candidate) }
            else { try writeManifest(candidate) }
        }

        func replacing(_ session: ApplySession, index: Int,
                       with entry: UndoEntry) -> ApplySession {
            var entries = session.entries
            entries[index] = entry
            return ApplySession(timestamp: session.timestamp,
                                sessionDirectory: session.sessionDirectory,
                                entries: entries,
                                schemaVersion: session.schemaVersion)
        }

        // Wie beim Apply zuerst ALLE Backups und Ziele prüfen. Pending-
        // Einträge werden anhand des exakten Zielinhalts aufgelöst; ein nach
        // Crash schon originales Ziel gilt als restauriert, ein erwarteter
        // neuer Inhalt als angewendet. Alles andere bleibt Konflikt.
        var working = session
        func conflictError(_ message: String) -> ApplyError {
            if working.entries.contains(where: { $0.state == .restored }) {
                return .undoFailed(partial: working, message: message)
            }
            return .undoConflict(message)
        }
        var prepared: [(index: Int, backupBytes: Data)] = []
        for index in working.entries.indices {
            let entry = working.entries[index]
            let backup = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
            let backupBytes = try Data(contentsOf: backup)
            // Sanity: stimmt der Hash noch? Wenn nicht, wurde der Backup-
            // Ordner manipuliert — wir brechen ab, statt potenziell
            // falsche Bytes zurückzuspielen.
            guard FileSnapshot.sha256Hex(backupBytes) == entry.originalSHA256 else {
                throw ApplyError.backupFailed(L10n.format("Backup-Hash stimmt nicht: %@",
                                                          entry.backupRelativePath))
            }
            if entry.state == .restored { continue }

            let target = URL(fileURLWithPath: entry.originalPath)
            guard let current = try? FileSnapshot.read(from: target),
                  let expectedApplied = entry.appliedSnapshot else {
                throw conflictError(L10n.format(
                    "„%@“ wurde nach dem Apply geändert. Rückgängig wurde abgebrochen.",
                    target.lastPathComponent))
            }

            if current.snapshot.sha256 == entry.originalSHA256,
               current.data == backupBytes {
                let restored = UndoEntry(originalPath: entry.originalPath,
                                         backupRelativePath: entry.backupRelativePath,
                                         originalSHA256: entry.originalSHA256,
                                         encodingRawValue: entry.encodingRawValue,
                                         bom: entry.bom,
                                         appliedSnapshot: entry.appliedSnapshot,
                                         state: .restored)
                working = replacing(working, index: index, with: restored)
                continue
            }

            let appliedMatches = entry.state == .pending
                ? current.snapshot.hasSameContent(as: expectedApplied)
                : current.snapshot == expectedApplied
            guard appliedMatches else {
                throw conflictError(L10n.format(
                    "„%@“ wurde nach dem Apply geändert. Rückgängig wurde abgebrochen.",
                    target.lastPathComponent))
            }
            if entry.state == .pending {
                let resolved = UndoEntry(originalPath: entry.originalPath,
                                         backupRelativePath: entry.backupRelativePath,
                                         originalSHA256: entry.originalSHA256,
                                         encodingRawValue: entry.encodingRawValue,
                                         bom: entry.bom,
                                         appliedSnapshot: current.snapshot,
                                         state: .applied)
                working = replacing(working, index: index, with: resolved)
            }
            prepared.append((index, backupBytes))
        }

        if working != session { try persist(working) }

        for item in prepared {
            let entry = working.entries[item.index]
            let backupBytes = item.backupBytes
            let target = URL(fileURLWithPath: entry.originalPath)
            let tmp = temporarySiblingURL(for: target, purpose: "undo")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                // Wieder vor der finalen Zielprüfung vorbereiten: große
                // Backup-Bytes verlängern das TOCTOU-Fenster nicht.
                try backupBytes.write(to: tmp, options: .atomic)
                var replaceCompleted = false
                try coordinateReplacing(target) { coordinatedURL in
                    let current = try FileSnapshot.read(from: coordinatedURL)
                    guard current.snapshot == entry.appliedSnapshot else {
                        throw ApplyError.undoConflict(L10n.format(
                            "„%@“ wurde während Rückgängig geändert.", target.lastPathComponent))
                    }
                    if let atomicReplace {
                        try atomicReplace(backupBytes, coordinatedURL, tmp)
                    } else {
                        try replacePreparedTemporaryFile(at: coordinatedURL,
                                                         temporaryURL: tmp)
                    }
                    replaceCompleted = true
                }
                guard replaceCompleted else { throw CocoaError(.fileWriteUnknown) }
                let restored = UndoEntry(originalPath: entry.originalPath,
                                         backupRelativePath: entry.backupRelativePath,
                                         originalSHA256: entry.originalSHA256,
                                         encodingRawValue: entry.encodingRawValue,
                                         bom: entry.bom,
                                         appliedSnapshot: entry.appliedSnapshot,
                                         state: .restored)
                let restoredSession = replacing(working, index: item.index, with: restored)
                // Bei Manifestfehler bleibt der persistierte Applied-Zustand;
                // der nächste Lauf erkennt die bereits originalen Bytes und
                // setzt den Eintrag ohne erneuten Write auf restored.
                try persist(restoredSession)
                working = restoredSession
            } catch let error as ApplyError {
                if case .undoConflict(let message) = error {
                    throw conflictError(message)
                }
                throw ApplyError.undoFailed(partial: working,
                                            message: error.localizedDescription)
            } catch {
                throw ApplyError.undoFailed(partial: working,
                                            message: L10n.format("%@: %@",
                                                                 target.lastPathComponent,
                                                                 error.localizedDescription))
            }
        }
        return working
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

    static func writeManifest(_ session: ApplySession) throws {
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

    private static func replacePreparedTemporaryFile(at target: URL,
                                                     temporaryURL: URL) throws {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporaryURL)
    }

    /// Sibling statt Session-Temp: `replaceItemAt` bleibt damit auch dann auf
    /// einem Volume, wenn Application Support und Ziel auf verschiedenen
    /// Datenträgern liegen.
    private static func temporarySiblingURL(for target: URL,
                                            purpose: String) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).fastra-\(purpose)-\(UUID().uuidString).tmp")
    }

    private static func coordinateReplacing<T>(_ target: URL,
                                                operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: target, options: .forReplacing,
                               error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}
