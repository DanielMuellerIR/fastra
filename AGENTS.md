# Fastra — Projektstand & Wissen (agent-agnostisch)

**Aktuelle Version: v1.3.0** — Details und vollständige Historie in [`CHANGELOG.md`](CHANGELOG.md).

Dieses Dokument hält **nur, was sich nicht aus dem Code ablesen lässt**: Vision,
Konventionen, Produktprinzipien und Pointer auf die übrigen Wissens-Schichten. Bewusst
agent-agnostisch — jeder Coding-Agent soll hier einsteigen können. Was woanders
ablesbar ist, gehört nicht hierher:

| Schicht | Heimat |
|---|---|
| Roadmap (v1.0-Funktionsumfang + v1.1+) | [`ROADMAP.md`](ROADMAP.md) |
| Build · Test · QA | [`CLAUDE.md`](CLAUDE.md) |
| Vollständige Versions-Historie | [`CHANGELOG.md`](CHANGELOG.md) |
| Implementation / Patterns / Stack-Details | der Code (`app/`) |

---

## Typ & Zweck

- **Typ:** GUI-App
- **Zweck:** Natives macOS-Suchen-&-Ersetzen mit Vorher/Nachher-Diff-Vorschau —
  einfach mit `*`-Platzhaltern, mächtig mit regulären Ausdrücken.
- **Plattform:** macOS 14+, Apple Silicon

## Was ist Fastra?

Nativer macOS-Editor für Suchen & Ersetzen. Das zentrale Versprechen:
**Du siehst exakt, was passieren wird, bevor eine einzige Datei verändert wird.**

- **`*`-Platzhalter-Suche:** ein Sternchen fängt beliebigen Text innerhalb einer
  Zeile, `**` über Zeilengrenzen hinweg — Capture-Group-Mächtigkeit ohne
  RegEx-Syntax. Für alles darüber hinaus: voller RegEx-Modus.
- Side-by-Side-Diff zeigt betroffene Zeilen pro Datei vor dem Ausführen
- Capture Groups lassen sich per Drag & Drop vom Such- ins Ersetzungsfeld ziehen
- Token im Suchausdruck werden farblich hervorgehoben (Quantifier, Anker, Zeichenklassen)
- Lokal, kein Cloud-Kontakt, kein Abo

