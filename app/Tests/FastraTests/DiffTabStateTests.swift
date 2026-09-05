// DiffTabStateTests.swift
//
// Gebündelte Vergleichsfelder von `EditorTab` (Folgeauftrag 2026-09-05,
// kleinste Etappe): Neustart eines Vergleichs-Tabs, Nur-Lese-Sichten und
// die beim Kompilieren ausgeschlossene Kombination „Dokument ohne Auftrag"
// (ein `EditorTab` ohne `fileDiff`/`gitDiff` hat keinen Platz dafür).

import Foundation
import Testing
@testable import Fastra

@Suite("Vergleichsfelder eines Tabs")
struct DiffTabStateTests {

    private func request(_ tag: String) -> FileDiffRequest {
        FileDiffRequest(left: .text("l", name: "links-\(tag)"),
                        right: .text("r", name: "rechts-\(tag)"),
                        options: FileDiffOptions())
    }

    @Test("Ein Neustart verwirft das Ergebnis und erhöht die Generation")
    func restartClearsDocumentAndBumpsGeneration() {
        var state = FileDiffTabState(request: request("a"))
        #expect(state.document == nil)
        #expect(state.loadGeneration == 0)
        state.document = .failure(.tooDifferent(limit: 1))
        let second = request("a")
        let restarted = state.restarted(with: second)
        #expect(restarted.request.id == second.id)
        #expect(restarted.document == nil)
        #expect(restarted.loadGeneration == 1)
        #expect(restarted.restarted(with: second).loadGeneration == 2)
    }

    @Test("Die Nur-Lese-Sichten folgen dem gebündelten Zustand")
    func readOnlyViewsFollowState() {
        var tab = EditorTab(title: "t", path: "p")
        #expect(tab.fileDiffRequest == nil)
        #expect(tab.fileDiffDocument == nil)
        #expect(tab.gitDiffRequest == nil)
        #expect(tab.gitDiffDocument == nil)

        let fileRequest = request("b")
        tab.fileDiff = FileDiffTabState(request: fileRequest)
        #expect(tab.fileDiffRequest?.id == fileRequest.id)
        #expect(tab.fileDiffDocument == nil)
        tab.fileDiff?.document = .failure(.binary(side: .left))
        #expect(tab.fileDiffDocument?.limitation == .binary(side: .left))

        // Ohne Auftrag verschwindet auch das Dokument — es gibt keinen
        // zweiten Speicherplatz, der zurückbleiben könnte.
        tab.fileDiff = nil
        #expect(tab.fileDiffDocument == nil)
    }

    @Test("Ein Git-Diff-Dokument existiert nur zusammen mit seinem Auftrag")
    func gitDocumentNeedsRequest() {
        var tab = EditorTab(title: "g", path: "Git", gitKind: .diff)
        // Ohne Auftrag ist die Zuweisung eines Dokuments wirkungslos —
        // vorher blieb ein verwaistes Dokument im Tab stehen.
        tab.gitDiff?.document = GitDiffDocument(files: [], limitation: nil)
        #expect(tab.gitDiffDocument == nil)
        #expect(tab.gitDiffRequest == nil)
    }
}
