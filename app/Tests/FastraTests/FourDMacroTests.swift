// FourDMacroTests.swift
//
// Tests des 4D-Makro-Modells: XML-Parser, Einstufung („was kann Fastra
// damit tun?") und das Absuchen der Fundorte. Alles läuft gegen eingebaute
// Beispieldaten und temporäre Ordner — es braucht weder ein installiertes 4D
// noch ein echtes Projekt.

import Testing
import Foundation
@testable import Fastra

// MARK: - Beispieldaten

/// Nachbau einer echten „Macros v2"-Datei mit allen Formen, die real
/// vorkommen: Kürzel im Namen, Trennlinie, `<method>` mit maskiertem und mit
/// getaggtem `<method_name/>`, ein mehrzeiliges Textmakro mit bedeutungs-
/// tragender Einrückung, ein Zwischenablage-Makro, ein reiner Anzeige-
/// eintrag und ein unbekanntes Platzhalter-Tag.
private let sampleMacrosXML = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE macros SYSTEM "http://www.4d.com/dtd/2007/macros.dtd">
<macros>
  <macro name="Methode analysieren und ergänzen /#" version="2">
    <text><caret/><method>MAO_MethodeKomplettierenNeu("&lt;method_name/&gt;")</method></text>
  </macro>
  <macro name="Komplettieren ohne nicht verwendete /T" version="2">
    <text><method>MAO_MethodeKomplettierenNeu(<method_name/>;False;"";True)</method></text>
  </macro>
  <macro name="Komplettieren ohne var-Umwandlung /ü" version="2">
    <text><method>MAO_MethodeKomplettierenNeu("&lt;method_name/&gt;";False;"";False;False)</method></text>
  </macro>
  <macro name="Komplettieren ohne beides" version="2">
    <text><method>MAO_MethodeKomplettierenNeu("&lt;method_name/&gt;";False;"";True;False)</method></text>
  </macro>
  <macro name="-" version="2"><text> </text></macro>
  <macro name="If" version="2"><text>If (<caret/>)
\t<selection/>
End if</text></macro>
  <macro name="Aus Zwischenablage" version="2"><text><clipboard/></text></macro>
  <macro name="(MAO Makros - Sammlung v5.0" version="2"></macro>
  <macro name="Editor aufräumen /e" version="2">
    <text><method>MAO_EditorAufraeumen("&lt;method_name/&gt;";False)</method></text>
  </macro>
  <macro name="Kopfzeile" version="2"><text>// <user_os/> <date format="4"/> <time format="1"/>
<text/></text></macro>
  <macro name="Unbekanntes Tag" version="2"><text>vor<neuer_platzhalter/>nach</text></macro>
