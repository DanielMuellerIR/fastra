// Die Tests prüfen Planung ohne Schreibzugriff, unveränderte Dateien
// außerhalb des freigegebenen Umfangs und bytegenaue Wiederherstellung.
// Fehler vor und nach dem Tausch müssen fremde Änderungen erhalten und
// den offenen Cleanup über persistierte Sessions fortsetzen können.

import Testing
import Foundation
import Darwin
@testable import Fastra

@Test("Apply lehnt nach der Vorschau veränderte temporäre Ausgaben ab",
      arguments: [0, 1])
func transactionRejectsAlteredStagingBytes(failureIndex: Int) throws {
    let directory = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: directory) }
    let targets = directory.appendingPathComponent("targets", isDirectory: true)
    let backups = directory.appendingPathComponent("backups", isDirectory: true)
    try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true)
    let files = ["first.txt", "second.txt"].map { targets.appendingPathComponent($0) }
    let originals = [Data("foo one".utf8), Data("foo two".utf8)]
    for (file, bytes) in zip(files, originals) { try bytes.write(to: file) }
    let originalSnapshots = try files.map { try FileSnapshot.readSnapshotOnly(from: $0) }
    let transaction = try makeTransaction(files: files)
    #expect(transaction.inputs.map(\.url) == files)
    var sessionDirectory: URL?
    var backupSnapshots: [FileSnapshot] = []
    var progress: [ApplyTransaction.Progress] = []
    var partial: ApplySession?
    do {
        _ = try transaction.execute(backupRoot: backups, cleanupOlderThan: nil,
            progress: { progress.append($0) }, beforePreflight: {
                let session = try #require(FileManager.default.contentsOfDirectory(
                    at: backups, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("session-") })
                sessionDirectory = session
                backupSnapshots = try files.indices.map {
                    try FileSnapshot.readSnapshotOnly(
                        from: session.appendingPathComponent("files/\($0).bin"))
                }
                // Gleiche Länge: allein die Größenprüfung reicht nicht.
                try Data("BAD two".utf8).write(
                    to: session.appendingPathComponent("staged/\(failureIndex).bin"))
            })
        Issue.record("Die veränderte Stagingdatei hätte Apply abbrechen müssen")
    } catch ApplyError.backupFailed(let message) {
        #expect(failureIndex == 0)
        #expect(message.contains(files[failureIndex].lastPathComponent))
    } catch ApplyError.writeFailed(let session, let message) {
        #expect(failureIndex == 1)
        #expect(message.contains(files[failureIndex].lastPathComponent))
        partial = session
    }
    let sessionDir = try #require(sessionDirectory)
    // Extern überschriebene Ausgaben sind kein eigener Cleanupauftrag mehr.
    #expect(try Data(contentsOf: sessionDir.appendingPathComponent("staged/\(failureIndex).bin")) == Data("BAD two".utf8))
    let appliedProgress = progress.filter { $0.phase == .applied }
    #expect(appliedProgress == (failureIndex == 0 ? [] : [ApplyTransaction.Progress(
        phase: .applied, completedFiles: 1, totalFiles: 2, fileName: files[0].lastPathComponent)]))
    #expect(try FileSnapshot.readSnapshotOnly(from: files[1]) == originalSnapshots[1])
    #expect(try Data(contentsOf: files[1]) == originals[1])
    if failureIndex == 0 {
        #expect(partial == nil)
        #expect(try FileSnapshot.readSnapshotOnly(from: files[0]) == originalSnapshots[0])
        #expect(try Data(contentsOf: files[0]) == originals[0])
        #expect(FileManager.default.fileExists(atPath: sessionDir.path))
        #expect(try files.indices.map { try FileSnapshot.readSnapshotOnly(
            from: sessionDir.appendingPathComponent("files/\($0).bin")) } == backupSnapshots)
    } else {
        let session = try #require(partial)
        #expect(session.sessionDirectory.resolvingSymlinksInPath() == sessionDir.resolvingSymlinksInPath())
        #expect(session.entries.map(\.originalPath) == [files[0].path])
        #expect(session.entries.map(\.state) == [.applied])
        #expect(session.retainedPendingFiles.isEmpty)
        #expect(try ApplyEngine.loadSession(at: sessionDir) == session)
        let anchor = try #require(session.entries[0].pendingFile)
        #expect(anchor.isValid)
        #expect(try FileSnapshot.readSnapshotOnly(from: files[0]) == anchor.snapshot)
        #expect(try Data(contentsOf: files[0]) == Data("bar one".utf8))
        let backupURLs = files.indices.map { sessionDir.appendingPathComponent("files/\($0).bin") }
        #expect(try backupURLs.map { try FileSnapshot.readSnapshotOnly(from: $0) } == backupSnapshots)
        #expect(try backupURLs.map { try Data(contentsOf: $0) } == originals)
        let undone = try ApplyEngine.undo(session)
        #expect(undone.entries.map(\.state) == [.restored])
        #expect(try Data(contentsOf: files[0]) == originals[0])
        #expect(try FileSnapshot.readSnapshotOnly(from: files[1]) == originalSnapshots[1])
        #expect(try backupURLs.map { try FileSnapshot.readSnapshotOnly(from: $0) } == backupSnapshots)
        #expect(!FileManager.default.fileExists(atPath: anchor.url.path))
        #expect(!FileManager.default.fileExists(atPath: try #require(anchor.cleanupClaimURL).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(anchor.cleanupDirectory).url.path))
    }
    // Kein Nachbar, Anker oder privater Arbeitsordner bleibt im Zielordner.
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: targets.path))
        == Set(files.map(\.lastPathComponent)))
}

@Test("Apply lehnt Ausgaben über der Undo-Grenze vor jedem Dateischreiben ab")
func transactionRejectsOutputBeyondUndoLimit() throws {
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }
    let target = backups.appendingPathComponent("target.txt")
    try Data("foo".utf8).write(to: target)
    let options = SearchOptions(find: "foo",
        replace: String(repeating: "b", count: Int(FileSnapshot.maximumReadBytes) + 1),
        isRegex: false)
    let transaction = try makeTransaction(files: [target], options: options)
    do {
        _ = try transaction.execute(backupRoot: backups, cleanupOlderThan: nil)
        Issue.record("Die zu große Ersetzung wurde ausgeführt")
    } catch ApplyError.planNotApplyable { }
    let current = try FileSnapshot.read(from: target, byteLimit: 16)
    #expect(current.data == Data("foo".utf8))
}

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
    // Heuristik allein würde solche Dateien überspringen. Daher muss beim
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

