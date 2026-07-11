// ApplySafetyTests.swift
//
// Gerüst für das HARTE Apply-Sicherheits-Gate (v0.6). Multi-File-Replace ist
// potenziell zerstörerisch — laut AGENTS.md MÜSSEN diese Tests stehen, BEVOR
// die Apply-Logik geschrieben wird.
//
// Was hier JETZT schon grün läuft: die Bausteine, die ohne Apply-Engine
// existieren — Binär-Erkennung, Encoding-/Line-Ending-Erkennung und die
// Integrität des Test-Korpus. Die apply-abhängigen Verträge (Dry-Run,
// atomare Writes, „außerhalb Scope unverändert", bit-exaktes Undo) sind
// unten als ausdrückliches TODO markiert und werden mit der Apply-Logik
// implementiert.

import Testing
import Foundation
@testable import Fastra

// MARK: - Test-Korpus-Integrität

@Test("Korpus erzeugt Text- und Binärdateien")
func corpus_builds() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    #expect(corpus.files.count == 10)
    #expect(!corpus.textFiles.isEmpty)
    #expect(corpus.binaryFiles.count == 2)
    // Alle Dateien liegen wirklich auf der Platte.
    for file in corpus.files {
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }
}

// MARK: - Binär-Erkennung (Baustein für Binär-Schutz)

@Test("Echte Binärdateien werden als binär erkannt")
func binary_detectsBinaries() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    for file in corpus.binaryFiles {
        #expect(FileScanner.isBinary(file.bytes) == true)
        #expect(FileScanner.isBinaryFile(at: file.url) == true)
    }
}

@Test("Einbyte-Textdateien gelten nicht als binär")
func binary_textIsNotBinary() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    for name in ["utf8-lf.txt", "utf8-crlf.txt", "latin1.txt", "win1252.txt", "empty.txt"] {
        let url = corpus.root.appendingPathComponent(name)
        #expect(FileScanner.isBinaryFile(at: url) == false, "\(name) sollte Text sein")
    }
}

@Test("UTF-16-Text triggert die naive Null-Byte-Heuristik (dokumentierter Sonderfall)")
func binary_utf16IsNaivelyBinary() throws {
    // Wichtig fürs Apply-Gate: UTF-16/32 enthält Null-Bytes. Die Binär-
    // Heuristik allein würde solche Dateien überspringen. Daher MUSS beim
    // Suchen/Apply zuerst eine BOM-/Encoding-Erkennung laufen. Dieser Test
    // hält den Sonderfall bewusst fest, damit niemand ihn vergisst.
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf16le.txt")
    #expect(FileScanner.isBinaryFile(at: url) == true)
}

// MARK: - Line-Ending-Erkennung (Baustein)

@Test("Line-Endings werden korrekt erkannt")
func lineEndings_detected() {
    #expect(LineEnding.detect(in: "a\nb\n") == .lf)
    #expect(LineEnding.detect(in: "a\r\nb\r\n") == .crlf)
    #expect(LineEnding.detect(in: "a\rb\r") == .cr)
}

// MARK: - APPLY-GATE Stufe 1: Dry-Run (v0.6)
//
// Diese Tests sichern den nicht-destruktiven Teil: der Plan beschreibt
// Änderungen korrekt, ohne Bytes oder mtime der Eingabedateien zu
// verändern. Die destruktive Stufe (echte Writes, atomarer Replace,
// Undo-Backup) folgt erst, wenn diese Gruppe komplett grün ist.

// MARK: 1. Dry-Run berührt keine Datei

@Test("plan() ändert weder Bytes noch mtime der Eingabedateien")
func dryRun_doesNotMutateFiles() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    // Snapshot vor dem Plan-Lauf.
    let fm = FileManager.default
    let before: [(URL, Data, Date)] = try corpus.files.map { f in
        let data = try Data(contentsOf: f.url)
        let attrs = try fm.attributesOfItem(atPath: f.url.path)
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        return (f.url, data, mtime)
    }
    // Plan ausführen — sollte rein lesend sein.
    let options = SearchOptions(find: "foo", replace: "FOO",
                                isRegex: false, caseSensitive: true)
    _ = ApplyEngine.plan(files: corpus.files.map { $0.url }, options: options)
    // Snapshot nach dem Lauf vergleichen.
    for (url, oldData, oldMtime) in before {
        let newData = try Data(contentsOf: url)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let newMtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        #expect(newData == oldData, "Bytes verändert in \(url.lastPathComponent)")
        #expect(newMtime == oldMtime, "mtime verändert in \(url.lastPathComponent)")
    }
}

