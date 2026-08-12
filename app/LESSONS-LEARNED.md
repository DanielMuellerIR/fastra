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
als „unsealed contents" ab. Danach `verify-portable-app.sh` ausführen: Das
Skript blendet alle lokalen Build-Bundles kurz aus und verlangt einen echten
fensterlosen `localization`-Start sowie eine Ordnersuche mit dem gebündelten
ripgrep aus der gepackten App. Der zweite Lauf ist nötig, weil ein einzelner
später Pfad (konkret 2026-08-05: `RipgrepFileEnumerator`) beim Start noch
unberührt bleiben und erst beim ersten Suchlauf in `Bundle.module` crashen
kann. `build.sh` und `install.sh` rufen dieses Gate automatisch auf. Codesign,
Notarisierung, Stapler und Gatekeeper prüfen Integrität und Vertrauen, aber
nicht, ob die App ihre Laufzeitressourcen findet.

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
zusammenfallen. Bei einem langen Soft-Wrap-Dokument reicht dieser synchrone
Aufruf allein nicht: Eine weit unten liegende Zeile besitzt zunächst nur eine
geschätzte Höhe. Das Scrollen kann sie erstmals auslegen und dadurch ihre echte
Position unter den gerade erreichten Viewport verschieben. Ein ausschließlich
für verbleibende Auswahlen geplanter zweiter Abgleich im folgenden Main-Runloop
verwendet die stabilisierte Position, ohne normale Cursorbewegungen doppelt zu
bearbeiten. AppKit rundet den Scrollursprung außerdem auf Gerätepixel. Das
Scrollziel erhält deshalb vertikal einen Punkt Reserve; sonst kann die aktive
Zeichenbox trotz korrekter Rechnung um einen Bruchteil eines Punkts außerhalb
des Viewports bleiben.

**Regressionen:** `SoftWrapLayoutTests.extendingSelectionDownScrollsActiveEdgeIntoView`
verwendet den echten `TextViewController`, beginnt in einem bereits nach unten
versetzten kurzen Viewport, führt den NSTextInputClient-Befehl sechsmal aus und
verlangt sowohl einen veränderten Viewport als auch eine sichtbare
Nicht-Pivot-Kante. `./selftest.sh selectionscroll` wiederholt das mit dem Editor
aus dem gepackten App-Bundle. Der Test stellt über den produktiven
SessionStateStore ein Markdown-Dokument mit 2.200 stark unterschiedlich langen
Soft-Wrap-Zeilen wieder her, wartet auf den vollständigen Markdown-Split und
postet sechs Shift+↓-Tastaturereignisse über getrennte Runloop-Durchläufe an den
fokussierten linken Quelleditor. Vor dem verzögerten Abgleich lag die echte
Auswahlkante reproduzierbar unter dem unveränderten Viewport. Ein unmittelbarer
direkter Methodenaufruf reicht für diese Produktwirkung nicht als
Regressionsschutz.

### F.18 Ein Edit besitzt einen alten und einen neuen Bereich (2026-07-22)

`NSTextStorageDelegate.didProcessEditing` meldet `editedRange` im Zustand nach
der Änderung. Zusammen mit `changeInLength` lässt sich daraus der vorher
ersetzte Bereich berechnen. CodeEditTextView benötigte diesen alten Bereich
zum Entfernen ersetzter Layoutzeilen, invalidierte danach aber irrtümlich
erneut ihn statt des neuen Bereichs.

Bei einer reinen Einfügung hat der alte Bereich die Länge null. In einer
bereits ausgelegten langen Soft-Wrap-Zeile konnte deshalb das bisherige
Zeilenende als Fragment erhalten bleiben, obwohl die logische Zeilenlänge
schon den neuen Text enthielt. Sichtbar wirkte das Wort vollständig, aber für
seinen angehängten Teil fehlten Zeichenrechtecke: `rectForOffset` fiel auf ein
Nullbreiten-Rechteck zurück, `textOffsetAtPoint` lieferte `nil`, und AppKits
Fenster-Hit-Test landete im umgebenden Scroll-View. Ein Doppelklick ließ daher
die vorherige Auswahl unverändert.

**Workaround (Patch 4s in `build.sh`):** Der abgeleitete alte Bereich heißt
bewusst `replacedStringRange` und wird nur zum Entfernen der vorherigen
Zeilenstruktur verwendet. Nach `insertNewLines` invalidiert CodeEditTextView
den von NSTextStorage gelieferten neuen `editedRange`. Löschungen bleiben
korrekt: Ihr neuer Bereich ist leer, und CodeEdits bestehender Leerbereichs-
Pfad markiert die Zeile am Editierpunkt beziehungsweise die letzte Zeile.

