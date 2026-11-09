# F09: reine 4D-Token-Transformationen

Stand: 2026-11-05. Die zwei vorhandenen Swift-Befehle sind im gemeinsamen
`fastra-core::text_operations` verfügbar und werden sowohl vom nativen Textmenü
als auch von gespeicherten Textabläufen verwendet. Es werden keine Dateien
implizit gespeichert und keine proprietäre 4D-Laufzeit gestartet.

## Vertrag

„Text → 4D → 4D-Token-Suffixe entfernen“ entfernt erkannte `:Cnnn`- und
`:Knnn`-/`:Knnn:mm`-Suffixe. „4D-Befehls-Token ergänzen (keine Konstanten)“ ergänzt
nur bekannte Befehlsnummern. Im Ablaufeditor heißt dieser Schritt kurz und
vollständig sichtbar „4D: Nur Befehle tokenisieren“. Konstantennummern werden
nicht erfunden. Vorhandene Suffixe und unbekannte Namen bleiben beim Ergänzen
unverändert. Unbekannte, aber syntaktisch erkannte Exportnamen mit Suffix lassen
sich wie im Swift-Original detokenisieren.

Strings, Zeilen-/Blockkommentare und Objektmember bleiben gemäß dem tatsächlichen
`FourDTokenizer.swift` geschützt. Tabellenfelder werden nicht allein aufgrund
eines gleichnamigen Befehls tokenisiert. Typnamen nach einem Doppelpunkt in
`var`-/`#DECLARE`-Zeilen erhalten keine Befehlsnummer. Klassifikation, längstes
bekanntes Namenspräfix, einzelne Namensleerzeichen, Unicode-Zahlen, mehrwortige
Namen und die bestehenden tolerierten beziehungsweise abgewiesenen Suffixformen
folgen der Referenz. Nicht jede beliebige Zeichenfolge `:C…` wird entfernt.

Ohne Auswahl gilt das ganze Dokument, ansonsten ausschließlich die festgehaltene
zusammenhängende UTF-16-Auswahl. Die Transformation betrachtet wie der bestehende
Swift-Adapter den ausgewählten Ausschnitt als eigenen Eingabetext. Ein nativer
Undo-Schritt stellt den ganzen Befehl zurück. Die vorhandenen Guards gegen
geänderte Quelle, Auswahl, Revision oder Generation und nicht darstellbare
Ergebnisse bleiben erhalten.

## Bewusst verweigerte Graphemgrenzen

Ein konkreter Swift-6.2.1/Linux-Foundation-Fehler darf keine fremden Zeichen
entfernen: `NSMutableString` verschiebt beim Ersetzen angefangene Graphemgrenzen.
Die tatsächliche Referenz liefert zum Beispiel:

| Quelle | Swift `detokenize` | Rust |
| --- | --- | --- |
| `ALERT:C41\u{0307} Time` | `ALERT1\u{0307} Time` | `InvalidRange`; Quelle unverändert |
| `😀\u{0345}:C41` | `\u{0345}` (Emoji verloren) | `InvalidRange`; Quelle unverändert |

Der Referenzharness kennzeichnet diese Fälle ausdrücklich mit
`detokenizeRejectedForSplitGrapheme`. Vier Detokenisierungsfälle im Korpus werden
bewusst vollständig verweigert; die originalen Swift-Ausgaben bleiben im Beleg
erhalten. Die übrigen Operationsergebnisse stimmen exakt überein. Angefangene
Grapheme an der äußeren Auswahl werden ebenfalls verweigert. Es gibt keine
Normalisierung, keine stille Ausweitung des Tokenbereichs und keine Teilübernahme.
Die deutsche und englische Oberfläche erklärt die konkrete Grenze und erhält die
Quelle sowie die vorherige Undo-Historie. Der native Test prüft anschließend ein
reales Undo der vorherigen unabhängigen Eingabe.

## Gemeinsame Lexik und bewahrte Unterschiede

`four_d::Analysis` und die Transformationen verwenden denselben String-/
Kommentar-Scanner. Die bestehende öffentliche Analysis-/Index-API bleibt erhalten.
Der Scanner besitzt zwei ausdrückliche Stringregeln: Der bisherige statische
Analysis-Vertrag maskiert mehrzeilige Strings; der tatsächliche Swift-Tokenizer
beendet ungeschlossene Strings an LF, aber nicht an CR. Escapes und Kommentare
werden nur an dieser gemeinsamen Stelle gescannt.

Die bestehende strukturelle Navigation blendet SQL-Blöcke weiterhin aus. Die
Swift-Token-Transformationen besitzen dagegen keinen SQL-Modus und können dort
erkannte 4D-Namen ebenfalls umformen. Dieses Verhalten ist ausdrücklich in den
Swift-Vergleichsdaten enthalten. Es wurde weder still korrigiert noch durch eine
zweite SQL-Engine ersetzt. Die Befehle sind keine Compiler- oder SQL-Prüfung.

