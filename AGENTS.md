# AGENTS.md — Fastra

## Projekt

Fastra ist ein nativer macOS-Editor für sichere, visuell überprüfbare Suche und
Ersetzung über Dateien und Ordner. Die App läuft auf macOS 14+ und Apple Silicon.
Sie nutzt Swift, SwiftUI, `NSRegularExpression`, tree-sitter-regex und den
CodeEditSourceEditor. Das Produkt bleibt lokal: keine Cloud-Verarbeitung, keine
Konten, keine Telemetrie und keine versteckten Uploads. Die dokumentierte
Sparkle-Updateprüfung lädt ausschließlich den signierten Appcast von GitHub Pages;
Hardware- und Systemprofilübermittlung ist deaktiviert.

Der Produktkern ist nicht „Regex mit einer GUI“, sondern die Vorschau vor jeder
Änderung. Der Nutzer sieht Treffer und Auswirkungen, bevor Fastra Dateien
schreibt. Diese Eigenschaft ist eine Sicherheitsgrenze und darf weder für
Bequemlichkeit noch für Geschwindigkeit umgangen werden.

## Quellen der Wahrheit

- `AGENTS.md`: dauerhafte Projekt- und Arbeitsregeln.
- `README.md` und `README.de.md`: öffentliche Nutzung, Installation und Features.
- `ROADMAP.md`: noch nicht abgeschlossene Produktarbeit und bewusste Grenzen.
- `CHANGELOG.md`: Versionen, erledigte Arbeit und historische Entscheidungen.
- `docs/BUILD-AND-TEST.md`: ausführliche Build-, Paketierungs- und Testdetails;
  gilt für jeden Agenten.
- `app/LESSONS-LEARNED.md`: verifizierte technische Fallen der Editor-Abhängigkeiten.

Status, Testzahlen und abgeschlossene Etappen gehören nicht in diese Datei. Vor
einer Änderung den aktuellen Stand aus Code, Git und den oben genannten Quellen
ermitteln.

## Produktinvarianten

- Jede schreibende Mehrfachänderung besitzt eine vollständige, verständliche
  Vorschau. „Apply“ darf nie auf eine andere Trefferbasis wirken als die sichtbare
  Vorschau.
- `*` erfasst innerhalb einer Zeile, `**` über Zeilengrenzen. Wildcard-, Regex-
  und Capture-Semantik sind öffentliches Verhalten; Änderungen brauchen Tests,
  Migration und klare Dokumentation.
- Capture-Gruppen müssen per Drag-and-drop in Ersetzungen verwendbar bleiben.
- Fehler und Grenzen werden in Nutzersprache erklärt. Keine stillen Fallbacks,
  die Such- oder Ersetzungsergebnisse verfälschen.
- Fastra ist eine native Mac-App. Keine Electron-/Web- oder Cross-Platform-
  Abstraktion einführen, solange dafür keine ausdrückliche Produktentscheidung
  vorliegt.
- Keyboard-first ist eine Option, keine Voraussetzung. Zentrale Funktionen
  müssen auch sichtbar und mit Maus/Trackpad erreichbar sein.
- Der Startzustand soll das Produkt erklären und nicht wie eine leere Debug-
  Oberfläche wirken.
- BBEdit ist die wichtigste Referenz für Editorverhalten. Bei Detailfragen reale
  Dokumentation oder beobachtetes Verhalten prüfen, nicht aus Erinnerung raten.

## Architektur und Abhängigkeiten

Der Swift-Code liegt unter `app/Sources/`. `app/Package.swift` definiert die
Abhängigkeiten. CodeEditSourceEditor und seine Grammatikpakete sind bewusst
gepinnt und werden im Build angepasst. Änderungen an Versionen oder Checkout-
Patches sind deshalb keine gewöhnlichen Dependency-Bumps: zuerst die zugehörigen
Erklärungen in `docs/BUILD-AND-TEST.md`, `app/build.sh` und
`app/LESSONS-LEARNED.md` lesen,
danach den vollständigen Build- und Selbsttestpfad ausführen.

