// FolderSearchTests.swift
//
// Sichert die Folder-Scope-Suche ab. Reproduzierbarer kleiner Korpus
// pro Test (eigenes Temp-Verzeichnis), damit Tests parallel laufen
// können ohne sich gegenseitig zu sehen.

import Testing
import Foundation
@testable import Fastra

// MARK: - Mini-Korpus für Folder-Tests

private final class FolderCorpus {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastra-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ name: String, _ content: String, encoding: String.Encoding = .utf8,
               in subfolder: String? = nil) throws -> URL {
        let dir = subfolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.data(using: encoding)!.write(to: url)
        return url
    }

    @discardableResult
    func writeRaw(_ name: String, _ bytes: Data, in subfolder: String? = nil) throws -> URL {
        let dir = subfolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}

private func makeRipgrepStub(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-rg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("rg-fixture")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: script.path)
    return script
}

private final class CancellationCounter: @unchecked Sendable {
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

// MARK: - File-Type-Filter

@Test("Filter .all lässt alles durch, auch Endungen wie .bin")
func filter_allAcceptsAnything() {
    let url = URL(fileURLWithPath: "/tmp/test.bin")
    #expect(FolderSearch.passesFilter(url: url, filter: .all) == true)
}

@Test("Filter .knownText lässt bekannte Text-Endungen durch")
func filter_knownTextAcceptsTextExts() {
    for ext in ["txt", "md", "swift", "json", "csv", "yaml"] {
        let url = URL(fileURLWithPath: "/tmp/x.\(ext)")
        #expect(FolderSearch.passesFilter(url: url, filter: .knownText) == true, "\(ext) sollte durchgehen")
    }
}

@Test("Filter .knownText lehnt Binär-Endungen und nackte Dateien ab")
func filter_knownTextRejectsBinary() {
    for ext in ["pdf", "png", "jpg", "zip", "exe", "dmg"] {
        let url = URL(fileURLWithPath: "/tmp/x.\(ext)")
        #expect(FolderSearch.passesFilter(url: url, filter: .knownText) == false, "\(ext) sollte rausfliegen")
    }
    let noExt = URL(fileURLWithPath: "/tmp/Makefile")
    #expect(FolderSearch.passesFilter(url: noExt, filter: .knownText) == false)
}

@Test("Filter ist case-insensitive bei der Endung")
func filter_caseInsensitiveExt() {
    let upper = URL(fileURLWithPath: "/tmp/README.MD")
    #expect(FolderSearch.passesFilter(url: upper, filter: .knownText) == true)
}

// MARK: - Empty / ungültiges Pattern

@Test("Leerer Find-String → leeres Ergebnis")
func find_emptyPatternIsEmpty() throws {
    let c = try FolderCorpus()
    try c.write("a.txt", "foo bar")
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "", replace: "x"))
    #expect(r.perFile.isEmpty)
    #expect(r.invalidPatternMessage == nil)
}

@Test("Ungültige RegEx → invalidPatternMessage, kein perFile-Lauf")
func find_invalidPatternAborts() throws {
    let c = try FolderCorpus()
    try c.write("a.txt", "foo bar")
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "(unbalanced", replace: "x", isRegex: true))
    #expect(r.invalidPatternMessage != nil)
    #expect(r.perFile.isEmpty)
}

// MARK: - Trefferzählung über mehrere Dateien

@Test("Treffer werden über mehrere Dateien gefunden und gezählt")
func find_countsAcrossFiles() throws {
    let c = try FolderCorpus()
    try c.write("a.txt", "foo bar foo")
    try c.write("b.md",  "irgendwas foo hier")
    try c.write("c.json", "{\"x\": \"keine\"}")
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false, caseSensitive: true))
    #expect(r.filesWithMatches.count == 2)
    #expect(r.totalMatches == 3)
}

@Test("Rekursion in Unterordner funktioniert")
func find_recursesIntoSubfolders() throws {
    let c = try FolderCorpus()
    try c.write("top.txt", "foo")
    try c.write("nested.txt", "foo foo", in: "sub1")
    try c.write("deeper.txt", "foo", in: "sub1/sub2")
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    #expect(r.totalMatches == 4)
}