@Test("plan()/apply()/undo() behandeln UTF-32 LE und BE symmetrisch und bytegenau")
func plan_applyUndoHandlesUtf32BothEndiannesses() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-utf32-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let variants: [(String.Encoding, Data, String)] = [
        (.utf32LittleEndian, Data([0xFF, 0xFE, 0x00, 0x00]), "le"),
        (.utf32BigEndian, Data([0x00, 0x00, 0xFE, 0xFF]), "be"),
    ]
    for (encoding, bom, name) in variants {
        let url = directory.appendingPathComponent("\(name).txt")
        var original = bom
        original.append(try #require("Hallo Welt\n".data(using: encoding)))
        try original.write(to: url)
        let plan = ApplyEngine.plan(
            files: [url],
            options: SearchOptions(find: "Hallo", replace: "Guten Tag",
                                   isRegex: false, caseSensitive: true))
        let file = try #require(plan.files.first)
        #expect(file.encoding == encoding)
        #expect(file.bom == bom)
        #expect(file.matches.count == 1)
        #expect(file.newBytes.starts(with: bom))
        #expect((file.newBytes.count - bom.count).isMultiple(of: 4))

        let session = try ApplyEngine.apply(plan: plan, backupRoot: backups,
                                            cleanupOlderThan: nil)
        let entry = try #require(session.entries.first)
        #expect(entry.encodingRawValue == encoding.rawValue)
        #expect(entry.bom == bom)
        let payload = try Data(contentsOf: url).dropFirst(bom.count)
        #expect(String(data: Data(payload), encoding: encoding) == "Guten Tag Welt\n")
        _ = try ApplyEngine.undo(session)
        #expect(try Data(contentsOf: url) == original)
    }
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

@Test("Windows-1252-C1-Zeichen wählen CP1252 vor Latin-1 und roundtrippen")
func plan_detectsWindows1252BeforeLatin1() throws {
    let corpus = try TestCorpus()
    defer { corpus.cleanup() }
    let url = corpus.root.appendingPathComponent("win1252.txt")
    let plan = ApplyEngine.plan(
        files: [url],
        options: SearchOptions(find: "„test“", replace: "„fertig“",
                               isRegex: false, caseSensitive: true))
    let file = try #require(plan.files.first)
    #expect(file.encoding == .windowsCP1252)
    #expect(file.matches.count == 1)
    #expect(String(data: file.newBytes, encoding: .windowsCP1252)
            == "Anführungszeichen „fertig“\n")
    #expect(file.newBytes.contains(0x84))
    #expect(file.newBytes.contains(0x93))
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
    // RegEx aus → der Replace-String "$1!" soll wörtlich stehen. Früher
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
    let dir = testTemporaryDirectory()
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

@Test("Ganzwort-Apply ersetzt nur vollständige Alternativen mit unveränderten Captures")
func apply_wholeWordAlternationPreservesCaptures() throws {
    let directory = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("words.txt")
    let original = Data("foobar xbar foo bar".utf8)
    try original.write(to: url)
    let options = SearchOptions(find: "(foo)|(bar)", replace: "$2/$1",
                                isRegex: true, caseSensitive: true, wholeWord: true)
    let plan = ApplyEngine.plan(files: [url], options: options)
    let file = try #require(plan.files.first)
    #expect(file.matches.map(\.range) == [NSRange(location: 12, length: 3),
                                       NSRange(location: 16, length: 3)])
    #expect(file.matches.map(\.after) == ["/foo", "bar/"])
    #expect(file.newBytes == Data("foobar xbar /foo bar/".utf8))
    #expect(try Data(contentsOf: url) == original)

    let transaction = try makeTransaction(files: [url], options: options)
    _ = try transaction.execute(backupRoot: directory, cleanupOlderThan: nil)
    #expect(try Data(contentsOf: url) == file.newBytes)
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
// wird ebenfalls überschrieben (nie der echte ~/Library-Pfad).

/// Liefert einen isolierten Backup-Root für einen einzelnen Test.
private func makeBackupRoot() throws -> URL {
    let url = testTemporaryDirectory()
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

// MARK: W9. Plan- und Undo-Konflikte brechen vor dem ersten Write ab

@Test("apply() bricht bei einem seit der Planung geänderten Ziel vollständig ab")
func apply_staleTargetDoesNotStartTransaction() throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-stale-apply-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = dir.appendingPathComponent("first.txt")
    let second = dir.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let plan = ApplyEngine.plan(
        files: [first, second],
        options: SearchOptions(find: "foo", replace: "bar", isRegex: false,
                               caseSensitive: true))

    let external = Data("external second".utf8)
    try external.write(to: second, options: .atomic)

    #expect(throws: ApplyError.self) {
        _ = try ApplyEngine.apply(plan: plan, backupRoot: backups,
                                  cleanupOlderThan: nil)
    }
    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == external)
    #expect((try FileManager.default.contentsOfDirectory(atPath: backups.path)).isEmpty)
}

@Test("undo() überschreibt keine Änderung nach dem Apply und startet nicht partiell")
func undo_changedTargetAbortsBeforeFirstRestore() throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-stale-undo-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = dir.appendingPathComponent("first.txt")
    let second = dir.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let session = try ApplyEngine.apply(
        plan: ApplyEngine.plan(
            files: [first, second],
            options: SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                   caseSensitive: true)),
        backupRoot: backups, cleanupOlderThan: nil)
    let firstApplied = try Data(contentsOf: first)
    let external = Data("external after apply".utf8)
    try external.write(to: second, options: .atomic)

    #expect(throws: ApplyError.self) {
        try ApplyEngine.undo(session)
    }
    #expect(try Data(contentsOf: first) == firstApplied,
            "Undo darf vor dem Konflikt-Preflight keine frühere Datei restaurieren")
    #expect(try Data(contentsOf: second) == external)
}

private enum ApplyTestFailure: Error { case injected }

@Test("partielle Apply-Session enthält nur wirklich geschriebene Dateien")
func apply_partialSessionExcludesNeverWrittenTargets() throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-partial-apply-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = dir.appendingPathComponent("first.txt")
    let second = dir.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let plan = ApplyEngine.plan(
        files: [first, second],
        options: SearchOptions(find: "foo", replace: "bar", isRegex: false,
                               caseSensitive: true))
    let laterSecond = Data("later untouched target".utf8)

    var writes = 0
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.apply(
            plan: plan, backupRoot: backups, cleanupOlderThan: nil,
            atomicReplace: { _, target, temporary in
                writes += 1
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                if writes == 1 {
                    // Der zweite Zielkonflikt entsteht sicher vor dessen
                    // Replace-Aufruf. Nur so ist belastbar bewiesen, dass die
                    // Datei nie angewendet wurde und aus Partial/Undo gehört.
                    try laterSecond.write(to: second, options: .atomic)
                }
            })
        Issue.record("Der Konflikt vor dem zweiten Write hätte fehlschlagen müssen")
    } catch ApplyError.writeFailed(let session, _) {
        partial = session
    }
    let session = try #require(partial)
    #expect(session.entries.map(\.originalPath) == [first.path])

    try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == laterSecond,
            "Nie angewendete Ziele dürfen nicht in Undo geraten")
}