// MARK: 2. Treffer-Vollständigkeit

@Test("plan() findet alle Treffer in many.txt (50 Zeilen × 2 = 100)")
func plan_countsAllMatches() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("many.txt")
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "foo", replace: "FOO",
                                                       isRegex: false, caseSensitive: true))
    #expect(plan.totalMatches == 100)
    #expect(plan.changedFiles.count == 1)
}

// MARK: 3. Binärdateien werden übersprungen

@Test("plan() überspringt Binärdateien mit Grund .binary")
func plan_skipsBinaries() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let urls = corpus.binaryFiles.map { $0.url }
    let plan = ApplyEngine.plan(files: urls,
                                options: SearchOptions(find: "text", replace: "BOOM",
                                                       isRegex: false))
    #expect(plan.files.count == urls.count)
    for file in plan.files {
        #expect(file.skipped == .binary, "\(file.url.lastPathComponent) sollte als binär markiert sein")
        #expect(file.newBytes == file.originalBytes, "Binärdateien dürfen keine newBytes haben")
    }
}

// MARK: 4. UTF-16 mit BOM wird NICHT als binär verworfen

@Test("plan() behandelt UTF-16-Text korrekt (BOM vor Binär-Heuristik)")
func plan_handlesUtf16WithBom() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf16le.txt")
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "Hallo", replace: "Hello",
                                                       isRegex: false))
    let file = try #require(plan.files.first)
    #expect(file.skipped == nil, "UTF-16 darf NICHT als binär gelten")
    #expect(file.matches.count == 1)
    #expect(file.encoding == .utf16LittleEndian)
    // BOM muss vorne stehen bleiben.
    #expect(file.newBytes.prefix(2) == Data([0xFF, 0xFE]))
    // Round-Trip: newBytes lassen sich wieder als UTF-16 dekodieren.
    let payload = file.newBytes.dropFirst(2)
    let decoded = String(data: Data(payload), encoding: .utf16LittleEndian)
    #expect(decoded == "Hello Welt\nasdf\n")
}

// MARK: 5. Latin-1 round-trippt byte-exakt

@Test("plan() erhält Latin-1-Bytes (kein UTF-8-Drift)")
func plan_preservesLatin1Bytes() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("latin1.txt")
    // Ersetzung „Café" → „Cafe": bleibt darstellbar in Latin-1.
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "Café", replace: "Cafe",
                                                       isRegex: false))
    let file = try #require(plan.files.first)
    #expect(file.skipped == nil)
    #expect(file.encoding == .isoLatin1)
    // Bytes außerhalb der Ersetzung müssen identisch sein. Wir prüfen
    // den Anfang („Grüße aus München - "), der in Latin-1 spezifische
    // Bytes wie 0xFC (ü), 0xDF (ß) hat — gerade die wollen wir schützen.
    let prefix = "Grüße aus München - ".data(using: .isoLatin1)!
    #expect(file.newBytes.prefix(prefix.count) == prefix)
}

// MARK: 6. Leere Datei: kein Treffer, keine Änderung

@Test("plan() lässt leere Datei unverändert")
func plan_emptyFileUnchanged() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("empty.txt")
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "irgendwas", replace: "x",
                                                       isRegex: false))
    let file = try #require(plan.files.first)
    #expect(file.matches.isEmpty)
    #expect(file.newBytes == file.originalBytes)
    #expect(file.hasChanges == false)
}

// MARK: 7. Line-Endings bleiben erhalten

@Test("plan() lässt nicht-Treffer-Bytes intakt — CRLF wird nicht zu LF")
func plan_preservesLineEndings() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf8-crlf.txt")
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "Zwei", replace: "TWO",
                                                       isRegex: false))
    let file = try #require(plan.files.first)
    #expect(file.skipped == nil)
    #expect(file.matches.count == 1)
    // Datei muss weiterhin CRLF-getrennt sein.
    let after = String(data: file.newBytes, encoding: .utf8)
    #expect(after == "Eins\r\nTWO\r\nDrei\r\n")
}

