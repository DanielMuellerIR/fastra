import AppKit
import Darwin
import Foundation
import Testing
@testable import Fastra

@Suite
@MainActor
struct MarkdownImageFailureRetentionSerialRunnerIntegrationTests {
    private func fixture(_ body: (URL, URL, [MarkdownImageStore.StoredImage]) throws -> Void) throws {
        let temporary = testTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.canonicalFileURL
        let document = root.appendingPathComponent("note.md")
        try Data().write(to: document)
        let images = try (0..<2).map { index in
            try MarkdownImageStore.storePastedData(.init(data: Data("image-\(index)".utf8), fileExtension: "png"), documentURL: document)
        }
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Bildfehler-Fixture blieb erhalten: \(error)") }
        }
        try body(root, document, images)
    }

    private func changedReferenceGate(_ document: URL) -> (Workspace, MarkdownImageRemoval.DetailedGate) {
        let other = Workspace()
        var tab = EditorTab(title: "other.md", path: "", content: "before")
        tab.url = document.deletingLastPathComponent().appendingPathComponent("other.md")
        other.tabs = [tab]
        let gate = MarkdownImageUndo.detailedRemovalGate(for: MarkdownImageUndo.openDocumentContents())
        other.tabs[0].content = "after"
        return (other, gate)
    }

    @Test("Bild-Undo meldet die fehlende Schreibberechtigung vor der Entnahme")
    func readOnlyImageDirectoryReportsPreflightFailure() throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let directory = images[0].fileURL.deletingLastPathComponent()
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let effect = MarkdownImageUndoSideEffect(images: images, buffer: buffer)
            var directoryInfo = stat()
            try #require(stat(directory.path, &directoryInfo) == 0)
            let originalMode = directoryInfo.st_mode & 0o777
            try #require(chmod(directory.path, 0o555) == 0)
            defer { #expect(chmod(directory.path, originalMode) == 0) }

            #expect(!effect.undo())
            let result = MarkdownImageUndo.ReferenceWorkResult(
                outcome: .completed(true), files: .capture(true, effects: [effect]))
            #expect(result.removalWarning == POSIXError(.EACCES).localizedDescription)
            #expect(buffer.byteCount == 0)
            let actualNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(Set(actualNames) == Set(images.map(\.fileURL.lastPathComponent)))
            for (index, image) in images.enumerated() {
                #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8))
            }

            #expect(effect.redo())
            #expect(MarkdownImageUndoSideEffect.WorkResult.capture(true, effects: [effect]).removalFailures.isEmpty)
            #expect(effect.documentSaved(visible: true))
            #expect(MarkdownImageUndoSideEffect.WorkResult.capture(true, effects: [effect]).removalFailures.isEmpty)

            try #require(chmod(directory.path, originalMode) == 0)
            try #require(effect.undo())
            try #require(effect.documentSaved(visible: false))
            #expect(effect.removalFailureDescription == nil)
            #expect(result.removalWarning == POSIXError(.EACCES).localizedDescription)
            #expect(images.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
            try #require(effect.redo())
            for (index, image) in images.enumerated() {
                #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8))
            }
        }
    }

    @Test("Terminale Kennung erledigt keinen neueren Referenzabbruch oder echten Dateifehler", arguments: [false, true])
    func terminalRetirementKeepsNewerResult(_ genuine: Bool) throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let files = MarkdownImageUndoFiles(images: images)
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            #expect(!files.removeForUndo(gate: gate))
            let captured = try #require(files.referenceRejectionID)
            let oldResult = try #require(files.lastRemovalResult)
            let oldDescription = files.removalFailureDescription
            if genuine {
                #expect(!files.removeForUndo(hooks: .init(beforeClaim: { _ in throw POSIXError(.ECANCELED) })))
            } else {
                #expect(!files.removeForUndo(gate: gate))
                #expect(files.referenceRejectionID != captured)
            }
            let currentDescription = files.removalFailureDescription
            let currentID = files.referenceRejectionID
            files.retireReferenceRejection(captured)
            #expect(files.removalFailureDescription == currentDescription)
            #expect(files.referenceRejectionID == currentID)
            #expect(oldResult.referenceRejectionID == captured && oldResult.errorDescription == oldDescription)
            if let currentID {
                files.retireReferenceRejection(currentID)
                #expect(files.removalFailureDescription == nil)
            } else {
                #expect(currentDescription?.contains(POSIXError(.ECANCELED).localizedDescription) == true)
            }
            for (index, image) in images.enumerated() {
                #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8))
            }
        }
    }

    @Test("Terminales Erledigen reiner Herkunft erhält echten Teilfehler und alte Payloads", arguments: [POSIXErrorCode.EIO, .ECANCELED])
    func terminalRetirementKeepsGenuinePartialFailure(_ code: POSIXErrorCode) throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let effect = MarkdownImageUndoSideEffect(images: images, removalHooks: .init(beforeUnlink: { index in
                if index == 1 { throw POSIXError(code) }
            }))
            defer { effect.discard() }
            effect.discard(unusedBy: [])
            let oldPayload = MarkdownImageUndoSideEffect.WorkResult.capture(false, effects: [effect])
            let oldMessages = oldPayload.removalFailures
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            effect.discard(unusedBy: [], gate: gate)
            let rejection = try #require(effect.referenceRejectionID)
            let terminalPayload = MarkdownImageUndoSideEffect.WorkResult.capture(false, effects: [effect])
            let terminalMessages = terminalPayload.removalFailures
            effect.retireReferenceRejection(rejection)
            let message = try #require(effect.removalFailureDescription)
            #expect(message.contains(POSIXError(code).localizedDescription))
            #expect(message.contains(images[0].fileURL.path) && message.contains(images[1].fileURL.path))
            #expect(oldPayload.removalFailures == oldMessages && terminalPayload.removalFailures == terminalMessages)
            #expect(effect.referenceRejectionID == nil)
            #expect(!FileManager.default.fileExists(atPath: images[0].fileURL.path))
            #expect(try Data(contentsOf: images[1].fileURL) == Data("image-1".utf8))
        }
    }

    @Test("Teilfehler, weiterer echter Fehler, Referenzgate und Schutz behalten beide Ursachen")
    func genuineFailuresSurviveReferenceProtection() throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            var phase = 0
            var claims = 0
            var unlinks = 0
            let effect = MarkdownImageUndoSideEffect(images: images, removalHooks: .init(
                afterClaim: { _, _ in claims += 1 }, beforeUnlink: { index in
                    unlinks += 1
                    if phase == 0 && index == 1 { throw POSIXError(.EIO) }
                    if phase == 1 { throw POSIXError(.EACCES) }
                }))
            defer { effect.discard() }
            effect.discard(unusedBy: [])
            let first = MarkdownImageUndoSideEffect.WorkResult.capture(false, effects: [effect])
            phase = 1
            effect.discard(unusedBy: [])
            let second = MarkdownImageUndoSideEffect.WorkResult.capture(false, effects: [effect])
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            effect.discard(unusedBy: [], gate: gate)
            let beforeProtection = (claims, unlinks)
            effect.discard(unusedBy: [images[1].fileURL.canonicalFileURL])
            let warning = try #require(effect.removalFailureDescription)
            #expect(warning.contains(POSIXError(.EIO).localizedDescription))
            #expect(warning.contains(POSIXError(.EACCES).localizedDescription))
            #expect(!warning.contains(POSIXError(.ECANCELED).localizedDescription))
            for image in images { #expect(warning.contains(image.fileURL.path)) }
            #expect(claims == beforeProtection.0 && unlinks == beforeProtection.1)
            #expect(try Data(contentsOf: images[1].fileURL) == Data("image-1".utf8))
            #expect(first.removalFailures.count == 1 && !first.removalFailures[0].contains(POSIXError(.EACCES).localizedDescription))
            #expect(second.removalFailures.count == 1 && second.removalFailures[0].contains(POSIXError(.EIO).localizedDescription))
        }
    }

    @Test("Vollständiger permanenter Retry quittiert echte Altfehler, unveränderliche Payloads bleiben gleich")
    func successfulPermanentRetryAcknowledges() throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            var phase = 0
            let effect = MarkdownImageUndoSideEffect(images: images, removalHooks: .init(beforeUnlink: { index in
                if phase == 0 && index == 1 { throw POSIXError(.EIO) }
                if phase == 1 { throw POSIXError(.EACCES) }
            }))
            defer { effect.discard() }
            effect.discard(unusedBy: [])
            let payload = MarkdownImageUndoSideEffect.WorkResult.capture(false, effects: [effect])
            let text = payload.removalFailures
            phase = 1
            effect.discard(unusedBy: [])
            let secondPayload = MarkdownImageUndoSideEffect.WorkResult.capture(false, effects: [effect])
            let secondText = secondPayload.removalFailures
            #expect(secondText.first?.contains(POSIXError(.EACCES).localizedDescription) == true)
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            effect.discard(unusedBy: [], gate: gate)
            phase = 2
            effect.discard(unusedBy: [])
            #expect(effect.removalFailureDescription == nil)
            #expect(secondPayload.removalFailures == secondText)
            #expect(payload.removalFailures == text && text.first?.contains(POSIXError(.EIO).localizedDescription) == true)
            #expect(images.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        }
    }

    @Test("Verschiedene echte Ursachen desselben Fehlercodes bleiben erhalten, sichtbare Zeilen werden dedupliziert")
    func distinctCauseDescriptionsAreMerged() throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            var phase = 0
            let effect = MarkdownImageUndoSideEffect(images: images, removalHooks: .init(beforeClaim: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
                    NSLocalizedDescriptionKey: "cause-\(phase) at image-\(phase)\nshared detail"
                ])
            }))
            defer { effect.discard() }
            #expect(!effect.undo())
            phase = 1
            #expect(!effect.undo())
            #expect(effect.undo(usedImages: [images[0].fileURL.canonicalFileURL]))
            let lines = try #require(effect.removalFailureDescription).components(separatedBy: "\n")
            #expect(lines.contains("cause-0 at image-0") && lines.contains("cause-1 at image-1"))
            #expect(lines.filter { $0 == "shared detail" }.count == 1)
        }
    }

    @Test("Ein Legacy-Erfolgsbool verdeckt keinen echten Fehler seines Commitbodys")
    func legacySuccessCannotHideBodyFailure() throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let effect = MarkdownImageUndoSideEffect(images: images,
                removalHooks: .init(beforeClaim: { _ in throw POSIXError(.ECANCELED) }))
            defer { effect.discard() }
            #expect(!effect.undo(gate: { commit in _ = commit(); return true }))
            #expect(effect.undo(usedImages: [images[0].fileURL.canonicalFileURL]))
            #expect(effect.removalFailureDescription?.contains(POSIXError(.ECANCELED).localizedDescription) == true)
        }
    }

    @Test("Ein Erfolgsbool ohne Dateientnahme quittiert keinen echten früheren Befund")
    func successWithoutCommitDoesNotAcknowledge() throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let files = MarkdownImageUndoFiles(images: images)
            #expect(!files.removePermanently(hooks: .init(beforeUnlink: { index in
                if index == 1 { throw POSIXError(.EIO) }
            })))
            #expect(files.removePermanently(gate: { _ in true }))
            #expect(files.removalFailureDescription?.contains(POSIXError(.EIO).localizedDescription) == true)
            #expect(files.removalFailureDescription?.contains(images[0].fileURL.path) == true)
            #expect(try Data(contentsOf: images[1].fileURL) == Data("image-1".utf8))
        }
    }

    @Test("Allow hat vor geänderten Referenzen Vorrang", arguments: [false, true])
    func disallowedGateIsNeverForgotten(_ changed: Bool) throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let other = Workspace()
            var tab = EditorTab(title: "other.md", path: "", content: "before")
            tab.url = document
            other.tabs = [tab]
            defer { withExtendedLifetime(other) {} }
            var stale = 0
            let gate = MarkdownImageUndo.detailedRemovalGate(for: MarkdownImageUndo.openDocumentContents(),
                allow: { false }, onStale: { stale += 1 })
            if changed { other.tabs[0].content = "after" }
            let effect = MarkdownImageUndoSideEffect(images: images)
            defer { effect.discard() }
            #expect(!effect.undo(gate: gate))
            #expect(effect.undo(usedImages: [images[0].fileURL.canonicalFileURL]))
            #expect(effect.removalFailureDescription?.contains(POSIXError(.ECANCELED).localizedDescription) == true)
            #expect(stale == 1)
            for (index, image) in images.enumerated() { #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8)) }
        }
    }

    @Test("Echtes ECANCELED vor und nach Claim überlebt Folgegate und Schutz", arguments: [false, true])
    func realCancellationSurvives(_ afterClaim: Bool) throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            var fail = true
            let hooks = MarkdownImageRemoval.Hooks(
                beforeClaim: { _ in if fail && !afterClaim { throw POSIXError(.ECANCELED) } },
                afterClaim: { _, _ in if fail && afterClaim { throw POSIXError(.ECANCELED) } })
            let effect = MarkdownImageUndoSideEffect(images: images, removalHooks: hooks)
            defer { effect.discard() }
            effect.discard(unusedBy: [])
            fail = false
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            effect.discard(unusedBy: [], gate: gate)
            effect.discard(unusedBy: [images[0].fileURL.canonicalFileURL])
            let warning = try #require(effect.removalFailureDescription)
            #expect(warning.components(separatedBy: POSIXError(.ECANCELED).localizedDescription).count == 2)
            if afterClaim { #expect(warning.contains(images[0].fileURL.path)) }
        }
    }

    @Test("Echtes ESTALE bleibt trotz gleichem Code eines bereits erledigten Ordnerabschlusses sichtbar")
    func genuineStaleIsNotResolvedCleanupCause() throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            var fail = true
            var unlinks = 0
            let effect = MarkdownImageUndoSideEffect(images: images, removalHooks: .init(
                afterClaim: { _, _ in if fail { throw POSIXError(.ESTALE) } },
                beforeUnlink: { _ in unlinks += 1 }))
            defer { effect.discard() }
            effect.discard(unusedBy: [])
            let stale = POSIXError(.ESTALE).localizedDescription
            let first = try #require(effect.removalFailureDescription)
            #expect(first.components(separatedBy: stale).count == 2)
            fail = false
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            effect.discard(unusedBy: [], gate: gate)
            effect.discard(unusedBy: [images[0].fileURL.canonicalFileURL])
            let final = try #require(effect.removalFailureDescription)
            #expect(final.components(separatedBy: stale).count == 2)
            #expect(!final.contains(POSIXError(.ECANCELED).localizedDescription))
            #expect(unlinks == 0)
            for (index, image) in images.enumerated() { #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8)) }
        }
    }

    @Test("Betretener Commitbody und unbekanntes Legacygate sind keine reine Referenzablehnung", arguments: [false, true])
    func enteredOrUnknownGateIsNotForgotten(_ enterBody: Bool) throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let effect = MarkdownImageUndoSideEffect(images: images)
            defer { effect.discard() }
            if enterBody {
                let gate: MarkdownImageRemoval.DetailedGate = { commit in _ = commit(); return .referencesChanged }
                effect.discard(unusedBy: [], gate: gate)
            } else { effect.discard(unusedBy: [], gate: { _ in false }) }
            effect.discard(unusedBy: [images[0].fileURL.canonicalFileURL])
            #expect(effect.removalFailureDescription?.contains(POSIXError(.ECANCELED).localizedDescription) == true)
            for (index, image) in images.enumerated() { #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8)) }
        }
    }

    @Test("Eine vor neuem Dateiergebnis gescheiterte Vorbereitung vergisst keine Referenzwarnung")
    func attemptStartDoesNotForgetReferenceRejection() throws {
        try fixture { (root: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let effect = MarkdownImageUndoSideEffect(images: images)
            defer { effect.discard() }
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            #expect(!effect.undo(gate: gate))
            let backup = root.appendingPathComponent("temporarily-moved.png")
            try FileManager.default.moveItem(at: images[0].fileURL, to: backup)
            #expect(!effect.undo())
            #expect(effect.removalFailureDescription?.contains(POSIXError(.ECANCELED).localizedDescription) == true)
            try FileManager.default.moveItem(at: backup, to: images[0].fileURL)
            #expect(effect.undo(usedImages: [images[0].fileURL.canonicalFileURL]))
            #expect(effect.removalFailureDescription == nil)
        }
    }

    @Test("Nur positive Schutzgrenzen vergessen reine Referenzablehnungen", arguments: [0, 1, 2, 3, 4])
    func positiveProtectionBoundaries(_ kind: Int) throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let effect = MarkdownImageUndoSideEffect(images: images)
            defer { effect.discard() }
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            #expect(!effect.undo(gate: gate))
            #expect(effect.redo())
            #expect(effect.documentSaved(visible: false))
            #expect(effect.removalFailureDescription != nil)
            switch kind {
            case 0: #expect(effect.undo(usedImages: [images[0].fileURL.canonicalFileURL]))
            case 1:
                effect.protectSavedReferences([images[0].fileURL.canonicalFileURL])
                #expect(effect.undo())
            case 2: #expect(effect.documentSaved(visible: true))
            case 3: effect.discard(unusedBy: [images[0].fileURL.canonicalFileURL])
            default:
                effect.discard()
                effect.discard(unusedBy: [images[0].fileURL.canonicalFileURL])
            }
            #expect((effect.removalFailureDescription == nil) == (kind != 4))
            for (index, image) in images.enumerated() { #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8)) }
        }
    }

    @Test("Referenzablehnung mit erhaltenem Arbeitsordner bleibt ein echter Befund")
    func referenceRejectionWithDirectoryRemainder() throws {
        try fixture { (_: URL, document: URL, images: [MarkdownImageStore.StoredImage]) throws in
            var remainder: URL?
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let effect = MarkdownImageUndoSideEffect(images: images, buffer: buffer,
                removalHooks: .init(afterPreparingDirectory: { directory in
                    remainder = directory
                    try Data("obstruction".utf8).write(to: directory.appendingPathComponent("obstruction"))
                }))
            defer { effect.discard() }
            let (other, gate) = changedReferenceGate(document)
            defer { withExtendedLifetime(other) {} }
            #expect(effect.undo(gate: gate))
            #expect(effect.undo(usedImages: [images[0].fileURL.canonicalFileURL]))
            let retained = try #require(remainder)
            #expect(effect.removalFailureDescription?.contains(retained.path) == true)
            #expect(effect.removalFailureDescription?.contains(POSIXError(.ESTALE).localizedDescription) == true)
            #expect(effect.redo())
            let warning = try #require(effect.removalFailureDescription)
            #expect(warning.contains(L10n.format("Bei einer früheren Bildbereinigung blieb „%@“ erhalten.", retained.path)))
            #expect(FileManager.default.fileExists(atPath: retained.path))
            #expect(buffer.byteCount == 0)
        }
    }

    @Test("Berichtsauflösung erhält Rohresultat, Bool und RAM-Ticket des bisherigen Claimrückbaus")
    func reportingDoesNotChangeRawClaimRollback() throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            #expect(files.removeForUndo(hooks: .init(afterClaim: { _, _ in throw POSIXError(.ECANCELED) })))
            let raw = try #require(files.lastRemovalResult)
            #expect(!raw.complete && !raw.remainingEntries.isEmpty && buffer.byteCount > 0)
            let cleanupIndex = try #require(raw.resolvedDirectoryCauseIndices.first)
            #expect(cleanupIndex == 1 && raw.causes.count == 2)
            #expect((raw.causes[0] as? POSIXError)?.code == .ECANCELED)
            #expect((raw.causes[cleanupIndex] as? POSIXError)?.code == .ESTALE)
            let remainder = try #require(raw.remainingEntries.first)
            #expect(remainder.operationID.map { raw.resolvedOperations.contains($0) } == true)
            let message = try #require(files.removalFailureDescription)
            #expect(message.contains(POSIXError(.ECANCELED).localizedDescription))
            #expect(!message.contains(POSIXError(.ESTALE).localizedDescription))
            #expect(!message.contains(remainder.url.path))
            #expect(files.restoreFromMemory())
            #expect(buffer.byteCount == 0 && files.removalFailureDescription == nil)
            #expect(raw.causes.count == 2 && raw.remainingEntries.count == 1)
            for (index, image) in images.enumerated() { #expect(try Data(contentsOf: image.fileURL) == Data("image-\(index)".utf8)) }
        }
    }

    @Test("Erfolgreiche Wiederherstellung quittiert nur belegte Claims derselben Operation")
    func resolvedClaimRetryAcknowledges() throws {
        try fixture { (_: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            #expect(files.removeForUndo(hooks: .init(beforeUnlink: { index in
                if index == 1 {
                    try Data("foreign".utf8).write(to: images[1].fileURL)
                    throw POSIXError(.EIO)
                }
            })))
            let payload = try #require(files.removalFailureDescription)
            #expect(!files.restoreFromMemory())
            #expect(files.removalFailureDescription?.contains(POSIXError(.EIO).localizedDescription) == true)
            try FileManager.default.removeItem(at: images[1].fileURL)
            #expect(files.restoreFromMemory())
            #expect(files.removalFailureDescription == nil)
            #expect(payload.contains(POSIXError(.EIO).localizedDescription) && payload.contains(images[0].fileURL.path))
            #expect(buffer.byteCount == 0)
        }
    }

    @Test("Abgetrennte eigene Restdatei bleibt nach erfolgreichem Restore historisch gemeldet")
    func detachedRemainderSurvivesSuccessfulRestore() throws {
        try fixture { (root: URL, _: URL, images: [MarkdownImageStore.StoredImage]) throws in
            let backup = root.appendingPathComponent("detached.png")
            let buffer = MarkdownImageUndoBuffer(byteLimit: 1024 * 1024)
            let files = MarkdownImageUndoFiles(images: images, buffer: buffer)
            #expect(files.removeForUndo(hooks: .init(afterClaim: { _, claim in
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.moveItem(at: claim, to: backup)
                    try Data("foreign".utf8).write(to: claim)
                }
            })))
            try FileManager.default.removeItem(at: images[0].fileURL)
            #expect(files.restoreFromMemory())
            let warning = try #require(files.removalFailureDescription)
            #expect(warning.contains(POSIXError(.ESTALE).localizedDescription))
            #expect(warning.contains(L10n.format("Bei einer früheren Bildbereinigung blieb „%@“ erhalten.", backup.path)))
            #expect(try Data(contentsOf: backup) == Data("image-0".utf8))
            #expect(files.removePermanently())
            #expect(files.removalFailureDescription?.contains(backup.path) == true)
            #expect(buffer.byteCount == 0)
        }
    }
}
