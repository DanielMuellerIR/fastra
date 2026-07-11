// Patterns/BuiltInPatterns.swift
//
// Mitgelieferte RegEx-Vorlagen für v1.0.
// Liste und Auswahl-Begründung: Produktmanagement/Suchmasken-Konzept-v1.0.md
// (Abschnitt B „Vorlagen-Liste").
//
// Anpassungen an dieser Liste sind okay — aber bitte die Tests in
// Tests/FastraTests/PatternTests.swift laufen lassen, damit jede Vorlage
// ihren Beispiel-Treffer weiterhin findet und die Group-Labels zur
// Group-Anzahl passen.

import Foundation

public enum BuiltInPatterns {

    // MARK: - Identifikatoren (5)

    /// E-Mail-Adresse. Pragmatisch, **nicht** RFC-5322-vollständig — die
    /// vollständige Spec ist 200 Zeichen lang und in der Praxis nicht
    /// nützlich. Dies hier deckt > 99 % der real vorkommenden Adressen.
    public static let email = PatternTemplate(
        id: "email",
        name: "E-Mail-Adresse",
        category: .identifier,
        regex: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        exampleMatch: "max.muster@example.com"
    )

    /// URL (http oder https). Bewusst einfach gehalten — wir greifen nicht
    /// alle URI-Schemes ab. Wer FTP-URLs sucht, baut sich eine eigene.
    public static let url = PatternTemplate(
        id: "url",
        name: "URL",
        category: .identifier,
        regex: #"https?://[\w.-]+(?:/[\w./?=&%#-]*)?"#,
        exampleMatch: "https://example.com/path?q=1"
    )

    /// IBAN — Länderkürzel + 2-stellige Prüfziffer + bis zu 30 alphanum.
    /// Stellen. Validierungslogik (Mod-97) liegt außerhalb dessen, was
    /// ein RegEx leisten kann.
    public static let iban = PatternTemplate(
        id: "iban",
        name: "IBAN",
        category: .identifier,
        regex: #"[A-Z]{2}\d{2}[A-Z0-9]{1,30}"#,
        exampleMatch: "DE89370400440532013000"
    )

    /// IPv4-Adresse. Akzeptiert auch invalide Werte wie `999.999.999.999`
    /// — die exakte 0-255-Range über RegEx zu prüfen ist möglich, aber
    /// macht die Vorlage unleserlich. Für Suche reicht das hier.
    public static let ipv4 = PatternTemplate(
        id: "ipv4",
        name: "IPv4-Adresse",
        category: .identifier,
        regex: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
        exampleMatch: "192.168.1.1"
    )

    /// UUID Version 4-Format (8-4-4-4-12 Hex).
    public static let uuid = PatternTemplate(
        id: "uuid",
        name: "UUID",
        category: .identifier,
        regex: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
        exampleMatch: "550e8400-e29b-41d4-a716-446655440000"
    )

    // MARK: - Datum & Zeit (3)

    /// ISO-Datum `YYYY-MM-DD`. Drei Capture Groups: Jahr, Monat, Tag.
    /// Default-Ersetzung dreht ins deutsche Format `DD.MM.YYYY` um —
    /// klassischer „Fastra-Moment" und gleich ein didaktisches Beispiel
    /// für die Drag&Drop-Mechanik.
    public static let isoDate = PatternTemplate(
        id: "iso_date",
        name: "ISO-Datum (YYYY-MM-DD)",
        category: .dateTime,
        regex: #"\b(\d{4})-(\d{2})-(\d{2})\b"#,
        exampleMatch: "2026-05-26",
        groupLabels: ["Jahr", "Monat", "Tag"],
        defaultReplacement: "$3.$2.$1"
    )

    /// Deutsches Datum `DD.MM.YYYY`. Spiegelbild von `isoDate`.
    public static let germanDate = PatternTemplate(
        id: "german_date",
        name: "Deutsches Datum (DD.MM.YYYY)",
        category: .dateTime,
        regex: #"\b(\d{2})\.(\d{2})\.(\d{4})\b"#,
        exampleMatch: "26.05.2026",
        groupLabels: ["Tag", "Monat", "Jahr"],
        defaultReplacement: "$3-$2-$1"
    )