@Test("Apply verwirft pending nach einem Fehler vor dem atomaren Tausch")
func apply_preSwapFailureExcludesNeverWrittenTarget() throws {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-apply-pre-swap-failure-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = directory.appendingPathComponent("target.txt")
    let original = Data("foo\n".utf8)
    try original.write(to: target)
    let transaction = try makeTransaction(files: [target])

    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            beforeAtomicReplace: { _ in throw ApplyTestFailure.injected })
        Issue.record("Der injizierte Fehler vor dem Swap hätte Apply abbrechen müssen")
    } catch ApplyError.backupFailed {
        Issue.record("Der Commit-Fehler darf nicht als Backup-Fehler erscheinen")
    } catch ApplyError.writeFailed(let partial, _) {
        #expect(partial.entries.isEmpty)
    }

    #expect(try Data(contentsOf: target) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

@Test("Crash-Fenster nach Replace bleibt als pending manifestiert und rückgängig")
func apply_manifestFailureAfterReplaceRecoversPendingEntry() throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-pending-apply-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = dir.appendingPathComponent("target.txt")
    let original = Data("foo".utf8)
    try original.write(to: target)
    let plan = ApplyEngine.plan(
        files: [target],
        options: SearchOptions(find: "foo", replace: "bar", isRegex: false,
                               caseSensitive: true))

    var manifestWrites = 0
    do {
        _ = try ApplyEngine.apply(
            plan: plan, backupRoot: backups, cleanupOlderThan: nil,
            manifestWriter: { session in
                manifestWrites += 1
                if manifestWrites == 3 { throw ApplyTestFailure.injected }
                try ApplyEngine.writeManifest(session)
            })
        Issue.record("Manifest-Failpoint nach Replace hätte werfen müssen")
    } catch ApplyError.writeFailed(let partial, _) {
        #expect(partial.entries.count == 1)
        #expect(partial.entries[0].state == .pending)
    }
    #expect(try Data(contentsOf: target) == Data("bar".utf8))

    let recovered = try ApplyEngine.loadSession(
        at: try #require(FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil).first))
    #expect(recovered.entries[0].state == .pending)
    let retained = try #require(recovered.entries[0].pendingFile)
    #expect(retained.isValid)
    #expect(recovered.entries[0].appliedSnapshot == retained.snapshot)
    #expect(try FileSnapshot.readSnapshotOnly(from: target) == retained.snapshot)
    _ = try ApplyEngine.undo(recovered)
    #expect(!FileManager.default.fileExists(atPath: retained.url.path))
    #expect(try Data(contentsOf: target) == original)
}

@Test("Apply behält pending, wenn Replace erst schreibt und dann fehlschlägt")
func apply_replaceFailureAfterSideEffectKeepsPendingEntry() throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-replace-side-effect-\(UUID().uuidString)",
                                isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: dir,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = dir.appendingPathComponent("target.txt")
    let original = Data("foo".utf8)
    try original.write(to: target)
    let plan = ApplyEngine.plan(
        files: [target],
        options: SearchOptions(find: "foo", replace: "bar", isRegex: false,
                               caseSensitive: true))

    var partial: ApplySession?
    do {
        _ = try ApplyEngine.apply(
            plan: plan, backupRoot: backups, cleanupOlderThan: nil,
            atomicReplace: { _, target, temporary in
                _ = try FileManager.default.replaceItemAt(target,
                                                           withItemAt: temporary)
                throw ApplyTestFailure.injected
            })
        Issue.record("Fehler nach wirksamem Replace hätte weitergereicht werden müssen")
    } catch ApplyError.writeFailed(let session, _) {
        partial = session
    }

    let session = try #require(partial)
    #expect(session.entries.map(\.state) == [.pending])
    #expect(try Data(contentsOf: target) == Data("bar".utf8))
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == session)
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: target) == original)
}

@Test("Partielles Undo persistiert Fortschritt und setzt beim Retry fort")
func undo_partialFailureResumesFromPersistedState() throws {
    let dir = testTemporaryDirectory()
        .appendingPathComponent("fastra-partial-undo-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = dir.appendingPathComponent("first.txt")
    let second = dir.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let session = try ApplyEngine.apply(
        plan: ApplyEngine.plan(
            files: [first, second],
            options: SearchOptions(find: "foo", replace: "bar", isRegex: false,
                                   caseSensitive: true)),
        backupRoot: backups, cleanupOlderThan: nil)

    var restores = 0
    var partial: ApplySession?
    do {
        _ = try ApplyEngine.undo(session, atomicReplace: { _, target, temporary in
            restores += 1
            if restores == 2 { throw ApplyTestFailure.injected }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        })
        Issue.record("Zweiter Undo-Replace hätte fehlschlagen müssen")
    } catch ApplyError.undoFailed(let progress, _) {
        partial = progress
    }
    let progress = try #require(partial)
    #expect(progress.entries.map(\.state) == [.restored, .applied])
    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == Data("bar two".utf8))
    let persisted = try ApplyEngine.loadSession(at: session.sessionDirectory)
    #expect(persisted.entries.map(\.state) == [.restored, .applied])

    _ = try ApplyEngine.undo(progress)
    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == Data("foo two".utf8))
}

@Test("Legacy-Manifest ohne Applied-Snapshot wird explizit fail-closed abgelehnt")
func undo_legacyManifestIsRejectedExplicitly() throws {
    let backups = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: backups) }
    let directory = backups.appendingPathComponent("session-legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let json: [String: Any] = [
        "timestamp": Date().timeIntervalSinceReferenceDate,
        "sessionDirectory": directory.absoluteString,
        "entries": [[
            "originalPath": "/tmp/legacy.txt",
            "backupRelativePath": "files/0.bin",
            "originalSHA256": "deadbeef",
        ]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: directory.appendingPathComponent("manifest.json"))

    let legacy = try ApplyEngine.loadSession(at: directory)
    #expect(legacy.schemaVersion == 1)
    #expect(legacy.entries[0].state == .legacy)
    #expect(throws: ApplyError.self) { try ApplyEngine.undo(legacy) }
}

// MARK: - Dateibasierte Ordner-Transaktion

private final class ApplyCancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

private final class ApplyCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let cancelAfter: Int

    init(cancelAfter: Int) { self.cancelAfter = cancelAfter }

    func shouldCancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfter
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return checks
    }
}

private func makeTransaction(
    files: [URL],
    options: SearchOptions = SearchOptions(
        find: "foo", replace: "bar", isRegex: false, caseSensitive: true)
) throws -> ApplyTransaction {
    let plan = ApplyEngine.plan(files: files, options: options)
    let inputs = try plan.changedFiles.map { file in
        ApplyTransaction.Input(
            url: file.url,
            snapshot: try #require(file.originalSnapshot),
            matches: file.matches)
    }
    return ApplyTransaction(inputs: inputs, options: options)
}

