import Foundation
import Testing
@testable import Fastra

private typealias ClipboardItems = SelfTestPasteboardBackup.Items
private typealias ClipboardSession = SelfTestPasteboardSession<ClipboardItems>

/// Nur das Backend besitzt die simulierte Zwischenablage und das Journal;
/// der getestete Session-Typ verwaltet seinen eigenen, privaten Besitzstand.
private final class ClipboardBackend {
    static let original: ClipboardItems = [
        ["text": Data([1, 2]), "html": Data([3])], ["image": Data([4, 5])]
    ]
    static let expected: ClipboardItems = [["text": Data([6])], ["image": Data([7])]]
    var count = 6
    var items = original
    var journal: SelfTestPasteboardBackup?
    var captures = 0
    var persists = 0
    var writes = 0
    var abandons = 0
    var events: [String] = []
    var capture: (() throws -> ClipboardItems)?
    var failPersistAt: Int?
    var failPrepareRestore = false
    var failWrite = false
    var restoreCountStep = 1

    lazy var session = ClipboardSession(backend: .init(
        currentChangeCount: { [unowned self] in self.count },
        captureItems: { [unowned self] in
            self.captures += 1
            return try self.capture?() ?? self.items
        },
        persistBackup: { [unowned self] backup in
            self.persists += 1
            self.events.append("persist-\(backup.ownedChangeCount)-\(backup.mutationConfirmed)")
            if self.persists == self.failPersistAt { throw Self.failure }
            self.journal = backup
        },
        abandonBackup: { [unowned self] in
            self.abandons += 1
            self.events.append("abandon")
            self.journal = nil
        },
        prepareRestore: { [unowned self] items in
            self.events.append("prepare-restore")
            if self.failPrepareRestore { throw Self.failure }
            return items
        },
        writeRestore: { [unowned self] items in
            self.writes += 1
            self.events.append("write-restore")
            self.count += self.restoreCountStep
            if self.failWrite { throw Self.failure }
            self.items = items
        }
    ))

    static var failure: NSError {
        NSError(domain: "ClipboardFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Backend fehlgeschlagen"])
    }

    func mutate() {
        events.append("mutate")
        count += 1
        items = Self.expected
    }

    func confirm() throws {
        try session.prepare()
        mutate()
        try session.note(expectedItems: Self.expected)
    }
}

@Test("Fremdkopie während der ersten Sicherung erlaubt weder Mutation noch spätere Rückgabe", arguments: [false, true], [false, true])
func clipboardSessionForeignDuringInitialCapture(_ unreadable: Bool, _ matchingItems: Bool) throws {
    let backend = ClipboardBackend()
    let newer: ClipboardItems = [["new-user-copy": Data([9])]]
    backend.capture = {
        let captured = backend.items
        backend.count += 1
        backend.items = newer
        if unreadable { throw NSError(domain: "FastraSelfTestPasteboard", code: 4) }
        return matchingItems ? newer : captured
    }
    do {
        try backend.session.prepare()
        Issue.record("Veraltete Sicherung hat die Testmutation freigegeben")
    } catch {
        #expect(ClipboardSession.outcome(for: error) == .environment)
    }
    #expect(backend.session.expectedChangeCount == nil)
    #expect(backend.journal == nil)
    #expect(backend.persists == 0)
    guard case .none = backend.session.finish() else {
        Issue.record("Ungebundene Sicherung wurde zurückgegeben"); return
    }
    #expect(backend.items == newer)
    #expect(backend.count == 7)
    #expect(backend.writes == 0)
}

@Test("Eine Kopie vor der ersten Sicherung wird selbst zur Rückgabebasis")
func clipboardSessionForeignBeforeInitialCapture() throws {
    let backend = ClipboardBackend()
    let newer: ClipboardItems = [["new-user-copy": Data([9])]]
    backend.items = newer
    backend.count = 7
    try backend.confirm()
    guard case .restored = backend.session.finish() else {
        Issue.record("Aktuelle Nutzersicherung fehlt"); return
    }
    #expect(backend.items == newer)
}

@Test("Clipboard journalisiert vor der Änderung und gibt vollständige Items zurück")
func clipboardSessionRoundTrip() throws {
    let backend = ClipboardBackend()
    try backend.confirm()
    #expect(backend.journal?.items == ClipboardBackend.original)
    #expect(backend.journal?.mutationConfirmed == true)
    #expect(backend.captures == 2)
    // Eine zweite Änderung darf die erste Nutzersicherung nicht ersetzen.
    try backend.session.prepare()
    backend.mutate()
    try backend.session.note(expectedItems: ClipboardBackend.expected)
    #expect(backend.captures == 3)
    guard case .restored = backend.session.finish() else { Issue.record("Rückgabe fehlt"); return }
    #expect(backend.items == ClipboardBackend.original)
    #expect(backend.events == [
        "persist-7-false", "mutate", "persist-7-true",
        "persist-8-false", "mutate", "persist-8-true",
        "prepare-restore", "persist-9-false", "write-restore", "persist-9-true", "abandon"
    ])
    #expect(backend.journal == nil)
    #expect(backend.session.expectedChangeCount == nil)
    guard case .none = backend.session.finish() else { Issue.record("Sicherung doppelt zurückgegeben"); return }
}

