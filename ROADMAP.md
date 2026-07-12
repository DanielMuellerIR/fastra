# Fastra — Roadmap

> **Funktionsumfang v1.0** (was die App können *muss*) + zurückgestellte **v1.1+**-Themen.
> Schichtenmodell: Roadmap lebt hier, nicht in [AGENTS.md](AGENTS.md).

## Funktionsumfang v1.0

Was die App können muss, um v1.0 zu sein. Die Reihenfolge folgt der Roadmap, nicht der Wichtigkeit.

- **A. Floating Search Dialog** — schwebender Such/Ersetzen-Dialog statt starrer Sidebar. Scope-Tabs (Datei / Geöffnet / Ordner / Projekt) als Segmented Control. Find- und Replace-Felder voll breit, Monospace, kein Wrap. Trefferbaum mit Zählern direkt im Dialog. **Such-Optionen** als schmale Toggle-Zeile unter dem Find-Feld: `RegEx` (Default aus — siehe Konzept B.5), `Groß-/Kleinschreibung`, `Ganzes Wort`, `Wrap-around`. Jeder Toggle mit Tooltip-Erklärung. Wenn `RegEx` aus ist, sind Token-Highlighting, Element-Picker und Vorlagen-Dropdown deaktiviert (nicht versteckt).
- **B. Drag & Drop von Capture Groups** — Kernmechanik: Gruppen aus dem Find-Feld lassen sich per Drag & Drop ins Replace-Feld ziehen, dort als `$1`, `$2` … eingefügt. Auto-Erkennung von `(...)`. Anspruch ist **einfache Benutzerführung**, nicht visuelle Effekthascherei. Visualisierung der Gruppen (Inline-Spans vs. Tray vs. hybrid) ist eine offene Designentscheidung, hängt am Suchmasken-Konzept.
- **C. Token-Highlighting im Find-Feld** — RegEx-Bestandteile werden als farbige Inline-Tokens dargestellt: Anker rötlich, Zeichenklassen bläulich, Quantifier ocker, Literale Standard. Parsing via `tree-sitter-regex`.
- **D. Diff & Preview** — Side-by-side Diff in zwei Panels (rot/grün, Treffer-Highlighting). **Implementierung verschoben (Daniel, 2026-05-26):** Die Sofort-Trefferliste in der Suchmaske erfüllt den primären Bedarf bereits weitgehend. Die ausgewachsene Diff-Implementierung rutscht auf v0.9 oder v1.1+ — Entscheidung nach erstem Nutzer-Feedback. Der Button „Vorschau der Änderungen" bleibt als Stub in der Maske. Inline-Diff am Ort der Änderung weiterhin v1.1+.
- **E. Performance & große Dateien** — **Pragmatische Auslegung (Entscheidung 2026-06-11):** Asynchrones Datei-Laden ohne UI-Block (Spinner statt Beachball) + reale Messung mit großen Testdateien. Chunk-basiertes / memory-mapped Loading bräuchte tiefe CESE-Eingriffe → v1.1+. Folder-Suche in `Task.detached`. Kein Hard-Cap; Warn-Dialog erst unmittelbar vor Preview/Apply bei Dateien > ~200 MB.
- **F. Footer (BBEdit-Style)** — Encoding · Line-Endings · Chars/Words/Lines. Statistiken asynchron berechnet, blockieren nie die UI; Placeholder `— / — / —` während Berechnung. Encoding-Erkennung via `NSString.stringEncoding(for:)`.
- **G. Syntax-Highlighting** — via `CodeEditLanguages` (~40 Sprachen out-of-the-box, tree-sitter). Auswahl per Dateiendung, Plain-Text-Fallback.
- **H. Markdown-Vorschau** — **hohe Priorität** (Daniel-Präferenz). Separates Fenster, read-only, GFM (Tabellen, Task-Listen, Code-Blöcke). Implementierung via `MarkdownUI`. Zusätzlich Integration von [`md-clip`](https://github.com/DanielMuellerIR/md-clip) (eigenes Tool): zwei Paste-Modi — *Plain Text* und *Formatiert → Markdown konvertiert*. md-clip ist bereits gelöst, übernehmen wir in Teilen.
- **I. Hex-View für Binärdateien** — **Auf v1.1 verschoben (Entscheidung 2026-06-11).** Read-only Hex+ASCII via HexFiend, automatisch bei erkannten Binärdateien (Null-Byte-Check). Binärdateien bleiben in v1.0 durch den Binär-Schutz der Suche abgefangen.
- **J. Platzhalter-Suche (`*`) ohne RegEx-Kenntnisse** — **In v1.0 gezogen (Daniel, 2026-06-14).** Der Kernanspruch des Produkts auf den Punkt: alltägliche Umstell-Aufgaben müssen **ohne jede RegEx-Kenntnis und ohne Nachlesen** lösbar sein. Auslösender Fall: nachgestellter Artikel in Titel-Listen — `ring, The` → `The ring`, gelöst durch `*, the` (suchen) / `the *` (ersetzen). Die kuratierte Vorlagen-Liste reicht dafür nicht — eine Vorlage setzt das Verständnis der Mechanik voraus.
  - **Kein eigener Modus.** `*` wirkt **im bestehenden Zustand „RegEx aus"** (= Default). Bewusste Entscheidung gegen einen dritten Modus: ein Modus, den der Nutzer erst finden und umschalten muss, ist genau die Hürde, die das Feature beseitigen soll.
  - **Ein-Sternchen-Fall** (`*, the` → `the *`) funktioniert wortlos — der 80-%-Fall.
  - **Mehrere `*` → automatisch nummerierte Capture Groups.** Beim Verlassen des Suchfelds wird jedes `*` zur farbigen, nummerierten **Pille** (①②③) — dieselbe Token-Pillen-Sprache wie im RegEx-Modus. Im Ersetzen-Feld erscheinen genau diese Pillen als anklick- **und** ziehbare Bausteine (DnD + Klick). Pillen statt getipptem `*1`/`*2`: eine getippte Referenz wäre mehrdeutig (Referenz vs. literales `*2`), eine Pille nie. Bei einem `*` genügt eine namenlose Pille.
  - **Live-Vorschau ist der eigentliche Lehrer:** erste Zeilen als Vorher→Nachher direkt unter den Feldern, während getippt wird. Greift in die Preview-Garantie (Produktprinzip 1).
  - **Einzige echte Kollision — literales `*`:** „RegEx aus" war bisher rein wörtlich; `*` ist ein häufiges Zeichen (Markdown-Bullets, Multiplikation, `/* */`). Auflösung ohne neuen Modus/Syntax: die sichtbare Pille signalisiert „besonders", und ein **kontextueller Mini-Schalter „`*` wörtlich nehmen" erscheint nur, wenn das Muster ein `*` enthält**. Normalfall kostenlos, seltener Fall mit offensichtlichem Ausweg.
  - **Verhaltens-Semantik (geklärt mit Daniel, 2026-06-14):** (1) **`*` greift nur innerhalb einer Zeile** — jedes `*` → `(.+)`; die Option `dotMatchesLineSeparators` wird NICHT gesetzt, also matcht `.` kein `\n` (Default). Sonst würde `*` über Zeilen hinweg viel zu viel verschlucken. Per Test absichern (mehrzeiliger Puffer → kein Sprung über `\n`). (2) **Gierig** als Default (`.+`, nicht `.+?`): nimmt das *letzte* Vorkommen des nachgestellten Literal-Ankers — genau das will der Artikel-am-Ende-Fall (`Hello, There, The` → `*` = „Hello, There", nicht „Hello"). (3) **Der Literal-Teil nach dem `*` wird nie vom `*` gefangen** — er ist der Anker, `*` stoppt davor. (4) **Literal-Teil case-insensitiv** finden; gewünschte Schreibweise schreibt der Nutzer im Ersetzen-Feld selbst (`the *` vs. `The *`), er sieht sie in der Vorschau. (5) Mehrere `*` → mehrere gierige Gruppen, durch dazwischenliegende Literale getrennt; die Aufteilung ist inhärent mehrdeutig → die Live-Vorschau ist das Sicherheitsnetz.
  - **Implementierungs-Reibung:** ändert den dokumentierten Plain-Text-Vertrag von `BufferSearch`/`ApplyEngine` (seit v0.5 wird `*` wörtlich via `escapedTemplate` escapt) inkl. Tests. „RegEx aus" wird vom rein-wörtlichen zum Platzhalter-Modus; rein-wörtlich rückt hinter den Mini-Schalter.
  - **Wettbewerbs-Befund (BBEdit live geprüft, 2026-06-14):** BBEdit hat **keinen** Glob-/Platzhalter-Modus zwischen wörtlich und Grep — nur die `Use Grep`-Checkbox; deren Nicht-Grep ist voll wörtlich. Einstiegshilfen sind die [Pattern Playground](https://www.barebones.com/support/technotes/PatternPlaygrounds.html) (Live-Fenster, listet je Capture Group den tatsächlich gematchten Text) und ein Grep-Cheat-Sheet — beides setzt weiter Grep-Verständnis voraus, kein DnD, keine `*`-Auto-Nummerierung. Damit liegt das Platzhalter-Verhalten **oberhalb** von BBEdit und kollidiert mit keiner etablierten Erwartung; es verstärkt die in [AGENTS.md](AGENTS.md) dokumentierten Alleinstellungen. BBEdits Playground bestätigt die Live-Vorschau-Empfehlung.

---

## Projekt- & Git-Ausbau (beschlossen 2026-07-11, nächste große Etappe)

Fastra bekommt Projekt-Bewusstsein und Git-Sichtbarkeit — ohne zum VS-Code-Klon zu
werden. Leitfrage für jedes Teilfeature: „Braucht man das täglich, und können wir es
dauerhaft in guter Qualität warten?" — nicht „Hat VS Code das auch?".

**Philosophie: Git liefert Logik und Daten, Fastra liefert Sichtbarkeit und Knöpfe.**
Alle Git-Funktionen sind dünne Frontends über das installierte `git`-CLI (kein libgit2,
kein Eigenbau). Der CLI-Weg erbt automatisch die Auth-Konfiguration des Nutzers
(SSH-Keys, Keychain-Helper). Schwerpunkt **lesend + wenige Shortcuts für die häufigsten
Aktionen**, keine breite Git-Unterstützung.

**Etappe 1 — Projekte & Seitenleiste (umgesetzt in v1.4.0, 2026-07-12):**
- **Willkommensbildschirm** beim Start / neuen Fenster ohne geöffnete Datei: Liste der
  zuletzt benutzten Projekte, ein Klick lädt das Projekt. ✓
- **Projekt = geöffneter Ordner mit `.git`** — wird automatisch gemerkt (damit bekommt
  das offene „Projekt-Konzept" des Scope-Tabs seine Definition). Zusätzlich „Ordner
  öffnen…" (⇧⌘O) für Ordner ohne Git. ✓
- **Hierarchische Datei-Seitenleiste** (SwiftUI + `FileManager`, lazy pro Ebene) — die
  einzige echte Eigenentwicklung dieser Etappe. ✓
- **Feinarbeit in v1.9.0:** rekursive Live-Aktualisierung über FSEvents,
  Kontextmenü für Umbenennen/Papierkorb/Neu und projektweise persistenter
  Aufklapp-Zustand. ✓

**Etappe 2 — Git-Sichtbarkeit + kuratierte Aktionen (umgesetzt in v1.5.0, 2026-07-12):**
- **Status in der Seitenleiste:** geänderte/neue Dateien eingefärbt + Kürzel-Badge,
  Branch mit Ahead/Behind (`git status --porcelain=v1 -b`), Ordner-Rollup-Punkt. ✓
- **History als read-only-Tab:** `git log --graph --oneline --decorate`, Klick auf
  Commit → `git show <hash>` in weiterem Tab. ✓
- **Diff als read-only-Tab:** `git diff HEAD` gefärbt (added/removed/Hunk/Header). Die
  aufgeschobene Side-by-side-Ansicht (Funktionsumfang D) bleibt Ausbaustufe. ✓
- **Kuratierte Aktionen** (Popup in der Branch-Zeile + „Git"-Menü in der Menüleiste):
  Alles committen, Amend (--no-edit), Push, Pull (Fast-Forward / mit Merge), Fetch,
  Pickaxe (`log -S`), Zum vorherigen Branch (`switch -`). ✓
- **Dezente Hilfe-Texte** als Tooltip an jedem Menüpunkt. ✓
- Erster Push mit automatischem `-u` erledigt (v1.5.1): fehlt der Upstream, macht
  „Push" selbstständig `push -u origin HEAD`. ✓
- **Feinarbeit abgeschlossen:** Stage/Unstage einzelner Dateien über die
  „Änderungen"-Ansicht, lokale Branch-Auswahl aus einer Liste und nicht-modales
  Erfolgs-Feedback für Netzwerk-Aktionen. ✓

**UX-Regeln (verbindlich):**
- **Discovery-Prinzip:** Wichtiges easy, schnell und schick; Fortgeschrittenes
  angedeutet und mit wenig Erkundung gefunden — keine Feature-Friedhöfe, kein Geklicke.
- **Git fehlt → Funktionen bleiben still weg.** Keine Dialoge, keine Installations-
  Aufforderung, kein Gefrage. Wer git nicht installiert hat, braucht die Funktionen nicht.
- **Nie den Main-Thread blockieren** (Push/Pull über langsames Netz) — async wie die
  Folder-Suche.
- **Fehler = echte git-Ausgabe als Text zeigen**, nicht wegabstrahieren. Ehrlich und billig.

**Bewusst verworfen (statt dessen):**
Merge-GUI (→ Konflikt-Marker sind editierbarer Text; Button „In FileMerge öffnen" via
`opendiff` aus den Xcode-CLT), eingebettetes Terminal/SwiftTerm (→ Button „Im Terminal
öffnen"), Minify HTML/JS/CSS (keine brauchbare native Lösung, niedrige Priorität).

**Nachträglich umgesetzt (Daniel, 2026-07-12):** der zunächst verworfene History-Graph
kam als nativer Seitenleisten-Modus „Graph" mit echten Multi-Lane-Verzweigungslinien
(VS-Code-Stil) doch hinzu — der ASCII-`git log`-Tab bleibt zusätzlich bestehen (v1.7.0).

**Release-Gate:** Diese Etappen sind eine größere Änderung — **keine GitHub-Pushes,
bis alles ordentlich getestet ist** (Daniel, 2026-07-11). Commits + internes Backup
laufen normal weiter. (Der frühere technische ghosttext-Blocker ist seit v1.6.1,
Commit `8656f56`, behoben + per Selbsttest `ghosttext` abgesichert — offen bleibt nur
die bewusste Release-Abnahme, kein Bug mehr.)

---

## Globale UI-Skalierung (umgesetzt in v1.8.0, 2026-07-12)

- **Globale UI-Skalierung ⌘ +/− / ⌘0:** Schrift, native Controls und die
  zentralen Leisten-/Feldhöhen skalieren über eine persistente Zoomstufe.
  `Theme.swift` stellt semantische, per Environment skalierbare Schriftrollen
  bereit; auch SourceEditor und AppKit-Such-/Trefferfelder ziehen live mit. ✓

---

## v1.1+ (zurückgestellt)

- **HexFiend-Bridge (Hex-View für Binärdateien)** — aus v1.0 verschoben (2026-06-11).
- **Rectangle Selection (ALT-Spalten-Drag wie BBEdit)** — aus v0.8 verschoben (2026-06-11): CodeEditTextView bietet kein eingebautes Spalten-Select; Nachrüsten = tiefes Maus-Handling.
- **Gutter-Dimmen bei nicht-vorderem Fenster** — aus v0.5/v0.6 verschoben (2026-06-11): `GutterView.backgroundColor` ist `internal`.
- **Chunk-basiertes / memory-mapped Laden großer Dateien** — pragmatische v1.0-Auslegung (async ohne UI-Block) reicht erstmal; echtes Chunk-Loading bräuchte tiefe CESE-Eingriffe (2026-06-11).
- **Voll ausgebaute Side-by-side Diff-Vorschau** im Hauptfenster (Vorher/Nachher in zwei Panels, rot/grün). Erst aktiv angehen, wenn Nutzer-Feedback zeigt, dass die Sofort-Trefferliste nicht reicht.
- **Extrahieren-Dialog** mit Trennzeichen-Auswahl (Zeilenumbruch / Komma / Semikolon / Tab / eigenes), Ziel (Clipboard / neue Datei), Quoting-Optionen, Dedup.
- **Projekt-Konzept** für den Scope-Tab (gespeicherte Datei-Sets + Filter + Excludes) — Grunddefinition „Projekt = Ordner mit `.git`" jetzt beschlossen, siehe Sektion „Projekt- & Git-Ausbau"; Datei-Sets/Filter/Excludes weiter offen.
- **Englische Lokalisierung** (`Localizable.strings`-Umbau, alle UI-Strings durchziehen).
- **Vorlagen-Editor** — eigene Patterns speichern, Import/Export.
- Inline-Diff am Ort der Änderung (L5-Layout).
- `ripgrep`-Bundle für ultraschnelle Folder-Suche.
- Live-Preview während des Tippens (falls Diff-Vorschau überhaupt erhalten bleibt).
- Eigenes Akzentfarben-Token-System (statt System-Accent).
- Hex-Editor mit Edit-Modus (HexFiend kann es, v1.0 read-only).
- Dark Mode polishing.
- Cross-Platform-Portabilität (Windows/Linux) — **Machbarkeit zu prüfen**.
- **Find-Panel-Rest-Aufblitzen endgültig beseitigen** (Daniel, 2026-05-27): Bei sehr schnellem CMD+F-Hämmern blitzt CodeEditSourceEditors Find-Panel gelegentlich noch kurz auf, bevor die Reconciliation es schließt (siehe [CLAUDE.md](CLAUDE.md) → QA-Strategie). Aktueller Stand reicht für jetzt. Komplett flackerfrei vermutlich nur, indem der Editor-eigene CMD+F-Monitor an der Quelle neutralisiert wird (kostet dann ggf. CMD+/, CMD+[ /], Tab-Indent — Abwägung). Nach v1.0 angehen.

- **Transformation per Beispiel** (Ausbaustufe des Platzhalter-Verhaltens, Funktionsumfang J): Nutzer gibt `ring, The` → `The ring` als Beispielpaar ein, das Programm leitet das Muster selbst ab (wie Excel-Blitzvorschau). Mächtig, aber deutlich aufwändiger und fehleranfälliger als das `*`-Platzhalter-Verhalten. Vision, nicht v1.0.
