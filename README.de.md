<p align="center">
  <img src="screenshots/app-icon.png" width="128" alt="Fastra App-Icon">
</p>

# Fastra: Nativer Texteditor für macOS

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Fastra ist ein nativer macOS-Texteditor für sicheres, visuell überprüfbares
Suchen & Ersetzen: einfach mit `*`, mächtig mit RegEx.

Die `*`-Syntax schlägt die Brücke zwischen gewöhnlichem Suchen & Ersetzen und
komplexen regulären Ausdrücken: Sie fängt Text ohne RegEx-Syntax ein, während
die Vorschau jede Änderung zeigt, bevor Fastra schreibt.

*Daher der Name: **f**acillime ad **astra**, „mit größter Leichtigkeit zu den
Sternen“. Das Sternchen (`*`) ist der Star.*

![Fastra im Light-Mode mit sichtbarem Home-Button](screenshots/editor-light.png)

## Download / Releases

Fertige Builds gibt es als DMG auf der
[Releases-Seite](https://github.com/DanielMuellerIR/fastra/releases):
DMG laden, öffnen und Fastra in den Programme-Ordner ziehen. Das DMG ist
mit einer Developer-ID signiert und von Apple notariell beglaubigt,
Gatekeeper öffnet es deshalb ohne Warnung. Fastra muss zunächst einmal per DMG
installiert werden; ab Version 1.19.1 findet **Fastra → Nach Updates suchen …**
signierte Releases direkt in der App. Voraussetzung: macOS 14+ (Apple Silicon).

## Das `*`-Sternchen: Mächtigkeit ohne Syntax

Alltägliche Umbau-Aufgaben sind in einem normalen Texteditor schlicht
unmöglich und mit RegEx überdimensioniert. Fastras Antwort ist das Sternchen:
**ein `*` fängt beliebigen Text**, und im Ersetzen-Feld verwendet man ihn
einfach wieder.

> Aus `ring, The` wird `The ring`, über eine ganze Liste hinweg:
> Suchen `*, The`, Ersetzen `The *`. Fertig. Kein RegEx, kein Nachschlagen,
> kein Risiko: Die Live-Vorschau zeigt jede Änderung, bevor sie angewendet wird.

<p align="center">
  <img src="screenshots/search-wildcards.png" width="84.2%" alt="Suchdialog mit Sternchen">
</p>

- Jedes `*` wird zur nummerierten, ziehbaren Fang-Pille. Text umstellen
  heißt: Pillen ins Ersetzen-Feld ziehen.
- `**` fängt über Zeilenumbrüche hinweg (ganze Blöcke zwischen zwei Markern).
- Das kann ein gewöhnlicher Texteditor **gar nicht**, und mit regulären
  Ausdrücken bräuchte es Syntax, die die meisten jedes Mal nachschlagen
  müssen. Mit Fastra ist es ein Tastendruck.

Und wenn eine Aufgabe wirklich die volle Kraft braucht, schaltet man den
RegEx-Modus ein: Token-Highlighting, kuratierte Vorlagen und geführte
Capture Groups.

<p align="center">
  <img src="screenshots/search-regex.png" width="84.2%" alt="Suchdialog im RegEx-Modus">
</p>

## Funktionen

- **Vorschau vor Apply**: Vorher/Nachher side-by-side für jede Operation;
  geschrieben wird erst nach Bestätigung.
- **`*`-Platzhalter-Suche** mit Capture-Semantik, ganz ohne RegEx-Kenntnisse.
- **Voller RegEx-Modus** mit farbigem Token-Highlighting und kuratierter Vorlagen-Bibliothek.
- **Capture Groups per Drag & Drop** vom Such- ins Ersetzen-Feld.
- **Bereiche**: Aktuelle Datei, alle offenen Tabs, Ordner oder eine konfigurierte
  Dateimenge im aktuellen Projekt.
- **Projekte und Git**: Lebender Dateibaum, getrennte bereitgestellte und offene
  Änderungen, nativer mehrspuriger Commit-Graph und aussagekräftige Diffs direkt
  im Editor.
- **4D-Projektunterstützung**: Vertraute `.4dm`-Farben, Vervollständigung mit
  Signaturen, Prüfungen und Alt-Doppelklick-Navigation zu Methoden und Klassen.
- **Markdown**: Lokale Live-Vorschau, Formatierungswerkzeuge, Bilder, Formeln und
  Mermaid-Diagramme direkt neben dem Quelltext.
- **Dateien side-by-side vergleichen**: Zwei gespeicherte Dateien oder offene
  Tabs lassen sich frei wählen, ein bearbeiteter Tab auch mit seiner Fassung
  auf der Platte vergleichen. Shift-Klick auf einen zweiten Tab wählt beide
  Dokumente für den Schnellweg vor.
- **Rechteckauswahl unter Soft Wrap** bleibt auf logischen Textzeilen;
  Spalten-Copy/Paste, Tippen, Löschen, Transformationen und „Spalte einfügen“
  sind jeweils eine widerrufbare Aktion.
- **Ein sichtbarer Home-Button** führt das aktuelle Fenster sicher zum
  Willkommensbildschirm zurück. Ungesicherte Arbeit wird zuerst gemeinsam
  bestätigt und erhält anschließend die normalen Speicherdialoge.
- **Light- & Dark-Mode**, natives SwiftUI/AppKit, kein Electron.
- **Lokal & privat**: Keine Konten, Telemetrie, Dokument-Uploads oder Abos. Die
  Updateprüfung kontaktiert nur Fastras signierten GitHub-Pages-Feed und sendet
  kein Hardware- oder Systemprofil.

## Projekte und Git direkt im Editor

Beim Öffnen eines Ordners zeigt Fastra einen lebenden, hierarchischen Dateibaum
mit dauerhaft sichtbarem Dateinamensfilter. Git-Repositories erkennt die App
automatisch und merkt sie für den Startbildschirm. Dabei bleiben sie ganz normale
lokale Ordner: Fastra ist zuerst ein Texteditor, nicht der Ersatz für einen
vollwertigen Git-Client.

- Die Ansicht **Änderungen** trennt bereitgestellte von noch offenen Dateien.
  Einzelne Dateien lassen sich bereitstellen, aus der Bereitstellung nehmen oder
  nach Rückfrage verwerfen; ihr Diff öffnet sich im Editor. Darüber stehen
  Commit-Nachricht und Commit-Schaltfläche. Bei Konflikten aus Merge, Rebase,
  Cherry-pick oder Revert navigiert eine kompakte Leiste im normalen Editor
  durch die Konfliktblöcke, übernimmt obere, untere oder beide Seiten mit
  nativem Undo und markiert nur den verifizierten, gespeicherten Dateistand als
  gelöst. Binäre, von Git per Dateiattribut als binär klassifizierte oder nur
  abschnittsweise geladene Dateien erhalten eine ehrliche Grenze statt einer
  ungeeigneten Textauflösung.
- Die Ansicht **Graph** zeichnet Branches und Merges als nativen mehrspurigen
  Verlauf mit Branch- und Tag-Markierungen. Commits lassen sich aufklappen;
  ein Doppelklick auf Commit oder Datei öffnet den passenden Diff-Tab.
  Text-Patches können als schreibgeschützter Side-by-side-Diff mit ausgerichteten
  Zeilen, Intra-Zeilen-Hervorhebung, Faltungen, Übersichtsleiste und
  Tastaturnavigation zwischen Änderungsblöcken erscheinen. Binäre und kombinierte
  Patches bleiben über klare Metadaten beziehungsweise den auswählbaren
  Unified-Fallback zugänglich.
- In der Projekt-Seitenleiste stehen aktueller Branch, Ahead/Behind-Stand und
  Dateistatus. Fetch kann manuell oder bei aktiver App zeitgesteuert laufen;
  Alter und Fehler bleiben sichtbar. Pull verwendet immer eine gewählte Strategie
  (Rebase, Merge oder nur Fast-Forward), prüft das Repository unmittelbar vor
  dem Start erneut und versteckt weder automatischen Stash noch Push.
- Kuratierte Aktionen decken neuen Branch, Stash/Pop, Cherry-pick, Revert sowie
  Fortsetzen und Abbrechen eines laufenden Git-Vorgangs ab. Destruktive oder
  verlaufsändernde Wege besitzen eine frische Vorprüfung und Bestätigung. Force
  Push ist ausschließlich als exakte **Force-with-Lease**-Aktion verfügbar.
  Die Git-Identität lässt sich repository-lokal oder nach gesonderter Bestätigung
  global konfigurieren.
- **Im Terminal öffnen** übergibt den Projektordner an Terminal.app, ohne in
  Fastra einen Shell-Befehl zu konstruieren oder auszuführen.

Die Git-Funktionen sind eine schlanke, asynchrone Oberfläche für das installierte
`git`-Kommando. Fehlt Git, bleiben die zugehörigen Bedienelemente unsichtbar;
bei Fehlern zeigt Fastra die tatsächliche Git-Meldung statt einer unklaren
Ersatzmeldung. Repository-Vorgänge werden über Fastra-Fenster hinweg koordiniert,
damit kollidierende Befehle nicht übereinanderlaufen.

## 4D-Projekte als echter Quellcode

Fastra behandelt 4D-Quellcode nicht als gewöhnlichen Text. `.4dm`-Methoden
erhalten ein eigenes, vertrautes Farbschema für Befehle, Keywords, Variablen,
Tabellen und Kommentare. In einem geöffneten Projekt indexiert Fastra
`Project/Sources/Methods` unabhängig von Groß-/Kleinschreibung und hebt
Projektmethoden getrennt von Prozessvariablen hervor.

Besonders nützlich beim Erkunden größerer Codebasen: **Alt-Doppelklick** auf
einen Methodennamen öffnet direkt die zugehörige Projektmethode, auf einen
Klassennamen die Klassendatei. `Function`-Definitionen in der aktuellen Klasse
springen lokal. Ist kein Ziel auffindbar, öffnet Fastra die Projektsuche mit
dem Namen, statt still nichts zu tun.

- Die Vervollständigung schlägt nach zwei eingegebenen Zeichen Befehle mit
  Syntax-Signaturen sowie Konstanten vor.
- **Dokument prüfen** bietet lokale Strukturprüfungen, validiert `.4DForm`-
  Dateien gegen ihr Schema und kann optional ein bereits installiertes tool4d
  für verbindliche Syntaxdiagnosen verwenden. Fastra bündelt oder lädt tool4d
  nicht.
- `.4DProject` und `.4DForm` öffnen als JSON, `.4DCatalog` und `.4DSettings` als
  XML. Transformationen im Text-Menü entfernen Token-Suffixe aus kanonischen
  4D-Exporten oder ergänzen Befehls-Token erneut.

## Markdown bleibt lokal

Für Markdown-Dateien lässt sich rechts neben dem Editor eine optionale,
live aktualisierte Vorschau mit dauerhaftem Splitter einblenden. Der lokale
Renderer beherrscht GitHub-Flavoured Markdown, darunter Tabellen, Aufgabenlisten,
Durchstreichungen, syntaxhervorgehobene Code-Blöcke und Links. Er zeigt außerdem
lokale Bilder, TeX-Formeln in `$…$` oder `$$…$$` und Diagramme aus
`mermaid`-Code-Blöcken. Markierter Vorschau-Text lässt sich als Klartext, HTML
oder Rich Text kopieren, sofern das Zielprogramm es unterstützt.

Eine Formatierungs-Toolbar sowie Befehle in Menü und Rechtsklickmenü decken
Hervorhebungen, Überschriften, Listen, Zitate, Links und Tabellen als normale,
widerrufbare Markdown-Edits ab. Eingefügte oder abgelegte Bilder speichert
beziehungsweise kopiert Fastra neben das gespeicherte Dokument und setzt einen
relativen Link, damit Text und Bilder gemeinsam portabel bleiben.

Fastras Vorschau ergänzt GFM um eine bewusst enge Schreibweise für sichtbare
Leerzeilen: Eine Quellzeile, die ausschließlich aus mindestens zwei normalen
ASCII-Leerzeichen besteht, erscheint als genau eine vollständig leere
Textzeile. Eine leere Zeile oder genau ein Leerzeichen verhält sich weiterhin
nach CommonMark. Die zwei Leerzeichen am Ende einer nichtleeren Zeile sowie
der Backslash bleiben normale harte Umbrüche; in Codeblöcken gilt die
Erweiterung nicht.

Text zwischen zwei Gleichheitszeichen-Paaren, etwa `==wichtig==`, erscheint mit
einem festen, ans Erscheinungsbild angepassten Textmarker-Hintergrund. Das ist
eine Fastra-Erweiterung und kein Standard-GFM; verschachteltes Markdown wird
weiterhin formatiert, Code bleibt wörtlich. Toolbar, Menü und Rechtsklickmenü
können den Textmarker setzen. Ein eigener Befehl **Harter Zeilenumbruch** fügt
genau zwei Leerzeichen am Zeilenende plus einen normalen Umbruch ein und macht
diese leicht zu vergessende Markdown-Schreibweise sichtbar.

Ein Klick in den Vorschautext scrollt den Editor an die zugehörige Quellzeile
und setzt den Cursor dorthin — auch innerhalb eines langen Absatzes, wo die
Zeile aus den Umbrüchen vor der Klickstelle bestimmt wird. Die Spalte ist eine
Näherung, weil im gerenderten Text die Markdown-Syntax fehlt. Links öffnen
weiterhin den Browser, und eine gezogene Textauswahl löst keinen Sprung aus.

Die Vorschau und ihre Render-Bibliotheken arbeiten ausschließlich lokal.
Bildpfade werden relativ zur Markdown-Datei aufgelöst; externe Bilder werden
bewusst nicht nachgeladen. Schon das Öffnen einer Datei erzeugt also keinen
stillen Netzwerkverkehr. Links öffnet Fastra nur nach einem bewussten Klick.

**Smart-Paste** wandelt formatierten Inhalt aus Browsern oder Office-Programmen
an der Cursorposition in sauberes Markdown um. Dafür nutzt Fastra das separat
installierte Kommandozeilenwerkzeug
[md-clip](https://github.com/DanielMuellerIR/md-clip); fehlt es, erklärt Fastra
die Installation.

## Mehr als Suchen & Ersetzen

Das Text-Menü bündelt Transformationen, für die man sonst zu den ganz großen
Editoren greifen muss. Die anspruchsvolleren darunter:

- **Case-Transformationen im Ersetzungsmuster** (`\U \L \u \l \E`):
  Groß-/Kleinschreibung direkt beim Ersetzen umformen.
- **Zeilen verarbeiten, die … enthalten**: Suchen & Ersetzen nur auf Zeilen
  anwenden, die einem Filter entsprechen.
- **Doppelte Zeilen verarbeiten**: Duplikate erkennen und transformieren oder
  einsammeln.
- **Treffer extrahieren**: Alle Fundstellen in ein neues Dokument ausleiten.
- **Zap Gremlins**: Unsichtbare und ungültige Zeichen aufspüren.
- **Unicode-Normalisierung** (NFC/NFD), Diakritika entfernen, gerade ⇄
  typografische Anführungszeichen, Escape-Sequenzen.
- Zeilen ausdrücklich alphabetisch auf- oder absteigend sortieren, verbinden
  und deduplizieren, harter Umbruch, Zeilennummern hinzufügen/entfernen,
  Wörter tauschen sowie JSON oder XML formatieren.
- **Transformation per Beispiel** leitet aus Vorher/Nachher-Text ein
  Platzhalter-Muster ab; eigene Suchvorlagen lassen sich speichern,
  importieren und exportieren.
- Große und binäre Dateien bleiben beherrschbar, unter anderem mit einer
  schreibgeschützten Hex-Ansicht und einem ausdrücklich aktivierten Edit-Modus.

Fastra bleibt dabei bewusst zugänglich: Es gibt Editoren mit noch mehr
Maschinerie, und mit entsprechender Lernkurve. Fastra deckt die Alltagsfälle
ab, ohne dass man ein Handbuch braucht.

Beim nächsten Start öffnet Fastra standardmäßig die zuletzt verwendeten
Projektfenster und gespeicherten Dokumente wieder. Das lässt sich unter
**Einstellungen → Start** abschalten. Inhalte ungesicherter oder unbenannter
Dokumente werden dabei bewusst nie gespeichert oder wiederhergestellt.

### XPath-Navigation für XML

`⇧⌘X` öffnet für XML-artige Dokumente (`.xml`, `.xsd`, `.xsl`, `.xslt`,
`.plist`, `.svg`-Quelltext, `.4DCatalog`, `.4DSettings`) eine schwebende
XPath-Leiste: Beim Tippen springt der Editor live zur ersten Fundstelle,
Enter/Pfeile gehen weiter, Kind-Elemente und Attribute werden aus dem
Dokument vorgeschlagen. Unterstützt wird bewusst ein kompaktes Teilset:

- absolute (`/wurzel/kind`) und relative Pfade (wirken wie `//…`),
- `//` (beliebige Tiefe) und `*` (beliebiger Elementname),
- Prädikate `[n]`, `[@attr]`, `[@attr='wert']`,
- Ziele `@attr` und `text()`.

Alles andere (Achsen, Funktionen, `..`) meldet die Leiste verständlich als
nicht unterstützt. Bei fehlerhaftem XML bleibt der letzte gültige Index
aktiv; der Fehler erscheint dezent in der Leiste.

### Ansichten, Vorschau und Spracherkennung

- Der Ansichts-Umschalter im Footer (auch im Menü „Darstellung“,
  `⌃⌘1–3`) wechselt je Datei zwischen Text, Vorschau und Hex — damit ist
  die Hex-Ansicht für jede gespeicherte Datei erreichbar.
- Bilder (PNG, JPEG, GIF, HEIC, TIFF, WebP) und PDFs öffnen in einer
  schreibgeschützten Vorschau (große Bilder werden speicherschonend
  herunterskaliert); SVG rendert standardmäßig und lässt sich als
  XML-Quelltext bearbeiten.
- Ungespeicherte Tabs ohne Endung erkennen ihre Sprache konservativ aus dem
  Inhalt (JSON, XML, HTML, Markdown, CSS, JavaScript, Shebang-Skripte); der
  Format-Chip im Footer ist zugleich ein manueller Sprachumschalter, dessen
  Wahl immer gewinnt.
- Der sichtbare Soft-Wrap-Schalter daneben speichert Ein/Aus pro effektivem
  Format und synchronisiert alle offenen Dokumente dieses Formats. Reiner
  Text, Markdown, HTML und XML starten umbrochen; Code- und
  Konfigurationsformate ohne Umbruch und mit horizontalem Scrollen. Als
  Umbruchziel sind Fensterbreite, eine appweite Seitenlinie oder eine feste
  Spalte wählbar; die Seitenlinie lässt sich unabhängig einblenden.
- Alt-Drag markiert auch bei sichtbarem Umbruch ein Rechteck über logische
  Textzeilen. **Bearbeiten → Spalte einfügen** (`⌃⌘V`) setzt Clipboard-Zeilen
  untereinander ein und füllt kurze Zielzeilen bis zur gewählten Spalte auf.

### Syntax-Highlighting

Tree-sitter-basiertes Highlighting für 26 Sprachen und Dateiformate: Bash, C,
C++, C#, CSS, Dart, Dockerfile, Go (inkl. go.mod), HTML, Java, JavaScript/JSX,
JSON, Kotlin, Lua, Markdown, Objective-C, Perl, PHP, Python, Ruby, Rust, SQL,
Swift, TOML, TypeScript/TSX und YAML. Alles andere öffnet als reiner Text.

## Voraussetzungen & Installation

- macOS 14+ (Apple Silicon)
- DMG aus den [Releases](../../releases) laden, Fastra nach `/Programme`
  ziehen, fertig.
- Ab Version 1.19.1 stehen künftige signierte Releases unter
  **Fastra → Nach Updates suchen …** bereit und werden erst nach Zustimmung installiert.

### Aus dem Quellcode bauen

```bash
cd app
./build.sh release   # Bundle landet als Fastra.app im Projekt-Root
./selftest.sh        # Unit-Tests + In-App-Selbsttests
```

Details: [Build und Tests](docs/BUILD-AND-TEST.md) ·
[Erkenntnisse zu Abhängigkeiten](app/LESSONS-LEARNED.md) ·
[AGENTS.md](AGENTS.md) (Architektur & Produktprinzipien) ·
[ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## Lizenz

[MIT](LICENSE), © 2026 Daniel Müller

Fastra bündelt und linkt Drittsoftware (Sparkle, ripgrep, PCRE2, die CodeEdit- und
tree-sitter-Komponenten, cmark-gfm sowie die Markdown-Vorschau-Assets). Deren
Lizenzen und Copyright-Vermerke sind in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) gesammelt.
