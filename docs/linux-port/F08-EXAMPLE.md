# F08/F09: Transformation per Beispiel

Das native Werkzeug unter „Werkzeuge → Transformation per Beispiel …“ übernimmt
die bestehende `ExampleTransformation` aus `Patterns/PatternLibrary.swift`; es ist
von den Regex-Groß-/Kleinschreiboperatoren in `CaseTemplate` unabhängig.

`fastra_core::example_transformation::infer` bildet die längste gemeinsame
Teilzeichenfolge über ICU-Grapheme und kanonische Character-Gleichheit ab. Nur ein
strikt längerer Treffer gewinnt, entsprechend der Quell-/Ziel-Reihenfolge der
Swift-Matrix. Die ersten kanonisch passenden Bereiche liefern Vor-/Nachtexte aus
den Originalbytes. Quellen werden nicht normalisiert; NFC dient ausschließlich
dem Vergleich. Der native Mac-Referenzlauf ist maßgeblich, auch für den ersten
Treffer vor einer nach einem Zeilenumbruch folgenden kombinierenden Marke.

Leer, kanonisch gleich, Sternchen, mehr als 512 Grapheme, mehr als 4 MiB UTF-8 und
fehlende sichere gemeinsame Bereiche sind ausdrücklich erklärt. Die zusätzliche
Bytegrenze schützt auch ein einzelnes Graphem mit sehr vielen kombinierenden
Zeichen. Speicheraufwand der längsten Teilzeichenfolge bleibt linear; die
begrenzte quadratische Rechnung läuft einschließlich Darstellung auf Workern.
Eingabewechsel brechen frühere Jobs ab; veraltete Completions werden verworfen.

Die Vorschau nutzt unverändert die echte Wildcard-Engine und zeigt Suchen,
Ersetzen und tatsächliches Ergebnis über die bestehende vollständige Escape-
Darstellung (je höchstens 64 KiB). Erst bei kanonisch gleichem Ziel ist Übernehmen
möglich. Originalbytes bleiben erhalten. Das füllt ausschließlich das gebundene
Suchformular und wählt Wildcard, ohne Bereich oder Optionen zu verändern. Es
startet weder Suche noch Editor-/Dateischreibvorgang. Eine bestehende Vorschau
wird entwertet; die reguläre Vorschau/Freigabe bleibt erforderlich. Geänderte
Formulargeneration, aktiver Tab oder geschlossenes Besitzerfenster sperren die
Übernahme. Return übernimmt, Escape verwirft; Shift+Return ermöglicht Beispiele
mit Umbrüchen.

## Belegter Sonderfall im Bestand

Original-Swift liefert für `before α\nβ` → `α\nβ after` die Muster `before *`
und `* after`. Ein einzelner `*` erfasst laut Produktvertrag keine Umbrüche.
Deshalb kann die tatsächliche Wildcard-Vorschau dieses Ziel nicht erzeugen. Das
Werkzeug zeigt die originale Ableitung und die tatsächliche Ausgabe, erklärt die
Abweichung und sperrt die Formularübernahme. Es wandelt den Platzhalter nicht
still in `**` um. Dieser Schutz verändert die reine Inference nicht und ist
keine Behauptung einer entsprechenden macOS-UI-Korrektur.

Ein weiterer Bestandsfall ist `foo` → `$1foo`: Die ursprüngliche Ableitung
`*` → `$1*` erzeugt wegen des gültigen Wildcard-Backrefs tatsächlich `foofoo`.
Auch hier bleiben Ableitung und tatsächliche Ausgabe sichtbar, während die
Übernahme gesperrt ist. Ein literales `$1` innerhalb des Captures wird dagegen
unverändert übernommen, weil Captureinhalte nicht erneut expandiert werden.

## Referenzen und Prüfung

`tools/linux-probes/example-transformation/reference.py` baut einen eigenständig
ausführbaren Swift-Referenzlauf aus dem unveränderten Originalenum. Der Korpus
`crates/fastra-core/tests/fixtures/example-transformation-swift.json` enthält
122 tatsächlich mit Apple Swift 6.3.3/Foundation auf macOS 26 ausgeführte Paare:
NFC/NFD, Emoji-ZWJ, Tie-Breaks, erste Fundstelle, CRLF/CR/LF und angrenzende
Extend-, SpacingMark- und ZWJ-Zeichen sowie 512/513-Grenzen. Alle abgeleiteten
Muster werden bytegenau gegen Rust geprüft. Der vorherige Corelibs-Foundation-
Lauf mit Swift 6.2.1 unterschied sich in 18 Fällen: Er verweigerte Bereiche vor
Extend-Marken, die das originale Mac-Programm zulässt. Seit 1.165.1 gilt der
echte Mac-Korpus. Die tatsächliche Mint-/Wayland-UI-Abnahme bleibt separat offen.

Backendtests prüfen außerdem tatsächliche Wildcardausgabe, literales `$` und
Backslash, Capturebytes bei kanonisch äquivalentem Ziel, Multiline-Sperre und
Abbruch. Der native Test `FASTRA_EXAMPLE_SELFTEST=1` betätigt Tools-Einstieg,
Übernehmen, Return und Escape mit echten XTest-Ereignissen und prüft veraltetes
Formular sowie unveränderte Dokumente und Optionen. Deutsch/Englisch jeweils bei
560 und 1080 Pixeln prüfen und die Aufnahmen ansehen.
