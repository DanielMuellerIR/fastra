// FourDMacroTests.swift
//
// Tests des 4D-Makro-Modells: XML-Parser, Einstufung („was kann Fastra
// damit tun?") und das Absuchen der Fundorte. Alles läuft gegen eingebaute
// Beispieldaten und temporäre Ordner — es braucht weder ein installiertes 4D
// noch ein echtes Projekt.

import Testing
import Foundation
import AppKit
import CodeEditTextView
import Darwin
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

@Test("Parserbudgets verwerfen übergroße Quelle, Makrozahl und Text")
func macroParserBudgetsAreHardLimits() {
    let one = Data("<macros><macro name=\"A\"><text>12345</text></macro></macros>".utf8)
    let two = Data("<macros><macro name=\"A\"><text>1</text></macro><macro name=\"B\"><text>2</text></macro></macros>".utf8)
    let nestedMacros = Data(
        "<macros><macro name=\"A\"><macro name=\"B\"/></macro></macros>".utf8
    )
    let deeplyNested = Data((
        "<macros><macro name=\"A\"><text>"
        + String(repeating: "<x>", count: 300)
        + String(repeating: "</x>", count: 300)
        + "</text></macro></macros>"
    ).utf8)
    let manyParts = Data(
        "<macros><macro name=\"A\"><text><caret/><selection/><caret/></text></macro></macros>".utf8
    )

    #expect(FourDMacroXML.parse(
        data: one, sourceLabel: "bytes.xml",
        limits: .init(sourceBytes: one.count - 1, macroCount: 10,
                      textUTF16Units: 100)
    ).isEmpty)
    #expect(FourDMacroXML.parse(
        data: two, sourceLabel: "count.xml",
        limits: .init(sourceBytes: two.count, macroCount: 1,
                      textUTF16Units: 100)
    ).isEmpty)
    #expect(FourDMacroXML.parse(
        data: one, sourceLabel: "text.xml",
        limits: .init(sourceBytes: one.count, macroCount: 10,
                      textUTF16Units: 4)
    ).isEmpty)
    #expect(FourDMacroXML.parse(
        data: nestedMacros, sourceLabel: "nested-macros.xml",
        limits: .init(sourceBytes: nestedMacros.count, macroCount: 1,
                      textUTF16Units: 100)
    ).isEmpty)
    #expect(FourDMacroXML.parse(
        data: deeplyNested, sourceLabel: "nested-elements.xml",
        limits: .init(sourceBytes: deeplyNested.count, macroCount: 10,
                      textUTF16Units: 100)
    ).isEmpty)
    #expect(FourDMacroXML.parse(
        data: manyParts, sourceLabel: "parts.xml",
        limits: .init(sourceBytes: manyParts.count, macroCount: 10,
                      textUTF16Units: 100, partCount: 2)
    ).isEmpty)
}

@Test("Textbudget zählt auch den Ersatztext wiederholter <method_name/>-Tags")
func macroMethodNameTagsCountAgainstTextBudget() {
    // Jedes leere Tag wird zur 14 UTF-16-Einheiten langen Zeichenkette
    // `<method_name/>` normalisiert und gehalten — ohne Buchung ließe sich
    // die Textgrenze mit beliebig vielen Tags unterlaufen.
    let tagCount = 6
    let placeholderUnits = ("<method_name/>" as NSString).length
    let xml = "<macros><macro name=\"A\"><text><method>"
        + String(repeating: "<method_name/>", count: tagCount)
        + "</method></text></macro></macros>"
    let data = Data(xml.utf8)

    // Genau an der Grenze bleibt das Makro vollständig erhalten …
    let atLimit = FourDMacroXML.parse(
        data: data, sourceLabel: "methodname.xml",
        limits: .init(sourceBytes: data.count, macroCount: 10,
                      textUTF16Units: tagCount * placeholderUnits)
    )
    #expect(atLimit.count == 1)
    #expect(atLimit.first?.methodCall
            == String(repeating: "<method_name/>", count: tagCount))
    // … eine Einheit darunter greift die harte Grenze für die ganze Quelle.
    #expect(FourDMacroXML.parse(
        data: data, sourceLabel: "methodname.xml",
        limits: .init(sourceBytes: data.count, macroCount: 10,
                      textUTF16Units: tagCount * placeholderUnits - 1)
    ).isEmpty)
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

@Test("Projektweiter Makro-Cache trifft nur bei unveränderten Quellen")
func macroCatalogCacheUsesSourceFingerprints() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sourceURL = scratch.appendingPathComponent("Macros.xml")
    try writeFile(sourceURL,
                  "<macros><macro name=\"Erstes\"><text>1</text></macro></macros>")
    let source = FourDMacroSource(url: sourceURL, origin: .userLibrary)
    let key = "test:\(UUID().uuidString)"
    let cache = FourDMacroCatalogCache()

    let first = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: key, force: false, cache: cache
    )
    let second = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: key, force: false, cache: cache
    )
    #expect(!first.cacheHit)
    #expect(second.cacheHit)
    #expect(second.macros.map(\.displayName) == ["Erstes"])

    // Andere Größe garantiert einen neuen Fingerabdruck auch auf Dateisystemen
    // mit grober Zeitauflösung.
    try writeFile(sourceURL,
                  "<macros><macro name=\"Zweites Makro\"><text>22</text></macro></macros>")
    let changed = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: key, force: false, cache: cache
    )
    #expect(!changed.cacheHit)
    #expect(changed.macros.map(\.displayName) == ["Zweites Makro"])

    let forced = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: key, force: true, cache: cache
    )
    #expect(!forced.cacheHit)
}

@Test("Makro-Katalogcache teilt globale Quellen und verdrängt alte Projekte")
func macroCatalogCacheIsBoundedLRU() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sourceURL = scratch.appendingPathComponent("Macros.xml")
    try writeFile(sourceURL,
                  "<macros><macro name=\"Klein\"><text>x</text></macro></macros>")
    let source = FourDMacroSource(url: sourceURL, origin: .userLibrary)
    let keyPrefix = "lru-test:\(UUID().uuidString):"
    let cache = FourDMacroCatalogCache(maximumEntryCount: 2)

    #expect(FourDMacroCatalogLoader.cacheKey(projectRoot: nil)
            == "standalone:global")
    #expect(FourDMacroCatalogLoader.cacheKey(projectRoot: scratch)
            != FourDMacroCatalogLoader.cacheKey(projectRoot: nil))
    for index in 0...2 {
        let loaded = FourDMacroCatalogLoader.load(
            sources: [source], cacheKey: "\(keyPrefix)\(index)", force: false,
            cache: cache
        )
        #expect(!loaded.cacheHit)
    }

    // Nach einem Eintrag mehr als der festen Grenze ist der älteste weg,
    // der zuletzt verwendete aber weiterhin ein Treffer.
    let oldest = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: "\(keyPrefix)0", force: false,
        cache: cache
    )
    let newest = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: "\(keyPrefix)2", force: false,
        cache: cache
    )
    #expect(!oldest.cacheHit)
    #expect(newest.cacheHit)
}