@Test("ApplyTransaction plant/sichert dateiweise und journalisiert den Erfolg")
func transactionStagesSequentiallyAndApplies() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-transaction-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let transaction = try makeTransaction(files: [first, second])
    var progress: [ApplyTransaction.Progress] = []

    let session = try transaction.execute(
        backupRoot: backups, cleanupOlderThan: nil,
        progress: { progress.append($0) })

    #expect(try Data(contentsOf: first) == Data("bar one".utf8))
    #expect(try Data(contentsOf: second) == Data("bar two".utf8))
    #expect(session.entries.map(\.state) == [.applied, .applied])
    #expect(progress.map(\.phase) == [
        .planned, .backedUp, .planned, .backedUp, .applied, .applied,
    ])
    #expect(!FileManager.default.fileExists(
        atPath: session.sessionDirectory.appendingPathComponent("staged").path))

    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == Data("foo two".utf8))
}

@Test("ApplyTransaction behält pending nach wirksamem Replace-Fehler")
func transactionReplaceFailureAfterSideEffectKeepsPendingEntry() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-transaction-side-effect-\(UUID().uuidString)",
                                isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = directory.appendingPathComponent("target.txt")
    let original = Data("foo".utf8)
    try original.write(to: target)
    let transaction = try makeTransaction(files: [target])

    var partial: ApplySession?
    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            atomicReplace: { _, target, temporary in
                _ = try FileManager.default.replaceItemAt(target,
                                                           withItemAt: temporary)
                throw ApplyTestFailure.injected
            })
        Issue.record("Fehler nach wirksamem Replace hätte weitergereicht werden müssen")
    } catch ApplyError.writeFailed(let session, _) {
        partial = session
    }

    let session = try #require(partial)
    #expect(session.entries.map(\.state) == [.pending])
    #expect(try Data(contentsOf: target) == Data("bar".utf8))
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == session)
    _ = try ApplyEngine.undo(session)
    #expect(try Data(contentsOf: target) == original)
}

@Test("ApplyTransaction-Abbruch vor Preflight ist vollständig write-frei")
func transactionCancellationBeforePreflightWritesNothing() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-transaction-cancel-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let transaction = try makeTransaction(files: [first, second])
    let cancellation = ApplyCancellationLatch()

    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            shouldCancel: { cancellation.isCancelled() },
            progress: {
                if $0.phase == .backedUp { cancellation.cancel() }
            })
        Issue.record("Abgebrochene Transaktion hätte werfen müssen")
    } catch ApplyError.cancelled {
        // Erwarteter, expliziter Abbruchzustand.
    }

    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == Data("foo two".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

@Test("ApplyTransaction bricht während der RegEx-Planung einer großen Datei ab")
func transactionCancellationInterruptsLargeFilePlanning() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-transaction-scan-cancel-\(UUID().uuidString)",
                                isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = directory.appendingPathComponent("large.txt")
    try Data((String(repeating: "x", count: 8 * 1024 * 1024) + "foo").utf8)
        .write(to: target)
    let transaction = try makeTransaction(files: [target])
    let cancellation = ApplyCancellationCounter(cancelAfter: 5)
    var progress: [ApplyTransaction.Progress] = []

    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            shouldCancel: { cancellation.shouldCancel() },
            progress: { progress.append($0) })
        Issue.record("Abbruch während der Dateiplanung hätte werfen müssen")
    } catch ApplyError.cancelled {
        // Erwartet: `.reportProgress` reicht den Abbruch aus dem RegEx-Scan hoch.
    }

    #expect(cancellation.value >= 5)
    #expect(progress.isEmpty)
    #expect(try Data(contentsOf: target).suffix(3) == Data("foo".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

@Test("ApplyTransaction prüft alle Ziele erneut vor dem ersten Write")
func transactionGlobalPreflightRejectsLateConflict() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-transaction-preflight-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    try Data("foo one".utf8).write(to: first)
    try Data("foo two".utf8).write(to: second)
    let transaction = try makeTransaction(files: [first, second])
    let external = Data("foo external".utf8)

    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            beforePreflight: { try external.write(to: second, options: .atomic) })
        Issue.record("Später Konflikt hätte den globalen Preflight stoppen müssen")
    } catch ApplyError.conflict {
        // Erwarteter Konflikt vor dem ersten Ziel-Write.
    }

    #expect(try Data(contentsOf: first) == Data("foo one".utf8))
    #expect(try Data(contentsOf: second) == external)
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

private func requireEffectiveReadDenial(at url: URL) throws {
    try #require(chmod(url.path, 0o000) == 0)
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    let failureCode = errno
    if descriptor >= 0 { close(descriptor) }
    try #require(descriptor == -1 && failureCode == EACCES,
                 "Die Rechte-Fixture muss effektives EACCES erzeugen; privilegierte Reads zählen nicht als Nachweis")
}

private enum LegacyPlanReadFixture: CaseIterable, Equatable {
    case missing, denied, oversized, directory
}

@Test("Dateiplan erhält konkrete Lesefehler und schreibt übersprungene Eingaben nicht",
      arguments: LegacyPlanReadFixture.allCases)
private func legacyPlanReadFailurePreservesCause(kind: LegacyPlanReadFixture) throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    defer { if kind == .denied { _ = chmod(target.path, 0o600) } }
    let control = root.appendingPathComponent("control.txt")
    let original = Data("foo untouched\n".utf8)
    try original.write(to: control)
    let oversizedCount = FileSnapshot.maximumReadBytes + 1
    switch kind {
    case .missing: break
    case .denied:
        try original.write(to: target)
        try requireEffectiveReadDenial(at: target)
    case .oversized:
        try Data().write(to: target)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.truncate(atOffset: oversizedCount)
    case .directory:
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    }
    let plan = ApplyEngine.plan(files: [target], options: SearchOptions(
        find: "foo", replace: "bar", isRegex: false))
    let file = try #require(plan.files.first)
    #expect(file.url == target)
    #expect(file.skipped == .unreadable)
    #expect(file.originalSnapshot == nil && file.encoding == nil)
    #expect(file.bom.isEmpty && file.originalBytes.isEmpty && file.newBytes.isEmpty)
    #expect(file.matches.isEmpty && !file.hasChanges)
    switch kind {
    case .missing, .denied:
        guard case .system(let cause, let underlying) = try #require(file.readFailure) else {
            Issue.record("Der direkte POSIX-Lesefehler fehlt")
            return
        }
        let code: POSIXErrorCode = kind == .missing ? .ENOENT : .EACCES
        #expect(cause.domain == NSPOSIXErrorDomain && cause.code == Int(code.rawValue))
        #expect(cause.message == (POSIXError(code) as NSError).localizedDescription)
        #expect(underlying == nil)
    case .oversized:
        #expect(file.readFailure == .snapshot(.tooLarge(byteCount: oversizedCount)))
    case .directory:
        #expect(file.readFailure == .snapshot(.notRegularFile))
    }
    let backups = root.appendingPathComponent("backups")
    do {
        _ = try ApplyEngine.apply(plan: plan, backupRoot: backups, cleanupOlderThan: nil)
        Issue.record("Ein reiner Skip-Plan darf keine Schreibsession erzeugen")
    } catch ApplyError.planNotApplyable { }
    #expect(!FileManager.default.fileExists(atPath: backups.path))
    #expect(try Data(contentsOf: control) == original)
    switch kind {
    case .missing:
        #expect(!FileManager.default.fileExists(atPath: target.path))
    case .denied:
        try #require(chmod(target.path, 0o600) == 0)
        #expect(try Data(contentsOf: target) == original)
    case .oversized:
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.uint64Value == oversizedCount)
    case .directory:
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}

