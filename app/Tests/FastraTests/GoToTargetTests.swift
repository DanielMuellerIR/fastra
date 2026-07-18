// GoToTargetTests.swift
//
// Unit-Tests der „Gehe zum Ziel"-Auflösung (Etappe 7 Wunschpaket
// 2026-07c): Phrasen-Erkennung, 4D-Methoden-/Klassen-/Function-Ziele
// samt Projektbaum-Suche und die Markdown-Linkarten.

import Testing
import Foundation
@testable import Fastra

// MARK: - Phrase unter dem Cursor

@Test("Phrase: Wort, mehrwortiger Name, Klick mitten im Wort")
func phraseUnderCursor() {
    let text = "Meine Methode($x)"
    // Klick auf „Methode" — die Phrase umfasst beide Wörter.
    let range = GoToTarget.phraseRange(in: text, at: 8)
    #expect(range.map { GoToTarget.substring(text, $0) } == "Meine Methode")
    // Klick auf Symbol → keine Phrase.
    #expect(GoToTarget.phraseRange(in: "x:=(1)", at: 3) == nil)
}

// MARK: - 4D-Provider

private func makeFourDProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .canonicalFileURL
        .appendingPathComponent("fastra-gototarget-\(UUID().uuidString)")
    let methods = root.appendingPathComponent("Project/Sources/Methods")
    let classes = root.appendingPathComponent("Project/Sources/Classes")
    try FileManager.default.createDirectory(at: methods,
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: classes,
                                            withIntermediateDirectories: true)
    try "$x:=1".write(to: methods.appendingPathComponent("Ziel Methode.4dm"),
                      atomically: true, encoding: .utf8)
    try "Function greet()".write(to: classes.appendingPathComponent("Kunde.4dm"),
                                 atomically: true, encoding: .utf8)
    return root
}

@Test("4D: Methodenname öffnet die Projektmethode (Dokument-Vorfahren)")
func fourDMethodViaDocument() throws {
    let root = try makeFourDProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = root.appendingPathComponent("Project/Sources/Methods/Aufrufer.4dm")
    let text = "Ziel Methode($p)"
    let action = FourDGoToTarget.resolve(GoToTargetContext(
        text: text, location: 2, documentURL: document, projectURL: nil
    ))
    guard case .openFile(let url) = action else {
        Issue.record("Erwartet openFile, bekommen: \(String(describing: action))")
        return
    }
    #expect(url.lastPathComponent == "Ziel Methode.4dm")
}

@Test("4D: Klassenname öffnet die Klassendatei (Projektwurzel)")
func fourDClassViaProjectRoot() throws {
    let root = try makeFourDProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let action = FourDGoToTarget.resolve(GoToTargetContext(
        text: "$k:=cs.Kunde.new()", location: 7, documentURL: nil,
        projectURL: root
    ))
    guard case .openFile(let url) = action else {
        Issue.record("Erwartet openFile, bekommen: \(String(describing: action))")
        return
    }
    #expect(url.lastPathComponent == "Kunde.4dm")
    #expect(url.path.contains("Classes"))
}

@Test("4D: Function-Definition in der aktuellen Datei springt lokal")
func fourDFunctionJump() {
    let text = """
    Function eins()
    \treturn 1

    Function zwei($x : Integer)
    \treturn $x
    """
    let location = (text as NSString).range(of: "zwei($x").location
    let action = FourDGoToTarget.resolve(GoToTargetContext(
        text: text, location: location + 1, documentURL: nil, projectURL: nil
    ))
    guard case .jumpToRange(let range) = action else {
        Issue.record("Erwartet jumpToRange, bekommen: \(String(describing: action))")
        return
    }
    #expect((text as NSString).substring(with: range).hasPrefix("Function zwei"))
}

@Test("4D: Befehle/Keywords haben kein Projektziel (nil, Geste läuft weiter)")
func fourDCommandsResolveToNil() {
    #expect(FourDGoToTarget.resolve(GoToTargetContext(
        text: "ALERT(\"x\")", location: 2, documentURL: nil, projectURL: nil
    )) == nil)
    #expect(FourDGoToTarget.resolve(GoToTargetContext(
        text: "If (True)", location: 1, documentURL: nil, projectURL: nil
    )) == nil)
}