@Test("Makro-Katalogcache berechnet auch strukturelle Platzhalter")
func macroCatalogCacheWeightsStructuralParts() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sourceURL = scratch.appendingPathComponent("Macros.xml")
    let placeholders = String(repeating: "<caret/>", count: 32)
    try writeFile(
        sourceURL,
        "<macros><macro name=\"X\"><text>\(placeholders)</text></macro></macros>"
    )
    let source = FourDMacroSource(url: sourceURL, origin: .userLibrary)
    let cache = FourDMacroCatalogCache(
        maximumEntryCount: 2, maximumWeight: 128
    )
    let key = "parts-weight:\(UUID().uuidString)"

    let first = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: key, force: false, cache: cache
    )
    let second = FourDMacroCatalogLoader.load(
        sources: [source], cacheKey: key, force: false, cache: cache
    )

    #expect(!first.cacheHit)
    #expect(!second.cacheHit,
            "Viele Platzhalter dürfen nicht als nahezu gewichtsloser Cacheeintrag gelten")

    let compactURL = scratch.appendingPathComponent("Compact.xml")
    try writeFile(
        compactURL,
        "<macros><macro name=\"Y\"><text><caret/>x</text></macro></macros>"
    )
    let compact = FourDMacroSource(url: compactURL, origin: .userLibrary)
    let compactCache = FourDMacroCatalogCache(
        maximumEntryCount: 2, maximumWeight: 4_096
    )
    let compactKey = "parts-compact:\(UUID().uuidString)"
    let compactFirst = FourDMacroCatalogLoader.load(
        sources: [compact], cacheKey: compactKey, force: false,
        cache: compactCache
    )
    let compactSecond = FourDMacroCatalogLoader.load(
        sources: [compact], cacheKey: compactKey, force: false,
        cache: compactCache
    )
    #expect(!compactFirst.cacheHit)
    #expect(compactSecond.cacheHit,
            "Wenige Bausteine müssen als regulärer Katalogeintrag im Cache bleiben")
}

@Test("Katalogbudgets werden in genau einem Makrodurchlauf gemessen")
func macroCatalogMeasurementsVisitEachMacroOnce() {
    let xml = """
    <macros>
      <macro name="A"><text>eins<caret/></text></macro>
      <macro name="B"><text><selection/>zwei</text></macro>
    </macros>
    """
    let macros = FourDMacroXML.parse(
        data: Data(xml.utf8), sourceLabel: "measurements.xml"
    )
    let measurements = FourDMacroCatalogLoader.retainedMeasurements(in: macros)

    #expect(macros.count == 2)
    #expect(measurements.visitedMacroCount == macros.count)
    #expect(measurements.partCount == macros.reduce(0) {
        $0 + $1.textParts.count
    })
    #expect(measurements.textUTF16Units > 0)
    #expect(measurements.cacheWeight > measurements.textUTF16Units)
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

@Test("Fundorte: Das Quellenbudget begrenzt schon die Discovery")
func macroSourcesHonorSourceBudget() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let home = scratch.appendingPathComponent("home")
    // Mehr als das Doppelte des Budgets, damit auch das zwischenzeitliche
    // Eindampfen der begrenzten Auswahl durchlaufen wird.
    for number in 1...9 {
        try writeFile(home.appendingPathComponent(
            "Library/Application Support/4D/Macros v2/m\(number).xml"))
    }

    let limited = FourDMacroDiscovery.macroSources(
        projectRoot: nil, homeDirectory: home, applicationDirectories: [],
        preferredLanguages: ["de"], maximumSourceCount: 4
    )
    // Es gewinnen die alphabetisch ersten Dateien — dieselben, die vor der
    // Budgetierung nach dem vollständigen Sortieren vorn gestanden hätten.
    #expect(limited.map(\.url.lastPathComponent)
            == ["m1.xml", "m2.xml", "m3.xml", "m4.xml"])

    // Komponentenquellen verbrauchen das Budget VOR dem Benutzerordner:
    // Die Prioritätsreihenfolge der Fundorte bleibt erhalten.
    let root = scratch.appendingPathComponent("MeinProjekt")
    try writeFile(root.appendingPathComponent("Project/App.4DProject"))
    for number in 1...3 {
        try writeFile(root.appendingPathComponent(
            "Components/Komponente.4dbase/Macros v2/k\(number).xml"))
    }
    let prioritized = FourDMacroDiscovery.macroSources(
        projectRoot: root, homeDirectory: home, applicationDirectories: [],
        preferredLanguages: ["de"], maximumSourceCount: 2
    )
    #expect(prioritized.map(\.url.lastPathComponent) == ["k1.xml", "k2.xml"])
    #expect(prioritized.allSatisfy {
        $0.origin == .component(name: "Komponente")
    })
}

/// Zeichnet die nicht rekursiven Verzeichniszugriffe der Discovery auf. Der
/// Test prüft damit nicht nur die Ergebniszahl, sondern ob nach verbrauchtem
/// Quellenbudget tatsächlich keine nachrangigen Fundorte mehr gelesen werden.
private final class RecordingMacroFileManager: FileManager {
    private(set) var readDirectories: [URL] = []

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        readDirectories.append(url.standardizedFileURL)
        return try super.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: mask)
    }

}

@Test("Ein verbrauchtes Makro-Quellenbudget überspringt nachrangige Fundorte")
func macroSourcesStopDiscoveryAfterSourceBudget() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let project = scratch.appendingPathComponent("Projekt")
    try writeFile(project.appendingPathComponent(
        "Components/Komponente.4dbase/Macros v2/a.xml"))
    let applications = scratch.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(
        at: applications, withIntermediateDirectories: true)
    let fileManager = RecordingMacroFileManager()

    let limited = FourDMacroDiscovery.macroSources(
        projectRoot: project, homeDirectory: scratch,
        applicationDirectories: [applications], fileManager: fileManager,
        preferredLanguages: ["de"], maximumSourceCount: 1
    )

    #expect(limited.map(\.url.lastPathComponent) == ["a.xml"])
    #expect(!fileManager.readDirectories.contains(applications.standardizedFileURL),
            "Nach dem Komponentenfund darf kein nutzloser Programme-Scan folgen")

    let zeroBudgetFileManager = RecordingMacroFileManager()
    let empty = FourDMacroDiscovery.macroSources(
        projectRoot: project, homeDirectory: scratch,
        applicationDirectories: [applications], fileManager: zeroBudgetFileManager,
        preferredLanguages: ["de"], maximumSourceCount: 0
    )
    #expect(empty.isEmpty)
    #expect(zeroBudgetFileManager.readDirectories.isEmpty,
            "Ein Nullbudget darf keinen Fundort öffnen")
}

