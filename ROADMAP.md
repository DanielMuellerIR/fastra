# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **4D-Parameterhilfe/Typeahead: verbliebene Komponenten-/Plugin-Grenzen**
  (verbleibende Grenze nach der Komponentenmethoden-Unterstützung; diese ist mit
  v1.50.0 umgesetzt — Typeahead + Signaturhilfe aus `.4dbase`, `.4DZ` und
  Methodendokumentation, nur geteilte Methoden, Projektmethode gewinnt):
  - **Plugins:** Struktur zuerst am echten Bundle erheben, nichts aus
    Erinnerung raten. **Stand 2026-08-09:** Ein reales Referenzprojekt MIT
    `Plugins`-Ordner (enthält `4D InternetCommands.bundle`) ist inzwischen
    lokal verfügbar (privater Pfad, siehe gitignorierte
    `app/soak-test.local`) — die Erhebung kann bei Bedarf starten.
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
  Etappe 2 (Umbruchziele und Seitenlinie, v1.41.0), Etappe 3
  (Rechteckauswahl unter Soft Wrap, v1.42.0) sowie aus Etappe 4 die
  Einrückungsprofile pro Format und „Einfügen und Einrückung angleichen"
  (v1.68.0).** Offen bleibt aus Etappe 4 die rein visuelle Einrückung von
  Soft-Wrap-Folgezeilen (Spezifikation:
  theplan `tasks/fastra-soft-wrap-2026-07/goal-4-einrueckung.md`, Punkt 3):
  - Die BBEdit-Semantik der drei Modi ist erhoben (Handbuch 16.0.2, S. 125
    und 262): „Flush Left" = Folgefragmente bündig am Fensterrand,
    „First Line" = auf der Einrückung der ersten Zeile, „Reverse" = genau
    EINE Einrückungsstufe tiefer als die erste Zeile. Werkstandard soll
    „First Line" sein; der Wert gehört ins Formatprofil (Feld ist im Store
    vorbereitet, aber bewusst noch nicht angelegt — kein totes Setting).
  - Der Kern ist Geometrie im CodeEditTextView-Layout: Folgefragmente
    brauchen einen eigenen x-Ursprung UND eine entsprechend verkleinerte
    Umbruchbreite (mindestens ein Graphem pro Fragment). Denselben Ursprung
    müssen teilen: Zeichnen, Caret, `rectForOffset`, `textOffsetAtPoint`,
    Auswahlflächen, IME, Drag-and-drop, Auto-Scroll und Rechteckauswahl —
    ein nur optisch eingerückter Text mit falschem Klickziel gilt als nicht
    fertig. Wegen dieser Streuung über viele Layout-Stellen ist der Punkt
    eine eigene, konzentrierte Etappe mit Fenster-Selbsttest
    `softwrapindent` und darf nicht nebenbei entstehen.
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
  Markdown-Schreiben mit Bild-Paste/-Drop). Das hier ursprünglich
  ausgeklammerte echte WYSIWYG („Schreibmodus“) ist inzwischen ausdrücklich
  beauftragt — Stand und Auftrag stehen nur noch unter „Aus Daniels
  Ideenliste übernommen (2026-08-18)“ weiter unten.
- **Wunschpaket Juli 2026** (beschlossen 2026-07-17): Die sechs Etappen sind
  mit v1.20.0–v1.25.0 umgesetzt. Bewusst offen geblieben:
  - **4D-Farbdetails:** Underline (Konstanten) kennt das CESE-Attributmodell
    nicht; `errors`/`plug_ins`/`member` aus den Farbvorgaben entfallen
    mangels Analyse bzw. Unterscheidbarkeit (siehe Slot-Mapping in
    `EditorView.swift`).

## Aus Daniels Ideenliste übernommen (2026-08-18)

