# F07: gemeinsame Grundlage für Syntaxfaltung

Stand 2026-11-08, ab 1.217.0: gemeinsamer Provider und native Linux-Bedienung.
Die eigene Mac-Oberfläche bleibt unverändert. Die ursprüngliche Machbarkeitsprobe
und der inzwischen integrierte Vertrag sind unten getrennt beschrieben.

## Ergebnis

Der bestehende Mac-Ansatz ist übertragbar: Tree-sitter liefert Syntaxbäume;
eine davon getrennte Regel bestimmt Faltbereiche, normalisiert Duplikate und
verwirft kreuzende Bereiche. 4D besitzt bereits auf dem Mac einen eigenen
lexikalischen Provider. GtkSourceView bleibt Renderer und Quelle nativer
Zeichenpositionen; seine Sprachdefinitionen sind keine austauschbaren
Tree-sitter-Grammatiken. Der generische GtkSourceRegion-Typ ist ebenfalls
kein Syntax-Faltprovider. [GtkSource-API](https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/index.html),
[Tree-sitter-Syntaxbäume und Bytepositionen](https://tree-sitter.github.io/tree-sitter/using-parsers/2-basic-parsing.html).

Die kleine [C-Probe](../../tools/linux-probes/folding/probe.c) übersetzt die
bestehenden Bereichsregeln aus `app/Sources/Fastra/CodeFolding.swift`; sie
ersetzt diese noch nicht. Unter Linux wurden die Rust-, Python- und
Markdown-Grammatiken aus den im Mac-Sprachpaket festgehaltenen Revisionen
gebaut. Auf macOS wurde dieselbe Probe gegen das tatsächlich verwendete
statische Spracharchiv aus CodeEditLanguages gelinkt. Beide Programme liefern
bytegleich dieselben Ergebnisse:

- Rust: Funktion und zwei verschachtelte Zweige, mit CRLF und Emoji im String.
- Python: Funktion und zwei eingerückte Zweige, ebenfalls CRLF und Emoji.
- Unvollständiges Rust: keine erfundenen abgeschlossenen Bereiche.
- Markdown: gültiger Baum, aber keine Bereiche unter der bisherigen generischen
  Mac-Regel. Eine vorhandene Grammatik bedeutet also noch keine Faltfunktion.

[Quellen, Artefakthashes und genaue Bytebereiche](../../tools/linux-probes/folding/feasibility.json)
binden diese vier Fälle. Runtime ist der bestehende Tree-sitter-Pin 0.25.10;
die drei Grammatik-ABIs sind 14. Der Nachweis gilt weder für alle Grammatiken
noch für eine bereits integrierte Linux-Oberfläche.

## Empfohlene gemeinsame Architektur

1. Ein versionsgebundener Sprachkatalog trennt Syntax-ID, Grammatikquelle,
   Revision, ABI, Lizenz und Faltregel. Die Swift-Paketauflösung des App-Projekts
   und die eigene Auflösung des CodeLanguages-Frameworks sind unterschiedliche
   Quellen. Der Apple-Binärcontainer wird unter Linux nicht verwendet.
2. Ein gemeinsamer reiner Plan enthält Quellrevision, Sprach-/Provideridentität
   sowie geprüfte UTF-8-Bereiche und Tiefe. GTK-Zeichenoffsets und AppKit-UTF-16
   werden ausdrücklich adaptiert; Tree-sitter-Zeilenpunkte dürfen bei CR/CRLF
   nicht ungeprüft zu GTK-Zeilen werden. Fehlerhafte, fehlende oder nicht
   unterstützte Syntax liefert keine erfundenen Bereiche.
3. Analyse läuft außerhalb des GUI-Threads mit Abbruch und begrenztem Speicher.
   Ein älterer Plan darf nach Text-, Sprach- oder Dokumentwechsel nicht angewandt
   werden. Inkrementelle Bäume sind möglich, benötigen aber genau gebundene
   Änderungen; bloß weiterverwendete Nodepositionen reichen nicht.
   [Inkrementelle Tree-sitter-Änderungen](https://tree-sitter.github.io/tree-sitter/using-parsers/3-advanced-parsing.html).
4. Der GTK-Teil verwaltet mehrere verschachtelte Bereiche je Dokument und
   zeichnet Griffe außerhalb des Textbuffers. Text-Anchors oder Paintables als
   Platzhalter würden den reinen Text-/Bytezählvertrag verletzen. Beim Öffnen
   eines Elternbereichs bleibt ein eingeklapptes Kind eingeklappt; Auswahl,
   Navigation, geteilte Ansichten und Zeilennummern brauchen eigene Abnahme.

Einrückung allein wäre ein anderes Verhalten und keine Syntaxparität. Ebenso
wäre ein pauschales „alles falten“ über sämtliche mehrzeiligen AST-Nodes zu breit:
Strings, Kommentare, Zweige und fehlerhafte Syntax müssen derselben ausdrücklich
benannten Regel folgen wie auf dem Mac.

## Getrennte Integrationsschritte

Die Integration beginnt mit dem gemeinsamen Katalog und Bereichsplan für die vorhandenen
Mac-Provider aufbauen, ohne den Editor schon umzustellen. Dieser Schritt ist inzwischen umgesetzt. Abnahme sind
identische normalisierte Bereiche aus bestehenden Mac-Referenzfällen,
Unicode/CRLF/CR, verschachtelten und fehlerhaften Eingaben sowie Abbruch- und
Stale-Revisionsfällen. Danach folgt der getrennte GTK-Zustand für mehrere
Bereiche mit echter Split-/Navigations-/Undoprüfung. Vor einer Paketintegration
sind Quellen und Lizenzen jeder aufgenommenen Grammatik zu binden.

Die ursprüngliche Probe allein lieferte noch keine Produktfunktion. Der heutige
Umfang und die weiterhin offenen Abnahmen folgen im nächsten Abschnitt.

## Integrierter Provider

`fastra-core::folding` enthält den gepinnten Katalog und die normalisierten
Bereiche. Das Feature `syntax-folding` baut die Grammatiken offline;
[Quellen und Lizenztexte](../../crates/fastra-core/native/folding/README.md)
sind pro Projekt gebunden. Der Provider liefert UTF-8-, GTK-Zeichen- und
UTF-16-Bereiche mit Tiefe. Er erfindet weder Einrückungsfalten noch
Markdown-Überschriftenbereiche. Die 4D-Regeln verwenden den bestehenden
lexikalischen Kern einschließlich der ursprünglichen Tokenklassifikation.

394 [Referenzfälle](../../crates/fastra-core/tests/fixtures/mac-folding-regions.json)
wurden direkt vom unveränderten Swift-Provider mit den tatsächlichen
Mac-Grammatiken erzeugt. Die Linux-Ergebnisse stimmen in allen drei
Positionssystemen und der Tiefe überein. Der
[Herkunftsnachweis](../../tools/linux-probes/folding/provider-witness.json)
bindet Code und Artefakt; die fensterlose Reproduktion lautet:

```sh
python3 tools/linux-probes/folding/mac-witness.py \
  --products app/.build/debug --output /tmp/fastra-fold-witness.json
cargo test --locked --offline -p fastra-core --features syntax-folding folding
```

Der derzeitige reine Plan begrenzt Eingaben auf 32 MiB, Ergebnisse auf 10.000
Bereiche, Tiefe auf 512 und Analysezeit auf drei Sekunden. Abbruch und
Grenzüberschreitung verwerfen den vollständigen Plan; Fehler werden nicht als
leere erfolgreiche Analyse ausgegeben. Der Linux-Controller ergänzt eine harte Prozessgrenze von 768 MiB Adressraum,
vier/fünf Sekunden CPU und fünf Sekunden Prozesslaufzeit. Ein einziger Worker
und ein wartender Auftrag begrenzen die Nebenläufigkeit; überholte Aufträge
werden abgebrochen. Der lokale Prozesskanal übernimmt Quellbytes mit kleinem
Protokollkopf bis zur Editorgrenze. Hostkanäle behalten ihre 8-MiB-Grenze.

## Native Linux-Bedienung

Der Controller bindet jeden Plan an Dokumentidentität, Quellgeneration, Revision
und Sprache. Geschlossene Dokumente bleiben auch dann ausgeschlossen, wenn ein
anderer Aufrufer ihre alte Instanz noch hält. Der Renderer hält eigene
Faltzustände und GTK-Marks für beide Ausschnitte. Nur äußerste geschlossene
Bereiche erhalten unsichtbare Tags; Kindzustände bleiben separat gespeichert.
Außerhalb liegende Edits verschieben ihre Marks. Betroffene Bereiche öffnen
vor der Änderung, neue Pläne behalten ausschließlich noch exakt passende
Bereiche. Ein Fehler öffnet alles.

Gutter-Pfeile und unveränderte Originalzeilennummern bleiben sichtbar. Die
Nummern verwenden die nativen Schrift-/Farbschemata; Klickaktionen gehen an den
originalen GtkSource-Zeilennummernrenderer. Der optimierte native Ziffernrenderer
zeichnet sonst auch Nummern vollständig versteckter Zeilen an derselben Stelle.
Platzhalter liegen außerhalb des Textbuffers, nehmen echte Button-Events entgegen
und verändern keine Quellzeichen. Doppelklick öffnet und markiert den Body.
Kopieren/Ausschneiden exportiert die vollständige Auswahl einschließlich
unsichtbarer Teile; native Rücknahme und die gemeinsame Split-History bleiben
zuständig. Faltbefehle schließen ihr Popup und aktivieren den gebundenen Ausschnitt.

Reproduktion: `linux/test.sh folding` und `linux/test.sh folding-guards` auf einer
isolierten Sitzung. Die zweite Prüfung verzögert ausschließlich im Debug-Test
auf dem isolierten Display eine bereits fertig berechnete Antwort; Sprachwechsel
und Schließen müssen diese alte Antwort verwerfen. Die übrigen Eingaben sind
native Maus-/Tastaturereignisse. Externe Kandidatenfenster-, vollständige
Screenreader-/Wayland- und allgemeine IME-Abnahme bleiben getrennt offen.

## Konkrete Darstellungsgrenze

Die schließende Quellzeile bleibt unter GTK separat. Ein unsichtbares Tag ersetzt
keinen absatzübergreifenden Bereich durch einen Inline-Layoutgegenstand. Ein
Text-Anchor würde stattdessen ein Quellzeichen einfügen und damit den Buffer-,
Positions- und Vorschauvertrag verletzen. Eine vollständig inline zusammengezogene
Mac-Darstellung benötigt daher eine eigene oder veränderte Textlayout-Engine.
Diese technische Grenze betrifft den Platzhalterfluss; vollständige Quellbytes,
Zeilennummern, unabhängige Ausschnitte und verschachtelte Faltzustände bleiben
gebunden. Die optische Gesamtabnahme der Linux-Anwendung ist damit weiterhin
kein abgeschlossener Punkt.