@Test("Komponenten-Discovery hält Eintragsbudget und überspringt zweite Makrolage")
func macroSourcesHonorDirectoryEntryBudgetInsideComponents() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let project = scratch.appendingPathComponent("Projekt")
    let component = project.appendingPathComponent(
        "Components/Komponente.4dbase", isDirectory: true)
    try writeFile(component.appendingPathComponent("Macros v2/a.xml"))
    try writeFile(component.appendingPathComponent("Contents/Macros v2/b.xml"))

    let sourceLimitedManager = RecordingMacroFileManager()
    let one = FourDMacroDiscovery.macroSources(
        projectRoot: project, homeDirectory: scratch,
        applicationDirectories: [], fileManager: sourceLimitedManager,
        preferredLanguages: ["de"], maximumSourceCount: 1,
        maximumDirectoryEntryCount: 10)
    #expect(one.map(\.url.lastPathComponent) == ["a.xml"])

    let entryLimitedManager = RecordingMacroFileManager()
    let none = FourDMacroDiscovery.macroSources(
        projectRoot: project, homeDirectory: scratch,
        applicationDirectories: [], fileManager: entryLimitedManager,
        preferredLanguages: ["de"], maximumSourceCount: 10,
        maximumDirectoryEntryCount: 1)
    #expect(none.isEmpty,
            "Der Komponenten-Eintrag verbraucht das letzte Arbeitsbudget vor dem XML-Scan")
}

@Test("Quellenlimit kappt nicht die Suche nach der ersten brauchbaren Komponente")
func macroSourcesSearchPastEmptyComponentsWithinEntryBudget() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let project = scratch.appendingPathComponent("Projekt")
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent("Components/A.4dbase"),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent("Components/B.4dbase"),
        withIntermediateDirectories: true)
    try writeFile(project.appendingPathComponent(
        "Components/C.4dbase/Macros v2/c.xml"))

    let sources = FourDMacroDiscovery.macroSources(
        projectRoot: project, homeDirectory: scratch,
        applicationDirectories: [], preferredLanguages: ["de"],
        maximumSourceCount: 1, maximumDirectoryEntryCount: 10)

    #expect(sources.map(\.url.lastPathComponent) == ["c.xml"])
}

@Test("Eintragsbudget gilt auch für die Suche in Programme-Ordnern")
func macroSourcesHonorDirectoryEntryBudgetInApplications() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let applications = scratch.appendingPathComponent("Applications")
    try makeFourDBundle(
        at: applications.appendingPathComponent("4D v21/4D.app"),
        version: "21.1", languages: ["de"])

    let exhausted = FourDMacroDiscovery.macroSources(
        projectRoot: nil, homeDirectory: scratch,
        applicationDirectories: [applications], preferredLanguages: ["de"],
        maximumSourceCount: 1, maximumDirectoryEntryCount: 1)
    #expect(exhausted.isEmpty)

    let sufficient = FourDMacroDiscovery.macroSources(
        projectRoot: nil, homeDirectory: scratch,
        applicationDirectories: [applications], preferredLanguages: ["de"],
        maximumSourceCount: 1, maximumDirectoryEntryCount: 3)
    #expect(sufficient.map(\.origin) == [
        .fourDApplication(version: "21.1")
    ])
}

@Test("dependencies.json besitzt eine harte Lesegrenze")
func macroDependenciesJSONReadIsBounded() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let project = scratch.appendingPathComponent("Projekt")
    let json = """
    {"dependencies":{"Extern":{"path":"../Extern/Komponente.4dbase"}}}
    """
    // Das Leerzeichen hinter dem vollständigen JSON macht den Grenzfall
    // messbar: Wer nur `maximumBytes` liest, sähe ein gültiges Präfix und
    // könnte die tatsächlich zu große Datei fälschlich akzeptieren.
    let storedJSON = json + " "
    let data = Data(storedJSON.utf8)
    try writeFile(
        project.appendingPathComponent("Project/Sources/dependencies.json"),
        storedJSON)

    let accepted = FourDMacroDiscovery.declaredDependencies(
        in: project, fileManager: .default, maximumBytes: data.count)
    let rejected = FourDMacroDiscovery.declaredDependencies(
        in: project, fileManager: .default, maximumBytes: data.count - 1)

    #expect(accepted.map(\.name) == ["Extern"])
    #expect(rejected.isEmpty,
            "Schon ein Byte über der Grenze darf nicht vollständig geparst werden")
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

@Test("4D.app: vollständige regionale Sprache gewinnt vor ihrer Basis")
func macroApplicationRegionalLanguageChoice() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bundle = scratch.appendingPathComponent("4D.app")
    try makeFourDBundle(at: bundle, version: "21.1", languages: ["pt", "pt-BR"])

    let chosen = FourDMacroDiscovery.applicationMacrosFile(
        inBundle: bundle, preferredLanguages: ["pt_BR"],
        fileManager: .default
    )
    #expect(chosen?.path.contains("/pt-BR.lproj/") == true)
}

@Test("4D.app: Schriftvariante gewinnt zwischen Region und Basissprache")
func macroApplicationScriptLanguageChoice() throws {
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bundle = scratch.appendingPathComponent("4D.app")
    try makeFourDBundle(at: bundle, version: "21.1",
                        languages: ["zh", "zh-Hant"])

    let chosen = FourDMacroDiscovery.applicationMacrosFile(
        inBundle: bundle, preferredLanguages: ["zh-Hant-TW"],
        fileManager: .default
    )
    #expect(chosen?.path.contains("/zh-Hant.lproj/") == true)
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
        let original = "var $t : Text\nvar $d : Date\nvar $time : Time\n"
            + "#DECLARE -> $result : Date\nALERT:C41(Char:C90(13))\n"
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

    @Test("Mehrwortige unbekannte Symbole bekommen exakt ihr gelerntes Suffix")
    func learnedRoundtripRebuildsUnknownMultiWordSymbols() {
        // Der Tokenizer sieht ohne Suffix nur das erste Wort. Die gelernte
        // Symbolmenge muss deshalb den längsten vollständigen Namen liefern;
        // ein kürzeres `Future`-Token darf nicht mitten im Namen landen.
        let original = "If (x=Future:K91:1)\n"
            + "If (y=Future const:K91:2)\nEnd if"
        let learned = FourDTokenTransform.learnedSuffixes(from: original)
        let detokenized = FourDTokenTransform.detokenize(original)
        #expect(FourDTokenTransform.retokenize(detokenized, learned: learned)
                == original)
    }

    @Test("Ein gelerntes Teilwort verdoppelt das Suffix des längeren Namens nicht")
    func learnedRoundtripKeepsOverlappingNamesDisjoint() {
        // `Future Tail` UND das eigenständige `Tail` sind beide gelernt. Ohne
        // Bereichsbelegung bekam der enttokenisierte mehrwortige Name zuerst
        // das Suffix von `Tail` und am selben Offset zusätzlich das von
        // `Future Tail` — der geschriebene 4D-Code war damit kaputt.
        let original = "If (x=Future Tail:K91:2)\n"
            + "If (y=Tail:K92:3)\nEnd if"
        let learned = FourDTokenTransform.learnedSuffixes(from: original)
        let detokenized = FourDTokenTransform.detokenize(original)
        let restored = FourDTokenTransform.retokenize(detokenized,
                                                      learned: learned)
        #expect(restored == original)
        #expect(!restored.contains(":K92:3:K91:2"))
        #expect(!restored.contains(":K91:2:K92:3"))
    }

    @Test("Abgebrochene Rücktokenisierung liefert kein Teilergebnis")
    func retokenizeCancellationStopsWithoutPartialResult() {
        let text = "//" + String(repeating: "a", count: 20_000)
        // Nicht abgebrochen: identisch zur öffentlichen Variante.
        #expect(FourDTokenTransform.retokenize(
            text, learned: [:], isCancelled: { false })
            == FourDTokenTransform.retokenize(text, learned: [:]))
        // Der reine Kommentar erzeugt kein rücktokenisierbares Token. Nur ein
        // Abbruch IM Tokenizer kann den Lauf deshalb stoppen; die spätere
        // Planungsschleife wird bei diesem Fixture nie betreten.
        var checks = 0
        let cancelled = FourDTokenTransform.retokenize(
            text, learned: [:],
            isCancelled: { checks += 1; return checks > 4 })
        #expect(cancelled == nil)
        #expect(checks > 4)
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