@Test("Gebündeltes ripgrep liefert auch mehr Ausgaben als ein Pipe-Puffer")
func ripgrepEnumerationDrainsLargeOutput() throws {
    let c = try FolderCorpus()
    // 2.000 absolute Pfade liegen deutlich über einem üblichen 64-KiB-Puffer.
    // Der Test schützt gegen den früheren Deadlock „Prozess wartet auf Pipe,
    // Aufrufer wartet auf Prozessende“.
    for index in 0..<2_000 {
        try c.write("entry-\(index).txt", "needle", in: "many")
    }
    let files = try RipgrepFileEnumerator.files(in: c.root)
    #expect(files.count == 2_000)
}

@Test("ripgrep leert stdout und stderr gleichzeitig")
func ripgrepEnumerationDrainsBothPipes() throws {
    let c = try FolderCorpus()
    let fixture = try makeRipgrepStub("""
    i=0
    while [ "$i" -lt 4000 ]; do
      printf '%s/generated-%s.txt\\0' "$6" "$i"
      printf 'diagnostic-%s-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' "$i" >&2
      i=$((i + 1))
    done
    """)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    let files = try RipgrepFileEnumerator.files(in: c.root,
                                                 executableURL: fixture,
                                                 timeout: 5)
    #expect(files.count == 4_000)
}

@Test("ripgrep-Timeout liefert keine partielle Dateiliste")
func ripgrepEnumerationTimesOutExplicitly() throws {
    let c = try FolderCorpus()
    let fixture = try makeRipgrepStub("sleep 5")
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    do {
        _ = try RipgrepFileEnumerator.files(in: c.root,
                                            executableURL: fixture,
                                            timeout: 0.05)
        Issue.record("Timeout wurde fälschlich als vollständige Dateiliste akzeptiert")
    } catch let failure as RipgrepFileEnumerator.Failure {
        #expect(failure == .timedOut)
    }
}

@Test("ripgrep-Exit 1 ohne Ausgabe bedeutet einen gültigen leeren Ordner")
func ripgrepEnumerationAcceptsEmptyDirectory() throws {
    let c = try FolderCorpus()
    let fixture = try makeRipgrepStub("exit 1")
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    let files = try RipgrepFileEnumerator.files(in: c.root,
                                                 executableURL: fixture)
    #expect(files.isEmpty)
}

@Test("ripgrep-Ausgabelimit liefert keine gekürzte Dateiliste")
func ripgrepEnumerationRejectsTruncatedStdout() throws {
    let c = try FolderCorpus()
    let fixture = try makeRipgrepStub("""
    i=0
    while [ "$i" -lt 100 ]; do
      printf '%s/a-very-long-generated-file-name-%s.txt\\0' "$6" "$i"
      i=$((i + 1))
    done
    """)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    do {
        _ = try RipgrepFileEnumerator.files(
            in: c.root, executableURL: fixture,
            outputLimit: GitOutputLimit(stdoutBytes: 64, stderrBytes: 64))
        Issue.record("Gekürztes stdout wurde fälschlich als vollständige Dateiliste akzeptiert")
    } catch let failure as RipgrepFileEnumerator.Failure {
        #expect(failure == .outputLimit)
    }
}

@Test("ripgrep-Abbruch beendet den Prozess ohne Fallback-Vollscan")
func ripgrepEnumerationCancelsProcess() throws {
    let c = try FolderCorpus()
    let fixture = try makeRipgrepStub("while :; do sleep 1; done")
    let counter = CancellationCounter(cancelAfter: 3)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

    do {
        _ = try RipgrepFileEnumerator.files(in: c.root,
                                            executableURL: fixture,
                                            timeout: 5,
                                            shouldCancel: { counter.shouldCancel() })
        Issue.record("Abbruch wurde fälschlich als vollständige Dateiliste akzeptiert")
    } catch let failure as RipgrepFileEnumerator.Failure {
        #expect(failure == .cancelled)
        #expect(counter.value >= 3)
    }
}

@Test("Ordnersuche reicht das Abbruchsignal bis in Enumeration und Dateiloop")
func folderSearchPropagatesCancellation() throws {
    let c = try FolderCorpus()
    try c.write("a.txt", String(repeating: "kein Treffer\n", count: 20_000))
    let counter = CancellationCounter(cancelAfter: 4)

    let result = FolderSearch.find(
        in: [c.root], filter: .knownText,
        options: SearchOptions(find: "NADEL", replace: "", isRegex: false),
        shouldCancel: { counter.shouldCancel() })

    #expect(counter.value >= 4)
    #expect(result == .empty)
}

