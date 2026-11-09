# F09: reine Textoperationen begonnen

Stand: 2026-11-04. `fastra_core::text_operations` ergänzt einen ersten
zusammenhängenden Satz reiner Textbefehle. Keine GUI, Dateizugriffe oder
Produktpfad-Umschaltung. Bestehende Such- und Vorschau-Signaturen bleiben
unverändert. Die Linux-Anbindung über das native Textmenü ist inzwischen in
[F12-MARKDOWN](F12-MARKDOWN.md) mit den zugehörigen Editorprüfungen beschrieben;
eine Textoperations-API über UniFFI ist weiterhin offen.

## Umgesetzter Vertrag

`transform_lines` nimmt Text, UTF-16-Auswahl, Operation, Core-Grenzen und
Cancellation an. Eine leere Auswahl meint das gesamte Dokument; eine echte
Auswahl wird auf die berührten Zeilen erweitert. Der letzte Trenner des
Auswahlblocks bleibt außerhalb des ersetzten Bereichs. Ein Auswahlende am
Anfang der nächsten Zeile nimmt diese nicht mit. `TextResult` enthält den
vollständigen neuen Text, den ersetzten Bereich im alten Text und die Anzahl
verbleibender Inhaltszeilen; `None` ist eine wirkungslose Operation.

Implementiert:

- Sortieren: stabile ICU-Root-Kollation mit auf-/absteigender Richtung,
  numerischem Vergleich und optionaler Groß-/Kleinschreibung.
- Duplikate: erstes Vorkommen behalten, nur mehrfach vorkommende Zeilen je
  einmal behalten oder alle mehrfach vorkommenden Zeilen entfernen.
  Gleichheit ist wie bei Swift kanonisch äquivalent; erhalten bleibt die
  ursprüngliche Bytefolge des ersten Vorkommens.
- Zeilen umkehren; leere/Whitespace-Zeilen entfernen; nachgestellte ASCII-Spaces
  und Tabs entfernen; Präfix/Suffix; mit frei gewähltem Trenner verbinden.
- Relative rechtsbündige Zeilennummern ab 1 ergänzen und Nummern nach
  `^ *[0-9]+ ?` entfernen.
- Ganze Zeilen nach ICU-Regex behalten oder löschen, optional case-insensitiv.
  Ein leerer Filter ist wirkungslos; ungültige Regex liefern strukturierte
  Core-Fehler. Filter und die beiden selektiven Duplikatmodi liefern bei leerer
  Ergebnismenge `None`, wie die bestehenden Swift-Befehle.

LF, CRLF und CR werden zerlegt. Wie im bestehenden Swift-Code gilt bei erneutem
Zusammenbau CRLF vor CR vor LF, wenn das ganze Dokument mehrere Arten enthält.
Das ist keine individuelle Erhaltung jedes Trenners in gemischten Dateien.
Ein abschließender Dokument-Trenner zählt nicht als zusätzliche Inhaltszeile;
Verbindungsbefehle entfernen ihn bewusst wie die Swift-Vorlage.

`transform_characters` arbeitet auf der exakten Auswahl oder dem ganzen
Dokument. Es bietet Root-Unicode-Groß-/Kleinschreibung, Unicode-Zs-Spaces zu
ASCII-Space, Entfernen von C0/DEL außer Tab/LF/CR sowie NFC/NFD. Normalisierung
weitet angeschnittene Grapheme vollständig aus und prüft echte Byteänderungen.
Andere Operationen weisen eine Auswahl mitten im Surrogatpaar kontrolliert ab.

Die bestehenden Core-Grenzen begrenzen Text, Ausgabe und Inhaltszeilen.
Zeilen werden schon während des Zerlegens gezählt, damit viele kurze Zeilen
nicht erst unbegrenzt Hilfsobjekte erzeugen. Sortierschlüssel sind zusätzlich
aggregiert begrenzt. Abbruch wird zwischen Arbeitsschritten geprüft und erreicht
bei Filtern auch den laufenden ICU-Match. Ergebnisse werden erst vollständig
zurückgegeben, nie als teilweise ausgeführter Plan. ICU-Normalisierung und
Kollation bleiben hinter der vorhandenen C-Schicht; keine neuen Cargo-Pakete.

