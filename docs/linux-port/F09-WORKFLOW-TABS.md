# F09: Gespeicherter Textablauf auf editierbare Tabs

Der vorhandene Ablaufeditor bietet „Ablauf auf alle Tabs …“. Nur eine geladene,
gespeicherte Definition kann den Auftrag öffnen. Das neue native GTK-Fenster hält
einen unveränderlichen Clone und zeigt Name, Schritte und alle Parameter. Eine
spätere Änderung im Definitionsfenster verändert diesen Auftrag nicht; eine
andere Definition öffnet einen neuen Auftrag. Es gibt keinen automatischen Lauf
auf Dateien. Der Umfang ist ausdrücklich der vollständige Text jedes aktuell
editierbaren Tabs dieses Fensters, unabhängig vom ausgewählten Quelltab.

Vorbild sind `TextWorkflowOpenDocumentsPlan` und der Dokumentzweig von
`TextWorkflowBatch`: vollständige Quellen, eindeutige Dokumente, Zwischenstufen,
Gesamtbudgets, alle Eingaben bis zur letzten Übernahmeprüfung sowie ein gebundener
Rücknahmebeleg. Der bestehende Linux-Ablaufkern `preview`/`apply` bleibt
unverändert. Datei-/Ordner-/Projektabläufe mit Plattenschreiben bleiben offen.

Der Reiter „Endergebnisse und Freigaben“ verwendet die gemeinsame ApprovalPane.
Eindeutige Tabnummern und vollständige gebundene RawPaths beziehungsweise ein
Ungespeichert-Hinweis unterscheiden auch gleiche Dateinamen. Jeder Tab besitzt genau einen Freigabepunkt für die vollständige Ersetzung.
Auch unveränderte Tabs bleiben sichtbar und gebunden. Die Anzeigen enthalten den
vollständigen Quelltext und das vollständig freigegebene Ergebnis; keine
gekürzte Darstellung wird als Vorschau benutzt. „Zwischenstufen“ bietet jeden
aktivierten Schritt je Dokument vollständig an, einschließlich der optionalen
Escape-Ansicht. Diese Stufen ändern die Freigaben des Endergebnisses nicht.

`BatchPreview::from_replacements` ist ein additiver Einstieg im bestehenden
Batchmodul. Er bildet bereits berechnete Ausgaben unmittelbar auf vollständige
UTF-16-Ranges ab, ohne Regex oder künstliche Suchmuster. `plan`, `validate` und
`Restoration` bleiben der einzige Apply-/Undo-Kern. Wirkungslose und nicht
freigegebene Dokumente gehören bis Apply und gemeinsamer Rücknahme weiterhin
zur identischen Gesamtbasis.

Der Host hält starke Dokumentreferenzen und bindet den gesamten Tabbestand,
Revisionen, Texte, Dirty-/Save-/Readonly-/Rich-Zustand und den gespeicherten
Snapshotbeleg. Auch übersprungene Ansichten sind als Bestand/Status gebunden.
Neu angelegte, entfernte, ausgetauschte oder inzwischen gesperrte Tabs verweigern
einen alten Auftrag. Alle vollständigen Ausgaben werden auf dem Worker erzeugt
und geprüft. Unmittelbar vor der ersten synchronen GtkBuffer-Änderung erfolgt
nochmals die gesamte Prüfung. Jeder geänderte Tab erhält eine native Undo-Aktion;
Dateien werden nicht geschrieben. Der gemeinsame Rücknahmebeleg enthält die
wirklich entstandenen Revisionen und prüft vor jeder Rücknahme erneut alle
ursprünglichen Dokumente. Ein natives Undo oder eine weitere Änderung in einem
Tab macht den gemeinsamen Beleg stale. „Gemeinsame Rücknahme verwerfen“ löst nur
diese Bindung; normale Dokumenthistorien bleiben erhalten. Nach Übernahme und Rücknahme wird
der Dirty-Zustand über den zentralen Hosthelper
`Document::update_saved_baseline_status` gegen die gespeicherte Originalbasis abgeglichen; bereits vor
dem Ablauf ungesicherte Inhalte werden nicht versehentlich als gesichert markiert.
Beim Schließen des
Werkzeugfensters endet die gemeinsame Bindung ebenfalls.

