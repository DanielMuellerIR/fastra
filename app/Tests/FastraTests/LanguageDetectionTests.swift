// LanguageDetectionTests.swift
//
// Tests für die inhaltsbasierte Spracherkennung (Etappe 3 Wunschpaket
// 2026-07): Positiv-/Negativbeispiele je Format (inklusive absichtlich
// mehrdeutiger Fälle, die Plaintext bleiben MÜSSEN), Hysterese sowie die
// Debounce-/Drossel-Entscheidung als pure Funktion.

import Foundation
import Testing
@testable import Fastra

private typealias Detection = ContentLanguageDetection

// MARK: - Positivfälle (hohe Konfidenz)

@Test("JSON: vollständiges Objekt wird erkannt")
func detect_jsonObject() {
    let text = #"{"name": "Fastra", "version": 21, "tags": ["editor", "regex"]}"#
    #expect(Detection.detect(in: text) == .json)
}

@Test("JSON: Array aus Objekten wird erkannt")
func detect_jsonArray() {
    let text = #"[{"id": 1, "wert": "a"}, {"id": 2, "wert": "b"}]"#
    #expect(Detection.detect(in: text) == .json)
}

@Test("JSON: abgeschnittener Riesen-Paste mit typischem Anfang wird erkannt")
func detect_jsonTruncatedStart() {
    // Bewusst NICHT parsebar (fehlende Klammern), aber eindeutiger Anfang.
    let text = #"{"records": [{"id": 1, "payload": "..."#
        + String(repeating: "x", count: 100)
    #expect(Detection.detect(in: text) == .json)
}

@Test("XML: Deklaration wird erkannt")
func detect_xmlDeclaration() {
    let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<wurzel><kind/></wurzel>"
    #expect(Detection.detect(in: text) == .xml)
}

@Test("XML: wohlgeformtes Dokument ohne Deklaration wird erkannt")
func detect_wellFormedXMLWithoutDeclaration() {
    let text = "<rezepte>\n  <rezept name=\"Brot\"><zutat>Mehl</zutat></rezept>\n</rezepte>"
    #expect(Detection.detect(in: text) == .xml)
}

@Test("HTML: Doctype und <html> werden erkannt")
func detect_html() {
    #expect(Detection.detect(in: "<!DOCTYPE html>\n<html><body>Hi</body></html>") == .html)
    #expect(Detection.detect(in: "<html lang=\"de\"><head></head></html>") == .html)
}

@Test("Markdown: Überschrift + Link/Codezaun werden erkannt")
func detect_markdown() {
    let text = """
    # Projektnotizen

    Siehe [Doku](https://example.org) für Details.

    ## Nächste Schritte
    """
    #expect(Detection.detect(in: text) == .markdown)
}

@Test("CSS: mehrere Regelblöcke werden erkannt")
func detect_css() {
    let text = """
    body { margin: 0; font-family: sans-serif; }
    .sidebar { width: 240px; background: #eee; }
    """
    #expect(Detection.detect(in: text) == .css)
}

@Test("JavaScript: mehrere starke Marker werden erkannt")
func detect_javascript() {
    let text = """
    const zahlen = [1, 2, 3];
    const doppelt = zahlen.map((n) => n * 2);
    console.log(doppelt);
    """
    #expect(Detection.detect(in: text) == .javascript)
}

// MARK: - Negativfälle (müssen Plaintext bleiben)

@Test("Prosa bleibt Plaintext")
func detect_plainProse() {
    let text = """
    Lieber Herr Müller,

    vielen Dank für Ihre Nachricht. Wir melden uns Anfang nächster Woche
    mit einem Terminvorschlag.
    """
    #expect(Detection.detect(in: text) == nil)
}

@Test("Shell-Kommentare sind KEIN Markdown (nur eine Marker-Art)")
func detect_hashCommentsStayPlain() {
    let text = """
    # Konfiguration laden
    # Danach den Dienst neu starten
    wert=42
    """
    #expect(Detection.detect(in: text) == nil)
}

@Test("Einzelnes const ist KEIN JavaScript (C-Code bleibt Plaintext)")
func detect_cCodeStaysPlain() {
    let text = """
    static const int limit = 42;
    int main(void) { return limit; }
    """
    #expect(Detection.detect(in: text) == nil)
}

@Test("Kaputtes Pseudo-XML bleibt Plaintext")
func detect_brokenXMLStaysPlain() {
    let text = "<wurzel><offen>ohne Ende</wurzel>"
    #expect(Detection.detect(in: text) == nil)
}

@Test("Zu kurze Schnipsel bleiben Plaintext")
func detect_tooShortStaysPlain() {
    #expect(Detection.detect(in: "{}") == nil)
    #expect(Detection.detect(in: "# x") == nil)
}

@Test("Ungültige Klammer-Anfänge sind KEIN JSON")
func detect_nonJSONBraceStart() {
    // Sieht klammerig aus, ist aber weder parsebar noch typischer JSON-Start.
    #expect(Detection.detect(in: "{ dies ist nur eine geschweifte Notiz }") == nil)
}

// MARK: - Hysterese

