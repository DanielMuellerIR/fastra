# Begrenzte XPath-Quellnavigation im Linux-Host

## Bedienung und Bindung

„Werkzeuge → XPath-Navigation“ öffnet ein natives GTK-Fenster für den aktuellen
editierbaren Quelltab. „XML neu prüfen“ baut im Hintergrund einen unveränderlichen
Index; „XPath auswerten“ und Return berechnen die aktuelle Query. Eine Änderung
der Eingabe bricht eine laufende Auswertung ab und startet danach die aktuelle
Eingabe. Maximal ein Parser und eine Auswertung laufen je Fenster gleichzeitig.
Ein Abbruch hält weitere Parserstarts gesperrt, bis die begrenzte alte Phase endet.

Trefferbuttons markieren nur den originalen Quellbereich. Voriger/Nächster Treffer,
Vorschläge und Seiten mit je 100 Einträgen sind sichtbar erreichbar. Es gibt keine
Dateisuche, Dateiöffnung, Dateischreibvorgänge oder Textänderung. Das ursprüngliche
Dokumentobjekt, aktive Tab, Quellrevision, Rich-/Readonly-Sperre und die konkrete
Ergebnisgeneration müssen vor jedem Sprung noch passen. Ein verspäteter alter
Trefferknopf darf nach Neuaufbau nicht auf neue Treffer desselben Listenindex
wirken. Gleiches gilt für Vorschläge und ihre Eingabebasis. Ein Quellwechsel
entfernt alte Bereiche sofort; ein expliziter Neuaufbau ist erforderlich.

## Teilmenge aus dem bestehenden Swift-Code

Referenz sind [XPathSupport.swift](../../app/Sources/Fastra/XPathSupport.swift)
und [XPathSupportTests.swift](../../app/Tests/FastraTests/XPathSupportTests.swift).
Enthalten sind `/`, `//`, `*`, positive `[n]`, `[@attr]`, `[@attr='wert']`, terminales
`@attr` und `text()`. Relative Einstiege wirken wie `//`. Positionen zählen je
Elternkontext, Prädikate werden in Eingabereihenfolge angewendet. Überlappende
Descendant-Kontexte werden vor ihrer weiteren Traversierung dedupliziert; die
Ausgabe bleibt in Dokumentreihenfolge.

Namen und Präfixe folgen der lexikalischen Quellschreibweise, ohne XPath-Namespace-
Engine. Groß-/Kleinschreibung bleibt relevant. Wie bei Swift-Stringgleichheit gelten
kanonisch äquivalente Unicode-Schreibweisen als gleich. NFC-Vergleichsschlüssel
werden einmal gecacht; die Quelle und ihre Positionen werden nie normalisiert.
Attribute verwenden die fünf XML-Entities und numerische Zeichenreferenzen. Die
rohen CRLF-/Tabzeichen eines Attributwerts bleiben wie im Swift-Scanner erhalten;
XML-Whitespace-Normalisierung würde hier andere Prädikatsergebnisse erzeugen.
Namespace-Deklarationen bleiben als lexikalische Attribute auffindbar.

`text()` wählt ausschließlich die erste nichtleere direkte physische Text-/CDATA-
Stelle; Kindtext wird nicht zum Elterntext zusammengezogen. Der originale Inhalt
von Entity-Schreibweisen bleibt als Sprungbereich erhalten. Kommentare und PI sind
keine Ziele. Achsen, Funktionen wie `count`/`last`, boolesche Prädikate, Unionen
und andere nicht dokumentierte Konstrukte werden sichtbar verweigert. Quotes in
einem Literal dürfen keine nicht unterstützte Prädikatlogik verdecken.

## Validator und Quellpositionen

Der vorhandene, exakt gepinnte `roxmltree = 0.21.1` ist alleiniger Struktur- und
Namensvalidator. Ein kleiner vorgeschalteter Sicherheitslauf erkennt nur
quote-/Kommentar-/CDATA-/PI-bewusste Taggrenzen und Ressourcenlimits; er baut keinen
Baum und implementiert keine zweite XML-/Namespace-Engine. Ein gebundener
Range-Adapter rekonstruiert danach ausschließlich Name-, Attribut- und erste
Textspannen an bereits validierten Knoten. Dies ist nötig, weil roxmltree
Namespace-Attribute nicht als normale Attribute liefert und benachbarte
Text-/CDATA-Stellen zusammenführt.

`SourceMap` hält skalare Checkpoints alle 256 Zeichen. Byte-, GTK-Unicode-Skalar-
und UTF-16-Bereiche bleiben auf der unveränderten UTF-8-Quellfassung gebunden;
CRLF zählt für absolute Offsets vollständig und als ein Zeilenende. Jede spätere
Offsetabbildung benötigt eine binäre Checkpointsuche und höchstens 256 Skalare.
Index und Traversierung sind iterativ; Arbeit und Sortierung werden budgetiert.