// MARK: - Binär-Schutz

@Test("Binärdateien werden mit Grund .binary übersprungen, NICHT durchsucht")
func find_skipsBinariesEvenInAllFilter() throws {
    let c = try FolderCorpus()
    // Binärdatei mit ".txt"-Endung, um den Filter zu umgehen — die
    // Binär-Heuristik MUSS sie trotzdem fangen.
    try c.writeRaw("trojan.txt",
                   Data([0x66, 0x6F, 0x6F, 0x00, 0x66, 0x6F, 0x6F])) // "foo\0foo"
    try c.write("plain.txt", "foo")
    let r = FolderSearch.find(in: [c.root], filter: .all,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    let trojan = r.perFile.first { $0.url.lastPathComponent == "trojan.txt" }
    let plain = r.perFile.first { $0.url.lastPathComponent == "plain.txt" }
    #expect(trojan?.skipped == .binary)
    #expect(trojan?.matches.isEmpty == true)
    #expect(plain?.matches.count == 1)
}

// MARK: - Encoding-Vielfalt

@Test("Latin-1- und UTF-8-Dateien werden gleichermaßen durchsucht")
func find_handlesMultipleEncodings() throws {
    let c = try FolderCorpus()
    try c.write("u.txt", "Müller", encoding: .utf8)
    try c.write("l.txt", "Müller", encoding: .isoLatin1)
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "Müller", replace: "X",
                                                     isRegex: false))
    #expect(r.totalMatches == 2)
}

@Test("UTF-32 LE/BE werden mit Vierbyte-BOM symmetrisch durchsucht")
func find_handlesUtf32BothEndiannesses() throws {
    let c = try FolderCorpus()
    let variants: [(String.Encoding, Data, String)] = [
        (.utf32LittleEndian, Data([0xFF, 0xFE, 0x00, 0x00]), "le.txt"),
        (.utf32BigEndian, Data([0x00, 0x00, 0xFE, 0xFF]), "be.txt"),
    ]
    for (encoding, bom, name) in variants {
        var bytes = bom
        bytes.append(try #require("Hallo UTF-32".data(using: encoding)))
        try c.writeRaw(name, bytes)
    }
    let result = FolderSearch.find(
        in: [c.root], filter: .knownText,
        options: SearchOptions(find: "UTF-32", replace: "Unicode",
                               isRegex: false, caseSensitive: true))
    #expect(result.totalMatches == 2)
    #expect(result.filesWithMatches.count == 2)
    #expect(result.filesWithMatches.allSatisfy { $0.skipped == nil })
}

@Test("Windows-1252-Anführungszeichen sind in der Ordnersuche erreichbar")
func find_detectsWindows1252BeforeLatin1() throws {
    let c = try FolderCorpus()
    try c.write("cp1252.txt", "„Treffer“ und 10 €", encoding: .windowsCP1252)
    let result = FolderSearch.find(
        in: [c.root], filter: .knownText,
        options: SearchOptions(find: "„Treffer“", replace: "gefunden",
                               isRegex: false, caseSensitive: true))
    #expect(result.totalMatches == 1)
    #expect(result.filesWithMatches.first?.matches.first?.matchText == "„Treffer“")
}

// MARK: - Filter wirkt vorm Lesen

@Test("Dateien mit nicht-erlaubter Endung tauchen nicht im Ergebnis auf")
func find_filterDropsFilesPreLoad() throws {
    let c = try FolderCorpus()
    try c.write("y.txt", "foo")
    try c.write("z.pdf", "foo")  // Pseudo-PDF, würde sonst gematched
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false))
    #expect(r.perFile.count == 1)
    #expect(r.perFile.first?.url.lastPathComponent == "y.txt")
}

// MARK: - maxMatches-Kappung (pro Datei)

@Test("maxResultsPerFile kappt die Trefferliste pro Datei")
func find_capsMatchesPerFile() throws {
    let c = try FolderCorpus()
    try c.write("many.txt", String(repeating: "foo\n", count: 100))
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false),
                              maxResultsPerFile: 10)
    #expect(r.perFile.first?.matches.count == 10)
}

