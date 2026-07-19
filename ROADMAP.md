# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Soft Wrap, Rechteckauswahl und Einrückung** (beschlossen 2026-07-19):
  Umsetzung in vier getrennten Etappen mit eigener Verifikation und Version.
  **Umgesetzt: Etappe 1 (Formatprofile und Fußzeilen-Bedienung, v1.40.0),
  Etappe 2 (Umbruchziele und Seitenlinie, v1.41.0) und Etappe 3
  (Rechteckauswahl unter Soft Wrap, v1.42.0).** Offen bleibt Etappe 4
  (Einrückungsprofile, intelligentes Einfügen und Folgezeilen-Einrückung).
- **Wunschpaket 3** (beschlossen 2026-07-18):
  **Alle acht Etappen umgesetzt:** Etappe 1 (Diff-Kern & Datei-Diff
  dual-pane, v1.32.0), Etappe 2 (Git-Diff auf gemeinsamem Renderer,
  v1.33.0), Etappe 3 (Dateinamens-Filter in der Projektansicht,
  v1.34.0), Etappe 4 (tool4d-Ersteinrichtungshilfe, v1.35.0),
  Etappe 5 (4D-Struktur-Hinweise, v1.36.0), Etappe 6
  (4D-Vervollständigung/`.4DForm`-Schema/Export-Transformation,
  v1.37.0), Etappe 7 (Alt-Doppelklick „Gehe zum Ziel“, v1.38.0), Etappe 8
  (4D-Syntaxdiagnosen via tool4d-LSP, v1.39.0).**
  - **Bewusst NICHT in Etappe 1** (Kandidaten für eigene Aufträge):
    Ordner-Vergleich, „Apply to Left/Right“-Übernahme einzelner
    Unterschiede ins Dokument, Export der Differenzen-Liste.
  - **Bekannte Grenze des Datei-Diffs:** Nach Abzug gemeinsamer
    Anfangs-/Endzeilen verarbeitet der Vergleich bis zu 30.000 Zeilen
    Unterschiedsbereich (Myers-Diff ist im schlechtesten Fall
    quadratisch). Sehr große Dateien mit über die GANZE Länge
    verstreuten Änderungen lehnt er deshalb ehrlich ab; ein
    Anker-basierter Diff (Patience-Stil) für solche Fälle wäre ein
    möglicher späterer Ausbau.
- **Wunschpaket 2** (beschlossen 2026-07-18): Alle fünf Etappen sind mit
  v1.27.0–v1.31.0 umgesetzt (Navigation & Chrome, Suchdialog, Sprachmenü
  mit wählbarem 4D, Hilfe samt `help-audit`-Mechanik, assistiertes
  Markdown-Schreiben mit Bild-Paste/-Drop). Bewusst offen: Echtes
  WYSIWYG („Schreibmodus“) ist ausgeklammert — Daniel entscheidet nach
  gelebter Erfahrung mit Etappe 5 separat und nur auf ausdrücklichen Auftrag.
- **Wunschpaket Juli 2026** (beschlossen 2026-07-17): Die sechs Etappen sind
  mit v1.20.0–v1.25.0 umgesetzt. Bewusst offen geblieben:
  - **4D-Farbdetails:** Underline (Konstanten) kennt das CESE-Attributmodell
    nicht; `errors`/`plug_ins`/`member` aus den Farbvorgaben entfallen
    mangels Analyse bzw. Unterscheidbarkeit (siehe Slot-Mapping in
    `EditorView.swift`).

## Kleine offene Ideen

- **Hilfe später hübscher:** Die mitgelieferte Hilfe (Etappe 4 Wunschpaket
  2026-07b) ist bewusst reiner Text ohne Bilder. Screenshots/Illustrationen
  der zentralen Abläufe (Suchmaske, Vorschau→Apply, Git-Seitenleiste) wären
  ein sinnvoller späterer Ausbau.

- **Datei-Drag vom Dokument-Tab:** Mit dem titellosen Fensterchrome entfiel
  das Ziehen der Datei aus der Titelzeile (Proxy-Icon) ersatzlos. Möglicher
  Ersatz wäre ein `.onDrag` der Datei-URL direkt am Tab — nur bei echtem Bedarf.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
- **Monetarisierung:** Entschieden 2026-07-18 — Fastra ist Open Source;
  keine Lizenz-, Trial- oder Bezahlfunktionen. Höchstens ein
  Donation-Button kommt eventuell später, aber vorerst nicht und nur auf
  ausdrücklichen Auftrag.