@Test("4D: Unbekannter Name → Projekt-Suche als Fallback bzw. Meldung")
func fourDFallbacks() throws {
    let root = try makeFourDProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let withProject = FourDGoToTarget.resolve(GoToTargetContext(
        text: "GibtsNicht($x)", location: 2, documentURL: nil, projectURL: root
    ))
    #expect(withProject == .searchProject("GibtsNicht"))
    let without = FourDGoToTarget.resolve(GoToTargetContext(
        text: "GibtsNicht($x)", location: 2, documentURL: nil, projectURL: nil
    ))
    guard case .notFound = without else {
        Issue.record("Erwartet notFound, bekommen: \(String(describing: without))")
        return
    }
}

// MARK: - Markdown-Provider

@Test("Markdown: Link-Ziel unter dem Cursor (Inline, Bild, Autolink, nackt)")
func markdownLinkTargets() {
    let text = """
    Siehe [Doku](docs/anleitung.md "Titel") und ![Bild](bilder/foto.png).
    Autolink: <https://example.org/pfad> und nackt https://example.com/x.
    """
    let ns = text as NSString
    func target(near marker: String) -> String? {
        MarkdownGoToTarget.linkTarget(in: text,
                                      at: ns.range(of: marker).location)
    }
    #expect(target(near: "Doku") == "docs/anleitung.md")
    #expect(target(near: "foto.png") == "bilder/foto.png")
    #expect(target(near: "example.org") == "https://example.org/pfad")
    #expect(target(near: "example.com") == "https://example.com/x")
    // Außerhalb von Links: kein Ziel.
    #expect(target(near: "Siehe") == nil)
}

@Test("Markdown: URLs öffnen im Browser, Anker springen zur Überschrift")
func markdownURLAndAnchor() {
    let text = """
    # Einleitung

    ## Zweiter Abschnitt

    [Sprung](#zweiter-abschnitt) und [Web](https://example.org).
    """
    let ns = text as NSString
    let anchorAction = MarkdownGoToTarget.resolve(GoToTargetContext(
        text: text, location: ns.range(of: "Sprung").location,
        documentURL: nil, projectURL: nil
    ))
    guard case .jumpToRange(let range) = anchorAction else {
        Issue.record("Erwartet jumpToRange, bekommen: \(String(describing: anchorAction))")
        return
    }
    #expect(ns.substring(with: range).contains("Zweiter Abschnitt"))

    let urlAction = MarkdownGoToTarget.resolve(GoToTargetContext(
        text: text, location: ns.range(of: "Web").location,
        documentURL: nil, projectURL: nil
    ))
    #expect(urlAction == .openURL(URL(string: "https://example.org")!))
}

@Test("Markdown: relative Datei öffnet im Editor; fehlende meldet sich")
func markdownRelativeFiles() throws {
    let dir = FileManager.default.temporaryDirectory
        .canonicalFileURL
        .appendingPathComponent("fastra-mdtarget-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("docs"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Ziel".write(to: dir.appendingPathComponent("docs/ziel.md"),
                     atomically: true, encoding: .utf8)
    let document = dir.appendingPathComponent("start.md")
    let text = "[Hin](docs/ziel.md#abschnitt) [Weg](docs/fehlt.md)"
    let ns = text as NSString

    let found = MarkdownGoToTarget.resolve(GoToTargetContext(
        text: text, location: ns.range(of: "Hin").location,
        documentURL: document, projectURL: nil
    ))
    guard case .openFile(let url) = found else {
        Issue.record("Erwartet openFile, bekommen: \(String(describing: found))")
        return
    }
    #expect(url.lastPathComponent == "ziel.md")

    let missing = MarkdownGoToTarget.resolve(GoToTargetContext(
        text: text, location: ns.range(of: "Weg").location,
        documentURL: document, projectURL: nil
    ))
    guard case .notFound = missing else {
        Issue.record("Erwartet notFound, bekommen: \(String(describing: missing))")
        return
    }
}

// MARK: - Provider-Wahl

@Test("Provider-Registry: 4dm und Markdown, sonst keiner")
func providerRegistry() {
    #expect(GoToTarget.provider(forFileName: "methode.4dm") != nil)
    #expect(GoToTarget.provider(forFileName: "README.md") != nil)
    #expect(GoToTarget.provider(forFileName: "notizen.MARKDOWN") != nil)
    #expect(GoToTarget.provider(forFileName: "main.swift") == nil)
    #expect(GoToTarget.provider(forFileName: "ohne-endung") == nil)
}
