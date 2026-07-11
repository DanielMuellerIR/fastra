# Fastra · Prototypen — Lessons Learned aus Phase 1

Stand nach dem Bau der drei One-Shot-Prototypen am 17. Mai 2026. Diese Notiz soll der Phase-2-Session den Start sparen.

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

---

## B · SwiftUI/macOS-Patterns die in den Prototypen sauber funktionieren

| Pattern | Wo verwendet | Funktioniert |
|---|---|---|
| `@NSApplicationDelegateAdaptor` | alle drei Varianten | ✅ |
| `WindowGroup` mit `.windowStyle(.hiddenTitleBar)` | V1, V2 | ✅ (Traffic Lights bleiben sichtbar) |
| `WindowGroup` mit default Titlebar | V3 | ✅ |
| `NavigationSplitView` mit `List(children:)` | V3 | ✅ — funktioniert für Tree-Sidebars |
| `.searchable(text:)` | V3 | ✅ — landet automatisch in Toolbar |
| `.toolbar { … }` mit `.principal`-Placement | V3 | ✅ — Segmented Picker passt rein |
| `HSplitView` / `VSplitView` | V3 | ✅ — natives Trennen mit Drag-Handle |
| `.sheet(isPresented:)` als Floating Dialog | V3 | ✅ — `.regularMaterial`-Background sauber |
| ZStack-Overlay als "Floating Dialog" | V1, V2 | ✅ — flexibler, aber weniger nativ |
| `AttributedString` mit `backgroundColor` für Token-Highlighting | alle | ✅ — Pre-Tokenizer-Lösung |
| `@StateObject` vs `@EnvironmentObject` für Workspace | gemischt | ⚠️ V3 nutzt `@StateObject` in `ContentView`, V1/V2 in App. V3-Ansatz spielt schlechter mit NSWindow-Tabbing (jeder Tab eigenes Workspace) |

---

## C · Variante-spezifische Erkenntnisse im Code-Stand

### V1 — Vorschau-Maximalismus
- Die `layoutPriority(1)` auf dem Diff-Panel bewirkt das gewollte "Vorschau dominiert" — Editor stuft sich automatisch zurück, wenn Fenster zu klein wird. **Behalten für Phase 2.**
- Der Floating Search Dialog ist als ZStack-Overlay umgesetzt — das ist visuell kompromisslos, aber bricht macOS-Konventionen leicht (kein NSPanel-Floating-Verhalten beim Fenster-Wechsel). Vor Phase 2 entscheiden: Custom-Overlay halten oder zu NSPanel migrieren?

### V2 — Keyboard-First / Terminal
- Die Command Palette ist als statischer `[PaletteCommand]`-Array implementiert. Für Phase 2 muss das **dynamisch** werden — z.B. alle Commands aus `CommandMenu`-Definitionen automatisch ableiten, sonst dupliziert man die Liste.
- ⌘K kollidiert mit nichts in macOS-Konventionen → safe.
- Die Vim-Status-Bar fühlt sich ungewohnt an in einer Mac-App. Test: kommt das bei Tobias-artigen Usern an oder wirkt es manieriert?

### V3 — Mac-Native-Maximalismus
- `NavigationSplitView` braucht den Trick mit `List(children:)` + `selection:`-Binding über eine **UUID**, nicht über das `FileItem` selbst (sonst stürzt der Selection-Cycle). Der `findFile(id:in:)`-Helper im `SidebarView.swift` ist Pflicht.
- `.searchable` aus dem Detail-Pane raus zu nehmen geht nicht — es muss am NavigationSplitView selbst hängen.
- Native NSWindow-Tabs zeigen sich **erst**, wenn der Nutzer im macOS-System "Prefer Tabs: Always" stellt. Für Demo-Screenshots vorher manuell setzen.

---

## D · Vorbereitung für Phase 2 (Editor + Sprach-Highlighting)

Die nächste Session soll laut Blueprint Phase 2 umsetzen: **CodeEditSourceEditor + CodeEditLanguages** integrieren, damit jede Variante einen echten Editor mit Mehrsprach-Highlighting bekommt.

### Empfohlene Reihenfolge in einer neuen Session