// MARK: 8. Plain-Text-Modus interpretiert Meta-Zeichen literal

@Test("Plain-Text-Modus: '.' ist Punkt, nicht beliebiges Zeichen")
func plan_plainTextEscapesMeta() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    // Inhalt: "Zeile A\nZeile B\nkunde@example.com\n"
    // RegEx-Modus: 'k.nde' würde matchen. Plain-Text: nur literales 'k.nde'.
    let regexPlan = ApplyEngine.plan(files: [url],
                                     options: SearchOptions(find: "k.nde", replace: "X",
                                                            isRegex: true))
    let plainPlan = ApplyEngine.plan(files: [url],
                                     options: SearchOptions(find: "k.nde", replace: "X",
                                                            isRegex: false))
    #expect(regexPlan.totalMatches == 1)
    #expect(plainPlan.totalMatches == 0)
}

// MARK: 8b. Plain-Text-Modus setzt auch den REPLACE-String literal ein

@Test("Plain-Text-Replace: '$1' steht wörtlich, wird nicht als Backref gedeutet")
func plan_plainTextReplaceDollarIsLiteral() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    // Inhalt: "Zeile A\nZeile B\nkunde@example.com\n"
    // RegEx aus → der Replace-String "$1!" soll WÖRTLICH stehen. Früher
    // wurde „$1" als (leerer) Backref auf Gruppe 1 interpretiert und
    // verschluckt → „!" statt „$1!".
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "Zeile", replace: "$1!",
                                                       isRegex: false, caseSensitive: true))
    let file = try #require(plan.files.first)
    #expect(file.skipped == nil)
    #expect(file.matches.count == 2)
    #expect(file.matches.allSatisfy { $0.after == "$1!" })
    let after = String(data: file.newBytes, encoding: .utf8)
    #expect(after == "$1! A\n$1! B\nkunde@example.com\n")
}

@Test("replacementTemplate escapt nur im Plain-Text-Modus")
func replacementTemplate_escapesOnlyInPlainMode() {
    let regexOpts = SearchOptions(find: "x", replace: "$1\\n", isRegex: true)
    let plainOpts = SearchOptions(find: "x", replace: "$1\\n", isRegex: false)
    // RegEx-Modus: Roh-Template unverändert durchgereicht.
    #expect(ApplyEngine.replacementTemplate(for: regexOpts) == "$1\\n")
    // Plain-Modus: `$` und `\` werden escapt → re-eingesetzt als Literal.
    let escaped = ApplyEngine.replacementTemplate(for: plainOpts)
    #expect(escaped != "$1\\n")
    #expect(escaped == NSRegularExpression.escapedTemplate(for: "$1\\n"))
}

// MARK: 9. Ungültige RegEx → invalidPattern, niemals Apply

@Test("Ungültige RegEx markiert ALLE Dateien als invalidPattern")
func plan_invalidRegexAbortsCleanly() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let urls = corpus.textFiles.map { $0.url }
    let plan = ApplyEngine.plan(files: urls,
                                options: SearchOptions(find: "(unbalanced", replace: "x",
                                                       isRegex: true))
    #expect(plan.files.count == urls.count)
    for file in plan.files {
        if case .invalidPattern = file.skipped { continue }
        Issue.record("Datei \(file.url.lastPathComponent) hätte invalidPattern sein müssen")
    }
    #expect(plan.changedFiles.isEmpty)
}

// MARK: 10. Case-Sensitivity

@Test("caseSensitive=false matched Groß-/Kleinschreibung")
func plan_caseInsensitive() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    let sensitive = ApplyEngine.plan(files: [url],
                                     options: SearchOptions(find: "zeile", replace: "X",
                                                            isRegex: false, caseSensitive: true))
    let insensitive = ApplyEngine.plan(files: [url],
                                       options: SearchOptions(find: "zeile", replace: "X",
                                                              isRegex: false, caseSensitive: false))
    #expect(sensitive.totalMatches == 0)
    #expect(insensitive.totalMatches == 2)
}

// MARK: 11. Whole-Word verhindert Substring-Treffer

