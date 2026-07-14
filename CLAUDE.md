# CLAUDE.md — Fastra (Build · Test)

> Claude-/Build-spezifisch (wie baue, teste, betreibe ich dieses Projekt).
> Projektfakten, Vision, Konventionen → [AGENTS.md](AGENTS.md).

## Build-Anleitung

```bash
cd app
./build.sh                 # debug
./build.sh release         # release (signiert ad-hoc)
NOTARY_PROFILE=<profil> ./install.sh   # notarisiert → /Applications/Fastra.app

# Gleiches bequem direkt aus dem Projekt-Root:
NOTARY_PROFILE=<profil> ./install.sh
```

**Installations-Workflow (`app/install.sh`):** baut Release, signiert mit
Developer ID + Hardened Runtime, notarisiert bei Apple (`--wait`), stapelt das
Ticket und kopiert nach `/Applications`. Die Signatur-Identität wird zur Laufzeit
aus dem Schlüsselbund ermittelt (nichts Privates im Skript — public Repo). Der
Notary-Keychain-Profilname steht bewusst NICHT im Skript; per `NOTARY_PROFILE`
übergeben (der fleet-spezifische Profilname steht in
`~/git/intern/knowledge/fastra.md`). `./install.sh --no-notarize` = nur
signiert (schnell, läuft auf diesem Mac sofort).

Der Root-Wrapper `./install.sh` reicht Optionen und Umgebungsvariablen
unverändert an `app/install.sh` weiter; dadurch funktioniert der komplette Lauf
auch ohne vorheriges `cd app`.

**Pflicht-Gate für Installationen (seit v1.12.2):** SwiftPMs generierte
`Bundle.module`-Accessor erwarten beim CLI-Build Ressourcen neben dem
Executable und enthalten zusätzlich einen absoluten Fallback in
`.build/<Konfiguration>`. Eine signierbare macOS-App braucht die Bundles aber
unter `Contents/Resources`. Fastras Locator und die `build.sh`-Patches für
CodeEditSymbols/CodeEditLanguages bevorzugen deshalb
`Bundle.main.resourceURL`; danach ruft der Build `verify-portable-app.sh` auf: Alle
lokalen `.build/*.bundle`-Fallbacks werden kurz ausgeblendet, dann muss der
fensterlose Selbsttest `localization` aus der gepackten App starten.
`install.sh` wiederholt dieses Gate nach dem Kopieren mit der tatsächlich
installierten App. Signatur-, Stapler- und Gatekeeper-Prüfungen ersetzen
diesen echten Zielstart nicht.

**Agent-bindend (2026-07-13):** `build.sh` kopiert **jeden erfolgreichen
Build** nach `/Applications/Fastra.app` — auch Debug-Builds.
Nicht jeder Build wird jedoch notarisiert: Der notarisierten Release-Workflow
via `install.sh` bleibt für:
- einer **abgeschlossenen, verifizierten größeren Etappe** (Release-reifer Stand,
  den Daniel produktiv nutzen soll), oder
