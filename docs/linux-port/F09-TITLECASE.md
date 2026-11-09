# F09 – Wortanfänge groß mit ausdrücklicher Systemlocale

Die Linux-Textoperation und der bestehende Workflow-Kind `titlecase` verwenden
jetzt eine ausdrücklich bestimmte Text-Systemlocale. Damit sind alle 39
ursprünglichen Schrittarten im gemeinsamen Backend verfügbar. Es gibt keine
Änderung am JSON-Schema und keine zusätzliche Locale-Eigenschaft in gespeicherten
Definitionen. Ein Ablauf wird unter der beim Berechnen sichtbaren Systemlocale
ausgeführt; seine Vorschau hält diese Locale unabhängig von der Definition fest.

## Vertrag

Nach der GTK-Initialisierung liest der Host `setlocale(LC_CTYPE, NULL)` auf dem
GTK-Thread und kopiert die ID vor der Hintergrundrechnung. Er verändert die
Prozesslocale nicht. Die Zeichensatzangabe entfällt bei der ICU-ID; beispielsweise
wird `tr_TR.UTF-8` zu `tr_TR`. `C`, `C.UTF-8` und `POSIX` werden ausdrücklich als
`en_US_POSIX` angezeigt und gerechnet. Unbekannte Sprachkennungen, unzulässige
Zeichen oder fehlende IDs werden verweigert. `LANGUAGE` und `LC_MESSAGES` steuern
keine Textregeln. Auch der ICU-Default wird nicht als Casing-Locale verwendet.

Der native Menüpfad lautet **Text → Unicode → Wortanfänge groß · Systemlocale
(ID)**. Die Workflow-Schrittart heißt **Wortanfänge groß (Systemlocale)**. Die
vollständige Schritt- und Endvorschau nennt die verwendete ID. Eine andere Locale
bei späterem Worker-Abschluss oder Apply macht die Vorschau ungültig. Die normale
Revision-, Text-, Auswahl-, Definitions- und Generationsbindung bleibt bestehen.
Eine Übernahme ist ein Undo-Schritt und speichert keine Datei.

Core bietet `TitlecaseLocale::from_ctype` und `titlecase_with_locale`. Workflow
bietet die additiven APIs `preview_with_locale` und `Preview::apply_with_locale`
mit `Option<&TitlecaseLocale>` sowie `Preview::locale()`. Die bisherigen
`preview`/`apply`-APIs reichen `None` weiter: bestehende andere Schrittarten
funktionieren weiter; ein aktiviertes `titlecase` ohne expliziten Kontext wird
vollständig verweigert. Batch-Hosts müssen denselben Kontext ausdrücklich
übergeben, statt eine zweite Casing-Engine einzuführen.

## Belege und bewusste Grenze

Die Swift-Produktquelle verwendet in `TextOperations.swift` für `titlecase`
`localizedCapitalized`. Auf Swift 6.2.1/Linux blieb `Locale.current` bei den
geprüften gültigen de/en/tr/C-Prozesslocales jedoch `en_001`, selbst nachdem
`setlocale` die tatsächliche LC_CTYPE-ID gesetzt hatte. Diese Linux-Ausgabe
belegt deshalb keine türkische macOS-Systemlocale. Die Goldenfälle verwenden
stattdessen ausdrücklich `capitalized(with: Locale(identifier: ...))`.

Eine reale GTK-Probe mit getrennten Locales zeigte den erforderlichen Unterschied:
LC_CTYPE `tr_TR.UTF-8`, LC_MESSAGES/UI Englisch ergab türkisches LC_CTYPE, aber
ICU-Default `en_US`. Die falsche Default-Auswahl hätte `Istanbul` statt `İstanbul`
erzeugt. `TitlecaseLocale` hält deshalb die tatsächliche Text-ID fest.

Die Casing-Rechnung verwendet ICU 78.3 `u_strToTitle` mit expliziter Casing-Locale
und einem expliziten `en_US_POSIX`-Wortiterator. Dieser Wortiterator ist durch
Swift-Ausgaben belegt: Der Standarditerator für beispielsweise `en_US` liefert
bei `foo.bar` `Foo.bar`, Foundation liefert `Foo.Bar`. Die Wortgrenzen bleiben
somit fest bestimmt; die sprachabhängige Groß-/Kleinschreibung bleibt dynamisch.