- **Markdown-WYSIWYG-Modus („Schreibmodus")** — Daniel hat den bisher
  ausgeklammerten Punkt aus Wunschpaket 2 am 2026-08-18 ausdrücklich beauftragt.
  Damit ist die dort formulierte Bedingung („Daniel entscheidet nach gelebter
  Erfahrung mit Etappe 5 separat und nur auf ausdrücklichen Auftrag") erfüllt;
  der Punkt gilt nicht mehr als zurückgestellt, sondern als offene Produktarbeit.
  Der bereits gebaute Einmalimport von RTF/RTFD nach Markdown
  (`MarkdownImport.swift`) bleibt davon unberührt — gewünscht ist das Bearbeiten
  im WYSIWYG-Modus, nicht ein weiterer Importweg.
  Herkunft: Idee #18 in `theplan/ideen.md`.

- **4D-Makros: verbliebene Grenzen** — Der Kern ist seit v1.105.0 gebaut
  (Discovery, Menü, native Text-Makros, Komplettieren über die tool4d-Engine
  mit Diff-Vorschau, ⌘#/⌘T). Bewusst offen: Makros mit Zwischenablage-,
  Editor-Auswahl- oder Host-Projekt-Bezug (FileMerge, Sortieren, „Ungenutzte
  Methoden" …) laufen nur im echten 4D-Methodeneditor — headless bräuchte je
  Makro eine code-übergebende Variante wie beim Komplettieren. Ebenfalls
  offen: ein warmer tool4d-Prozess, falls die Kaltstartzeit (real ~3 s) im
  Alltag stört. Herkunft: Idee #28 in `theplan/ideen.md`.

- **4D-Makro-Engine: mehrwortige unbekannte Symbole verlieren ihr
  Token-Suffix.** Nach einem headless gelaufenen Komplettieren-Makro stellt
  Fastra die Token-Suffixe aus dem Originalpuffer wieder her. Bei einem
  Symbol aus MEHREREN Wörtern, das weder im Befehls- noch im Konstanten-
  katalog steht (etwa eine ganz neue 4D-Konstante „Future const"), gelingt
  das nicht: Ohne Suffix und ohne Katalogeintrag hat der Tokenizer kein
  Merkmal, an dem er die Wörter als EIN Symbol erkennen könnte. Einwortige
  unbekannte Befehle und Konstanten sind seit dem Reviewfund vom 2026-08-20
  abgedeckt. Lösungsrichtung: Die gelernten Namen vor dem Tokenisieren als
  zusätzliche Symbolmenge in den Tokenizer geben, statt sie erst danach
  nachzuschlagen. Festgehalten als Test
  `learnedRoundtripCannotRebuildUnknownMultiWordSymbols`.

## Kleine offene Ideen

- **Druck-Ausbau (beauftragt 2026-08-18, aus der manuellen Druckabnahme):**
  Der Schalter-Teil ist mit v1.102.0 erledigt (Kopf-/Fußzeile und
  Zeilennummern direkt im Systemdruckdialog). Offen bleibt allein:
  - **Syntaxfarben im Quelltext-Ausdruck:** Der Farbausdruck ist jetzt
    ausdrücklich gewünscht. Vor der Umsetzung am echten Code erheben, wie die
    Editor-Einfärbung für den Druck wiederverwendet werden kann (heller
    Farbsatz auf Papier, unabhängig vom Bildschirm-Thema).

- **Drucken: weiterhin bewusst gezogene Grenzen** (v1.100.0):
  - Die **gerenderte Markdown-Vorschau hat keine Kopf- und Fußzeile**. Diese
    Seiten setzt WebKit selbst; Seitenzahlen in den Papierrand einer
    WebKit-Seite gibt es ohne eigene Seitenaufteilung nicht. Quelltext-, Hex-
    und Bildausdruck haben sie.
  - **Kein eigener „Als PDF exportieren"-Befehl.** Der Systemdialog kann das
    schon („PDF" unten links), und ein zweiter Weg dorthin wäre nur eine
    weitere Stelle, die vom ersten abweichen kann. Programmatisch nutzt genau
    diesen Weg der `print`-Selbsttest.

- **Markdown-Umwandlung: bewusst offen gelassen** (umgesetzt 2026-07-26 über
  `poormans-text --formats`):
  - Der Formatkatalog wird beim Start vorgewärmt und fünf Minuten
    zwischengespeichert. Wird `poormans-text` in dieser Zeit aktualisiert,
    braucht es einen Fastra-Neustart. Bewusst so — eine Invalidierung über
    einen Dateiwächter wäre für den Nutzen zu viel Maschinerie.
  - Es läuft immer nur EINE Umwandlung gleichzeitig; der Befehl ist währenddessen
    gesperrt. Eine Warteschlange lohnt erst, wenn Stapelumwandlung gewünscht ist.
  - Kein Fortschritt und kein Abbruch während einer Umwandlung. Dafür wäre die
    direkte Library-Anbindung statt des CLI-Aufrufs nötig (siehe
    `poormans_text/ROADMAP.md`).
  - Der Katalog fragt nur, OB ein Werkzeug installiert ist, nicht welche
    Eingabeformate dessen Version beherrscht. Ein sehr altes Pandoc könnte
    deshalb erst beim Umwandeln scheitern — dann mit echter Fehlermeldung.

- **Hilfe später hübscher:** Die mitgelieferte Hilfe (Etappe 4 Wunschpaket
  2026-07b) ist bewusst reiner Text ohne Bilder. Screenshots/Illustrationen
  der zentralen Abläufe (Suchmaske, Vorschau→Apply, Git-Seitenleiste) wären
  ein sinnvoller späterer Ausbau.

- **Datei-Drag vom Dokument-Tab:** Mit dem titellosen Fensterchrome entfiel
  das Ziehen der Datei aus der Titelzeile (Proxy-Icon) ersatzlos. Möglicher
  Ersatz wäre ein `.onDrag` der Datei-URL direkt am Tab — nur bei echtem Bedarf.

- **Datenschutz-Erklärung der Markdown-Vorschau: Produktvergleiche bleiben
  bewusst draußen** (Rest der Idee 2026-07-28; der erklärende Abschnitt
  selbst steht seit v1.5x in README und mitgelieferter Hilfe, bewusst ohne
  Produktnamen und Werturteile). Sollte je ein konkreter Vergleich mit
  anderen Werkzeugen gewünscht sein: nur mit eigener, aktueller Messung,
  und dabei zwischen der VORGEFUNDENEN Konfiguration und der
  Auslieferungs-Voreinstellung unterscheiden — eine Aussage über die
  Voreinstellung braucht eine frische Umgebung. Die Einzelmessung vom
  2026-07-28 liegt in der privaten Projektdokumentation; ein öffentliches
  Repo ist kein Ort für ungeprüfte Befunde über fremde Software.

## Aus dem Dauertest und den Betriebsmeldungen (2026-08-07/08)

Der lange Dauertest (`app/soak-test.sh`) läuft — seit dem Realismus-Ausbau
auch mit echten Dokumenten, RTFD-Umwandlung samt sofortiger
Weiterbearbeitung, einem echten 4D-Projekt (Completion, Signaturhilfe,
ALT-Doppelklick), Fenstergeometrie, Kopieren/Einfügen zwischen Fenstern und
echten Menübefehlen (private Datenquellen in der gitignorierten
`app/soak-test.local`). Diese Punkte hat er oder der Arbeitsbetrieb gemeldet
und sie sind noch offen.

- **Die Ansicht kriecht beim Markieren mit der Maus nach unten** — nur in
  Markdown, nicht deterministisch reproduzierbar (der Selbsttest
  `dragnoscroll` fängt es nicht ein: synthetische Drag-Ereignisse kommen
  nicht einzeln an). **Wurzel mit v1.67.1 behandelt:** Das Nachzieh-Scrollen
  war seit v1.65.0 ans Key-Window gebunden (`bgscroll`); mit dem
  CESE-Patch 4c-2 vergleicht der Reconcile jetzt über
  `controller.resolveCursorPosition`, wodurch ein bereits angewandter
  Sprung (range == .notFound, nur Zeile/Spalte) als „gleich" gilt und der
  Zweig nicht mehr bei jeder SwiftUI-Neubewertung feuert. Die Beobachtung
  bleibt bis zur Bestätigung im Arbeitsbetrieb notiert; bei erneutem
  Auftreten Repro-Schritte und geöffnete Dokumente festhalten.
- **Das Fenstermenü listete nur eine von zwei offenen Dateien.** In kurzer
  Nachstellung korrekt — also zustandsabhängig.
- **`folderSearch_deduplicatesOverlappingRoots` einmal rot** (2026-07-28,
  nicht reproduziert). Der Test meldete 0 statt 1 Treffer in einem
  vollständigen `swift test`; isoliert dreimal und in zwei weiteren
  vollständigen Läufen grün. Passt zur Klasse der lastabhängigen Befunde
  dieses Tages. Bei erneutem Auftreten notieren, ob der Lauf unter Fremdlast
  stand, und den Kandidatenpfad der Datei-Set-Wurzeln prüfen.

- **„Späte Attributantwort eines alten Tabs" lastabhängig rot**
  (`GitConflictAndAdvancedTests`, beobachtet 2026-08-09 in zwei von etwa
  acht vollständigen `swift test`-Läufen): Die erste Attributprüfung
  startete gar nicht (`executor.count == 0`) — der Guard in
  `invalidateAndRefreshActiveConflictInspection` bricht dann still ab.
  Der Test degradiert seit 2026-08-09 sauber (Issue statt Index-Trap, der
  vorher die GANZE Suite beendete). Ursache unklar; Verdacht ist ein
  asynchroner Überschreiber von `gitStatus` unter Testparallelität. Bei
  erneutem Auftreten die Guard-Bedingungen einzeln protokollieren.

- **Eine Ursache lastabhängig roter Tests ist seit 2026-08-17 belegt und
  behoben.** Im vollen parallelen Lauf steht der Main-Actor mehrere Sekunden
  am Stück still, weil alle `@MainActor`-Tests im selben Prozess denselben
  Actor teilen (gemessen: 6,98 s Pause in einer 10-ms-Warteschleife). Eine
  Wanduhr-Frist verstrich dadurch, ohne dass der Test überhaupt nachsehen
  konnte; `waitUntil` misst seitdem nur noch beobachtete Zeit (AGENTS.md,
  „Bekannte technische Fallen"). Die beiden Befunde darüber stammen aus der
  Zeit davor und sind damit NICHT erklärt: Sie melden einen falschen Wert,
  keine gerissene Frist. Bei einem neuen lastabhängigen Befund trotzdem
  zuerst prüfen, ob eine Frist beteiligt war.

## Offene Beobachtungen (nicht reproduziert)

- **⌘⇧+Pfeiltasten ohne Wirkung auf einem anderen Mac** (Daniel-Meldung
  2026-07-29; auf dem Entwicklungs-Mac funktioniert es). Befund: Fastras eigenes
  Key-Routing (`KeyRouting.route`) fasst ⌘- und ⌘⇧-Pfeilkombinationen nicht
  an — sie gehen unverändert an den Editor durch; es gibt also keinen
  Fastra-Code, der das nur auf einem Rechner abschalten könnte. Verdacht:
  Umgebung des anderen Macs (systemweite oder App-Tastenkürzel, die
  ⌘⇧+Pfeil abfangen, Sonderbelegung der Tastatur). Bei erneutem Auftreten
  auf dem betroffenen Mac prüfen: Systemeinstellungen → Tastatur →
  Kurzbefehle auf Konflikte, und ob dieselbe Kombination in TextEdit
  funktioniert (falls nein, ist es kein Fastra-Thema).

- **Fenster ganz ohne Tabs mit tippbarer Editorfläche nach App-Start**
  (Daniel-Meldung 2026-07-29, einmalig, kein Repro). Analyse: `tabs` kann
  nur über den Fensterschließen-Pfad (`prepareToCloseWindow`) dauerhaft leer
  werden; SwiftUI hält Szene samt Workspace am Leben und kann das Fenster
  später wieder anzeigen (Dock-Klick wirkt wie App-Start) — dann stand ein
  Fenster ohne Tabs da, dessen Editor ins Leere schrieb. Zweifach
  abgesichert: Nach dem Leeren kehrt der Workspace sofort in den
  Willkommens-Zustand zurück, und ein Fenster ohne jeden Tab zeigt zur Not
  die Willkommensseite statt des Geister-Editors. Sollte es dennoch wieder
  auftreten: notieren, ob die App vorher wirklich beendet war (⌘Q) oder nur
  alle Fenster geschlossen waren.

## Ältere offene Beobachtungen (2026-07-24/25, nicht reproduziert)

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
- **„Tab-Wechsel repariert die Emoji-Darstellung“** (Daniel-Meldung
  2026-07-27). Die beiden greifbaren Teile des Befunds sind geklärt und in
  v1.52.1/v1.52.2 abgearbeitet: Der Editor legte attributierten Text (RTF)
  aufs Clipboard, dessen RTF-nach-HTML-Weg U+FE0F verlor, und in der
  gemeldeten Datei steht über die ganze Git-Historie das nackte `⏸` ohne
  Variantenselektor, das Editor und Vorschau systembedingt unterschiedlich
  zeigen (Wächter `emojipreview`). Offen bleibt allein die Beobachtung, dass
  ein Tab-Wechsel die Darstellung verändert hat: Der Wächter `emojipaste`
  prüft Speicherinhalt, Attributläufe, Glyph-Runs, gezeichnete Pixel und die
  Live-Vorschau an 13 Einfügestellen und findet nichts. Passt zur Klasse
  „laufende Sitzung zeichnet veraltet“ (F.18). Bei erneutem Auftreten
  notieren: Editor-Text oder Vorschau, Fensterbreite, ob ein App-Neustart
  genügt, und welche Codepoints die Datei an der Stelle wirklich enthält.

  **Zwischenstand 2026-07-28:** Daniel hat die notarisierte v1.53.1 im echten
  Einsatz benutzt und meldet die Emoji-Darstellung auf beiden Seiten — Editor
  und Vorschau — als korrekt. Das ist der erste positive Gegenbefund seit der
  Meldung; die Beobachtung bleibt aber notiert, weil ein einzelner guter Lauf
  eine sporadische Zeichenfrage nicht ausschließt. Die Wächter `emojipaste`,
  `emojipreview` und `emojisplit` laufen weiter im Standardlauf.

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