@Test("Kürzel: App-Menü gewinnt; doppelte Makro-Kürzel werden nur einmal vergeben")
func macroShortcutsRespectAppMenuAndDuplicates() {
    let xml = """
    <macros>
      <macro name="Speichern /s"><text>S</text></macro>
      <macro name="Erstes /x"><text>1</text></macro>
      <macro name="Zweites /x"><text>2</text></macro>
      <macro name="Frei /t"><text>T</text></macro>
    </macros>
    """
    let parsed = FourDMacroXML.parse(data: Data(xml.utf8), sourceLabel: "x")
    let resolved = FourDMacroXML.resolvingShortcuts(in: parsed,
                                                    reserved: ["s", "w", "q"])
    #expect(resolved.map(\.shortcutKey) == [nil, "x", nil, "t"])
    #expect(resolved.map(\.displayName)
            == ["Speichern", "Erstes", "Zweites", "Frei"])
}

@Test("Komplettieren: bekannte Varianten samt ausgeschriebener Standardform gelten")
func macroKomplettierenSignaturesAreExact() {
    let placeholder = "\"<method_name/>\""
    #expect(FourDMacroXML.komplettierenVariant(arguments: [placeholder]) == .standard)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False"]) == .standard)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"\""]) == .standard)
    #expect(FourDMacroXML.komplettierenVariant(
        arguments: [placeholder, "False", "\"\"", "False"]) == .standard)
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

@Test("Befehls-Token bleiben aus Date- und Time-Typpositionen heraus")
func commandTokenizationSkipsDeclarationTypes() {
    let source = "var $d : Date\nvar $t : Time\n"
        + "#DECLARE($value : Date)\n#DECLARE -> $result : Time\n"
        + "Date(\"2026-08-20\")"
    let tokenized = FourDTokenTransform.tokenizeCommands(source)
    #expect(tokenized.contains("var $d : Date\n"))
    #expect(tokenized.contains("var $t : Time\n"))
    #expect(tokenized.contains("$value : Date)"))
    #expect(tokenized.contains("$result : Time\n"))
    #expect(tokenized.contains("Date:C102("))
}

@Test("Viele 4D-Deklarationen behalten ihre Typen ohne wiederholte Präfixkopien")
func commandTokenizationHandlesLargeDeclarationFiles() {
    func source(declarationPairs: Int) -> String {
        let declarations = (0..<declarationPairs).map { index in
            "var $date\(index) : Date\nvar $time\(index) : Time"
        }.joined(separator: "\n")
        return declarations + "\nDate(\"2026-08-26\")"
    }
    func threadCPUSeconds(for source: String) -> Double {
        var before = timespec()
        var after = timespec()
        #expect(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &before) == 0)
        _ = FourDTokenTransform.tokenizeCommands(source)
        #expect(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &after) == 0)
        let seconds = Double(after.tv_sec - before.tv_sec)
        let nanoseconds = Double(after.tv_nsec - before.tv_nsec) / 1_000_000_000
        return seconds + nanoseconds
    }

    let smallSource = source(declarationPairs: 1_024)
    let largeSource = source(declarationPairs: 4_096)
    _ = FourDTokenTransform.tokenizeCommands(source(declarationPairs: 32))
    let smallCPU = threadCPUSeconds(for: smallSource)
    let largeCPU = threadCPUSeconds(for: largeSource)
    let tokenized = FourDTokenTransform.tokenizeCommands(largeSource)
    let retokenized = FourDTokenTransform.retokenize(
        largeSource, learned: ["date": ":C102", "time": ":C179"]
    )

    #expect(largeCPU <= smallCPU * 8 + 0.02,
            "Vierfache Eingabe darf nicht wieder annähernd quadratische CPU-Zeit brauchen (klein: \(smallCPU)s, groß: \(largeCPU)s)")
    #expect(!tokenized.contains(": Date:C102"))
    #expect(!tokenized.contains(": Time:C179"))
    #expect(tokenized.hasSuffix("Date:C102(\"2026-08-26\")"))
    #expect(retokenized == tokenized)
}

@Test("Unbekannte Platzhalter werden vor leerem Inhalt erklärt — auch im Methodenaufruf")
func unknownMacroPlaceholdersNeverDisappearSilently() throws {
    let textXML = """
    <macros><macro name="X"><text><neu/></text></macro></macros>
    """
    let methodXML = """
    <macros><macro name="Y"><text><method>\
    MAO_MethodeKomplettierenNeu("<method_name/>";False;"";True<neu/>)\
    </method></text></macro></macros>
    """
    let textMacro = try #require(FourDMacroXML.parse(
        data: Data(textXML.utf8), sourceLabel: "x"
    ).first)
    let methodMacro = try #require(FourDMacroXML.parse(
        data: Data(methodXML.utf8), sourceLabel: "y"
    ).first)
    #expect(unsupportedReason(FourDMacroXML.capability(of: textMacro))?.contains("<neu/>") == true)
    #expect(unsupportedReason(FourDMacroXML.capability(of: methodMacro))?.contains("<neu/>") == true)
}

@Test("4D-Makroformate 0…8 und 0…6 werden abgebildet; fremde Werte werden abgelehnt")
func macroDateAndTimeFormatsAreExplicit() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let locale = Locale(identifier: "en_US_POSIX")
    for format in 0...8 {
        #expect(!FourDMacroRendering.renderDate(date, format: format,
                                               locale: locale).isEmpty)
    }
    for format in 0...6 {
        #expect(!FourDMacroRendering.renderTime(date, format: format,
                                               locale: locale).isEmpty)
    }
    #expect(FourDMacroRendering.renderDate(date, format: 4, locale: locale)
        .range(of: #"^\d{2}/\d{2}/\d{2}$"#, options: .regularExpression) != nil)
    #expect(FourDMacroRendering.renderDate(date, format: 7, locale: locale)
        .range(of: #"^\d{2}/\d{2}/\d{4}$"#, options: .regularExpression) != nil)
    #expect(FourDMacroRendering.renderDate(date, format: 8, locale: locale)
        .range(of: #"^\d{4}-\d{2}-\d{2}T00:00:00$"#,
               options: .regularExpression) != nil)

    let invalidDateXML = """
    <macros><macro name="Ungültiges Datum"><text><date format="9"/></text></macro></macros>
    """
    let invalidTimeXML = """
    <macros><macro name="Ungültige Zeit"><text><time format="x"/></text></macro></macros>
    """
    let invalidDate = try #require(FourDMacroXML.parse(
        data: Data(invalidDateXML.utf8), sourceLabel: "x"
    ).first)
    let invalidTime = try #require(FourDMacroXML.parse(
        data: Data(invalidTimeXML.utf8), sourceLabel: "x"
    ).first)
    #expect(unsupportedReason(FourDMacroXML.capability(of: invalidDate))?.contains("9") == true)
    #expect(unsupportedReason(FourDMacroXML.capability(of: invalidTime))?.contains("-1") == true)
}

