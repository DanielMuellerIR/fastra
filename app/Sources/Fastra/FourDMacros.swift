// FourDMacros.swift
//
// Modell und Parser der 4D-Methodeneditor-Makros (Daniels Ideenliste,
// „4D-Makros"). Diese Datei ist bewusst PUR: nur Foundation, kein AppKit,
// kein Workspace, keine Oberfläche. Sie liest XML und beantwortet die Frage,
// was Fastra mit einem Makro überhaupt anfangen kann.
//
// 4D legt die Makros des Methodeneditors als XML in Ordnern namens
// „Macros v2" ab (DTD `macros.dtd` von 2007). Eine solche Datei sieht so aus:
//
//     <macros>
//       <macro name="Methode analysieren und ergänzen /#" version="2">
//         <text><caret/><method>MAO_MethodeKomplettierenNeu("&lt;method_name/&gt;")</method></text>
//       </macro>
//       <macro name="-" version="2"><text> </text></macro>
//     </macros>
//
// Zwei Eigenheiten dieses Formats bestimmen den ganzen Parser:
//
// 1. `<text>` enthält GEMISCHTEN Inhalt — echten Text und dazwischen leere
//    Element-Tags als Platzhalter (`<caret/>` für die spätere Einfügemarke,
//    `<selection/>` für den markierten Text und so weiter). Der Text muss
//    dabei zeichengenau erhalten bleiben: Die Einrückungen der Makros sind
//    der eingefügte 4D-Quelltext, ein „aufgeräumter" Whitespace wäre ein
//    Datenverlust.
// 2. `<method>` steht INNERHALB von `<text>` und enthält einen 4D-Methoden-
//    aufruf als Text. Der Platzhalter `<method_name/>` kommt darin real in
//    beiden Schreibweisen vor: als echtes Tag und als maskierter Text
//    (`&lt;method_name/&gt;`). Beide Formen werden hier auf dieselbe
//    Zeichenkette `<method_name/>` normalisiert, damit der spätere Ausführer
//    nur einen Fall kennen muss.
//
// Geparst wird mit Foundations `XMLParser`, nicht mit Regex: Ein Regex über
// gemischten Inhalt mit maskierten Tags wäre genau an den beiden Stellen
// falsch, an denen es darauf ankommt.

import Foundation

/// Ein Baustein des einzufügenden Makro-Textes. Die Reihenfolge der
/// Bausteine ist der einzufügende Text von links nach rechts.
enum FourDMacroTextPart: Equatable {
    /// Gewöhnlicher Text — genau so, wie er in der XML steht.
    case literal(String)
    /// `<caret/>`: Hier steht die Einfügemarke nach dem Einfügen.
    case caret
    /// `<selection/>`: Hier wird der zuvor markierte Text wieder eingesetzt.
    case selection
    /// `<text/>`: der komplette Text der aktuellen Methode.
    case fullText
    /// `<method_name/>`: Name der aktuellen Methode.
    case methodName
    /// `<user_os/>`: Anmeldename des Benutzers laut Betriebssystem.
    case userOS
    /// `<clipboard/>`: aktueller Inhalt der Zwischenablage.
    case clipboard
    /// `<date format="N"/>`: aktuelles Datum in einem der 4D-Formate.
    case date(format: Int)
    /// `<time format="N"/>`: aktuelle Uhrzeit in einem der 4D-Formate.
    case time(format: Int)
}

