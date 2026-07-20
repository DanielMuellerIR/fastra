# Menüvolltest 2026-07-20

Getestet wurde Fastra v1.44.0 (Build 102) als wegwerfbare, ad hoc signierte
Test-App mit eigener Bundle-ID im Projekt-Root. Das normale App-Bundle in
`/Applications` wurde weder ersetzt noch gestartet. Projekt, Dateien und
Git-Remote waren ausschließlich lokale Test-Fixtures.

## Vorbedingungen

- Swift-Tests, Lokalisierungs-Audit, Debug-Build und portable Bundle-Prüfung:
  bestanden.
- Vollständiger In-App-Selbsttest vor dem manuellen Lauf: 52 bestanden,
  kein Funktionsfehler, ein ehrlicher Umgebungsskip wegen fehlender sicherer
  `tool4d`-Testprojektfreigabe.
- Nach den beiden manuellen Funden wurden die Swift-Tests und die betroffenen
  echten Editor-/Sitzungs-Selbsttests erneut ausgeführt.

## Manuell geprüft

- App-Menü, Versionsdialog, Einstellungen und Hilfefenster.
- Ablage-, Bearbeiten-, Darstellungs-, Such-, Text-, Markdown-, Git- und
  Fenstermenüs auf Vollständigkeit und kontextabhängige Aktivierung.
- Alphabetische Zeilensortierung auf- und absteigend einschließlich gleicher
  Zeilen, natürlicher Zahlensortierung, Undo und Redo.
- Vollauswahl mit Soft Wrap: Alle Inhaltszeilen waren ausgewählt. Eine graue
  zusätzliche Zeilennummer bezeichnet korrekt die leere logische Zeile hinter
  einem abschließenden Zeilenumbruch; dort existiert kein Zeichen, das blau
  hinterlegt werden könnte.
- Zeilen verbinden mit Leerzeichen und Undo: Text, Gutter und Scrollposition
  blieben sichtbar; kein leerer Editor und kein Leerraum oberhalb von Zeile 1.
- Neu laden von Festplatte einschließlich Rückfrage bei ungesichertem Inhalt.
- Soft Wrap aus/ein, Datei- und Ordnersuche, Markdown-Quelle und Vorschau,
  Markdown-Fettung plus Undo.
- Gültiges JSON formatieren und prüfen; ungültiges JSON meldete die
  Fehlerposition verständlich.
- Git-Verlauf und Side-by-side-Diff gegen ein lokales Repository.
- Sitzungswiederherstellung mit zwei Fenstern, mehreren gespeicherten Tabs,
  einem unbenannten Dokument und ungesicherten Änderungen.
- Deaktivierte Sitzungswiederherstellung: Neustart zeigte korrekt nur das
  Willkommensfenster.

## Gefundene Regressionen

1. Eine Textauswahl wurde beim Wechsel auf eine andere Datei übernommen.
   Dadurch versuchte „Dokument formatieren“ nur den geerbten Teilbereich zu
   formatieren. Behoben durch tab-eigenen Cursor-/Selektionszustand; Unit-Test
   und echter `tabswitch`-Editor-Selbsttest schützen den Fall.
2. Beim interaktiven Beenden wurde nur das vorderste von zwei Fenstern
   wiederhergestellt. Behoben durch einen Snapshot aller noch registrierten
   Dokumentfenster, unabhängig von AppKits vorübergehendem Sichtbarkeitsstatus;
   ein Regressionstest bildet den ausgeblendeten Beenden-Zwischenzustand nach.

Ungesicherter Inhalt wurde bereits im fehlerhaften Lauf korrekt verworfen und
kam nach dem Neustart nicht zurück.

## Abgrenzung

Jeder Menüeintrag wurde sichtbar geprüft; repräsentative schreibende Pfade
wurden real bedient. Nicht jede der zahlreichen Texttransformationen und keine
potenziell destruktive Git-Mutation wurde im Vordergrund einzeln ausgeführt.
Diese Pfade werden durch die vorhandenen Unit- und In-App-Selbsttests mit
wegwerfbaren Dateien beziehungsweise lokalen Repositories abgedeckt. Der
gelegentliche Vordergrundtest ergänzt diese Suite vor allem um reale
Menüzustände, Fokus, Auswahl, Layout, Undo und Fenster-Lifecycle.
