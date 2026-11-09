# F09: Suchvorlagen unter Linux

Stand: 2026-11-05. Dieses Teilpaket ergänzt das bestehende Suchformular um eine
native Vorlagenverwaltung. Die Vorlage füllt ausschließlich das Fenster, aus dem
sie geöffnet wurde. Eine Formularfüllung verändert weder Dokumenttext noch Dateien
und löst keine Suche aus. Eine neue Vorschau und Freigabe bleiben erforderlich.

## Vorhandenes Produktformat

Grundlage sind `Patterns/Pattern.swift`, `BuiltInPatterns.swift`,
`PatternLibrary.swift`, `PatternEditorView.swift` und die Formularfüllung in
`FloatingSearchDialog.applyTemplate`. Die 38 mitgelieferten Definitionen wurden
mit den unveränderten Codable-Typen als JSON erzeugt und sind unveränderlich
gebündelt. Englische Anzeigenamen und alle Bedienelemente sind lokalisiert;
originale Kategorie-Rohwerte und Capture-Beschriftungen bleiben Daten des Formats.

Das Import-/Exportformat ist ein nacktes JSON-Array, kein neuer Umschlag:
`id`, `name`, `category`, `regex`, `exampleMatch`, `groupLabels` und das optionale
`defaultReplacement`. Die sechs deutschen Kategorie-Rohwerte bleiben unverändert.
Fehlender oder `null`-Ersetzungsvorschlag wird als fehlendes Feld exportiert;
ein vorhandener leerer Vorschlag bleibt ausdrücklich leer. JSON-Formatierung und
Schlüsselreihenfolge werden neu erzeugt. Zusatzfelder und präzise große JSON-Zahlen
bleiben erhalten. Unbekannte Kategorien oder Zusatzfelder sperren die Formularfüllung
sichtbar, statt unbekannte Semantik zu ignorieren. Die JSON-Ansicht zeigt die volle
Definition. Steuerzeichen in Auswahlnamen werden für die einzeilige Anzeige
kenntlich gemacht; gespeicherte Namen bleiben unverändert.

Import prüft das ganze Array, einschließlich Regex-Kompilierung, bevor eine Sammlung
übernommen werden kann. Anders als der Mac-Importer überspringt dieser Teilstand
keine ungültigen Einträge. Leere/reservierte oder doppelte IDs, fehlerhafte Regex,
U+0000 in verarbeiteten Textfeldern und überschrittene Grenzen weisen den gesamten
Import zurück. Vor dem Speichern zeigt ein eigener Dialog die vollständige
resultierende Sammlung und die Anzahl ersetzter bestehender IDs. Gleiche IDs werden
wie bei der vorhandenen Mac-Bibliothek ersetzt; andere IDs bleiben erhalten.
Die Importdatei wird nie geändert.

## Bedienung und Bindung

„Suchvorlagen …“ ist direkt neben dem Suchbereich erreichbar. Mitgelieferte Vorlagen
können dupliziert werden. Eigene Definitionen unterstützen Neu aus Suchformular,
Duplizieren, Bearbeiten, Speichern, Löschen mit Bestätigung, Entwurf verwerfen und
Neu laden. Mehrzeilige Muster, Ersetzungen und Beispiele liegen in nativen
Textfeldern; Capture-Beschriftungen werden als JSON-Stringarray bearbeitet.
Ungesicherte Entwürfe werden auch beim Schließen des Hauptfensters geschützt.

„Suchformular füllen“ setzt das Regex-Muster und den Regex-Modus. Nur ein vorhandener
Ersetzungsvorschlag ersetzt das aktuelle Ersetzungsfeld; ohne Vorschlag bleibt es
erhalten. Bereich, Groß-/Kleinschreibung und Whole Word bleiben erhalten.
Vorhandene Freigaben werden sofort ungültig. Auch nach asynchroner Validierung wird
die Suchgeneration geprüft: Eine inzwischen geänderte Eingabe oder ein Tabwechsel
verhindert die verspätete Formularfüllung. Eine ungesicherte Definition kann das
Formular füllen, wird dadurch aber nicht automatisch gespeichert.

## Private Speicherung und Grenzen