/// Ein geparstes Makro aus einer „Macros v2"-XML.
struct FourDMacro: Equatable, Identifiable {
    /// Stabil über Programmstarts hinweg: Quelle plus laufende Nummer in
    /// dieser Quelle. Der Name taugt dafür nicht — Trennlinien heißen alle
    /// „-", und derselbe Makroname kommt in mehreren Dateien vor.
    let id: String
    /// Name OHNE das Kürzel-Suffix „ /x" — das gehört in die Menüanzeige.
    let displayName: String
    /// Kürzel aus dem Suffix „ /x" des Namens (x ist genau EIN Zeichen,
    /// etwa `t`, `ü` oder `#`), kleingeschrieben.
    let shortcutKey: Character?
    /// Der einzufügende Text als Folge von Bausteinen.
    let textParts: [FourDMacroTextPart]
    /// Inhalt eines `<method>`-Tags: der 4D-Methodenaufruf als Text,
    /// `<method_name/>` darin immer als Zeichenkette `<method_name/>`.
    let methodCall: String?
    /// Name „-": im 4D-Menü eine Trennlinie, kein ausführbares Makro.
    let isSeparator: Bool
    /// Woher das Makro stammt, etwa der Dateiname der XML — für Tooltips.
    let sourceLabel: String
    /// Name eines Platzhalter-Tags im `<text>`, das Fastra nicht kennt.
    /// Ein solches Makro darf nicht eingefügt werden: Der Platzhalter würde
    /// still verschwinden und der eingesetzte Text wäre unvollständig.
    let unknownPlaceholder: String?
}

/// Welche Ausbaustufe der Methoden-Komplettierung ein Makro anfordert.
/// Die Rohwerte sind bewusst kurze, stabile Kennungen: Sie landen später in
/// gespeicherten Einstellungen und dürfen sich nicht mit der Anzeige ändern.
enum FourDKomplettierenVariant: String, Equatable, CaseIterable {
    case standard = "komplettieren"
    case ohneNichtVerwendet = "komplettieren-ohne-nv"
    case ohneVarUmwandlung = "komplettieren-ohne-var"
    case ohneNichtVerwendetUndVar = "komplettieren-ohne-nv-var"
}

/// Wie Fastra ein Makro ausführen kann.
enum FourDMacroCapability: Equatable {
    /// Reines Text-Makro: Fastra fügt den Text selbst ein.
    case nativeText
    /// `MAO_MethodeKomplettierenNeu` über die tool4d-Engine.
    case engine(FourDKomplettierenVariant)
    /// Braucht den 4D-Methodeneditor, die Zwischenablage oder das
    /// Hostprojekt. `reason` ist Nutzertext und wird direkt angezeigt.
    case unsupported(reason: String)
}

enum FourDMacroXML {

    /// Harte Obergrenzen für fremde Makro-XML. Eine einzelne übergroße oder
    /// absichtlich aufgeblähte Komponente darf weder den Hintergrundscan noch
    /// den dauerhaft gehaltenen Menükatalog unbeschränkt wachsen lassen.
    struct Limits: Equatable {
        let sourceBytes: Int
        let macroCount: Int
        let textUTF16Units: Int
        let partCount: Int

        init(sourceBytes: Int, macroCount: Int, textUTF16Units: Int,
             partCount: Int = 131_072) {
            self.sourceBytes = sourceBytes
            self.macroCount = macroCount
            self.textUTF16Units = textUTF16Units
            self.partCount = partCount
        }

        static let catalog = Limits(
            sourceBytes: 8 * 1024 * 1024,
            macroCount: 4_096,
            textUTF16Units: 4 * 1024 * 1024,
            partCount: 131_072
        )
    }

    // MARK: - Parsen

    /// Liest eine „Macros v2"-XML. Fehlertolerant: Ist die Datei kaputt,
    /// kommt eine leere Liste zurück — ein defekter Makro-Ordner darf die
    /// übrigen Fundorte nicht verhindern.
    ///
    /// `sourceLabel` ist der ANZEIGETEXT der Herkunft (üblicherweise der
    /// Dateiname, er steht im Tooltip). `sourceKey` ist dagegen die eindeutige
    /// Kennung der Quelle und gehört in die Makro-ID: Zwei gleichzeitig
    /// geladene Dateien heißen real beide „Macros.xml“ (mitgelieferte 4D-Makros
    /// und Komponenten-Makros), und aus gleichen IDs wählte der Menüklick sonst
    /// stets das erste Makro — also möglicherweise das einer anderen Quelle.
    /// Fehlt der Schlüssel, gilt weiterhin die Beschriftung.
    static func parse(data: Data, sourceLabel: String,
                      sourceKey: String? = nil,
                      limits: Limits = .catalog) -> [FourDMacro] {
        guard data.count <= limits.sourceBytes else { return [] }
        let parser = XMLParser(data: data)
        // Keine externen Entitäten auflösen: Eine fremde XML darf keine
        // Dateien nachladen. (Standardwert; hier ausdrücklich festgehalten.)
        parser.shouldResolveExternalEntities = false
        let collector = FourDMacroCollector(sourceLabel: sourceLabel,
                                            sourceKey: sourceKey ?? sourceLabel,
                                            limits: limits)
        parser.delegate = collector
        guard parser.parse(), !collector.exceededBudget else { return [] }
        return collector.macros
    }

