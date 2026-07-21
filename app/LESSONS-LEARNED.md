# Fastra — verifizierte Build- und Editor-Fallen

Diese Notiz bewahrt technische Befunde, deren Ursachen und die verifizierten
Gegenmaßnahmen. Die historische Abschnittsnummer `F` bleibt erhalten, weil
Code-Kommentare gezielt auf einzelne Unterpunkte verweisen.

---

## A · SPM- und Build-Gotchas (überraschend & ärgerlich)

### A.1 `Info.plist` als SPM-Resource ist verboten
**Beobachtung:** Die natürliche Annahme war, `Info.plist` in `Sources/Fastra/Resources/` zu legen und über `.process("Resources")` einzubinden. SPM bricht dann mit einem harten Fehler ab:
> error: resource 'Resources/Info.plist' in target 'Fastra' is forbidden; Info.plist is not supported as a top-level resource file in the resources bundle

**Lösung, die funktioniert (ohne Warnung):** `Info.plist` an den **Package-Root** legen (neben `Package.swift`) und per Linker-Section in die Binary einbetten:

```swift
.executableTarget(
    name: "Fastra",
    resources: [.process("Resources")],
    linkerSettings: [
        .unsafeFlags([
            "-Xlinker", "-sectcreate",
            "-Xlinker", "__TEXT",
            "-Xlinker", "__info_plist",
            "-Xlinker", "Info.plist"
        ])
    ]
)
```

Das funktioniert sowohl mit `swift build` als auch beim Öffnen in Xcode. Wenn `Info.plist` irgendwo unter `Sources/` liegt — selbst mit `exclude: ["Info.plist"]` — gibt es eine "unhandled file"-Warnung.

### A.2 `#Preview { … }` killt `swift build`
**Beobachtung:** Der praktische SwiftUI-Macro `#Preview { ContentView() }` braucht `PreviewsMacros` von Xcode. Bei `swift build` aus dem Terminal kommt:
> error: external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found

**Lösung:** `#Preview`-Blöcke in den Sources weglassen, **wenn der Workflow CLI-Builds einschließt**. Stattdessen Previews erst nach dem Öffnen in Xcode hinzufügen, oder via `#if DEBUG && canImport(SwiftUI) && canImport(PreviewsMacros)` einklammern (umständlich).

### A.3 `Assets.xcassets` funktioniert ohne Xcode
Anders als befürchtet wird `Assets.xcassets` (inkl. `AppIcon.appiconset`) vom SPM-Build sauber kompiliert. Ergebnis ist `Assets.car` neben der Binary. Das App-Icon erscheint allerdings nur, wenn `Info.plist` `CFBundleIconName=AppIcon` und `CFBundleIconFile=AppIcon` enthält UND die App in einer richtigen `.app`-Bundle-Struktur läuft (siehe A.4).

### A.4 `swift run` ≠ "richtige Mac-App"
**Beobachtung:** `swift run` startet die Binary im Terminal-Kontext. Das Fenster erscheint, aber:
- Dock-Icon fehlt
- Menüleiste integriert nicht vollständig
- App quittiert nicht über ⌘Q (Terminal fängt es ab)
- LSUIElement-Verhalten ist seltsam

**Lösung für volle Mac-App-Erfahrung:** `open -a Xcode Package.swift`, dann ▶. Xcode produziert ein echtes `.app`-Bundle. Alternativ manuelles Bundling per Skript.

### A.5 `Bundle.module` kann einen kaputten Release auf dem Build-Mac kaschieren

**Beobachtung:** SwiftPMs generierter `resource_bundle_accessor.swift` sucht ein
Ressourcenbundle zuerst direkt unter `Bundle.main.bundleURL`. Als zweiten Pfad
kompiliert SwiftPM den absoluten lokalen `.build/<Konfiguration>`-Pfad ein.
Fastra legte die Bundles fälschlich unter `Contents/Resources` ab. Auf dem
Build-Mac startete die App trotzdem über den absoluten Fallback; auf einem
anderen Mac crashte sie sofort in `Bundle.module`.