@Test("Makro-Herkunft unterscheidet Komponente, Benutzerordner und 4D.app")
func macroOriginLabelsAreDistinct() {
    let file = "Macros.xml"
    let labels = [
        FourDMacroSource.Origin.component(name: "Werkzeuge").displayLabel(fileName: file),
        FourDMacroSource.Origin.userLibrary.displayLabel(fileName: file),
        FourDMacroSource.Origin.fourDApplication(version: "21.0")
            .displayLabel(fileName: file),
    ]
    #expect(Set(labels).count == 3)
    #expect(labels.allSatisfy { $0.contains(file) })
}

@MainActor
@Test("Makro-Kürzel übernehmen weder ⌘- noch ⇧⌘-Menübefehle")
func liveAppMenuDefinesReservedMacroShortcuts() {
    let root = NSMenu()
    let file = NSMenu(title: "Datei")
    let fileItem = NSMenuItem(title: "Datei", action: nil, keyEquivalent: "")
    fileItem.submenu = file
    root.addItem(fileItem)
    file.addItem(withTitle: "Sichern", action: nil, keyEquivalent: "s")
    // Reale App-Befehle: ⇧⌘L „Soft Wrap", ⇧⌘M „Markdown-Vorschau rechts".
    // Der Router nimmt ein Makro-Kürzel auch mit Umschalttaste an, deshalb
    // müssen diese Tasten ebenfalls reserviert sein.
    let softWrap = NSMenuItem(title: "Soft Wrap", action: nil, keyEquivalent: "l")
    softWrap.keyEquivalentModifierMask = [.command, .shift]
    file.addItem(softWrap)
    // AppKit-Konvention: Großbuchstabe im keyEquivalent bedeutet ⇧, auch ohne
    // Shift in der Maske.
    let preview = NSMenuItem(title: "Markdown-Vorschau rechts anzeigen",
                             action: nil, keyEquivalent: "M")
    preview.keyEquivalentModifierMask = [.command]
    file.addItem(preview)
    // Option/Control brechen im Router ab und reservieren deshalb nichts.
    let optioned = NSMenuItem(title: "Sonderweg", action: nil, keyEquivalent: "q")
    optioned.keyEquivalentModifierMask = [.command, .option]
    file.addItem(optioned)

    let keys = AppMenuShortcutKeys.reservedMacroKeys(in: root)
    #expect(keys.contains("s"))
    #expect(keys.contains("l"))
    #expect(keys.contains("m"))
    #expect(!keys.contains("q"))
}

@MainActor
@Test("Makro-Lease erkennt Vorschau-Tab-Reuse, Save As und Projektwechsel")
func macroExecutionLeaseBindsWholeDocumentContext() throws {
    let suite = "fastra-test-macro-lease-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let firstURL = scratch.appendingPathComponent("First.4dm")
    let secondURL = scratch.appendingPathComponent("Second.4dm")
    try Data("x".utf8).write(to: firstURL)
    try Data("x".utf8).write(to: secondURL)
    let projectA = scratch.appendingPathComponent("Project-A")
    let projectB = scratch.appendingPathComponent("Project-B")
    try FileManager.default.createDirectory(at: projectA,
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectB,
                                            withIntermediateDirectories: true)

    let tabID = UUID()
    let documentID = UUID()
    workspace.projectURL = projectA
    workspace.tabs = [EditorTab(
        id: tabID, title: "First.4dm", path: scratch.path,
        url: firstURL, content: "x", documentID: documentID
    )]
    workspace.activeTabID = tabID
    let lease = try #require(FourDMacroExecutionLease(
        tab: workspace.tabs[0], projectRoot: workspace.projectURL,
        projectGeneration: workspace.projectGeneration
    ))
    #expect(lease.isCurrent(in: workspace))

    // Preview-Reuse: derselbe Platz und dieselbe Revision, aber ein anderes
    // Dokument. Tab-ID plus Revision allein hätten den alten Stand akzeptiert.
    workspace.tabs[0] = EditorTab(
        id: tabID, title: "Second.4dm", path: scratch.path,
        url: secondURL, content: "x", documentID: UUID()
    )
    #expect(!lease.isCurrent(in: workspace))

    // Save As behält die Dokument-ID; erst die gebundene URL erkennt es.
    workspace.tabs[0] = EditorTab(
        id: tabID, title: "Second.4dm", path: scratch.path,
        url: secondURL, content: "x", documentID: documentID
    )
    #expect(!lease.isCurrent(in: workspace))

    workspace.tabs[0] = EditorTab(
        id: tabID, title: "First.4dm", path: scratch.path,
        url: firstURL, content: "x", documentID: documentID
    )
    workspace.projectURL = projectB
    #expect(!lease.isCurrent(in: workspace))

    // Eine verzögerte Meldung bleibt an das Fenster ihres Starts gebunden.
    workspace.projectURL = projectA
    let window = NSWindow()
    WorkspaceWindowRegistry.register(workspace, for: window)
    let windowLease = try #require(FourDMacroExecutionLease(
        tab: workspace.tabs[0], projectRoot: workspace.projectURL,
        projectGeneration: workspace.projectGeneration,
        originWindow: window
    ))
    #expect(windowLease.isCurrent(in: workspace))
    #expect(windowLease.originWindow(in: workspace) === window)
    WorkspaceWindowRegistry.unregister(window)
    #expect(!windowLease.isCurrent(in: workspace))
    #expect(windowLease.originWindow(in: workspace) == nil)
}