Der Swift-Tokenizer klassifiziert einzelne UTF-16-Zellen. Seine Zeichenklassen
wurden für alle 63.488 gültigen BMP-Skalare mit Swift 6.2.1/Character und
Foundation ermittelt und als 631 kleine zusammenhängende Bereiche gebündelt.
So bleiben etwa griechische Combining-Zeichen, römische Zahlen und die besondere
Foundation-Whitespace-Menge erhalten. Supplementäre Skalare werden wie die
Surrogate im tatsächlichen Tokenizer nicht zu Namenszeichen. Graphemgrenzen für
die Swift-Substring-Konvertierung verwendet der vorhandene ICU-78.3-Iterator.
Eine begrenzte ICU-Regex übernimmt den bestehenden Deklarations-Keywordkontext.
Es gibt keinen Locale-Casing-Ersatz und keine zusätzliche Abhängigkeit.

## Daten und Grenzen

Der bestehende Linux-Generator leitet `four_d/catalog.tsv` aus
`FourDSymbols.swift` ab: 1.270 Befehle, 2.306 Konstanten und 1.252 bekannte
Befehlsnummern. Die 18 Befehlsnamen ohne Nummer erhalten keine erfundene Nummer.
Die unveränderlichen Fakten stammen aus der 4D-Dokumentation, © 4D SAS,
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), Quelle
[4d/docs](https://github.com/4d/docs). Attribution und die Beschreibung der
Extraktion stehen im Katalog und in `THIRD-PARTY-NOTICES.md`; Beschreibungs- und
Beispieltexte der fremden Dokumentation werden nicht übernommen.

Die Transformationen erlauben höchstens 4 MiB Quelltext und beachten das
Ausgabelimit sowie Cancel. Höchstens 100.000 normale Wort-/Phrasenkandidaten und
Deklarations-Keywordtreffer werden verarbeitet. Der bestehende Ablaufvertrag
begrenzt zusätzlich Schritte, gehaltene Zwischenstände und Rechenzeit. Bei Fehler
oder Grenze gibt es keine Teilübernahme. Lange einzelne Wortketten werden einmal
vermessen; die Präfixsuche ist durch den längsten Katalogeintrag begrenzt, statt
den gesamten verbleibenden Text für jedes Wort neu zu scannen.

Dieses Teilpaket stellte 38 von 39 ursprünglichen Schrittarten bereit. Das
anschließende [Titlecase-Paket](F09-TITLECASE.md) ergänzt den ausdrücklichen
Systemlocale-Vertrag und damit die 39. Art. Unbekannte Schritte und semantische Zusatzfelder sperren weiterhin die
Ausführung; sämtliche Definitionen bleiben im bestehenden JSON-Format erhalten.

## Referenzen und Prüfpfad

`four-d-transform-swift.json` enthält 7.200 Fälle aus den tatsächlichen
`FourDTokenizer.swift`-/`FourDTokenTransform.swift`-Funktionen, einschließlich des
gesamten generierten Katalogs und ausgewählter Ausschnitte. Das mitgelieferte dünne
Referenzprogramm liest beim Übersetzen die tatsächlichen Produktdateien; es
enthält keine Ersatzimplementierung der Transformationen:

```sh
reference_dir=$(mktemp -d)
cp crates/fastra-core/tests/fixtures/four-d-transform-reference.swift "$reference_dir/main.swift"
swiftc app/Sources/Fastra/LineOperations.swift \
  app/Sources/Fastra/FourDSymbols.swift app/Sources/Fastra/FourDTokenizer.swift \
  app/Sources/Fastra/FourDTokenTransform.swift "$reference_dir/main.swift" \
  -o "$reference_dir/oracle"
"$reference_dir/oracle" "$reference_dir/output"
python3 crates/fastra-linux/resources/generate-four-d.py \
  --character-oracle "$reference_dir/output/four-d-character-swift.json"
cargo test --locked -p fastra-core -p fastra-workflow
cargo clippy --locked -p fastra-core -p fastra-workflow -p fastra-linux --all-targets -- -D warnings
# Nur in eigenem Xvfb/D-Bus; ein temporäres Btrfs-/ext4-Verzeichnis verwenden:
FASTRA_ISOLATED_DISPLAY=1 FASTRA_UI_TEST_ROOT=/var/tmp/fastra-4d-test \
  linux/test.sh four-d-transform
```

Zusätzlich enthält ein echtes Schema-1-Archiv aus den bisherigen Codable-Typen die
beiden neuen Schritte. Seine vollständigen Zwischenstände, Auswahlbegrenzung,
Stale-Bindung und unveränderte JSON-Felder werden geprüft. Der native Test erreicht
beide Befehle über echte Text-Untermenüs, importiert den Ablauf über den nativen
Dateidialog, prüft die vollständige Vorschau und übernimmt sie mit einem Undo.
Die Mindest-/Breitansichten werden in Deutsch und Englisch im eigenen Fenster
aufgenommen. Die Referenzausführung ist Swift 6.2.1/Foundation auf Linux;
native macOS-, Mint- und Wayland-Abnahmen bleiben getrennte Produktprüfungen.
