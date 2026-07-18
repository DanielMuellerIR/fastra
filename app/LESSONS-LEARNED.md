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

`EditorTheme` hat 16 obligatorische Felder (text, insertionPoint, invisibles,
background, lineHighlight, selection, plus 10 Token-Attribute) und nimmt jeweils
`EditorTheme.Attribute(color:bold:italic:)`-Werte mit `NSColor`, nicht `Color`.
Fastra definiert sein Theme in `EditorView.swift`.

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

`build.sh` kapselt F.2 – F.4 + F.9 + F.10 vollständig. Aufruf:

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