    /// Uhrzeit `HH:MM` oder `HH:MM:SS`. Die Sekunden sind optional —
    /// `$3` ist dann leer. Das ist auch ein guter Test für unsere
    /// UI: leere Gruppen müssen sinnvoll dargestellt werden.
    public static let time = PatternTemplate(
        id: "time",
        name: "Uhrzeit",
        category: .dateTime,
        regex: #"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b"#,
        exampleMatch: "14:30:45",
        groupLabels: ["Stunden", "Minuten", "Sekunden"]
    )

    // MARK: - Text-Strukturen (5)

    /// Markdown-Link `[Text](url)`. Zwei Gruppen — Standard-Ersetzung
    /// `$1` extrahiert nur den Text (Link entfernen, Beschriftung
    /// behalten).
    public static let markdownLink = PatternTemplate(
        id: "md_link",
        name: "Markdown-Link",
        category: .textStructure,
        regex: #"\[([^\]]+)\]\(([^)]+)\)"#,
        exampleMatch: "[OpenAI](https://openai.com)",
        groupLabels: ["Linktext", "URL"],
        defaultReplacement: "$1"
    )

    /// Markdown-Überschrift `# … ######`. `$1` = Anzahl Doppelkreuze
    /// (Level), `$2` = Titel.
    /// Achtung: `^`/`$` brauchen `.anchorsMatchLines` beim Anwenden auf
    /// mehrzeilige Dokumente — das setzt die Engine später im Anwender-
    /// Code, nicht in der Vorlage.
    public static let markdownHeading = PatternTemplate(
        id: "md_heading",
        name: "Markdown-Überschrift",
        category: .textStructure,
        regex: #"^(#{1,6})\s+(.+)$"#,
        exampleMatch: "## Überschrift",
        groupLabels: ["Level (#-Zeichen)", "Titel"]
    )

    /// HTML-Tag (öffnend oder schließend). Drei Gruppen: Slash,
    /// Tag-Name, Attribute. Nutzbar z.B. für „alle `<img>`-Tags
    /// behalten, Rest entfernen".
    public static let htmlTag = PatternTemplate(
        id: "html_tag",
        name: "HTML-Tag",
        category: .textStructure,
        regex: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"#,
        exampleMatch: #"<a href="https://example.com">"#,
        groupLabels: ["Schließend? (/)", "Tag-Name", "Attribute"]
    )

    /// Fenced Code-Block (Markdown / GFM).
    /// Zwei Gruppen: Sprache (kann leer sein), Inhalt.
    /// Mehrzeilig — die `\s\S`-Klasse ist nötig, weil `.` in
    /// NSRegularExpression standardmäßig kein Newline matcht.
    public static let codeBlock = PatternTemplate(
        id: "code_block",
        name: "Code-Block (Markdown)",
        category: .textStructure,
        regex: #"```(\w*)\n([\s\S]*?)```"#,
        exampleMatch: "```swift\nlet x = 1\n```",
        groupLabels: ["Sprache", "Inhalt"]
    )

    /// Dateipfad — Ordnerpfad (inkl. trailing Slash) + Dateiname.
    /// Klassischer Anwendungsfall für die Drag&Drop-Demo:
    /// „Pfad und Dateiname tauschen" oder „nur Dateinamen behalten".
    /// Wie bei `markdownHeading` braucht `$` ggf. `.anchorsMatchLines`.
    public static let filePath = PatternTemplate(
        id: "file_path",
        name: "Dateipfad",
        category: .textStructure,
        regex: #"(.+/)([^/]+)$"#,
        exampleMatch: "/pfad/zu/notiz.md",
        groupLabels: ["Ordnerpfad", "Dateiname"],
        defaultReplacement: "$2"
    )

    // MARK: - Zahlen (3)

    /// Ganzzahl mit optionalem Minuszeichen.
    public static let integer = PatternTemplate(
        id: "integer",
        name: "Ganzzahl",
        category: .numbers,
        regex: #"-?\d+"#,
        exampleMatch: "-42"
    )

