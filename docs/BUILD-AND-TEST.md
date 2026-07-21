# Fastra bauen und testen

Diese Datei beschreibt den reproduzierbaren Build-, Paketierungs- und Testweg.
Projektfakten, Produktinvarianten und Konventionen stehen in
[AGENTS.md](../AGENTS.md).

## Build-Anleitung

```bash
cd app
./build.sh                 # debug
./build.sh release         # release (signiert ad-hoc)
./install.sh                           # notarisiert → /Applications/Fastra.app

# Gleiches bequem direkt aus dem Projekt-Root:
./install.sh
```

Beim ersten notarisierten Lauf prüft das Skript das Profil vor dem Build. Fehlt
die Clone-Einstellung, fragt es interaktiv nach dem Profilnamen; fehlt auch das
Profil im lokalen Schlüsselbund, bietet es die sichere interaktive Einrichtung
mit `notarytool store-credentials` an. Das App-spezifische Passwort wird dabei
nie als Argument übergeben. Optional kann der Profilname vorab gesetzt werden:

```bash
git config --local fastra.notaryProfile <profil>
```

`release.sh` und `install.sh` verwenden diese Einstellung, sofern
`NOTARY_PROFILE` nicht ausdrücklich gesetzt ist. Der Name liegt ausschließlich
in `.git/config`; Credentials bleiben im macOS-Schlüsselbund. Beides wird weder
committed noch zu einem Remote übertragen. Auf jedem weiteren Mac ist der
interaktive Bootstrap einmal nötig, weil iCloud notarytool-Profile nicht synct.

**Installations-Workflow (`app/install.sh`):** baut Release, signiert mit
Developer ID + Hardened Runtime, notarisiert bei Apple (`--wait`), stapelt das
Ticket und kopiert nach `/Applications`. Die Signatur-Identität wird zur Laufzeit
aus dem Schlüsselbund ermittelt (nichts Privates im Skript — public Repo). Der
Notary-Keychain-Profilname steht bewusst NICHT im Skript; er wird per
`NOTARY_PROFILE`, lokaler Git-Konfiguration oder Erstdialog ermittelt.
`./install.sh --no-notarize` signiert nur und legt das Test-Bundle im
Projekt-Root ab; es installiert ausdrücklich nichts nach `/Applications`.

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

**Agent-bindend (2026-07-21):** `/Applications` ist ausschließlich
notarisierten Bundles vorbehalten. `build.sh` legt Debug- und Release-Builds als
`Fastra.app` im Projekt-Root ab. Auch `install.sh --no-notarize` bleibt dort;
weder Ad-hoc- noch nur Developer-ID-signierte Builds dürfen nach
`/Applications` kopiert werden. Der vollständige notarierte Workflow via
`install.sh` ist der erforderliche Testpfad, sobald echtes
Installationsverhalten, Datei-Doppelklick über LaunchServices,
Finder-Zuordnungen oder macOS-Datei- bzw. Ordnerberechtigungen relevant sind.
Er darf ebenso für normale verifizierte Teststände verwendet werden; eine
abgeschlossene größere Etappe oder eine besondere Ansage sind dafür nicht
erforderlich.

Für schnelle rein interne Iterationen genügt `build.sh`; die frisch gebaute
Debug-App liegt danach im Projekt-Root. Für eine signierte, aber nicht
notarisierte Variante dient `install.sh --no-notarize`, ebenfalls ausschließlich
im Projekt-Root. Vor jeder Installation prüft `install.sh` Notary-Ticket,
Gatekeeper-Akzeptanz und Codesignatur des Quell-Bundles. Beim Version-Bump
`app/Info.plist` mitziehen (siehe AGENTS.md), sonst zeigt die App eine veraltete
Version.

`build.sh` kapselt Xcode-Toolchain-Switch + neunzehn Checkout-Patches
(SwiftLint-Plugins aus, CodeEditSymbols Resources, CMD+F-Zombie-Kill,
toter cursorPositions-Reconcile, verworfene Auto-Vervollständigung schließen,
Gutter-Drag-Clamp, horizontaler Scrollbalken, Zeilenbreiten-Messung,
exotische Sprachen ausschneiden, Highlight-Query-Pfad layout-robust,
Text-Geist-Fix, zwei portable Ressourcenpfade, getrennte 4D-Theme-Slots
einschließlich eines optionalen Methoden-Slots, feste Soft-Wrap-Spalten und
Rechteckauswahl auf logischen Zeilen, vollständige Dateiende-Auswahl sowie
stabile Auswahl- und Layoutzustände großer Textoperationen).