Eigene Vorlagen liegen unter `$XDG_CONFIG_HOME/fastra-patterns` beziehungsweise
`$HOME/.config/fastra-patterns`. Die interne Byteablage wird mit den Workflows geteilt;
deren öffentliche Store-API und bestehende Dateiformate bleiben unverändert.
Die Sammlungen liegen in getrennten Verzeichnissen. Gehaltene Verzeichnisdeskriptoren,
0700/0600, Eigentümer-/Dateityp-/Symlink-/Hardlink-Prüfung, eine nicht blockierende
Sperre, Vergleich des erwarteten Byte-Stands, atomarer Austausch und fsync schützen
vor verlorenen Änderungen. Eine beschädigte Sammlung wird nicht als leer behandelt.
Eine veraltete geladene Sammlung überschreibt keine fremde Änderung.

Export umfasst ausschließlich die geladene gespeicherte eigene Sammlung. Er nutzt
`fastra_io::Transaction::save_new_document`, erzeugt eine neue Datei und überschreibt
kein vorhandenes Ziel. Ungesicherte Entwürfe müssen vorher gespeichert oder verworfen
werden. Store- und Export-Schreibvorgänge haben keinen vorgetäuschten Abbruch;
lesende Vorbereitung und Validierung können abgebrochen werden.

Grenzen: UTF-8-JSON bis 1 MiB, 100 eigene Vorlagen, 16 KiB je Regex/Ersetzung/Beispiel,
512 UTF-8-Bytes je Name, 256 je ID und 64 Capture-Beschriftungen mit je 1 KiB.
Die bestehende begrenzte Core-Regex-Kompilierung wird verwendet. Vollständige
JSON-Ansichten müssen zusätzlich die gemeinsame 64-KiB-Zeilengrenze erfüllen;
sonst bleibt der Import gesperrt. Es gibt keine gekürzte freigabefähige Importansicht.

## Belege und verbleibende Grenzen

Die Fixtures `swift-patterns.json`, `swift-pattern-vectors.json` und die gebündelten
Definitionen entstanden mit Swift 6.2.1/Foundation aus den Originaltypen.
Die 38 Vektoren prüfen tatsächliche UTF-16-Trefferbereiche, Capture-Anzahl und
Ersetzungsresultate; Aufräumbeispiele dürfen bewusst nur Teilbereiche treffen.
Dies ist keine native macOS-Abnahme.

Fünf Backendtests decken die Swift-Formate/-Vektoren, ganze Importvalidierung,
präzise Zusatzfelder, getrennte private Stores, veraltete Speicherstände und
beschädigte beziehungsweise verlinkte Dateien ab. Die elf bestehenden Workflowtests
und der vollständige Workflow-/Snippet-GTK-Lauf bleiben grün. Der native
`FASTRA_PATTERN_SELFTEST` läuft mit privaten Xvfb-/D-Bus-/XDG-Verzeichnissen und prüft
über echte Maus-/Tastaturereignisse Importfreigabe, Export, Formularfüllung,
Generation, Duplizieren, Speichern, Neu/Verwerfen/Neu laden, Entwurfsschutz und
unbekannte Angaben. Deutsch/Englisch sowie Mindestbreite/breit wurden visuell geprüft.

```sh
cargo test --locked -p fastra-workflow
cargo clippy --locked -p fastra-workflow -p fastra-linux --all-targets -- -D warnings
# DISPLAY auf ein eigenes Xvfb und FASTRA_UI_TEST_ROOT auf ein privates
# Btrfs-/ext4-Verzeichnis setzen; der Runner isoliert D-Bus und XDG:
FASTRA_ISOLATED_DISPLAY=1 linux/test.sh patterns
```

Beispielpaare als neue Wildcard-Transformation abzuleiten ist separat unter
[Transformation per Beispiel](F08-EXAMPLE.md) beschrieben. Vorlagen steuern bestehende Suchbereiche über deren Formular; es gibt keine
zweite Ordner-, Mehrdatei- oder Dateischreibengine. Native Mint-/Wayland-Abnahme
steht weiterhin aus. Der verwendete private Ubuntu-Testcontainer besitzt keinen
Emoji-Fallbackfont; der Test prüft die erhaltenen Emoji-Codepunkte und Bereiche,
seine Aufnahmen zeigen dort deshalb einen fehlenden Glyphen.
