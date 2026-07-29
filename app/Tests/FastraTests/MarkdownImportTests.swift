// MarkdownImportTests.swift
//
// Fastra darf KEIN eigenes Formatwissen führen — alles kommt aus der Antwort
// von `poormans-text --formats --json`. Diese Tests sichern genau die
// Übergänge: Antwort lesen, Endung zuordnen, Zielnamen bilden, Werkzeug finden.
// Die echte Umwandlung mit echten Dateien prüft der Selbsttest `markdownimport`.

import Foundation
import Testing
@testable import Fastra

private let catalogSample = Data("""
{
  "ok": true,
  "version": "0.6.0",
  "formats": [
    {"format":"rtf","extensions":["rtf"],"container":"file",
     "requires":["pandoc"],"available":true},
    {"format":"rtfd","extensions":["rtfd"],"container":"package",
     "requires":["pandoc"],"available":true},
    {"format":"doc","extensions":["doc"],"container":"file",
     "requires":["textutil","pandoc"],"available":false,
     "unavailableReason":"missing required tool: pandoc"}
  ]
}
""".utf8)

@Suite("Markdown-Formatkatalog")
struct MarkdownImportCatalogTests {

    @Test("Katalog liefert Endung, Ablageform und Verfügbarkeit")
    func decodesFormats() throws {
        let catalog = try #require(MarkdownImportCatalog.decode(catalogSample))
        #expect(catalog.toolVersion == "0.6.0")
        #expect(catalog.formats.count == 3)

        let rtfd = try #require(catalog.format(forExtension: "rtfd"))
        #expect(rtfd.isPackage)
        #expect(rtfd.isAvailable)
        #expect(catalog.format(forExtension: "rtf")?.isPackage == false)
    }

    @Test("Endungssuche ignoriert Groß-/Kleinschreibung und führenden Punkt")
    func extensionLookupIsForgiving() throws {
        let catalog = try #require(MarkdownImportCatalog.decode(catalogSample))
        #expect(catalog.format(forExtension: "RTF")?.identifier == "rtf")
        #expect(catalog.format(forExtension: ".Rtf")?.identifier == "rtf")
        #expect(catalog.format(forExtension: "") == nil)
        #expect(catalog.format(forExtension: "txt") == nil)
    }

    @Test("Ein Format ohne installiertes Werkzeug wird nie angeboten")
    func unavailableFormatIsKnownButNotOffered() throws {
        let catalog = try #require(MarkdownImportCatalog.decode(catalogSample))
        // Bekannt bleibt es — sonst könnte Fastra nicht erklären, warum nichts
        // angeboten wird. Angeboten wird es aber nicht, weil Pandoc fehlt.
        #expect(catalog.format(forExtension: "doc") != nil)
        #expect(catalog.availableFormat(forExtension: "doc") == nil)
    }