    /// Dezimalzahl im deutschen Format: Komma als Dezimal­trennzeichen,
    /// Punkt als Tausender­trennzeichen (optional).
    /// Matcht u.a.: `0,5` · `12,34` · `1.234,56` · `-7,89`
    /// Matcht nicht: `1,234.56` (das wäre das englische Format).
    public static let germanDecimal = PatternTemplate(
        id: "german_decimal",
        name: "Dezimalzahl (deutsch)",
        category: .numbers,
        regex: #"-?\d+(?:\.\d{3})*,\d+"#,
        exampleMatch: "1.234,56"
    )

    /// Deutsche Telefonnummer. Bewusst tolerant — verschiedene
    /// Schreibweisen, Trennzeichen Space/Slash/Bindestrich.
    /// Matcht u.a.: `+49 30 12345678` · `030/1234567` · `0151-12345678`
    public static let phoneDE = PatternTemplate(
        id: "phone_de",
        name: "Telefonnummer (DE)",
        category: .numbers,
        regex: #"(?:\+49|0)[\s/-]?\d{2,5}[\s/-]?\d{4,8}"#,
        exampleMatch: "+49 30 12345678"
    )

    // MARK: - Identifikatoren, Ergänzungen (v1.1)

    /// Hex-Farbwert `#RGB` oder `#RRGGBB`.
    public static let hexColor = PatternTemplate(
        id: "hex_color",
        name: "Hex-Farbe (#RRGGBB)",
        category: .identifier,
        regex: #"#(?:[0-9a-fA-F]{3}){1,2}\b"#,
        exampleMatch: "#FF9900"
    )

    /// Versionsnummer nach SemVer-Muster, optional mit führendem `v`.
    public static let semver = PatternTemplate(
        id: "semver",
        name: "Versionsnummer (v1.2.3)",
        category: .identifier,
        regex: #"\bv?\d+\.\d+\.\d+\b"#,
        exampleMatch: "v1.2.3"
    )

    /// Dateiname mit Endung. Die Endung muss mit einem Buchstaben beginnen —
    /// sonst würde jede Dezimalzahl („1.23") fälschlich mitgematcht.
    public static let fileName = PatternTemplate(
        id: "file_name",
        name: "Dateiname mit Endung",
        category: .identifier,
        regex: #"[\w.-]+\.[A-Za-z][A-Za-z0-9]{0,4}\b"#,
        exampleMatch: "notiz.md"
    )

    // MARK: - Datum & Zeit, Ergänzungen (v1.1)

    /// ISO-Zeitstempel `YYYY-MM-DD HH:MM[:SS]` (Trenner Space oder `T`).
    /// Sechs Gruppen — Sekunden optional (`$6` ggf. leer, wie bei `time`).
    public static let isoTimestamp = PatternTemplate(
        id: "iso_timestamp",
        name: "ISO-Zeitstempel",
        category: .dateTime,
        regex: #"\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\b"#,
        exampleMatch: "2026-07-10 15:30:00",
        groupLabels: ["Jahr", "Monat", "Tag", "Stunden", "Minuten", "Sekunden"]
    )

    // MARK: - Text-Strukturen, Ergänzungen (v1.1)

    /// HTML-/XML-Kommentar `<!-- … -->` (auch mehrzeilig — `[\s\S]` statt
    /// `.`, weil `.` in NSRegularExpression kein Newline matcht).
    public static let htmlComment = PatternTemplate(
        id: "html_comment",
        name: "HTML-Kommentar",
        category: .textStructure,
        regex: #"<!--[\s\S]*?-->"#,
        exampleMatch: "<!-- TODO: prüfen -->"
    )

    // MARK: - Zahlen, Ergänzungen (v1.1)

    /// Dezimalzahl im englischen Format: Punkt als Dezimaltrennzeichen,
    /// Komma als Tausendertrennzeichen (optional). Spiegelbild von
    /// `germanDecimal`.
    public static let englishDecimal = PatternTemplate(
        id: "english_decimal",
        name: "Dezimalzahl (englisch)",
        category: .numbers,
        regex: #"-?\d+(?:,\d{3})*\.\d+"#,
        exampleMatch: "1,234.56"
    )

