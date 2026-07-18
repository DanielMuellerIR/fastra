# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Wunschpaket 2** (beschlossen 2026-07-18, offen): Fünf Etappen —
  Navigation & Chrome (Git-Root beim Datei-Öffnen, Seitenleisten-Kopf auf
  allen Tabs, Ansichts-Umschalter in die Fußzeile, Tab-Pfadmenü per
  Cmd-Klick, Fenstertitel-Recherche), Suchdialog (Button-Prominenz,
  mitscrollende Trefferliste, Live-Markierung aller Treffer), Sprachmenü
  mit wählbarem 4D samt Anti-Drift-Test, Hilfedokument samt
  `help-audit`-Mechanik, assistiertes Markdown-Schreiben mit
  Bild-Paste/-Drop. Spezifikation:
  `docs/wunschpaket-2026-07b/goal-vorschlag.md`. Echtes WYSIWYG
  („Schreibmodus“) ist bewusst ausgeklammert; Entscheidungsvorlage in
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
    tragfähigem Einzeldatei-Konzept.
  - **4D-Farbdetails:** Underline (Konstanten) kennt das CESE-Attributmodell
    nicht; `errors`/`plug_ins`/`member` aus den Farbvorgaben entfallen
    mangels Analyse bzw. Unterscheidbarkeit (siehe Slot-Mapping in
    `EditorView.swift`).

## Offene Produktentscheidungen

- **Monetarisierung:** Ältere Anforderungen nennen eine kostenlose
  Testmöglichkeit als wichtig. Das aktuelle Modell beschreibt Fastra dagegen als
  Donationware ohne Lizenz- oder Trial-Wall. Vor einer Monetarisierungsfunktion
  muss dieser Widerspruch ausdrücklich entschieden werden.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