**Regression:** `./selftest.sh wordclick` stellt den realen Zustand her, indem
es in einem langen Markdown-Dokument zuerst nur den Wortanfang auslegt und den
Rest anschließend über `TextView.insertText` einfügt. Danach sendet der Test
echte Fensterereignisse als Doppelklick an Wortanfang und Wortende. Ein reiner
Modell- oder Frische-Layout-Test reicht nicht: Text und Zeilenlänge waren auch
im Fehlerfall korrekt, nur die alten Trefferflächen blieben bestehen.

### F.19 Eine überschriebene hitTest darf hidden nicht ignorieren (2026-07-24)

AppKits Default-`hitTest` sortiert verborgene Views selbst aus. Wer die
Methode überschreibt, übernimmt diese Pflicht mit. `MinimapView.hitTest`
(CodeEditSourceEditor) beantwortete Treffer im eigenen sichtbaren Bereich
immer selbst und prüfte `isHidden` nie; `mouseDown`/`mouseDragged` sind dort
zusätzlich bewusst leere Überschreibungen („Eat mouse events“). Bei
ausgeblendeter Minimap — Fastras Default — lag dadurch eine unsichtbare,
rund 90 pt breite Fläche über der rechten Editorkante: Klicks und
Doppelklicks auf Text in diesem Band kamen nie im Editor an. Im
Markdown-Split fiel es zuerst auf, weil der Editor dort schmal ist und
umbrochene Zeilen bis an den Scrollbalken reichen; betroffen war aber jede
Ansicht. Die Wirkung ähnelte den älteren Trefferflächen-Fehlern (F.18),
hatte jedoch eine völlig eigene Ursache — „gleiches Symptom“ heißt bei
Klickpfaden nicht „gleiche Wurzel“.

**Workaround (Patch 4t in `build.sh`):** `hitTest` beginnt mit
`guard !isHiddenOrHasHiddenAncestor else { return nil }`.

**Regression:** `./selftest.sh rightedge` stellt die gemeldete Geometrie
(1100×800, Seitenleiste, integrierte Vorschau, Markdown mit bis zu
646-Zeichen-Zeilen) wieder her und prüft ein ganzes Raster von Punkten bis
einen Punkt vor dem vertikalen Scrollbalken: Fenster-Hit-Test muss den
Editor treffen und `textOffsetAtPoint` eine Position liefern.

### F.20 Caret-Rundung ist die falsche Basis für Doppelklick-Wörter (2026-07-24)

`textOffsetAtPoint` rundet wie eine Einfüge-Position: Ein Klick auf die
rechte Hälfte eines Zeichens liefert den Offset DANACH. Für den einfachen
Klick ist das korrekt. Der Doppelklick-Pfad übernahm dieselbe Position und
markierte deshalb beim Klick auf die rechte Hälfte des letzten Wortzeichens
den Leerraum hinter dem Wort. NSTextView und BBEdit wählen das Wort über die
tatsächlich getroffene Zeichenzelle.

**Workaround (Patch 4u in `build.sh`):** Liegt der Klickpunkt in der Zelle
des Vorgängerzeichens, rückt `handleDoubleClick` die Auswahlbasis vor
`selectWord` dorthin.

**Regression:** Der zweite Teil von `./selftest.sh rightedge` doppelklickt
mit echten Fensterereignissen auf das letzte Zeichen eines Wortes an einer
Umbruchkante und verlangt exakt dieses Wort als Auswahl.

### F.21 Der Drag-Anker gehört an den Maus-Down, nicht an das erste Drag-Event (2026-07-24)

CodeEditTextView verankerte eine Maus-Selektion erst im ERSTEN
`mouseDragged`. Schnelle Mausbewegungen liefern grob gerasterte Events: Das
erste Drag-Ereignis kann weit vom Klickpunkt entfernt liegen, unterhalb des
Fensters wird es durch das Clamping sogar auf das Dokumentende gezogen. Die
Auswahl begann dann nicht am angeklickten Zeichen (Befund: Klick bei
Offset 10, Auswahl begann bei 2040) — sichtbar als „Auswahl springt weg /
läuft unten davon“.

**Workaround (Patch 4v in `build.sh`):** `mouseDown` setzt den Anker sofort
auf die geklemmte Klickposition; das erste Drag-Ereignis erweitert nur noch.

