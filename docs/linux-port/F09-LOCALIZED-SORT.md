# F09: stabile Sortierung nach Textlocale

Ab 1.186.0 verwenden die sichtbaren Linux-Sortierbefehle und die bestehenden
Ablaufschritte `sortAscending`/`sortDescending` einen ausdrücklich erfassten
Textlocale-Snapshot. Diese Produktentscheidung ersetzt die bisher sichtbare
Root-Sortierung, behauptet aber keine identische Finder-/Mac-Reihenfolge.

## Vertrag

ICU 78.3 arbeitet mit Locale-Tailoring, numerischer Kollation, Normalisierung,
tertiärer Stärke, ausgeschaltetem zusätzlichem Case-Level, Kleinbuchstaben zuerst
und beachteten Satzzeichen. Gleiche Sortierschlüssel behalten ihre ursprüngliche
Reihenfolge in beiden Richtungen. Das gilt auch für numerisch gleiche Werte mit
führenden Nullen und kanonisch gleichwertige Unicode-Schreibweisen. Die
Dokumentbytes werden dabei weder normalisiert noch anderweitig umgeschrieben.

`sort_lines_with_locale` ist eine additive Core-API. `RootSortOptions`,
`LineOperation::SortRoot` und `transform_lines` behalten ihre deterministische
Root-Semantik. Auch die reine Workflow-API ohne Locale behält Root-Sortierung.
Bestehende JSON-Definitionen benötigen kein zusätzliches Feld; die produktiven
Hosts übergeben ihren Kontext ausdrücklich.

Der Kontext verwendet dieselbe erfasste `LC_CTYPE`-ID wie die
[Case-Operationen](F09-TITLECASE.md), keine implizite ICU-Defaultlocale und keine
von der Oberflächensprache abgeleitete Locale. Einzel-, Mehrtab- und Dateiabläufe
binden Berechnung, vollständige Schritt-/Endvorschau und Apply an denselben
Snapshot. Das gilt auch für wirkungslose Ergebnisse. Ein späterer Localewechsel
verweigert eine alte Completion oder Übernahme. Die vorhandenen Dokument-,
Revisions-, Auswahl-, Pane- und Eigentümerprüfungen bleiben bestehen.

Textmenübefehle wirken auf die tatsächliche letzte Quellansicht. Zeilenbefehle
weiten eine Auswahl auf ganze berührte Zeilen aus; eine leere Auswahl meint das
Dokument. Limits, Abbruch und ein gemeinsames Undo bleiben erhalten. Die
Workflow-Ausführung erhält weiterhin die positionsbezogenen Zeilentrenner,
auch bei gemischtem LF/CRLF.

## Prüfung und Grenze

Der Vertragskorpus prüft sechs Locales in beiden Richtungen, numerische und
kanonische Gleichstände, Case, Satzzeichen, UTF-16-Auswahl, CRLF, Limits, Abbruch,
No-op, unveränderte Root-APIs und stale Workflow-Übernahmen. Native Menü- und
Workflowbelege gehören zur zugehörigen Paketabnahme; reine Coretests allein
belegen keine bedienbare Oberfläche.

Die Mac-App verwendet weiter Foundation `localizedStandardCompare`. Dessen
[Vertrag](https://developer.apple.com/documentation/foundation/nsstring/localizedstandardcompare(_:))
ist locale- und systemabhängig. Die Linux-Entscheidung ist ausdrücklich eine
stabile ICU-Ordnung; die [Kollationsattribute](https://unicode-org.github.io/icu/userguide/collation/customization/)
sind festgelegt und werden bei künftigen ICU-Wechseln erneut geprüft.