Seit v1.19.0 verpackt `build.sh` zusätzlich das exakt gepinnte
`Sparkle.framework` unter `Contents/Frameworks`, entfernt die für die nicht
sandboxed App unnötigen XPC-Dienste und signiert Ressourcen, Autoupdate,
Updater-App, Framework und Fastra strikt von innen nach außen. `--deep` dient
nur noch der abschließenden Prüfung, nie der Signierung. Der Selbsttest
`updates` prüft im gepackten Bundle Menüpunkt, Feed, Signaturpflicht,
zustimmungspflichtige Installation und deaktiviertes Systemprofiling.
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
Patch 4c1 (4D-Auto-Vervollständigung, 2026-07-19): CESE setzt vor einer
asynchronen Vorschlagsanfrage `activeTextView`. Liefert der 4D-Delegate für das
erste Zeichen absichtlich noch `nil`, blieb dieser Zustand ohne sichtbares
Fenster stehen; die Anfrage für das zweite Zeichen aktualisierte nur die
unsichtbare Liste. Der Patch ruft in diesem `nil`-Pfad `willClose()` auf. Der
Regressions-Wächter `./selftest.sh completion4d` lädt eine echte `.4dm`-Datei
und prüft Auto-Popup, ⌃Leertaste, ↓ sowie Klick/Doppelklick in der sichtbaren
CESE-Tabelle. Weil die letzten drei Schritte echten Fensterfokus brauchen,
startet der Runner die App über LaunchServices und beendet sie danach wieder.
Patch 4m (4D-Projektmethoden, 2026-07-19): Die 4D-Vorgaben unterscheiden
Methoden farblich und typografisch von Befehlen. `EditorTheme` besitzt upstream
keinen freien Methoden-Slot; der Checkout-Patch ergänzt daher am Ende des
Initializers ein optionales `methods`-Attribut mit Default `commands` und mappt
`.method` dorthin, während `.function` auf `commands` bleibt. Der Default ist
entscheidend: Alle bestehenden Themes und Sprachen behalten ihre Darstellung.
Der Patch prüft Marker und Mapping hart und verwirft anschließend die
CodeEditSourceEditor-Artefakte. Regressions-Wächter: Unit-Test gegen die
eingecheckten 4D-JSON-Farben sowie `./selftest.sh highlight4d`, der im echten
Editor Methode (Farbe + bold/italic), Befehl, Prozessvariable und String in
hellem und dunklem Theme beobachtet.
Patch 4n (Soft-Wrap-Spalten und Seitenlinie, 2026-07-19): CodeEdit kann
upstream nur an der Viewportbreite umbrechen. Fastra ergänzt eine optionale
maximale Layoutbreite und `wrapAtColumn`; die effektive Breite bleibt das
Minimum aus Spaltenziel und nutzbarem Viewport. Umbruch und vorhandene
Reformatting-Linie verwenden dieselbe reale Schrift-, Kern- und Inset-Geometrie.
Der Patch korrigiert außerdem die bisher halbierte Guide-Koordinate und zeichnet
die versetzte Guide-View in lokalen Bounds. Bei extrem schmaler Breite erzwingt
der Typesetter mindestens ein vollständiges Graphem pro Fragment. Beim
Umschalten von Soft Wrap sichert der Patch die tatsächliche oberste logische
Textzeile statt des absoluten Y-Werts. Höchstens 24 Layoutschritte konvergieren
innerhalb desselben Runloops auf die neue Ankergeometrie; erst die stabile
Endposition wird sichtbar. So entstehen weder zeitversetzte Scrollkorrekturen
noch ein vollständiges Layout aller vorangehenden Zeilen.
Regressions-Wächter: `SoftWrapLayoutTests` treiben echte CodeEdit-Controller,
Layoutfragmente und Bitmap-Rendering; `./selftest.sh softwrapmodes` prüft im
laufenden Fenster alle drei Ziele, Guide-Koordinate, Resize, Zoom und
zustandsneutrales Reconcile. `./selftest.sh softwrapanchor` verankert in einem
realen Dokument mit 2.400 langen Zeilen die unabhängig beobachtete oberste
Zeile beim Aus- und Einschalten. Der Test tastet den sichtbaren Zustand alle
20 ms ab und akzeptiert keine abweichende Zwischenposition. `ghosttext`,
`hscroll`, `colsel` und `gutterdim` bleiben ergänzende Regressionen.