@Test("Dateiplan wendet gültige Nachbarn an und erhält echte Lesefehler-Skips")
func legacyPlanReadFailureKeepsMixedApply() throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let good = root.appendingPathComponent("good.txt")
    let denied = root.appendingPathComponent("denied.txt")
    let missing = root.appendingPathComponent("missing.txt")
    try Data("foo good\n".utf8).write(to: good)
    let original = Data("foo denied\n".utf8)
    try original.write(to: denied)
    let before = try FileSnapshot.readSnapshotOnly(from: denied)
    let mtime = try FileManager.default.attributesOfItem(atPath: denied.path)[.modificationDate] as? Date
    defer { _ = chmod(denied.path, 0o600) }
    try requireEffectiveReadDenial(at: denied)
    let plan = ApplyEngine.plan(files: [good, denied, missing], options: SearchOptions(
        find: "foo", replace: "bar", isRegex: false))
    #expect(plan.files.map(\.url) == [good, denied, missing])
    #expect(plan.files[0].readFailure == nil)
    #expect(plan.files[1].readFailure != nil && plan.files[2].readFailure != nil)
    let session = try ApplyEngine.apply(plan: plan,
        backupRoot: root.appendingPathComponent("backups"), cleanupOlderThan: nil)
    #expect(session.entries.count == 1 && session.entries[0].originalPath == good.path)
    #expect(try Data(contentsOf: good) == Data("bar good\n".utf8))
    try #require(chmod(denied.path, 0o600) == 0)
    #expect(try Data(contentsOf: denied) == original)
    #expect(try FileSnapshot.readSnapshotOnly(from: denied) == before)
    #expect(try FileManager.default.attributesOfItem(atPath: denied.path)[.modificationDate] as? Date == mtime)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test("Dateiplan kopiert den echten Foundation-Lesefehler samt POSIX-Ursache")
func legacyPlanReadFailureKeepsFoundationCause() throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("write-only.txt")
    try Data("own fixture".utf8).write(to: target)
    let descriptor = open(target.path, O_WRONLY | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    do {
        _ = try handle.read(upToCount: 1)
        Issue.record("Der schreibende Deskriptor muss den echten Foundation-Lesefehler liefern")
    } catch {
        let original = error as NSError
        let originalCause = try #require(original.userInfo[NSUnderlyingErrorKey] as? NSError)
        guard case .system(let copied, let cause) = PlannedReadFailure(error) else {
            Issue.record("Foundation-Lesefehler wurde nicht erhalten")
            return
        }
        #expect(copied.domain == original.domain && copied.code == original.code)
        #expect(copied.message == original.localizedDescription)
        #expect(cause?.domain == NSPOSIXErrorDomain && cause?.code == Int(EBADF))
        #expect(cause?.message == originalCause.localizedDescription)
    }
}

@Test("Erfolgreiche, binäre und Regex-Skips erfinden keine Lesefehler")
func legacyPlanReadFailureDoesNotInventCause() throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = root.appendingPathComponent("text.txt")
    let binary = root.appendingPathComponent("binary.bin")
    try Data("foo".utf8).write(to: text)
    try Data([0, 1, 2]).write(to: binary)
    let plan = ApplyEngine.plan(files: [text, binary], options: SearchOptions(
        find: "foo", replace: "bar", isRegex: false))
    #expect(plan.files.allSatisfy { $0.readFailure == nil })
    #expect(plan.files[0].hasChanges && plan.files[1].skipped == .binary)
    let invalid = ApplyEngine.plan(files: [root.appendingPathComponent("missing")],
        options: SearchOptions(find: "(", replace: "bar", isRegex: true))
    #expect(invalid.files.count == 1 && invalid.files[0].readFailure == nil)
    #expect(invalid.files[0].skipped != .unreadable)
}

private func expectReadDenialMessage(_ message: String, at url: URL) {
    #expect(message.contains(L10n.format("„%@“ konnte nicht gelesen werden",
                                        url.lastPathComponent)))
    #expect(message.contains(POSIXError(.EACCES).localizedDescription))
    #expect(!message.contains(L10n.format(
        "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
        url.lastPathComponent)))
    #expect(!message.contains(L10n.format(
        "„%@“ wurde nach dem Apply geändert. Rückgängig wurde abgebrochen.",
        url.lastPathComponent)))
}

@Test("Apply benennt EACCES auch für wirkungslose Eingaben vor jedem Zielwrite",
      arguments: [false, true])