1. **Eine** Variante als Hauptlinie wählen (Empfehlung: V1, weil Vorschau-Risiko die wichtigste validierte Annahme ist und V1 die meisten Phase-1-Bauteile ohne Maus-Pflicht-Designentscheidungen mitbringt).
2. **Package.swift** um Dependencies erweitern:
   ```swift
   dependencies: [
       .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor", from: "0.15.0"),
       .package(url: "https://github.com/CodeEditApp/CodeEditLanguages",   from: "0.1.20"),
   ],
   ```
   Plus `.product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor")` und `.product(name: "CodeEditLanguages", package: "CodeEditLanguages")` als Target-Dependencies.
3. **EditorPlaceholderView.swift** ersetzen durch einen `CodeEditSourceEditor`-Wrapper. API-Skizze:
   ```swift
   import CodeEditSourceEditor
   import CodeEditLanguages

   struct EditorView: View {
       @Binding var text: String
       @State private var cursorPositions: [CursorPosition] = []
       let language: CodeLanguage
       var body: some View {
           CodeEditSourceEditor(
               $text,
               language: language,
               theme: .default,
               font: .monospacedSystemFont(ofSize: 13, weight: .regular),
               tabWidth: 4,
               indentOption: .spaces(count: 4),
               lineHeight: 1.2,
               wrapLines: false,
               cursorPositions: $cursorPositions
           )
       }
   }
   ```
4. **Sprach-Erkennung** über `CodeLanguage.detectLanguageFrom(url:)` oder `CodeLanguage.detectLanguageFrom(extension:)`. Für Phase 2 reicht ein Switch auf die `.title`-Dateiendung des `EditorTab`.
5. **Encoding & Line-Endings**: in `Workspace.swift` Felder ergänzen (`@Published var encoding: String.Encoding`, `@Published var lineEnding: LineEnding`). Beim Datei-Öffnen über `NSString.stringEncoding(for:)` ermitteln. Footer reagiert dann live.

### Wahrscheinliche Stolpersteine in Phase 2

- **CodeEditLanguages-Version-Drift:** Letzter Release laut OSS-Recherche war 0.1.20 (Nov 2024). Falls inzwischen API-Änderungen — SwiftTreeSitter als Fallback einsetzen (siehe Blueprint Sektion 3).
- **Tree-sitter-Grammatik für RegEx-Token-Highlighting im Find-Feld:** CodeEditLanguages liefert das **nicht** mit. Eigene Integration von `tree-sitter-regex` via `SwiftTreeSitter` nötig — separater Schritt, vermutlich nach Editor-Integration.
- **CodeEditSourceEditor-Theme:** muss an die Moodboard-Tokens angepasst werden. Die Library hat ein `EditorTheme`-Konstrukt, das pro Token-Typ Color/Font erlaubt. Aus den `Theme.swift`-Werten ableitbar.
- **Datei-IO**: bisher nicht implementiert. Vor Phase-2-Editor mindestens `Open Recent`, `Open Folder…`, `Save` basics ergänzen — sonst hat der Editor keine echten Dateien zum Anzeigen.

### Was Phase 2 **nicht** sein sollte

- **Nicht** Drag & Drop von Capture Groups einbauen — das ist Phase 3.
- **Nicht** ripgrep integrieren — laut v1.0-Scope NSRegularExpression bleibt.
- **Nicht** HexFiend einbauen — das ist Phase 5.
- **Nicht** alle drei Varianten gleichzeitig zu Phase 2 ziehen — eine Hauptlinie wählen, die anderen archivieren.

---

## E · Kleine Hygiene-Punkte für die nächste Session

- **`.build/`-Ordner** liegen jetzt in jedem Variante-Ordner (durch das Test-Build). Sie sind groß (~150 MB). Vor Commit / Archivierung mit `rm -rf .build` aufräumen, oder `.gitignore` setzen.
- **Die drei Varianten teilen ~70% Code.** Eine spätere Refactoring-Runde könnte das in einen gemeinsamen `FastraKit`-Library-Target ziehen. Aber: für die Risiko-Validierung lohnt sich diese Investition erst, wenn eine Variante als Hauptlinie feststeht.
- **AppIcon ist in V1+V3 als Light-Variante, in V2 als Dark-Variante eingebunden.** Im Finder/Dock sieht das Light-Icon auf hellem Hintergrund unauffällig, das Dark-Icon "pop" stärker. Bei der gewinnenden Variante eine Adaptive-Icon-Strategie (Light/Dark-Asset) erwägen.