@MainActor
@Test("Makro-Vorschau wendet im gebundenen Editor trotz blockiertem globalem Sheet-Ziel an")
func macroPreviewApplyUsesBoundEditorInsteadOfGlobalTarget() throws {
    let suite = "fastra-test-macro-preview-apply-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    let competingSuite = "\(suite)-competing"
    let competingDefaults = testSuiteDefaults(named: competingSuite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        competingDefaults.removePersistentDomain(forName: competingSuite)
    }
    let workspace = Workspace(defaults: defaults)
    let competingWorkspace = Workspace(defaults: competingDefaults)
    let scratch = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let url = scratch.appendingPathComponent("Probe.4dm")
    try Data("vorher".utf8).write(to: url)
    let tab = EditorTab(title: "Probe.4dm", path: scratch.path,
                        url: url, content: "vorher")
    workspace.tabs = [tab]
    workspace.activeTabID = tab.id

    let textView = TextView(string: "vorher")
    let documentController = NSViewController()
    documentController.view = textView
    let documentWindow = NSWindow(contentViewController: documentController)
    documentWindow.identifier = NSUserInterfaceItemIdentifier(
        "Fastra.DocumentWindow"
    )
    WorkspaceWindowRegistry.register(workspace, for: documentWindow)
    documentWindow.orderFront(nil)
    let competingTextView = TextView(string: "konkurrierend")
    let competingController = NSViewController()
    competingController.view = competingTextView
    let competingWindow = NSWindow(contentViewController: competingController)
    competingWindow.identifier = NSUserInterfaceItemIdentifier(
        "Fastra.DocumentWindow"
    )
    WorkspaceWindowRegistry.register(competingWorkspace, for: competingWindow)
    // Ohne Key-Window nimmt die globale Zielwahl das vorderste Dokument.
    // Der konkurrierende Workspace steht absichtlich VOR dem Lease-Fenster.
    competingWindow.orderFront(nil)
    defer {
        WorkspaceWindowRegistry.unregister(competingWindow)
        competingWindow.close()
        WorkspaceWindowRegistry.unregister(documentWindow)
        documentWindow.close()
    }

    let lease = try #require(FourDMacroExecutionLease(
        tab: tab, projectRoot: workspace.projectURL,
        projectGeneration: workspace.projectGeneration,
        originWindow: documentWindow
    ))
    let request = FileDiffRequest(
        left: .text("vorher", name: "Vorher"),
        right: .text("nachher", name: "Nachher"),
        options: FileDiffOptions()
    )
    workspace.fourDMacroPreview = FourDMacroPreviewState(
        macroName: "Test", lease: lease, resultText: "nachher",
        request: request,
        document: Workspace.computeFileDiffDocument(request: request)
    )

    // Während des echten Button-Aufrufs ist das SwiftUI-Sheet ein unbekanntes
    // Key-Window. Die pure Fensterlogik belegt deterministisch, dass ein
    // globaler Dokument-Fallback dann absichtlich gesperrt ist. Dieser Test
    // darf trotzdem headless laufen und prüft anschließend den Lease-Pfad.
    let keySheetScenario = [
        WindowTargeting.Candidate(isDocumentWindow: false, isKey: true),
        WindowTargeting.Candidate(isDocumentWindow: true, isKey: false),
    ]
    #expect(WindowTargeting.targetIndex(in: keySheetScenario) == nil)
    let globalTarget = try #require(CommandTargeting.target())
    #expect(globalTarget.workspace === competingWorkspace)
    #expect(workspace.applyFourDMacroPreview())
    #expect(textView.string == "nachher")
    #expect(competingTextView.string == "konkurrierend")
    #expect(workspace.fourDMacroPreview == nil)
}

@MainActor
@Test("Eingereihter Makrolauf prüft seine Lease vor jeder Nebenwirkung")
func macroEngineQueuedRunCanCancelBeforeStart() async {
    let missing = URL(fileURLWithPath: "/nicht-vorhanden/fastra-tool4d")
    let result = await withCheckedContinuation { continuation in
        FourDMacroEngine.run(
            tool4d: missing,
            engineProjectRoot: missing.deletingLastPathComponent(),
            engineProjectFile: missing,
            code: "C_TEXT($0)", variant: "komplettieren", methodName: "Test",
            shouldStart: { false }
        ) { continuation.resume(returning: $0) }
    }
    #expect(result == .cancelledBeforeStart)
}

@Test("Fensterschließen bricht die gesamte Makro-Nachbearbeitung ab")
@MainActor
func macroPostprocessingStopsWhenWindowCloses() throws {
    let suite = "fastra-test-macro-window-close-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let probe = try startBlockingMacroDiff(in: workspace, keepSecondTab: false)
    #expect(probe.diffStarted.wait(timeout: .now() + 2) == .success)

    #expect(workspace.prepareToCloseWindow())

    #expect(probe.diffCancelled.wait(timeout: .now() + 2) == .success)
    #expect(workspace.fourDMacroPostprocessTask == nil)
    #expect(!workspace.fourDMacroEngineBusy)
    #expect(workspace.fourDMacroPreview == nil)
}

@Test("Tab-Schließen gibt die Makro-Sperre auch während des Diffs frei")
@MainActor
func macroPostprocessingStopsWhenTabCloses() throws {
    let suite = "fastra-test-macro-tab-close-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let probe = try startBlockingMacroDiff(in: workspace, keepSecondTab: true)
    #expect(probe.diffStarted.wait(timeout: .now() + 2) == .success)

    workspace.closeTab(id: probe.activeTabID)

    #expect(probe.diffCancelled.wait(timeout: .now() + 2) == .success)
    let retainedTabID = try #require(probe.retainedTabID)
    #expect(workspace.tabs.map(\.id) == [retainedTabID])
    #expect(workspace.fourDMacroPostprocessTask == nil)
    #expect(!workspace.fourDMacroEngineBusy)
    #expect(workspace.fourDMacroPreview == nil)
}

@MainActor
private func startBlockingMacroDiff(
    in workspace: Workspace, keepSecondTab: Bool
) throws -> (
    activeTabID: UUID, retainedTabID: UUID?,
    diffStarted: DispatchSemaphore, diffCancelled: DispatchSemaphore
) {
    let activeURL = URL(fileURLWithPath: "/tmp/fastra-macro-diff-active.4dm")
    let activeTab = EditorTab(
        title: activeURL.lastPathComponent,
        path: activeURL.deletingLastPathComponent().path,
        url: activeURL, content: "vorher"
    )
    let retainedTab = keepSecondTab ? Workspace.makeScratchTab() : nil
    workspace.tabs = [activeTab] + [retainedTab].compactMap { $0 }
    workspace.activeTabID = activeTab.id
    let lease = try #require(FourDMacroExecutionLease(
        tab: activeTab, projectRoot: workspace.projectURL,
        projectGeneration: workspace.projectGeneration
    ))
    let diffStarted = DispatchSemaphore(value: 0)
    let diffCancelled = DispatchSemaphore(value: 0)
    workspace.startFourDMacroPostprocessing(
        newCode: "nachher", learned: [:], originalText: "vorher",
        macroName: "Probe", lease: lease,
        buildDiff: { request in
            diffStarted.signal()
            while !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.001)
            }
            diffCancelled.signal()
            return Workspace.computeFileDiffDocument(request: request)
        }
    )
    return (activeTab.id, retainedTab?.id, diffStarted, diffCancelled)
}

@Test("Eine verspätete Engine-Completion löscht die Sperre eines neueren Laufs nicht")
@MainActor
func staleEngineCompletionKeepsNewerRunLock() {
    let suite = "fastra-test-macro-stale-engine-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)

    // Erster Lauf: Preflight/tool4d laufen, noch KEIN Postprocess-Task.
    let firstRun = workspace.beginFourDMacroEngineRun()
    #expect(workspace.fourDMacroEngineBusy)

    // Home räumt den Fensterzustand ab und gibt die Sperre frei — der erste
    // Lauf rechnet im Hintergrund aber noch weiter.
    workspace.enterWelcomeState()
    #expect(!workspace.fourDMacroEngineBusy)

    // Der Nutzer öffnet eine neue 4D-Datei und startet einen zweiten Lauf.
    let secondRun = workspace.beginFourDMacroEngineRun()
    #expect(workspace.fourDMacroEngineBusy)

    // Die verspätete Completion des ERSTEN Laufs darf die Sperre des
    // zweiten nicht löschen — sonst könnte ein dritter Lauf parallel starten
    // (Review 2026-08-29).
    workspace.releaseFourDMacroEngineLock(runID: firstRun)
    #expect(workspace.fourDMacroEngineBusy)

    // Nur die eigene Completion des zweiten Laufs gibt die Sperre frei.
    workspace.releaseFourDMacroEngineLock(runID: secondRun)
    #expect(!workspace.fourDMacroEngineBusy)
}