func transactionReadDenialPreservesCause(duringGlobalPreflight: Bool) throws {
    let directory = try makeBackupRoot()
    let backups = try makeBackupRoot()
    let changing = directory.appendingPathComponent("changing.txt")
    let effectless = directory.appendingPathComponent("effectless.txt")
    defer {
        _ = chmod(effectless.path, 0o600)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let changingBytes = Data("FOO wird klein".utf8)
    let effectlessBytes = Data("foo bleibt".utf8)
    try changingBytes.write(to: changing)
    try effectlessBytes.write(to: effectless)
    let transaction = try makePreviewTransaction(files: [changing, effectless],
        options: SearchOptions(find: "foo", replace: "foo", isRegex: false))
    if !duringGlobalPreflight { try requireEffectiveReadDenial(at: effectless) }
    var writes = 0
    do {
        _ = try transaction.execute(backupRoot: backups, cleanupOlderThan: nil,
            beforePreflight: {
                #expect(duringGlobalPreflight)
                try requireEffectiveReadDenial(at: effectless)
            }, beforeAtomicReplace: { _ in writes += 1 })
        Issue.record("Der Lesefehler muss Apply vor dem ersten Zielwrite abbrechen")
    } catch ApplyError.conflict(let message) {
        expectReadDenialMessage(message, at: effectless)
    }
    #expect(writes == 0)
    try #require(chmod(effectless.path, 0o600) == 0)
    #expect(try Data(contentsOf: changing) == changingBytes)
    #expect(try Data(contentsOf: effectless) == effectlessBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

@Test("Undo benennt EACCES und erhält Backups, Manifest und Retry-Basis",
      arguments: [false, true])
func undoReadDenialPreservesCauseAndRetry(firstAlreadyOriginal: Bool) throws {
    let directory = try makeBackupRoot()
    let backups = try makeBackupRoot()
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    defer {
        _ = chmod(second.path, 0o600)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let firstOriginal = Data("foo one".utf8)
    let secondOriginal = Data("foo two".utf8)
    try firstOriginal.write(to: first)
    try secondOriginal.write(to: second)
    let session = try makeTransaction(files: [first, second]).execute(
        backupRoot: backups, cleanupOlderThan: nil)
    if firstAlreadyOriginal { try firstOriginal.write(to: first, options: .atomic) }
    let targetsBefore = try [first, second].map { try FileSnapshot.read(from: $0) }
    let backupURLs = session.entries.map {
        session.sessionDirectory.appendingPathComponent($0.backupRelativePath)
    }
    let backupsBefore = try backupURLs.map { try FileSnapshot.readSnapshotOnly(from: $0) }
    let persistedBefore = try ApplyEngine.loadSession(at: session.sessionDirectory)
    try requireEffectiveReadDenial(at: second)
    var writes = 0
    var retry = session
    do {
        _ = try ApplyEngine.undo(session, beforeAtomicReplace: { _ in writes += 1 })
        Issue.record("Der Lesefehler muss Undo vor dem ersten Restore abbrechen")
    } catch ApplyError.undoConflict(let message) {
        #expect(!firstAlreadyOriginal)
        expectReadDenialMessage(message, at: second)
    } catch ApplyError.undoFailed(let partial, let message) {
        #expect(firstAlreadyOriginal)
        #expect(partial.entries.map(\.state) == [.restored, .applied])
        #expect(partial.entries[1] == session.entries[1])
        retry = partial
        expectReadDenialMessage(message, at: second)
    }
    #expect(writes == 0)
    try #require(chmod(second.path, 0o600) == 0)
    #expect(try [first, second].map { try FileSnapshot.readSnapshotOnly(from: $0) }
            == targetsBefore.map { $0.snapshot })
    #expect(try backupURLs.map { try FileSnapshot.readSnapshotOnly(from: $0) } == backupsBefore)
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == persistedBefore)
    let restored = try ApplyEngine.undo(retry)
    #expect(restored.entries.map(\.state) == [.restored, .restored])
    #expect(try Data(contentsOf: first) == firstOriginal)
    #expect(try Data(contentsOf: second) == secondOriginal)
}

@Test("Undo meldet fehlende oder unlesbare Sicherungen mit Pfad und hält sie wiederholbar",
      arguments: [false, true], [false, true])
func undoBackupReadFailurePreservesPathAndRetry(afterFirstRestore: Bool, missing: Bool) throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ["first.txt", "second.txt"].map { root.appendingPathComponent($0) }
    let originals = ["foo one\r\n", "foo two\r\n"].map { Data($0.utf8) }
    let applied = ["bar one\r\n", "bar two\r\n"].map { Data($0.utf8) }
    for (file, bytes) in zip(files, originals) { try bytes.write(to: file) }
    let session = try makeTransaction(files: files).execute(
        backupRoot: root.appendingPathComponent("backups"), cleanupOlderThan: nil)
    let entry = try #require(session.entries.last)
    let backup = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
    let parked = backup.appendingPathExtension("parked")
    let originalBackup = try FileSnapshot.readSnapshotOnly(from: backup)
    let appliedTargets = try files.map { try FileSnapshot.readSnapshotOnly(from: $0) }
    let cause: POSIXErrorCode = missing ? .ENOENT : .EACCES

    func blockBackupRead() throws {
        if missing {
            try FileManager.default.moveItem(at: backup, to: parked)
            let descriptor = open(backup.path, O_RDONLY)
            let readError = errno
            if descriptor >= 0 { close(descriptor) }
            try #require(descriptor == -1 && readError == ENOENT)
        } else {
            try requireEffectiveReadDenial(at: backup)
        }
    }

    if !afterFirstRestore { try blockBackupRead() }
    var swaps: [URL] = []
    var retry = session
    var failureMessage: String?
    do {
        _ = try ApplyEngine.undo(session, beforeAtomicReplace: { url in
            swaps.append(url)
            try #require(afterFirstRestore && swaps == [files[0]])
            try blockBackupRead()
        })
        Issue.record("Die unerreichbare zweite Sicherung muss Undo abbrechen")
    } catch ApplyError.backupFailed(let message) {
        #expect(!afterFirstRestore)
        failureMessage = message
    } catch ApplyError.undoFailed(let partial, let message) {
        #expect(afterFirstRestore)
        retry = partial
        failureMessage = message
    }
    let message = try #require(failureMessage)
    #expect(message.contains(files[1].lastPathComponent))
    #expect(message.contains(backup.path))
    #expect(message.contains(POSIXError(cause).localizedDescription))
    #expect(swaps == (afterFirstRestore ? [files[0]] : []))
    #expect(retry.entries.map(\.state) == (afterFirstRestore ? [.restored, .applied] : [.applied, .applied]))
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == retry)
    #expect(try FileSnapshot.readSnapshotOnly(from: files[1]) == appliedTargets[1])
    #expect(try files.map { try Data(contentsOf: $0) }
            == (afterFirstRestore ? [originals[0], applied[1]] : applied))

    if missing {
        try FileManager.default.moveItem(at: parked, to: backup)
    } else {
        try #require(chmod(backup.path, 0o600) == 0)
    }
    let reopenedBackup = try FileSnapshot.readSnapshotOnly(from: backup)
    #expect(reopenedBackup.identity == originalBackup.identity)
    #expect(reopenedBackup.sha256 == originalBackup.sha256)
    let restored = try ApplyEngine.undo(retry)
    #expect(restored.entries.map(\.state) == [.restored, .restored])
    #expect(try files.map { try Data(contentsOf: $0) } == originals)
}

@Test("Undo nennt bei beschädigter Sicherung die Datei und den vollständigen Sicherungspfad",
      arguments: [false, true])
