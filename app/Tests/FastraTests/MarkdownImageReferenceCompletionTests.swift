import AppKit
import CodeEditTextView
import Foundation
import Testing
@testable import Fastra

private let referencePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGioAAAAASUVORK5CYII=")!

private final class ReferenceRemovalSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private let holds = (0..<8).map { _ in DispatchSemaphore(value: 0) }
    private var enabled = true
    private var arrivals = 0
    private var claims = 0
    private var unlinks = 0

    var counts: (arrivals: Int, claims: Int, unlinks: Int) {
        lock.withLock { (arrivals, claims, unlinks) }
    }

    func hold() {
        let index: Int? = lock.withLock {
            guard enabled else { return nil }
            arrivals += 1
            return arrivals - 1
        }
        if let index, holds.indices.contains(index) { holds[index].wait() }
    }

    func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
    func recordClaim() { lock.withLock { claims += 1 } }
    func recordUnlink() { lock.withLock { unlinks += 1 } }
    func release(_ index: Int) { holds[index].signal() }
    func releaseAll() { holds.forEach { $0.signal() } }

    var hooks: MarkdownImageRemoval.Hooks {
        .init(afterPreparingDirectory: { [self] _ in hold() },
              beforeClaim: { [self] _ in recordClaim() },
              beforeUnlink: { [self] _ in recordUnlink() })
    }
}

@MainActor
private final class ReferenceCompletionFixture {
    let directory: URL
    let document: URL
    let image: MarkdownImageStore.StoredImage
    let view: TextView
    let manager: CEUndoManager
    let history: DocumentUndoHistory
    let buffer = MarkdownImageUndoBuffer(byteLimit: 2 * 1024 * 1024)
    let schedule = ReferenceRemovalSchedule()
    let other: Workspace
    let defaults: UserDefaults
    let suiteName: String
    var warnings: [String] = []

