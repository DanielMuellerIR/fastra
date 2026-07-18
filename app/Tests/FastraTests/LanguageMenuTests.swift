// LanguageMenuTests.swift
//
// Anti-Drift-Tests für das Sprachmenü und die Eigen-Sprachen-Registry
// (Etappe 3 Wunschpaket 2026-07b): Jede unterstützte Sprache — gebündelte
// tree-sitter-Grammatiken UND Registry-Eigen-Sprachen — muss im Menü
// wählbar sein; bewusst versteckte IDs bleiben dokumentiert. Dazu das
// Override-Routing: 4D manuell an/aus, unabhängig von der Dateiendung.

import Foundation
import Testing
import CodeEditLanguages
@testable import Fastra

// MARK: - Anti-Drift: Menü-Inhalt

@Test("Jede gebündelte Grammatik (außer dokumentierten hiddenIDs) ist im Menü wählbar")
func menu_containsEveryBundledGrammar() {
    let entryIDs = Set(LanguageMenuSupport.selectableEntries.map(\.id))
    let missing = CodeLanguage.allLanguages
        .filter { $0.language != nil && !LanguageMenuSupport.hiddenIDs.contains($0.id) }
        .filter { !entryIDs.contains("grammar.\($0.id.rawValue)") }
    #expect(missing.isEmpty,
            "Nicht im Menü: \(missing.map(\.tsName)) — Menüquelle driftet")
}

@Test("Jede Eigen-Sprache der Registry ist im Menü wählbar (4D kann nicht mehr vorbeilaufen)")
func menu_containsEveryRegistryLanguage() {
    let entryIDs = Set(LanguageMenuSupport.selectableEntries.map(\.id))
    let missing = CustomLanguageRegistry.all.filter { !entryIDs.contains($0.id) }
    #expect(missing.isEmpty,
            "Eigen-Sprache fehlt im Menü: \(missing.map(\.displayName))")
}

@Test("hiddenIDs bleiben die dokumentierten eingebetteten Hilfs-Grammatiken")
func menu_hiddenIDsStayDocumented() {
    // Wächst diese Liste, muss das eine bewusste, hier nachgezogene
    // Entscheidung sein — kein stilles Verstecken einer echten Sprache.
    #expect(LanguageMenuSupport.hiddenIDs == [.jsdoc, .markdownInline, .regex, .goMod])
}

@Test("Menü: Plaintext steht zuerst, Einträge sind eindeutig")
func menu_plainTextFirstAndUnique() {
    let entries = LanguageMenuSupport.selectableEntries
    #expect(entries.first == .grammar(.default))
    #expect(Set(entries.map(\.id)).count == entries.count, "doppelte Menü-Einträge")
}

@Test("Registry: 4D beschreibt .4dm mit Plaintext-Unterbau")
func registry_fourDDescription() {
    #expect(CustomLanguageRegistry.language(forExtension: "4dm") == CustomLanguageRegistry.fourD)
    #expect(CustomLanguageRegistry.language(forExtension: "4DM") == CustomLanguageRegistry.fourD)
    #expect(CustomLanguageRegistry.fourD.baseGrammar == .default)
    // Projekt-Begleitdateien sind echte JSON-/XML-Dateien — KEINE Eigen-Sprache.
    #expect(CustomLanguageRegistry.language(forExtension: "4dproject") == nil)
    #expect(CustomLanguageRegistry.language(forExtension: "4dcatalog") == nil)
}

// MARK: - Override-Routing (4D an/aus, unabhängig von der Endung)

private func tab(title: String, url: URL? = nil) -> EditorTab {
    EditorTab(title: title, path: "—", url: url)
}

@Test(".4dm ohne Override → 4D aktiv (Endungs-Automatik unverändert)")
func routing_automaticFourD() {
    let t = tab(title: "methode.4dm",
                url: URL(fileURLWithPath: "/tmp/methode.4dm"))
    #expect(EditorView.customLanguage(for: t) == CustomLanguageRegistry.fourD)
}

@Test("Manuelle 4D-Wahl aktiviert 4D auch an einer Nicht-.4dm-Datei")
func routing_manualFourDOnForeignExtension() {
    var t = tab(title: "notizen.txt", url: URL(fileURLWithPath: "/tmp/notizen.txt"))
    t.customLanguageOverrideID = CustomLanguageRegistry.fourD.id
    #expect(EditorView.customLanguage(for: t) == CustomLanguageRegistry.fourD)
}

@Test("Manuelle GRAMMATIK-Wahl schaltet 4D an einer .4dm-Datei ab")
func routing_grammarOverrideLeavesFourD() {
    var t = tab(title: "methode.4dm", url: URL(fileURLWithPath: "/tmp/methode.4dm"))
    t.languageOverride = .json
    #expect(EditorView.customLanguage(for: t) == nil)
}

@Test("Ohne Override und ohne 4D-Endung → keine Eigen-Sprache")
func routing_plainFileStaysPlain() {
    let t = tab(title: "notizen.txt", url: URL(fileURLWithPath: "/tmp/notizen.txt"))
    #expect(EditorView.customLanguage(for: t) == nil)
}

@Test("Ungespeicherter Tab: Titel-Endung .4dm reicht für die Automatik")
func routing_titleExtensionCounts() {
    #expect(EditorView.customLanguage(for: tab(title: "neu.4dm")) == CustomLanguageRegistry.fourD)
}

// MARK: - Workspace-Setter halten die Invariante (höchstens ein Override)

@Test("setCustomLanguageOverride setzt 4D und räumt die Grammatik-Wahl")
@MainActor
func workspace_setCustomOverride() {
    let suite = "fastra-test-lang-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let ws = Workspace(defaults: defaults)
    ws.tabs = [tab(title: "notizen.txt", url: URL(fileURLWithPath: "/tmp/notizen.txt"))]
    ws.activeTabID = ws.tabs[0].id

    ws.setLanguageOverride(.json)
    ws.setCustomLanguageOverride(CustomLanguageRegistry.fourD)
    #expect(ws.tabs[0].customLanguageOverrideID == CustomLanguageRegistry.fourD.id)
    #expect(ws.tabs[0].languageOverride == nil)

    // Grammatik-Wahl verlässt die Eigen-Sprache wieder.
    ws.setLanguageOverride(.swift)
    #expect(ws.tabs[0].customLanguageOverrideID == nil)
    #expect(ws.tabs[0].languageOverride == .swift)

    // „Automatisch“ räumt beides.
    ws.setCustomLanguageOverride(CustomLanguageRegistry.fourD)
    ws.setLanguageOverride(nil)
    #expect(ws.tabs[0].customLanguageOverrideID == nil)
    #expect(ws.tabs[0].languageOverride == nil)
}