@Test("wholeWord schließt 'foo' in 'foobar' aus")
func plan_wholeWordExcludesSubstring() throws {
    // Eigener Mini-Korpus, damit der Test sich nicht auf many.txt verlässt.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-wholeword-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("words.txt")
    try "foo foobar foo".data(using: .utf8)!.write(to: url)
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "foo", replace: "X",
                                                       isRegex: false, caseSensitive: true,
                                                       wholeWord: true))
    #expect(plan.totalMatches == 2)
    let file = try #require(plan.files.first)
    let after = String(data: file.newBytes, encoding: .utf8)
    #expect(after == "X foobar X")
}

// MARK: 12. Capture-Group-Backrefs im Replace ($1)

@Test("RegEx-Modus löst $1-Backrefs auf")
func plan_capturesAreInterpolated() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    // E-Mail-Pattern: kunde@example.com → kunde[at]example.com
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "([a-z]+)@([a-z]+)",
                                                       replace: "$1[at]$2",
                                                       isRegex: true))
    let file = try #require(plan.files.first)
    let after = String(data: file.newBytes, encoding: .utf8)
    #expect(after?.contains("kunde[at]example") == true)
}

// MARK: - APPLY-GATE Stufe 2: Write (echte Schreib-Vorgänge)
//
// Hier wird wirklich auf die Platte geschrieben — aber nur in einen
// frischen Temp-Korpus, der nach jedem Test gelöscht wird. Backup-Wurzel
// wird ebenfalls überschrieben (NIE der echte ~/Library-Pfad).

/// Liefert einen isolierten Backup-Root für einen einzelnen Test.
private func makeBackupRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: W1. apply() schreibt erwartete Bytes atomar

@Test("apply() ersetzt die Original-Bytes durch newBytes")
func apply_writesNewBytes() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    let url = corpus.root.appendingPathComponent("many.txt")
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "foo", replace: "FOO",
                                                       isRegex: false, caseSensitive: true))
    let session = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
    let after = try Data(contentsOf: url)
    let expected = String(repeating: "FOO bar FOO\n", count: 50).data(using: .utf8)!
    #expect(after == expected)
    #expect(session.entries.count == 1)
}

// MARK: W2. Backup enthält Original-Bytes mit korrektem Hash

@Test("apply() legt vor dem Schreiben ein Backup mit korrektem Hash an")
func apply_backupContainsOriginals() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    let original = try Data(contentsOf: url)
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "Zeile", replace: "Line",
                                                       isRegex: false))
    let session = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
    let entry = try #require(session.entries.first)
    let backupURL = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
    let backupBytes = try Data(contentsOf: backupURL)
    #expect(backupBytes == original)
    #expect(entry.originalPath == url.path)
}

// MARK: W3. Bit-exaktes Undo

@Test("undo() macht apply() bit-exakt rückgängig")
func undo_restoresOriginalBytes() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    // Mehrere Dateien gleichzeitig modifizieren, dann komplett undo.
    let targets = ["utf8-lf.txt", "utf8-crlf.txt", "many.txt", "latin1.txt"].map {
        corpus.root.appendingPathComponent($0)
    }
    let snapshotBefore = try targets.map { try Data(contentsOf: $0) }
    let plan = ApplyEngine.plan(files: targets,
                                options: SearchOptions(find: "e", replace: "X",
                                                       isRegex: false, caseSensitive: false))
    let session = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
    // Nach Apply: anders.
    for (i, url) in targets.enumerated() {
        let now = try Data(contentsOf: url)
        if plan.files[i].hasChanges {
            #expect(now != snapshotBefore[i], "\(url.lastPathComponent) sollte verändert sein")
        }
    }
    // Nach Undo: bit-exakt wie vorher.
    try ApplyEngine.undo(session)
    for (i, url) in targets.enumerated() {
        let restored = try Data(contentsOf: url)
        #expect(restored == snapshotBefore[i], "\(url.lastPathComponent) NICHT bit-exakt wiederhergestellt")
    }
}

// MARK: W4. Dateien außerhalb des Plans bleiben unangetastet