Grenzen: höchstens 128 gebundene Ansichten und 32 editierbare Eingaben; 4 MiB je
Text, zusammen 16 MiB Quellen und 16 MiB Endausgaben, 32 MiB gehaltene
Zwischenstufen. Die bestehenden fünf Sekunden pro Einzelablauf gelten weiter;
der Gesamtauftrag wird nach 15 Sekunden abgebrochen. Nicht darstellbare NUL-
Zeichen und logische Zeilen über 64 KiB sperren den ganzen Auftrag. Optionale
Escape-Stufen sind auf 16 MiB pro Seite begrenzt und melden Überschreitungen
sichtbar. Nicht erfolgreiche oder abgebrochene Rechnungen veröffentlichen
keinen Teilplan. Alle Grenzen können konservativ früher greifen; es wird nichts
still abgeschnitten.

Prüfstand 2026-11-05: Rust1.99.1, drei neue und acht vorhandene Batchtests sowie
zwei neue Host-Ressourcenprüfungen bestanden; Clippy für alle Hosttargets mit
`-D warnings` grün. Native Xvfb-Regressionen DE/EN bei 640/1100Pixeln prüfen den
sichtbaren Workflow-Button, unveränderliche Definition, vollständige Stufen,
Einzelfreigaben, Apply, gemeinsame Rücknahme, wirkungslose/nicht freigegebene und
übersprungene Eingaben. Gezielt geändert werden Dirty, Rich, Readonly, Save,
Mitgliedschaft, Revision und gespeicherte Basis; jede alte Übernahme wird
verweigert. Eine Änderung im wirkungslosen Tab sperrt das gemeinsame Undo.
Die Rücknahme macht eine saubere echte Snapshotbasis wieder clean und erhält
bereits vorher ungespeicherte Inhalte als dirty. Abbruch erhält Editorinhalte
und die synthetische Quelldatei. Bildbelege bleiben
außerhalb des Repos. Keine Desktop-/IME- oder plattformweite Releaseabnahme.


## Titlecase und expliziter Locale-Kontext

Auch der 39. Schritt `titlecase` verwendet auf allen Tabs den gemeinsamen
[Titlecase-Systemlocale-Vertrag](F09-TITLECASE.md). Der GTK-Thread liest vor der
Rechnung den bestehenden `operations::titlecase_locale`-Helper. Derselbe
unveränderliche Snapshot wird an `preview_with_locale` für jeden Tab übergeben;
`Preview::locale()` bindet ihn an jede vollständige Vorschau. Die Definition
bleibt eine unveränderliche Kopie und bekommt kein neues JSON-Feld.

Die vollständige Locale-ID erscheint im Status des Auftrags, in jeder
Endergebnis-Auswahl und bei jeder vollständig dargestellten Zwischenstufe.
Vor Apply wird der aktuelle GTK-LC_CTYPE-Kontext erneut geprüft und an
`apply_with_locale` übergeben. Eine Änderung während der Vorschau- oder
Apply-Rechnung sperrt auch deren späten GTK-Abschluss. Der bestehende periodische
Stale-Wächter entfernt alte Freigaben ebenfalls bei geändertem Kontext.
Andere Schrittarten benötigen weiterhin keinen Locale-Kontext.

Das gemeinsame Undo stellt gebundene Texte wieder her und berechnet kein
Titlecase neu. Es funktioniert deshalb auch nach einem Locale-Wechsel, solange
alle bestehenden Dokument-/Dirty-/Dateibindungen unverändert passen. Eine zuvor
saubere Snapshotbasis wird wieder sauber; vorher ungesicherte Inhalte bleiben
ungesichert. Keine Datei wird geschrieben.

Gezielte echte XTest-Läufe prüfen Türkisch `tr_TR` und
`C.UTF-8`/`en_US_POSIX` mit deutscher sowie englischer Oberfläche. Geprüft sind
mehrere Tabs, vollständige Zwischenstufen und Endergebnisse, die sichtbare ID,
native Übernahme, gemeinsame Rücknahme samt Dirty-Erhalt, Kontextwechsel vor
Apply, während der Vorschau und zwischen Apply-Worker und GTK-Übernahme.
Die acht betroffenen Ansichten bei 760/1280 Pixeln wurden visuell geprüft.
Der vollständige bisherige Mehrtab-GUI-Test und die beiden bestehenden
Host-Ressourcen-/Cancel-Prüfungen bleiben grün. Native macOS-Paritätsabnahme
und systemweite Locale-Umschaltung gehören nicht zu diesem isolierten Test.