Patch 4o (Rechteckauswahl, 2026-07-19): Upstream baut die Spaltenauswahl aus
jedem sichtbaren `lineFragment` und macht umbrochene Fortsetzungen dadurch zu
zusätzlichen Rechteckzeilen. Fastra ersetzt
`TextView+ColumnSelection.swift` reproduzierbar aus
`app/Patches/CodeEditTextView/` und verdrahtet Copy/Paste, Delete sowie
Mehrfachbereich-Undo. Zeilen und Spalten werden aus logischen NSString-Zeilen,
vollständigen `Character`-Graphemen und tabstopp-bewussten visuellen Spalten
berechnet. CodeEditSourceEditor reicht die aktive Tabbreite und
Einrückungseinheit weiter. Alle Integrationsstellen besitzen harte Marker;
eine abweichende Upstream-Quelle bricht den Build ab. Regressions-Wächter:
`./selftest.sh colsel colselwrap colpaste` prüft Punkt-Drag, echte
Soft-Wrap-Fragmente, Vorwärts/Rückwärts, kurze und leere Zeilen, Tabs, CRLF,
Unicode, Copy/Paste/Cut/Delete/Tippen/Paste Column, Transformationen und genau
eine Undo-Gruppe pro Schreibaktion.

Patch 4p (Auswahl am Dateiende, 2026-07-20): Endet eine Datei mit LF, CRLF
oder CR, liegt der Dokumentend-Cursor bereits links in der nachfolgenden leeren
Zeile. CodeEditTextView verwendete diese X-Position als rechte Kante der
vorherigen ausgewählten Textzeile und erzeugte dort ein Rechteck mit Breite
null. Der Patch zeichnet eine ausgewählte abschließende Zeilenendung bis zum
rechten Textrand; Dateien ohne abschließenden Zeilenumbruch markieren weiterhin
nur bis zum letzten Zeichen. `SoftWrapLayoutTests` prüft die echte
CodeEdit-Auswahlrange und deren erzeugte Rechtecke für alle drei Zeilenenden.

Patch 4q (große Textoperationen mit Undo, 2026-07-20): CodeEditTextView setzt
nach einer großen Bereichsersetzung den Cursor ans Ende des Ersatztexts und
leitet die Undo-Auswahl allein aus der alten Mutationsrange ab. Bei „Zeilen
verbinden“ entstand dadurch eine extrem lange Soft-Wrap-Zeile mit instabilem
Scroll-/Layoutanker; Undo markierte anschließend das ganze alte Dokument und
konnte einen leeren Bildschirm oberhalb von Zeile 1 zeigen. Fastras
Textoperationspfad bildet Cursor oder Selektion nun bewusst auf das Ergebnis ab
und hinterlegt dafür opt-in Auswahlzustände im Undo-Element. Undo und Redo bauen
das Layout synchron am wiederhergestellten Anker auf. Normales Tippen und
Einfügen behalten CodeEdits Standardverhalten. `SoftWrapLayoutTests` prüft den
echten Controller einschließlich Text, sichtbarer Fragmente, Auswahl,
Undo und Redo. `./selftest.sh joinundo` treibt denselben Menüpfad im gepackten
Markdown-Editor und zählt echte sichtbare `LineFragmentView`s.

