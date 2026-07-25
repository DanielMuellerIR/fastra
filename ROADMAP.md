# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Test-Defaults-Aufräumer integrieren** (2026-07-24): Branch
  `claude/kind-dewdney-f519ae` (Nebensession) löscht die von Testläufen
  hinterlassenen UUID-Suiten in `~/Library/Preferences`
  (`TestDefaultsJanitorTests`, Erstbereinigung 8286 → 37 Dateien) — bei
  Gelegenheit nach main übernehmen (z. B. `/cherry-pick-to-main`).

- **4D-Parameterhilfe/Typeahead: verbliebene Komponenten-/Plugin-Grenzen**
  (verbleibende Grenze nach der Komponentenmethoden-Unterstützung; diese ist mit
  v1.50.0 umgesetzt — Typeahead + Signaturhilfe aus `.4dbase`, `.4DZ` und
  Methodendokumentation, nur geteilte Methoden, Projektmethode gewinnt):
  - **Plugins:** erst angehen, wenn ein reales Projekt mit `Plugins`-Ordner
    als Fixture verfügbar ist — Struktur dann zuerst am echten Bundle
    erheben, nichts aus Erinnerung raten (im verfügbaren Referenzprojekt
    existiert kein solcher Ordner).
  - **GitHub-Abhängigkeiten:** `Project/Sources/dependencies.json` kann
    Komponenten benennen, die nicht unter `<Projekt>/Components/` liegen
    (z. B. von 4D verwaltete Downloads). Bewusst offen, bis der reale
    Ablageort an einem echten Projekt erhoben ist.
  - **Benannte klassische Parameter:** 4D-Methodendoku kompilierter
    Komponenten deklariert Parameter teils als benannte Variablen
    (`C_LONGINT($pid_i)`) — der Parser zählt ehrlich nur `$N`/`#DECLARE`;
    das Panel zeigt dann `(…)`. Eine Zuordnung benannter Deklarationen zu
    Parameterpositionen wäre Raterei und bleibt bewusst außen vor.
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

## Offene Beobachtungen (2026-07-24/25, nicht reproduziert)

- **Editor-Befunde 2026-07-24/25:** Der Return-/Tipp-Scroll-Befund ist mit
  v1.50.1 GELÖST (State-Reconcile-Race, F.23; Daniel-verifiziert am
  Live-Repro), ebenso der dabei entdeckte ⌘V+⌘Z-Crash (F.24). Offen
  bleiben zwei Beobachtungen aus der Sitzung VOR dem cfprefsd-Neustart
  vom 2026-07-24, seither nicht wieder aufgetreten: Palette-Emoji erschien
  erst nach dem zweiten Einfügen; Shift+← hinter Emojis erweiterte die
  Markierung sichtbar nicht. Beide passen zur selben Klasse „laufende
  Sitzung zeichnet veraltet“ (F.18); Wächter `typescroll` läuft im
  Standardlauf. Bei erneutem Auftreten: notieren, ob ein App-Neustart es
  behebt, und `FASTRA_TYPESCROLL_FIXTURE=<Dateikopie> ./selftest.sh
  typescroll` auf dem betroffenen Stand fahren.

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