**Regression:** `./selftest.sh dragscroll` beginnt den Drag bei Offset 10,
zieht mit echten Events 40 Punkte unter das Fenster und verlangt beides:
Autoscroll folgt nach unten UND die Auswahl bleibt am Klickpunkt verankert.
`./selftest.sh selshort` sichert zusätzlich die Tastaturvariante in der
kleinen, stark umbrochenen Nutzerdatei (11 Zeilen, längste 646 Zeichen).

### F.22 Highlight-Provider müssen ihre Bereiche auf den Chunk zuschneiden (2026-07-24)

CESEs `StyledRangeContainer.applyHighlightResult` dokumentiert den Vertrag
nur im Kommentar: Gelieferte Highlight-Bereiche dürfen den angefragten
Bereich nicht überschreiten. Ein Bereich, der VOR dem Chunk beginnt, wird
komplett verworfen („Skip! Overlapping“) — ohne Assertion, ohne Log. Nach
einem Edit färbt CESE ab der Editposition neu; Fastras 4D-Provider lieferte
seine gecachten Token aber ungeclippt. Ein langer `/* … */`-Kommentarblock
begann vor dem neu einzufärbenden Abschnitt, wurde deshalb verworfen und
verlor hinter der Editposition sichtbar die Farbe (Befund im echten
4D-Projekt: Block gefärbt bis zur Editzeile, dahinter schwarz).

**Fix:** `FourDHighlightProvider.clippedRanges` schneidet jeden Cache-
Treffer auf `NSIntersectionRange` mit dem angefragten Bereich zu.

**Regression:** `./selftest.sh comment4d` editiert real in einem langen
Kommentarblock und verlangt anschließend Kommentarfarbe bis zum Blockende
(beobachtet an echten Vordergrundfarben, nicht an Provider-Ausgaben);
`FourDHighlightClippingTests` prüft die reine Zuschneide-Logik.

### F.23 CESEs State-Reconcile darf die Scroll-Position nicht besitzen (2026-07-24)

`SourceEditor.updateControllerWithState` scrollt bei jedem SwiftUI-Update auf
`state.scrollPosition`, sobald sie von der echten ClipView-Position abweicht.
Der Rückschreiber (`Coordinator.textControllerScrollDidChange`) läuft aber
via `receive(on: RunLoop.main)` erst im NÄCHSTEN Runloop. Löst ein
Tastendruck neben dem Tipp-Scroll noch ein weiteres SwiftUI-Update aus
(bei Fastra: Fußzeile mit Zeile/Spalte), gewinnt der Reconcile mit der
veralteten Position: Der frische Scroll wird zurückgedreht, der Cursor
verschwindet unter dem Fensterrand, Tippen bleibt unsichtbar. Das Race ist
timing-abhängig — auf demselben Mac im Selbsttest grün, in der echten
Nutzersitzung zu 100 % rot (Beleg: Call-Stack via Bounds-Change-Spion).

**Fix (Patch 4x in `build.sh`):** Der Scroll-Reconcile-Zweig in
`SourceEditor.updateControllerWithState` ist deaktiviert — Fastra steuert
Scrollen ausschließlich selbst (`convergeScroll`), ein externes Scroll-Soll
über den State existiert nicht. Cursor-Reconcile (externe Sprünge) bleibt
erhalten.

**Sackgasse (v1.50.1, sofort wieder entfernt):** Ein Fastra-seitiges
Filter-Binding mit eigenen get/set-Closures (`state.scrollPosition = nil`
beim Lesen) behob das Race zwar, stürzte aber in SwiftUIs
Zugriffsverfolgung ab (SIGSEGV in `swift_beginAccess` beim
Runloop-Observer-Flush): CESEs Coordinator hält das Binding dauerhaft und
schreibt während View-Updates hinein — das verträgt nur das echte
`@State`-Binding, keine handgebauten Closures.

**Regression:** `./selftest.sh typescroll` (inkl. erzwungenem Zusatz-Update
nach jedem Tastendruck und Zweitfenster-Stufe); das Race selbst feuert unter
Testtiming nicht deterministisch — verlässlicher Beleg war Daniels
100-%-Repro vor/nach dem Fix.

### F.24 rectForOffset crasht im Undo-Fenster mit veraltetem Zeilen-Storage (2026-07-24)