// MARK: - Gesamt-Cap (maxTotalMatches)

@Test("Gesamt-Cap löst aus wenn Treffer > cap → wasCapped == true, Anzahl ≤ cap")
func find_totalCap_triggers() throws {
    // Corpus: eine einzige Datei mit 50 "foo"-Vorkommen, Cap auf 10 gesetzt.
    // Der Cap MUSS greifen, da die eine Datei 50 > 10 Treffer liefert.
    let c = try FolderCorpus()
    try c.write("many.txt", String(repeating: "foo\n", count: 50))
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false),
                              maxResultsPerFile: 5000,
                              maxTotalMatches: 10)
    // Cap muss ausgelöst haben.
    #expect(r.wasCapped == true)
    // MATERIALISIERT wird höchstens der Cap (Speicher-/Arbeitsschutz).
    #expect(r.perFile.reduce(0) { $0 + $1.matches.count } <= 10)
    // ABER: totalMatches meldet seit dem Review-Fix 2026-06-23 den WAHREN
    // Count der gescannten Datei (50), nicht die materialisierte Zahl —
    // sonst untercountete eine Datei mit mehr Treffern als dem Cap. `wasCapped`
    // signalisiert, dass die LISTE unvollständig ist.
    #expect(r.totalMatches == 50)
    // Pattern-Fehler darf nicht gesetzt sein.
    #expect(r.invalidPatternMessage == nil)
}

@Test("Per-Datei-Cap: totalMatches meldet WAHREN Count, Liste bleibt gekappt (Review 2026-06-23)")
func find_perFileCap_reportsTrueTotal() throws {
    // Eine Datei mit 8000 Treffern, Pro-Datei-Cap 5000, Gesamt-Cap weit darüber.
    // Vor dem Fix zeigte totalMatches die materialisierten 5000 (Undercount);
    // jetzt den wahren Count 8000. matches bleibt auf 5000 begrenzt (UI-Speicher).
    let c = try FolderCorpus()
    try c.write("many.txt", String(repeating: "foo\n", count: 8000))
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false),
                              maxResultsPerFile: 5000,
                              maxTotalMatches: 100_000)
    #expect(r.perFile.first?.matches.count == 5000)
    #expect(r.perFile.first?.totalMatches == 8000)
    #expect(r.totalMatches == 8000)
    #expect(r.wasCapped == false)  // Gesamt-Cap NICHT ausgelöst
}

@Test("Gesamt-Cap löst NICHT aus wenn Treffer ≤ cap → wasCapped == false")
func find_totalCap_doesNotTriggerBelowCap() throws {
    // Corpus: fünf Treffer insgesamt, Cap auf 100 gesetzt → kein Kappen.
    let c = try FolderCorpus()
    try c.write("a.txt", "foo foo foo")   // 3 Treffer
    try c.write("b.txt", "foo foo")       // 2 Treffer
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false),
                              maxResultsPerFile: 5000,
                              maxTotalMatches: 100)
    #expect(r.wasCapped == false)
    #expect(r.totalMatches == 5)
}

@Test("Gesamt-Cap bricht dateiübergreifend ab: 3 Dateien à 5 Treffer, Cap 7 → Gesamt ≤ 7")
func find_totalCap_breaksAcrossFiles() throws {
    // Jede Datei hat genau 5 Treffer. Cap = 7. Nach Datei 1 (5) + einem
    // Teil von Datei 2 (2) oder nach Datei 1 + Datei 2 (10 > 7) muss die
    // Enumeration abbrechen. Der Gesamt-Cap ist dateiweise — sobald nach
    // dem Einlesen einer Datei totalSoFar >= cap, bricht die Schleife ab.
    // Bei cap 7: Datei 1 liefert 5, addiert → 5 < 7; Datei 2 liefert 5,
    // addiert → 10 >= 7 → capped. Ergebnis: perFile hat ≤ 3 Dateien,
    // totalMatches ≤ 10 (per-file-cap 5000, 2 volle Dateien à 5 = 10).
    let c = try FolderCorpus()
    // Feste Namen erzwingen stabile Enumerationsreihenfolge (alphabetisch).
    try c.write("a.txt", "foo foo foo foo foo")  // 5 Treffer
    try c.write("b.txt", "foo foo foo foo foo")  // 5 Treffer
    try c.write("c.txt", "foo foo foo foo foo")  // 5 Treffer (wird evtl. nie gelesen)
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false),
                              maxResultsPerFile: 5000,
                              maxTotalMatches: 7)
    // Cap muss ausgelöst haben.
    #expect(r.wasCapped == true)
    // Nicht alle drei Dateien konnten vollständig gezählt werden:
    // totalMatches ≤ 10 (maximal 2 Dateien à 5 — dritte wird nie angefangen
    // oder auch der letzte Lauf bricht bei ≥ cap ab).
    #expect(r.totalMatches <= 10)
    // Mindestens eine Datei muss enthalten sein (sonst wäre das Ergebnis leer,
    // was bedeuten würde, die Suche hätte gar nicht stattgefunden).
    #expect(r.filesWithMatches.count >= 1)
}