    /// Prozentangabe — Ganz- oder Dezimalzahl (Komma oder Punkt), optionales
    /// Leerzeichen vor dem Prozentzeichen.
    public static let percentage = PatternTemplate(
        id: "percentage",
        name: "Prozentangabe",
        category: .numbers,
        regex: #"-?\d+(?:[.,]\d+)?\s?%"#,
        exampleMatch: "42,5 %"
    )

    /// Euro-Betrag im deutschen Format (`1.234,56 €`), Cent optional.
    public static let euroAmount = PatternTemplate(
        id: "euro_amount",
        name: "Geldbetrag (€)",
        category: .numbers,
        regex: #"-?\d{1,3}(?:\.\d{3})*(?:,\d{2})?\s?€"#,
        exampleMatch: "1.234,56 €"
    )

    // MARK: - Wörter & Zeilen (v1.1)
    //
    // Die „simplen" Vorlagen für Nicht-RegEx-Profis — genau die Fälle aus
    // Daniels Tests (Namen tauschen). Bewusst mit `\w`: ICU-\w ist Unicode-
    // fähig und matcht auch Umlaute/ß.

    /// Ein einzelnes Wort.
    public static let oneWord = PatternTemplate(
        id: "one_word",
        name: "Ein Wort",
        category: .words,
        regex: #"\w+"#,
        exampleMatch: "Hallo"
    )

    /// Zwei Wörter hintereinander — die Standard-Ersetzung tauscht sie.
    public static let twoWords = PatternTemplate(
        id: "two_words",
        name: "Zwei Wörter (tauschen)",
        category: .words,
        regex: #"(\w+)\s+(\w+)"#,
        exampleMatch: "Michael Mustermann",
        groupLabels: ["Erstes Wort", "Zweites Wort"],
        defaultReplacement: "$2 $1"
    )

    /// „Nachname, Vorname" → die Standard-Ersetzung dreht zu
    /// „Vorname Nachname" (der klassische Namenslisten-Fall).
    public static let lastFirstName = PatternTemplate(
        id: "last_first_name",
        name: "Nachname, Vorname → Vorname Nachname",
        category: .words,
        regex: #"(\w+),\s*(\w+)"#,
        exampleMatch: "Mustermann, Michael",
        groupLabels: ["Nachname", "Vorname"],
        defaultReplacement: "$2 $1"
    )

    /// Versehentlich doppelt getipptes Wort („der der") — die Standard-
    /// Ersetzung behält es einmal. `\1` referenziert im SUCH-Muster die
    /// erste Gruppe (Backreference), `$1` in der Ersetzung.
    public static let doubledWord = PatternTemplate(
        id: "doubled_word",
        name: "Doppeltes Wort (der der)",
        category: .words,
        regex: #"\b(\w+)\s+\1\b"#,
        exampleMatch: "der der",
        groupLabels: ["Wort"],
        defaultReplacement: "$1"
    )

    /// Großgeschriebenes Wort (Namen, Satzanfänge, Substantive).
    public static let capitalizedWord = PatternTemplate(
        id: "capitalized_word",
        name: "Großgeschriebenes Wort",
        category: .words,
        regex: #"\b[A-ZÄÖÜ][a-zäöüß]+\b"#,
        exampleMatch: "Berlin"
    )

    /// Text in geraden Anführungszeichen — `$1` ist der Inhalt ohne
    /// Anführungszeichen (Standard-Ersetzung entfernt sie).
    public static let quotedText = PatternTemplate(
        id: "quoted_text",
        name: "Text in \"Anführungszeichen\"",
        category: .words,
        regex: #""([^"]*)""#,
        exampleMatch: #""Zitat""#,
        groupLabels: ["Inhalt"],
        defaultReplacement: "$1"
    )

    /// Text in typografischen deutschen Anführungszeichen („…“).
    public static let germanQuotedText = PatternTemplate(
        id: "german_quoted_text",
        name: "Text in „Anführungszeichen“",
        category: .words,
        regex: #"„([^“]*)“"#,
        exampleMatch: "„Zitat“",
        groupLabels: ["Inhalt"],
        defaultReplacement: "$1"
    )