**Verbindliche Lösung:** In Fastra und betroffenen Fremdmodulen eigene Locator
verwenden, die in einer gepackten App zuerst `Bundle.main.resourceURL` prüfen,
und SwiftPM-`.bundle`-Verzeichnisse unter `Contents/Resources` kopieren.
Bundles direkt in der `.app`-Wurzel sind keine Alternative: Codesign lehnt sie
als „unsealed contents" ab. Danach
`verify-portable-app.sh` ausführen: Das Skript blendet alle lokalen
Build-Bundles kurz aus und verlangt einen echten fensterlosen `localization`-
Start aus der gepackten App. `build.sh` und `install.sh` rufen dieses Gate
automatisch auf. Codesign, Notarisierung, Stapler und Gatekeeper prüfen
Integrität und Vertrauen, aber nicht, ob die App ihre Laufzeitressourcen findet.

## F · CodeEdit-Build-Realität und Checkout-Patches

Mehrere voneinander unabhängige Probleme der gepinnten Abhängigkeiten treffen
aufeinander, sobald Fastra über die Kommandozeile gebaut wird. `build.sh`
kapselt und verifiziert die weiterhin benötigten Gegenmaßnahmen.

### F.1 API-Drift in CodeEditSourceEditor 0.15.0 → 0.15.2

In 0.15.2 (gepinnt in `Package.resolved`) heißt der öffentliche Typ
`SourceEditor` und nimmt:

```swift
SourceEditor(
    $text,
    language: CodeLanguage.detectLanguageFrom(url: someURL),   // oder .default
    configuration: SourceEditorConfiguration(
        appearance: .init(
            theme: editorTheme,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            wrapLines: false,
            tabWidth: 4
        )
    ),
    state: $editorState        // SourceEditorState mit cursorPositions etc.
)
```

`EditorTheme` hat upstream 16 obligatorische Felder (text, insertionPoint,
invisibles, background, lineHighlight, selection, plus 10 Token-Attribute)
und nimmt jeweils `EditorTheme.Attribute(color:bold:italic:)`-Werte mit
`NSColor`, nicht `Color`. Fastras Patch 4m ergänzt nur für Fastra ein
optionales Feld `methods`, das standardmäßig `commands` übernimmt. Dadurch
bleiben alle fremden Themes quellkompatibel; die 4D-Themes in
`EditorView.swift` können trotzdem die eigene Methodenfarbe setzen.

### F.2 SwiftLint-Build-Plugin macht jeden CLI-Build kaputt

Sowohl `CodeEditSourceEditor` als auch `CodeEditTextView` deklarieren ein `BuildToolPlugin` für SwiftLint (`lukepistrol/SwiftLintPlugin`). Das prebuilt SwiftLint-Binary unter `.build/artifacts/swiftlintplugin/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint` wirft beim Start:

```
SourceKittenFramework/library_wrapper.swift:58:
Fatal error: Loading sourcekitdInProc.framework/Versions/A/sourcekitdInProc failed
```

Das `sourcekitdInProc.framework` existiert sowohl in CommandLineTools (`/Library/Developer/CommandLineTools/usr/lib/`) als auch in Xcode (`/Applications/Xcode.app/.../XcodeDefault.xctoolchain/usr/lib/`). `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` allein und auch `--disable-sandbox` reichen nicht — das prebuilt Binary findet das Framework über `@rpath` nicht.

**Workaround:** Lokal die `plugins: [.plugin(name: "SwiftLint", …)]`-Blöcke und die `SwiftLintPlugin`-Dependency aus den `Package.swift`-Dateien im `.build/checkouts/`-Ordner herauskommentieren. Das Build-Skript `build.sh` macht das automatisch via `perl -i -0pe`-Patches und re-applied sie nach jedem `swift package update`.

### F.3 CodeEditSymbols vergisst seine eigenen Resources

`CodeEditSymbols/Package.swift` deklariert das Target ohne `resources:`-Block, der Source-Code referenziert aber `Bundle.module.image(forResource:)`. Build-Fehler: `type 'Bundle' has no member 'module'`. **Workaround:** `resources: [.process("Symbols.xcassets")]` ergänzen (auch im build.sh automatisiert). Sollte als Issue beim Upstream gemeldet werden.

### F.4 `#Preview`-Macro-Plugin braucht Xcode-Toolchain

In `CodeEditSourceEditor/Sources/CodeEditSourceEditor/Find/PanelView/` stehen `#Preview` (Xcode-SwiftUI-Preview-Macro)-Blöcke in produktiven Sources, nicht in Test-Targets. Das Macro-Plugin `PreviewsMacros` ist nur in Xcode-Toolchains enthalten, nicht in CommandLineTools. Build-Fehler: `external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found`.