@Test("Hysterese: nil ersetzt eine bestehende Erkennung nicht")
func hysteresis_nilKeepsCurrent() {
    #expect(!Detection.shouldReplace(current: .json, with: nil))
}

@Test("Hysterese: gleiches Format ändert nichts")
func hysteresis_sameFormatNoChange() {
    #expect(!Detection.shouldReplace(current: .json, with: .json))
}

@Test("Hysterese: anderes Format mit hoher Konfidenz ersetzt")
func hysteresis_strongCounterEvidenceReplaces() {
    #expect(Detection.shouldReplace(current: .json, with: .xml))
    #expect(Detection.shouldReplace(current: nil, with: .css))
}

// MARK: - Auslöser/Drossel

@Test("Block-Einfügung (Paste) → sofortige Analyse")
func trigger_bulkInsertIsImmediate() {
    #expect(Detection.trigger(oldLength: 0, newLength: 500,
                              lastAnalyzedLength: nil) == .immediate)
    #expect(Detection.trigger(oldLength: 100, newLength: 700,
                              lastAnalyzedLength: 100) == .immediate)
}

@Test("Normales Tippen → Debounce")
func trigger_typingIsDebounced() {
    #expect(Detection.trigger(oldLength: 100, newLength: 101,
                              lastAnalyzedLength: nil) == .debounced)
    #expect(Detection.trigger(oldLength: 100, newLength: 101,
                              lastAnalyzedLength: 80) == .debounced)
}

@Test("Drossel: minimale Änderung seit letzter Analyse → keine Analyse")
func trigger_throttleSkipsTinyChanges() {
    #expect(Detection.trigger(oldLength: 100, newLength: 101,
                              lastAnalyzedLength: 100) == .none)
    #expect(Detection.trigger(oldLength: 101, newLength: 100,
                              lastAnalyzedLength: 98) == .none)
}

// MARK: - Workspace-Integration (Eignung + manuelle Wahl)

@Test("Eignung: nur ungespeicherte, endungslose Tabs ohne manuelle Wahl")
func eligibility_rules() {
    let plain = EditorTab(title: "Ohne Titel", path: "—")
    #expect(Workspace.isEligibleForContentDetection(plain))

    var withExtension = plain
    withExtension.title = "notizen.txt"
    #expect(!Workspace.isEligibleForContentDetection(withExtension))

    var saved = plain
    saved.url = URL(fileURLWithPath: "/tmp/x")
    #expect(!Workspace.isEligibleForContentDetection(saved))

    var manual = plain
    manual.languageOverride = .json
    #expect(!Workspace.isEligibleForContentDetection(manual))

    var welcome = plain
    welcome.isWelcome = true
    #expect(!Workspace.isEligibleForContentDetection(welcome))
}

@Test("Sofortige Erkennung nach Block-Einfügung setzt die Tab-Sprache")
@MainActor
func workspace_detectsAfterBulkInsert() async throws {
    let suite = "fastra-langdetect-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let tab = EditorTab(title: Workspace.untitledBaseName, path: "—")
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    // Simuliertes Paste über das echte Content-Binding (Block-Einfügung).
    ws.activeTabContent.wrappedValue =
        #"{"name": "Fastra", "version": 21, "aktiv": true}"#

    let deadline = Date().addingTimeInterval(5)
    while ws.tabs[0].contentDetectedLanguage == nil, Date() < deadline {
        await Task.yield()
    }
    #expect(ws.tabs[0].contentDetectedLanguage == .json)
    #expect(ws.tabs[0].contentDetectedFormat == .json)
    #expect(ws.activeDocumentFormat.id == .grammar(.json))
}

@Test("Shebang-Inhalt nutzt die Upstream-Erkennung (bash)")
@MainActor
func workspace_detectsShebang() async throws {
    let suite = "fastra-langdetect-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let tab = EditorTab(title: Workspace.untitledBaseName, path: "—")
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.activeTabContent.wrappedValue = """
    #!/bin/bash
    set -euo pipefail
    echo "Sicherung läuft"
    """

    let deadline = Date().addingTimeInterval(5)
    while ws.tabs[0].contentDetectedLanguage == nil, Date() < deadline {
        await Task.yield()
    }
    #expect(ws.tabs[0].contentDetectedLanguage?.id == .bash)
}

@Test("Manuelle Sprachwahl gewinnt und beendet die Automatik")
@MainActor
func workspace_manualOverrideStopsAutomatic() async throws {
    let suite = "fastra-langdetect-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let ws = Workspace(defaults: defaults)
    let tab = EditorTab(title: Workspace.untitledBaseName, path: "—")
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.setLanguageOverride(.swift)
    #expect(ws.tabs[0].languageOverride == .swift)
    #expect(!Workspace.isEligibleForContentDetection(ws.tabs[0]))

    // Ein JSON-Paste darf die manuelle Wahl NICHT mehr ändern.
    ws.activeTabContent.wrappedValue =
        #"{"name": "Fastra", "version": 21, "aktiv": true}"#
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(ws.tabs[0].contentDetectedLanguage == nil)
    #expect(ws.tabs[0].languageOverride == .swift)
}