Der eingecheckte Swift-Referenzgenerator erzeugt 217 Texte mit acht expliziten
Locales (`de_DE`, `en_US`, `tr_TR`, `C`, `en_US_POSIX`, `nl_NL`, `lt_LT`, `el_GR`).
Alle 1.736 Ergebnisse stimmen mit ICU 78.3 überein. Enthalten sind 50
Trennzeichen, gerade und typografische Apostrophe, Satzzeichen, Ziffern,
Unterstriche, kombinierende Zeichen, griechische Formen, Ligaturen, deutsches ß,
Türkisch, niederländisches IJ, Emoji, ZWJ und verschiedene Zeilenenden.
Das ist eine konkrete Referenzmatrix, kein Beleg allgemeiner Foundation-Parität.
Native macOS-Abnahme bleibt offen.

Die bestehenden Eingabe-/Ausgabelimits und Cancellation gelten weiter. Die
Workflow-Rechnung liefert bei Fehlern keine Teilvorschau; U+0000 und überlange
Zeilen werden weiterhin durch den gemeinsamen Hostschutz gesperrt.

## Geprüfte Oberfläche

Ein echter XTest-Lauf prüft den Menüpfad, türkische Casing-Regeln bei unabhängig
deutscher und englischer Oberfläche, Auswahl und ein Undo sowie den Import einer
mit bestehenden Swift-Codable-Typen exportierten Zwei-Schritt-Definition. Beide
Zwischenstände, die sichtbare Locale-ID, Übernahme/Undo und stale Input werden
geprüft. Die Workflow-Ansicht wurde in beiden Sprachen bei Mindestbreite und breit
visuell geprüft. Der bisherige Workflow-/Snippet-Selbsttest bleibt ein eigener
Kompatibilitätswächter.

Primärquellen: [GTK-Initialisierung und setlocale](https://docs.gtk.org/gtk4/func.disable_setlocale.html),
[GLib-Oberflächensprachen](https://docs.gtk.org/glib/func.get_language_names.html) und
[ICU Case Mappings](https://unicode-org.github.io/icu/userguide/transforms/casemappings.html).


## Groß-/Kleinschreibung mit demselben Kontext

Das Textmenü verwendet auch für Groß-/Kleinschreibung den frisch auf dem GTK-Thread
erfassten Snapshot. `case_with_locale` transformiert den vollständigen ausgewählten
Teilstring über die vorhandene ICU-Schicht; Kontext außerhalb der Auswahl wird
nicht übernommen. `casing` und die bisherigen Root-Character-Operationen bleiben
für Ersetzungstemplates und deterministische Core-Aufrufer erhalten.

`Step::uses_text_locale()` erfasst Titlecase, Uppercase und Lowercase zentral.
Alle drei produktiven Hosts (Einzelansicht, Mehrtabablauf, Dateiablauf) erfassen für
aktivierte Schritte zwingend eine gültige Locale oder brechen sichtbar ab.
Completion und Apply prüfen dieselbe Locale erneut. Es gibt keine neuen
JSON-Eigenschaften. Die reine bestehende Workflow-API mit `None` behält ihre
Root-Groß-/Kleinschreibung; `Some(snapshot)` rechnet lokalisiert und bleibt
streng daran gebunden. Eine solche Vorschau lässt sich nicht über `apply(None)`
oder eine andere Locale anwenden. Titlecase ohne Kontext bleibt verweigert.

Der explizite Foundation-Korpus enthält 120 Eingabe-/Locale-/Richtungsvektoren
für sechs Locales einschließlich kombinierender litauischer Zeichen und
kontextabhängigem griechischem Sigma. Er wurde mit Swift 6.2.1 offline erzeugt
und unabhängig byteidentisch regeneriert. Dies ist eine begrenzte explizite
Mappingreferenz, kein Nachweis von `Locale.current` auf einem Mac. Native Tests
prüfen jeden der drei Hosts mit tatsächlichem türkischem LC_CTYPE und
unabhängiger DE-/EN-Oberflächensprache für beide Richtungen. Grenzen bleiben
4 MiB Ein-/Ausgabe, die vollständige native Zeilenprüfung sowie Auswahl-,
Dokument-, Abbruch- und Rücknahmebindungen. Sortierung bleibt separat Root.
