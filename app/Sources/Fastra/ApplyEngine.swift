// ApplyEngine.swift
//
// Die Planbildung bindet Treffer an Dateisnapshots und schreibt keine Bytes.
// Apply und Undo verwenden anschließend den gemeinsamen Transaktionskern
// mit atomarem Austausch und gebundenen Wiederherstellungsdaten.
//
// Wichtige Entscheidungen:
//
// * **BOM vor Binär-Heuristik.** UTF-16/UTF-32-Text enthält Null-Bytes und
//   würde von `FileScanner.isBinary` fälschlich als binär gemeldet.
//   Deshalb wird zuerst nach einer BOM gesucht; nur UTF-16-/UTF-32-BOMs
//   erlauben Nullbytes. Die Klassifikation entspricht dem Datei-Editor.
// * **Encoding bleibt erhalten.** Wir dekodieren die Datei in einen Swift-
//   String, ersetzen darauf, und kodieren das Ergebnis mit dem gleichen
//   Encoding + ggf. ursprünglicher BOM zurück. Bytes außerhalb der
//   Trefferregionen sollen sich nicht verändern.
// * **Pure Funktion.** `ApplyEngine.plan(...)` schreibt nichts und ist
//   damit voll testbar. Der einzige Seiteneffekt ist Datei-Lesen.

import FastraPatternSyntax
import CryptoKit
import Darwin
import Foundation

// MARK: - Such-Optionen

/// Such-/Ersetzen-Eingaben für die Engine. Bewusst frei vom Workspace-
/// Modell — die Engine soll auch aus Tests und CLI heraus aufrufbar sein.
struct SearchOptions: Equatable, Sendable {
    /// Roh-Eingabe aus dem Find-Feld. Bei `isRegex == false` wird
    /// dieser String wie ein literaler Text behandelt.
    let find: String
    /// Roh-Eingabe aus dem Replace-Feld. Bei `isRegex == false` werden
    /// `$N`-Backrefs nicht interpretiert (Plain-Text-Modus).
    let replace: String
    let isRegex: Bool
    let caseSensitive: Bool
    /// `\b…\b` um das Muster — funktioniert auch im Plain-Text-Modus,
    /// weil dort der escapte Find-String wieder in eine RegEx gepackt wird.
    let wholeWord: Bool

    /// Mini-Schalter „`*` wörtlich nehmen". Wenn `true`, wird der
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
    /// Source of Truth für Such- und Ersetz-Seite.
    var usesWildcard: Bool {
        !isRegex && !treatWildcardLiterally && WildcardPattern.containsWildcard(find)
    }
}

/// Ein für genau einen Suchlauf vorbereiteter, unveränderlicher Plan.
///
/// Ordner-, Geöffnet- und Apply-Läufe reichen dieselbe Instanz an alle
/// Dateien beziehungsweise Tabs weiter. Dadurch entstehen das reguläre
/// Ausdrucksmuster und das Ersetzungstemplate einmal pro Lauf statt einmal
/// pro Eingabe. `NSRegularExpression` ist nach dem Initialisieren
/// unveränderlich; die Sendable-Zusage betrifft ausschließlich dieses
/// kontrollierte Teilen des fertig gebauten Foundation-Objekts.
struct SearchPlan: @unchecked Sendable {
    let options: SearchOptions
    let regex: NSRegularExpression
    let replacementTemplate: String

    init(options: SearchOptions) throws {
        self.options = options
        // Im Wildcard-Modus liefert eine Übersetzung sowohl das RegEx-Muster
        // als auch die Zahl der Ersetzungsgruppen. Ohne diesen gemeinsamen
        // Wert würde selbst ein einzelner SearchPlan die Suchseite zweimal
        // übersetzen.
        let wildcard = options.usesWildcard
            ? WildcardPattern.compileFind(options.find)
            : nil
        regex = try ApplyEngine.buildRegex(options, wildcard: wildcard)
        replacementTemplate = ApplyEngine.replacementTemplate(
            for: options, wildcard: wildcard
        )
    }
}

// MARK: - Plan-Datenmodell

/// Warum eine Datei nicht angefasst wurde. Skip-Gründe sind sichtbarer
/// Teil des Plans, damit der Nutzer sieht, dass etwas übersprungen wurde —
/// stilles Überspringen wäre eine Sicherheitslücke (Nutzer denkt, alles
/// ist erfasst, in Wahrheit liegt eine Binärdatei mit Treffer unverändert).
enum SkipReason: Equatable {
    /// Nullbyte in vollständig gelesenen Daten ohne UTF-16-/UTF-32-BOM.
    case binary
    /// Datei nicht lesbar (Rechte, kaputter Symlink etc.).
    case unreadable
    /// Encoding ließ sich nicht erkennen oder Re-Encoding scheitert
    /// (z.B. Latin-1-Datei, neuer Text enthält Zeichen außerhalb Latin-1).
    case undecodable
    /// RegEx ist syntaktisch ungültig — Plan würde unsinnig.
    case invalidPattern(String)
}

enum PlannedReadFailure: Equatable {
    struct SystemCause: Equatable {
        let domain: String
        let code: Int
        let message: String

        init(_ error: NSError) {
            domain = error.domain
            code = error.code
            message = error.localizedDescription
        }
    }

    case snapshot(FileSnapshotReadError)
    case system(SystemCause, underlying: SystemCause?)

    init(_ error: Error) {
        if let snapshot = error as? FileSnapshotReadError {
            self = .snapshot(snapshot)
        } else {
            let error = error as NSError
            // FileHandle verpackt den POSIX-Lesefehler in einen Cocoa-Fehler.
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? Error)
                .map { SystemCause($0 as NSError) }
            self = .system(SystemCause(error), underlying: underlying)
        }
    }
}

/// Ein einzelner Treffer innerhalb einer Datei. NSRange ist hier praktisch,
/// weil NSRegularExpression auch NSRange liefert; UI/Tests können bei Bedarf
/// per `Range(_:, in:)` in Swift-String-Ranges umrechnen.
struct PlannedMatch: Equatable {
    /// Bereich im dekodierten String (NSString-Indizes, UTF-16-Code-Units).
    let range: NSRange
    /// Der Text, der ursprünglich an dieser Stelle stand.
    let before: String
    /// Der Text, der durch Apply dort stehen würde.
    let after: String

    // Die Vorschau bindet exakte Bytes, nicht nur kanonisch gleiche Zeichen.
    static func == (lhs: PlannedMatch, rhs: PlannedMatch) -> Bool {
        lhs.range == rhs.range && lhs.before.utf8.elementsEqual(rhs.before.utf8)
            && lhs.after.utf8.elementsEqual(rhs.after.utf8)
    }
}

/// Plan für eine einzelne Datei. Entweder Treffer + neue Bytes, oder
/// `skipped` mit Grund — nie beides.
struct PlannedFileChange: Equatable {
    let url: URL
    /// Exakte Datei-Basis des Plans. Apply darf nur schreiben, solange Inhalt
    /// und Dateiidentität noch genau diesem Snapshot entsprechen.
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
    /// Wertkopie des Lesefehlers; der übersprungene Plan hält kein Fehlerobjekt.
    let readFailure: PlannedReadFailure?
    /// nil wendet alle Treffer an; eine leere Menge schreibt keinen Treffer.
    let approvedRanges: Set<NSRange>?

    init(url: URL, originalSnapshot: FileSnapshot?, encoding: String.Encoding?, bom: Data,
         originalBytes: Data, newBytes: Data, matches: [PlannedMatch], skipped: SkipReason?,
         approvedRanges: Set<NSRange>? = nil, readFailure: PlannedReadFailure? = nil) {
        self.url = url
        self.originalSnapshot = originalSnapshot
        self.encoding = encoding
        self.bom = bom
        self.originalBytes = originalBytes
        self.newBytes = newBytes
        self.matches = matches
        self.skipped = skipped
        self.approvedRanges = approvedRanges
        self.readFailure = readFailure
    }

    var hasChanges: Bool { skipped == nil && originalBytes != newBytes }
}

/// Gesamt-Plan über alle gescannten Dateien.
struct ReplacePlan: Equatable {
    let files: [PlannedFileChange]
    /// Die Suchsemantik, aus der dieser Plan entstand. `apply(plan:)` reicht
    /// sie an den Transaktionskern weiter, der jede Datei auf exakt dieser
    /// Basis erneut plant und gegen die sichtbaren Treffer vergleicht.
    let options: SearchOptions

    var changedFiles: [PlannedFileChange] { files.filter { $0.hasChanges } }
    var skippedFiles: [PlannedFileChange] { files.filter { $0.skipped != nil } }
    var totalMatches: Int { files.reduce(0) { $0 + $1.matches.count } }
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
        let approvedRanges: Set<NSRange>?

        init(url: URL, snapshot: FileSnapshot, matches: [PlannedMatch],
             approvedRanges: Set<NSRange>? = nil) {
            self.url = url
            self.snapshot = snapshot
            self.matches = matches
            self.approvedRanges = approvedRanges
        }
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

    // Ein früherer `planSHA256` über Suchsemantik, Zielpfade und Treffer
    // wurde entfernt: Die Transaktion ist ein reiner
    // Wert-Typ und kann sich nach dem Bau nicht mehr ändern — der Hash wurde
    // an keiner Grenze geprüft. Der echte Schutz gegen veränderte Ziele ist
    // der Snapshot-Preflight in `execute` (`expectedOnDisk`).
    let inputs: [Input]
    let options: SearchOptions
    let folderSourceBasis: FolderSearch.SourceBasis?

    init(inputs: [Input], options: SearchOptions, folderSourceBasis: FolderSearch.SourceBasis? = nil) {
        self.inputs = inputs
        self.options = options
        self.folderSourceBasis = folderSourceBasis
    }

    @discardableResult
    func execute(
        backupRoot: URL? = nil,
        cleanupOlderThan: TimeInterval? = 30 * 24 * 60 * 60,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        progress: (Progress) -> Void = { _ in },
        beforePreflight: (() throws -> Void)? = nil,
        beforeAtomicReplace: ((URL) throws -> Void)? = nil,
        afterCleanupClaim: ((URL) throws -> Void)? = nil,
        atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
        manifestWriter: ((ApplySession) throws -> Void)? = nil
    ) throws -> ApplySession {
        try ApplyEngine.execute(
            transaction: self, backupRoot: backupRoot,
            cleanupOlderThan: cleanupOlderThan,
            shouldCancel: shouldCancel, progress: progress,
            beforePreflight: beforePreflight,
            beforeAtomicReplace: beforeAtomicReplace,
            afterCleanupClaim: afterCleanupClaim,
            atomicReplace: atomicReplace,
            manifestWriter: manifestWriter)
    }
}