**Workaround:** Build über Xcode-Toolchain treiben:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun --toolchain XcodeDefault swift build
```

`xcrun --toolchain XcodeDefault` wechselt `swift` selbst auf die Xcode-Variante; `DEVELOPER_DIR` zusätzlich, damit Sub-Tools (sourcekitd, swift-frontend-Plugins) die Xcode-Pfade finden. Beides ist nötig — eines allein reicht nicht.

### F.5 Konsequenz: build.sh

`build.sh` kapselt die hier beschriebenen Checkout-Patches vollständig. Aufruf:

```bash
./build.sh           # debug
./build.sh release   # release
```

Die Patches sind idempotent und ändern den `.build/checkouts/`-Inhalt, nicht den
Produktcode. Nach `swift package update` muss das Skript erneut laufen.

### F.6 Kosmetische Linker-Warnungen sind harmlos

Beim Linkschritt erscheinen viele Warnungen der Form

```
warning: (arm64) /Users/Khan/Developer/CodeEditLanguages/DerivedData/.../parser.o
        unable to open object file: No such file or directory
```

Das sind Debug-Info-Pfade aus den prebuilt TreeSitter-Static-Libraries, die auf den Build-Host des Library-Autors zeigen. Sie betreffen nur DWARF-Symbolisierung, nicht die Funktion. Wenn das langfristig stört: TreeSitter selbst bauen statt prebuilt.

### F.6b CodeEditSourceEditor.MinimapView crasht auf Gray-Colorspace-Farben

Beim ersten Start kracht der Editor mit `NSInvalidArgumentException` im AppKit-Layout:

```
*** -getHue:saturation:brightness:alpha: not valid for the NSColor
    Generic Gray Profile Gamma 2,2 colorspace; need to first convert colorspace.
```

Ursache: `MinimapView.setTheme()` ruft auf jeder Theme-Farbe `brightnessComponent` auf, was nur im RGB-Colorspace funktioniert. `NSColor.white` und `NSColor(white:alpha:)` liegen im **Generic-Gray-Profile** — die exception fliegt sofort beim Initial-Layout (lange bevor man die Minimap überhaupt sieht).

**Lösung:** Alle Farben im `EditorTheme` konsequent über `NSColor(srgbRed:green:blue:alpha:)` erzeugen. Helper in `EditorView.swift`:

```swift
private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
```

Diagnose via `lldb -o "b objc_exception_throw" -o "run"` — ohne den Breakpoint sieht man im Stderr nichts, weil SwiftUI die Exception schluckt und der Stack-Trace ein generischer QuartzCore-CA::Transaction-Crash ist.

### F.9 CMD+F-Zombie-Patch — Editor-eigenes Find-Panel an der Quelle abschalten (2026-06-03)

`CodeEditSourceEditor` installiert beim Laden einen eigenen `keyDown`-Monitor (`TextViewController.handleCommand`), der bei fokussiertem Editor CMD+F abfängt und sein internes Find-Panel via `showFindPanel()` zeigt. Wir wollen stattdessen unsere eigene Suchmaske. Das Rennen der konkurrierenden `NSEvent`-Local-Monitore (LIFO) ist **nicht zuverlässig gewinnbar** — das Panel blitzte trotz Write-back-Reconcile (`EditorView.onChange(findPanelVisible)`) noch kurz auf, weil `showFindPanel()` 0,15 s einanimiert.

**Workaround (vierter build.sh-Patch):** Im resolved Checkout `…/Controller/TextViewController+Lifecycle.swift` den CMD+F-Zweig von

```swift
case (commandKey, "f"):
    _ = self.textView.resignFirstResponder()
    self.findViewController?.showFindPanel()
    return nil