Der Name: **Fastra** = *facillime ad astra* („aufs Leichteste zu den Sternen") —
das Sternchen `*` ist Programm.

---

## Brand & Visuelles

- **Name & Motto:** „Fastra", Motto *facillime ad astra*. Der englische Nebensinn
  „fast" zahlt aufs Produkt ein.
- **Logo & Icon:** Leuchtende Sonne mit Asterisk im stilisierten Nachthimmel
  (Apple-Squircle). Master + `.icns` unter `app/`.
- **Tone of Voice:** Professionell. Humor sehr dezent und in der normalen UI nicht
  sichtbar — nur im Über-Dialog (Motto).
- **Visual Language:**
  - System-Schrift (`-apple-system`) für UI, Monospace ausschließlich für
    Editor-Inhalt, Diff, RegEx-Tokens, Pfade.
  - Light- und Dark-Mode werden unterstützt (folgt der System-Einstellung,
    umschaltbar in den Einstellungen).
  - Tab-Leiste im Browser-Stil in der Titelzeile (via `NSWindow`-Tabbing).
  - **Kein eigenes Akzentfarben-System.** System-Accent reicht.

---

## Tech-Stack

| Komponente | Entscheidung |
|---|---|
| Sprache / UI | Swift / SwiftUI, macOS 14+ |
| Architektur | **Apple Silicon (arm64) only** — kein Intel/x86_64 (Entscheidung 2026-07-08) |
| Editor | CodeEditSourceEditor (v0.15.2 gepinnt) |
| Sprach-Highlighting | CodeEditLanguages — exotische Grammatiken ausgeschnitten (build.sh 4g), Bundle ~53 MB statt 489 MB; Details → [CLAUDE.md](CLAUDE.md) „Bundle-Größe" |
| RegEx-Engine | NSRegularExpression (kein ripgrep) |
| RegEx-Token-Highlighting | tree-sitter-regex via SwiftTreeSitter |
| Build | `./build.sh` in `app/` (kapselt Xcode-Toolchain + Patches) |

---

## Nicht-verhandelbare DNA

1. **`*`-Platzhalter-Suche** — die einfache Mächtigkeit, die kein normaler Editor bietet
2. **Drag & Drop von Capture Groups** (Find → Replace) — Kernmechanik
3. **Visual Token Highlighting** im Suchfeld (Farben pro Token-Typ)
4. **Native macOS** — kein Electron, kein Cross-Platform
5. **Vorschau vor Apply** — jede destruktive Operation ist vorher eindeutig sichtbar
6. **Lokal und privat by default** — kein Cloud-Kontakt, keine Telemetrie

---

## Produktprinzipien (Reihenfolge = Verbindlichkeit)

1. Vorschau vor Aktion (inviolable)
2. Native Mac, kein Kompromiss (inviolable)
3. Lokal und privat by default (inviolable)
4. Bekanntes ergänzen statt ersetzen — Coexistence mit IDE (strong preference)
5. Ehrlich über Grenzen (strong preference)

**Ergänzende UX-Leitplanken:**
- **Low Friction:** Möglichst wenig Tipparbeit für Replace-Muster — `*`-Syntax,
  Drag & Drop und sichtbare Hilfen statt Syntax-Auswendiglernen.
- **Native Feel:** System-Fonts, Window-Chrome, Standard-Shortcuts. Die App soll
  nicht wie ein Web-Tool aussehen, das auf den Mac portiert wurde.
- **Preview-Garantie:** Vor jeder destruktiven Aktion eindeutige Vorschau.

---

## Wettbewerbs-Positionierung

Vergleich gegen die beiden Editoren, gegen die wir am häufigsten gemessen werden.
Ehrliche Einschätzung; ⚠️ = teilweise/mit Einschränkung. Stand 2026-05.

| Feature | BBEdit | VS Code | Fastra |
|---|---|---|---|
| Native macOS (kein Electron) | ✅ | ❌ | ✅ |
| `*`-Platzhalter mit Capture-Semantik | ❌ | ❌ | ✅ — **Alleinstellung** |
| RegEx-Token-Highlighting im Find-Feld | ✅ | ⚠️ rudimentär | ✅ |
| Kuratierte RegEx-Vorlagen-Liste | ✅ (mit Edit) | ⚠️ via Snippets | ✅ |
| Geführte Capture-Group-Definition am Treffer | ❌ | ❌ | ✅ — **Alleinstellung** |
| **Drag & Drop von Capture Groups ins Replace** | ❌ | ❌ | ✅ — **Alleinstellung** |
| Markdown-Vorschau out-of-the-box | ❌ (extern) | ✅ | ✅ |
| **Markdown Smart-Paste (formatiert → MD)** | ❌ | ❌ | ✅ — **Alleinstellung** (via md-clip) |
| Vorschau vor Apply als Kern-Prinzip | ⚠️ teilweise | ❌ | ✅ |

**Erkenntnis für Roadmap und Marketing:** Die Alleinstellungen (`*`-Platzhalter,
geführte Capture-Group-Definition, Drag & Drop von Capture Groups, Markdown
Smart-Paste) haben bei Feature-Konflikten Vorrang. Alles andere ist
„Pflichtprogramm, damit man uns ernst nimmt" und nicht Differenzierung.

---

## Daten-Fluss

1. Find-Eingabe → `tree-sitter-regex` parst → farbige Tokens + Capture-Group-Markierungen im Find-Feld.
2. Nutzer zieht Capture Group ins Replace-Feld → `$N` wird eingefügt (im Platzhalter-Modus zählt jedes `*` bzw. jeder `**`-Lauf als eine Gruppe).
3. Nutzer klickt **Preview** → Suche läuft auf aktiver Datei (oder Folder-Scope) → Side-by-side Diff.
4. Nutzer klickt **Apply** → Warn-Dialog bei großen Dateien → Ersetzung wird geschrieben.

---

## Hinweise zur Zusammenarbeit

- Planungsentscheidungen in projektsichtbare Markdown-Dateien dokumentieren
  (AGENTS.md, CHANGELOG.md), nicht in agent-spezifisches Memory.
- Bei großen Tasks vor dem Loslegen kurz den Plan skizzieren, dann ausführen.
- **Varianten-Naming:** Varianten der App **immer** als `Variante-1`, `Variante-2`,
  `Variante-3` — niemals als `V1/V2/V3`. Die Kurzform `v1.0`, `v2.0` ist
  ausschließlich für Versionsnummern reserviert.
- **Referenz-Editor bei UI-Zweifeln: BBEdit.** Wenn unklar ist, wie sich eine
  Komponente verhalten oder aussehen soll, ist BBEdit der erste Vergleichspunkt —
  nicht VS Code, nicht Sublime Text. Bei einer offenen UX-/Verhaltensfrage nicht
  raten, sondern BBEdit real konsultieren (Handbuch, bei Bedarf live testen).
  Verhalten übernehmen, wenn der Aufwand vertretbar ist.

### Kontext-Quellen für den Agenten (`repos/`)

Statt fremde Library-Doku zu beschreiben, liegt der **Source-Code** der genutzten
Fremd-Frameworks lokal als Grep-Referenz — der Agent grept im echten Code, statt
aus veralteter Doku zu halluzinieren.

- **Ablage:** `app/repos/github.com/<org>/<repo>/`. Klonen per
  `git clone --depth 1`. `repos/` ist in `.gitignore` — Fremd-Code, nicht mitversioniert.
- **Empfohlene Klone:**
  - `CodeEditApp/CodeEditSourceEditor` — gepinnt auf `424453d` (gebaute Revision).
    Find-Panel-Mechanismus: `handleCommand` + `showFindPanel()` in
    `Sources/.../Controller/TextViewController+Lifecycle.swift`.
  - `ChimeHQ/SwiftTreeSitter` — gepinnt auf `08ef81e` (gebaute Revision). Binding-API.
  - `tree-sitter/tree-sitter-regex` — default branch (Grammar für Token-Snap-Logik).
- Gilt nur für Fremd-Frameworks. Eigener Fastra-Code bleibt die primäre Wahrheit.

### Versionierung & Auto-Commits (agent-bindend)

- **Versionsschema:** semver-nah `vX.Y`; Bump beim Abschluss einer logischen
  Etappe — nicht pro Commit.
- **Quellen der Wahrheit:** Versions-Header oben in dieser Datei, vollständige
  History in `CHANGELOG.md` (Keep-a-Changelog-Format), Git-Tags `vX.Y` pro Bump.
- **Selbstständige Commits:** nach abgeschlossenen Etappen, Doku-Updates, grünen
  Test-Suites. Commit-Subjekt enthält die aktuelle Version, z. B. `feat(v1.4): …`.
- **Rückfrage erforderlich bei:** destruktiven Git-Operationen (force-push,
  reset --hard, branch -D), Architektur-Entscheidungen, allem, was außerhalb des
  Projekts sichtbar wird (Public Releases, Tags pushen, gh release create).
- **Push-Stopp (Daniel, 2026-07-11):** Während des Projekt- & Git-Ausbaus (siehe
  ROADMAP.md) **keine Pushes zum GitHub-Remote**, bis die Etappen ordentlich
  getestet sind. Commits + internes Backup-Remote laufen normal weiter.
- **Beim Version-Bump immer parallel:** Header in AGENTS.md aktualisieren,
  CHANGELOG-Eintrag schreiben, Git-Tag setzen, Commit-Message mit Versionsnummer.

### Tests & Verifikation (agent-bindend)

**Automatische Tests sind ausdrücklich sehr erwünscht.** (Coverage-Plan, Test-Pflicht
und Regressions-Lehren: [`CLAUDE.md`](CLAUDE.md) → QA-Strategie.)

- **Selbsttests/Integrationstests von Anfang an mitplanen.** Der In-App-Selbsttest
  (`--selftest-findbar`) ist das Vorbild: Bugs, die App-weites Verhalten betreffen
  (Event-Routing, Fenster-/Lifecycle, Monitor-Reihenfolge), entgehen reinen Unit-Tests.
- **Automatische Tests ersetzen NICHT das manuelle Testen** — sie ergänzen es.
  Was sich automatisch absichern lässt, wird automatisch abgesichert, BEVOR es
  zum manuellen Test geht.
- **Manuelle Tests anstoßen:** Wenn ein Schritt fertig ist, der nur visuell oder
  durch Bedienung verifizierbar ist, aktiv vorschlagen: *„Bitte teste jetzt X."*
- **Grenze:** Nicht testen, was die QA-Strategie explizit ausschließt
  (UI-Rendering, OSS-Framework-Interna, DnD-Mausgesten).

---

## Ordnerstruktur

```
fastra/
├── AGENTS.md            ← Vision, Konventionen, Schichten-Map (diese Datei)
├── ROADMAP.md           ← v1.0-Funktionsumfang + v1.1+
├── CLAUDE.md            ← Build · Test · QA
├── CHANGELOG.md         ← vollständige Versions-Historie
├── README.md · README.de.md · LICENSE · screenshots/
├── app/                 ← die App (SwiftPM-Package)
│   ├── Sources/ · Tests/             ← Swift-Quellcode + Swift-Testing-Suite
│   ├── build.sh · selftest.sh · release.sh
│   ├── repos/                        ← Fremd-Framework-Source als Grep-Referenz (gitignored)
│   ├── dist/                         ← Release-DMGs (gitignored)
│   └── LESSONS-LEARNED.md            ← Build-Gotchas, Pattern-Bewertungen
├── build.sh · selftest.sh · release.sh   ← Wrapper auf app/
```

---

## Erkenntnisse aus den Nutzer-Gesprächen

*(Nutzerinterviews während der Discovery-Phase, 2026.)*

Diese Erkenntnisse sind verbindlich für Produktentscheidungen:

1. **Die Vorschau ist das Produkt** — nicht ein Feature. Alle befragten Nutzer
   nannten sie als primären Kaufgrund. Die Sicherheit des Nutzers soll aus der
   Vorschau resultieren, nicht aus Backup-Mechanismen.
2. **Kein Cloud-Kontakt ist aktiver Kaufgrund** — nicht nur technische Präferenz.
   Auch harmlose Telemetrie würde den Großteil der Zielgruppe abschrecken. Unveränderlich.
3. **Keyboard-First als Designprinzip ist falsch** — Keyboard-Shortcuts als
   Ergänzung sind ok, als Pflicht nicht.
4. **Leerer Start-Zustand verhindert Einstieg** — Neue Nutzer brechen ab, wenn
   die App leer öffnet. Beispiel-Pattern und Demo-Datei sind vorgeladen.
5. **Fehler erklären, nicht nur markieren** — senkt die Hürde für Nutzer ohne
   Terminal-Hintergrund.
6. **Empfehlung von Kollegen ist der primäre Entdeckungskanal** — die App muss so
   gut sein, dass Nutzer sie aktiv weiterempfehlen.
7. **Free Trial ist Pflicht** — kein befragter Nutzer würde blind kaufen.

---

## Monetarisierung

Donationware. Ein unaufdringlicher Spendenaufruf in der App ruft zur freiwilligen
Unterstützung auf — kein Abo, keine Lizenzschlüssel, keine Trial-Wall. Der
Spendenaufruf ist derzeit per Hauptschalter deaktiviert
(`DonationPrompt.isEnabled = false`); die Logik bleibt vollständig erhalten.