Patch 4r (Tastaturauswahl mitscrollen, 2026-07-21): CodeEditTextView versucht
nach `moveDownAndModifySelection` zwar, die Auswahl sichtbar zu halten, nutzt
dafür aber deren Bounding-Rect. Dessen Fill-Rects sind auf den sichtbaren
Textbereich begrenzt; die mit Shift+Pfeil bewegte Kante kann deshalb unter den
Viewport laufen, während das Scrollziel weiter auf den sichtbaren oberen
Ausschnitt zeigt. Fastra verwendet CodeEdits bereits vorhandene, zuvor an
dieser Stelle ungenutzte Nicht-Pivot-Kante als kleines eindeutiges Scrollziel.
Der direkte `SoftWrapLayoutTests`-Regressionstest treibt den echten
`moveDownAndModifySelection`-Befehl in einem kurzen Viewport; der gepackte
Editor wird zusätzlich mit `./selftest.sh selectionscroll` geprüft. Dieser
Selbsttest wartet ausdrücklich auf beide Hälften des Markdown-Splits, fokussiert
den linken Quelleditor, sendet echte wiederholte Shift+↓-Events und misst die
sichtbare aktive Kante erst nach dem folgenden SwiftUI-Abgleich.

### Bundle-Größe — Apple-Silicon-only, ~57 MB (Stand 2026-07-15)

Das Bundle war einmal 489 MB. Drei Ursachen, alle in `build.sh` adressiert:
1. **Kein Intel.** Fastra wird nur für arm64 gebaut (Produktentscheidung 2026-07-08).
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
  Haupt-App- und SwiftPM-Ressourcenbundle sowie die lokalen KaTeX-, Mermaid-
  und highlight.js-Dateien.
- **Markdown-Vorschau:** `./selftest.sh markdown` lädt ein echtes temporäres PNG,
  eine TeX-Formel, einen Swift-Code-Block und ein Mermaid-Diagramm. Der Test liest
  unabhängig das fertige WebKit-DOM: Bildbreite, MathML, SVG und Highlight-Spans
  müssen tatsächlich vorhanden sein.
- **Klick-Sprung aus der Vorschau:** `./selftest.sh markdownjump` klickt im echten
  WebKit-DOM mitten in einen dreizeiligen Absatz und erwartet den Cursor auf der
  passenden Dateizeile. Genau dieser Fall lässt sich nicht als String-Test
  abbilden: Der Block kennt nur seine erste Zeile, die restlichen löst erst das
  Vorschau-JS über die Zeilenumbrüche vor der Klickstelle auf. Steht der Cursor
  am Absatzanfang statt in der geklickten Zeile, ist diese Auflösung defekt.
- **XPath-Sprung:** `./selftest.sh xpath` tippt die Query bewusst SOFORT nach
  dem Öffnen der Leiste, also bevor der asynchrone Index fertig ist — genau der
  Fall, in dem der Sprung verloren ging. Die Fixture ist deshalb absichtlich
  groß (rund 4000 Elemente): Bei einer winzigen Datei ist der Index manchmal
  schon fertig, und der Test wäre je nach Systemlast mal grün, mal rot. Die
  Erfolgsmeldung weist aus, welcher Fall geprüft wurde; steht dort „Index war
  bereits fertig", lief der Lauf am eigentlichen Risiko vorbei.
- **Hell-/Dunkel-Wechsel der Vorschau:** `./selftest.sh markdownappearance`
  startet bewusst dunkel und schaltet erst im laufenden Betrieb auf hell. Nur
  dieser Ablauf deckt den Fall auf, dass `underPageBackgroundColor` einmalig
  gesetzt wurde und WebKits eigene Ableitung einfriert — ein Start direkt im
  Zielmodus bliebe grün. Gegengeprüft: Mit der Farbe nur in `makeNSView`
  schlägt der Test fehl, mit dem Setzen bei jedem Update besteht er.
- **Nicht getestet:** visuelles Rendering von Diff/Tokens/Pillen und
  OSS-Framework-Interna von CodeEditSourceEditor. Kritische
  App-weite Bridges werden dagegen über In-App-Selbsttests abgesichert.
- **Zwei-Tab-Vergleich:** `./selftest.sh tabcompare` lädt zwei echte
  Dokumente, sendet einen Shift-Klick durch die Fenster-Eventpipeline und
  beobachtet unabhängig die stärkere Primär- und schwächere
  Vergleichsmarkierung. Anschließend müssen beide Tab-IDs als linkes/rechtes
  Feld im echten Vergleichs-Sheet erscheinen; ein normaler Klick muss die
  Paar-Auswahl wieder aufheben.