```

auf `return event` umbiegen (CMD+F durchreichen statt Panel zeigen). Damit fängt CMD+F ausschließlich unser App-Monitor ab — deterministisch, unabhängig von der Monitor-Reihenfolge.

**Zwei Stolpersteine:**
1. SPM trackt Quell-Änderungen **innerhalb** von `.build/checkouts/` NICHT (Dependencies gelten als immutable). Der Patch landet sonst nicht im Binary. → build.sh verwirft nach dem Patchen die CESE-Build-Artefakte (`.build/*/{debug,release}/CodeEditSourceEditor.build` + `.swiftmodule`), damit SPM neu übersetzt.
2. Der Patch **verifiziert sich selbst** (`grep` nach `showFindPanel()` muss danach leer sein, sonst `exit 1`) — nach einem Versions-Bump mit geänderter Quelle kehrt der Zombie sonst lautlos zurück.

Verifikation: `./selftest.sh findbar` pollt auf transientes Aufblitzen. Volle
Begründung und verbotene Irrwege stehen in
`../docs/BUILD-AND-TEST.md` unter „QA-Strategie“.

### F.10 Toter cursorPositions-Reconcile — Treffer-Sprung an der Quelle reparieren (2026-06-04)

Der Treffer-Sprung (CMD+G / Listen-Klick / Voriger-Nächster) setzt `editorState.cursorPositions`; CodeEditSourceEditor soll daraus die Editor-Selektion ableiten und in Sicht scrollen. Tat es NIE. Grund ist ein Bug in CESE 0.15.x: `SourceEditor.updateControllerWithState` prüft

```swift
if let cursorPositions = state.cursorPositions, cursorPositions != state.cursorPositions {
    controller.setCursorPositions(cursorPositions)
}
```

Die Bedingung vergleicht die frisch gebundene Variable **mit sich selbst** → immer `false`. `setCursorPositions()` läuft dadurch nur einmal in `makeNSViewController` (Editor-Erzeugung); jede spätere Änderung von außen verpufft. Reine Unit-Tests sahen das nicht — sie durchlaufen das CESE-Zeile/Spalte→Selektion-Mapping nicht.

**Workaround (fünfter build.sh-Patch):** Im resolved Checkout `…/SourceEditor/SourceEditor.swift` die Bedingung auf den IST-Stand des Controllers umbiegen und beim Anwenden in Sicht scrollen:

```swift
if let cursorPositions = state.cursorPositions, cursorPositions != controller.cursorPositions {
    controller.setCursorPositions(cursorPositions, scrollToVisible: true)
}
```

Gleiche zwei Stolpersteine wie F.9 (SPM trackt Checkout-Änderungen nicht → CESE-Artefakte verwerfen; Patch verifiziert sich selbst via `grep`). Zusätzlich nötig: `CodeEditTextView` explizit als Dependency deklariert (war transitiv, 0.12.1), damit der Selbsttest die echte Editor-Selektion typsicher zurücklesen kann.

Aufgedeckt und verifiziert durch `./selftest.sh jump`: Der Test lädt Text mit
unterschiedlich langen Vorzeilen einschließlich Emoji-Surrogatpaar, postet
einen Sprung exakt wie die GUI und liest `TextView.selectedRange()` zurück.
Der selektierte Text muss exakt der Treffer sein; damit ist auch der Offset-Fix
(Zeile/Spalte statt absoluter Range) Ende-zu-Ende belegt.

### F.11 Abgebrochene Vervollständigung darf keinen unsichtbaren Zustand behalten (2026-07-19)

`CodeEditSourceEditor` setzt in `SuggestionViewModel.showCompletions` vor der
asynchronen Delegate-Anfrage `activeTextView`. Fastras 4D-Delegate antwortet
beim ersten Buchstaben absichtlich mit `nil`, weil die automatische
Vervollständigung erst ab zwei Zeichen erscheinen soll. Upstream kehrte dann
sofort zurück, ohne den bereits gesetzten Zustand zu schließen. Die zweite
Anfrage hielt `activeTextView` deshalb für aktiv und aktualisierte lediglich
eine nicht sichtbare Liste.

**Workaround (Patch 4c1 in `build.sh`):** Im `nil`-Zweig
`self.willClose()` aufrufen und erst dann zurückkehren. Das ist enger als ein
neuer Trigger oder ein eigener Popup-Controller: Es räumt nur die unvollständige
Upstream-Anfrage auf und lässt die bestehende CESE-Bedienung unverändert.

**Regressionstest:** `./selftest.sh completion4d` erzeugt eine echte
`.4dm`-Fixture, lädt sie in den laufenden Editor und fügt `AL` über die
öffentliche TextView-Eingabe ein. Er beobachtet danach das echte Child-Window
mit seiner `NSTableView`. Anschließend öffnet er die Liste über ⌃Leertaste und
prüft ↓, gezielten Klick sowie Doppelklick bis zur Einfügung von `ALERT`.
Der kurze Wait vor ↓ ist kein Produkt-Delay: CESE befüllt die Tabelle über
einen asynchronen Publisher; ohne abgeschlossenen Reload konnte eine korrekte
Auswahl direkt wieder auf die Startzeile zurückspringen.

### F.12 Feste Soft-Wrap-Spalten brauchen eine gemeinsame Layoutgeometrie (2026-07-19)

CodeEditTextView begrenzt Soft Wrap upstream ausschließlich auf die
Viewportbreite. CodeEditSourceEditors vorhandene Reformatting-Linie berechnete
ihre Position zugleich mit `font.charWidth / 2` und
`textViewInsets.left / 2`. Damit lag sie weder an der konfigurierten Textspalte
noch an einer reproduzierbaren Umbruchgrenze. Zusätzlich zeichnete die bereits
nach rechts versetzte Guide-View mit ihrem `frame`; dieser liegt im
Koordinatensystem des Eltern-Views und verschob Linie und Schattierung beim
Zeichnen ein zweites Mal.

**Workaround (Patch 4n in `build.sh`):**

- `TextLayoutManager.maximumWrapWidth` begrenzt die vorhandene
  Viewport-Layoutbreite optional; der Viewport bleibt immer die harte
  Obergrenze.
- `SourceEditorConfiguration.Behavior.wrapAtColumn` transportiert das
  Spaltenziel. Controller und Guide berechnen beide
  `Spalte × (reale Schriftbreite + Kern)` ab dem tatsächlichen linken
  Layout-Inset und reagieren auf Font-/Kernwechsel.
- `ReformattingGuideView` zeichnet in lokalen `bounds`.
- Liefert CoreText bei extrem schmaler Breite keinen Fortschritt, fällt der
  Typesetter auf genau ein vollständiges zusammengesetztes Zeichen zurück.
- Beim Wechsel von Soft Wrap darf nicht der absolute Y-Scrollwert erhalten
  bleiben: Durch die neue Zahl der Umbruchfragmente zeigt er auf eine andere
  logische Zeile. Zeitversetzte Nachkorrekturen sind ebenfalls falsch: CodeEdits
  Lazy-Layout verschiebt den Anker danach erneut und lässt den Ausschnitt
  sichtbar zwischen zwei Positionen pendeln. Der Patch merkt die tatsächlich
  oberste Textzeile, konvergiert in höchstens 24 Layoutschritten innerhalb
  desselben Runloops und setzt nur die stabile Endposition sichtbar. Ein
  vollständiges Layout aller vorherigen Zeilen bleibt unnötig.

**Regressionen:** `SoftWrapLayoutTests` verwenden den realen
`TextViewController`, beobachten dessen maximale Layoutbreite, Viewport-Minimum,
Guide-Geometrie samt Gutter und Fontwechsel, rendern die versetzte Guide-View in
ein Bitmap und prüfen Unicode-Fortschritt. `./selftest.sh softwrapmodes` prüft
zusätzlich im echten Fenster Fensterbreite, Page Guide und feste Spalte sowie
Resize, Zoom, Auswahl, Text, Dirty-Zustand und Undo-Stack.
`./selftest.sh softwrapanchor` scrollt in einem Dokument mit 2.400 langen Zeilen
tief nach unten und beobachtet alle 20 ms unabhängig, dass beim Aus- und
Einschalten dieselbe logische Textzeile ohne Zwischenabweichung oben bleibt.

### F.13 Rechteckzeilen dürfen keine Umbruchfragmente sein (2026-07-19)

CodeEditTextView erzeugt upstream die Spaltenauswahl aus allen sichtbaren
`lineFragments`. Unter Soft Wrap wird eine lange logische Zeile deshalb
mehrfach ausgewählt. Eine bloße Filterung der Fragmente reicht nicht: Tabs,
kurze Zeilen und zusammengesetzte Unicode-Zeichen brauchen weiterhin eine
eindeutige Spalten- und UTF-16-Abbildung.

**Workaround (Patch 4o in `build.sh`):** Die versionierte Ersatzdatei unter
`Patches/CodeEditTextView/` bildet jeden Drag-Punkt zuerst auf logische
NSString-Zeile und visuelle Spalte ab. Sie iteriert Swift-`Character`, zählt
Tabs bis zum nächsten Tabstopp und setzt pro logischer Zeile genau einen
graphem-sicheren UTF-16-Bereich. Copy/Paste, Paste Column und Zeichen-
Transformationen teilen diesen Zustand. Mehrfachänderungen werden im
`CEUndoManager` ausdrücklich gruppiert.

Zwei Randfälle brauchen eigene Wächter:

- Ein Nullbereich auf einer kurzen Zeile darf bei Backspace/Delete nicht in
  Upstreams „Zeichen am Cursor löschen“-Pfad fallen; er bleibt unverändert.
- Eine Zeichen-Transformation darf einen Nullbereich nicht als „keine Auswahl
  = ganzes Dokument“ interpretieren.

`./selftest.sh colsel colselwrap colpaste` prüft diese Fälle zusammen mit
echtem Soft Wrap, Vorwärts/Rückwärts, Tabs, CRLF, Unicode, Clipboard-
Mismatch-Regel und exakt einer Undo-Gruppe.

### F.14 Der Dokumentend-Cursor ist nicht die rechte Kante der letzten Textzeile (2026-07-20)

Endet ein Dokument mit einem Zeilenumbruch, liegt `rectForOffset(documentEnd)`
bereits am linken Rand der nachfolgenden leeren Dateiende-Zeile.
`TextSelectionManager.getFillRects` verwendete diese X-Position trotzdem als
rechte Kante der vorherigen Textzeile. Bei „Alles auswählen“ entstand dort
deshalb ein Auswahlrechteck mit Breite null: Die Range war korrekt, die letzte
Textzeile wirkte aber unmarkiert. Soft Wrap machte den Effekt durch die
Fragmentgeometrie auffälliger, war jedoch nicht die Ursache.

**Workaround (Patch 4p in `build.sh`):** Enthält das letzte ausgewählte
Zeilenfragment eine LF-, CRLF- oder CR-Zeilenendung, reicht seine Markierung
bis zum rechten Textrand. Ohne abschließenden Zeilenumbruch bleibt die bisherige
zeichenexakte rechte Kante erhalten.

**Regression:** `SoftWrapLayoutTests.selectAllIncludesLastVisibleLine` setzt
die echte CodeEdit-Auswahl per `selectAll`, prüft die vollständige
Dokumentrange und verlangt für die letzte Textzeile ein sichtbares
Auswahlrechteck. Der Fall läuft getrennt mit LF, CRLF und CR.

### F.15 Große Ersetzungen brauchen einen expliziten Auswahl- und Layoutanker (2026-07-20)

„Zeilen verbinden“ ersetzt den bearbeiteten Bereich bewusst in einer einzigen
Undo-fähigen Mutation. CodeEditTextView setzt die Auswahl danach standardmäßig
ans Ende des Ersatztexts. Bei einem ganzen Markdown-Dokument ist das eine
einzige, tausende Zeichen lange Soft-Wrap-Zeile. Der Cursor am Zeilenende und
der noch am Dokumentanfang liegende Viewport können dadurch während der
asynchronen Highlight-Aktualisierung verschiedene Layoutstände beobachten:
Der Modelltext bleibt vollständig, aber Text und Gutter werden leer gerendert.

Beim Undo entsteht ein zweiter Fehler: `CEUndoManager` rekonstruiert die Auswahl
aus der Mutationsrange und markiert deshalb das gesamte alte Dokument. Sein
Scrollanker kann dann vor der neu aufgebauten ersten Zeile liegen, sodass ein
leerer Bildschirm oberhalb von Zeile 1 erscheint.

**Workaround (Patch 4q in `build.sh`):** Fastras Textoperationspfad bildet die
alte Auswahl bewusst auf den Ersatzbereich ab. Bei einer Ganzdokument-Operation
ohne Auswahl bleibt der Cursor am stabilen Blockanfang. Dasselbe gilt, wenn
Cmd+A das gesamte Dokument als Operationsbereich ausgewählt hat: Die riesige
Auswahl wird nach Verbinden sowie für Undo/Redo zu einem Cursor am Anfang
reduziert, weil sie sonst selbst zum fehlerhaften Layoutanker wird. Eine
opt-in-Erweiterung des `CEUndoManager` speichert nur für solche Operationen die
stabilen Zustände vor und nach der Mutation. Undo und Redo bauen das Layout
synchron an diesem Anker auf und scrollen ihn sichtbar. Gewöhnliches Tippen,
Einfügen und CodeEdits übrige Undo-Semantik bleiben unverändert.

**Regressionen:** `SoftWrapLayoutTests.joinLinesAndUndoKeepTextVisible` nutzt
einen echten `TextViewController` mit einer 61-zeiligen CSS-Datei, Soft Wrap
aus und echter Vollauswahl. Es verlangt nach Verbinden, Undo und Redo jeweils
korrekten Text, Cursor am Dokumentanfang und sichtbare Layoutfragmente.
`./selftest.sh joinundo` führt denselben Cmd+A-Menüpfad im gepackten Editor aus
und zählt reale sichtbare `LineFragmentView`s; ein bloßer Vergleich des
Modelltexts hätte den ursprünglichen Fehler nicht erkannt.

### F.16 Ad-hoc-Builds verändern die TCC-Code-Identität (2026-07-20)

macOS bindet Ordnerfreigaben wie Desktop und Dokumente nicht nur an die
Bundle-ID, sondern auch an die Code-Anforderung der App. Wiederholt nach
`/Applications` kopierte Ad-hoc-Builds besitzen keine stabile Developer-Team-
Identität. Im TCC-Log erscheint dann trotz unveränderter Bundle-ID
`Failed to match existing code requirement`; macOS fragt die Ordnerfreigabe
erneut ab. Der Dialog beweist dabei nicht, dass das geöffnete Projekt in diesem
Ordner liegt: Auch ein Systemdialog oder eine frühere URL kann den geschützten
Dienst ansprechen.

**Konsequenz:** `build.sh` und `install.sh --no-notarize` legen Test-Bundles
ausschließlich im Projekt-Root ab. Nur `install.sh` nach erfolgreicher
Notarisierung, Stapler-Prüfung, Gatekeeper-Abnahme und Codesignaturprüfung darf
`/Applications/Fastra.app` ersetzen. So bleibt die Code-Identität produktiver
Installationen über Versionswechsel stabil.

### F.17 Auswahl-Bounding-Rects sind kein stabiler Tastatur-Scrollanker (2026-07-21)

CodeEditTextView ruft nach jedem `moveDownAndModifySelection` korrekt
`scrollSelectionToVisible()` auf. Die Funktion verwendete jedoch das
Bounding-Rect der Auswahl. Dieses entsteht aus Fill-Rects, die auf den aktuell
sichtbaren Textbereich begrenzt sind. Verlässt die bewegte Auswahlkante den
Viewport, beschreibt das vermeintliche Scrollziel daher weiterhin den schon
sichtbaren Teil; die feste Pivot-Kante bleibt im Bild, die aktive Kante läuft
unten heraus.

**Workaround (Patch 4r in `build.sh`):** CodeEdits vorhandener Helfer
`offsetNotPivot` bestimmt die tatsächlich bewegte Kante. Nur deren kleines
Zeichenrechteck wird sichtbar gescrollt; bei einer Bewegung zurück über den
Pivot wechselt die aktive Seite automatisch. Eine gewöhnliche Cursorbewegung
behält ihr bisheriges Verhalten, weil Pivot und Cursorposition dort
zusammenfallen.

**Regressionen:** `SoftWrapLayoutTests.extendingSelectionDownScrollsActiveEdgeIntoView`
verwendet den echten `TextViewController`, führt den NSTextInputClient-Befehl
24-mal aus und verlangt sowohl einen veränderten Viewport als auch eine
sichtbare Nicht-Pivot-Kante. `./selftest.sh selectionscroll` wiederholt das mit
dem Editor aus dem gepackten App-Bundle. Der Test wartet auf den vollständigen
Markdown-Split, sendet echte wiederholte Shift+↓-Tastaturereignisse an den
fokussierten linken Quelleditor und misst nach dem SwiftUI-Abgleich unabhängig
die untere Auswahlrange-Kante. Ein unmittelbarer direkter Methodenaufruf reicht
für diese Produktwirkung nicht als Regressionsschutz.