Während Undo/Redo schrumpft der Text; der Zeilen-Storage des
`TextLayoutManager` hinkt einen Moment hinterher. Fällt in dieses Fenster
ein Scroll (macOS-„Concurrent Scrolling“-Synchronizer → `updatedViewport`
→ `repositionCursorSelection`), fragt CETV `rectForOffset` mit der noch
nicht geclampten alten Cursorposition. Der Bounds-Check gegen
`lineStorage.length` greift dann nicht, und
`rangeOfComposedCharacterSequence(at:)` wirft eine NSRangeException →
SIGABRT (Befund: Crash nach ⌘V + ⌘Z am Dateiende).

**Workaround (Patch 4w in `build.sh`):** Offsets außerhalb des ECHTEN
Storage liefern ein 0-breites Rechteck statt der Range-Abfrage.

**Regression:** `TextLayoutManagerStaleOffsetTests` stellt das Fenster nach
(Storage schrumpft ohne Delegate-Benachrichtigung) — ohne Patch stürzt der
Testprozess, mit Patch kommt ein ehrliches Rechteck zurück.

### F.25 Completion-Herkunft muss bis ins Theme erhalten bleiben (2026-07-25)

Eine korrekte Typeahead-Zeile beweist noch keine korrekte Darstellung nach
dem Einfügen. Fastra kannte geteilte 4D-Komponentenmethoden im
`FourDComponentIndex` und kennzeichnete sie im Popup mit Komponentenname und
Shippingbox. Der Highlight-Provider erhielt danach jedoch nur die
Projektmethodennamen; der eingefügte Name fiel auf `.methodCall` zurück und
erschien wie ein normaler Befehl. Die semantische Herkunft muss deshalb durch
die ganze Kette reisen: Workspace-Index → Provider-Cache-Schlüssel →
Tokenizer-Kategorie → Capture → Theme-Slot. Bei einer Namenskollision prüft
der Tokenizer weiterhin zuerst die Projektmethode.

**Rückwärtskompatibler Patch 4m2:** `EditorTheme.componentMethods` ist
optional und verwendet ohne Angabe `commands`. Damit behalten alle
vorhandenen Themes und Sprachen exakt ihre Darstellung. Der neue
`CaptureName.componentMethod`-Case steht am Enum-Ende; ein Einfügen in der
Mitte würde die automatisch vergebenen Raw Values vorhandener Cases ändern.
`build.sh` prüft jede Patchstelle hart und verwirft anschließend die
CodeEditSourceEditor-Buildprodukte.

**Regressionen:** Tokenizer-/Provider-Tests prüfen Kategorie, Kollision,
Refresh und Theme-Mapping. `./selftest.sh highlight4d` beobachtet
Komponentenmethode, Projektmethode und Befehl im echten TextStorage in Hell
und Dunkel. `./selftest.sh completion4d` übernimmt eine Shared-Component per
echtem Typeahead-Doppelklick und prüft Farbe sowie Font erst am eingefügten
Text.

### F.26 Aktuelle Zeile und Textauswahl sind zwei getrennte Ebenen (2026-08-05)

`TextSelectionManager.drawSelections` zeichnete upstream entweder den
Hintergrund einer leeren Cursorzeile **oder** die Rechtecke einer nichtleeren
Auswahl. Sobald Fastra einen Suchtreffer selektierte, verschwand dadurch die
aktuelle Zeile. Der Gutter wiederholte dieselbe Einschränkung. Ein schlichtes
Entfernen der `isEmpty`-Prüfung ist falsch: Eine Rechteckauswahl besteht aus
mehreren Ranges und würde dann jede ihrer Zeilen als „aktuell“ einfärben;
mehrzeilige Auswahlen könnten ebenfalls uneindeutig werden.

**Fix (Patch 4y in `build.sh`):** `fastraHighlightedLineOffsets` trennt die
Zeilenebene von den Auswahlrechtecken. Mehrere leere Cursor markieren weiter
ihre jeweiligen Zeilen. Existiert mindestens eine echte Auswahl, liefert nur
die primäre (letzte) Range eine aktuelle Zeile; bei Tastaturauswahl bestimmt
der Gegenpol des `pivot` die bewegte Kante. Textfläche und Gutter verwenden
dieselbe Liste. Die Auswahlrechtecke werden danach weiterhin vollständig
gezeichnet.

**Regression:** `SoftWrapLayoutTests.selectedRangesKeepOneCurrentLine` prüft
eine rechteckartige Mehrfachauswahl, mehrere leere Cursor und eine rückwärts
aufgezogene Auswahl direkt am gepatchten `TextSelectionManager`.

### F.27 Fließtext darf nicht die Einrückungsregeln von Quellcode erben (2026-08-11)

