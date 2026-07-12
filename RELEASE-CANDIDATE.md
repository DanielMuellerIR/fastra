# Fastra v1.12.0 — Release-Kandidaten-Bericht

**Stand:** 2026-07-12

**Kandidat:** v1.12.0 (Build 30)

**Technischer Status:** release-fähiger Kandidat

**Öffentliche Veröffentlichung:** nicht freigegeben

## Ergebnis

Alle für diesen Ausbau beauftragten Funktionen sind implementiert, integriert,
automatisch geprüft und intern gesichert. Der Release-Build ist mit Developer ID
signiert, von Apple notarisiert, mit Ticket versehen und als v1.12.0 unter
`/Applications/Fastra.app` installiert.

Das einzige verbleibende Release-Gate ist die bewusste manuelle Abnahme und die
anschließende Veröffentlichungsentscheidung. Es besteht kein bekannter
technischer Release-Blocker. Insbesondere ist der frühere Ghosttext-Fehler seit
v1.6.1, Commit `8656f56`, behoben und durch den Selbsttest `ghosttext`
abgesichert.

## Enthaltener Ausbau

- Globale, persistente UI-Skalierung über ⌘+, ⌘− und ⌘0 für SwiftUI-, AppKit-
  und Editor-Oberflächen.
- Rekursiv live aktualisierter Projektbaum mit Kontextaktionen und gespeichertem
  Aufklappzustand.
- Lokale Branch-Auswahl sowie sichtbares Erfolgsfeedback für Push, Pull und
  Fetch; Stage/Unstage einzelner Dateien bleibt integriert.
- Native, seitenweise Hex+ASCII-Ansicht für Binärdateien.
- Rectangle Selection per ALT-Spalten-Drag und Fokus-Dimmen des Editor-Gutters.
- Speicherbegrenzte 256-KiB-Abschnittsansicht für Textdateien über 32 MiB.
- Vollständiger, zeilenweise ausgerichteter Side-by-side-Dokument-Diff.
- Extrahieren-Dialog mit Trennzeichen, Ziel, Quoting, Deduplizierung und
  optionaler Ersetzung.
- Projekt-Scope mit persistenten Datei-Sets, Dateitypfilter und Glob-
  Ausschlüssen.
- Vollständige englische Oberfläche zusätzlich zu Deutsch, einschließlich
  AppKit-Dialogen, Tooltips, Statusmeldungen, Vorlagen, Regex-Hilfen,
  Erststart-Demo und Finder-Metadaten.

## Automatische Verifikation

| Prüfung | Ergebnis |
|---|---:|
| `swift test` | 728 Tests in 6 Suites, 0 Fehler |
| `./selftest.sh` | 24/24, 0 Funktionsfehler, 0 Umgebungsfehler |
| `./localization-audit.sh` | 178 SwiftUI-Schlüssel, 498 englische Einträge, 0 Lücken |
| Debug-Build | erfolgreich |
| Release-Build | erfolgreich |
| Developer-ID-Signatur | gültig |
| Apple-Notarisierung | akzeptiert |
| Stapler-Validierung | erfolgreich |
| Gatekeeper `spctl` | `accepted`, Notarized Developer ID |
| Installierte Version | v1.12.0 |

Die Selbsttest-Suite deckt unter anderem echte Fenster, Suchfelder,
CodeEditSourceEditor, Syntaxfarben, Treffer-Sprünge, Ghosttext, Ersetzen,
Pillen-Drop, Rectangle Selection, Gutter-Dimmen, Projekt-Suche, Git-Aktionen
gegen temporäre Remotes, Hex-/Großdatei-Routing und die gepackten
Lokalisierungstabellen ab.

Zusätzlich wurde das Suchfenster mit erzwungener englischer macOS-Sprache als
echtes App-Fenster visuell geprüft. Dabei wurde ein zunächst fehlender
Haupt-Bundle-Kopiervorgang entdeckt und korrigiert; die Wiederholungsprüfung
zeigte die statischen und dynamischen Texte vollständig auf Englisch.

## Manuelle Abnahme vor öffentlicher Veröffentlichung

Diese Punkte sind trotz grüner Automatik bewusst von Hand zu prüfen:

- [ ] ⌘+/−/0 bei Minimal-, Normal- und Maximalstufe in Editor, Seitenleiste,
  Dateibaum, Änderungen/Graph, Tabs, Footer, Suchfenster und Dialogen; danach
  App-Neustart zur Persistenzprüfung.
- [ ] Externe Datei-/Ordneränderungen sowie Neu, Umbenennen und Papierkorb im
  Projektbaum mit einem entbehrlichen Testprojekt.
- [ ] Branch-Auswahl, Push, Pull und Fetch mit einem echten privaten Test-Repo;
  Erfolgsbanner und echte Fehlerausgabe prüfen.
- [ ] Binärdatei, Datei über 32 MiB, ALT-Spalten-Drag und Gutter-Dimmen mit zwei
  Dokumentfenstern visuell bedienen.
- [ ] Mehrzeilige Ersetzung im Side-by-side-Diff prüfen; danach Extraktion in
  neues Dokument und Zwischenablage mit mehreren Trenn-/Quoting-Varianten.
- [ ] Projekt-Datei-Set, Filter und Ausschlüsse anlegen, App neu starten und
  Persistenz sowie Suchergebnis prüfen.
- [ ] Ein vollständiger deutscher und englischer Oberflächen-Rundgang nach
  Änderung der bevorzugten App-Sprache in macOS.
- [ ] Abschließend explizit entscheiden: GitHub-Push und öffentliche
  Veröffentlichung freigeben oder weiter zurückhalten.

## Bewusste Grenzen

- Hex- und Großdateiansicht sind read-only. Hex-Bearbeitung ist kein Bestandteil
  dieses Kandidaten.
- Der vollständige Side-by-side-Diff gilt für den aktiven Datei-Scope. In
  Mehrdatei-Scopes bleibt der Button deaktiviert; dort schützt die vorhandene
  Treffer-/Apply-Vorschau.
- Bei absichtlich gekappten Mehrdatei-Trefferlisten extrahiert der Dialog die
  materialisierten Treffer. Die Oberfläche weist auf die Kappung hin.
- Projekt-Ausschlüsse unterstützen die dokumentierten Globs `*`, `?` und `**`;
  Datei-Set-Pfade dürfen die Projektwurzel nicht verlassen.
- Die Sprache folgt der macOS-Sprachreihenfolge; ein eigener In-App-
  Sprachschalter ist nicht vorgesehen.
- Weiterhin offene, nicht zu diesem Auftrag gehörende Ausbaustufen stehen in
  `ROADMAP.md`, darunter Vorlagen-Editor, Inline-Diff, optionales ripgrep,
  Hex-Edit-Modus und Cross-Platform-Prüfung.

## Freigabe-Checkliste

- [x] Funktionsumfang dieses Auftrags implementiert
- [x] Dokumentation und Handoff-Korrektur aktuell
- [x] Unit-/Integrations-/In-App-Tests grün
- [x] Release-Build signiert und notarisiert
- [x] Interne Commits/Tags auf dem Backup-Remote erfolgt
- [x] Kein GitHub-Push und kein öffentlicher Release erfolgt
- [ ] Manuelle Produktabnahme abgeschlossen
- [ ] Explizite Freigabe für GitHub-Push/Release erteilt