private struct ClipboardNoteCase {
    let name: String
    let items: ClipboardItems
    let matches: Bool
}

private let clipboardNoteCases: [ClipboardNoteCase] = [
    .init(name: "vollständig identisch", items: ClipboardBackend.expected, matches: true),
    .init(name: "andere Bytes", items: [["text": Data([8])], ["image": Data([7])]], matches: false),
    .init(name: "anderer Typ", items: [["html": Data([6])], ["image": Data([7])]], matches: false),
    .init(name: "zusätzlicher Typ", items: [["text": Data([6]), "html": Data([6])], ["image": Data([7])]], matches: false),
    .init(name: "fehlendes Item", items: [["text": Data([6])]], matches: false),
    .init(name: "zusätzliches Item", items: ClipboardBackend.expected + [["extra": Data()]], matches: false),
    .init(name: "andere Itemreihenfolge", items: Array(ClipboardBackend.expected.reversed()), matches: false),
    .init(name: "leere Zwischenablage", items: [], matches: false)
]

@Test("Clipboard bestätigt nur Zähler und vollständige Items gemeinsam", arguments: [-1, 0, 1], clipboardNoteCases)
private func clipboardSessionNoteMatrix(_ delta: Int, _ test: ClipboardNoteCase) throws {
    let backend = ClipboardBackend()
    try backend.session.prepare()
    backend.count = 7 + delta
    backend.items = test.items
    var observed: NSError?
    do { try backend.session.note(expectedItems: ClipboardBackend.expected) }
    catch { observed = error as NSError }
    #expect(backend.captures == 2, Comment(rawValue: test.name))
    if delta == 0 && test.matches {
        #expect(observed == nil)
        #expect(backend.journal?.mutationConfirmed == true)
        #expect(backend.persists == 2)
    } else {
        let foreign = delta != 0 && !test.matches
        #expect(observed?.code == (foreign ? 5 : delta == 0 ? 9 : 10))
        #expect(backend.persists == 1)
        #expect(backend.abandons == (foreign ? 1 : 0))
        if foreign {
            guard case .none = backend.session.finish() else { Issue.record("Fremdkopie noch in Besitz"); return }
            #expect(backend.journal == nil)
        } else {
            guard case .failed = backend.session.finish() else { Issue.record("Unbestätigte Änderung zurückgegeben"); return }
            #expect(backend.journal?.mutationConfirmed == false)
        }
        #expect(backend.writes == 0)
        #expect(backend.items == test.items)
    }
}