    init() throws {
        let directory = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        let document = directory.appendingPathComponent("A/note.md")
        try FileManager.default.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("B"), withIntermediateDirectories: true)
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: directory) } }
        try Data().write(to: document)
        let image = try MarkdownImageStore.storePastedData(.init(data: referencePNG, fileExtension: "png"), documentURL: document)
        let history = EditorTab(title: "note.md", path: "", content: "").undoHistory
        let view = TextView(string: "")
        let manager = history.manager(for: "")
        view.setUndoManager(manager)
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: image.link)
        history.didEditInSource(view.string)
        suiteName = "fastra-test-image-reference-\(UUID().uuidString)"
        defaults = testSuiteDefaults(named: suiteName)
        other = Workspace(defaults: defaults)
        var tab = EditorTab(title: "other.md", path: "", content: "Version 0")
        tab.url = directory.appendingPathComponent("B/other.md")
        other.tabs = [tab]
        self.directory = directory
        self.document = document
        self.image = image
        self.view = view
        self.manager = manager
        self.history = history
        initialized = true
    }

    func register(removalHooks: MarkdownImageRemoval.Hooks? = nil) {
        MarkdownImageUndo.register(textView: view, insertion: image.link, storedImages: [image],
            documentURL: document, buffer: buffer, removalHooks: removalHooks ?? schedule.hooks,
            redoWarningHandler: { [weak self] _, message in self?.warnings.append(message) })
    }

    func drain() async -> Bool {
        var drained = false
        MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { drained = true }
        return await waitUntil { drained }
    }

    /// Die Obergrenze prüft Endlichkeit, ohne die interne normale Retryanzahl
    /// zum Produktvertrag zu machen. Jede Freigabe entwertet den echten Snapshot.
    func keepChanging(until finished: () -> Bool, onHold: (Int) -> Void = { _ in }) async throws {
        for index in 0..<8 {
            try #require(await waitUntil { self.schedule.counts.arrivals > index || finished() })
            if finished() { return }
            #expect(!view.isEditable || !manager.isUndoing && !manager.isRedoing)
            other.tabs[0].content = "Version \(index + 1)"
            onHold(index)
            schedule.release(index)
        }
        try #require(await waitUntil { finished() })
    }

    func cleanUp() async {
        schedule.setEnabled(false)
        schedule.releaseAll()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        guard await waitUntil({ !manager.isUndoing && !manager.isRedoing }) else {
            Issue.record("Eigene Bildaktion wurde nicht idle; Fixture bleibt in der Sandbox.")
            manager.fastraWhenIdle { [manager] in manager.clearStack() }
            return
        }
        manager.clearStack()
        guard await drain() else {
            Issue.record("Eigener Bildabbau wurde nicht zugestellt; Fixture bleibt in der Sandbox.")
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func withReferenceCompletionFixture(_ body: (ReferenceCompletionFixture) async throws -> Void) async throws {
    let fixture = try ReferenceCompletionFixture()
    defer { fixture.schedule.releaseAll() }
    do { try await body(fixture) }
    catch { await fixture.cleanUp(); throw error }
    await fixture.cleanUp()
}

// Appweite I/O-Halte gehören in die vorhandene exklusive Runnerphase.
@Suite
struct MarkdownImageReferenceCompletionSerialRunnerIntegrationTests {
    @Test("Fortgesetzt wechselnde Referenzen beenden Source-Undo mit einer Warnung und korrektem Redo")
    @MainActor
    func changingReferencesFinishUndo() async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.register()
            fixture.manager.undo()
            var idleCount = 0
            var pendingFinished = false
            fixture.manager.fastraWhenIdle { idleCount += 1 }
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) {
                #expect(!fixture.manager.isUndoing)
                pendingFinished = true
            }
            try await fixture.keepChanging(until: { !fixture.manager.isUndoing }) { _ in
                #expect(!pendingFinished && idleCount == 0)
                #expect(fixture.view.string.isEmpty && !fixture.view.isEditable)
                #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
                #expect(fixture.buffer.byteCount > 0)
            }
            try #require(await waitUntil { pendingFinished })
            #expect(idleCount == 1 && fixture.view.isEditable)
            #expect(!fixture.manager.canUndo && fixture.manager.canRedo)
            #expect(fixture.warnings.count == 1)
            let warning = try #require(fixture.warnings.first)
            #expect(warning.contains(L10n.string("Die Prüfung offener Dokumente wurde nicht stabil abgeschlossen. Verbliebene Bilddateien wurden nicht weiter bereinigt.")))
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
            let terminalCount = fixture.schedule.counts.arrivals
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.view.isEditable)
            #expect(fixture.manager.canUndo && !fixture.manager.canRedo)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0 && idleCount == 1)
            #expect(fixture.schedule.counts.arrivals == terminalCount && fixture.warnings.count == 1)
        }
    }

    @Test("Nach einer Referenzänderung und anschließender Ruhe endet Undo ohne Warnung")
    @MainActor
    func settledReferencesAllowUndoRedo() async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.register()
            fixture.manager.undo()
            var idleCount = 0
            fixture.manager.fastraWhenIdle { idleCount += 1 }
            try #require(await waitUntil { fixture.schedule.counts.arrivals > 0 })
            fixture.other.tabs[0].content = "Neue Fassung"
            fixture.schedule.release(0)
            try #require(await waitUntil { fixture.schedule.counts.arrivals > 1 })
            #expect(fixture.manager.isUndoing && idleCount == 0)
            fixture.schedule.releaseAll()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(idleCount == 1 && fixture.view.string.isEmpty && fixture.view.isEditable)
            #expect(!fixture.manager.canUndo && fixture.manager.canRedo)
            #expect(!FileManager.default.fileExists(atPath: fixture.image.fileURL.path))
            #expect(fixture.buffer.byteCount > 0 && fixture.warnings.isEmpty)
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.manager.canUndo && !fixture.manager.canRedo)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0 && fixture.warnings.isEmpty)
        }
    }

    enum NewReference: CaseIterable {
        case sameFolder, relativeOtherFolder, absolute, fileURL, newTab, movedURL, duplicateURL, opaqueHTML
    }

    @Test("Ein während I/O neuer relevanter URL-Puffer schützt das Bild", arguments: NewReference.allCases)
    @MainActor
    func newReferenceProtectsImage(_ variant: NewReference) async throws {
        try await withReferenceCompletionFixture { fixture in
            if variant == .sameFolder {
                fixture.other.tabs[0].url = fixture.document.deletingLastPathComponent().appendingPathComponent("other.md")
            }
            fixture.register()
            fixture.manager.undo()
            try #require(await waitUntil { fixture.schedule.counts.arrivals > 0 })
            var content = "![x](../A/images/\(fixture.image.fileURL.lastPathComponent))"
            switch variant {
            case .sameFolder: content = fixture.image.link
            case .absolute: content = "![x](<\(fixture.image.fileURL.path)>)"
            case .fileURL: content = "![x](<\(fixture.image.fileURL.absoluteString)>)"
            case .opaqueHTML: content = "<img srcset=\"unknown.png 1x\">"
            case .movedURL:
                fixture.other.tabs[0].url = fixture.document.deletingLastPathComponent().appendingPathComponent("moved.md")
                content = fixture.image.link
            default: break
            }
            if variant == .newTab || variant == .duplicateURL {
                var tab = EditorTab(title: "new.md", path: "", content: content)
                tab.url = variant == .duplicateURL ? fixture.other.tabs[0].url : fixture.directory.appendingPathComponent("B/new.md")
                fixture.other.tabs.append(tab)
            } else { fixture.other.tabs[0].content = content }
            fixture.schedule.releaseAll()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(fixture.view.string.isEmpty && fixture.view.isEditable && fixture.manager.canRedo)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
            #expect(fixture.buffer.byteCount == 0)
            #expect(fixture.warnings.isEmpty, "Gültiger neuer Bildverweis schützt die Datei; ein überholter Gateabbruch darf keine Fehlerwarnung erzeugen.")
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.view.isEditable)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
            #expect(fixture.warnings.isEmpty)
        }
    }

    @Test("Terminaler Wrapperabschluss erhält frühere Effekte und ihre RAM-Tickets")
    @MainActor
    func earlierEffectSurvivesNotSettled() async throws {
        try await withReferenceCompletionFixture { fixture in
            let restoredImage = try MarkdownImageStore.storePastedData(.init(data: referencePNG, fileExtension: "png"), documentURL: fixture.document)
            let first = MarkdownImageUndoSideEffect(images: [fixture.image, restoredImage], buffer: fixture.buffer,
                removalHooks: .init(beforeUnlink: { index in if index == 1 { throw POSIXError(.EIO) } }))
            let secondImage = try MarkdownImageStore.storePastedData(.init(data: referencePNG, fileExtension: "png"), documentURL: fixture.document)
            let second = MarkdownImageUndoSideEffect(images: [secondImage], buffer: fixture.buffer, removalHooks: fixture.schedule.hooks)
            defer { first.discard(); second.discard() }
            var outcome: MarkdownImageUndo.ReferenceWorkResult?
            var completions = 0
            MarkdownImageUndo.performWithReferences(buffer: fixture.buffer, work: { _, gate in
                _ = first.undo(gate: gate)
                return .capture(second.undo(gate: gate), effects: [first, second])
            }, completion: { result in outcome = result; completions += 1 })
            try await fixture.keepChanging(until: { outcome != nil }) { _ in
                #expect(!FileManager.default.fileExists(atPath: fixture.image.fileURL.path))
                #expect(fixture.buffer.byteCount > 0)
            }
            guard case .notSettled = outcome?.outcome else { Issue.record("Terminales notSettled fehlt"); return }
            #expect(completions == 1)
            #expect(try Data(contentsOf: secondImage.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount > 0)
            let warning = try #require(outcome?.removalWarning)
            #expect(!warning.contains(L10n.string("Der Text blieb unverändert.")))
            #expect(warning.contains(POSIXError(.EIO).localizedDescription))
            #expect(warning.contains(fixture.image.fileURL.path) && warning.contains(restoredImage.fileURL.path))
            #expect(try Data(contentsOf: restoredImage.fileURL) == referencePNG)
            #expect(first.redo() && second.redo())
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(try Data(contentsOf: secondImage.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
            #expect(await fixture.drain())
        }
    }

    @Test("Stabiler Mehr-Effekt-Abschluss erhält echten Teilfehler und vergisst nur fremden Gateabbruch")
    @MainActor
    func earlierPartialFailureSurvivesLaterProtectedEffect() async throws {
        try await withReferenceCompletionFixture { fixture in
            let restoredImage = try MarkdownImageStore.storePastedData(.init(data: referencePNG, fileExtension: "png"), documentURL: fixture.document)
            let first = MarkdownImageUndoSideEffect(images: [fixture.image, restoredImage], buffer: fixture.buffer,
                removalHooks: .init(beforeUnlink: { index in if index == 1 { throw POSIXError(.EIO) } }))
            let secondImage = try MarkdownImageStore.storePastedData(.init(data: referencePNG, fileExtension: "png"), documentURL: fixture.document)
            let second = MarkdownImageUndoSideEffect(images: [secondImage], buffer: fixture.buffer, removalHooks: fixture.schedule.hooks)
            defer { first.discard(); second.discard() }
            var outcome: MarkdownImageUndo.ReferenceWorkResult?
            var completions = 0
            MarkdownImageUndo.performWithReferences(buffer: fixture.buffer, work: { opened, gate in
                _ = first.undo(gate: gate)
                guard let references = second.savedReferences(documentURL: fixture.document, opened: opened) else {
                    return .capture(false, effects: [first, second])
                }
                return .capture(second.undo(usedImages: references, gate: gate), effects: [first, second])
            }, completion: { result in outcome = result; completions += 1 })
            try #require(await waitUntil { fixture.schedule.counts.arrivals > 0 })
            fixture.other.tabs[0].content = "![protected](<\(secondImage.fileURL.path)>)"
            fixture.schedule.releaseAll()
            try #require(await waitUntil { outcome != nil })
            guard case .completed(true) = outcome?.outcome else { Issue.record("Stabiler Mehr-Effekt-Abschluss fehlt"); return }
            #expect(completions == 1 && fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
            let payload = try #require(outcome)
            let warning = try #require(payload.removalWarning)
            #expect(warning.contains(POSIXError(.EIO).localizedDescription))
            #expect(!warning.contains(POSIXError(.ECANCELED).localizedDescription))
            #expect(warning.contains(fixture.image.fileURL.path) && warning.contains(restoredImage.fileURL.path))
            #expect(second.removalFailureDescription == nil)
            #expect(fixture.buffer.byteCount > 0)
            #expect(try Data(contentsOf: restoredImage.fileURL) == referencePNG)
            #expect(try Data(contentsOf: secondImage.fileURL) == referencePNG)
            #expect(!FileManager.default.fileExists(atPath: fixture.image.fileURL.path))
            #expect(first.redo() && second.redo())
            #expect(first.removalFailureDescription == nil && second.removalFailureDescription == nil)
            #expect(payload.removalWarning == warning)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
            #expect(await fixture.drain())
        }
    }

    @Test("Historyinvalidierung während terminalem Source-Undo hängt keinen Redo-Schritt ein", arguments: [false, true])
    @MainActor
    func invalidatedHistoryStaysInvalid(_ replaceModel: Bool) async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.register()
            fixture.manager.undo()
            var idleCount = 0
            fixture.manager.fastraWhenIdle { idleCount += 1 }
            try await fixture.keepChanging(until: { !fixture.manager.isUndoing }) { index in
                if index == 0 {
                    if replaceModel { fixture.history.replace("", with: "Neuer Text") }
                    else { fixture.manager.clearStack() }
                }
            }
            #expect(idleCount == 1 && fixture.view.isEditable && fixture.view.string.isEmpty)
            #expect(!fixture.manager.canRedo)
            if !replaceModel { #expect(!fixture.manager.canUndo) }
            #expect(fixture.warnings.count == 1)
            fixture.schedule.setEnabled(false)
            fixture.schedule.releaseAll()
            #expect(await fixture.drain())
            #expect(!fixture.manager.canRedo && fixture.buffer.byteCount == 0)
            if replaceModel {
                let replacement = TextView(string: "Neuer Text")
                replacement.setUndoManager(fixture.history.manager(for: "Neuer Text"))
                #expect(!replacement.undoManager!.canRedo)
                #expect(replacement.string == "Neuer Text")
            }
        }
    }
    @Test("Ein abgewiesenes Mehrbildgate beansprucht keinen Namen")
    @MainActor
    func rejectedBatchHasNoClaims() async throws {
        try await withReferenceCompletionFixture { fixture in
            let second = try MarkdownImageStore.storePastedData(.init(data: referencePNG, fileExtension: "png"), documentURL: fixture.document)
            let effect = MarkdownImageUndoSideEffect(images: [fixture.image, second], buffer: fixture.buffer, removalHooks: fixture.schedule.hooks)
            defer { effect.discard() }
            var outcome: MarkdownImageUndo.ReferenceWorkResult?
            var terminalAtInvalidation: [Bool] = []
            MarkdownImageUndo.performWithReferences(buffer: fixture.buffer,
                work: { _, gate in .capture(effect.undo(gate: gate), effects: [effect]) }, completion: { outcome = $0 })
            try await fixture.keepChanging(until: { outcome != nil }) { _ in
                #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
                fixture.buffer.invalidate { terminalAtInvalidation.append(outcome != nil) }
            }
            guard case .notSettled = outcome?.outcome else { Issue.record("Mehrbildprüfung endet nicht terminal"); return }
            #expect(terminalAtInvalidation.count == fixture.schedule.counts.arrivals)
            #expect(terminalAtInvalidation.last == true)
            for image in [fixture.image, second] { #expect(try Data(contentsOf: image.fileURL) == referencePNG) }
            #expect(fixture.buffer.byteCount == 0)
            #expect(fixture.schedule.counts.claims == 0 && fixture.schedule.counts.unlinks == 0)
        }
    }

    @Test("Abgebrochenes Source-Redo entnimmt ein zuvor unangetastetes Plattenbild nicht")
    @MainActor
    func cancelledRedoLeavesExistingImageUntouched() async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.schedule.setEnabled(false)
            fixture.register()
            var rejectRedo = true
            var laterPreparations = 0
            fixture.manager.fastraRegisterSideEffectForLatestUndo(undo: {}, redo: {},
                prepareRedoAsync: { laterPreparations += 1; $0(!rejectRedo) }, discard: {})
            let held = fixture.directory.appendingPathComponent("held.png")
            try FileManager.default.moveItem(at: fixture.image.fileURL, to: held)
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            try #require(fixture.view.string.isEmpty && fixture.manager.canRedo)
            try FileManager.default.moveItem(at: held, to: fixture.image.fileURL)
            let before = try FileSnapshot.readSnapshotOnly(from: fixture.image.fileURL)
            let counts = fixture.schedule.counts
            let warnings = fixture.warnings
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            try #require(await fixture.drain())
            #expect(laterPreparations == 1)
            #expect(fixture.view.string.isEmpty && fixture.view.isEditable && fixture.manager.canRedo)
            #expect(fixture.schedule.counts.claims == counts.claims && fixture.schedule.counts.unlinks == counts.unlinks)
            #expect(try FileSnapshot.readSnapshotOnly(from: fixture.image.fileURL) == before)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0 && fixture.warnings == warnings)
            rejectRedo = false
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.view.isEditable)
            #expect(try FileSnapshot.readSnapshotOnly(from: fixture.image.fileURL) == before)
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(!FileManager.default.fileExists(atPath: fixture.image.fileURL.path))
            #expect(fixture.buffer.byteCount > 0)
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
        }
    }

    @Test("Source-Redo erklärt ein fehlendes Plattenbild mit Pfad und lässt Text und Retry erhalten")
    @MainActor
    func missingOnDiskImageRejectsSourceRedo() async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.schedule.setEnabled(false)
            fixture.register()
            let held = fixture.directory.appendingPathComponent("held.png")
            try FileManager.default.moveItem(at: fixture.image.fileURL, to: held)
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            let warningCount = fixture.warnings.count
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            try #require(await fixture.drain())
            #expect(fixture.view.string.isEmpty && fixture.view.isEditable && fixture.manager.canRedo)
            let imagePath = fixture.image.fileURL.deletingLastPathComponent().canonicalFileURL
                .appendingPathComponent(fixture.image.fileURL.lastPathComponent).path
            let missingMessage = L10n.format("Die benötigte Bilddatei „%@“ fehlt. Stelle sie am ursprünglichen Pfad wieder bereit und versuche Wiederholen erneut.", imagePath)
            #expect(fixture.warnings.dropFirst(warningCount).contains { message in
                message.contains(missingMessage)
            }, Comment(rawValue: "Erwartet: " + missingMessage + "\n" + fixture.warnings.joined(separator: "\n")))
            #expect(fixture.buffer.byteCount == 0)
            #expect(try Data(contentsOf: held) == referencePNG)
            try FileManager.default.moveItem(at: held, to: fixture.image.fileURL)
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
        }
    }

    @Test("Source-Redo übernimmt externe Bildaktualisierungen am selben Pfad", arguments: [false, true])
    @MainActor
    func updatedOnDiskImageIsAcceptedBySourceRedo(_ atomic: Bool) async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.schedule.setEnabled(false)
            fixture.register()
            let held = fixture.directory.appendingPathComponent("held.png")
            try FileManager.default.moveItem(at: fixture.image.fileURL, to: held)
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            try FileManager.default.moveItem(at: held, to: fixture.image.fileURL)
            let updated = referencePNG + Data("extern aktualisiert".utf8)
            try updated.write(to: fixture.image.fileURL, options: atomic ? .atomic : [])
            let before = try FileSnapshot.readSnapshotOnly(from: fixture.image.fileURL)
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.view.isEditable)
            #expect(try FileSnapshot.readSnapshotOnly(from: fixture.image.fileURL) == before)
            #expect(try Data(contentsOf: fixture.image.fileURL) == updated)
            #expect(fixture.buffer.byteCount == 0)
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(fixture.view.string.isEmpty)
            #expect(try FileSnapshot.readSnapshotOnly(from: fixture.image.fileURL) == before)
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link)
            #expect(try Data(contentsOf: fixture.image.fileURL) == updated)
        }
    }

    @Test("Erschöpfter Redo-Rückbau meldet eigene Reste und gibt Editor und Redo frei")
    @MainActor
    func cancelledRedoFinishesWithRetainedFile() async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.schedule.setEnabled(false)
            fixture.register()
            var rejectRedo = true
            fixture.manager.fastraRegisterSideEffectForLatestUndo(undo: {}, redo: {},
                prepareRedoAsync: { $0(!rejectRedo) }, discard: {})
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(!FileManager.default.fileExists(atPath: fixture.image.fileURL.path))
            #expect(fixture.buffer.byteCount > 0)
            fixture.schedule.setEnabled(true)
            fixture.manager.redo()
            var idleCount = 0
            fixture.manager.fastraWhenIdle { idleCount += 1 }
            try await fixture.keepChanging(until: { !fixture.manager.isRedoing }) { _ in
                #expect(idleCount == 0 && !fixture.view.isEditable && fixture.view.string.isEmpty)
                #expect(fixture.buffer.byteCount > 0)
            }
            #expect(idleCount == 1 && fixture.view.isEditable && fixture.view.string.isEmpty)
            #expect(fixture.manager.canRedo && !fixture.manager.canUndo)
            #expect(fixture.warnings.count == 1)
            #expect(fixture.warnings[0].contains(L10n.string("Die Prüfung offener Dokumente wurde nicht stabil abgeschlossen. Verbliebene Bilddateien wurden nicht weiter bereinigt.")))
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
            fixture.schedule.setEnabled(false)
            rejectRedo = false
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.view.isEditable)
            #expect(fixture.manager.canUndo && !fixture.manager.canRedo)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0 && fixture.warnings.count == 1)
        }
    }

    @Test("Speichern und Verwerfen beenden eine instabile Bildbereinigung sichtbar", arguments: [false, true])
    @MainActor
    func lifecycleFinishesWithWarning(_ discard: Bool) async throws {
        try await withReferenceCompletionFixture { fixture in
            try fixture.image.link.write(to: fixture.document, atomically: true, encoding: .utf8)
            fixture.register()
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(fixture.manager.canRedo && fixture.warnings.isEmpty)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            try Data().write(to: fixture.document)
            if discard { fixture.manager.clearStack() }
            else { fixture.manager.fastraDocumentSaved("", at: fixture.document) }
            var finished = false
            MarkdownImageUndoSideEffect.pendingIO.notify(queue: .main) { finished = true }
            try await fixture.keepChanging(until: { finished })
            #expect(fixture.warnings.count == 1 && fixture.view.string.isEmpty && fixture.view.isEditable)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(try Data(contentsOf: fixture.document).isEmpty)
            #expect(fixture.buffer.byteCount == 0 && fixture.schedule.counts.claims == 0)
            if discard { #expect(!fixture.manager.canUndo && !fixture.manager.canRedo) }
            else {
                fixture.manager.redo()
                try #require(await waitUntil { !fixture.manager.isRedoing })
                #expect(fixture.view.string == fixture.image.link && fixture.manager.canUndo)
                #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            }
        }
    }

    @Test("Explizites Cleanup verwirft einen veralteten Snapshot ohne erneuten Löschversuch")
    @MainActor
    func explicitCleanupKeepsRejectedPreview() async throws {
        try await withReferenceCompletionFixture { fixture in
            let snapshot = MarkdownImageUndo.openDocumentContents()
            let preview = try MarkdownImageCleanup.plan(documentURL: fixture.document, content: "", openDocuments: snapshot)
            #expect(preview.candidates.map(\.fileURL) == [fixture.image.fileURL.canonicalFileURL])
            var gateCalls = 0
            let baseGate = MarkdownImageUndo.removalGate(for: snapshot)
            let gate: (() -> Bool) -> Bool = { commit in
                // apply läuft im Hintergrund; nur der bestehende Gatecheck
                // wird auf Main zugestellt.
                DispatchQueue.main.sync { gateCalls += 1 }
                return baseGate(commit)
            }
            fixture.other.tabs[0].content = "![x](../A/images/\(fixture.image.fileURL.lastPathComponent))"
            let result = await Task.detached { Result { try MarkdownImageCleanup.apply(preview, gate: gate) } }.value
            guard case .failure(let error) = result,
                  let removal = error as? MarkdownImageRemoval.Result else {
                Issue.record("Die ungültige Cleanup-Vorschau wurde nicht abgewiesen")
                return
            }
            #expect(gateCalls == 1 && removal.removed.isEmpty && removal.restored.isEmpty)
            #expect(removal.remainingEntries.isEmpty)
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(preview.candidates.map(\.fileURL) == [fixture.image.fileURL.canonicalFileURL])
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.image.fileURL.deletingLastPathComponent().path) == [fixture.image.fileURL.lastPathComponent])
        }
    }

    @Test("Ein echter ECANCELED-Dateifehler bleibt ohne Gateablehnung sichtbar")
    @MainActor
    func realCancellationErrorIsNotSuppressed() async throws {
        try await withReferenceCompletionFixture { fixture in
            fixture.register(removalHooks: .init(beforeClaim: { _ in throw POSIXError(.ECANCELED) }))
            fixture.manager.undo()
            try #require(await waitUntil { !fixture.manager.isUndoing })
            #expect(fixture.view.string.isEmpty && fixture.view.isEditable && fixture.manager.canRedo)
            #expect(fixture.warnings.count == 1)
            let warning = try #require(fixture.warnings.first)
            #expect(warning.contains(POSIXError(.ECANCELED).localizedDescription))
            #expect(!warning.contains(L10n.string("Die Prüfung offener Dokumente wurde nicht stabil abgeschlossen. Verbliebene Bilddateien wurden nicht weiter bereinigt.")))
            #expect(try Data(contentsOf: fixture.image.fileURL) == referencePNG)
            #expect(fixture.buffer.byteCount == 0)
            fixture.manager.redo()
            try #require(await waitUntil { !fixture.manager.isRedoing })
            #expect(fixture.view.string == fixture.image.link && fixture.warnings.count == 1)
        }
    }

}