    /// Zerlegt den Makronamen in Anzeigename und Kürzel. Ein Kürzel ist das
    /// Suffix „ /x" mit genau EINEM Zeichen; „ /ab" ist keins und bleibt
    /// deshalb vollständig im Anzeigenamen stehen.
    static func splitName(_ rawName: String) -> (displayName: String, shortcutKey: Character?) {
        let characters = Array(rawName)
        guard characters.count >= 3,
              characters[characters.count - 3] == " ",
              characters[characters.count - 2] == "/" else {
            return (rawName, nil)
        }
        let key = characters[characters.count - 1]
        // Ein Trennzeichen als „Kürzel" wäre keins — „ / " ist nur Text.
        guard !key.isWhitespace else { return (rawName, nil) }
        let display = String(characters[..<(characters.count - 3)])
            .trimmingTrailingWhitespace()
        return (display, key.lowercasedCharacter)
    }

    /// Entfernt Kürzel, die ein echtes App-Menü bereits als schlichtes ⌘-Kürzel
    /// belegt, sowie das zweite und jedes weitere Vorkommen eines Makro-Kürzels.
    /// Die Makros bleiben über das Menü ausführbar; nur ein irreführendes oder
    /// verlustnahes Tastenkürzel entfällt.
    static func resolvingShortcuts(in macros: [FourDMacro],
                                   reserved: Set<Character>) -> [FourDMacro] {
        var claimed = Set<Character>()
        return macros.map { macro in
            let key = macro.shortcutKey
            let available = key.flatMap { candidate -> Character? in
                guard !reserved.contains(candidate), claimed.insert(candidate).inserted else {
                    return nil
                }
                return candidate
            }
            guard available != key else { return macro }
            return FourDMacro(
                id: macro.id, displayName: macro.displayName,
                shortcutKey: available, textParts: macro.textParts,
                methodCall: macro.methodCall, isSeparator: macro.isSeparator,
                sourceLabel: macro.sourceLabel,
                unknownPlaceholder: macro.unknownPlaceholder
            )
        }
    }

    // MARK: - Einstufung

