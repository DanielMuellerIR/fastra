# AGENTS.md — Fastra

## Projekt

Fastra ist ein nativer macOS-Editor für sichere, visuell überprüfbare Suche und
Ersetzung über Dateien und Ordner. Die App läuft auf macOS 14+ und Apple Silicon.
Sie nutzt Swift, SwiftUI, `NSRegularExpression`, tree-sitter-regex und den
CodeEditSourceEditor. Das Produkt bleibt lokal: keine Cloud-Verarbeitung, keine
Konten, keine Telemetrie und keine versteckten Uploads. Die dokumentierte
Sparkle-Updateprüfung auf macOS lädt ausschließlich den signierten Appcast von
GitHub Pages. Aktive Linux-Benutzerinstallationen prüfen stabile GitHub-Releases
und installieren passende, vollständig geprüfte Pakete erst nach Freigabe.
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

- Die Linux-Oberfläche soll der aktuellen Mac-Version optisch und im Aufbau
  entsprechen. Farben, Typografie, Abstände, Tabs, Seitenleiste und Suchfenster
  anhand gleicher Testdaten direkt vergleichen. Plattformunterschiede nur bei
  konkreten technischen Grenzen oder unverhältnismäßigem Aufwand akzeptieren
  und einzeln begründen; ein Toolkit-Standardlayout ist kein Ersatz.
  Die Linux-Titelleisten verwenden die üblichen Fenstersymbole rechts. Das
  Fastra-Hauptmenü sitzt direkt links daneben.
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

`app/build.sh` patcht die Abhängigkeiten und legt `Fastra.app` im Projekt-Root
ab. Vor Selbst- und GUI-Tests am Bundle diesen Build ausführen. Für
Installationstests, Finder-/LaunchServices-Aufrufe und macOS-Berechtigungen
gilt der notarisierte `./install.sh`-Pfad. `/Applications` ist notarisierten
Bundles vorbehalten.

Ressourcen über `AppResources.bundle` laden. Absolute SwiftPM-`.build`-Pfade
können fehlende Bundle-Ressourcen auf dem Build-Mac verdecken.
`verify-portable-app.sh` und der `localization`-Selbsttest sind Pflicht.
Portabilität am betroffenen Funktionspfad des gepackten Bundles bei
ausgeblendeten lokalen Build-Ressourcen prüfen.

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
  fehlerhafte Verhalten prüft, nicht bloß die Patch-Zeile. Jeder Checkout-Patch
  prüft zusätzlich unmittelbar nach dem Anwenden selbst, ob er gegriffen hat, und
  bricht den Build sonst mit einer Fehlermeldung ab. Ohne diese Selbstprüfung
  verschwindet ein Fix lautlos, sobald Upstream die gepatchte Stelle umschreibt.
- Hilfe-Pflege: Bei nutzersichtbaren Änderungen die mitgelieferte Hilfe
  (`app/Sources/Fastra/Resources/Help/hilfe.de.md` + `hilfe.en.md`, beide
  Sprachen!) prüfen und bei Bedarf aktualisieren, danach den Marker
  `app/help-reviewed-commit` auf den geprüften Commit fortschreiben.
  `app/help-audit.sh` listet offene produktrelevante Commits; die Bewertung,
  was davon in die Hilfe gehört, ist bewusst Aufgabe des Agenten. Im
  Release-/Bump-Lauf (`./help-audit.sh --release`) ist ein veralteter Marker
  ein harter Fehler.
- README-Screenshots müssen die Sprache der jeweiligen README tatsächlich in
  der gestarteten App verwenden: `README.md` referenziert `.en.png` aus der
  englischen Lokalisierung, `README.de.md` die deutschen Aufnahmen. Bei
  UI-Änderungen nur die betroffenen Screenshot-Paare neu erzeugen und beide
  Sprachfassungen visuell prüfen.

## Bauen und testen

Vor Build, Installation oder Tests den passenden Abschnitt der
[Arbeitsreferenz](docs/AGENT-REFERENCE.md#bauen-und-testen) und bei Bedarf
[BUILD-AND-TEST.md](docs/BUILD-AND-TEST.md) lesen. Selbsttests mit Exit 2
belegen ein Umgebungsproblem oder übersprungene Prüfungen. Für echte
Fenstertests eine geeignete GUI-Sitzung verwenden.

Für ein lokales Fastra-Update oder einen vorbereiteten Fastra-Test ist keine
erneute Rückfrage zum regulären Beenden oder zur nötigen Fokusübernahme nötig,
wenn in keinem Fastra-Fenster ungesicherte Änderungen vorliegen. Das gilt für
alle Tabs, auch unbenannte Dokumente und Hex-Änderungen. Bei einem
Sichern-Dialog anhalten und den Nutzer entscheiden lassen.
[Beenden und laufende Instanzen](docs/BUILD-AND-TEST.md#beenden-und-laufende-instanzen)
beschreibt die Prüfung und die Installationsgrenze.

## Version und Veröffentlichung

Funktionsänderungen im selben Commit in `app/Info.plist` und `CHANGELOG.md`
versionieren. Reine Doku, Regeln, Tests und Umbauten ohne Verhaltensänderung
brauchen keinen Produktversions-Bump. Commits veröffentlichungsfähig halten.
Für öffentliche Pushes und Releases ist eine ausdrückliche Freigabe nötig.
[Versions- und Veröffentlichungsregeln](docs/AGENT-REFERENCE.md#version-und-veröffentlichung)
vor Releases und Versionsänderungen lesen.

## Bekannte technische Fallen

Vor Änderungen an Editor, Suche, Dateizugriff, Fenstern oder Selbsttests die
passenden [technischen Fallen](docs/AGENT-REFERENCE.md#bekannte-technische-fallen)
prüfen. Für Editor-Abhängigkeiten zusätzlich `app/LESSONS-LEARNED.md` lesen.

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
