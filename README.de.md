<p align="center">
  <img src="screenshots/app-icon.png" width="128" alt="Fastra App-Icon">
</p>

# Fastra

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Fastra ist ein nativer Texteditor für macOS mit Suchen-&-Ersetzen-Fähigkeiten,
die kein anderer Editor bietet: So einfach wie Tippen, so mächtig wie reguläre
Ausdrücke, und man sieht immer exakt, was sich ändern wird, bevor ein einziges
Zeichen angefasst wird.

*Der Name ist Programm: **f**acillime **ad astra**, „aufs Leichteste zu den
Sternen". Das Sternchen (`*`) ist der Star.*

![Fastra im Light-Mode](screenshots/editor-light.png)

## Download / Releases

Fertige Builds gibt es als DMG auf der
[Releases-Seite](https://github.com/DanielMuellerIR/fastra/releases):
DMG laden, öffnen und Fastra in den Programme-Ordner ziehen. Das DMG ist
mit einer Developer-ID signiert und von Apple notariell beglaubigt,
Gatekeeper öffnet es deshalb ohne Warnung. Voraussetzung: macOS 14+ (Apple Silicon).

## Das `*`-Sternchen: Mächtigkeit ohne Syntax

Alltägliche Umbau-Aufgaben sind in einem normalen Texteditor schlicht
unmöglich und mit RegEx überdimensioniert. Fastras Antwort ist das Sternchen:
**ein `*` fängt beliebigen Text**, und im Ersetzen-Feld verwendet man ihn
einfach wieder.

> Aus `ring, The` wird `The ring`, über eine ganze Liste hinweg:
> Suchen `*, The`, Ersetzen `The *`. Fertig. Kein RegEx, kein Nachschlagen,
> kein Risiko: Die Live-Vorschau zeigt jede Änderung, bevor sie angewendet wird.

![Suchdialog mit Sternchen](screenshots/search-wildcards.png)

- Jedes `*` wird zur nummerierten, ziehbaren Fang-Pille. Text umstellen
  heißt: Pillen ins Ersetzen-Feld ziehen.
- `**` fängt über Zeilenumbrüche hinweg (ganze Blöcke zwischen zwei Markern).
- Das kann ein gewöhnlicher Texteditor **gar nicht**, und mit regulären
  Ausdrücken bräuchte es Syntax, die die meisten jedes Mal nachschlagen
  müssen. Mit Fastra ist es ein Tastendruck.

Und wenn eine Aufgabe wirklich die volle Kraft braucht, schaltet man den
RegEx-Modus ein: Token-Highlighting, kuratierte Vorlagen und geführte
Capture Groups.

![Suchdialog im RegEx-Modus](screenshots/search-regex.png)

## Funktionen

- **Vorschau vor Apply**: Vorher/Nachher side-by-side für jede Operation;
  geschrieben wird erst nach Bestätigung.
- **`*`-Platzhalter-Suche** mit Capture-Semantik, ganz ohne RegEx-Kenntnisse.
- **Voller RegEx-Modus** mit farbigem Token-Highlighting und kuratierter Vorlagen-Bibliothek.
- **Capture Groups per Drag & Drop** vom Such- ins Ersetzen-Feld.
- **Scopes**: Aktuelle Datei, alle offenen Tabs oder ganze Ordner.
- **Ein gut gefülltes Text-Menü** (siehe unten).
- **Markdown-Vorschau** und Smart-Paste, das aus formatierter Zwischenablage
  Markdown macht.
- **Light- & Dark-Mode**, natives SwiftUI/AppKit, kein Electron.
- **Lokal & privat**: Kein Cloud-Kontakt, keine Telemetrie, kein Abo.

![Fastra im Dark-Mode](screenshots/editor-dark.png)

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
- Zeilen sortieren/verbinden/deduplizieren, harter Umbruch, Zeilennummern
  hinzufügen/entfernen, Wörter tauschen.

Fastra bleibt dabei bewusst zugänglich: Es gibt Editoren mit noch mehr
Maschinerie, und mit entsprechender Lernkurve. Fastra deckt die Alltagsfälle
ab, ohne dass man ein Handbuch braucht.

### Syntax-Highlighting

Tree-sitter-basiertes Highlighting für 26 Sprachen und Dateiformate: Bash, C,
C++, C#, CSS, Dart, Dockerfile, Go (inkl. go.mod), HTML, Java, JavaScript/JSX,
JSON, Kotlin, Lua, Markdown, Objective-C, Perl, PHP, Python, Ruby, Rust, SQL,
Swift, TOML, TypeScript/TSX und YAML. Alles andere öffnet als reiner Text.

## Voraussetzungen & Installation

- macOS 14+ (Apple Silicon)
- DMG aus den [Releases](../../releases) laden, Fastra nach `/Programme`
  ziehen, fertig.

### Aus dem Quellcode bauen

```bash
cd app
./build.sh release   # Bundle landet in app/dist/
./selftest.sh        # Unit-Tests + In-App-Selbsttests
```

Details: [app/README.md](app/README.md) · [CLAUDE.md](CLAUDE.md) (Build, Tests, QA)
· [AGENTS.md](AGENTS.md) (Architektur & Produktprinzipien) ·
[ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## Lizenz

[MIT](LICENSE), © 2026 Daniel Müller