// MARK: - Engine

enum ApplyEngine {
    enum PlanningError: Error { case outputTooLarge }
    /// Erstellt einen Dry-Run-Plan über alle übergebenen Dateien. Liest die
    /// Dateien, berührt sie aber nicht. Reihenfolge der Eingabe bleibt
    /// erhalten, damit Tests deterministisch arbeiten.
    static func plan(files: [URL], options: SearchOptions) -> ReplacePlan {
        guard !options.isEmpty else {
            return ReplacePlan(files: [], options: options)
        }
        let searchPlan: SearchPlan
        do {
            searchPlan = try SearchPlan(options: options)
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
            return ReplacePlan(files: invalid, options: options)
        }

        let planned = files.map { url in
            do {
                let read = try FileSnapshot.read(from: url)
                return planSingle(url: url, data: read.data, snapshot: read.snapshot,
                                  searchPlan: searchPlan)
            } catch {
                return PlannedFileChange(url: url, originalSnapshot: nil,
                                         encoding: nil, bom: Data(),
                                         originalBytes: Data(), newBytes: Data(),
                                         matches: [], skipped: .unreadable,
                                         readFailure: PlannedReadFailure(error))
            }
        }
        return ReplacePlan(files: planned, options: options)
    }

    // MARK: - Einzeldatei

    private static func planSingle(url: URL,
                                   data: Data,
                                   snapshot: FileSnapshot,
                                   searchPlan: SearchPlan) -> PlannedFileChange {
        // Der normale Dry-Run besitzt kein Abbruchsignal. Der transaktionale
        // Pfad darunter verwendet dieselbe Logik mit einem echten Signal.
        // Ohne Ausgabegrenze wirft der gemeinsame Planer keinen Fehler.
        try! planSingleCancellable(url: url, data: data, snapshot: snapshot,
                              searchPlan: searchPlan,
                              shouldCancel: { false })!
    }

    /// Abbrechbare Einzeldatei-Planung für `ApplyTransaction`. `nil` bedeutet
    /// ausschließlich Cancellation; fachliche Skip-Gründe bleiben weiterhin
    /// als vollständiger `PlannedFileChange` sichtbar.
    private static func planSingleCancellable(
        url: URL,
        data: Data,
        snapshot: FileSnapshot,
        searchPlan: SearchPlan,
        approvedRanges: Set<NSRange>? = nil,
        maximumOutputTextBytes: Int? = nil,
        maximumOutputBytes: Int? = nil,
        shouldCancel: @escaping () -> Bool
    ) throws -> PlannedFileChange? {
        if shouldCancel() { return nil }
        let originalSnapshot = snapshot

        // 1. BOM zuerst — UTF-16/32 enthält Null-Bytes, die die Binär-
        //    Heuristik sonst falsch alarmieren würden.
        let (bom, bomEncoding) = detectBOM(in: data)
        let payload = data.dropFirst(bom.count)

        // 2. Bereits vollständig gelesene Daten wie der Editor klassifizieren.
        if !FileLoader.bomEncodingAllowsNUL(bomEncoding) && data.contains(0) {
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
        var outputTooLarge = false
        var outputBytes = 0
        func append(_ piece: String) -> Bool {
            if let maximumOutputTextBytes {
                guard piece.utf8.count <= maximumOutputTextBytes - outputBytes else { return false }
                outputBytes += piece.utf8.count
            }
            assembled.append(piece)
            return true
        }
        // RegEx und Template stammen aus dem einmal vorbereiteten Laufplan.
        searchPlan.regex.enumerateMatches(in: text, options: [.reportProgress],
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
                guard append(chunk) else {
                    outputTooLarge = true; stop.pointee = true; return
                }
            }
            let before = ns.substring(with: r)
            // Über CaseTemplate statt direkt: unterstützt BBEdits
            // \U/\L/\u/\l/\E im Ersetzungsmuster (Fast Path ohne
            // Operatoren = unverändert NSRegularExpression).
            let after = CaseTemplate.replacement(
                for: result, in: text, regex: searchPlan.regex,
                template: searchPlan.replacementTemplate
            )
            guard append(approvedRanges.map { $0.contains(r) } == false ? before : after) else {
                outputTooLarge = true; stop.pointee = true; return
            }
            matches.append(PlannedMatch(range: r, before: before, after: after))
            cursor = r.location + r.length
        }
        if cancelled { return nil }
        if outputTooLarge { throw PlanningError.outputTooLarge }
        // Rest hinter dem letzten Treffer.
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            guard append(tail) else { throw PlanningError.outputTooLarge }
        }