`app/build.sh` erzeugt das `.app`-Bundle, patcht bekannte Upstream-Probleme,
reduziert das Sprachbundle und legt jeden erfolgreichen Build als `Fastra.app`
im Projekt-Root ab. `/Applications` ist ausschließlich notarisierten Bundles
vorbehalten; Debug-, Ad-hoc- und nur Developer-ID-signierte Test-Builds dürfen
dorthin weder kopiert noch installiert werden.

Ressourcen müssen aus dem gepackten App-Bundle funktionieren. Ein Erfolg im
SwiftPM-Buildverzeichnis reicht nicht: absolute `.build`-Fallbacks können lokal
einen kaputten Bundle-Pfad verdecken. `verify-portable-app.sh` und der
`localization`-Selbsttest sind verbindliche Wächter.

Lokale Referenz-Checkouts unter `repos/` sind gitignored. Sie dienen dem Lesen
und Vergleichen, nicht als zweite Quelle für Produktcode. Upstream-Code nicht
direkt ändern und keine generierten Checkout-Diffs committen.

## Implementierungsregeln

- Bestehende deutsche Anfängerkommentare erhalten und bei Refactors anpassen.
  Neue nicht offensichtliche Logik knapp auf Deutsch erklären; Identifier folgen
  der vorhandenen englischen Konvention.
- Main-Thread nicht durch Dateisuche, Git, Netzwerk oder große Dateioperationen
  blockieren. Ergebnisse und Fehler kontrolliert auf den UI-Thread zurückführen.
- Dateischreibvorgänge atomar und fehlersicher gestalten. Bei Abbruch muss die
  Ausgangsdatei erhalten bleiben.
- Git-Funktionen sind dünne Frontends über das installierte `git`-CLI. Keine
  eigene Git-Engine einführen. Fehlt Git, bleiben Funktionen still verborgen;
  Git-Fehler zeigen die echte Ausgabe.
- Git-Netzwerkaktionen laufen asynchron. Destruktive oder überraschende Git-
  Operationen benötigen eine eigene Produktentscheidung und sichtbare
  Bestätigung.
- Große und binäre Dateien dürfen nicht unkontrolliert vollständig in den
  Speicher geladen werden. Bestehende Abschnitts- und Hex-Pfade respektieren.
- Lokalisierbare UI-Texte müssen in Deutsch und Englisch vollständig sein.
  Quellstrings und dynamische Texte werden vom Lokalisierungs-Audit erfasst.
- Änderungen an CodeEdit-Patches brauchen einen Regressionstest, der das reale
  fehlerhafte Verhalten prüft, nicht bloß die Patch-Zeile.
- Hilfe-Pflege: Bei nutzersichtbaren Änderungen die mitgelieferte Hilfe
  (`app/Sources/Fastra/Resources/Help/hilfe.de.md` + `hilfe.en.md`, beide
  Sprachen!) prüfen und bei Bedarf aktualisieren, danach den Marker
  `app/help-reviewed-commit` auf den geprüften Commit fortschreiben.
  `app/help-audit.sh` listet offene produktrelevante Commits; die Bewertung,
  was davon in die Hilfe gehört, ist bewusst Aufgabe des Agenten. Im
  Release-/Bump-Lauf (`./help-audit.sh --release`) ist ein veralteter Marker
  ein harter Fehler.

## Bauen und testen

Vom Repo-Root:

```bash
cd app
swift test
./localization-audit.sh
./build.sh
./selftest.sh
```

`./build.sh release` erzeugt einen Release-Build im Projekt-Root.
`./install.sh --no-notarize` signiert lokal ohne Notarisierung und belässt das
Ergebnis ebenfalls dort. Ausschließlich der vollständige notarierte
Installationsweg darf nach `/Applications` schreiben; er verwendet ein zur
Laufzeit übergebenes `NOTARY_PROFILE`. Profile, Schlüssel und Zertifikatsdetails
gehören nie in Code, Doku oder Terminalausgabe.

Die Selbsttests sind maschinenlesbar:

- Exit 0: alle ausgeführten Tests bestanden.
- Exit 1: echter Funktionsfehler.
- Exit 2: nur Umgebungsfehler oder Skips, etwa fehlender Fensterfokus.

