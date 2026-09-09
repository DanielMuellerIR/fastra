import Foundation
import Testing
@testable import Fastra

/// Der Soft-Wrap-Schalter der Fußzeile bedient ein Profil je Dokumentformat.
/// Ein Vergleich hat aber kein Dokumentformat — er zeigt zwei fremde Dateien
/// nebeneinander. Ohne eigenes Profil hinge sein Umbruch an der Endung im
/// Tab-Titel: „Diff: a.swift ↔ b.swift" wäre Swift, „Diff: a.txt ↔ b.txt"
/// Klartext, und derselbe Schalter änderte einmal den Editor und einmal den
/// Vergleich. Deshalb hat die Vergleichsansicht ein eigenes Profil.
@Suite("Soft Wrap im Vergleich")
struct DiffSoftWrapScopeTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "fastra-test-diffwrap-\(UUID().uuidString)"
        return (testSuiteDefaults(named: suite), suite)
    }

    private func diffRequest() -> FileDiffRequest {
        FileDiffRequest(
            left: .file(URL(fileURLWithPath: "/tmp/links.swift")),
            right: .file(URL(fileURLWithPath: "/tmp/rechts.swift")),
            options: FileDiffOptions()
        )
    }

    @Test("Vergleichs-Tab nutzt das Vergleichsprofil, nicht das der Dateien")
    @MainActor
    func diffTabUsesItsOwnProfile() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ws = Workspace(defaults: defaults)

        ws.tabs = [EditorTab(title: "Diff: links.swift ↔ rechts.swift",
                             path: "Vergleich",
                             fileDiff: FileDiffTabState(request: diffRequest()))]
        ws.activeTabID = ws.tabs.first?.id

        #expect(ws.activeTabShowsDiff)
        #expect(ws.softWrapScopeFormatID == .diff)
        // Werkstandard: Der Vergleich bricht um, wie vor der Einstellung.
        #expect(ws.softWrapEnabled)

        ws.setSoftWrapEnabled(false)
        #expect(!ws.softWrapEnabled)
        // Das Profil der verglichenen Sprache bleibt unberührt.
        #expect(ws.softWrapProfiles.isEnabled(for: .diff) == false)
        #expect(!ws.softWrapProfiles.hasOverride(for: .grammar(.swift)))
    }

    @Test("Ein Textdokument bleibt beim Profil seines Formats")
    @MainActor
    func textTabKeepsFormatProfile() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ws = Workspace(defaults: defaults)

        ws.tabs = [EditorTab(title: "notiz.txt", path: "/tmp/notiz.txt",
                             url: URL(fileURLWithPath: "/tmp/notiz.txt"))]
        ws.activeTabID = ws.tabs.first?.id

        #expect(!ws.activeTabShowsDiff)
        #expect(ws.softWrapScopeFormatID == .plainText)
        ws.setSoftWrapEnabled(false)
        #expect(ws.softWrapProfiles.isEnabled(for: .plainText) == false)
        // Der Vergleich hört NICHT mit: Sein Profil steht weiter auf Umbruch.
        #expect(ws.softWrapProfiles.isEnabled(for: .diff))
    }

    @Test("Der Werkstandard des Vergleichs ist Umbruch")
    func diffFactoryDefaultWraps() {
        #expect(SoftWrapFactoryDefaults.isEnabled(for: .diff))
        // Ohne Eintrag in `additionalProfileIDs` fiele der Vergleich aus dem
        // Vollständigkeitstest der Werkseinstellungen.
        #expect(DocumentFormatResolver.additionalProfileIDs.contains(.diff))
    }
}