        // 5. Re-Encoding. Wenn das fehlschlägt (z.B. neuer Text enthält
        //    Umlaute, die im Original-Encoding nicht darstellbar sind),
        //    melden wir das ehrlich — kein stiller Datenverlust.
        if let maximumOutputBytes,
           encodedSize(assembled, encoding: encoding) > maximumOutputBytes - bom.count {
            throw PlanningError.outputTooLarge
        }
        guard let body = assembled.data(using: encoding, allowLossyConversion: false),
              let roundTrip = decode(payload: body, encoding: encoding),
              roundTrip.utf8.elementsEqual(assembled.utf8) else {
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
                                 matches: matches, skipped: nil, approvedRanges: approvedRanges)
    }

    /// Plant genau die stabil gelesene sichtbare Basis einer Transaktions-
    /// Datei und reicht Cancellation bis in die RegEx-Enumeration durch.
    static func planApprovedInput(
        _ input: ApplyTransaction.Input,
        data: Data,
        snapshot: FileSnapshot,
        searchPlan: SearchPlan,
        maximumOutputTextBytes: Int? = nil,
        maximumOutputBytes: Int? = nil,
        shouldCancel: @escaping () -> Bool
    ) throws -> PlannedFileChange {
        if shouldCancel() { throw ApplyError.cancelled }
        guard snapshot == input.snapshot else {
            throw ApplyError.conflict(L10n.format(
                "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.", input.url.lastPathComponent))
        }
        guard let file = try planSingleCancellable(
            url: input.url, data: data, snapshot: snapshot,
            searchPlan: searchPlan, approvedRanges: input.approvedRanges,
            maximumOutputTextBytes: maximumOutputTextBytes, maximumOutputBytes: maximumOutputBytes,
            shouldCancel: shouldCancel
        ) else {
            throw ApplyError.cancelled
        }
        guard file.skipped == nil else {
            if file.skipped == .undecodable, file.encoding != nil {
                throw ApplyError.planNotApplyable(L10n.format("%@: %@", input.url.lastPathComponent,
                    L10n.string("Das Ergebnis enthält Zeichen, die sich in der ursprünglichen Kodierung nicht verlustfrei speichern lassen.")))
            }
            throw ApplyError.planNotApplyable(L10n.format(
                "„%@“ kann nicht auf der sichtbaren Vorschau-Basis ersetzt werden.", input.url.lastPathComponent))
        }
        // Unfreigegebene Treffer bleiben Teil der geprüften Basis. Nur die
        // Ausgabe wird gefiltert; eine Teilfreigabe darf keine Lücke im
        // Snapshot- oder Treffervergleich erzeugen.
        guard file.matches == input.matches,
              input.approvedRanges.map({ $0.isSubset(of: Set(file.matches.map(\.range))) }) != false else {
            throw ApplyError.conflict(L10n.string(
                "Die berechnete Änderung stimmt nicht mehr mit der sichtbaren Vorschau überein. Starte die Suche erneut; es wurde nichts verändert."))
        }
        if file.hasChanges { try checkWritePermission(at: input.url) }
        return file
    }

    static func isWritableTarget(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: url.path)
            && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    static func checkWritePermission(at url: URL) throws {
        guard isWritableTarget(url) else {
            throw ApplyError.planNotApplyable(writePermissionMessage(at: url))
        }
    }

    private static func checkAtomicReplacementSupport(at url: URL) throws {
        let target = URL(fileURLWithPath: url.path)
        let volume = try target.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey])
        // Ohne eindeutige Angabe bleibt der gebundene atomare Tausch maßgeblich.
        if volume.volumeSupportsSwapRenaming == false {
            throw ApplyError.planNotApplyable(L10n.format("%@: %@", url.path,
                AtomicFileCommit.Failure.unsupportedAtomicSwap.localizedDescription))
        }
    }

    static func encodedSize(_ text: String, encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf8: return text.utf8.count
        case .utf16LittleEndian, .utf16BigEndian: return text.utf16.count * 2
        case .utf32LittleEndian, .utf32BigEndian: return text.unicodeScalars.count * 4
        default: return text.unicodeScalars.count
        }
    }

    private static func writePermissionMessage(at url: URL) -> String {
        L10n.format("%@: %@", url.lastPathComponent,
            L10n.string("Die Datei oder ihr Ordner ist schreibgeschützt."))
    }

    // MARK: - Pattern-Bau

    /// Übersetzt `SearchOptions` in eine fertige `NSRegularExpression`.
    /// `wholeWord` und der Plain-Text-Modus werden auf RegEx-Ebene umgesetzt,
    /// damit es nur einen Matching-Pfad gibt.
    static func buildRegex(_ options: SearchOptions) throws -> NSRegularExpression {
        try buildRegex(options, wildcard: nil)
    }

    fileprivate static func buildRegex(
        _ options: SearchOptions,
        wildcard preparedWildcard: WildcardPattern.Compiled?
    ) throws -> NSRegularExpression {
        var pattern: String
        if options.isRegex {
            pattern = options.find
        } else if options.usesWildcard {
            // Platzhalter-Modus: jeder Stern-Lauf → gierige Gruppe
            // (`*` → `(.+)`, `**` → `([\s\S]+)`), der Rest wörtlich escapt.
            // `.dotMatchesLineSeparators` setzen wir bewusst nicht → `.` matcht
            // kein `\n`, der Einzelstern bleibt zeilenweise; nur der
            // Doppelstern fängt über Zeilenumbrüche (via \s\S-Klasse).
            pattern = (preparedWildcard
                ?? WildcardPattern.compileFind(options.find)).regexPattern
        } else {
            // Plain-Text → vollständig escapen, sodass Sonderzeichen
            // wie `.` `*` `(` literal gemeint sind.
            pattern = NSRegularExpression.escapedPattern(for: options.find)
        }
        let unwrappedPattern = pattern
        if options.wholeWord {
            pattern = "\\b(?:" + pattern + ")\\b"
        }
        var opts: NSRegularExpression.Options = []
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: opts)
        } catch {
            guard options.wholeWord, options.isRegex else { throw error }
            // Ein abschließender x-Kommentar verschluckt die Wrapperklammer.
            // Nur bei gültigem Original und fehlgeschlagener Einbettung einen
            // Zeilenabschluss ergänzen; bei ausgeschaltetem x bleibt alles literal.
            _ = try NSRegularExpression(pattern: unwrappedPattern, options: opts)
            return try NSRegularExpression(pattern: "\\b(?:" + unwrappedPattern + "\n)\\b", options: opts)
        }
    }

    /// Liefert den Template-String, der an `regex.replacementString(...)`
    /// geht. Im RegEx-Modus wird die Roh-Eingabe durchgereicht — `$1`,
    /// `$0`, `\n` etc. sind dort gewollte Backref-/Escape-Syntax. Im
    /// Plain-Text-Modus (`isRegex == false`) werden `$` und `\` via
    /// `escapedTemplate` neutralisiert, damit sie literal eingesetzt
    /// werden. Ohne das würde z.B. ein Ersetzungstext „$5.00" als
    /// (leerer) Backref auf Gruppe 5 gedeutet — der Vertrag in
    /// `SearchOptions.replace` verlangt aber literale Ersetzung.
    static func replacementTemplate(for options: SearchOptions) -> String {
        replacementTemplate(for: options, wildcard: nil)
    }

    fileprivate static func replacementTemplate(
        for options: SearchOptions,
        wildcard preparedWildcard: WildcardPattern.Compiled?
    ) -> String {
        if options.isRegex { return options.replace }
        // Platzhalter-Modus: N-tes `*` im Ersetzen → `$N`. Greift
        // nur, wenn die Such-Seite Platzhalter nutzt (gleiche Bedingung), damit
        // ein `*` ohne zugehörige Fanggruppe nicht ins Leere referenziert.
        if options.usesWildcard {
            // Die Zahl der Such-Sterne grenzt gültige Pillen-Verweise ein:
            // `$1` bis `$N` bleiben Rückreferenzen, andere Dollar-Texte literal.
            let wildcard = preparedWildcard
                ?? WildcardPattern.compileFind(options.find)
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
        // UTF-32 muss vor UTF-16 geprüft werden: FF FE 00 00 beginnt sonst
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

    /// Foundation ignoriert bei UTF-16/32 unvollständige Codeeinheiten am
    /// Dateiende. Vor der Dekodierung ablehnen, damit kein Byte still entfällt.
    static func decode(payload: Data, encoding: String.Encoding) -> String? {
        let width: Int
        switch encoding {
        case .utf16, .utf16LittleEndian, .utf16BigEndian: width = 2
        case .utf32, .utf32LittleEndian, .utf32BigEndian: width = 4
        default: width = 1
        }
        guard payload.count.isMultiple(of: width) else { return nil }
        // Die Datei-BOM ist bereits entfernt. Ein weiteres U+FEFF gehört zum
        // Inhalt; Foundations UTF-8-Initialisierer würde es erneut abtrennen.
        if encoding == .utf8 {
            guard String(data: payload, encoding: .utf8) != nil else { return nil }
            return String(decoding: payload, as: UTF8.self)
        }
        return String(data: payload, encoding: encoding)
    }

    /// Versucht, die Nutzdaten in einen String zu dekodieren. Wenn eine
    /// BOM bekannt ist, hat deren Encoding Vorrang. Sonst gilt UTF-8 zuerst;
    /// definierte druckbare C1-Bytes wählen Windows-1252, alle übrigen
    /// Single-Byte-Daten fallen konservativ auf Latin-1 zurück.
    static func decode(payload: Data, bomEncoding: String.Encoding?) -> (String, String.Encoding)? {
        if let enc = bomEncoding {
            guard let s = decode(payload: payload, encoding: enc) else { return nil }
            return (s, enc)
        }
        if let utf8 = decode(payload: payload, encoding: .utf8) {
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
//     tauschen sie über `AtomicFileCommit` gegen die Original-Datei.
//     Jeder erreichbare Stand enthält dadurch vollständige Bytes; der
//     verdrängte Stand bleibt bis zur abschließenden Prüfung erhalten.
//  2. **Vor jedem Apply ein Backup.** Die Original-Bytes jeder zu
//     verändernden Datei wandern vor dem Schreibvorgang in einen
//     zentralen Backup-Ordner (default: `~/Library/Application Support/Fastra/undo/<session>/`).
//     Schlägt der Backup-Schritt fehl, wird nichts geschrieben.
//  3. **Bit-exaktes Undo.** Eine `ApplySession` weiß, welche Original-Datei
//     wohin gesichert wurde. `undo(_:)` spielt die Backups bit-genau über
//     denselben atomaren Austausch zurück.
//
// Was nicht garantiert wird: dass eine Folge-Datei-Schreibung in einem
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
    /// Pfad der Backup-Datei relativ zum Session-Ordner.
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
    /// `pending` wird vor dem Replace persistiert. So kann ein Crash keine
    /// bereits geänderte Datei aus dem Undo-Journal verschwinden lassen.
    let state: State
    /// Neue Einträge halten ihre Ersatz-Inode auch nach pending fest, bis
    /// Rücknahme oder Backup-Ablauf den Eigentumsbeleg nicht mehr brauchen.
    let pendingFile: ApplyPendingFile?

    enum CodingKeys: String, CodingKey {
        case originalPath, backupRelativePath, originalSHA256, encodingRawValue, bom,
             appliedSnapshot, state, pendingFile
    }

    init(originalPath: String, backupRelativePath: String, originalSHA256: String,
         encodingRawValue: UInt? = nil, bom: Data = Data(),
         appliedSnapshot: FileSnapshot?, state: State,
         pendingFile: ApplyPendingFile? = nil) {
        self.originalPath = originalPath
        self.backupRelativePath = backupRelativePath
        self.originalSHA256 = originalSHA256
        self.encodingRawValue = encodingRawValue
        self.bom = bom
        self.appliedSnapshot = appliedSnapshot
        self.state = state
        self.pendingFile = pendingFile
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
        pendingFile = try values.decodeIfPresent(ApplyPendingFile.self, forKey: .pendingFile)
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
    /// Nur Cleanup, keine zusätzlichen Undo-Ziele: etwa nach gescheitertem
    /// Manifest-Rückschritt eines sicher nie angewendeten Eintrags.
    let retainedPendingFiles: [ApplyPendingFile]

    var hasRecoveryWork: Bool { !entries.isEmpty || !retainedPendingFiles.isEmpty }
    var isCleanupOnly: Bool { entries.isEmpty && !retainedPendingFiles.isEmpty }

    func undoResourceURLs(includingRestoredTargets: Bool = true) -> [URL] {
        let targets = entries.filter { includingRestoredTargets || $0.state != .restored }
            .map { URL(fileURLWithPath: $0.originalPath) }
        let cleanup = (retainedPendingFiles + entries.compactMap(\.pendingFile))
            .flatMap(\.cleanupResourceURLs)
        return Array(Set(targets + cleanup)).sorted { $0.path < $1.path }
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, timestamp, sessionDirectory, entries, retainedPendingFiles }

    init(timestamp: Date, sessionDirectory: URL, entries: [UndoEntry],
         schemaVersion: Int = ApplySession.currentSchemaVersion,
         retainedPendingFiles: [ApplyPendingFile] = []) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.sessionDirectory = sessionDirectory
        self.entries = entries
        self.retainedPendingFiles = retainedPendingFiles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        sessionDirectory = try values.decode(URL.self, forKey: .sessionDirectory)
        entries = try values.decode([UndoEntry].self, forKey: .entries)
        retainedPendingFiles = try values.decodeIfPresent([ApplyPendingFile].self,
            forKey: .retainedPendingFiles) ?? []
    }
}

enum ApplyError: LocalizedError, Equatable {
    var errorDescription: String? { TextWorkflowFailure.message(self) }

    /// Plan enthält invalide Patterns oder Skip-Gründe in geänderten Dateien.
    case planNotApplyable(String)
    /// Backup-Schritt fehlgeschlagen — es wurde nichts geschrieben.
    case backupFailed(String)
    /// Ein Ziel lässt sich nicht prüfen oder weicht von der sichtbaren Basis ab.
    case conflict(String)
    /// Ein Undo-Ziel lässt sich nicht prüfen oder wurde seit dem Apply verändert.
    case undoConflict(String)
    /// Älteres Manifest enthält keinen verlässlichen Zustand nach Apply.
    case legacySession(String)
    /// Schreibschritt fehlgeschlagen, partieller Apply. Aufrufer sollte
    /// `undo(_:)` mit der zurückgegebenen Session aufrufen.
    case writeFailed(partial: ApplySession, message: String)
    /// Änderungen oder eigene Aufräumaufträge sind erhalten, ihre ursprüngliche
    /// Ablage ist am bisherigen Pfad aber nicht mehr bestätigt. Erhaltene
    /// Artefakte stehen in der Meldung.
    case recoveryUnavailable(partial: ApplySession, message: String)
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
        beforeAtomicReplace: ((URL) throws -> Void)? = nil,
        afterCleanupClaim: ((URL) throws -> Void)? = nil,
        atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
        manifestWriter: ((ApplySession) throws -> Void)? = nil
    ) throws -> ApplySession {
        guard !transaction.inputs.isEmpty, !transaction.options.isEmpty else {
            throw ApplyError.planNotApplyable(L10n.string("Der Apply-Auftrag ist leer."))
        }
        if shouldCancel() { throw ApplyError.cancelled }
        let searchPlan: SearchPlan
        do {
            searchPlan = try SearchPlan(options: transaction.options)
        } catch {
            throw ApplyError.planNotApplyable((error as NSError).localizedDescription)
        }

        return try executePrepared(
            inputs: transaction.inputs, sourceURL: { $0.url }, sourceSnapshot: { $0.snapshot },
            prepare: { input, data, snapshot in
                let file = try planApprovedInput(
                    input, data: data, snapshot: snapshot,
                    searchPlan: searchPlan, shouldCancel: shouldCancel)
                return PreparedReplacement(originalBytes: file.originalBytes, newBytes: file.newBytes,
                                           encoding: file.encoding, bom: file.bom)
            }, backupRoot: backupRoot, cleanupOlderThan: cleanupOlderThan,
            shouldCancel: shouldCancel, progress: progress, beforePreflight: beforePreflight, folderSourceBasis: transaction.folderSourceBasis,
            beforeAtomicReplace: beforeAtomicReplace, afterCleanupClaim: afterCleanupClaim,
            atomicReplace: atomicReplace, manifestWriter: manifestWriter)
    }

    /// Der Ablaufplan trägt seine vollständigen Original-/Nachherbytes selbst.
    /// Suche und Ablauf teilen danach Preflight, Journal, Austausch und Undo.
    static func execute(
        workflowPlan: TextWorkflowFilePlan,
        backupRoot: URL? = nil,
        cleanupOlderThan: TimeInterval? = 30 * 24 * 60 * 60,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        progress: (ApplyTransaction.Progress) -> Void = { _ in },
        beforePreflight: (() throws -> Void)? = nil,
        beforeAtomicReplace: ((URL) throws -> Void)? = nil,
        afterCleanupClaim: ((URL) throws -> Void)? = nil,
        atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
        manifestWriter: ((ApplySession) throws -> Void)? = nil
    ) throws -> ApplySession {
        guard workflowPlan.changedFileCount > 0 else { throw TextWorkflowFilePlan.Failure.noChanges }
        let byURL = Dictionary(uniqueKeysWithValues: workflowPlan.files.map { ($0.url, $0) })
        func validateBinding(_ file: TextWorkflowFilePlan.File) throws {
            guard file.requestedURL.canonicalFileURL == file.url else {
                throw ApplyError.conflict(L10n.format(
                    "„%@“ wurde während des Apply geändert.", file.requestedURL.lastPathComponent))
            }
            if file.changed { try TextWorkflowFilePlan.requireWritable(file.url) }
        }
        return try executePrepared(
            inputs: workflowPlan.files, sourceURL: { $0.url }, sourceSnapshot: { $0.snapshot },
            prepare: { file, data, _ in
                try validateBinding(file)
                guard data == file.originalBytes else {
                    throw ApplyError.conflict(L10n.format(
                        "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.", file.requestedURL.lastPathComponent))
                }
                return PreparedReplacement(originalBytes: data, newBytes: file.newBytes,
                                           encoding: file.encoding, bom: file.bom)
            }, backupRoot: backupRoot, cleanupOlderThan: cleanupOlderThan,
            shouldCancel: shouldCancel, progress: progress,
            beforePreflight: {
                try beforePreflight?()
                for file in workflowPlan.files { try validateBinding(file) }
            }, beforeAtomicReplace: { url in
                try beforeAtomicReplace?(url)
                if let file = byURL[url] { try validateBinding(file) }
            }, afterCleanupClaim: afterCleanupClaim, atomicReplace: atomicReplace, manifestWriter: manifestWriter)
    }

    private struct PreparedReplacement {
        let originalBytes: Data
        let newBytes: Data
        let encoding: String.Encoding?
        let bom: Data
        var hasChanges: Bool { originalBytes != newBytes }
    }

    private struct StagedFile {
        let url: URL
        let expectedSnapshot: FileSnapshot
        let backupRelativePath: String
        let stagedNewURL: URL
        let originalSHA256: String
        let expectedNewContent: FileSnapshot
        let encodingRawValue: UInt?
        let bom: Data
    }

    private static func readForComparison<Value>(
        from url: URL, conflictMessage: String, failure: (String) -> ApplyError,
        read: () throws -> Value
    ) throws -> Value {
        do {
            return try read()
        } catch is CancellationError {
            throw ApplyError.cancelled
        } catch FileSnapshotReadError.tooLarge,
                FileSnapshotReadError.changedDuringRead,
                FileSnapshotReadError.notRegularFile {
            // Die Vorschau bindet eine reguläre Datei mit fester Größe. Ein
            // Typwechsel oder instabiler/größerer Stand verletzt diese Basis.
            throw failure(conflictMessage)
        } catch {
            throw failure(L10n.format("%@: %@",
                L10n.format("„%@“ konnte nicht gelesen werden", url.lastPathComponent),
                error.localizedDescription))
        }
    }

    private enum FileApplyOutcome {
        case applied(ApplySession)
        case failed(ApplyError, keepSession: Bool)
    }

    // Der Dateischritt entscheidet vollständig über Partial-Session und
    // Aufräumaufträge; die Mehrdateischleife übernimmt nur seinen Endzustand.
    private static func applyStagedFile(
        _ item: StagedFile,
        after beforePending: ApplySession,
        persist: @escaping (ApplySession) throws -> Void,
        barriers: ApplyPersistenceBarriers,
        beforeAtomicReplace: ((URL) throws -> Void)?,
        atomicReplace: ((Data, URL, URL) throws -> Void)?
    ) -> FileApplyOutcome {
        var session = beforePending
        let now = beforePending.timestamp
        let sessionDir = beforePending.sessionDirectory
        let newBytes: Data
        do {
            newBytes = try barriers.readStaged(named: item.stagedNewURL.lastPathComponent,
                expected: item.expectedNewContent)
        } catch {
            let keepSession = !session.entries.isEmpty
            if keepSession {
                return .failed(.writeFailed(
                    partial: session,
                    message: L10n.format("%@: %@", item.url.lastPathComponent,
                                         error.localizedDescription)), keepSession: keepSession)
            }
            return .failed(.backupFailed(L10n.format(
                "Temporäre Datei lesen (%@): %@", item.url.lastPathComponent,
                error.localizedDescription)), keepSession: keepSession)
        }
        let temporaryURL = temporarySiblingURL(for: item.url, purpose: "apply")
        var pendingFile: ApplyPendingFile?
        var temporaryFile: ApplyPendingFile?
        var replacementAttempted = false
        var preserveTemporaryForRecovery = false
        var pendingWasAttempted = false
        func retainPending(descriptor: Int32, snapshot: FileSnapshot) throws {
            let retained = try ApplyPendingFile.retain(
                preparedURL: temporaryURL, descriptor: descriptor, snapshot: snapshot,
                cleanupDirectory: temporaryFile?.cleanupDirectory,
                onCreate: { pendingFile = $0 })
            pendingFile = retained
            try retained.synchronize()
            try barriers.validateBackup(named: URL(fileURLWithPath: item.backupRelativePath).lastPathComponent,
                expected: item.expectedSnapshot)
            let pending = UndoEntry(
                originalPath: item.url.path,
                backupRelativePath: item.backupRelativePath,
                originalSHA256: item.originalSHA256,
                encodingRawValue: item.encodingRawValue, bom: item.bom,
                appliedSnapshot: snapshot, state: .pending, pendingFile: retained)
            let candidate = ApplySession(timestamp: now, sessionDirectory: sessionDir,
                entries: beforePending.entries + [pending],
                retainedPendingFiles: beforePending.retainedPendingFiles
                    + (temporaryFile.map { [$0] } ?? []))
            // Auch ein Writer, der nach seinem Write wirft, darf den
            // Anker nicht vor einem belegten Manifest-Rückschritt lösen.
            session = candidate
            pendingWasAttempted = true
            try persist(candidate)
        }
        do {
            let temporary = try ApplyPendingFile.prepare(newBytes, at: temporaryURL)
            temporaryFile = temporary
            let applied: FileSnapshot = try coordinateReplacing(item.url) { coordinatedURL in
                guard coordinatedURL.standardizedFileURL.path
                        == item.url.standardizedFileURL.path else {
                    throw ApplyError.conflict(L10n.format(
                        "„%@“ wurde während des Apply umbenannt.",
                        item.url.lastPathComponent))
                }
                if let atomicReplace {
                    let current = try FileSnapshot.read(from: coordinatedURL)
                    guard current.snapshot == item.expectedSnapshot else {
                        throw ApplyError.conflict(L10n.format(
                            "„%@“ wurde während des Apply geändert.",
                            item.url.lastPathComponent))
                    }
                    let opened = try FileSnapshot.openRegularFile(at: temporaryURL)
                    defer { close(opened.descriptor) }
                    let prepared = try FileSnapshot.readSnapshotOnly(
                        descriptor: opened.descriptor, fileStat: opened.stat)
                    guard prepared == temporary.snapshot else {
                        throw ApplyError.conflict(L10n.format(
                            "„%@“ wurde während des Apply geändert.", item.url.lastPathComponent))
                    }
                    try retainPending(descriptor: opened.descriptor, snapshot: prepared)
                    try beforeAtomicReplace?(coordinatedURL)
                    try barriers.validateBackup(named: URL(fileURLWithPath: item.backupRelativePath).lastPathComponent,
                        expected: item.expectedSnapshot)
                    try checkWritePermission(at: coordinatedURL)
                    // Der injizierte Testpfad kann nach einer Nebenwirkung
                    // werfen. Dann bleibt `pending` wie bisher erhalten.
                    replacementAttempted = true
                    try atomicReplace(newBytes, coordinatedURL, temporaryURL)
                } else {
                    replacementAttempted = true
                    do {
                        return try AtomicFileCommit.replaceExisting(
                            at: coordinatedURL,
                            withPreparedFile: temporaryURL,
                            expecting: item.expectedSnapshot,
                            replacementContent: temporary.snapshot,
                            retainPreparedFile: retainPending,
                            beforeSwap: { url in
                                try beforeAtomicReplace?(url)
                                try barriers.validateBackup(named: URL(fileURLWithPath: item.backupRelativePath).lastPathComponent,
                                    expected: item.expectedSnapshot)
                                try checkWritePermission(at: url)
                            })
                    } catch let failure as AtomicFileCommit.Failure {
                        preserveTemporaryForRecovery =
                            failure.mustPreservePreparedPath
                        switch failure {
                        case .conflictUnchanged, .conflictRolledBack:
                            replacementAttempted = false
                            throw ApplyError.conflict(L10n.format(
                                "„%@“ wurde während des Apply geändert.",
                                item.url.lastPathComponent))
                        case .unsupportedAtomicSwap:
                            replacementAttempted = false
                            throw ApplyError.conflict(
                                failure.localizedDescription)
                        case .recoveryRequired:
                            // Eine gescheiterte Ankerbindung liegt noch
                            // vor dem pending-Write und damit vor jedem Swap.
                            if !pendingWasAttempted { replacementAttempted = false }
                            throw failure
                        }
                    } catch {
                        // Alle untypisierten Fehler verlassen den
                        // Committer entweder vor dem Swap oder nach einem
                        // vollständig geprüften Rücktausch.
                        replacementAttempted = false
                        throw error
                    }
                }
                let verified = try FileSnapshot.read(from: coordinatedURL)
                guard verified.data == newBytes,
                      verified.snapshot == pendingFile?.snapshot else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return verified.snapshot
            }
            try barriers.validateBackup(named: URL(fileURLWithPath: item.backupRelativePath).lastPathComponent,
                expected: item.expectedSnapshot)
            guard let pending = session.entries.last else {
                throw CocoaError(.fileWriteUnknown)
            }
            let appliedEntry = UndoEntry(
                originalPath: pending.originalPath,
                backupRelativePath: pending.backupRelativePath,
                originalSHA256: pending.originalSHA256,
                encodingRawValue: pending.encodingRawValue,
                bom: pending.bom, appliedSnapshot: applied, state: .applied,
                pendingFile: pendingFile)
            let appliedSession = ApplySession(
                timestamp: now, sessionDirectory: sessionDir,
                entries: Array(session.entries.dropLast()) + [appliedEntry],
                retainedPendingFiles: beforePending.retainedPendingFiles)
            try persist(appliedSession)
            session = appliedSession
            return .applied(session)
        } catch {
            var message = (error as? ApplyError).flatMap { failure -> String? in
                if case .conflict(let message) = failure { return message }
                if case .planNotApplyable(let message) = failure { return message }
                return nil
            } ?? L10n.format("%@: %@", item.url.lastPathComponent,
                              error.localizedDescription)
            if let failure = error as? ApplyPendingFile.PreparationFailure,
               let pending = failure.pendingFile {
                // Prepare hat nie ein Ziel ersetzt. Sein belegter Teilstand
                // muss vor jedem Manifestversuch im RAM übernommen werden.
                session = ApplySession(timestamp: now, sessionDirectory: sessionDir,
                    entries: beforePending.entries,
                    retainedPendingFiles: beforePending.retainedPendingFiles + [pending])
                do { try persist(session) }
                catch {
                    message += "\n" + L10n.format("Manifest schreiben: %@",
                                                   error.localizedDescription) + "\n" + sessionDir.path
                }
                return .failed(.writeFailed(partial: session, message: message), keepSession: true)
            }
            var canFinishRollback = false
            if !replacementAttempted {
                session = beforePending
                if pendingWasAttempted || pendingFile != nil {
                    let rollback = ApplySession(timestamp: now, sessionDirectory: sessionDir,
                        entries: beforePending.entries,
                        retainedPendingFiles: beforePending.retainedPendingFiles
                            + (pendingFile.map { [$0] } ?? [])
                            + (temporaryFile.map { [$0] } ?? []))
                    var rollbackWasPersisted = false
                    do {
                        // Der Rückschritt behält den Cleanup-Pfad selbst
                        // dann, wenn der Prozess gleich danach endet.
                        try persist(rollback)
                        rollbackWasPersisted = true
                        session = rollback
                        try pendingFile?.remove()
                        canFinishRollback = !preserveTemporaryForRecovery
                    } catch {
                        session = rollback
                        // Zweiter Fehler bleibt sichtbar; RAM-Partial und
                        // Backups gehen dabei nicht aus dem Vertrag verloren.
                        message += "\n" + (rollbackWasPersisted
                            ? error.localizedDescription
                            : L10n.format("Manifest schreiben: %@", error.localizedDescription))
                            + "\n" + sessionDir.path
                    }
                }
            }
            if !preserveTemporaryForRecovery {
                do { try temporaryFile?.remove() }
                catch {
                    canFinishRollback = false
                    if let temporaryFile {
                        session = ApplySession(timestamp: now, sessionDirectory: sessionDir,
                            entries: session.entries,
                            retainedPendingFiles: session.retainedPendingFiles
                                + (session.retainedPendingFiles.contains(temporaryFile) ? [] : [temporaryFile]))
                        // Der Cleanup-Pfad bleibt auch über Prozessende
                        // auffindbar; ein weiterer Manifestfehler bleibt sichtbar.
                        do { try persist(session) }
                        catch {
                            message += "\n" + L10n.format("Manifest schreiben: %@",
                                error.localizedDescription)
                        }
                    }
                    message += "\n" + error.localizedDescription + "\n" + sessionDir.path
                }
            }
            if canFinishRollback {
                do {
                    // Erst nach beiden Cleanup-Schritten darf das Manifest
                    // die Aufträge vergessen. Bei Writefehler bleibt der
                    // vollständige Rückschritt im RAM sicher wiederholbar.
                    try persist(beforePending)
                    session = beforePending
                } catch {
                    message += "\n" + L10n.format("Manifest schreiben: %@",
                        error.localizedDescription) + "\n" + sessionDir.path
                }
            }
            let keepSession = !session.entries.isEmpty || replacementAttempted
                || !session.retainedPendingFiles.isEmpty
            if case ApplyError.conflict = error, !keepSession {
                return .failed(.conflict(message), keepSession: keepSession)
            }
            if case ApplyError.planNotApplyable = error, !keepSession {
                return .failed(.planNotApplyable(message), keepSession: keepSession)
            }
            return .failed(.writeFailed(partial: session, message: message),
                           keepSession: keepSession)
        }
    }

    private static func executePrepared<Input>(
        inputs: [Input], sourceURL: (Input) -> URL, sourceSnapshot: (Input) -> FileSnapshot,
        prepare: (Input, Data, FileSnapshot) throws -> PreparedReplacement,
        backupRoot: URL?, cleanupOlderThan: TimeInterval?,
        shouldCancel: @escaping @Sendable () -> Bool,
        progress: (ApplyTransaction.Progress) -> Void,
        beforePreflight: (() throws -> Void)?, folderSourceBasis: FolderSearch.SourceBasis? = nil,
        beforeAtomicReplace: ((URL) throws -> Void)?,
        afterCleanupClaim: ((URL) throws -> Void)?,
        atomicReplace: ((Data, URL, URL) throws -> Void)?, manifestWriter: ((ApplySession) throws -> Void)?
    ) throws -> ApplySession {
        // Testhaken wie beim Undo: `manifestWriter` ersetzt das Schreiben des
        // Journals, `atomicReplace` den atomaren Austausch. Das Produkt
        // übergibt beides nie. `afterCleanupClaim` beobachtet ausschließlich
        // bereits beanspruchte Cleanup-Dateien und bleibt im Produkt nil.
        var preserveArtifacts = false
        let root: URL
        do { root = try ApplyPersistenceBarriers.resolvingRootAliases(backupRoot ?? defaultBackupRoot) }
        catch {
            throw ApplyError.backupFailed(L10n.format(
                "Backup-Ordner anlegen: %@", error.localizedDescription))
        }
        if let maxAge = cleanupOlderThan {
            try? cleanupBackups(maxAge: maxAge, in: root)
        }
        let now = Date()
        let dirName = "session-\(iso8601Compact(now))-\(UUID().uuidString.prefix(8))"
        let sessionDir = root.appendingPathComponent(dirName, isDirectory: true)
        let stagedDir = sessionDir.appendingPathComponent("staged", isDirectory: true)
        let barriers: ApplyPersistenceBarriers
        do { barriers = try ApplyPersistenceBarriers(beforeCreating: sessionDir) }
        catch {
            throw ApplyError.backupFailed(L10n.format(
                "Backup-Ordner anlegen: %@", error.localizedDescription))
        }
        var keepSession = false
        var lastSession: ApplySession?
        func persist(_ candidate: ApplySession) throws {
            do {
                try barriers.validateDirectories()
                let data = try manifestData(candidate)
                if let manifestWriter {
                    try manifestWriter(candidate)
                    try barriers.acknowledgeManifest(data)
                } else { try barriers.writeManifest(data) }
                try barriers.validateDirectories()
            } catch {
                if error is ApplyPersistenceBarriers.Failure { preserveArtifacts = true }
                throw error
            }
        }
        do {
            try barriers.createAndBindDirectories()
        } catch {
            preserveArtifacts = true
            do { try barriers.finish(after: error) }
            catch {
                throw ApplyError.backupFailed(L10n.format(
                    "Backup-Ordner anlegen: %@",
                    ApplyPersistenceBarriers.Failure(primary: error, closeErrors: []).localizedDescription)
                    + "\n" + sessionDir.path)
            }
        }

        do {
            var staged: [StagedFile] = []
            staged.reserveCapacity(inputs.count)
            // Erwarteter Platten-Stand jeder Eingabe — auch der wirkungslosen, die
            // unten übersprungen werden. Der globale Preflight prüft diese Liste,
            // nicht nur `staged`: Sonst bliebe eine Datei, die sich nach ihrer
            // Planung noch ändert, unbemerkt, obwohl die Transaktion zusagt, vor
            // dem ersten Schreiben alle Ziele erneut zu prüfen.
            var expectedOnDisk: [(url: URL, snapshot: FileSnapshot)] = []
            expectedOnDisk.reserveCapacity(inputs.count)
            let total = inputs.count

            // Planung + Backup halten immer nur die aktuelle Datei im Speicher.
            // Der jeweilige Planadapter bestätigt dabei die vollständige Vorschaubasis.
            for (index, input) in inputs.enumerated() {
                if shouldCancel() { throw ApplyError.cancelled }
                let url = sourceURL(input)
                let snapshot = sourceSnapshot(input)
                let conflictMessage = L10n.format(
                    "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
                    url.lastPathComponent)
                let current = try readForComparison(
                    from: url, conflictMessage: conflictMessage, failure: ApplyError.conflict) {
                    try FileSnapshot.read(from: url, byteLimit: UInt64(max(0, snapshot.byteCount)), isCancelled: shouldCancel)
                }
                guard current.snapshot == snapshot else {
                    throw ApplyError.conflict(conflictMessage)
                }
                let file = try prepare(input, current.data, current.snapshot)
                // Nachher-Prüfung und Undo lesen über dieselbe feste Grenze.
                // Eine größere Ausgabe muss vor dem ersten Ziel-Write scheitern.
                guard UInt64(file.newBytes.count) <= FileSnapshot.maximumReadBytes else {
                    throw ApplyError.planNotApplyable(L10n.format(
                        "Die Ersetzung würde „%@“ über die sichere Größe von 256 MiB vergrößern. Es wurde nichts verändert.",
                        url.lastPathComponent))
                }
                expectedOnDisk.append((url: url, snapshot: current.snapshot))
                progress(ApplyTransaction.Progress(
                    phase: .planned, completedFiles: index + 1,
                    totalFiles: total, fileName: url.lastPathComponent))

                // Ergibt die Ersetzung exakt den Ausgangstext (etwa „foo“ → „foo“),
                // entfallen Schreiben, Backup und Sitzungseintrag für diese Datei.
                // Die übrigen Änderungen des Auftrags werden weiterhin ausgeführt.
                guard file.hasChanges else { continue }
                try checkWritePermission(at: url)

                let backupRelativePath = "files/\(index).bin"
                let stagedNewURL = stagedDir.appendingPathComponent("\(index).bin")
                do {
                    try barriers.prepare(file.originalBytes, named: "\(index).bin", staged: false)
                    try barriers.prepare(file.newBytes, named: "\(index).bin", staged: true)
                } catch {
                    preserveArtifacts = true
                    throw ApplyError.backupFailed(L10n.format(
                        "Backup vorbereiten (%@): %@", url.lastPathComponent,
                        error.localizedDescription))
                }
                staged.append(StagedFile(
                    url: url, expectedSnapshot: current.snapshot,
                    backupRelativePath: backupRelativePath,
                    stagedNewURL: stagedNewURL,
                    originalSHA256: current.snapshot.sha256,
                    expectedNewContent: FileSnapshot(data: file.newBytes, identity: nil),
                    encodingRawValue: file.encoding?.rawValue, bom: file.bom))
                progress(ApplyTransaction.Progress(
                    phase: .backedUp, completedFiles: index + 1,
                    totalFiles: total, fileName: url.lastPathComponent))
            }

            // Ändert sich durch die Ersetzung keine einzige Datei, ist der Auftrag
            // als Ganzes wirkungslos — das bleibt eine ehrliche Ablehnung statt
            // eines Erfolgs ohne jede Wirkung.
            guard !staged.isEmpty else {
                throw ApplyError.planNotApplyable(L10n.string(
                    "Keine der Dateien ändert sich durch diese Ersetzung. Es wurde nichts verändert."))
            }

            try beforePreflight?()

            do {
                for item in staged {
                    if shouldCancel() { throw ApplyError.cancelled }
                    try barriers.synchronizeBackup(
                        named: URL(fileURLWithPath: item.backupRelativePath).lastPathComponent,
                        expected: item.expectedSnapshot)
                }
                try barriers.synchronizeDirectories()
            } catch ApplyError.cancelled {
                throw ApplyError.cancelled
            } catch {
                // Ein beobachteter unbekannter Ablagestand gibt auch nach einem
                // späteren erfolgreichen Manifest-Rückschritt keine Löschvollmacht.
                preserveArtifacts = true
                throw ApplyError.backupFailed(L10n.format(
                    "Backup vorbereiten (%@): %@", sessionDir.lastPathComponent,
                    ApplyPersistenceBarriers.Failure(primary: error, closeErrors: []).localizedDescription)
                    + "\n" + sessionDir.path)
            }

            // Alle Ziele noch einmal prüfen, bevor auch nur ein Ziel verändert
            // wird. Der Durchlauf liest weiterhin nur eine Datei gleichzeitig.
            for item in expectedOnDisk {
                if shouldCancel() { throw ApplyError.cancelled }
                let conflictMessage = L10n.format(
                    "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
                    item.url.lastPathComponent)
                let current = try readForComparison(
                    from: item.url, conflictMessage: conflictMessage, failure: ApplyError.conflict) {
                    try FileSnapshot.readSnapshotOnly(from: item.url, byteLimit: UInt64(max(0, item.snapshot.byteCount)),
                                                      isCancelled: shouldCancel)
                }
                guard current == item.snapshot else {
                    throw ApplyError.conflict(conflictMessage)
                }
            }
            for item in staged {
                if shouldCancel() { throw ApplyError.cancelled }
                try checkWritePermission(at: item.url)
                try checkAtomicReplacementSupport(at: item.url)
            }
            do {
                try folderSourceBasis?.validate(shouldCancel: shouldCancel)
            } catch is CancellationError {
                throw ApplyError.cancelled
            } catch {
                throw ApplyError.conflict(error.localizedDescription)
            }
            if shouldCancel() { throw ApplyError.cancelled }

            var session = ApplySession(timestamp: now,
                                       sessionDirectory: sessionDir, entries: [])
            do {
                try persist(session)
            } catch {
                // Auch der leere erste Write kann bereits veröffentlicht sein.
                // Er enthält noch keinen rückgängig zu machenden Zieleintrag.
                preserveArtifacts = true
                throw ApplyError.backupFailed(L10n.format(
                    "Manifest schreiben: %@", error.localizedDescription) + "\n" + sessionDir.path)
            }

            for (index, item) in staged.enumerated() {
                switch applyStagedFile(item, after: session, persist: persist, barriers: barriers,
                                      beforeAtomicReplace: beforeAtomicReplace,
                                      atomicReplace: atomicReplace) {
                case .applied(let appliedSession):
                    session = appliedSession
                    lastSession = session
                    progress(ApplyTransaction.Progress(
                        phase: .applied, completedFiles: index + 1,
                        totalFiles: total, fileName: item.url.lastPathComponent))
                case .failed(let error, let retainSession):
                    keepSession = retainSession
                    throw error
                }
            }

            keepSession = true
            // Auch nach dem letzten wirksamen Austausch und dem letzten
            // Fortschrittscallback muss die angebotene Undo-Basis erreichbar sein.
            for item in staged {
                try barriers.validateBackup(named: URL(fileURLWithPath: item.backupRelativePath).lastPathComponent,
                    expected: item.expectedSnapshot)
            }
            do { try barriers.cleanup(keepingSession: true, afterClaim: afterCleanupClaim) }
            catch {
                preserveArtifacts = true
                throw ApplyError.writeFailed(partial: session, message: L10n.format(
                    "Zusätzlicher Fehler beim Sichern oder Aufräumen: %@",
                    ApplyPersistenceBarriers.Failure(primary: error, closeErrors: []).localizedDescription))
            }
            try barriers.validateDirectories()
            try barriers.finish()
            return session
        } catch {
            if barriers.isFinished {
                if let lastSession {
                    let message = error.localizedDescription + "\n" + L10n.format(
                        "Bestätigt angewendete Dateien:\n%@", lastSession.entries.map(\.originalPath).joined(separator: "\n"))
                        + "\n" + lastSession.sessionDirectory.path
                    throw ApplyError.writeFailed(partial: lastSession, message: message)
                }
                throw ApplyError.backupFailed(error.localizedDescription)
            }
            var message: String
            let partial: ApplySession?
            switch error {
            case ApplyError.writeFailed(let session, let detail): partial = session; message = detail
            case ApplyError.backupFailed(let detail), ApplyError.conflict(let detail),
                 ApplyError.planNotApplyable(let detail): partial = lastSession; message = detail
            default: partial = lastSession; message = error.localizedDescription
            }
            var bindingFailure = false
            do { try barriers.validateDirectories() }
            catch {
                bindingFailure = true
                preserveArtifacts = true
                message += "\n" + L10n.string("Die Sicherungsablage wurde während des Apply verändert. Der Vorgang wurde angehalten.") + "\n" + sessionDir.path
            }
            func validateRecovery() throws {
                guard let partial, partial.hasRecoveryWork else { return }
                let needsBackups = !partial.entries.isEmpty
                try barriers.validateRecoveryDirectories(requiringBackups: needsBackups)
                for entry in partial.entries {
                    let backup = try readBackup(for: entry, in: partial.sessionDirectory)
                    guard backup.sha256 == entry.originalSHA256 else {
                        throw backupContentMismatch(for: entry, in: partial.sessionDirectory)
                    }
                }
                try barriers.validateRecoveryDirectories(requiringBackups: needsBackups)
            }
            // Unsichere Originale müssen schon vor jedem Cleanup erhalten bleiben.
            do { try validateRecovery() }
            catch {
                preserveArtifacts = true
                if case ApplyError.backupFailed(let detail) = error { message += "\n" + detail }
            }
            if !preserveArtifacts {
                do { try barriers.cleanup(keepingSession: keepSession || partial?.hasRecoveryWork == true,
                    afterClaim: afterCleanupClaim) }
                catch {
                    preserveArtifacts = true
                    message += "\n" + L10n.format("Zusätzlicher Fehler beim Sichern oder Aufräumen: %@", error.localizedDescription)
                }
            }
            func appendRetainedArtifacts() {
                let originals = barriers.reachableBackupPaths()
                if !originals.isEmpty {
                    message += "\n" + L10n.format("Erreichbare unveränderte Originalsicherungen:\n%@", originals.joined(separator: "\n"))
                }
                let pending = partial.map { $0.retainedPendingFiles + $0.entries.compactMap(\.pendingFile) } ?? []
                let temporaryPaths = Array(Set(pending.filter(\.isValid).map { $0.url.path })).sorted()
                if !temporaryPaths.isEmpty {
                    message += "\n" + L10n.format("Erreichbare temporäre Wiederherstellungsdateien:\n%@", temporaryPaths.joined(separator: "\n"))
                }
                let paths = barriers.reachableDirectoryPaths()
                message += "\n" + (paths.isEmpty
                    ? L10n.string("Kein ursprünglicher Sicherungsordner ist unter einem geprüften Pfad erreichbar.")
                    : L10n.format("Erreichbare ursprüngliche Sicherungsordner (Stand der Fehlerprüfung):\n%@",
                        paths.joined(separator: "\n")))
            }
            let artifactsWereReported = preserveArtifacts
            if artifactsWereReported { appendRetainedArtifacts() }
            var recoveryReachable = true
            // Cleanup arbeitet an gebundenen FDs weiter, auch wenn der öffentliche
            // Session-/files-Name inzwischen ersetzt wurde. Die letzte positive
            // Undo-Zusage muss deshalb nach Cleanup und Diagnose erneut gelten.
            do { try validateRecovery() }
            catch {
                recoveryReachable = false
                preserveArtifacts = true
                if case ApplyError.backupFailed(let detail) = error, !message.contains(detail) {
                    message += "\n" + detail
                }
                if !artifactsWereReported { appendRetainedArtifacts() }
            }
            do { try barriers.finish() }
            catch { message += "\n" + error.localizedDescription }
            if let partial {
                let applied = partial.entries.filter { $0.state == .applied }.map(\.originalPath)
                let pending = partial.entries.filter { $0.state == .pending }.map(\.originalPath)
                if !applied.isEmpty { message += "\n" + L10n.format("Bestätigt angewendete Dateien:\n%@", applied.joined(separator: "\n")) }
                if !pending.isEmpty { message += "\n" + L10n.format("Noch nicht abschließend geprüfte Dateien:\n%@", pending.joined(separator: "\n")) }
                if !recoveryReachable {
                    if partial.isCleanupOnly {
                        let notice = L10n.string("Die Sicherungsablage wurde während des Apply verändert. Der Vorgang wurde angehalten.")
                        if !message.contains(notice) { message += "\n" + notice }
                    } else {
                        message += "\n" + L10n.string("Unter dem bisherigen Pfad ist keine verlässlich erreichbare Rückgängig-Basis bestätigt. Erhaltene Sicherungen und temporäre Dateien wurden nicht gelöscht.")
                    }
                    throw ApplyError.recoveryUnavailable(partial: partial, message: message)
                }
                throw ApplyError.writeFailed(partial: partial, message: message)
            }
            if bindingFailure || preserveArtifacts { throw ApplyError.backupFailed(message) }
            throw error
        }
    }

    /// Wendet einen Plan über den produktiven Transaktionskern
    /// (`execute(transaction:)`) an. Auch Tests dieses Einstiegs durchlaufen
    /// damit denselben Backup-/Journal-/Schreibpfad.
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
        // Skip-Reasons wie `.invalidPattern` signalisieren „auch nicht
        // versuchen" und bleiben ein harter Fehler; andere Skips (binär,
        // nicht dekodierbar) werden wie bisher schlicht nicht angefasst.
        for file in plan.files {
            if case .invalidPattern(let msg) = file.skipped {
                throw ApplyError.planNotApplyable(L10n.format("ungültige RegEx: %@", msg))
            }
        }
        let inputs = plan.files
            .filter { $0.skipped == nil }
            .compactMap { file -> ApplyTransaction.Input? in
                guard let snapshot = file.originalSnapshot else { return nil }
                return ApplyTransaction.Input(url: file.url, snapshot: snapshot,
                                              matches: file.matches, approvedRanges: file.approvedRanges)
            }
        let transaction = ApplyTransaction(inputs: inputs, options: plan.options)
        return try execute(transaction: transaction,
                           backupRoot: backupRoot,
                           cleanupOlderThan: cleanupOlderThan,
                           shouldCancel: { false },
                           progress: { _ in },
                           atomicReplace: atomicReplace,
                           manifestWriter: manifestWriter)
    }

    /// Liest eine Backup-Datei über den gehärteten Deskriptor-Pfad statt über
    /// `Data(contentsOf:)`.
    ///
    /// Der Hash-Vergleich unten schützt den Inhalt, aber er kommt zu spät für
    /// den Speicher: Ein beschädigtes oder ausgetauschtes Backup könnte
    /// beliebig groß sein und wäre längst vollständig eingelesen, bevor der
    /// Hash überhaupt gebildet wird. `FileSnapshot.read` prüft deshalb schon
    /// beim Öffnen Typ (nur reguläre Dateien) und Größe (256-MiB-Grenze) am
    /// selben Deskriptor, aus dem gelesen wird — ein Backup-Ordner, den ein
    /// Fremder gegen einen Verweis auf eine Riesendatei tauscht, kann den
    /// Rückgängig-Lauf so nicht mehr über den Speicher kippen
    ///
    /// Legitime Backups bleiben unberührt: Sie entstehen aus Dateien, die
    /// Suche und Apply selbst über dieselbe 256-MiB-Grenze gelesen haben.
    /// Typ-, Größen- und Versionsfehler behalten ihre Cocoa-Abbildung.
    /// Andere Lesefehler nennen das Dokument und die betroffene Sicherung.
    ///
    /// Der Hash kommt aus dem Snapshot des Lesevorgangs und wird deshalb
    /// zurückgegeben: Ein zweites `sha256Hex` über dieselben Bytes wäre reine
    /// doppelte Rechenarbeit.
    private static func readBackup(for entry: UndoEntry, in directory: URL,
                                   recovery: ApplyPersistenceBarriers.RecoveryValidation? = nil) throws
        -> (bytes: Data, sha256: String) {
        let url = directory.appendingPathComponent(entry.backupRelativePath)
        do {
            try recovery?.validateBackup(entry.backupRelativePath)
            let read = try FileSnapshot.read(from: url)
            try recovery?.validateBackup(entry.backupRelativePath, readSnapshot: read.snapshot)
            return (read.data, read.snapshot.sha256)
        } catch FileSnapshotReadError.tooLarge {
            throw CocoaError(.fileReadTooLarge)
        } catch FileSnapshotReadError.notRegularFile {
            throw CocoaError(.fileReadUnknown)
        } catch FileSnapshotReadError.changedDuringRead {
            throw CocoaError(.fileReadCorruptFile)
        } catch {
            let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error ?? error
            throw ApplyError.backupFailed(L10n.format(
                "Die Sicherung für „%@“ konnte nicht gelesen werden: %@\n%@",
                URL(fileURLWithPath: entry.originalPath).lastPathComponent,
                cause.localizedDescription, url.path))
        }
    }

    private static func backupContentMismatch(for entry: UndoEntry, in directory: URL) -> ApplyError {
        .backupFailed(L10n.format(
            "Die Sicherung für „%@“ stimmt nicht mit dem Original überein.\n%@",
            URL(fileURLWithPath: entry.originalPath).lastPathComponent,
            directory.appendingPathComponent(entry.backupRelativePath).path))
    }

    /// Spielt eine Apply-Session bit-genau zurück. Atomar pro Datei.
    /// Hash-Check warnt, wenn das Backup beschädigt ist.
    @discardableResult
    static func undo(_ session: ApplySession,
                     beforeAtomicReplace: ((URL) throws -> Void)? = nil,
                     atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
                     manifestWriter: ((ApplySession) throws -> Void)? = nil,
                     verifiedOriginal: ((URL, FileSnapshot) -> Void)? = nil) throws -> ApplySession {
        try undoSession(session, beforeAtomicReplace: beforeAtomicReplace,
                        atomicReplace: atomicReplace, manifestWriter: manifestWriter, verifiedOriginal: verifiedOriginal)
    }

    /// Nur für die erneut bestätigte historische Sitzung. Der Caller hält den
    /// Anspruch über Pfadreservierung, Undo und anschließendes Neuladen hinweg.
    @discardableResult
    static func undoRecovery(_ session: ApplySession, holding claim: ApplyRecoveryDirectoryClaim,
                             expectedManifest: FileSnapshot,
                             expectedBackups: [String: FileSnapshot],
                             beforeAtomicReplace: ((URL) throws -> Void)? = nil,
                             afterCleanupClaim: ((URL) throws -> Void)? = nil,
                             verifiedOriginal: ((URL, FileSnapshot) -> Void)? = nil) throws -> ApplySession {
        let recovery = try ApplyPersistenceBarriers.RecoveryValidation(session: session, holding: claim,
            expectedManifest: expectedManifest, expectedBackups: expectedBackups)
        do {
            let restored = try undoSession(session, beforeAtomicReplace: beforeAtomicReplace,
                recovery: recovery, afterCleanupClaim: afterCleanupClaim, verifiedOriginal: verifiedOriginal)
            try recovery.finish()
            return restored
        } catch { try recovery.finish(after: error) }
    }

    private static func undoSession(_ session: ApplySession,
                                    beforeAtomicReplace: ((URL) throws -> Void)? = nil,
                                    atomicReplace: ((Data, URL, URL) throws -> Void)? = nil,
                                    manifestWriter: ((ApplySession) throws -> Void)? = nil,
                                    recovery: ApplyPersistenceBarriers.RecoveryValidation? = nil,
                                    afterCleanupClaim: ((URL) throws -> Void)? = nil,
                                    verifiedOriginal: ((URL, FileSnapshot) -> Void)? = nil) throws -> ApplySession {
        try recovery?.validate()
        guard session.schemaVersion == ApplySession.currentSchemaVersion,
              !session.entries.contains(where: { $0.state == .legacy || $0.appliedSnapshot == nil }) else {
            throw ApplyError.legacySession(L10n.string(
                "Diese Rückgängig-Session verwendet ein nicht kompatibles Sicherheitsformat und wird deshalb nicht automatisch angewendet."))
        }

        func persist(_ candidate: ApplySession) throws {
            if let recovery { try recovery.writeManifest(manifestData(candidate)) }
            else if let manifestWriter { try manifestWriter(candidate) }
            else { try writeManifest(candidate) }
        }

        func remove(_ file: ApplyPendingFile?) throws {
            guard let file else { return }
            try recovery?.validate()
            try file.remove(afterClaim: recovery.map { validation in
                { url in
                    try validation.validate()
                    try afterCleanupClaim?(url)
                    try validation.validate()
                }
            })
            try recovery?.validate()
        }

        func replacing(_ session: ApplySession, index: Int,
                       with entry: UndoEntry) -> ApplySession {
            var entries = session.entries
            entries[index] = entry
            return ApplySession(timestamp: session.timestamp,
                                sessionDirectory: session.sessionDirectory,
                                entries: entries,
                                schemaVersion: session.schemaVersion,
                                retainedPendingFiles: session.retainedPendingFiles)
        }

        // Wie beim Apply zuerst alle Backups und Ziele prüfen. Pending-
        // Einträge brauchen für Ersatzbytes zusätzlich die gebundene,
        // weiterhin über ihren Anker erreichbare Identität. Originalbytes
        // gelten ohne Write als restauriert. Alles andere bleibt Konflikt.
        var working = session
        var persisted = session
        func conflictError(_ message: String) -> ApplyError {
            if persisted.entries.contains(where: { $0.state == .restored }) {
                return .undoFailed(partial: persisted, message: message)
            }
            return .undoConflict(message)
        }
        var prepared: [Int] = []
        for index in working.entries.indices {
            let entry = working.entries[index]
            // Bereits restaurierte Einträge vor jedem Backup-Zugriff
            // überspringen: Ihr Backup wird nicht mehr gebraucht, und ein
            // fehlendes oder beschädigtes Backup eines längst erledigten
            // Eintrags darf das restliche Rückgängig nicht blockieren
            if entry.state == .restored { continue }
            // Die Bytes leben nur für diesen Schleifendurchlauf; die
            // Schreibphase unten liest sie sequenziell erneut. Vorher lagen
            // alle Backups gleichzeitig im Speicher.
            let (backupBytes, backupSHA256) = try readBackup(for: entry, in: session.sessionDirectory, recovery: recovery)
            // Sanity: stimmt der Hash noch? Wenn nicht, wurde der Backup-
            // Ordner manipuliert — wir brechen ab, statt potenziell
            // falsche Bytes zurückzuspielen.
            guard backupSHA256 == entry.originalSHA256 else {
                throw backupContentMismatch(for: entry, in: session.sessionDirectory)
            }

            let target = URL(fileURLWithPath: entry.originalPath)
            let conflictMessage = L10n.format(
                "„%@“ wurde nach dem Apply geändert. Rückgängig wurde abgebrochen.",
                target.lastPathComponent)
            let current = try readForComparison(
                from: target, conflictMessage: conflictMessage, failure: conflictError) {
                try FileSnapshot.read(from: target)
            }
            guard let expectedApplied = entry.appliedSnapshot else {
                throw conflictError(conflictMessage)
            }

            if current.snapshot.sha256 == entry.originalSHA256,
               current.data == backupBytes {
                verifiedOriginal?(target, current.snapshot)
                let restored = UndoEntry(originalPath: entry.originalPath,
                                         backupRelativePath: entry.backupRelativePath,
                                         originalSHA256: entry.originalSHA256,
                                         encodingRawValue: entry.encodingRawValue,
                                         bom: entry.bom,
                                         appliedSnapshot: entry.appliedSnapshot,
                                         state: .restored, pendingFile: entry.pendingFile)
                working = replacing(working, index: index, with: restored)
                continue
            }

            let appliedMatches = current.snapshot == expectedApplied
                && (entry.state != .pending
                    || (expectedApplied.identity != nil
                        && entry.pendingFile?.snapshot == expectedApplied
                        && entry.pendingFile?.isValid == true))
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
                                         state: .applied, pendingFile: entry.pendingFile)
                working = replacing(working, index: index, with: resolved)
            }
            guard isWritableTarget(target) else {
                throw conflictError(writePermissionMessage(at: target))
            }
            prepared.append(index)
        }

        if working != session || !working.retainedPendingFiles.isEmpty {
            try persist(working)
            persisted = working
        }
        // Alle Ziele sind geprüft; ein RAM-Partial mit Cleanup-Resten muss
        // zuerst das möglicherweise ältere Plattenmanifest ablösen.
        do {
            for file in working.retainedPendingFiles { try remove(file) }
            for entry in working.entries where entry.state == .restored {
                try remove(entry.pendingFile)
            }
        } catch {
            throw ApplyError.undoFailed(partial: working, message: error.localizedDescription)
        }

        for index in prepared {
            let entry = working.entries[index]
            guard let appliedSnapshot = entry.appliedSnapshot else {
                throw ApplyError.legacySession(L10n.string(
                    "Diese Rückgängig-Session verwendet ein nicht kompatibles Sicherheitsformat und wird deshalb nicht automatisch angewendet."))
            }
            let target = URL(fileURLWithPath: entry.originalPath)
            let tmp = temporarySiblingURL(for: target, purpose: "undo")
            var preserveTemporaryForRecovery = false
            defer {
                if !preserveTemporaryForRecovery {
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
            do {
                // Backup erst jetzt lesen (eine Datei nach der anderen) und
                // den Hash erneut prüfen: Zwischen Prüf- und Schreibphase
                // darf niemand den Backup-Ordner ausgetauscht haben.
                let (backupBytes, backupSHA256) = try readBackup(for: entry, in: session.sessionDirectory, recovery: recovery)
                guard backupSHA256 == entry.originalSHA256 else {
                    throw backupContentMismatch(for: entry, in: session.sessionDirectory)
                }
                // Wieder vor der finalen Zielprüfung vorbereiten: große
                // Backup-Bytes verlängern das TOCTOU-Fenster nicht.
                try backupBytes.write(to: tmp, options: .atomic)
                var replaceCompleted = false
                try coordinateReplacing(target) { coordinatedURL in
                    guard coordinatedURL.standardizedFileURL.path
                            == target.standardizedFileURL.path else {
                        throw ApplyError.undoConflict(L10n.format(
                            "„%@“ wurde während Rückgängig umbenannt.",
                            target.lastPathComponent))
                    }
                    if let atomicReplace {
                        let current = try FileSnapshot.read(from: coordinatedURL)
                        guard current.snapshot == entry.appliedSnapshot else {
                            throw ApplyError.undoConflict(L10n.format(
                                "„%@“ wurde während Rückgängig geändert.",
                                target.lastPathComponent))
                        }
                        try beforeAtomicReplace?(coordinatedURL)
                        try recovery?.validateBackup(entry.backupRelativePath)
                        guard isWritableTarget(coordinatedURL) else {
                            throw ApplyError.undoConflict(writePermissionMessage(at: coordinatedURL))
                        }
                        try atomicReplace(backupBytes, coordinatedURL, tmp)
                    } else {
                        do {
                            let snapshot = try AtomicFileCommit.replaceExisting(
                                at: coordinatedURL,
                                withPreparedFile: tmp,
                                expecting: appliedSnapshot,
                                replacementContent: FileSnapshot(
                                    data: backupBytes, identity: nil),
                                beforeSwap: { url in
                                    try beforeAtomicReplace?(url)
                                    try recovery?.validateBackup(entry.backupRelativePath)
                                    guard isWritableTarget(url) else {
                                        throw ApplyError.undoConflict(writePermissionMessage(at: url))
                                    }
                                })
                            // Der Dateitausch ist bereits bestätigt, auch wenn
                            // anschließend das Manifest nicht geschrieben wird.
                            verifiedOriginal?(target, snapshot)
                        } catch let failure as AtomicFileCommit.Failure {
                            preserveTemporaryForRecovery =
                                failure.mustPreservePreparedPath
                            switch failure {
                            case .conflictUnchanged, .conflictRolledBack:
                                throw ApplyError.undoConflict(L10n.format(
                                    "„%@“ wurde während Rückgängig geändert.",
                                    target.lastPathComponent))
                            case .unsupportedAtomicSwap:
                                throw ApplyError.undoConflict(
                                    failure.localizedDescription)
                            case .recoveryRequired:
                                throw failure
                            }
                        }
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
                                         state: .restored, pendingFile: entry.pendingFile)
                let restoredSession = replacing(working, index: index, with: restored)
                // Bei Manifestfehler bleibt der persistierte Applied-Zustand;
                // der nächste Lauf erkennt die bereits originalen Bytes und
                // setzt den Eintrag ohne erneuten Write auf restored.
                try persist(restoredSession)
                working = restoredSession
                persisted = restoredSession
                try remove(entry.pendingFile)
            } catch let error as ApplyError {
                if case .undoConflict(let message) = error {
                    throw conflictError(message)
                }
                if case .backupFailed(let message) = error {
                    // Der geprüfte Klartext (z. B. Hash-Abweichung) ist die
                    // ehrliche Meldung — `localizedDescription` eines rohen
                    // Enum-Fehlers wäre nur Foundation-Kauderwelsch.
                    throw ApplyError.undoFailed(partial: working, message: message)
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
        try recovery?.validate()
        return working
    }

    /// Räumt Session-Ordner auf, die älter sind als `maxAge` Sekunden.
    /// Nur Verzeichnisse mit dem Präfix `session-` werden betrachtet —
    /// fremde Dateien im Backup-Root bleiben unangetastet.
    static func cleanupBackups(maxAge: TimeInterval, in backupRoot: URL? = nil) throws {
        let fm = FileManager.default
        let requestedRoot = backupRoot ?? defaultBackupRoot
        guard fm.fileExists(atPath: requestedRoot.path) else { return }
        let root = try ApplyPersistenceBarriers.resolvingRootAliases(requestedRoot)
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries where url.lastPathComponent.hasPrefix("session-") {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = values?.contentModificationDate ?? .distantFuture
            guard mtime < cutoff,
                  let claim = try? ApplyRecoveryDirectoryClaim(root: root,
                    sessionName: url.lastPathComponent) else { continue }
            defer { try? claim.finish() }
            do {
                // Nach der Auflistung kann eine Rücknahme die Verzeichniszeit erneuert haben.
                guard try claim.isOlder(than: cutoff) else { continue }
                let manifest = try claim.readManifestForCleanup()
                if let manifest {
                    let session = try JSONDecoder().decode(ApplySession.self, from: manifest.data)
                    guard !session.entries.contains(where: { $0.state == .pending }) else { continue }
                    guard ApplyRecoverySessionReader.hasValidCleanupReferences(session) else { continue }
                    let pendingFiles = session.retainedPendingFiles + session.entries.compactMap(\.pendingFile)
                    for file in pendingFiles {
                        try claim.validateBinding()
                        try file.remove()
                    }
                }
                try claim.removeExpiredDirectory(olderThan: cutoff, expectedManifest: manifest?.version)
            } catch {
                // Ein ungeklärter Anker behält sein Manifest samt Backup.
                continue
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

    private static func manifestData(_ session: ApplySession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(session)
    }

    static func writeManifest(_ session: ApplySession) throws {
        try ApplyPersistenceBarriers.writeManifest(manifestData(session), in: session.sessionDirectory)
    }

    /// Lädt eine zuvor gespeicherte Session aus ihrem Manifest. Nützlich,
    /// um nach App-Neustart ein Undo zu bauen.
    static func loadSession(at directory: URL) throws -> ApplySession {
        let url = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ApplySession.self, from: data)
    }

    /// Sibling statt Session-Temp: Der atomare Austausch bleibt damit auch
    /// dann auf einem Volume, wenn Application Support und Ziel auf
    /// verschiedenen Datenträgern liegen.
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
        coordinator.coordinate(writingItemAt: target, options: [],
                               error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}