    /// Text in runden Klammern — `$1` ist der Inhalt.
    public static let parenthesizedText = PatternTemplate(
        id: "parenthesized_text",
        name: "Text in (Klammern)",
        category: .words,
        regex: #"\(([^)]*)\)"#,
        exampleMatch: "(Hinweis)",
        groupLabels: ["Inhalt"],
        defaultReplacement: "$1"
    )

    /// Eine komplette Zeile (`^`/`$` wirken pro Zeile — die Engine setzt
    /// `.anchorsMatchLines` beim Anwenden, wie bei `markdownHeading`).
    public static let wholeLine = PatternTemplate(
        id: "whole_line",
        name: "Ganze Zeile",
        category: .words,
        regex: #"^.*$"#,
        exampleMatch: "eine ganze Zeile"
    )

    // MARK: - Leerraum & Aufräumen (v1.1)

    /// Mehrfache Leerzeichen — Standard-Ersetzung schrumpft auf eines.
    public static let multipleSpaces = PatternTemplate(
        id: "multiple_spaces",
        name: "Mehrfache Leerzeichen",
        category: .whitespace,
        regex: #" {2,}"#,
        exampleMatch: "zu  viel  Raum",
        defaultReplacement: " "
    )

    /// Leerraum am Zeilenende (Spaces/Tabs) — Standard-Ersetzung leert ihn
    /// (klassisches „trailing whitespace" aufräumen).
    public static let trailingWhitespace = PatternTemplate(
        id: "trailing_whitespace",
        name: "Leerraum am Zeilenende",
        category: .whitespace,
        regex: #"[ \t]+$"#,
        exampleMatch: "Zeile mit Rest   ",
        defaultReplacement: ""
    )

    /// Einrückung am Zeilenanfang (Spaces/Tabs) — Standard-Ersetzung
    /// entfernt sie (Text „nach links schieben").
    public static let leadingWhitespace = PatternTemplate(
        id: "leading_whitespace",
        name: "Einrückung (Zeilenanfang)",
        category: .whitespace,
        regex: #"^[ \t]+"#,
        exampleMatch: "    eingerückt",
        defaultReplacement: ""
    )

    /// Tabulator-Zeichen.
    public static let tabs = PatternTemplate(
        id: "tabs",
        name: "Tabulatoren",
        category: .whitespace,
        regex: #"\t+"#,
        exampleMatch: "\tEinzug"
    )

    /// Leerzeile (inkl. Zeilenumbruch) — Standard-Ersetzung löscht sie.
    public static let emptyLines = PatternTemplate(
        id: "empty_lines",
        name: "Leerzeilen",
        category: .whitespace,
        regex: #"^[ \t]*\n"#,
        exampleMatch: "\n",
        defaultReplacement: ""
    )

    // MARK: - Gesamtliste

    /// Alle mitgelieferten Vorlagen, in der Reihenfolge, in der sie im
    /// Picker erscheinen sollen (gruppiert nach Kategorie). Die v1.0-
    /// Vorlagen stehen in ihrer Kategorie bewusst VOR den v1.1-Ergänzungen
    /// (Daniel: „die bestehenden gehören zu den wichtigsten").
    public static let all: [PatternTemplate] = [
        // Identifikatoren
        email, url, iban, ipv4, uuid,
        hexColor, semver, fileName,
        // Datum & Zeit
        isoDate, germanDate, time,
        isoTimestamp,
        // Text-Strukturen
        markdownLink, markdownHeading, htmlTag, codeBlock, filePath,
        htmlComment,
        // Zahlen
        integer, germanDecimal, phoneDE,
        englishDecimal, percentage, euroAmount,
        // Wörter & Zeilen
        oneWord, twoWords, lastFirstName, doubledWord, capitalizedWord,
        quotedText, germanQuotedText, parenthesizedText, wholeLine,
        // Leerraum & Aufräumen
        multipleSpaces, trailingWhitespace, leadingWhitespace, tabs, emptyLines,
    ]

    /// Vorlagen einer Kategorie. Sortierung wie in `all`.
    public static func patterns(in category: PatternCategory) -> [PatternTemplate] {
        all.filter { $0.category == category }
    }
}