## Grenzen und bewusste Abweichungen

- 4 MiB UTF-8-Quelle, 100.000 Parserknoten und separat 100.000 Attribute.
- Maximal 32 Elementebenen, 128 Attribute und 8 KiB je Starttag.
- Query maximal 4 KiB, 128 Schritte und 128 Prädikate; begrenzte Auswertungsarbeit.
- Höchstens 10.000 vollständige Treffer; 100 sichtbare Einträge pro Seite und
  acht Vorschläge. Ein Grenzfehler liefert keine scheinbar vollständige Teilliste.
- DTD einschließlich leerer und externer Deklarationen wird gesperrt.
  Es gibt keinen Entity-Resolver und keinen Datei-/Netzzugriff.

Der rekursive Bibliotheksparser besitzt keinen Cancellation-Hook. Seine Phase ist
vorher hart begrenzt; Cancellation greift davor/danach sowie während Sicherheits-
prüfung, Index, Offsetaufbau und Auswertung. Eine sofortige Unterbrechung innerhalb
des Parseraufrufs wird nicht behauptet. Ein belegter Stackoverflow bei größerer
zulässiger Tiefe erforderte die konservative Grenze 32; höhere/tiefe Referenzfälle
werden vor dem Parser abgewiesen. Die früh erprobte pauschale 8-KiB-Textregions-
grenze konnte nach der gezielten Vorprüfung entfallen; lange reine Textstellen
bleiben erlaubt.

Dies ist keine vollständige XPath-/XML-Parität. Der neue XML-Validator verlangt
z. B. korrekte Namespace-Deklarationen. Der alte Swift-Scanner überspringt gewisse
DTD-Deklarationen und lehnt bestimmte NFD-Namen ab, die ein XML-Parser akzeptiert.
Nicht dokumentierte boolesche Syntax wird bewusst verweigert, auch wenn der alte
Parser Teile davon versehentlich als Literal behandeln konnte. Es gibt keinen
LSP, keine XML-Schema-/DTD-Validierung und keine XML-Änderungsfunktion.

## Prüfbelege

Der originale reine Swift-Code lief unverändert mit einem L10n-Stub in der
vorhandenen Swift-6.2.1-Linuxumgebung. Elf erfolgreiche Referenzvektoren mit
konkreten UTF-16-Bereichen werden aus einer kleinen Fixture automatisch gegen den
Rust-Kern geprüft. Ein zwölfter Fall hält die abweichende NFD-XML-Validierung fest.
Weitere explizite Swift-Vektoren prüfen Reihenfolge der Prädikate, Elternpositionen,
QNames, Entity-/Whitespace-Verhalten, CDATA, Autocomplete sowie 5.000 Einträge.

Die gezielte Sicherheitsprüfung enthält tatsächliche Tiefe 32, Vorabverweigerung
von 12.000 Ebenen, falsche Tags in Quotes/Kommentaren/CDATA/PI, Starttag-/Attribut-
limits, DTD/XXE, Ergebnis-/Arbeitsgrenzen und Cancellation ohne Teilergebnisse.
Ein adversarialer flacher Fall mit 120.000 Attributen und 974.007 Bytes endete im
Debuglauf nach rund 622 ms kontrolliert am aggregierten Attributlimit; ein
12.005-Byte-Tag wurde vor dem Parser in rund 10 µs verweigert. Diese Stichprobe ist
kein allgemeines Laufzeitversprechen unter Fremdlast.

Am 2026-11-05 bestanden 13 gezielte XPath-Prüfungen sowie insgesamt 65 Core- und
30 Hostprüfungen; ein gesonderter nativer Viewer-Test blieb ausdrücklich
ausgenommen. Clippy aller Targets mit `-D warnings`, Debugbuild, Releasecheck und
Formatprüfung bestanden. Vier echte GTK-/WebKit-Läufe DE/EN bei 640/1080 Pixeln
prüften den tatsächlichen Werkzeugeintrag, Unicode-/CRLF-/CDATA-Selektion, einen
fremden Tab mit gleicher Revision, Sourceänderung, verspäteten alten Trefferknopf,
Unsupported-Syntax, Abbruch und Rich-Sperre. Die 205-Treffer-Probe zeigte maximal
100 Zeilen pro Seite und navigierte exakt zum zweiten Seitenanfang. Treffer-,
Fehler- und Seitenansichten wurden in allen vier Varianten visuell geprüft.
Alle Daten, XDG-Profile und Xvfb-/DBus-Sitzungen waren privat und synthetisch.

Der letzte native Lauf verweigerte auch den automatischen Neustart einer beim
Abbruch bereits vorgemerkten Query. Parent-Hide schließt den XPathzustand und
bricht seine Worker ab; keine starke Fenster-/Modellschleife bleibt gehalten.