## Prüfung

**37 tatsächliche Swift-Referenzvektoren** wurden mit Swift 6.2.1/Foundation in
einem isolierten Linux-Container aus den unveränderten Produktmodulen
`LineOperations.swift`, `TextOperations.swift` und `LineFilter.swift` erzeugt.
Der kleine Referenztreiber enthält ausschließlich Ersatztypen für unbenutzte
Lokalisierungs-/Einrückungsoberflächen. Erwartungswerte sind keine vom Rust-Port
selbst berechneten Ausgaben. Erhalten sind Treiber und JSON unter
`crates/fastra-core/tests/fixtures/`.

Die Referenz prüft Ausgabebytes, ersetzten UTF-16-Bereich und Zeilenzahl für
Unicode, kanonische Duplikate, echte/Phantom-Leerzeilen, Auswahlgrenzen, LF/CRLF/CR,
gemischte Trenner, Nummernspalten und vollständige Normalisierungs-Grapheme.
Zusätzliche explizite Vektoren prüfen Sortieroptionen, Surrogatfehler,
Root-Casing, Größen-/Zeilengrenzen, Abbruch und Regex-Fehler.

Ausgeführt: **11 F09-Rust-Tests bestanden**, einschließlich aller 37 Referenzfälle.
Die vollständige isolierte Workspace-Suite und Clippy mit `-D warnings` sind grün.
Dies ist keine native Mac-Abnahme. Reproduktion der Swift-JSON-Datei vom Root:

```sh
swiftc -parse-as-library app/Sources/Fastra/LineOperations.swift \
  app/Sources/Fastra/TextOperations.swift app/Sources/Fastra/LineFilter.swift \
  crates/fastra-core/tests/fixtures/text-reference.swift -o /tmp/fastra-text-reference
/tmp/fastra-text-reference
cargo test --locked --workspace --all-features
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
```

## Bewusste Grenzen und verbleibende Arbeit

Die [lokalisierte Groß-/Kleinschreibung](F09-TITLECASE.md) verwendet inzwischen denselben expliziten Kontext wie Titlecase; die ursprünglichen Root-APIs bleiben erhalten.

Die [stabile localegebundene Sortierung](F09-LOCALIZED-SORT.md) ersetzt ab
1.186.0 nach ausdrücklicher Produktentscheidung die sichtbare Linux-Root-Sortierung.
Sie verspricht keine Finder-Gleichheit; die bisherigen Root-APIs bleiben erhalten.

Die folgenden ursprünglichen Restpunkte sind über die [fortgeschriebene Matrix](F00-MATRIX.md) und ihre Folgebelege einzuordnen: Entab/Detab,
Einrückungsbefehle, Hard Wrap, Transpose, Quote-/Escape-Transformationen,
Diakritika-Faltung, Emoji-Präsentation, 4D-Transformationen und gespeicherte
Textabläufe. Zeilenbereichsverhalten bei Unicode-Absatz-/Zeilentrennern außerhalb
LF/CRLF/CR ist nicht abgenommen. Native macOS-Referenzen, Host-Vorschau/Freigabe,
Undo und Bündelprüfung bleiben erforderlich. F09 ist damit begonnen, nicht als
ganze Produktfunktionsgruppe abgeschlossen.

## Fortsetzung: gespeicherte Definitionen

Die erste native Anbindung gespeicherter Textabläufe und Textbausteine für das
aktive Dokument beziehungsweise eine einzelne Auswahl steht unter
[F09-WORKFLOWS](F09-WORKFLOWS.md). Sie ergänzt vollständige Zwischen-/Endvorschauen,
ein gemeinsames Undo und die explizite exakte Zeichenansicht. Die oben genannten
weiteren Befehle und die All-Tabs-/Ordneranbindung bleiben eigene noch ausstehende
Teile; dies erklärt F09 nicht insgesamt für abgeschlossen. Die native
Suchvorlagenverwaltung steht unter [F09-PATTERNS](F09-PATTERNS.md).