CodeEditSourceEditor verwendete `TextualIndenter.basicPatterns` für jede
Sprache außer Python und Ruby. Damit galt eine `.txt`-Zeile wie `(1,5) …` als
geöffneter Klammerblock und Return fügte vier Leerzeichen ein. Entfernte man
diese von Hand und drückte erneut Return, übersprang der voreingestellte
Referenzzeilen-Filter die leere Zeile, fand wieder den Klammertext und stellte
die Einrückung erneut her.

**Fix (Patch 4z2 in `build.sh`):** Reiner Text und Markdown bekommen keine
Code-Klammermuster. Der Referenzfilter akzeptiert auch die unmittelbare leere
Vorzeile, damit sie die Einrückung bewusst auf null zurücksetzt. Echte
Code-Sprachen behalten ihre bisherigen Regeln.

**Regression:** `./selftest.sh mdindent` lädt eine `.txt`-Fixture mit dem
entscheidenden `(1,5)`-Präfix in den gepackten Editor und prüft Return sowohl
direkt als auch nach dem manuellen Entfernen einer etwaigen Einrückung.

### F.28 Ein externer Drop braucht die TextView als Drag-Ziel (2026-08-11)

SwiftUIs `onDrop` liefert `NSItemProvider`, aber weder die laufende
Textposition noch kontinuierliche Randbewegungen. Ein Bild konnte daher nur an
der schon vorher vorhandenen Einfügemarke landen; eine sichtbare Drop-Marke und
stationärer Autoscroll waren auf dieser Ebene nicht implementierbar.

**Fix (Patch 4z3 in `build.sh`):** Die echte CodeEditTextView routet von Fastra
akzeptierte externe Pasteboards vor ihrem normalen Text-Drag. Sie berechnet den
Offset aus jeder `NSDraggingInfo`-Position, zeichnet dort den vorhandenen
CodeEdit-Cursor und scrollt mit einem kurzen Timer weiter, solange die Maus am
oberen oder unteren Viewportrand steht. Beim Loslassen setzt sie erst die
Textauswahl auf diesen Offset und ruft dann den Markdown-Assistenten. Für andere
Pasteboards bleibt der Upstream-Pfad unverändert.

**Regression:** `./selftest.sh mddropcursor` treibt die echte
Drag-Destination mit einer Bilddatei, hält die Maus am unteren Rand und verlangt
sichtbaren Cursor, messbaren Autoscroll sowie den Link exakt am Drop-Offset.

### F.29 Eine Megazeile darf weder CoreText noch den Highlighter besitzen (2026-08-12)

Eine 4,36-MB-Textdatei mit nur einer logischen Zeile blockierte den Editor an
mehreren voneinander unabhängigen Stellen. Soft Wrap erzeugte tausende
Umbruchfragmente. Ohne Soft Wrap baute CoreText die gesamte Zeile als ein
einziges `CTLine` auf. CodeEditSourceEditor wiederholte das Layout beim
erstmaligen Anwenden bereits gesetzter Insets und Attribute. Schließlich
meldete `visibleTextRange` horizontal die ganze logische Zeile, sodass der
Highlighter auch unsichtbare Millionen Zeichen einplante; ein Sprachwechsel
entfernte alte Attribute synchron im ganzen Dokument.

**Fix (Patch 4z4 in `build.sh`):** Fastra setzt Soft Wrap für das einzelne
betroffene Dokument aus. CodeEditTextView hält ungebrochene Megazeilen als eine
visuelle Zeile, portioniert sie intern aber an sicheren Unicode-Grenzen in
16-KiB-`CTLine`s und zeichnet nur Portionen im Grafik-Ausschnitt. Die
Anfangskonfiguration wird vor dem Einhängen der TextView angewandt und
identische Startattribute werden nicht erneut geschrieben. Sichtbare Bereiche
bleiben horizontal und zwischen logischen Zeilen getrennt; der Sprachwechsel
setzt nur dort Attribute zurück.

**Regression:** `DifficultDocumentCorpusTests` erzeugt TXT, JSON, XML, CSV und
Markdown mit jeweils exakt 4.357.697 Byte aus einem ungültigen synthetischen
Base64-artigen Muster. Die Tests begrenzen Laden, vollständigen Editoraufbau,
Layout, JSON-Sprachwechsel, echte tree-sitter-Abfrage sowie JSON-/XML-
Formatierung. `LongLineEditorPerformanceTests` prüft zusätzlich View-Anzahl,
horizontal sichtbaren Bereich, Zeichendauer und Unicode-Grenzen der internen
Portionen. Die Fixture-Dateien entstehen nur im Test und liegen nicht im Repo.
