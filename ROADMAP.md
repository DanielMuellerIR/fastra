# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Wunschpaket 3** (vorgeschlagen 2026-07-18, noch nicht beschlossen):
  Spezifikationsentwurf in `docs/wunschpaket-2026-07c/goal-vorschlag.md` —
  acht Etappen: Datei-Diff dual-pane nach BBEdit-Vorbild (eigener Diff-Kern
  ohne Git), Git-Diffs auf denselben Renderer vereinheitlicht,
  Dateinamens-Filter in der Projektansicht, tool4d-Ersteinrichtungshilfe,
  4D-Struktur-Hinweise, 4D-Vervollständigung/`.4DForm`-Schema/Export-
  Transformation, Alt-Doppelklick „Gehe zum Ziel“ (4D-Methoden +
  Markdown-Links, erweiterbar), 4D-Syntax-Check via tool4d-LSP (Gate:
  rechtliche Freigabe durch den Maintainer). Umsetzung erst nach Prüfung
  des Entwurfs.
- **Wunschpaket 2** (beschlossen 2026-07-18): Alle fünf Etappen sind mit
  v1.27.0–v1.31.0 umgesetzt (Navigation & Chrome, Suchdialog, Sprachmenü
  mit wählbarem 4D, Hilfe samt `help-audit`-Mechanik, assistiertes
  Markdown-Schreiben mit Bild-Paste/-Drop). Spezifikation:
  `docs/wunschpaket-2026-07b/goal-vorschlag.md`. Bewusst offen: Echtes
  WYSIWYG („Schreibmodus“) ist ausgeklammert — Daniel entscheidet nach
  gelebter Erfahrung mit Etappe 5 separat; Entscheidungsvorlage in
  `docs/wunschpaket-2026-07b/goal-stufe-b-wysiwyg.md`, nur auf
  ausdrücklichen Auftrag.
- **Wunschpaket Juli 2026** (beschlossen 2026-07-17): Die sechs Etappen sind
  mit v1.20.0–v1.25.0 umgesetzt (Spezifikation samt 4D-Farbvorgaben liegt in
  `docs/wunschpaket-2026-07/`). Bewusst offen geblieben:
  - **tool4d-Anbindung (4D-Lint) zurückgestellt:** tool4d arbeitet
    projektbasiert; Einzeldatei-Diagnosen erfordern den LSP-Modus
    (dauerhafter Serverprozess, JSON-RPC) und die Nutzungsbedingungen für
    den Aufruf durch Dritt-Tools sind nicht abschließend geklärt. Statt der
    Integration liefert Fastra eine Anleitung in `docs/tool4d.de.md` und
    `docs/tool4d.md`. Wiedervorlage nur mit geklärten Bedingungen und
    tragfähigem Einzeldatei-Konzept. Recherche-Stand 2026-07-18: Die
    offizielle VS-Code-Extension „4D-Analyzer“ nutzt genau diesen LSP-Weg
    (`tool4d --lsp=<port>`, JSON-RPC über localhost-TCP) und verspricht
    Einzeldatei-Support — das Einzeldatei-Konzept ist damit greifbar; die
    formalen Nutzungsbedingungen von tool4d bleiben der offene Punkt
    (Indizien: frei, auch für CI/Dritt-Tools beworben). Details im
    Wunschpaket-3-Entwurf.
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
  das Ziehen der Datei aus der Titelzeile (Proxy-Icon) ersatzlos; Befund in
  `docs/wunschpaket-2026-07b/fenstertitel-befund.md`. Möglicher Ersatz wäre
  ein `.onDrag` der Datei-URL direkt am Tab — nur bei echtem Bedarf.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
- **Monetarisierung:** Entschieden 2026-07-18 — Fastra ist Open Source;
  keine Lizenz-, Trial- oder Bezahlfunktionen. Höchstens ein
  Donation-Button kommt eventuell später, aber vorerst nicht und nur auf
  ausdrücklichen Auftrag.