### Regressions-Schutz — Lehre aus dem „Zombie-Find-Bar" (2026-05-27)

Die Find-Leiste tauchte bei CMD+F mehrfach wieder auf. Der korrekte Befund nach gründlicher Analyse:

1. **Echter Root Cause:** Der „Zombie" ist NICHT die macOS-NSTextView-Find-Bar, sondern **CodeEditSourceEditors eigenes Find-Panel**. Der Editor installiert beim Laden einen EIGENEN lokalen `keyDown`-Monitor (`TextViewController.handleCommand`), der bei fokussiertem Editor CMD+F abfängt und `showFindPanel()` aufruft. Deshalb halfen `disableFindBars`/Menü-Purge nie — die zielen auf den FALSCHEN Mechanismus (Standard-NSTextView-Find), nicht aufs Editor-eigene Panel.
   **Was NICHT funktioniert:** Versuchen, den Konflikt über die Reihenfolge konkurrierender `NSEvent`-Local-Monitore zu gewinnen (LIFO/„neuester zuerst"). Diese Reihenfolge ist in der Praxis **nicht zuverlässig steuerbar** — Reinstall-auf-Notification und Launch-Timer waren beide flaky (per Selbsttest reproduziert).
   **Zwischenschritt (Write-back-Reconcile, reicht NICHT ganz):** CodeEditSourceEditors Coordinator schreibt `findPanelVisible` in den `SourceEditorState`-Binding ZURÜCK, wenn sein Panel öffnet (`SourceEditor+Coordinator`). Wir beobachten `editorState.findPanelVisible` in `EditorView`: wird es `true`, setzen wir es sofort `false` (der Editor reconciled → Panel schließt) und öffnen STATTDESSEN unsere Suchmaske (`.fastraShowSearchFile`). Problem: `showFindPanel()` animiert das Panel 0,15 s EIN, bevor unser `false` es wieder schließt — es **blitzt kurz auf** (reproduzierbar bei rapidem CMD+F + Klick ins Hauptfenster).
   **Finaler Fix (deterministisch, 2026-06-03):** `build.sh` patcht den resolved CESE-Checkout — der CMD+F-Zweig in `TextViewController.handleCommand` ruft nicht mehr `showFindPanel()`, sondern `return event` (CMD+F wird durchgereicht). Damit zeigt der Editor sein Panel NIE, egal wer das Monitor-Rennen gewinnt; CMD+F fängt ausschließlich unser App-Monitor ab. Der Patch fügt sich in das bestehende `build.sh`-Patch-Muster (nicht-invasiv, idempotent, verifiziert dass er greift, invalidiert die CESE-Build-Artefakte — SPM trackt Checkout-Änderungen sonst NICHT). Write-back-Reconcile + Reinstall-Hack (`installKeyMonitor`/`installFlagsMonitor` auf `didBecomeKey`/flagsChanged) bleiben als Sicherheitsnetz. Unser App-Monitor deckt zusätzlich CMD+F bei NICHT fokussiertem Editor sowie CMD+SHIFT+F/ESC ab.

2. **VERBOTENER Irrweg (kostete eine Session):** `NSApplication` zu subclassen, um CMD+F in `sendEvent` abzufangen — egal ob via `NSPrincipalClass` (wird unter SwiftUI ignoriert) oder via eigenem `main.swift`, der `CustomApp.shared` vor `App.main()` verankert. Letzteres ERSETZT SwiftUIs interne `SwiftUI.AppKitApplication`, deren eigenes Event-Routing dann fehlt → **die gesamte App wird maus-tot** (keine Klicks, kein Fenster-Schließen, CMD+Tab bringt nicht nach vorn). **Niemals NSApplication unter SwiftUI-Lifecycle subclassen.** Zur Laufzeit ist `NSApp.className == "SwiftUI.AppKitApplication"` — das ist korrekt und soll so bleiben.

3. **In-App-Selbsttests** (`SelfTest.swift`, kein Accessibility nötig — Events werden intern gepostet). **Aufruf: bevorzugt über den Runner `./selftest.sh` (alle Tests oder `./selftest.sh findbar jump`), direkt via `Fastra -selftest findbar -ApplePersistenceIgnoreState YES` oder Umgebungsvariable `FASTRA_SELFTEST=findbar`.** `-selftest findbar` postet ein echtes CMD+F bei fokussiertem Editor und **pollt ~1,2 s engmaschig**, ob das Editor-Find-Panel AUCH NUR KURZ auftaucht (eine Einzel-Messung am Ende würde das Aufblitzen verpassen). `-selftest newwindow` löst den echten ⌘N-Menübefehl aus, prüft ein zweites leeres Dokumentfenster mit unabhängigem Workspace, wechselt den Fokus zurück, belegt per echtem ⌘T das Routing globaler Commands und schließt anschließend den letzten Tab des Zweitfensters per echtem ⌘W (Fenster muss verschwinden; braucht ECHTEN Fenster-Fokus, s.u.). `-selftest fields` prüft, ob Suchen- UND Ersetzen-Feld echte, editierbare, betippbare Texteingaben sind (fing den toten Find-Feld-Bug). `-selftest tabswitch` prüft, ob der Editor beim Tab-Wechsel neu erzeugt wird (CESE schiebt Binding-Text nicht zurück → ohne `.id(activeTab.id)` bliebe der Inhalt stehen; via Objekt-Identität vorher≠nachher belegt). `-selftest cmdw` prüft CMD+W-Schließen (braucht ECHTEN Fenster-Fokus, s.u.). `-selftest jump` lädt Text mit unterschiedlich langen Vorzeilen (inkl. Emoji als UTF-16-Surrogatpaar) in einen Tab, postet exakt wie die GUI einen Treffer-Sprung (Zeile/Spalte-Pfad über `postMatchJump`) und liest die ECHTE Editor-Selektion zurück (`CodeEditTextView.TextView.selectedRange()`): der selektierte Text muss exakt der Treffer sein. Fing den toten Treffer-Sprung — CESE 0.15.x reconcilet `cursorPositions` von außen NIE (Bedingung `!= state.cursorPositions` vergleicht mit sich selbst, immer false; in `build.sh` gepatcht auf `!= controller.cursorPositions` + `scrollToVisible`). `-selftest replaceall` lädt den Demo-Inhalt („Nachname, Vorname"), setzt `(\w+), (\w+)` → `$2 $1`, ruft `applyAllInActiveBuffer()` und liest den ECHTEN Editor-`.string` zurück: er muss nach dem Replace den ersetzten Text zeigen (== Modell-Inhalt). Fing die Regression, dass „Alle ersetzen" im Editor folgenlos blieb (CESE übernimmt Binding-Änderungen nicht → in `EditorView` über `editorReloadNonce` an der `.id` eine Neuerzeugung erzwungen). `-selftest pilldrop` fokussiert das Ersetzen-Feld und treibt dessen Drag-Destination-Methoden mit einem `NSDraggingInfo`-Mock („$1"): Annahme (`draggingEntered == .copy`) + Einfügung müssen AUCH bei Fokus klappen. Fing den Bug, dass ein Gruppen-Pillen-Drop aufs fokussierte Ersetzen-Feld verpuffte (NSTextView lehnt Drops bei First-Responder ab → in `RegexFieldTextView` die Destination-Methoden überschrieben). `-selftest windows` ist ein reines Diagnose-Flag (Fenster-Dump über 10 s). Alle geben `SELFTEST <name>: PASS/FAIL` + Exit-Code aus; Fenster-Tests POLLEN bis 15 s auf ihr Fenster statt nach fixer Frist zu guarden. **Genau die Bug-Klasse (App-weites Event-/Eingabe-Verhalten), die reine Unit-Tests NICHT fangen.** Nach jeder Änderung an Lifecycle/Fenster/Monitoren mehrfach laufen lassen (Flakiness zeigt Race-Conditions).
   Seit v1.19.2 setzt `-selftest newwindow` zusätzlich eine markante
   Ausgangsgröße und vergleicht nach ⌘N den tatsächlichen `NSWindow`-Rahmen,
   damit SwiftUIs spätes Zurücksetzen auf die fitting size nicht unbemerkt bleibt.
   `-selftest multisearch` öffnet zwei Dokumentfenster mit je eigener
   Suchmaske und belegt, dass ein Treffer-Sprung ausschließlich Selektion,
   Fokus und Scrollziel des adressierten Workspace verändert.
   `-selftest sessionrestore` legt vor dem ersten Workspace eine isolierte
   gespeicherte Sitzung an und prüft den echten Kaltstart mit zwei Fenstern,
   drei dateibasierten Tabs, Projekt, aktivem Tab und ohne unbenannten Tab.
   `-selftest textop` bedient eine Texttransformation und beide
   Sortierrichtungen über den echten Notification-/Editorpfad und liest den
   tatsächlich sichtbaren Editorinhalt zurück.
   `-selftest markdown` prüft die echte WKWebView-Ausgabe eines lokalen Bildes,
   einer KaTeX-Formel, eines Mermaid-Diagramms und eines hervorgehobenen
   Code-Blocks; ein bloß vorhandenes HTML-Zielelement genügt nicht.
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

## Speicher-Diagnose: `leakscenario` + `leaks`

Das Diagnose-Szenario `-selftest leakscenario` übt Bildvorschau, PDF-Vorschau,
Hex-Ansicht und XPath-Leiste je einmal aus, schließt alles wieder, meldet
`LEAKSCENARIO READY <pid>` auf stderr und bleibt dann ~60 s am Leben — genau
für einen `leaks <pid>`-Durchlauf gegen die laufende App:

```bash
APP=".build/debug/Fastra.app/Contents/MacOS/Fastra"
ERR=$(mktemp); "$APP" -selftest leakscenario -ApplePersistenceIgnoreState YES 2>"$ERR" &
until grep -q READY "$ERR"; do sleep 1; done
leaks "$(awk '/READY/{print $3}' "$ERR")"
```

**Ergebnis 2026-07-17 (v1.25.0, Wunschpaket-Abschluss):** 288 Leaks /
14,4 KB — ausnahmslos bekannte Apple-XPC-Zyklen (`NSXPCConnection`/
`LNDaemonApplicationInterface`, AppIntents-Daemon-Anbindung); keine einzige
Fastra-Klasse in den Leak-Bäumen. Bundle-Wachstum des Wunschpakets
(Leitplanke ≤ ~1 MB): Debug-Binary v1.22.0 → v1.25.0 gemessen +536 KB
(überwiegend die generierten 4D-Symbollisten); Etappen 1–3 waren reiner
Code ohne neue Ressourcen. Gesamt klar unter der Leitplanke.

**Pflicht-Smoke-Test nach JEDER Änderung an App-Lifecycle, Fenster-Setup, Menüleiste oder Event-Monitoren — die Klasse von Bugs, die Unit-Tests nicht fangen:**
0. **Maus funktioniert überhaupt:** Klick in Editor setzt Cursor, Buttons reagieren, roter Schließen-Knopf schließt, CMD+Tab holt App nach vorn. (Diese Stufe zuerst — ist sie rot, ist alles andere irrelevant.)
1. CMD+F (Editor fokussiert) → Suchmaske öffnet, **kein** Editor-Find-Panel.
2. CMD+SHIFT+F → Ordner-Modus, Fenster wächst, kein Find-Panel.
3. ESC bei vorderer Suchmaske → blendet aus. ESC sonst → stört nichts.
4. CMD+F mehrfach hintereinander → kein Zombie, kein Doppel-Öffnen.
5. App-Wechsel raus und zurück, dann CMD+F → Suchmaske kommt wieder nach vorn.

Nach größeren Funktionspaketen ergänzt der gelegentliche, reale
[Menüvolltest](MANUAL-MENU-FULL-TEST.md) diese kurze Pflichtprüfung. Seine
wegwerfbare Test-App besitzt eine eigene Bundle-ID und bleibt im Projekt-Root;
er wird nur nach ausdrücklicher Freigabe des Nutzer-Desktops ausgeführt.