- **auf Ansage** („leg mir einen frischen Build hin").

Für normale Zwischen-Iterationen genügt `build.sh`; die frisch gebaute
Debug-App liegt danach ebenfalls unter `/Applications/Fastra.app`. Für eine
signierte, aber nicht notarisierten Variante dient weiter `install.sh --no-notarize`.
Beim Version-Bump `app/Info.plist` mitziehen (siehe AGENTS.md), sonst zeigt die
App eine veraltete Version.

`build.sh` kapselt Xcode-Toolchain-Switch + elf Checkout-Patches
(SwiftLint-Plugins aus, CodeEditSymbols Resources, CMD+F-Zombie-Kill,
toter cursorPositions-Reconcile, Gutter-Drag-Clamp, horizontaler Scrollbalken,
Zeilenbreiten-Messung, exotische Sprachen ausschneiden, Highlight-Query-Pfad
layout-robust und Text-Geist-Fix).
Details in `app/LESSONS-LEARNED.md` Sektion F (F.9 = CMD+F, F.10 = Reconcile).
Patch 4h (Highlight-Query-Pfad, 2026-07-10): `CodeLanguage.queryURL` baute
`resourceURL + "Resources/…"`, aber `Bundle.module.resourceURL` zeigt bei
unserem Bundle-Layout schon auf `…/Resources` → doppeltes
`Resources/Resources`, die highlights.scm wurde nie gefunden und der Editor
blieb monochrom (Sprache wurde trotzdem korrekt erkannt — betraf auch den
abgenommenen v1.0-Release). Regressions-Wächter: Selbsttest `highlight`
(zählt echte Vordergrundfarben im Editor-TextStorage).
Patch 4i (Text-Geist, 2026-07-12): CodeEditTextViews Break-Helfer liefert
einen absoluten Endindex im Content-Run, der Typesetter verwendete ihn aber
fälschlich als `NSRange.length`. Dadurch überlappten die gezeichneten
CoreText-Bereiche ab dem zweiten Umbruchfragment. Der Patch berechnet die
Länge als Endindex minus Startindex. Regressions-Wächter: Selbsttest
`ghosttext` (CoreText-Nutzlast, Fragmentbreite und doppelte Dokumentbereiche).
Gutter-Drag-Clamp (4d in build.sh): CESEs `mouseDragged` clampt die Drag-Position
auf `max(0, …)` → über der Gutter-Spalte liefert `textOffsetAtPoint` nil und die
Selektion friert ein; Patch clampt auf `max(layoutManager.edgeInsets.left, …)`.
Der zugehörige Gutter-Durchschuss-ins-Header-Fix ist App-seitig (`.clipped()` am
Editor in `EditorView`), KEIN Checkout-Patch.

### Bundle-Größe — Apple-Silicon-only, ~53 MB (Stand 2026-07-08)

Das Bundle war einmal 489 MB. Drei Ursachen, alle in `build.sh` adressiert:
1. **Kein Intel.** Fastra wird nur für arm64 gebaut (Daniel-Entscheidung 2026-07-08).
   `swift build` baut ohnehin nur die Host-Arch; die einzige x86_64-Quelle war das
   Grammatik-XCFramework (s. u.), das jetzt nicht mehr mitwandert.
2. **Grammatik-XCFramework NICHT mehr ins Bundle kopiert** (Bundle-Schritt in build.sh).
   `CodeLanguagesContainer` (CodeEditLanguages, `.binaryTarget`) ist ein STATISCHES
   ar-Archiv (~375 MB, universal): zur Build-Zeit ins Binary gelinkt, zur Laufzeit nie
   geladen (dyld kann kein ar-Archiv laden; nicht in `otool -L`). War reines totes Gewicht.
   Nur echte dynamische Frameworks (.dylib-Binary) dürften wieder kopiert werden.
3. **Exotische Grammatiken ausgeschnitten (Patch 4g).** Jeder `case .X: return tree_sitter_X()`
   in `CodeLanguage.swift` erzwingt die statische Linkage der Grammatik-.o (teils zweistellige
   MB). Patch 4g ersetzt den Rückgabewert der Exoten durch `return nil` → Linker lässt die .o
   draußen. Ausgeschnitten: Verilog, OCaml(+Interface), Julia, Haskell, Scala, Agda, Elixir,
   Zig (~50 MB). Dart + alle Mainstream-Sprachen bleiben. Cut-Sprache = kein Highlighting
   (Plaintext), sonst unberührt. Neue Sprache streichen: Case-Zeile in die 4g-Schleife.
4. **Release strippt + signiert ad-hoc neu.** `strip -x` (nur ~wenige MB, Grammatiken
   dominieren) invalidiert auf Apple Silicon die Signatur → `codesign --force --sign -`
   direkt danach, sonst startet die App nicht. Nur im Release-Build; Debug behält Symbole.

---

## QA-Strategie — Automatisierte Tests

- **Logik** automatisiert via [Swift Testing](https://developer.apple.com/xcode/swift-testing/) (Apple, ab Xcode 16). **UI und Visuelles** manuell — XCUITest ist aus Wartungssicht nicht vertretbar.
- **Laufzeit:** komplette Suite < 5 Sekunden lokal.
- **Workflow:** Tests werden parallel zur Implementierung geschrieben. Eine Phase gilt erst als abgeschlossen, wenn alle Tests grün sind.
- **Coverage:** über 700 Tests; Schwerpunkte sind RegEx-/Platzhalter-Parsing,
  Capture Groups, Find/Replace, Datei-/Projekt-/Git-Logik, Encoding,
  Zeilenenden, Hex-/Großdatei-Routing und Textoperationen.
- **Lokalisierung:** `cd app && ./localization-audit.sh` vergleicht statische
  SwiftUI-Schlüssel mit der englischen Tabelle und prüft Format-Platzhalter.
  `./selftest.sh localization` prüft danach die Tabellen im fertig gepackten
  Haupt-App- und SwiftPM-Ressourcenbundle.
- **Test-Pflicht pro Phase:** Phase 1 keine (reines UI-Gerüst), Phase 2 Encoding+Line-Endings+Stats, Phase 3 Tokenizer+Capture-Groups+Find/Replace (Kernlogik), Phase 4 File-Search+Threshold-Logik, Phase 5 keine (reine Bridges zu getesteten OSS-Komponenten).
- **Nicht getestet:** visuelles Rendering von Diff/Tokens/Pillen und
  OSS-Framework-Interna (MarkdownUI, CodeEditSourceEditor). Kritische
  App-weite Bridges werden dagegen über In-App-Selbsttests abgesichert.

### Regressions-Schutz — Lehre aus dem „Zombie-Find-Bar" (2026-05-27)

Die Find-Leiste tauchte bei CMD+F mehrfach wieder auf. Der korrekte Befund nach gründlicher Analyse:

1. **Echter Root Cause:** Der „Zombie" ist NICHT die macOS-NSTextView-Find-Bar, sondern **CodeEditSourceEditors eigenes Find-Panel**. Der Editor installiert beim Laden einen EIGENEN lokalen `keyDown`-Monitor (`TextViewController.handleCommand`), der bei fokussiertem Editor CMD+F abfängt und `showFindPanel()` aufruft. Deshalb halfen `disableFindBars`/Menü-Purge nie — die zielen auf den FALSCHEN Mechanismus (Standard-NSTextView-Find), nicht aufs Editor-eigene Panel.
   **Was NICHT funktioniert:** Versuchen, den Konflikt über die Reihenfolge konkurrierender `NSEvent`-Local-Monitore zu gewinnen (LIFO/„neuester zuerst"). Diese Reihenfolge ist in der Praxis **nicht zuverlässig steuerbar** — Reinstall-auf-Notification und Launch-Timer waren beide flaky (per Selbsttest reproduziert).
   **Zwischenschritt (Write-back-Reconcile, reicht NICHT ganz):** CodeEditSourceEditors Coordinator schreibt `findPanelVisible` in den `SourceEditorState`-Binding ZURÜCK, wenn sein Panel öffnet (`SourceEditor+Coordinator`). Wir beobachten `editorState.findPanelVisible` in `EditorView`: wird es `true`, setzen wir es sofort `false` (der Editor reconciled → Panel schließt) und öffnen STATTDESSEN unsere Suchmaske (`.fastraShowSearchFile`). Problem: `showFindPanel()` animiert das Panel 0,15 s EIN, bevor unser `false` es wieder schließt — es **blitzt kurz auf** (reproduzierbar bei rapidem CMD+F + Klick ins Hauptfenster).
   **Finaler Fix (deterministisch, 2026-06-03):** `build.sh` patcht den resolved CESE-Checkout — der CMD+F-Zweig in `TextViewController.handleCommand` ruft nicht mehr `showFindPanel()`, sondern `return event` (CMD+F wird durchgereicht). Damit zeigt der Editor sein Panel NIE, egal wer das Monitor-Rennen gewinnt; CMD+F fängt ausschließlich unser App-Monitor ab. Der Patch fügt sich in das bestehende `build.sh`-Patch-Muster (nicht-invasiv, idempotent, verifiziert dass er greift, invalidiert die CESE-Build-Artefakte — SPM trackt Checkout-Änderungen sonst NICHT). Write-back-Reconcile + Reinstall-Hack (`installKeyMonitor`/`installFlagsMonitor` auf `didBecomeKey`/flagsChanged) bleiben als Sicherheitsnetz. Unser App-Monitor deckt zusätzlich CMD+F bei NICHT fokussiertem Editor sowie CMD+SHIFT+F/ESC ab.

2. **VERBOTENER Irrweg (kostete eine Session):** `NSApplication` zu subclassen, um CMD+F in `sendEvent` abzufangen — egal ob via `NSPrincipalClass` (wird unter SwiftUI ignoriert) oder via eigenem `main.swift`, der `CustomApp.shared` vor `App.main()` verankert. Letzteres ERSETZT SwiftUIs interne `SwiftUI.AppKitApplication`, deren eigenes Event-Routing dann fehlt → **die gesamte App wird maus-tot** (keine Klicks, kein Fenster-Schließen, CMD+Tab bringt nicht nach vorn). **Niemals NSApplication unter SwiftUI-Lifecycle subclassen.** Zur Laufzeit ist `NSApp.className == "SwiftUI.AppKitApplication"` — das ist korrekt und soll so bleiben.

3. **In-App-Selbsttests** (`SelfTest.swift`, kein Accessibility nötig — Events werden intern gepostet). **Aufruf: bevorzugt über den Runner `./selftest.sh` (alle Tests oder `./selftest.sh findbar jump`), direkt via `Fastra -selftest findbar -ApplePersistenceIgnoreState YES` oder Umgebungsvariable `FASTRA_SELFTEST=findbar`.** `-selftest findbar` postet ein echtes CMD+F bei fokussiertem Editor und **pollt ~1,2 s engmaschig**, ob das Editor-Find-Panel AUCH NUR KURZ auftaucht (eine Einzel-Messung am Ende würde das Aufblitzen verpassen). `-selftest newwindow` löst den echten ⌘N-Menübefehl aus, prüft ein zweites leeres Dokumentfenster mit unabhängigem Workspace, wechselt den Fokus zurück, belegt per echtem ⌘T das Routing globaler Commands und schließt anschließend den letzten Tab des Zweitfensters per echtem ⌘W (Fenster muss verschwinden; braucht ECHTEN Fenster-Fokus, s.u.). `-selftest fields` prüft, ob Suchen- UND Ersetzen-Feld echte, editierbare, betippbare Texteingaben sind (fing den toten Find-Feld-Bug). `-selftest tabswitch` prüft, ob der Editor beim Tab-Wechsel neu erzeugt wird (CESE schiebt Binding-Text nicht zurück → ohne `.id(activeTab.id)` bliebe der Inhalt stehen; via Objekt-Identität vorher≠nachher belegt). `-selftest cmdw` prüft CMD+W-Schließen (braucht ECHTEN Fenster-Fokus, s.u.). `-selftest jump` lädt Text mit unterschiedlich langen Vorzeilen (inkl. Emoji als UTF-16-Surrogatpaar) in einen Tab, postet exakt wie die GUI einen Treffer-Sprung (Zeile/Spalte-Pfad über `postMatchJump`) und liest die ECHTE Editor-Selektion zurück (`CodeEditTextView.TextView.selectedRange()`): der selektierte Text muss exakt der Treffer sein. Fing den toten Treffer-Sprung — CESE 0.15.x reconcilet `cursorPositions` von außen NIE (Bedingung `!= state.cursorPositions` vergleicht mit sich selbst, immer false; in `build.sh` gepatcht auf `!= controller.cursorPositions` + `scrollToVisible`). `-selftest replaceall` lädt den Demo-Inhalt („Nachname, Vorname"), setzt `(\w+), (\w+)` → `$2 $1`, ruft `applyAllInActiveBuffer()` und liest den ECHTEN Editor-`.string` zurück: er muss nach dem Replace den ersetzten Text zeigen (== Modell-Inhalt). Fing die Regression, dass „Alle ersetzen" im Editor folgenlos blieb (CESE übernimmt Binding-Änderungen nicht → in `EditorView` über `editorReloadNonce` an der `.id` eine Neuerzeugung erzwungen). `-selftest pilldrop` fokussiert das Ersetzen-Feld und treibt dessen Drag-Destination-Methoden mit einem `NSDraggingInfo`-Mock („$1"): Annahme (`draggingEntered == .copy`) + Einfügung müssen AUCH bei Fokus klappen. Fing den Bug, dass ein Gruppen-Pillen-Drop aufs fokussierte Ersetzen-Feld verpuffte (NSTextView lehnt Drops bei First-Responder ab → in `RegexFieldTextView` die Destination-Methoden überschrieben). `-selftest windows` ist ein reines Diagnose-Flag (Fenster-Dump über 10 s). Alle geben `SELFTEST <name>: PASS/FAIL` + Exit-Code aus; Fenster-Tests POLLEN bis 15 s auf ihr Fenster statt nach fixer Frist zu guarden. **Genau die Bug-Klasse (App-weites Event-/Eingabe-Verhalten), die reine Unit-Tests NICHT fangen.** Nach jeder Änderung an Lifecycle/Fenster/Monitoren mehrfach laufen lassen (Flakiness zeigt Race-Conditions).
   `-selftest ghosttext` lädt mehrere lange Zeilen und prüft nach Laden und
   Resize die echten CoreText-Fragmente: gezeichnete Nutzlast entspricht dem
   Dokumentbereich, kein Fragment überschreitet die Umbruch-Breite und kein
   Dokumentbereich ist doppelt sichtbar. Er sichert den Fehler ab, bei dem
   Wörter nach Paste/Laden mehrfach erschienen und rechts aus dem Editor liefen.
   **Umgebungs-Fallen beim Selbsttest-Aufruf (2026-06-11, alle in `selftest.sh` gekapselt):**
   - **NIEMALS positionale `--selftest-…`-Argumente verwenden (Root Cause des „kein Hauptfenster"-Bugs).** AppKit interpretiert unbekannte positionale Argumente als „zu öffnende Datei" — die App durchläuft dann den Open-File-Launchpfad statt `applicationOpenUntitledFile`, und SwiftUI erzeugt das WindowGroup-Hauptfenster NIE (`NSApp.windows` bleibt leer, Main-Thread idle; empirisch: JEDES `--flag` löst das aus). `-Key Value`-Argumente (NSArgumentDomain) sind unschädlich → daher `-selftest <name>`. Dass die Fenster-Tests früher trotz `--selftest-…` grün waren, lag mutmaßlich an der Fenster-Restauration aus dem Saved State — die seit 2026-06-11 mitgegebene `-ApplePersistenceIgnoreState YES` schaltete genau diese Krücke ab und machte den Bug sichtbar. Alte Aufrufform wird erkannt und FAILt sofort mit Hinweis.
   - **Immer `-ApplePersistenceIgnoreState YES` mitgeben** (`Fastra -selftest findbar -ApplePersistenceIgnoreState YES`). Nach einem abgebrochenen Lauf (z.B. `pkill` in build.sh) zeigt macOS sonst beim nächsten Start den modalen „Fenster wiederherstellen?"-Dialog (`NSPersistentUIManager`) — die App hängt dann VOR dem Selbsttest endlos (per `sample` diagnostiziert: Main-Thread in `promptToIgnorePersistentStateWithCrashHistory`).
   - **Gesperrter Bildschirm = keine Fenster-Selbsttests.** Bei gesperrter Konsole (`ioreg -n Root -d1 | grep IOConsoleLocked` → Yes) schlagen alle fensterbasierten Tests fehl — das ist Umgebung, nicht Code. Nur `-selftest search` (fensterlos) ist dann aussagekräftig. `selftest.sh` prüft das vorab.
   - **`cmdw` und `newwindow` brauchen einen ruhigen Desktop.** macOS 26 verweigert einem im Hintergrund gestarteten Prozess die Selbst-Aktivierung komplett (`NSApp.activate` wirkungslos, `isActive` bleibt false — kooperative Aktivierung). `selftest.sh` startet beide deshalb via `open` und holt die App per System Events nach vorn. Arbeitet gleichzeitig jemand aktiv am Mac (z.B. Claude-App im Vordergrund), holt sich dessen App den Fokus sofort zurück → der Test meldet einen ausgewiesenen Umgebungs-FAIL („Umgebungsproblem", `selftest.sh`-Exit-Code 2), KEINEN Funktionsfehler. Unbeaufsichtigt (entsperrt + idle) laufen lassen oder manuell bewerten.

**Daraus abgeleitete Test-Leitlinien (verbindlich):**
- **Logik aus AppKit-Glue in pure Funktionen ziehen.** Entscheidungen (Event→Aktion, Footer-Kante, find-bezogener Menüpunkt) leben in `KeyRouting`, `CursorFooter`, `DocumentStats`, `AppDelegate.isFindRelated`. Abgedeckt durch `KeyRoutingTests`, `FooterLogicTests`, `FindBarSuppressionTests`, `RegexElementsTests`.
- **ABER: Pure Unit-Tests fangen die gefährlichste Bug-Klasse NICHT** — App-weite Event-/Lifecycle-/Monitor-Ordering-Fehler. Die `KeyRouting`-Tests waren grün, während die App komplett unbenutzbar war. Lehre: Logik-Tests sind nötig, aber NICHT hinreichend. Jede Änderung an App-Lifecycle/Fenster/Monitoren MUSS zusätzlich real verifiziert werden (manuell oder per UI-Automation).
- **Single Source of Truth.** CMD+F/ESC-Routing existiert genau einmal (`KeyRouting.route`).

**Pflicht-Smoke-Test nach JEDER Änderung an App-Lifecycle, Fenster-Setup, Menüleiste oder Event-Monitoren — die Klasse von Bugs, die Unit-Tests nicht fangen:**
0. **Maus funktioniert überhaupt:** Klick in Editor setzt Cursor, Buttons reagieren, roter Schließen-Knopf schließt, CMD+Tab holt App nach vorn. (Diese Stufe zuerst — ist sie rot, ist alles andere irrelevant.)
1. CMD+F (Editor fokussiert) → Suchmaske öffnet, **kein** Editor-Find-Panel.
2. CMD+SHIFT+F → Ordner-Modus, Fenster wächst, kein Find-Panel.
3. ESC bei vorderer Suchmaske → blendet aus. ESC sonst → stört nichts.
4. CMD+F mehrfach hintereinander → kein Zombie, kein Doppel-Öffnen.
5. App-Wechsel raus und zurück, dann CMD+F → Suchmaske kommt wieder nach vorn.