</macros>
"""

/// Die Anzahl wird hier zugesichert, nicht bloß erwartet: Ohne sie würde ein
/// fehlgeschlagener Parser die folgenden Zugriffe mit „Index out of range"
/// den ganzen Testprozess abbrechen lassen — und damit alle übrigen Tests.
private func parseSample() throws -> [FourDMacro] {
    let macros = FourDMacroXML.parse(data: Data(sampleMacrosXML.utf8),
                                     sourceLabel: "MAO.xml")
    try #require(macros.count == 11)
    return macros
}

/// Grund aus einer `.unsupported`-Einstufung — die Texte selbst sind
/// übersetzt, geprüft wird deshalb nur die Einstufung und ein Kernbegriff.
private func unsupportedReason(_ capability: FourDMacroCapability) -> String? {
    if case .unsupported(let reason) = capability { return reason }
    return nil
}

// MARK: - Parser

@Test("Parser: Namen, Kürzel, Trennlinie und stabile IDs")
func macroNamesAndShortcuts() throws {
    let macros = try parseSample()
    #expect(macros.count == 11)

    #expect(macros[0].displayName == "Methode analysieren und ergänzen")
    #expect(macros[0].shortcutKey == "#")
    #expect(macros[0].sourceLabel == "MAO.xml")
    #expect(macros[0].id == "MAO.xml#0")

    // Ein großgeschriebenes Kürzel wird kleingeschrieben gemerkt.
    #expect(macros[1].displayName == "Komplettieren ohne nicht verwendete")
    #expect(macros[1].shortcutKey == "t")
    #expect(macros[2].shortcutKey == "ü")

    // Ohne Suffix bleibt der Name vollständig und es gibt kein Kürzel.
    #expect(macros[3].displayName == "Komplettieren ohne beides")
    #expect(macros[3].shortcutKey == nil)

    #expect(macros[4].isSeparator)
    #expect(macros[4].displayName == "-")
    #expect(macros[4].shortcutKey == nil)
    #expect(macros[4].id == "MAO.xml#4")
    #expect(macros.filter(\.isSeparator).count == 1)
}

@Test("Parser: Kürzel nur bei genau einem Zeichen hinter „ /“")
func macroShortcutSuffixRules() {
    #expect(FourDMacroXML.splitName("Makro /t").shortcutKey == "t")
    #expect(FourDMacroXML.splitName("Makro  /t").displayName == "Makro")
    // Zwei Zeichen sind kein Kürzel — der Name bleibt vollständig stehen.
    #expect(FourDMacroXML.splitName("Makro /ab").shortcutKey == nil)
    #expect(FourDMacroXML.splitName("Makro /ab").displayName == "Makro /ab")
    // Ein Schrägstrich ohne Leerzeichen davor ebenso wenig.
    #expect(FourDMacroXML.splitName("Pfad/t").shortcutKey == nil)
    #expect(FourDMacroXML.splitName("Makro / ").shortcutKey == nil)
}

@Test("Parser: Text-Bausteine samt Zeilenumbruch und Tabulator")
func macroTextParts() throws {
    let macros = try parseSample()

    // Das If-Makro ist der Grund, warum Whitespace erhalten bleiben muss:
    // Der Tabulator ist die Einrückung des eingefügten 4D-Quelltexts.
    #expect(macros[5].displayName == "If")
    #expect(macros[5].textParts == [
        .literal("If ("),
        .caret,
        .literal(")\n\t"),
        .selection,
        .literal("\nEnd if"),
    ])

    #expect(macros[0].textParts == [.caret])
    #expect(macros[6].textParts == [.clipboard])

    // Datums-/Zeitformat kommt als Zahl aus dem Attribut; `<text/>` INNERHALB
    // von `<text>` ist der Platzhalter für den kompletten Methodentext.
    #expect(macros[9].textParts == [
        .literal("// "),
        .userOS,
        .literal(" "),
        .date(format: 4),
        .literal(" "),
        .time(format: 1),
        .literal("\n"),
        .fullText,
    ])

    // Ein unbekanntes Tag wird beim Text übersprungen — der Text drumherum
    // bleibt ein zusammenhängender Baustein —, aber sein Name wird vermerkt.
    #expect(macros[10].textParts == [.literal("vornach")])
    #expect(macros[10].unknownPlaceholder == "neuer_platzhalter")
    #expect(macros[5].unknownPlaceholder == nil)

    // Anzeigeeintrag ohne <text> und ohne <method>: trotzdem vorhanden.
    #expect(macros[7].textParts.isEmpty)
    #expect(macros[7].methodCall == nil)
    #expect(macros[7].displayName == "(MAO Makros - Sammlung v5.0")
}

@Test("Parser: <method> mit maskiertem und mit getaggtem <method_name/>")
func macroMethodCallExtraction() throws {
    let macros = try parseSample()
    // Maskiert (&lt;method_name/&gt;) …
    #expect(macros[0].methodCall == "MAO_MethodeKomplettierenNeu(\"<method_name/>\")")
    // … und als echtes Tag ergeben denselben normalisierten Text.
    #expect(macros[1].methodCall == "MAO_MethodeKomplettierenNeu(<method_name/>;False;\"\";True)")
    #expect(macros[8].methodCall == "MAO_EditorAufraeumen(\"<method_name/>\";False)")
    #expect(macros[5].methodCall == nil)
}

@Test("Parser: kaputtes XML ergibt eine leere Liste, keinen Fehler")
func macroBrokenXML() {
    let broken = "<macros><macro name=\"A\"><text>ohne Ende"
    #expect(FourDMacroXML.parse(data: Data(broken.utf8), sourceLabel: "kaputt.xml").isEmpty)
    #expect(FourDMacroXML.parse(data: Data(), sourceLabel: "leer.xml").isEmpty)
    #expect(FourDMacroXML.parse(data: Data("kein XML".utf8), sourceLabel: "text.xml").isEmpty)
}

// MARK: - Einstufung

@Test("Einstufung: alle vier Komplettieren-Varianten")
func macroCapabilityVariants() throws {
    let macros = try parseSample()
    #expect(FourDMacroXML.capability(of: macros[0]) == .engine(.standard))
    #expect(FourDMacroXML.capability(of: macros[1]) == .engine(.ohneNichtVerwendet))
    #expect(FourDMacroXML.capability(of: macros[2]) == .engine(.ohneVarUmwandlung))
    #expect(FourDMacroXML.capability(of: macros[3]) == .engine(.ohneNichtVerwendetUndVar))
    // Jede Variante hat einen eigenen, stabilen Rohwert.
    #expect(Set(FourDKomplettierenVariant.allCases.map(\.rawValue)).count == 4)
}

@Test("Einstufung: Textmakro, Trennlinie, Anzeigeeintrag, Zwischenablage")
func macroCapabilityKinds() throws {
    let macros = try parseSample()
    #expect(FourDMacroXML.capability(of: macros[5]) == .nativeText)
    #expect(FourDMacroXML.capability(of: macros[9]) == .nativeText)
    // Ein unbekannter Platzhalter macht das Makro NICHT ausführbar: Fastra
    // würde sonst still unvollständigen Text einsetzen.
    #expect(unsupportedReason(FourDMacroXML.capability(of: macros[10]))?
        .contains("neuer_platzhalter") == true)

    #expect(unsupportedReason(FourDMacroXML.capability(of: macros[4]))?.isEmpty == false)
    #expect(unsupportedReason(FourDMacroXML.capability(of: macros[6]))?.isEmpty == false)
    #expect(unsupportedReason(FourDMacroXML.capability(of: macros[7]))?.isEmpty == false)
}

@Test("Einstufung: fremder Methodenaufruf nennt die Methode im Grund")
func macroCapabilityForeignCall() throws {
    let macros = try parseSample()
    let reason = unsupportedReason(FourDMacroXML.capability(of: macros[8]))
    #expect(reason?.contains("MAO_EditorAufraeumen") == true)
}

@Test("Einstufung: nicht zuordenbare Argumente sind kein Engine-Aufruf")
func macroCapabilityUnknownArguments() {
    // $5 = True kennt Fastra nicht; das darf nicht still auf eine
    // Nachbar-Variante fallen, sonst liefe eine andere Komplettierung.
    let xml = """
    <macros><macro name="X" version="2"><text><method>\
    MAO_MethodeKomplettierenNeu("&lt;method_name/&gt;";False;"";True;True)\
    </method></text></macro></macros>
    """
    let macros = FourDMacroXML.parse(data: Data(xml.utf8), sourceLabel: "x.xml")
    #expect(macros.count == 1)
    #expect(unsupportedReason(FourDMacroXML.capability(of: macros[0]))?.isEmpty == false)
}

@Test("Methodenaufruf zerlegen: Semikolon in einer Zeichenkette trennt nicht")
func macroMethodCallParsing() {
    let parsed = FourDMacroXML.parseMethodCall(#"Foo("a;b";False;Bar(1;2);"c\"d")"#)
    #expect(parsed?.name == "Foo")
    #expect(parsed?.arguments == [#""a;b""#, "False", "Bar(1;2)", #""c\"d""#])

    #expect(FourDMacroXML.parseMethodCall("Ohne_Klammern")?.arguments.isEmpty == true)
    #expect(FourDMacroXML.parseMethodCall("Leer()")?.arguments.isEmpty == true)
    // Fehlende schließende Klammer ist kein lesbarer Aufruf.
    #expect(FourDMacroXML.parseMethodCall("Kaputt(\"a\"") == nil)
    #expect(FourDMacroXML.parseMethodCall("   ") == nil)

    #expect(FourDMacroXML.booleanLiteral(" TRUE ") == true)
    #expect(FourDMacroXML.booleanLiteral("False") == false)
    #expect(FourDMacroXML.booleanLiteral("\"False\"") == nil)
}

@Test("Methodenname aus Dateiname: Endung weg, Umlaut zusammengesetzt (NFC)")
func macroNormalizedMethodName() {
    // Das Dateisystem liefert „Ü" zerlegt als „U" plus Trema (NFD).
    let decomposed = "U\u{308}bersicht.4dm"
    #expect(FourDMacroXML.normalizedMethodName(forFileName: decomposed) == "Übersicht")
    #expect(FourDMacroXML.normalizedMethodName(forFileName: "Test.4DM") == "Test")
    #expect(FourDMacroXML.normalizedMethodName(forFileName: "Ohne Endung") == "Ohne Endung")
}

// MARK: - Fundorte

private func makeMacroScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-4dmacros-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Legt eine Datei samt aller fehlenden Ordner an.
private func writeFile(_ url: URL, _ contents: String = "<macros/>") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

/// Minimales App-Bundle mit Version und beliebig vielen Sprachordnern.
private func makeFourDBundle(at appURL: URL, version: String,
                             languages: [String]) throws {
    let plist: [String: Any] = ["CFBundleShortVersionString": version]
    let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml, options: 0)
    try FileManager.default.createDirectory(
        at: appURL.appendingPathComponent("Contents"),
        withIntermediateDirectories: true)
    try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    for language in languages {
        try writeFile(appURL.appendingPathComponent(
            "Contents/Resources/\(language).lproj/Macros.xml"))
    }
}

@Test("Projektwurzel: Aufstieg von der Methodendatei bis zum Ordner mit Project/*.4DProject")
func macroProjectRootAscent() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let root = scratch.appendingPathComponent("MeinProjekt")
    try writeFile(root.appendingPathComponent("Project/MeinProjekt.4DProject"), "{}")
    let method = root.appendingPathComponent("Project/Sources/Methods/X.4dm")
    try writeFile(method, "//%attributes = {}\n")

    #expect(FourDMacroDiscovery.projectRoot(forDocument: method)?.path == root.path)
    // Ohne .4DProject ist es kein Projekt.
    let fremd = scratch.appendingPathComponent("fremd/datei.txt")
    try writeFile(fremd, "x")
    #expect(FourDMacroDiscovery.projectRoot(forDocument: fremd) == nil)
}

@Test("Fundorte: Komponenten (v20 und v21), dependencies.json, Benutzerordner und 4D.app")
func macroSourcesAcrossAllLocations() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let root = scratch.appendingPathComponent("MeinProjekt")

    // Bis 4D v20: Makro-Ordner direkt im Bundle.
    try writeFile(root.appendingPathComponent(
        "Components/AltKomponente.4dbase/Macros v2/macros.xml"))
    // Ab v21: unter Contents.
    try writeFile(root.appendingPathComponent(
        "Components/NeuKomponente.4dbase/Contents/Macros v2/macros.xml"))
    // Eine Komponente von außerhalb, eingebunden über dependencies.json.
    try writeFile(root.appendingPathComponent("Project/Sources/dependencies.json"), """
    {"dependencies": {"ExterneKomponente": {"path": "../Extern/Extern.4dbase"},
                      "OhnePfad": {"version": "1.0.0"}}}
    """)
    try writeFile(scratch.appendingPathComponent(
        "Extern/Extern.4dbase/Contents/Macros v2/macros.xml"))

    let home = scratch.appendingPathComponent("home")
    try writeFile(home.appendingPathComponent(
        "Library/Application Support/4D/Macros v2/eigene.xml"))

    // Zwei 4D-Versionen in Versionsordnern (Tiefe 2) plus Ablenkungen.
    let apps = scratch.appendingPathComponent("Applications")
    try makeFourDBundle(at: apps.appendingPathComponent("4D v20/4D.app"),
                        version: "20.5", languages: ["de", "en"])
    try makeFourDBundle(at: apps.appendingPathComponent("4D v21/4D.app"),
                        version: "21.1", languages: ["de", "en"])
    try makeFourDBundle(at: apps.appendingPathComponent("4D v21/4D Server.app"),
                        version: "21.1", languages: ["de"])
    try makeFourDBundle(at: apps.appendingPathComponent("tool4d.app"),
                        version: "21.1", languages: ["de"])

    let sources = FourDMacroDiscovery.macroSources(
        projectRoot: root, homeDirectory: home, applicationDirectories: [apps],
        preferredLanguages: ["de-DE"]
    )
    #expect(sources.map(\.origin) == [
        .component(name: "AltKomponente"),
        .component(name: "NeuKomponente"),
        .component(name: "ExterneKomponente"),
        .userLibrary,
        .fourDApplication(version: "21.1"),
    ])
    // `require` statt `expect`: Ein zu kurzes Ergebnis soll den Test
    // beenden, nicht den ganzen Testprozess mit „Index out of range".
    try #require(sources.count == 5)
    #expect(sources[2].url.path.hasSuffix("Extern/Extern.4dbase/Contents/Macros v2/macros.xml"))
    #expect(sources[4].url.path.hasSuffix("4D v21/4D.app/Contents/Resources/de.lproj/Macros.xml"))
}

@Test("Fundorte: ohne Projekt bleiben Benutzerordner und 4D.app übrig")
func macroSourcesWithoutProject() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let home = scratch.appendingPathComponent("home")
    try writeFile(home.appendingPathComponent(
        "Library/Application Support/4D/Macros v2/eigene.xml"))
    let sources = FourDMacroDiscovery.macroSources(
        projectRoot: nil, homeDirectory: home,
        applicationDirectories: [scratch.appendingPathComponent("gibt-es-nicht")],
        preferredLanguages: ["de"]
    )
    #expect(sources.map(\.origin) == [.userLibrary])

    // Gar nichts vorhanden: leere Liste statt Fehler.
    let leer = FourDMacroDiscovery.macroSources(
        projectRoot: nil, homeDirectory: scratch.appendingPathComponent("leer"),
        applicationDirectories: [], preferredLanguages: ["de"]
    )
    #expect(leer.isEmpty)
}

@Test("4D.app: Sprachwahl folgt der Systemreihenfolge, sonst dem ersten lproj")
func macroApplicationLanguageChoice() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bundle = scratch.appendingPathComponent("4D.app")
    try makeFourDBundle(at: bundle, version: "21.1", languages: ["de", "en"])

    let fm = FileManager.default
    #expect(FourDMacroDiscovery.applicationMacrosFile(
        inBundle: bundle, preferredLanguages: ["en-US", "de-DE"], fileManager: fm
    )?.lastPathComponent == "Macros.xml")
    #expect(FourDMacroDiscovery.applicationMacrosFile(
        inBundle: bundle, preferredLanguages: ["en-US", "de-DE"], fileManager: fm
    )?.path.contains("/en.lproj/") == true)
    #expect(FourDMacroDiscovery.applicationMacrosFile(
        inBundle: bundle, preferredLanguages: ["de-DE"], fileManager: fm
    )?.path.contains("/de.lproj/") == true)
    // Unbekannte Systemsprache: Deutsch vor Englisch als fester Rückfall.
    #expect(FourDMacroDiscovery.applicationMacrosFile(
        inBundle: bundle, preferredLanguages: ["fr-FR"], fileManager: fm
    )?.path.contains("/de.lproj/") == true)

    // Bringt 4D weder Deutsch noch Englisch mit, gewinnt der erste lproj.
    let nurSpanisch = scratch.appendingPathComponent("Nur-es/4D.app")
    try makeFourDBundle(at: nurSpanisch, version: "21.1", languages: ["es"])
    #expect(FourDMacroDiscovery.applicationMacrosFile(
        inBundle: nurSpanisch, preferredLanguages: ["fr-FR"], fileManager: fm
    )?.path.contains("/es.lproj/") == true)
}

@Test("4D.app: höchste Version gewinnt, numerisch statt lexikalisch")
func macroApplicationVersionChoice() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let apps = scratch.appendingPathComponent("Applications")
    // „20.10" ist numerisch NEUER als „20.9".
    try makeFourDBundle(at: apps.appendingPathComponent("4D v20.9/4D.app"),
                        version: "20.9", languages: ["de"])
    try makeFourDBundle(at: apps.appendingPathComponent("4D v20.10/4D.app"),
                        version: "20.10", languages: ["de"])
    let bundles = FourDMacroDiscovery.fourDApplicationBundles(
        in: [apps], fileManager: FileManager.default)
    #expect(bundles.count == 2)
    #expect(FourDMacroDiscovery.highestVersionBundle(bundles)?.version == "20.10")
}

@Suite("4D-Makro-Rendering, Engine-Status und Rücktokenisierung")
struct FourDMacroRenderingTests {

    @Test("Platzhalter werden ersetzt, die Caret-Position stimmt in UTF-16")
    func rendersPlaceholdersAndCaret() {
        let parts: [FourDMacroTextPart] = [
            .literal("// "), .methodName, .literal(" "),
            .caret, .selection, .literal(" Ende"),
        ]
        let result = FourDMacroRendering.render(
            parts: parts, selection: "🙂SEL", methodName: "Übersicht",
            fullText: "egal")
        #expect(result.text == "// Übersicht 🙂SEL Ende")
        #expect(result.caretUTF16Offset == ("// Übersicht " as NSString).length)
    }

    @Test("Ohne Caret-Tag gibt es keine Cursorvorgabe")
    func noCaretMeansNoOffset() {
        let result = FourDMacroRendering.render(
            parts: [.literal("Text")], selection: "", methodName: "M",
            fullText: "")
        #expect(result.caretUTF16Offset == nil)
    }

    @Test("Gelernte Token-Suffixe stellen Befehls- UND Konstanten-Token wieder her")
    func learnedRoundtripRestoresTokens() {
        // Tokenisierter Originalcode, wie er in `.4dm`-Dateien liegt.
        let original = "var $t : Text\nALERT:C41(Char:C90(13))\n"
            + "If (Application type:C494=tool4d:K5:70)\nEnd if"
        let learned = FourDTokenTransform.learnedSuffixes(from: original)
        let detokenized = FourDTokenTransform.detokenize(original)
        #expect(!detokenized.contains(":C41"))
        #expect(FourDTokenTransform.retokenize(detokenized, learned: learned)
                == original)
    }

    @Test("Neue Befehle ohne gelerntes Suffix bekommen ihre Katalog-Nummer")
    func retokenizeUsesCatalogForNewCommands() {
        let result = FourDTokenTransform.retokenize("ALERT(\"Hi\")", learned: [:])
        #expect(result == "ALERT:C41(\"Hi\")")
    }

    @Test("Auch NOCH UNBEKANNTE 4D-Symbole behalten ihr gelerntes Token-Suffix")
    func learnedRoundtripCoversUnknownSymbols() {
        // Weder Befehl noch Konstante stehen im mitgelieferten Katalog. Im
        // tokenisierten Original erkennt der Tokenizer sie am „:C“/„:K“; ohne
        // Suffix hält er den einen für einen Methodenaufruf und die andere für
        // eine Prozessvariable. Genau diese beiden Fälle verloren ihr Suffix.
        let original = "FutureCommand:C9998(1)\nIf (x=Futureconst:K91:2)\nEnd if"
        let learned = FourDTokenTransform.learnedSuffixes(from: original)
        let detokenized = FourDTokenTransform.detokenize(original)
        #expect(!detokenized.contains(":C9998"))
        #expect(!detokenized.contains(":K91:2"))
        #expect(FourDTokenTransform.retokenize(detokenized, learned: learned)
                == original)
    }

    @Test("Bekannte Grenze: ein MEHRWORTIGES unbekanntes Symbol bleibt ohne Suffix")
    func learnedRoundtripCannotRebuildUnknownMultiWordSymbols() {
        // Ohne Suffix und ohne Katalog-Eintrag hat der Tokenizer kein Merkmal,
        // an dem er „Future const" als EIN Symbol erkennen könnte — er sieht
        // nur „Future". Das gelernte Suffix bleibt deshalb liegen. Bewusst als
        // Test festgehalten, damit die Grenze sichtbar bleibt statt zu
        // überraschen (als offener Punkt in ROADMAP.md notiert).
        let original = "If (x=Future const:K91:2)\nEnd if"
        let learned = FourDTokenTransform.learnedSuffixes(from: original)
        let detokenized = FourDTokenTransform.detokenize(original)
        #expect(FourDTokenTransform.retokenize(detokenized, learned: learned)
                != original)
    }

    @Test("Engine-Status: OK, UNVERAENDERT und FEHLER werden korrekt gelesen")
    func interpretsEngineStatus() {
        #expect(FourDMacroEngine.interpret(status: "OK\n", output: "neu")
                == .changed("neu"))
        #expect(FourDMacroEngine.interpret(status: "UNVERAENDERT", output: nil)
                == .unchanged)
        if case .failed(let text) = FourDMacroEngine.interpret(
            status: "FEHLER Makro lieferte leeren Code", output: nil) {
            #expect(text.contains("leeren Code"))
        } else {
            Issue.record("FEHLER-Zeile wurde nicht als Fehler gelesen")
        }
        if case .failed = FourDMacroEngine.interpret(status: nil, output: nil) {
        } else {
            Issue.record("Fehlende Statusdatei muss ein Fehler sein")
        }
        if case .failed = FourDMacroEngine.interpret(status: "OK", output: nil) {
        } else {
            Issue.record("OK ohne Ergebnisdatei muss ein Fehler sein")
        }
    }

    @Test("Engine-Argumente binden Projekt, MacroRun und user-param")
    func engineArgumentsAreComplete() {
        let args = FourDMacroEngine.arguments(
            projectFile: URL(fileURLWithPath: "/p/Project/E.4DProject"),
            inputFile: URL(fileURLWithPath: "/t/in.4dm"),
            outputFile: URL(fileURLWithPath: "/t/out.4dm"),
            variant: "komplettieren", methodName: "Foo")
        #expect(args.contains("--dataless"))
        #expect(args.contains("--skip-onstartup"))
        #expect(args.contains("MacroRun"))
        #expect(args.contains("/t/in.4dm|/t/out.4dm|komplettieren|Foo"))
    }
}

// MARK: - Reviewfunde 2026-08-20

@Test("IDs: zwei gleichnamige Quellen kollidieren nicht")
func macroIDsStayUniqueAcrossSameNamedSources() {
    // Real gibt es „Macros.xml“ mehrfach gleichzeitig: einmal mitgeliefert in
    // 4D.app, einmal in einer Projekt-Komponente. Ohne eigenen Quellschlüssel
    // hätten beide dieselben IDs, und ein Menüklick führte das Makro der
    // FALSCHEN Quelle aus.
    let xml = """
    <macros><macro name="A" version="2"><text>x</text></macro></macros>
    """
    let first = FourDMacroXML.parse(data: Data(xml.utf8), sourceLabel: "Macros.xml",
                                    sourceKey: "/Applications/4D v21/4D.app/…/Macros.xml")
    let second = FourDMacroXML.parse(data: Data(xml.utf8), sourceLabel: "Macros.xml",
                                     sourceKey: "/Projekt/Komponente.4dbase/…/Macros.xml")
    #expect(first.count == 1 && second.count == 1)
    #expect(first[0].id != second[0].id)
    // Die Beschriftung bleibt der kurze Dateiname (Tooltip im Menü).
    #expect(first[0].sourceLabel == "Macros.xml")
}

@Test("Kürzel: ⌘W bleibt „Tab schließen“ und wird nicht als Makro-Kürzel angeboten")
func macroReservedShortcutW() {
    // ⌘W wird im Routing VOR den Makros geprüft. Ein angezeigtes ⌘W wäre
    // deshalb ein Kürzel, das nie auslöst.
    #expect(FourDMacroXML.splitName("Fenster zu /w").shortcutKey == nil)
    #expect(FourDMacroXML.splitName("Fenster zu /w").displayName == "Fenster zu")
    #expect(FourDMacroXML.splitName("Fenster zu /W").shortcutKey == nil)
    // Andere Kürzel bleiben unberührt.
    #expect(FourDMacroXML.splitName("Makro /t").shortcutKey == "t")
}

@Test("Komplettieren: nur die vier bekannten Signaturen gelten")
func macroKomplettierenSignaturesAreExact() {
    let placeholder = "\"<method_name/>\""
    #expect(FourDMacroXML.komplettierenVariant(arguments: [placeholder]) == .standard)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"\"", "True"]) == .ohneNichtVerwendet)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"\"", "False", "False"]) == .ohneVarUmwandlung)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"\"", "True", "False"])
        == .ohneNichtVerwendetUndVar)

    // Kein Argument, fremdes erstes Argument, falsche Festwerte, zu viele
    // Argumente: alles KEINE bekannte Variante mehr.
    #expect(FourDMacroXML.komplettierenVariant(arguments: []) == nil)
    #expect(FourDMacroXML.komplettierenVariant(arguments: ["\"Fremd\""]) == nil)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "True", "\"\"", "True"]) == nil)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"x\"", "True"]) == nil)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"\"", "True", "False", "True"]) == nil)
}

@Test("Methodenaufruf: Text hinter der schließenden Klammer ist kein Aufruf mehr")
func macroMethodCallRejectsTrailingText() {
    #expect(FourDMacroXML.parseMethodCall("Foo(\"a\") ; Bar") == nil)
    // Reiner Leerraum dahinter bleibt in Ordnung.
    #expect(FourDMacroXML.parseMethodCall("Foo(\"a\")  \n")?.name == "Foo")
}

@Test("Ein leeres Makro ohne Argumente gilt nicht mehr als Standard-Komplettieren")
func macroEmptyKomplettierenCallIsUnsupported() {
    let xml = """
    <macros><macro name="X" version="2"><text><method>\
    MAO_MethodeKomplettierenNeu()\
    </method></text></macro></macros>
    """
    let macros = FourDMacroXML.parse(data: Data(xml.utf8), sourceLabel: "x.xml")
    #expect(macros.count == 1)
    #expect(unsupportedReason(FourDMacroXML.capability(of: macros[0]))?.isEmpty == false)
}