@Test("Clipboard-Fremdkopie während Capture gibt Besitz auch bei Lesefehler auf", arguments: [false, true], [false, true])
func clipboardSessionForeignDuringCapture(_ unreadable: Bool, _ matchingItems: Bool) throws {
    let backend = ClipboardBackend()
    try backend.session.prepare()
    backend.mutate()
    backend.capture = {
        backend.count += 1
        backend.items = [["foreign": Data([9])]]
        if unreadable { throw NSError(domain: "FastraSelfTestPasteboard", code: 4) }
        return matchingItems ? ClipboardBackend.expected : backend.items
    }
    do {
        try backend.session.note(expectedItems: ClipboardBackend.expected)
        Issue.record("Fremdkopie bestätigt")
    } catch { #expect((error as NSError).code == 5) }
    #expect(backend.captures == 2)
    #expect(backend.abandons == 1)
    guard case .none = backend.session.finish() else { Issue.record("Fremdkopie noch in Besitz"); return }
    #expect(backend.writes == 0)
    #expect(backend.items == [["foreign": Data([9])]])
}

@Test("Clipboard-Capturefehler bei gleichem oder falschem Zähler bleiben unbestätigt", arguments: [-1, 0, 1])
func clipboardSessionCaptureFailure(_ delta: Int) throws {
    let backend = ClipboardBackend()
    try backend.session.prepare()
    backend.count = 7 + delta
    backend.capture = { throw NSError(domain: "FastraSelfTestPasteboard", code: 4) }
    do {
        try backend.session.note(expectedItems: ClipboardBackend.expected)
        Issue.record("Lesefehler bestätigt")
    } catch { #expect((error as NSError).code == (delta == 0 ? 4 : 10)) }
    #expect(backend.captures == 2)
    #expect(backend.abandons == 0)
    guard case .failed = backend.session.finish() else { Issue.record("Unbestätigte Änderung zurückgegeben"); return }
    #expect(backend.journal?.mutationConfirmed == false)
    #expect(backend.writes == 0)
}

@Test("Clipboard-Vorbereitung schützt Fremdkopie und verwendet die ursprüngliche Sicherung")
func clipboardSessionForeignBeforePrepare() throws {
    let backend = ClipboardBackend()
    try backend.confirm()
    backend.count += 1
    backend.items = [["foreign": Data([9])]]
    do { try backend.session.prepare(); Issue.record("Fremdkopie überschreibbar") }
    catch { #expect((error as NSError).code == 1) }
    #expect(backend.persists == 2)
    guard case .keptNewerContent = backend.session.finish() else { Issue.record("Fremdkopie nicht behalten"); return }
    #expect(backend.items == [["foreign": Data([9])]])
    #expect(backend.writes == 0)
    #expect(backend.journal == nil)
}

@Test("Clipboard-Capture- und Persistfehler geben keine ungesicherte Änderung frei", arguments: ["capture", "prepare", "note"])
func clipboardSessionPreparationFailures(_ stage: String) throws {
    let backend = ClipboardBackend()
    if stage == "capture" { backend.capture = { throw ClipboardBackend.failure } }
    else { backend.failPersistAt = stage == "prepare" ? 1 : 2 }
    do {
        try backend.session.prepare()
        backend.mutate()
        try backend.session.note(expectedItems: ClipboardBackend.expected)
        Issue.record("Backendfehler verschluckt")
    } catch { #expect((error as NSError).domain == "ClipboardFixture") }
    #expect(backend.writes == 0)
    if stage == "note" {
        #expect(backend.session.expectedChangeCount == 7)
        #expect(backend.journal?.mutationConfirmed == false)
        guard case .failed = backend.session.finish() else { Issue.record("Fehlende Bestätigung ignoriert"); return }
    } else {
        #expect(backend.session.expectedChangeCount == nil)
        #expect(backend.journal == nil)
        #expect(backend.items == ClipboardBackend.original)
        guard case .none = backend.session.finish() else { Issue.record("Sicherung ohne Vorbereitung"); return }
    }
}

@Test("Clipboard-Abbruch zwischen Vorbereitung und Bestätigung behält die private Sicherung")
func clipboardSessionUnconfirmedAbort() throws {
    let backend = ClipboardBackend()
    try backend.session.prepare()
    // Genau eine fremde Kopie könnte denselben erwarteten Zähler erzeugen.
    backend.count = 7
    backend.items = [["foreign": Data([9])]]
    guard case .failed(let message) = backend.session.finish() else { Issue.record("Abbruch nicht erkannt"); return }
    #expect(message.contains("nicht bestätigt"))
    #expect(backend.journal?.items == ClipboardBackend.original)
    #expect(backend.journal?.mutationConfirmed == false)
    #expect(backend.writes == 0)
    #expect(backend.items == [["foreign": Data([9])]])
}

@Test("Clipboard-Rückgabefehler erhalten Journal und ursprüngliche Sicherung", arguments: ["prepare", "persist-before", "write", "count", "persist-after"])
func clipboardSessionRestoreFailures(_ stage: String) throws {
    let backend = ClipboardBackend()
    try backend.confirm()
    backend.failPrepareRestore = stage == "prepare"
    backend.failPersistAt = stage == "persist-before" ? 3 : stage == "persist-after" ? 4 : nil
    backend.failWrite = stage == "write"
    backend.restoreCountStep = stage == "count" ? 2 : 1
    guard case .failed = backend.session.finish() else { Issue.record("Rückgabefehler verschluckt"); return }
    #expect(backend.abandons == 0)
    #expect(backend.journal?.items == ClipboardBackend.original)
    #expect(backend.journal?.mutationConfirmed == (stage == "prepare" || stage == "persist-before"))
    #expect(backend.writes == (stage == "prepare" || stage == "persist-before" ? 0 : 1))
    if stage != "prepare" && stage != "persist-before" {
        // Auch ein zweiter Abschluss darf nach gescheiterter Rückgabe nicht
        // über einen möglicherweise fremden Inhalt schreiben.
        guard case .failed = backend.session.finish() else { Issue.record("Rückgabe nach Fehler erneut freigegeben"); return }
        #expect(backend.writes == 1)
    }
}

@Test("Clipboard ohne Vorbereitung und nach explizitem Aufgeben schreibt nichts")
func clipboardSessionNoBackupAndAbandon() throws {
    let backend = ClipboardBackend()
    try backend.session.note(expectedItems: ClipboardBackend.expected)
    #expect(backend.captures == 0)
    guard case .none = backend.session.finish() else { Issue.record("Leere Session besitzt Inhalt"); return }
    try backend.confirm()
    backend.session.abandon()
    guard case .none = backend.session.finish() else { Issue.record("Aufgegebene Session besitzt Inhalt"); return }
    #expect(backend.journal == nil)
    #expect(backend.session.expectedChangeCount == nil)
    #expect(backend.writes == 0)
}

@Test("Clipboard gibt auch eine vorhandene leere Sicherung zurück")
func clipboardSessionEmptyBackup() throws {
    let backend = ClipboardBackend()
    backend.items = []
    try backend.confirm()
    guard case .restored = backend.session.finish() else { Issue.record("Leere Sicherung fehlt"); return }
    #expect(backend.items.isEmpty)
    #expect(backend.writes == 1)
}