@Test("„Alle ersetzen“ im Geöffnet-Scope bricht die Makro-Nachbearbeitung ab")
@MainActor
func openReplaceAllCancelsMacroPostprocessing() throws {
    let suite = "fastra-test-macro-open-replace-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let workspace = Workspace(defaults: defaults)
    let probe = try startBlockingMacroDiff(in: workspace, keepSecondTab: false)
    #expect(probe.diffStarted.wait(timeout: .now() + 2) == .success)

    // Sichtbare Geöffnet-Trefferbasis wie nach einem fertigen Suchlauf —
    // „vorher" ist genau der Inhalt des Makro-Tabs aus dem Diff-Helfer.
    workspace.scope = .open
    workspace.findPattern = "vorher"
    workspace.replacePattern = "nachher"
    workspace.useRegex = false
    let inputs = workspace.tabs.map {
        OpenTabsSearch.TabInput(id: $0.id, title: $0.title, content: $0.content)
    }
    let found = OpenTabsSearch.find(tabs: inputs,
                                    options: workspace.currentSearchOptions)
    workspace.openResults = found.perTab
    workspace.openTotalMatches = found.totalMatches
    workspace.openResultsWereCapped = found.wasCapped
    workspace.visibleBufferResultsOptions = workspace.currentSearchOptions

    // Die programmgesteuerte Inhaltsänderung läuft am Editor-Binding vorbei;
    // sie muss die Nachbearbeitung des Makro-Tabs trotzdem sofort abbrechen
    // (Review 2026-08-29).
    #expect(workspace.applyAllInOpenTabs() == 1)

    #expect(probe.diffCancelled.wait(timeout: .now() + 2) == .success)
    #expect(workspace.fourDMacroPostprocessTask == nil)
    #expect(!workspace.fourDMacroEngineBusy)
    #expect(workspace.fourDMacroPreview == nil)
}

@Test("Workspace-Abbau lässt keinen Makro-Task weiterrechnen")
@MainActor
func macroPostprocessingStopsOnWorkspaceDeinit() {
    let suite = "fastra-test-macro-deinit-\(UUID().uuidString)"
    let defaults = testSuiteDefaults(named: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (reference, probe) = workspaceWithMacroCancellationProbe(defaults: defaults)

    // Der appweite Dokumentkontext beobachtet absichtlich den zuletzt aktiven
    // Workspace. Erst ein Fensterwechsel löst diese Beobachtung; danach ist
    // der im Helfer erzeugte Workspace nicht mehr stark besessen. Der Helfer
    // verhindert zugleich, dass Swift eine lokale Referenz bis zum Testende
    // verlängert und damit die ARC-Prüfung verfälscht.
    let otherWorkspace = Workspace(defaults: defaults)
    ActiveDocumentContext.shared.activate(otherWorkspace)

    #expect(reference.workspace == nil)
    #expect(probe.cancelled.wait(timeout: .now() + 10) == .success)
}

private final class WeakMacroWorkspaceReference {
    weak var workspace: Workspace?

    init(_ workspace: Workspace) {
        self.workspace = workspace
    }
}

@MainActor
private func workspaceWithMacroCancellationProbe(
    defaults: UserDefaults
) -> (WeakMacroWorkspaceReference, (
    task: Task<Void, Never>, cancelled: DispatchSemaphore
)) {
    let workspace = Workspace(defaults: defaults)
    let probe = macroCancellationProbe()
    workspace.fourDMacroPostprocessTask = probe.task
    workspace.fourDMacroPostprocessTabID = workspace.tabs[0].id
    workspace.fourDMacroPostprocessID = UUID()
    return (WeakMacroWorkspaceReference(workspace), probe)
}

private func macroCancellationProbe() -> (
    task: Task<Void, Never>, cancelled: DispatchSemaphore
) {
    let cancelled = DispatchSemaphore(value: 0)
    let task = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
        cancelled.signal()
    }
    return (task, cancelled)
}

@Test("Watch-Transaktion legt eine Datei beiseite und stellt sie wieder her")
func macroEngineWatchTransactionRoundtrip() throws {
    let root = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = root.appendingPathComponent("userPreferences.test")
    try FileManager.default.createDirectory(at: preferences,
                                            withIntermediateDirectories: true)
    let original = preferences.appendingPathComponent("debuggerWatches.json")
    try Data("aktuell".utf8).write(to: original)

    let backups = try FourDMacroEngine.setAsideDebuggerWatches(
        in: root, fileManager: .default
    )
    #expect(backups.count == 1)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    FourDMacroEngine.restoreDebuggerWatches(backups)
    #expect(try String(contentsOf: original, encoding: .utf8) == "aktuell")
}

@Test("Watch-Restore bleibt an den ursprünglich geöffneten Ordner gebunden")
func macroEngineWatchRestoreSurvivesDirectoryReplacement() throws {
    let root = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = root.appendingPathComponent("userPreferences.test")
    let movedPreferences = root.appendingPathComponent("userPreferences.moved")
    try FileManager.default.createDirectory(at: preferences,
                                            withIntermediateDirectories: true)
    let original = preferences.appendingPathComponent("debuggerWatches.json")
    try Data("ursprünglich".utf8).write(to: original)
    let backups = try FourDMacroEngine.setAsideDebuggerWatches(
        in: root, fileManager: .default
    )

    try FileManager.default.moveItem(at: preferences, to: movedPreferences)
    try FileManager.default.createDirectory(at: preferences,
                                            withIntermediateDirectories: true)
    try Data("Ersatzordner".utf8).write(to: original)
    FourDMacroEngine.restoreDebuggerWatches(backups)

    #expect(try String(contentsOf: original, encoding: .utf8) == "Ersatzordner")
    #expect(try String(contentsOf: movedPreferences.appendingPathComponent(
        "debuggerWatches.json"
    ), encoding: .utf8) == "ursprünglich")
}

@Test("Watch-Transaktion ohne vorhandene Datei bleibt eine leere Operation")
func macroEngineWatchTransactionWithoutFile() throws {
    let root = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("userPreferences.test"),
        withIntermediateDirectories: true
    )
    #expect(try FourDMacroEngine.setAsideDebuggerWatches(
        in: root, fileManager: .default
    ).isEmpty)
}

@Test("Watch-Transaktion verwechselt ähnlich benannte Ordner nicht mit Benutzerpräferenzen")
func macroEngineWatchTransactionRejectsPrefixConfusion() throws {
    let root = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["userPreferences", "userPreferences-test", "userPreferencesEvil"] {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try Data(name.utf8).write(to: directory.appendingPathComponent(
            "debuggerWatches.json"
        ))
    }

    #expect(try FourDMacroEngine.setAsideDebuggerWatches(
        in: root, fileManager: .default
    ).isEmpty)
    for name in ["userPreferences", "userPreferences-test", "userPreferencesEvil"] {
        let original = root.appendingPathComponent(name).appendingPathComponent(
            "debuggerWatches.json"
        )
        #expect(try String(contentsOf: original, encoding: .utf8) == name)
    }
}

