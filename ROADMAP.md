# Fastra — Roadmap

Hier stehen nur offene Produktarbeit und bewusst zurückgestellte Grenzen.
Erledigte Arbeit und historische Entscheidungen stehen in
[CHANGELOG.md](CHANGELOG.md).

## Jetzt

- **Tests räumen ihre Preferences-Domains nicht auf** (gemeldet 2026-07-28, M3):
  Jeder Testlauf legt unter `~/Library/Preferences` eigene Domains mit UUID im
  Namen an und lässt sie liegen — gefunden wurden 3713 plists (~22 MB), Muster
  `FastraTests.GitPreferences.<UUID>` (1419), `FastraTests.PatternLibrary.<UUID>`
  (482), `Fastra-DiffLifecycle-<UUID>`, `fastra-test-extchange-<UUID>`,
  `search-jump-first/second-<UUID>`; dazu Altbestand des archivierten Vorläufers
  cregex. Das ist nicht nur Unordnung: `cfprefsd` kam mit der Domain-Flut nicht
  mehr klar — `defaults read com.apple.Terminal` lieferte NICHTS mehr, und
  Terminal.app startete mit dem Standardprofil statt Daniels Einstellungen; nach
  Löschen der 3713 Dateien und cfprefsd-Neustart war alles wieder normal.
  **Zu tun:** Tests entfernen ihre Domain im `tearDown`
  (`removePersistentDomain` für den jeweiligen Suite-Namen, alternativ
  `defaults delete`); zusätzlich ein Guard am Suite-Ende, der meldet, wenn eine
  Test-Domain übrig bleibt.
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

- **Willkommen als Platzhalter statt eigenem Tab:** Von Daniel am 2026-07-30
  entschieden, umgesetzt und am installierten Stand abgenommen („Passt nun",
  nach Entfernen der anfänglichen Projekt-Sperre; siehe CHANGELOG
  Unreleased). Die README-Screenshots zeigen den Willkommensbildschirm
  nicht und bleiben unverändert. Offen sind nur noch die fokus-pflichtigen
  Fenster-Selbsttests (welcomenew, newwindow, cmdw, sessionrestore,
  coldopen) auf einer geeigneten UI-Sitzung.

- **Datenschutz und Sicherheit der Markdown-Vorschau erklären** (Idee
  2026-07-28): Ein kurzer Abschnitt in README und mitgelieferter Hilfe, der
  beschreibt, wie Fastra Markdown anzeigt und welcher Kompromiss dahintersteht.
  Der Punkt ist nicht „sicherer als andere", sondern **nachvollziehbar**: Ein
  Vorschaufenster rendert fremde Dokumente, und Leser sollen wissen, was dabei
  passiert.

  Zu erklären wäre die bewusste Mitte. Vollständige HTML-Unterdrückung macht
  verbreitete GitHub-READMEs unbrauchbar — ein zentriertes Logo in
  `<p align="center"><img …></p>` ist der Normalfall. Fastra rendert deshalb
  eine kleine, fest umrissene Menge an Elementen, einschließlich `<img>`, und
  hält gleichzeitig fest: `default-src 'none'` verbietet jeden Netzabruf,
  entfernte Bilder werden neutralisiert, lokale laufen über interne Tokens,
  der Prüfer erzeugt die Ausgabe neu statt Eingabebytes durchzureichen,
  `script-src` nutzt einen Nonce pro Render statt `'unsafe-inline'`, und
  unsichere Link-Schemata (`javascript:`, `vbscript:`, `file:`, `data:`)
  prüft Fastra selbst. Kein `<script>`, `<style>`, `<iframe>`, `<svg>`,
  `<math>`, keine Ereignis-Attribute, kein `style`, `class` oder `id`.

  **Zum Vergleich mit anderen Werkzeugen:** Umgesetzt ist das in README und
  Hilfe bewusst ohne Produktnamen und ohne Werturteil — beschrieben wird der
  Mechanismus, den die wenigsten kennen (entfernte Bilder verraten das Öffnen;
  Formel- und Diagrammbibliotheken kommen beim Anzeigen von einem CDN), samt
  Hinweis, dass beides meist umstellbar ist, und einer Anleitung zum
  Selbst-Nachprüfen. Diese Form altert nicht mit fremden Versionsnummern.

  Sollte je ein konkreter Vergleich gewünscht sein: nur mit eigener, aktueller
  Messung, und dabei zwischen der VORGEFUNDENEN Konfiguration und der
  Auslieferungs-Voreinstellung unterscheiden — die sind nicht dasselbe, und
  eine Aussage über die Voreinstellung braucht eine frische Umgebung. Die
  Einzelmessung vom 2026-07-28 liegt in der privaten Projektdokumentation,
  nicht hier: Ein öffentliches Repo ist kein Ort für Befunde über fremde
  Software, die niemand gegengeprüft hat.

## Bekannte Fehler

- **`folderSearch_deduplicatesOverlappingRoots` einmal rot** (2026-07-28,
  nicht reproduziert). Der Test meldete 0 statt 1 Treffer in einem
  vollständigen `swift test`; isoliert dreimal und in zwei weiteren
  vollständigen Läufen grün. Passt zur Klasse der lastabhängigen Befunde
  dieses Tages. Bei erneutem Auftreten notieren, ob der Lauf unter Fremdlast
  stand, und den Kandidatenpfad der Datei-Set-Wurzeln prüfen.

## Offene Beobachtungen (nicht reproduziert)

- **⌘⇧+Pfeiltasten ohne Wirkung auf einem anderen Mac** (Daniel-Meldung
  2026-07-29; auf Daniels M3 funktioniert es). Befund: Fastras eigenes
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