    /// Was Fastra mit diesem Makro tun kann. Reine Rechnung ohne
    /// Dateizugriff, damit die Oberfläche das gefahrlos beim Aufbauen des
    /// Menüs fragen kann.
    static func capability(of macro: FourDMacro) -> FourDMacroCapability {
        if macro.isSeparator {
            return .unsupported(
                reason: L10n.string("Trennlinie im Makro-Menü — hier gibt es nichts auszuführen.")
            )
        }
        // Ein Platzhalter, den Fastra nicht kennt, darf nicht einfach
        // wegfallen: Der eingefügte Text wäre unvollständig, ohne dass es
        // jemand merkt (Produktinvariante „keine stillen Fallbacks").
        if let placeholder = macro.unknownPlaceholder {
            return .unsupported(reason: L10n.format(
                "Das Makro enthält den 4D-Platzhalter <%@/>, den Fastra nicht kennt. Es würde sonst unvollständigen Text einsetzen; im 4D-Methodeneditor läuft es weiterhin.",
                placeholder
            ))
        }
        if let call = macro.methodCall,
           !call.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return capability(ofCall: call)
        }
        for part in macro.textParts {
            switch part {
            case .date(let format) where !(0...8).contains(format):
                return .unsupported(reason: L10n.format(
                    "Das Makro verlangt das unbekannte 4D-Datumsformat %ld (erlaubt: 0 bis 8).",
                    format
                ))
            case .time(let format) where !(0...6).contains(format):
                return .unsupported(reason: L10n.format(
                    "Das Makro verlangt das unbekannte 4D-Zeitformat %ld (erlaubt: 0 bis 6).",
                    format
                ))
            default:
                break
            }
        }
        guard macro.textParts.contains(where: isMeaningful) else {
            return .unsupported(
                reason: L10n.string("Reiner Anzeigeeintrag: Das Makro fügt keinen Text ein.")
            )
        }
        if macro.textParts.contains(.clipboard) {
            return .unsupported(
                reason: L10n.string("Zwischenablage-Makros laufen nur im 4D-Methodeneditor.")
            )
        }
        return .nativeText
    }

    /// Ein Baustein zählt als Inhalt, wenn er kein reiner Leerraum ist.
    /// Platzhalter zählen immer — `<selection/>` allein ist ein sinnvolles
    /// Makro (es setzt die Auswahl wieder ein).
    private static func isMeaningful(_ part: FourDMacroTextPart) -> Bool {
        if case .literal(let text) = part {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Einstufung eines `<method>`-Aufrufs.
    private static func capability(ofCall call: String) -> FourDMacroCapability {
        guard let parsed = parseMethodCall(call) else {
            return .unsupported(
                reason: L10n.string("Der Methodenaufruf dieses Makros ist nicht lesbar.")
            )
        }
        guard parsed.name.compare("MAO_MethodeKomplettierenNeu",
                                  options: .caseInsensitive) == .orderedSame else {
            return .unsupported(reason: L10n.format(
                "Das Makro ruft die 4D-Methode %@ auf und braucht dafür den 4D-Methodeneditor (Editor-Auswahl, Zwischenablage oder Host-Projekt); headless über tool4d ist das nicht ausführbar.",
                parsed.name
            ))
        }
        guard let variant = komplettierenVariant(arguments: parsed.arguments) else {
            return .unsupported(reason: L10n.format(
                "Die Argumente des Komplettieren-Aufrufs (%@) passen zu keiner Variante, die Fastra kennt.",
                parsed.arguments.joined(separator: "; ")
            ))
        }
        return .engine(variant)
    }

    /// Argumente von `MAO_MethodeKomplettierenNeu` auf eine Variante
    /// abbilden. `$1` ist der Methodenname, `$2` ist immer `False` und `$3`
    /// immer `""` — für die Variante zählen allein `$4` (nicht verwendete
    /// Variablen weglassen) und `$5` (var-Umwandlung weglassen).
    ///
    /// Geprüft werden die vier realen Varianten samt ihren festen Werten. Die
    /// Standardvariante darf ihre unveränderten Präfixargumente ausschreiben;
    /// alles andere ergibt `nil` und wird als „kennt Fastra nicht" erklärt.
    /// Ein fremdes oder künftig erweitertes Makro darf nicht als bekannte
    /// Variante durchgehen und dann mit anderer Bedeutung laufen.
    static func komplettierenVariant(arguments: [String]) -> FourDKomplettierenVariant? {
        // Erstes Argument ist immer der Methodenplatzhalter, in beiden
        // Schreibweisen, die real vorkommen: mit und ohne Anführungszeichen.
        guard let first = arguments.first, isMethodNamePlaceholder(first) else {
            return nil
        }
        if arguments.count == 1 { return .standard }
        // Ausgeschriebene Präfixe der Standardform sind ebenfalls gültig:
        // `$2=False`, `$3=""` und `$4=False` verändern ihre Bedeutung nicht.
        guard booleanLiteral(arguments[1]) == false else { return nil }
        if arguments.count == 2 { return .standard }
        guard isEmptyStringLiteral(arguments[2]) else { return nil }
        if arguments.count == 3 { return .standard }
        if arguments.count == 4 {
            switch booleanLiteral(arguments[3]) {
            case true: return .ohneNichtVerwendet
            case false: return .standard
            case nil: return nil
            }
        }
        guard arguments.count == 5 else { return nil }
        switch (booleanLiteral(arguments[3]), booleanLiteral(arguments[4])) {
        case (false, false): return .ohneVarUmwandlung
        case (true, false): return .ohneNichtVerwendetUndVar
        default: return nil
        }
    }

    /// Der Methodenplatzhalter `<method_name/>`, wahlweise in doppelten
    /// Anführungszeichen (so steht er maskiert in der XML).
    static func isMethodNamePlaceholder(_ argument: String) -> Bool {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "<method_name/>" || trimmed == "\"<method_name/>\""
    }

    /// Die leere Zeichenkette `""` als 4D-Literal.
    static func isEmptyStringLiteral(_ argument: String) -> Bool {
        argument.trimmingCharacters(in: .whitespacesAndNewlines) == "\"\""
    }

    /// `true`/`false` als 4D-Literal; alles andere ist keine Wahrheitsangabe.
    static func booleanLiteral(_ argument: String) -> Bool? {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    // MARK: - Methodenaufruf zerlegen

    /// Zerlegt `Name("a";False;"")` in Methodennamen und Argumente.
    /// Bewusst eine einfache, robuste Zerlegung und kein 4D-Parser: Sie
    /// respektiert nur verschachtelte Klammern und Zeichenketten in doppelten
    /// Anführungszeichen (mit `\"` als maskiertem Anführungszeichen). Ein
    /// Semikolon INNERHALB einer Zeichenkette trennt deshalb nicht.
    /// Ohne Klammern gilt der ganze Text als Methodenname ohne Argumente;
    /// bei fehlender schließender Klammer kommt `nil` zurück. Steht hinter der
    /// schließenden Klammer noch etwas anderes als Leerraum, ist das kein
    /// einzelner Aufruf mehr — dann kommt ebenfalls `nil`, statt den Rest
    /// stillschweigend wegzuwerfen.
    static func parseMethodCall(_ call: String) -> (name: String, arguments: [String])? {
        let characters = Array(call.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !characters.isEmpty else { return nil }
        guard let open = indexOfTopLevelOpeningParenthesis(characters) else {
            return (String(characters), [])
        }
        let name = String(characters[..<open])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let close = indexOfMatchingParenthesis(characters, from: open) else {
            return nil
        }
        guard characters[(close + 1)...].allSatisfy(\.isWhitespace) else { return nil }
        return (name, splitArguments(Array(characters[(open + 1)..<close])))
    }

    /// Erste öffnende Klammer außerhalb einer Zeichenkette.
    private static func indexOfTopLevelOpeningParenthesis(_ characters: [Character]) -> Int? {
        var inString = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "(" {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Zu einer öffnenden Klammer die passende schließende finden.
    private static func indexOfMatchingParenthesis(_ characters: [Character],
                                                   from open: Int) -> Int? {
        var depth = 0
        var inString = false
        var index = open
        while index < characters.count {
            let character = characters[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Klammerinhalt an den Semikola der obersten Ebene trennen.
    private static func splitArguments(_ characters: [Character]) -> [String] {
        guard !characters.isEmpty else { return [] }
        var arguments: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                current.append(character)
                if character == "\\", index + 1 < characters.count {
                    current.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"":
                    inString = true
                    current.append(character)
                case "(", "[", "{":
                    depth += 1
                    current.append(character)
                case ")", "]", "}":
                    depth -= 1
                    current.append(character)
                case ";" where depth == 0:
                    arguments.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                default:
                    current.append(character)
                }
            }
            index += 1
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        // `Name()` hat kein Argument, `Name("a";)` dagegen ein leeres zweites.
        if !arguments.isEmpty || !last.isEmpty { arguments.append(last) }
        return arguments
    }

    // MARK: - Dateiname → Methodenname

    /// Methodenname zu einer `.4dm`-Datei. Die Unicode-Normalisierung ist
    /// keine Kosmetik: Das Dateisystem liefert Umlaute zerlegt (NFD, „U" plus
    /// Trema), 4D erwartet sie zusammengesetzt (NFC, „Ü"). Ohne diesen
    /// Schritt findet ein Vergleich mit dem Methodennamen aus dem Projekt
    /// bei jedem Umlaut nichts.
    static func normalizedMethodName(forFileName fileName: String) -> String {
        var name = fileName
        if name.lowercased().hasSuffix(".4dm") { name = String(name.dropLast(4)) }
        return name.precomposedStringWithCanonicalMapping
    }
}

// MARK: - XML-Delegat

/// Sammelt die Makros beim Durchlaufen der XML. Eigene Klasse, weil
/// `XMLParser` einen Delegaten mit Zustand braucht; der Zustand bleibt
/// vollständig hier drin.
private final class FourDMacroCollector: NSObject, XMLParserDelegate {

    /// Das 4D-Schema ist nur wenige Ebenen tief. Die zusätzliche Grenze
    /// verhindert, dass eine künstlich tief verschachtelte XML den
    /// Elementstapel trotz begrenzter Dateigröße unnötig aufbläht.
    private static let maximumElementDepth = 256

    private let sourceLabel: String
    /// Eindeutige Kennung der Quelle für die Makro-IDs (siehe `parse`).
    private let sourceKey: String
    private let limits: FourDMacroXML.Limits
    private(set) var macros: [FourDMacro] = []
    private(set) var exceededBudget = false
    private var textUTF16Units = 0
    private var seenMacroCount = 0
    private var seenPartCount = 0

    /// Die gerade offenen Elemente. Über die Tiefe unterscheidet sich das
    /// umschließende `<text>`-Element vom gleichnamigen Platzhalter `<text/>`
    /// darin — beide heißen „text", nur die Verschachtelung trennt sie.
    private var openElements: [String] = []
    /// Tiefe, in der das umschließende `<text>` geöffnet wurde.
    private var textContainerDepth: Int?
    /// Tiefe, in der ein `<method>` geöffnet wurde.
    private var methodDepth: Int?

    private var currentRawName: String?
    private var currentParts: [FourDMacroTextPart] = []
    private var pendingLiteral = ""
    private var currentMethodCall: String?
    /// Erstes unbekanntes Platzhalter-Tag im `<text>` des laufenden Makros.
    private var currentUnknownPlaceholder: String?

    init(sourceLabel: String, sourceKey: String,
         limits: FourDMacroXML.Limits) {
        self.sourceLabel = sourceLabel
        self.sourceKey = sourceKey
        self.limits = limits
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        guard openElements.count < Self.maximumElementDepth else {
            exceededBudget = true
            parser.abortParsing()
            return
        }
        openElements.append(elementName)
        let depth = openElements.count

        if elementName == "macro" {
            guard seenMacroCount < limits.macroCount else {
                exceededBudget = true
                parser.abortParsing()
                return
            }
            seenMacroCount += 1
            beginMacro(name: attributeDict["name"] ?? "")
            return
        }
        guard currentRawName != nil else { return }

        // Innerhalb von <method> zählt nur Text; das einzige Tag mit
        // Bedeutung ist <method_name/>, das als Zeichenkette erhalten bleibt.
        if methodDepth != nil {
            if elementName == "method_name" {
                currentMethodCall? += "<method_name/>"
            } else if currentUnknownPlaceholder == nil {
                // Auch im Methodenaufruf darf ein unbekanntes Tag nicht still
                // verschwinden und dadurch die Argumentbedeutung ändern.
                currentUnknownPlaceholder = elementName
            }
            return
        }
        // Solange kein <text> offen ist, ist ein „text" das umschließende
        // Element — erst darin wird daraus der Platzhalter <text/>.
        guard textContainerDepth != nil else {
            if elementName == "text" { textContainerDepth = depth }
            return
        }
        if elementName == "method" {
            methodDepth = depth
            currentMethodCall = ""
            return
        }
        appendPlaceholder(elementName, attributes: attributeDict, parser: parser)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let depth = openElements.count
        if methodDepth == depth, elementName == "method" {
            methodDepth = nil
        } else if textContainerDepth == depth, elementName == "text" {
            textContainerDepth = nil
        } else if elementName == "macro" {
            finishMacro(parser)
        }
        if !openElements.isEmpty { openElements.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textUTF16Units += (string as NSString).length
        guard textUTF16Units <= limits.textUTF16Units else {
            exceededBudget = true
            parser.abortParsing()
            return
        }
        if methodDepth != nil {
            currentMethodCall? += string
        } else if textContainerDepth != nil {
            // Whitespace bleibt Zeichen für Zeichen erhalten: Die Einrückung
            // ist der einzufügende 4D-Quelltext.
            pendingLiteral += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: text)
    }

    // MARK: - Zustandswechsel

    private func beginMacro(name: String) {
        currentRawName = name
        currentParts = []
        pendingLiteral = ""
        currentMethodCall = nil
        currentUnknownPlaceholder = nil
        textContainerDepth = nil
        methodDepth = nil
    }

    private func finishMacro(_ parser: XMLParser) {
        guard let rawName = currentRawName else { return }
        flushLiteral(parser)
        guard !exceededBudget else { return }
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSeparator = trimmedName == "-"
        let split = isSeparator
            ? (displayName: trimmedName, shortcutKey: Character?.none)
            : FourDMacroXML.splitName(rawName)
        macros.append(FourDMacro(
            id: "\(sourceKey)#\(macros.count)",
            displayName: split.displayName,
            shortcutKey: split.shortcutKey,
            textParts: currentParts,
            methodCall: currentMethodCall,
            isSeparator: isSeparator,
            sourceLabel: sourceLabel,
            unknownPlaceholder: currentUnknownPlaceholder
        ))
        currentRawName = nil
        currentParts = []
        pendingLiteral = ""
        currentMethodCall = nil
        currentUnknownPlaceholder = nil
        textContainerDepth = nil
        methodDepth = nil
    }

    /// Bekannte Platzhalter abbilden. Ein unbekanntes Tag wird vermerkt: Sein
    /// Textinhalt liefe zwar als `.literal` durch, aber die Bedeutung des Tags
    /// selbst kennt Fastra nicht. Das Makro gilt dadurch als nicht ausführbar
    /// (siehe `capability`), statt still unvollständigen Text einzusetzen.
    private func appendPlaceholder(_ elementName: String,
                                   attributes: [String: String],
                                   parser: XMLParser) {
        let part: FourDMacroTextPart
        switch elementName {
        case "caret": part = .caret
        case "selection": part = .selection
        case "text": part = .fullText
        case "method_name": part = .methodName
        case "user_os": part = .userOS
        case "clipboard": part = .clipboard
        case "date": part = .date(format: parsedFormat(attributes["format"]))
        case "time": part = .time(format: parsedFormat(attributes["format"]))
        default:
            // Der erste unbekannte Platzhalter gewinnt — er steht später in
            // der Erklärung, warum das Makro nicht ausführbar ist.
            if currentUnknownPlaceholder == nil {
                currentUnknownPlaceholder = elementName
            }
            return
        }
        flushLiteral(parser)
        appendPart(part, parser: parser)
    }

    /// Fehlendes Format = 4D-Standard 0. Ein nicht numerischer Wert bleibt als
    /// -1 sichtbar und wird von `capability` erklärt, statt still zu 0 zu werden.
    private func parsedFormat(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Gesammelten Text als einen Baustein ablegen. So entsteht pro
    /// zusammenhängendem Textstück genau ein `.literal`, auch wenn
    /// `XMLParser` es in mehreren Häppchen liefert.
    private func flushLiteral(_ parser: XMLParser) {
        guard !pendingLiteral.isEmpty else { return }
        appendPart(.literal(pendingLiteral), parser: parser)
        pendingLiteral = ""
    }

    /// Auch null Zeichen lange Platzhalter besitzen Array- und Enum-Speicher.
    /// Die Textgrenze allein begrenzt diese Struktur deshalb nicht.
    private func appendPart(_ part: FourDMacroTextPart, parser: XMLParser) {
        guard seenPartCount < limits.partCount else {
            exceededBudget = true
            parser.abortParsing()
            return
        }
        seenPartCount += 1
        currentParts.append(part)
    }
}

// MARK: - Kleine Helfer

private extension Character {
    /// Kleinbuchstabe eines einzelnen Zeichens. Kleinschreiben kann in
    /// Unicode mehrere Zeichen ergeben; dann bleibt das Original stehen,
    /// statt eine Hälfte zu verlieren.
    var lowercasedCharacter: Character {
        let lowered = String(self).lowercased()
        return lowered.count == 1 ? Character(lowered) : self
    }
}

private extension String {
    /// Nur den Leerraum am ENDE entfernen — führender Leerraum eines
    /// Makronamens ist Absicht des Autors (Einrückung im Menü).
    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
