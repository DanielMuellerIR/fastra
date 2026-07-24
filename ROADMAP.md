# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **4D-Parameterhilfe/Typeahead für Komponenten- und Plugin-Methoden**
  (Daniel-Auftrag 2026-07-24, Prio 2 nach den Projektmethoden aus
  v1.48.0/v1.49.0 — nächste Session):
  - **Ausgangslage im Code:** Signatur-Parser und Aufrufkontext liegen in
    `app/Sources/Fastra/FourDSignatureHelp.swift` (pure Logik, 15 Tests in
    `FourDSignatureHelpTests.swift`), das Panel in
    `FourDSignatureHelpPanel.swift`, das Typeahead in `FourDCompletion.swift`
    (Projektmethoden via `Workspace.fourDProjectMethodDisplayNames`).
    Methodenauflösung: `FourDSignatureHelpLogic.methodFileURL` sucht bisher
    nur `…/Sources/Methods/<Name>.4dm`. Selbsttests: `sighelp4d` (inkl.
    Verschachtelung), `completion4d`.
  - **Befund aus dem BA-Referenzprojekt (2026-07-24):** Komponenten liegen
    unter `<Projekt>/components/*.4dbase/Contents/` mit einem `.4DZ`-Archiv
    (echtes ZIP). Die sechs BA-Komponenten sind KOMPILIERT: Im 4DZ steckt
    `Project/DerivedData/…`, aber **kein einziges `.4dm`** — Quelltexte sind
    dort also nicht verfügbar. `Project/Sources/dependencies.json` existiert.
    Ein `Plugins`-Ordner existiert in BA nicht.
  - **Zu klärender Weg (in dieser Reihenfolge prüfen):** 1) Interpretierte
    Komponenten: 4DZ als ZIP öffnen bzw. entpackte `.4dbase` mit
    `Project/Sources/Methods/*.4dm` — dann greift der vorhandene Parser
    unverändert; nur `methodFileURL` und der Index brauchen Komponenten-
    Wurzeln (inkl. Lesen aus ZIP ohne Vollentpacken, Größenlimit). 2) Für
    kompilierte Komponenten prüfen, ob ein Katalog der exportierten Methoden
    existiert (im 4DZ, in `Contents/Resources/` oder via `dependencies.json`
    aufgelösten Quellen); ohne Signaturquelle ehrlich nur den Methodennamen
    im Typeahead anbieten (Kennzeichnung „Komponente“), keine erfundenen
    Parameter. 3) Plugins erst angehen, wenn ein reales Projekt mit
    `Plugins`-Ordner als Fixture verfügbar ist — Struktur dann zuerst am
    echten Bundle erheben, nichts aus Erinnerung raten.
  - **Verbindlich:** Fixtures für Tests selbst schreiben (keine BA-Inhalte
    ins öffentliche Repo); eine lokale BA-Arbeitskopie zum Testen ist
    erlaubt (Daniel-Freigabe 2026-07-24), Original unter
    `~/Documents/gita/BA` nie verändern. Hilfe (DE+EN) und `sighelp4d`/
    Unit-Tests erweitern; Namenskollision Projektmethode vs. Komponente
    klären (Projektmethode gewinnt).
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

## Bekannte Fehler (Code-Review-Probelauf 2026-07-24)

- **`bufferSearching` bleibt nach Abbruch hängen** (`app/Sources/Fastra/SearchRunner.swift`,
  Abbruch-/Guard-Pfad um Zeile 149 bzw. 181): Wird eine laufende Buffer-Suche
  in `rerun()` abgebrochen und danach der Ordner-Lauf wegen kurzem/leerem
  Pattern über den `guard` verworfen, setzt der Fehlerpfad nur
  `ws.folderSearching = false`. `ws.bufferSearching` bleibt dauerhaft `true`
  (Spinner klemmt). Fix: beim Abbruch auch `ws.bufferSearching = false` setzen.
- **Nicht reguläre Dateien werden nicht abgewiesen** (`app/Sources/Fastra/FileLoader.swift`,
  Zeile 88): `load(url:)` prüft den Dateityp nicht. FIFOs/Gerätedateien
  gelangen in die synchrone Probe, die unbegrenzt blockieren kann; ein
  Attributfehler wird zudem als Größe `0` behandelt und umgeht so den
  Large-File-Pfad. Fix: `.type == .typeRegular` verbindlich prüfen und
  Attributfehler nicht als Größe `0` interpretieren.

## Offene Beobachtungen (2026-07-24, nicht reproduziert)

- **Emoji „in zwei Zeichen zerplatzt“** (Daniel-Meldung, wahrscheinlich noch
  v1.46.8): Mit v1.48.0 nicht reproduzierbar — Dateibytes intakt,
  Attributläufe/Fragmente/Glyphen über 121 Umbruchbreiten sauber, Fenster-
  Screenshot einwandfrei. Wächter `emojisplit` läuft im Standardlauf.
  Daniel prüft mit v1.49.0 gegen; bei erneutem Auftreten Fensterbreite oder
  Screenshot zur Meldung geben.
- **Kurzzeitig doppelte Zeilenhöhe** beim Emoji-Einfügen über die
  Emoji-Palette (normalisierte sich nach dem nächsten Einfügen von selbst).
  Nicht reproduziert; passt zur Klasse „stehengebliebene Layoutfragmente
  nach Einfügung“ (F.18). Beobachtung im Blick behalten, bei erneutem
  Auftreten sofort Repro-Schritte notieren.

## Später – nur auf ausdrückliche Anfrage

- **Cross-Platform-Portabilität (Windows/Linux):** Weder Machbarkeit noch
  Implementierung werden ohne ausdrücklichen Auftrag untersucht.
- **Monetarisierung:** Entschieden 2026-07-18 — Fastra ist Open Source;
  keine Lizenz-, Trial- oder Bezahlfunktionen. Höchstens ein
  Donation-Button kommt eventuell später, aber vorerst nicht und nur auf
  ausdrücklichen Auftrag.