func undoBackupContentMismatchKeepsPathAndRetry(afterFirstRestore: Bool) throws {
    let root = try makeBackupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ["first.txt", "second.txt"].map { root.appendingPathComponent($0) }
    let originals = ["foo one\r\n", "foo two\r\n"].map { Data($0.utf8) }
    let applied = ["bar one\r\n", "bar two\r\n"].map { Data($0.utf8) }
    for (file, bytes) in zip(files, originals) { try bytes.write(to: file) }
    let session = try makeTransaction(files: files).execute(
        backupRoot: root.appendingPathComponent("backups"), cleanupOlderThan: nil)
    let entry = try #require(session.entries.last)
    let backup = session.sessionDirectory.appendingPathComponent(entry.backupRelativePath)
    let damaged = Data("foo TWO\r\n".utf8)
    try #require(damaged.count == originals[1].count)
    if !afterFirstRestore { try damaged.write(to: backup) }

    var swaps: [URL] = []
    var retry = session
    var failureMessage: String?
    do {
        _ = try ApplyEngine.undo(session, beforeAtomicReplace: { url in
            swaps.append(url)
            try #require(afterFirstRestore && swaps == [files[0]])
            try damaged.write(to: backup)
        })
        Issue.record("Die beschädigte zweite Sicherung muss Undo abbrechen")
    } catch ApplyError.backupFailed(let message) {
        #expect(!afterFirstRestore)
        failureMessage = message
    } catch ApplyError.undoFailed(let partial, let message) {
        #expect(afterFirstRestore)
        retry = partial
        failureMessage = message
    }
    let message = try #require(failureMessage)
    #expect(message.contains(files[1].lastPathComponent))
    #expect(message.contains(backup.path))
    #expect(message.localizedCaseInsensitiveContains("original"))
    #expect(swaps == (afterFirstRestore ? [files[0]] : []))
    #expect(retry.entries.map(\.state) == (afterFirstRestore ? [.restored, .applied] : [.applied, .applied]))
    #expect(try ApplyEngine.loadSession(at: session.sessionDirectory) == retry)
    #expect(try files.map { try Data(contentsOf: $0) }
            == (afterFirstRestore ? [originals[0], applied[1]] : applied))
    #expect(try Data(contentsOf: backup) == damaged)

    try originals[1].write(to: backup)
    let restored = try ApplyEngine.undo(retry)
    #expect(restored.entries.map(\.state) == [.restored, .restored])
    #expect(try files.map { try Data(contentsOf: $0) } == originals)
}

@Test("Byte-, Identitäts-, Größen- und Typwechsel bleiben Apply-Konflikte",
      arguments: ["bytes", "identity", "growth", "directory"], [false, true])
func transactionReadChangesRemainConflicts(change: String, duringGlobalPreflight: Bool) throws {
    let directory = try makeBackupRoot()
    let backups = try makeBackupRoot()
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = directory.appendingPathComponent("first.txt")
    let second = directory.appendingPathComponent("second.txt")
    let firstBytes = Data("foo one".utf8)
    let secondBytes = Data("foo two".utf8)
    try firstBytes.write(to: first)
    try secondBytes.write(to: second)
    let transaction = try makeTransaction(files: [first, second])
    let originalSecond = transaction.inputs[1].snapshot
    var foreignSnapshot: FileSnapshot?
    func changeTarget() throws {
        switch change {
        case "bytes": try Data("foo BAD".utf8).write(to: second)
        case "identity":
            try FileManager.default.moveItem(at: second,
                to: directory.appendingPathComponent("original-second.txt"))
            try secondBytes.write(to: second)
        case "growth": try Data("foo two grown".utf8).write(to: second)
        default:
            try FileManager.default.removeItem(at: second)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        }
        if change != "directory" {
            foreignSnapshot = try FileSnapshot.readSnapshotOnly(from: second)
        }
        if change == "identity" {
            #expect(foreignSnapshot?.identity != originalSecond.identity)
            #expect(foreignSnapshot?.hasSameContent(as: originalSecond) == true)
        }
    }
    if !duringGlobalPreflight { try changeTarget() }
    var writes = 0
    do {
        _ = try transaction.execute(backupRoot: backups, cleanupOlderThan: nil,
            beforePreflight: { try changeTarget() },
            beforeAtomicReplace: { _ in writes += 1 })
        Issue.record("Eine abweichende Vorschaubasis muss vor dem ersten Zielwrite stoppen")
    } catch ApplyError.conflict(let message) {
        #expect(message == L10n.format(
            "„%@“ wurde seit der Vorschau geändert. Es wurde nichts verändert.",
            second.lastPathComponent))
    }
    #expect(writes == 0)
    #expect(try Data(contentsOf: first) == firstBytes)
    if let foreignSnapshot {
        #expect(try FileSnapshot.readSnapshotOnly(from: second) == foreignSnapshot)
    } else {
        #expect(try second.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

@Test("Fremd-Replace nach dem letzten Apply-Preflight bleibt erhalten")
func transactionForeignReplaceAfterPerFilePreflightIsPreserved() throws {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-apply-commit-race-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = directory.appendingPathComponent("target.txt")
    try Data("foo\n".utf8).write(to: target)
    let transaction = try makeTransaction(files: [target])
    let external = Data("extern im Commit-Fenster\n".utf8)
    var hookCalls = 0

    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            beforeAtomicReplace: { coordinatedURL in
                hookCalls += 1
                try external.write(to: coordinatedURL, options: .atomic)
            })
        Issue.record("Der Fremd-Replace hätte Apply abbrechen müssen")
    } catch ApplyError.conflict {
        // Erwartet: Der Committer hat den verdrängten Fremdstand restauriert.
    }

    #expect(hookCalls == 1)
    #expect(try Data(contentsOf: target) == external)
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    let siblings = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    #expect(!siblings.contains { $0.lastPathComponent.contains(".fastra-apply-") })
}