@Test("Watch-Transaktion folgt keinem userPreferences-Symlink aus dem Engine-Projekt")
func macroEngineWatchTransactionRejectsPreferencesSymlink() throws {
    let root = try makeMacroScratch()
    let outside = try makeMacroScratch()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let original = outside.appendingPathComponent("debuggerWatches.json")
    try Data("außerhalb".utf8).write(to: original)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("userPreferences.test"),
        withDestinationURL: outside
    )

    #expect(throws: POSIXError.self) {
        try FourDMacroEngine.setAsideDebuggerWatches(
            in: root, fileManager: .default
        )
    }
    #expect(try String(contentsOf: original, encoding: .utf8) == "außerhalb")
    let outsideEntries = try FileManager.default.contentsOfDirectory(
        at: outside, includingPropertiesForKeys: nil
    )
    #expect(outsideEntries.map(\.lastPathComponent) == ["debuggerWatches.json"])
}

@Test("Watch-Transaktion startet mit keinem debuggerWatches-Symlink")
func macroEngineWatchTransactionRejectsWatchSymlink() throws {
    let root = try makeMacroScratch()
    let outside = try makeMacroScratch()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let preferences = root.appendingPathComponent("userPreferences.test")
    try FileManager.default.createDirectory(at: preferences,
                                            withIntermediateDirectories: true)
    let outsideWatch = outside.appendingPathComponent("watch.json")
    try Data("außerhalb".utf8).write(to: outsideWatch)
    try FileManager.default.createSymbolicLink(
        at: preferences.appendingPathComponent("debuggerWatches.json"),
        withDestinationURL: outsideWatch
    )

    #expect(throws: POSIXError.self) {
        try FourDMacroEngine.setAsideDebuggerWatches(
            in: root, fileManager: .default
        )
    }
    #expect(try String(contentsOf: outsideWatch, encoding: .utf8) == "außerhalb")
}

@Test("Watch-Vorbereitung bricht bei fehlendem exklusivem Rename ab und rollt zurück")
func macroEngineWatchPreparationFailureRollsBack() throws {
    let root = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let names = ["userPreferences.one", "userPreferences.two"]
    for name in names {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try Data(name.utf8).write(to: directory.appendingPathComponent(
            "debuggerWatches.json"
        ))
    }
    var renameCount = 0

    #expect(throws: POSIXError.self) {
        try FourDMacroEngine.setAsideDebuggerWatches(
            in: root, fileManager: .default,
            exclusiveRename: { directoryFD, source, destination in
                renameCount += 1
                if renameCount > 1 { return .ENOTSUP }
                guard renameatx_np(directoryFD, source,
                                   directoryFD, destination,
                                   UInt32(RENAME_EXCL)) != 0 else { return nil }
                return POSIXErrorCode(rawValue: errno) ?? .EIO
            }
        )
    }

    for name in names {
        let original = root.appendingPathComponent(name).appendingPathComponent(
            "debuggerWatches.json"
        )
        #expect(try String(contentsOf: original, encoding: .utf8) == name)
    }
}

@Test("Von mehreren Watch-Resten gewinnt der jüngste; ältere Fassungen bleiben erhalten")
func macroEngineRecoversNewestWatchWithoutDeletingOlderCopies() throws {
    let directory = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appendingPathComponent(
        "debuggerWatches.json.fastra-macro-backup-old"
    )
    let newest = directory.appendingPathComponent(
        "debuggerWatches.json.fastra-macro-backup-new"
    )
    try Data("alt".utf8).write(to: old)
    try Data("neu".utf8).write(to: newest)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                          ofItemAtPath: old.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
                                          ofItemAtPath: newest.path)

    FourDMacroEngine.recoverLeftoverWatchesBackups(in: directory,
                                                   fileManager: .default)
    let original = directory.appendingPathComponent("debuggerWatches.json")
    #expect(try String(contentsOf: original, encoding: .utf8) == "neu")
    let preserved = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(
        "debuggerWatches.json.fastra-macro-preserved-"
    ) }
    #expect(preserved.count == 1)
    #expect(try String(contentsOf: preserved[0], encoding: .utf8) == "alt")
}

@Test("Vorhandene Watch-Datei bleibt stehen; jeder Rest wird bewahrt")
func macroEnginePreservesLeftoversWhenOriginalExists() throws {
    let directory = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("debuggerWatches.json")
    try Data("4D-neu".utf8).write(to: original)
    for index in 1...2 {
        try Data("Rest \(index)".utf8).write(to: directory.appendingPathComponent(
            "debuggerWatches.json.fastra-macro-backup-\(index)"
        ))
    }
    FourDMacroEngine.recoverLeftoverWatchesBackups(in: directory,
                                                   fileManager: .default)
    #expect(try String(contentsOf: original, encoding: .utf8) == "4D-neu")
    let entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    #expect(entries.filter { $0.lastPathComponent.hasPrefix(
        "debuggerWatches.json.fastra-macro-preserved-"
    ) }.count == 2)
    #expect(entries.allSatisfy {
        !$0.lastPathComponent.hasPrefix("debuggerWatches.json.fastra-macro-backup-")
    })
}

@Test("Rest-Rettung überschreibt keine im letzten Moment angelegte Watch-Datei")
func macroEngineRecoveryUsesExclusiveRename() throws {
    let directory = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("debuggerWatches.json")
    let backup = directory.appendingPathComponent(
        "debuggerWatches.json.fastra-macro-backup-race"
    )
    try Data("vorher".utf8).write(to: backup)
    var injected = false

    FourDMacroEngine.recoverLeftoverWatchesBackups(
        in: directory, fileManager: .default,
        beforeExclusiveRename: {
            guard !injected else { return }
            injected = true
            try! Data("4D-neu".utf8).write(to: original)
        }
    )

    #expect(try String(contentsOf: original, encoding: .utf8) == "4D-neu")
    let preserved = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(
        "debuggerWatches.json.fastra-macro-preserved-"
    ) }
    #expect(preserved.count == 1)
    #expect(try String(contentsOf: preserved[0], encoding: .utf8) == "vorher")
}

@Test("Restore überschreibt keine im letzten Moment neu angelegte Watch-Datei")
func macroEngineRestoreUsesExclusiveRename() throws {
    let root = try makeMacroScratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("userPreferences.test")
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
    let original = directory.appendingPathComponent("debuggerWatches.json")
    try Data("vorher".utf8).write(to: original)
    let backups = try FourDMacroEngine.setAsideDebuggerWatches(
        in: root, fileManager: .default
    )

    FourDMacroEngine.restoreDebuggerWatches(
        backups,
        beforeExclusiveRename: {
            try! Data("4D-neu".utf8).write(to: original)
        }
    )

    #expect(try String(contentsOf: original, encoding: .utf8) == "4D-neu")
    let preserved = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(
        "debuggerWatches.json.fastra-macro-preserved-"
    ) }
    #expect(preserved.count == 1)
    #expect(try String(contentsOf: preserved[0], encoding: .utf8) == "vorher")
}
