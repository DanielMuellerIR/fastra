import Foundation
import Testing
import CodeEditLanguages
@testable import Fastra

@Suite("Dokumentprüfung folgt dem effektiven Format")
@MainActor
struct DocumentLintModeTests {
    private func workspace(with tab: EditorTab) -> Workspace {
        let workspace = Workspace(defaults: testSuiteDefaults(named: "fastra-lint-mode-\(UUID().uuidString)"))
        workspace.tabs = [tab]
        workspace.activeTabID = tab.id
        return workspace
    }

    @Test(arguments: ["daten.txt", "daten.json", "Form.4DForm", "Methode.4dm", "Bild.svg"])
    func manualJSONAndPlainText(filename: String) throws {
        let ws = workspace(with: EditorTab(title: filename, path: "—", content: "{}"))
        ws.setLanguageOverride(.json)
        let mode = try #require(ws.activeDocumentLintMode)
        #expect(mode == (filename == "Form.4DForm" ? .fourDForm : .json))
        guard case .valid = DocumentLinter.lint("{}", mode: mode) else {
            Issue.record("Das angebotene JSON muss tatsächlich als JSON geprüft werden")
            return
        }
        ws.setLanguageOverride(.default)
        #expect(ws.activeDocumentLintMode == nil)
        #expect(ws.activeDocumentFormattingID == nil)
    }

    @Test("Endungsloses erkanntes XML wird trotz HTML-Zeichengrammatik als XML geprüft")
    func detectedXML() throws {
        var tab = EditorTab(title: Workspace.untitledBaseName, path: "—", content: "<root/>")
        tab.contentDetectedFormat = .xml
        tab.contentDetectedLanguage = .html
        let ws = workspace(with: tab)
        let mode = try #require(ws.activeDocumentLintMode)
        #expect(mode == .xml)
        #expect(DocumentLinter.lint(tab.content, mode: mode) == .valid("XML"))
        ws.setLanguageOverride(.html)
        #expect(ws.activeDocumentLintMode == nil)
    }

    @Test(arguments: ["bild.SVG", "datei.xml", "schema.xsd", "stil.xsl", "stil.xslt",
                      "info.plist", "struktur.4DCatalog", "optionen.4DSettings"])
    func automaticXML(filename: String) throws {
        let ws = workspace(with: EditorTab(title: filename, path: "—", content: "<root/>"))
        #expect(ws.activeDocumentFormat.id == .xml)
        let mode = try #require(ws.activeDocumentLintMode)
        #expect(mode == .xml)
        #expect(DocumentLinter.lint("<root/>", mode: mode) == .valid("XML"))
        guard case .issue = DocumentLinter.lint("<root>", mode: mode) else {
            Issue.record("Das angebotene XML muss Syntaxfehler melden")
            return
        }
    }

    @Test("Formular-Schema bleibt innerhalb der JSON-Familie erhalten")
    func formSchemaPriority() throws {
        let source = #"{"pages":"keine Liste"}"#
        let ws = workspace(with: EditorTab(title: "Form.4dform", path: "—", content: source))
        for manual in [false, true] {
            if manual { ws.setLanguageOverride(.json) }
            let mode = try #require(ws.activeDocumentLintMode)
            #expect(mode == .fourDForm)
            guard case .issue(let issue) = DocumentLinter.lint(source, mode: mode) else {
                Issue.record("Formular-Schema wurde nicht ausgeführt")
                return
            }
            #expect(issue.message.contains("/pages"))
        }
        // Dieselbe gültige JSON-Syntax hat ohne Formular-Endung kein Schema.
        ws.tabs[0].title = "daten.txt"
        let jsonMode = try #require(ws.activeDocumentLintMode)
        #expect(DocumentLinter.lint(source, mode: jsonMode) == .valid("JSON"))
    }

    @Test(arguments: ["Methode.4dm", "Methode.txt"])
    func fourDChoiceAndToolEligibility(filename: String) throws {
        var tab = EditorTab(title: filename, path: "—",
                            url: URL(fileURLWithPath: "/tmp/\(filename)"), content: "If (True)")
        tab.customLanguageOverrideID = CustomLanguageRegistry.fourD.id
        let ws = workspace(with: tab)
        let mode = try #require(ws.activeDocumentLintMode)
        #expect(mode == .fourD)
        #expect(mode.canUseTool4D(for: tab) == filename.hasSuffix(".4dm"))
        guard case .hint = DocumentLinter.lint(tab.content, mode: mode) else {
            Issue.record("Der gewählte 4D-Modus muss den ungeschlossenen Block erkennen")
            return
        }
        tab.url = nil
        #expect(!mode.canUseTool4D(for: tab))
    }

    @Test("Sonderansichten bieten trotz JSON-Format keine Prüfung an")
    func noneditableViews() {
        let base = EditorTab(title: "daten.json", path: "—", content: "{}")
        var tabs: [EditorTab] = []
        var tab = base
        tab.readOnlyReason = "Git-Vorversion"
        tabs.append(tab)
        for kind in [GitTabKind.log, .diff, .commit] {
            tab = base
            tab.gitKind = kind
            tabs.append(tab)
        }
        for mode in [EditorDisplayMode.hex, .chunkedText] {
            tab = base
            tab.displayMode = mode
            tabs.append(tab)
        }
        tab = base
        tab.isLoading = true
        tabs.append(tab)
        tab = base
        let side = FileDiffSide(name: "daten.json", path: nil, url: nil, text: "{}")
        tab.fileDiffRequest = FileDiffRequest(left: side, right: side, options: FileDiffOptions())
        tabs.append(tab)
        let ws = workspace(with: base)
        #expect(ws.activeDocumentLintMode == .json)
        for candidate in tabs {
            ws.tabs = [candidate]
            #expect(ws.activeDocumentLintMode == nil)
        }
    }
}