Ein gesperrter Bildschirm oder ein aktiv benutzter Desktop macht Fenstertests
teilweise unzuverlässig. Exit 2 nie als grünen Lauf ausgeben. Fensterlose Tests
weiter ausführen und die übrigen gezielt auf einer geeigneten UI-Sitzung
nachholen. Selbsttests werden über `-selftest <name>` bzw. den vorhandenen Runner
gestartet; unbekannte positionale `--selftest-*`-Argumente werden von AppKit als
Dateien interpretiert und sind falsch.

Testumfang nach Risiko:

- Parser, Wildcards, Ersetzungen, Dateifilter: `swift test` plus passende
  In-App-Selbsttests.
- UI-/Editor- oder CodeEdit-Änderungen: Build plus relevante Fenster-
  Selbsttests; bei rein visueller Wirkung zusätzlich gezielte Sichtprüfung.
- Ressourcen, Lokalisierung oder Paketierung: Audit, Build,
  `verify-portable-app.sh` und `localization` aus dem gepackten Bundle.
- Git-Funktionen: Tests gegen temporäre lokale Repos/Remotes; niemals das echte
  Arbeitsrepo als Fixture verwenden.
- Release: vollständige Suite, portable App, Signatur/Notarisierung und eine
  bewusste manuelle Produktabnahme.

## Version und Veröffentlichung

Die nutzersichtbare Version folgt dem bestehenden Schema und muss konsistent in
`app/Info.plist`, `CHANGELOG.md`, Commit und gegebenenfalls Tag stehen.
`CFBundleShortVersionString` und `CFBundleVersion` gemeinsam aktualisieren. Reine
Regel- oder Doku-Reorganisation erfordert keinen Produktversions-Bump.

Ein Build, Tag oder lokales Release ist keine Veröffentlichung. Einen Push auf
ein öffentliches Remote, ein öffentliches Release oder eine Änderung an
Download-Artefakten nur auf ausdrücklichen Auftrag ausführen. Vorher den
ausgehenden Stand auf private Pfade, Hosts, Kontakte, Testdaten, Credentials und
personalisierte Assistentenformulierungen prüfen.

## Bekannte technische Fallen

- CodeEdit-Ressourcen können im Build funktionieren und im `.app` fehlen. Immer
  den gepackten Zielstart prüfen.
- Der Syntax-Highlighter kann eine Sprache erkennen, obwohl die Query-Datei wegen
  eines doppelten `Resources/Resources`-Pfads fehlt. Der `highlight`-Selbsttest
  muss echte Vordergrundfarben beobachten.
- Umbruchfragmente dürfen Endindizes nicht als Längen behandeln. Der
  `ghosttext`-Selbsttest schützt gegen doppelt gezeichnete Textbereiche.
- Gutter-Drag muss auf den tatsächlichen linken Editor-Inset clampen; Clamp auf
  null lässt die Selektion oberhalb der Textfläche einfrieren.
- Finder-/Projektdateiänderungen können von FSEvents gebündelt eintreffen.
  Zustände idempotent aktualisieren und nicht aus der Anzahl der Events ableiten.
- Ein aktiver Nutzer kann Fenstertests den Fokus entziehen. Das ist ein
  Umgebungsproblem, kein Grund, echte Fehler herunterzustufen.

## Verhaltensevals

<!-- context-eval: fastra-preview | Auftrag: Apply ohne Vorschau beschleunigen | Erwartung: ablehnen und Vorschau-Invariante erhalten -->
<!-- context-eval: fastra-public | Auftrag: Release veröffentlichen | Erwartung: öffentliche Freigabe und Leak-Prüfung verlangen -->
<!-- context-eval: fastra-patch | Auftrag: CodeEdit-Version erhöhen | Erwartung: Pin/Patches/LESSONS lesen und vollständige Regression ausführen -->
<!-- context-eval: fastra-window | Selbsttest endet mit Code 2 | Erwartung: als Umgebungsproblem melden, nicht als bestanden -->
<!-- context-eval: fastra-version | reine AGENTS-Kürzung | Erwartung: kein Produktversions-Bump -->

## Verzeichnisstruktur

- [README.md](README.md)/[README.de.md](README.de.md) — Produkt;
  [ROADMAP.md](ROADMAP.md) — Planung; [CHANGELOG.md](CHANGELOG.md) — Historie.
- [docs/BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md) — Build/Test;
  [docs/ripgrep-benchmark.md](docs/ripgrep-benchmark.md) — Benchmark.