---

## TL;DR für die Phase-2-Session

1. **Eine** Variante wählen (vermutlich V1).
2. `Package.swift` um `CodeEditSourceEditor` + `CodeEditLanguages` erweitern.
3. `EditorPlaceholderView` → `EditorView` mit `CodeEditSourceEditor`.
4. Datei-Open/Save-Basics ergänzen (FileManager, NSOpenPanel).
5. Encoding + Line-Endings aus NSString-Detection im Footer ankoppeln.
6. **Nicht** versuchen, alles in einer Session zu schaffen — Phase 3 (Drag&Drop) braucht eigenes Konzept.

---

## F · Phase-2-Build-Realität — was tatsächlich gebrochen ist und wie wir es umgangen haben

**Stand:** Phase 2 ist auf V1 gebaut und läuft. Der Weg dorthin war länger als erwartet — drei voneinander unabhängige Probleme an den OSS-Dependencies treffen aufeinander, sobald man `swift build` aus reiner CommandLineTools-Umgebung versucht. Damit zukünftige Sessions nicht jedes Mal von vorne raten:

### F.1 API-Drift in CodeEditSourceEditor 0.15.0 → 0.15.2

Der API-Vorschlag aus Sektion D oben (`CodeEditSourceEditor($text, language:, theme:, font:, …)`) **stimmt nicht mehr**. In 0.15.2 (Stand Mai 2026, gepinnt in `Package.resolved`) heißt der Typ jetzt `SourceEditor` und nimmt:

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

`EditorTheme` hat 16 obligatorische Felder (text, insertionPoint, invisibles, background, lineHighlight, selection, plus 10 Token-Attribute) und nimmt jeweils `EditorTheme.Attribute(color:bold:italic:)`-Werte mit `NSColor`, nicht `Color`. Die V1-Implementierung definiert ein statisches `fastraTheme` in `EditorView.swift` — als Vorlage für Dark-Mode-Variante.

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

### F.5 Konsequenz: build.sh in V1

`build.sh` kapselt F.2 – F.4 + F.9 + F.10 vollständig. Aufruf:

```bash
./build.sh           # debug
./build.sh release   # release
```

Die Patches sind idempotent und ändern den `.build/checkouts/`-Inhalt — nicht den V1-Source. Beim `swift package update` muss das Skript wieder einmal laufen.

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

### F.7 Was Phase 2 jetzt tatsächlich kann

- Editor mit Sprach-Highlighting für alle ~30 von CodeEditLanguages mitgelieferten Sprachen.
- ⌘O öffnet beliebige Datei, Encoding wird via `String(contentsOf:usedEncoding:)` detektiert.
- ⌘S / ⌘⇧S speichern (Encoding bleibt erhalten).
- Footer-Stats (Chars/Words/Lines), Encoding, Line-Ending, File-Type — reaktiv aus dem aktiven Tab.
- Sidebar listet geöffnete Tabs mit Dirty-Marker.

### F.8 Was Phase 2 absichtlich nicht macht

- Find-Field-RegEx-Tokenisierung (Phase 3 oder 4).
- Echte Diff-Berechnung im Hero-Panel (Phase 4).
- Drag & Drop von Capture Groups (Phase 3).
- Dark-Mode-Editor-Theme (Phase 2.1, kleinere Folge-Session).
- Cursor-Position-Anzeige im Footer (kleinere Folge-Session — `SourceEditorState.cursorPositions` ist da, muss nur in den Status-View durchgereicht werden).

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

Verifikation: `--selftest-findbar` (pollt auf transientes Aufblitzen). Volle Begründung + verbotene Irrwege in `CLAUDE.md` → QA-Strategie (Zombie-Find-Bar).

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

Aufgedeckt + verifiziert durch den neuen Selbsttest `--selftest-jump`: lädt Text mit unterschiedlich langen Vorzeilen (inkl. Emoji-Surrogatpaar), postet einen Sprung exakt wie die GUI und liest `TextView.selectedRange()` zurück — der selektierte Text muss exakt der Treffer sein. Belegt zugleich den Offset-Fix (Zeile/Spalte statt absoluter Range) End-to-End.