    @Test("Alles, was kein erfolgreicher Katalog ist, wird verworfen")
    func rejectsEverythingElse() {
        // Ältere CLI ohne `--formats`: gar kein JSON.
        #expect(MarkdownImportCatalog.decode(Data("Error: Unknown option".utf8)) == nil)
        // Fehlerantwort der neuen CLI.
        #expect(MarkdownImportCatalog.decode(Data(#"{"ok":false,"error":"x"}"#.utf8)) == nil)
        // Erfolgsantwort einer KONVERTIERUNG — enthält keine Formatliste.
        #expect(MarkdownImportCatalog.decode(
            Data(#"{"ok":true,"version":"0.6.0","markdownFile":"/tmp/a.md"}"#.utf8)
        ) == nil)
        // Formatliste ohne verwertbaren Eintrag.
        #expect(MarkdownImportCatalog.decode(
            Data(#"{"ok":true,"formats":[{"format":"x","extensions":[]}]}"#.utf8)
        ) == nil)
    }

    @Test("Ein unbekanntes Container-Wort gilt als Datei, nicht als Paket")
    func unknownContainerCountsAsFile() throws {
        // Vorwärtskompatibilität: Ein künftiges Wort darf keinen Ordner
        // fälschlich als Dokument behandeln.
        let catalog = try #require(MarkdownImportCatalog.decode(Data("""
        {"ok":true,"formats":[{"format":"future","extensions":["fut"],
          "container":"something-new","available":true}]}
        """.utf8)))
        #expect(catalog.format(forExtension: "fut")?.isPackage == false)
    }

    @Test("Ein neues Format wirkt ohne jede Änderung an Fastra")
    func newFormatsNeedNoFastraChange() throws {
        // Der eigentliche Zweck der dynamischen Abfrage.
        let catalog = try #require(MarkdownImportCatalog.decode(Data("""
        {"ok":true,"formats":[{"format":"pdf","extensions":["pdf"],
          "container":"file","requires":["pandoc"],"available":true}]}
        """.utf8)))
        #expect(catalog.availableFormat(forExtension: "pdf")?.identifier == "pdf")
        #expect(catalog.isUsable)
    }
}

@Suite("Zielname der Markdown-Umwandlung")
struct MarkdownImportNamingTests {
    private let source = URL(fileURLWithPath: "/docs/Bericht.rtf")

    @Test("Ohne Bilder landet das Markdown direkt neben der Quelle")
    func markdownOnlyIsASiblingFile() {
        let target = MarkdownImportNaming.availableTarget(
            forSource: source, producesAssets: false, exists: { _ in false }
        )
        #expect(target.path == "/docs/Bericht.md")
        #expect(MarkdownImportNaming.markdownFile(inTarget: target, sourceURL: source,
                                                  producesAssets: false).path
                == "/docs/Bericht.md")
    }

    @Test("Mit Bildern entsteht ein Ordner mit dem Dateinamen ohne Endung")
    func assetsLandInAFolder() {
        let target = MarkdownImportNaming.availableTarget(
            forSource: source, producesAssets: true, exists: { _ in false }
        )
        #expect(target.path == "/docs/Bericht")
        #expect(MarkdownImportNaming.markdownFile(inTarget: target, sourceURL: source,
                                                  producesAssets: true).path
                == "/docs/Bericht/Bericht.md")
    }

    @Test("Ein belegter Zielname wird nie überschrieben")
    func existingTargetIsNeverOverwritten() {
        // Bericht.rtf und Bericht.docx im selben Ordner wollen beide
        // „Bericht.md" — der zweite Lauf muss ausweichen.
        let taken: Set<String> = ["/docs/Bericht.md", "/docs/Bericht-2.md"]
        let target = MarkdownImportNaming.availableTarget(
            forSource: source, producesAssets: false,
            exists: { taken.contains($0.path) }
        )
        #expect(target.path == "/docs/Bericht-3.md")
    }

    @Test("Auch der Ordner weicht aus, die Datei darin behält den Quellnamen")
    func folderTargetAlsoAvoidsCollisions() {
        let target = MarkdownImportNaming.availableTarget(
            forSource: source, producesAssets: true,
            exists: { $0.path == "/docs/Bericht" }
        )
        #expect(target.path == "/docs/Bericht-2")
        #expect(MarkdownImportNaming.markdownFile(inTarget: target, sourceURL: source,
                                                  producesAssets: true).path
                == "/docs/Bericht-2/Bericht.md")
    }

    @Test("Eine Quelle ohne Endung kollidiert nicht mit sich selbst")
    func sourceWithoutExtensionStaysSafe() {
        // „Notiz" ohne Endung würde als Ordner „Notiz" die Quelle treffen.
        let bare = URL(fileURLWithPath: "/docs/Notiz")
        let target = MarkdownImportNaming.availableTarget(
            forSource: bare, producesAssets: true,
            exists: { $0.path == "/docs/Notiz" }
        )
        #expect(target.path == "/docs/Notiz-2")
    }
}

@Suite("Suche nach poormans-text")
struct MarkdownImportToolTests {

    @Test("Homebrew-Pfad wird gefunden, obwohl eine GUI-App ihn nicht im PATH erbt")
    func findsHomebrewWithoutPATH() {
        let found = MarkdownImportTool.locate(
            environment: ["PATH": "/usr/bin:/bin"],
            applicationDirectories: [],
            fileManager: StubFileManager(executables: ["/opt/homebrew/bin/poormans-text"])
        )
        #expect(found?.path == "/opt/homebrew/bin/poormans-text")
    }

    @Test("Die CLI im installierten App-Bundle zählt ebenfalls")
    func findsCLIInsideAppBundle() {
        let applications = URL(fileURLWithPath: "/Applications")
        let inside = applications
            .appendingPathComponent(MarkdownImportTool.bundleRelativeExecutablePath)
        let found = MarkdownImportTool.locate(
            environment: [:],
            applicationDirectories: [applications],
            fileManager: StubFileManager(executables: [inside.path])
        )
        #expect(found?.path == inside.path)
    }

    @Test("Eine ausdrücklich gesetzte Fassung gewinnt gegen jede installierte")
    func overrideWins() {
        let found = MarkdownImportTool.locate(
            environment: [MarkdownImportTool.overrideEnvironmentKey: "/build/poormans-text"],
            applicationDirectories: [],
            fileManager: StubFileManager(executables: [
                "/build/poormans-text", "/opt/homebrew/bin/poormans-text",
            ])
        )
        #expect(found?.path == "/build/poormans-text")
    }

    @Test("Fehlt das Werkzeug, wird das ehrlich gemeldet")
    func missingToolIsReported() {
        #expect(MarkdownImportTool.locate(
            environment: ["PATH": "/usr/bin"],
            applicationDirectories: [URL(fileURLWithPath: "/Applications")],
            fileManager: StubFileManager(executables: [])
        ) == nil)
    }
}

@Suite("Antwort einer Umwandlung")
struct MarkdownImportOutputTests {

    @Test("Markdown, Bilder und Warnungen werden gelesen")
    func readsEverything() throws {
        let output = try #require(MarkdownImportOutput.decode(Data("""
        {"ok":true,"markdownFile":"/tmp/out/A.md",
         "assets":["/tmp/out/images/1.png"],"warnings":["Farben gehen verloren"]}
        """.utf8)))
        #expect(output.markdownFile.path == "/tmp/out/A.md")
        #expect(output.assets.map(\.lastPathComponent) == ["1.png"])
        #expect(output.warnings == ["Farben gehen verloren"])
    }

    @Test("Ohne Bilder entsteht eine flache Markdown-Datei")
    func flatResult() throws {
        let output = try #require(MarkdownImportOutput.decode(
            Data(#"{"ok":true,"markdownFile":"/tmp/out/A.md","assets":[]}"#.utf8)
        ))
        #expect(output.assets.isEmpty)
        #expect(output.warnings.isEmpty)
    }

    @Test("Ein Fehler trägt die echte Meldung des Werkzeugs")
    func failureCarriesRealMessage() {
        let data = Data(#"{"ok":false,"version":"0.6.0","error":"Pandoc was not found."}"#.utf8)
        #expect(MarkdownImportOutput.decode(data) == nil)
        #expect(MarkdownImportOutput.decodeError(data) == "Pandoc was not found.")
        #expect(MarkdownImportOutput.decodeError(Data(#"{"ok":true}"#.utf8)) == nil)
    }
}

// Erkanntes Format, aber fehlendes Zusatzprogramm (meist pandoc): Fastra muss
// erklären, WAS fehlt und WIE man es bekommt, statt das Angebot still
// auszublenden (Daniel-Befund 2026-07-29 — Poor Man's Text installiert, pandoc
// nicht, und der RTFD-Import verschwand wortlos).
@Suite("Erklärung bei fehlendem Zusatzprogramm")
struct MarkdownImportUnavailableExplanationTests {

    private func format(reason: String?) -> MarkdownImportFormat {
        MarkdownImportFormat(identifier: "rtfd", fileExtensions: ["rtfd"],
                             isPackage: true, isAvailable: reason == nil,
                             unavailableReason: reason)
    }

    @Test("Die Maschinenform des Werkzeugs wird in Werkzeugnamen zerlegt")
    func parsesMissingTools() {
        #expect(format(reason: "missing required tool: pandoc")
            .missingTools == ["pandoc"])
        #expect(format(reason: "missing required tool: textutil, pandoc")
            .missingTools == ["textutil", "pandoc"])
        #expect(format(reason: nil).missingTools.isEmpty)
        // Unbekannte Meldung → keine Deutung, die Liste bleibt leer.
        #expect(format(reason: "kaputt").missingTools.isEmpty)
    }

    @Test("Fehlendes pandoc erklärt sich samt Installationsbefehl")
    func pandocHintNamesInstallCommand() throws {
        let text = try #require(Workspace.markdownImportUnavailableExplanation(
            for: format(reason: "missing required tool: pandoc")))
        #expect(text.contains("pandoc"))
        #expect(text.contains("brew install pandoc"))
    }

    @Test("Ein unverstandener Grund erscheint wörtlich, ohne pandoc-Rat")
    func unknownReasonShownVerbatim() {
        let text = Workspace.markdownImportUnavailableExplanation(
            for: format(reason: "kaputt"))
        #expect(text == "kaputt")
        // Verfügbares Format → nichts zu erklären.
        #expect(Workspace.markdownImportUnavailableExplanation(
            for: format(reason: nil)) == nil)
    }
}

/// Meldet genau die angegebenen Pfade als ausführbar.
private final class StubFileManager: FileManager, @unchecked Sendable {
    private let executables: Set<String>

    init(executables: [String]) {
        self.executables = Set(executables)
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}