@Test("Fremd-Replace nach dem letzten Undo-Preflight bleibt erhalten")
func undoForeignReplaceAfterPerFilePreflightIsPreserved() throws {
    let directory = testTemporaryDirectory().appendingPathComponent(
        "fastra-undo-commit-race-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let target = directory.appendingPathComponent("target.txt")
    try Data("foo\n".utf8).write(to: target)
    let session = try makeTransaction(files: [target]).execute(
        backupRoot: backups, cleanupOlderThan: nil)
    let external = Data("extern vor Undo-Commit\n".utf8)
    var hookCalls = 0

    do {
        _ = try ApplyEngine.undo(
            session,
            beforeAtomicReplace: { coordinatedURL in
                hookCalls += 1
                try external.write(to: coordinatedURL, options: .atomic)
            })
        Issue.record("Der Fremd-Replace hätte Undo abbrechen müssen")
    } catch ApplyError.undoConflict {
        // Erwartet: Der Committer hat den verdrängten Fremdstand restauriert.
    }

    #expect(hookCalls == 1)
    #expect(try Data(contentsOf: target) == external)
    let persisted = try ApplyEngine.loadSession(at: session.sessionDirectory)
    #expect(persisted.entries.map(\.state) == [.applied])
    let siblings = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    #expect(!siblings.contains { $0.lastPathComponent.contains(".fastra-undo-") })
}

@Test("Globaler Preflight prüft auch die wirkungslosen Eingaben")
func transactionGlobalPreflightCoversEffectlessInputs() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-transaction-effectless-\(UUID().uuidString)",
                                isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let effectless = directory.appendingPathComponent("effectless.txt")
    let changing = directory.appendingPathComponent("changing.txt")
    try Data("foo bleibt\n".utf8).write(to: effectless)
    try Data("FOO wird klein\n".utf8).write(to: changing)

    // „foo" → „foo" ohne Rücksicht auf Groß-/Kleinschreibung: Die erste Datei
    // hat einen Treffer, ändert sich dadurch aber nicht und bekommt deshalb
    // weder Backup noch Eintrag in der Sitzung. Die zweite ändert sich sehr
    // wohl. Ohne die Vollprüfung liefe der Auftrag hier durch und schriebe die
    // zweite Datei, obwohl die erste nicht mehr dem Vorschaustand entspricht.
    let options = SearchOptions(find: "foo", replace: "foo", isRegex: false,
                                caseSensitive: false)
    let plan = ApplyEngine.plan(files: [effectless, changing], options: options)
    let inputs = try plan.files.map { file in
        ApplyTransaction.Input(url: file.url,
                               snapshot: try #require(file.originalSnapshot),
                               matches: file.matches)
    }
    #expect(inputs.count == 2)
    #expect(plan.changedFiles.count == 1)
    let transaction = ApplyTransaction(inputs: inputs, options: options)
    let external = Data("foo fremd\n".utf8)

    do {
        _ = try transaction.execute(
            backupRoot: backups, cleanupOlderThan: nil,
            beforePreflight: { try external.write(to: effectless, options: .atomic) })
        Issue.record("Der späte Konflikt in der wirkungslosen Datei hätte stoppen müssen")
    } catch ApplyError.conflict {
        // Erwartet: Die Vorabprüfung deckt alle Eingaben ab, nicht nur die
        // tatsächlich zu schreibenden.
    }

    #expect(try Data(contentsOf: changing) == Data("FOO wird klein\n".utf8))
    #expect(try Data(contentsOf: effectless) == external)
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
}

// MARK: W-2026-08-02. Wirkungslose Datei bricht nicht mehr den ganzen Auftrag ab

// Ein Auftrag mit wirkungsloser Ersetzung muss die übrigen Änderungen
// ausführen. Die Eingaben stammen wie im Produkt aus allen Dateien mit
// Treffern der sichtbaren Ordner-Vorschau, nicht nur aus der Änderungsliste.

/// Auftrag über alle Treffer-Dateien — so, wie ihn die Ordner-Vorschau baut.
private func makePreviewTransaction(files: [URL],
                                    options: SearchOptions) throws -> ApplyTransaction {
    let plan = ApplyEngine.plan(files: files, options: options)
    let inputs = try plan.files.map { file in
        ApplyTransaction.Input(url: file.url,
                               snapshot: try #require(file.originalSnapshot),
                               matches: file.matches)
    }
    return ApplyTransaction(inputs: inputs, options: options)
}

@Test("Eine wirkungslose Datei wird übersprungen, die übrigen werden ersetzt")
func transaction_skipsUnchangedFileAndAppliesTheRest() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-noop-mix-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let changing = directory.appendingPathComponent("gross.txt")
    let unchanged = directory.appendingPathComponent("klein.txt")
    try Data("FOO eins".utf8).write(to: changing)
    try Data("foo zwei".utf8).write(to: unchanged)

    // „foo" ohne Beachtung der Großschreibung durch „foo" ersetzen: In der
    // ersten Datei ändert das wirklich etwas, in der zweiten nicht.
    let options = SearchOptions(find: "foo", replace: "foo",
                                isRegex: false, caseSensitive: false)
    let transaction = try makePreviewTransaction(files: [changing, unchanged],
                                                 options: options)
    #expect(transaction.inputs.count == 2, "Beide Dateien haben sichtbare Treffer")

    let session = try transaction.execute(backupRoot: backups, cleanupOlderThan: nil)

    #expect(try Data(contentsOf: changing) == Data("foo eins".utf8))
    #expect(try Data(contentsOf: unchanged) == Data("foo zwei".utf8))
    // Nur die wirklich geschriebene Datei steht in der Sitzung — die
    // übersprungene braucht weder Backup noch Rückgängig-Eintrag.
    #expect(session.entries.count == 1)
    #expect(session.entries.first?.originalPath == changing.path)
}

@Test("Ändert sich keine einzige Datei, wird der Auftrag ehrlich abgelehnt")
func transaction_refusesWhenNothingWouldChange() throws {
    let directory = testTemporaryDirectory()
        .appendingPathComponent("fastra-noop-all-\(UUID().uuidString)", isDirectory: true)
    let backups = try makeBackupRoot()
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backups)
    }
    let first = directory.appendingPathComponent("a.txt")
    let second = directory.appendingPathComponent("b.txt")
    try Data("foo eins".utf8).write(to: first)
    try Data("foo zwei".utf8).write(to: second)

    let options = SearchOptions(find: "foo", replace: "foo",
                                isRegex: false, caseSensitive: true)
    let transaction = try makePreviewTransaction(files: [first, second],
                                                 options: options)

    #expect(throws: ApplyError.self) {
        _ = try transaction.execute(backupRoot: backups, cleanupOlderThan: nil)
    }
    #expect(try Data(contentsOf: first) == Data("foo eins".utf8))
    #expect(try Data(contentsOf: second) == Data("foo zwei".utf8))
    #expect((try FileManager.default.contentsOfDirectory(atPath: backups.path)).isEmpty,
            "Ein abgelehnter Auftrag darf keine Sitzung hinterlassen")
}


@Test("Ganzwort erhält Extended-Kommentare und literales ausgeschaltetes x")
func apply_wholeWordExtendedComments() throws {
    for (pattern, text, expected) in [
        ("(?x)(foo) # Kommentar", "foo foobar", "foo! foobar"),
        ("(?x)(foo) # Kommentar\n", "foo foobar", "foo! foobar"),
        ("(?x)(?-x:(foo)#tag)", "foo#tag foo#tags", "foo! foo#tags"),
        ("(?x)(?-x)(foo)#tag", "foo#tag foo#tags", "foo! foo#tags"),
        ("(foo)\n", "foo\nbar", "foo!bar"),
    ] {
        let options = SearchOptions(find: pattern, replace: "$1!", isRegex: true,
                                    caseSensitive: true, wholeWord: true)
        let regex = try ApplyEngine.buildRegex(options)
        let range = NSRange(location: 0, length: text.utf16.count)
        #expect(regex.numberOfCaptureGroups == 1)
        #expect(regex.numberOfMatches(in: text, range: range) == 1)
        #expect(regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1!") == expected)
        let directory = try makeBackupRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("words.txt")
        try Data(text.utf8).write(to: url)
        let plan = ApplyEngine.plan(files: [url], options: options)
        #expect(plan.files.first?.newBytes == Data(expected.utf8))
    }
}