@Test("apply() berührt keine Dateien, die nicht im Plan sind")
func apply_leavesOtherFilesUntouched() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    let target = corpus.root.appendingPathComponent("many.txt")
    let untouched = ["utf8-lf.txt", "latin1.txt", "image.bin", "empty.txt"].map {
        corpus.root.appendingPathComponent($0)
    }
    let snapshot: [(URL, Data, Date)] = try untouched.map {
        let data = try Data(contentsOf: $0)
        let attrs = try FileManager.default.attributesOfItem(atPath: $0.path)
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        return ($0, data, mtime)
    }
    // Nur many.txt wird geplant + applied.
    let plan = ApplyEngine.plan(files: [target],
                                options: SearchOptions(find: "foo", replace: "FOO",
                                                       isRegex: false, caseSensitive: true))
    _ = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)

    for (url, oldData, oldMtime) in snapshot {
        let newData = try Data(contentsOf: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let newMtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        #expect(newData == oldData, "Fremde Datei verändert: \(url.lastPathComponent)")
        #expect(newMtime == oldMtime, "Fremde mtime verändert: \(url.lastPathComponent)")
    }
}

// MARK: W5. Plan mit invalidPattern verhindert Apply

@Test("apply() lehnt Plan mit invalidPattern ab")
func apply_refusesInvalidPlan() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    let snapshot = try Data(contentsOf: url)
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "(unbalanced", replace: "x",
                                                       isRegex: true))
    do {
        _ = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
        Issue.record("Apply hätte werfen müssen")
    } catch ApplyError.planNotApplyable {
        // OK.
    }
    // Datei garantiert unverändert.
    #expect(try Data(contentsOf: url) == snapshot)
}

// MARK: W6. Manifest persistiert + lädt zurück

@Test("Manifest wird geschrieben und ist über loadSession() lesbar")
func apply_manifestRoundtrip() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    let url = corpus.root.appendingPathComponent("utf8-lf.txt")
    let plan = ApplyEngine.plan(files: [url],
                                options: SearchOptions(find: "Zeile", replace: "Line",
                                                       isRegex: false))
    let session = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
    let manifestURL = session.sessionDirectory.appendingPathComponent("manifest.json")
    #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    let reloaded = try ApplyEngine.loadSession(at: session.sessionDirectory)
    #expect(reloaded.entries == session.entries)
}

// MARK: W7. Cleanup räumt alte Sessions auf

@Test("cleanupBackups() entfernt Sessions älter als die Frist")
func cleanup_removesOldSessions() throws {
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    // Drei Pseudo-Sessions anlegen, eine davon „alt" datieren.
    let fm = FileManager.default
    let oldDir = backups.appendingPathComponent("session-OLD")
    let newDir = backups.appendingPathComponent("session-NEW")
    let foreign = backups.appendingPathComponent("not-a-session")
    for d in [oldDir, newDir, foreign] {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
    }
    // mtime der „alten" Session 10 Tage zurück.
    let oldDate = Date().addingTimeInterval(-10 * 24 * 60 * 60)
    try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldDir.path)

    try ApplyEngine.cleanupBackups(maxAge: 24 * 60 * 60, in: backups)

    #expect(!fm.fileExists(atPath: oldDir.path), "Alte Session sollte weg sein")
    #expect(fm.fileExists(atPath: newDir.path), "Junge Session muss bleiben")
    #expect(fm.fileExists(atPath: foreign.path), "Fremde Ordner dürfen nicht angefasst werden")
}

// MARK: W8. Pro-Datei-Atomarität (kein halb beschriebenes File)

@Test("apply() lässt nach erfolgreichem Schreiben keine Temp-Dateien neben der Original-Datei")
func apply_doesNotLeakTempFilesNextToOriginal() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }

    let url = corpus.root.appendingPathComponent("many.txt")
    _ = try ApplyEngine.apply(
        plan: ApplyEngine.plan(files: [url],
                               options: SearchOptions(find: "foo", replace: "FOO",
                                                      isRegex: false, caseSensitive: true)),
        backupRoot: backups, cleanupOlderThan: nil)
    // Im Korpus-Verzeichnis darf keine *.tmp / .bak-Datei zurückbleiben.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: corpus.root.path)
    for name in siblings {
        #expect(!name.hasPrefix("tmp-") && !name.hasSuffix(".tmp") && !name.hasSuffix(".bak"),
                "Verdächtige Datei: \(name)")
    }
}
