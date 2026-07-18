# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Wunschpaket 3** (beschlossen 2026-07-18, in Umsetzung):
  Spezifikation in `docs/wunschpaket-2026-07c/goal-vorschlag.md` —
  acht Etappen. **Umgesetzt: Etappe 1 (Diff-Kern & Datei-Diff
  dual-pane, v1.32.0), Etappe 2 (Git-Diff auf gemeinsamem Renderer,
  v1.33.0), Etappe 3 (Dateinamens-Filter in der Projektansicht,
  v1.34.0), Etappe 4 (tool4d-Ersteinrichtungshilfe, v1.35.0),
  Etappe 5 (4D-Struktur-Hinweise, v1.36.0), Etappe 6
  (4D-Vervollständigung/`.4DForm`-Schema/Export-Transformation,
  v1.37.0), Etappe 7 (Alt-Doppelklick „Gehe zum Ziel“, v1.38.0).**
  Offen: NUR noch der 4D-Syntax-Check via tool4d-LSP (Etappe 8) —
  dessen Gate (rechtliche Freigabe durch den Maintainer) besteht
  formal weiter; Umsetzung erst nach der Bestätigung.
  - **Etappe 6 — Vervollständigung ist DEFEKT, nicht nur ungeprüft:** Die
    ausstehende Sichtprüfung fand am 2026-07-18 an v1.38.1 statt und war
    negativ. Das automatische Popup beim Tippen erscheint nicht, und das
    mit ⌃Leertaste geöffnete Fenster nimmt weder Pfeiltasten noch Klicks
    an. Die Logik ist unit-getestet und in Ordnung — der Defekt sitzt in
    der Anbindung an CodeEditSourceEditor. Befund mit Codepfaden,
    geprüften Sackgassen und empfohlenem Vorgehen:
    `docs/wunschpaket-2026-07c/vervollstaendigung-befund.md`. Vor einem
    Fix zuerst einen real fehlschlagenden Selbsttest bauen.
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
    Einzeldatei-Support — das Einzeldatei-Konzept ist damit greifbar.
    Offizielle Quellen erklären tool4d ausdrücklich für frei und
    lizenzlos („does not need any license to run“, 4D-Blog; „a free,
    lightweight, stand-alone application“, developer.4d.com/docs/Admin/
    cli); die abschließende Bestätigung holt der Maintainer ein. Details
    im Wunschpaket-3-Entwurf.
  - **4D-Farbdetails:** Underline (Konstanten) kennt das CESE-Attributmodell
    nicht; `errors`/`plug_ins`/`member` aus den Farbvorgaben entfallen
    mangels Analyse bzw. Unterscheidbarkeit (siehe Slot-Mapping in
    `EditorView.swift`).

## Kleine offene Ideen

- **Hilfe später hübscher:** Die mitgelieferte Hilfe (Etappe 4 Wunschpaket
  2026-07b) ist bewusst reiner Text ohne Bilder. Screenshots/Illustrationen
  der zentralen Abläufe (Suchmaske, Vorschau→Apply, Git-Seitenleiste) wären
  ein sinnvoller späterer Ausbau.

- **`jump`-Selbsttest (CR) ist flaky, nicht defekt:** Am 2026-07-18 fiel er in
  einem Lauf mit „Editor-TextView nicht als CodeEditTextView.TextView
  erreichbar" aus und war im direkt folgenden Lauf bei unverändertem Code
  grün (Suite 41/41). Der CR-Teilfall prüft also nicht zuverlässig, was er
  prüfen soll: Die Meldung beschreibt einen fehlgeschlagenen Zugriff auf die
  TextView, nicht ein falsches Sprungergebnis — die View ist zum Prüfzeitpunkt
  vermutlich noch nicht fertig aufgebaut. Wer den Fail untersucht, sollte
  deshalb zuerst dort ansetzen (auf Verfügbarkeit warten statt einmalig
  abzufragen) und ihn nicht als echten Regressionsfund im Sprung-Pfad lesen.
  Ein Fail in EINEM Lauf ist hier kein Beweis.

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