@Test("Gesamt-Cap zählt den WAHREN Per-Datei-Count, nicht die gekappte Liste (Review 2026-07-03)")
func find_totalCap_usesTrueCountAcrossFiles() throws {
    // Zwei Dateien mit je 6 echten Treffern, Pro-Datei-Cap 3, Gesamt-Cap 5.
    // Die ERSTE Datei überschreitet mit ihrem wahren Count (6) bereits den
    // Gesamt-Cap (5) → die zweite Datei darf NIE gelesen werden.
    // Vor dem Fix zählte der Cap nur die materialisierten 3 Treffer
    // (3 < 5) und las die zweite Datei fälschlich noch mit.
    let c = try FolderCorpus()
    try c.write("a.txt", "foo foo foo foo foo foo")  // 6 echte Treffer
    try c.write("b.txt", "foo foo foo foo foo foo")  // 6 echte Treffer
    let r = FolderSearch.find(in: [c.root], filter: .knownText,
                              options: SearchOptions(find: "foo", replace: "X",
                                                     isRegex: false),
                              maxResultsPerFile: 3,
                              maxTotalMatches: 5)
    #expect(r.wasCapped == true)
    // Nur EINE Datei im Ergebnis — egal welche die Enumeration zuerst
    // liefert (beide sind identisch aufgebaut, der Test ist reihenfolge-fest).
    #expect(r.perFile.count == 1)
    // Der wahre Count der einen gelesenen Datei wird gemeldet …
    #expect(r.totalMatches == 6)
    // … materialisiert bleibt die Liste auf den Pro-Datei-Cap begrenzt.
    #expect(r.perFile.first?.matches.count == 3)
}

@Test("Projekt-Globs schließen Ordner rekursiv und Dateimuster aus")
func folderSearch_projectExclusions() throws {
    let c = try FolderCorpus()
    try c.write("artifact.txt", "NADEL", in: "build")
    try c.write("foo.generated.swift", "NADEL")
    try c.write("keep.swift", "NADEL")
    let result = FolderSearch.find(
        in: [c.root], filter: .knownText,
        options: SearchOptions(find: "NADEL", replace: "", isRegex: false),
        excludedPatterns: ["build", "*.generated.swift"], relativeTo: c.root
    )
    #expect(result.filesWithMatches.map { $0.url.lastPathComponent } == ["keep.swift"])
}

@Test("Datei-Set darf eine einzelne Datei als Suchwurzel enthalten")
func folderSearch_directFileRoot() throws {
    let c = try FolderCorpus()
    let file = try c.write("single.txt", "EINZEL")
    let result = FolderSearch.find(
        in: [file], filter: .knownText,
        options: SearchOptions(find: "EINZEL", replace: "", isRegex: false)
    )
    #expect(result.totalMatches == 1)
    #expect(result.filesWithMatches.first?.url == file)
}

@Test("Überlappende Datei-Set-Wurzeln liefern jede Datei nur einmal")
func folderSearch_deduplicatesOverlappingRoots() throws {
    let c = try FolderCorpus()
    let sources = c.root.appendingPathComponent("Sources")
    try c.write("main.swift", "EINMAL", in: "Sources")
    let result = FolderSearch.find(
        in: [c.root, sources], filter: .knownText,
        options: SearchOptions(find: "EINMAL", replace: "", isRegex: false)
    )
    #expect(result.totalMatches == 1)
    #expect(result.filesWithMatches.count == 1)
}
