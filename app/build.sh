#!/usr/bin/env bash
# Fastra V1 — Phase-2-Build-Workflow
#
# Wrappt `swift build` so, dass:
#   1. Die Xcode-Toolchain (statt CommandLineTools) genutzt wird — sonst scheitert der
#      Build an den `#Preview`-Macros in CodeEditSourceEditor (Macro-Plugin nur in Xcode).
#   2. Die SwiftLint-Build-Plugins in CodeEditSourceEditor und CodeEditTextView lokal
#      auskommentiert werden — das prebuilt SwiftLint-Binary findet
#      `sourcekitdInProc.framework` nicht und kippt den Build.
#   3. Die fehlende `resources:`-Deklaration in CodeEditSymbols/Package.swift ergänzt wird —
#      sonst gibt es `type 'Bundle' has no member 'module'`.
#
# Die Patches sind nicht-invasiv (kommentieren statt löschen) und werden bei jedem
# `swift package update` zurückgesetzt — dann muss dieses Skript erneut laufen.
#
# Voraussetzung: Xcode unter /Applications/Xcode.app installiert. CommandLineTools allein
# reicht nicht.

set -e
cd "$(dirname "$0")"

# Sicherheitshalber alle laufenden Fastra-Instanzen beenden — sonst kann
# das spätere Bundle-Kopieren auf ein offenes Binary treffen und nur
# halb überschreiben. Das hatte uns einmal eine Stunde Debug gekostet.
if pgrep -x Fastra >/dev/null 2>&1; then
  echo "→ Vorhandene Fastra-Instanz beenden"
  pkill -x Fastra || true
  sleep 1
fi

CHECKOUTS=".build/checkouts"

# 1. Sources erst resolven, damit .build/checkouts/ existiert
if [ ! -d "$CHECKOUTS/CodeEditSourceEditor" ]; then
  echo "→ Dependencies werden gelöst…"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swift package resolve
fi

# 2. Patch CodeEditSourceEditor — SwiftLint-Plugin entfernen
CESE="$CHECKOUTS/CodeEditSourceEditor/Package.swift"
if grep -q 'plugin(name: "SwiftLint", package: "SwiftLintPlugin")' "$CESE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor/Package.swift (SwiftLint-Plugin aus)"
  # Plugin im Target rauspatchen (perl statt sed, weil sed-multiline auf macOS
  # brüchig ist — siehe LESSONS-LEARNED, Sektion F).
  /usr/bin/perl -i -0pe 's|plugins: \[\s*\.plugin\(name: "SwiftLint", package: "SwiftLintPlugin"\)\s*\]|plugins: []|g' "$CESE"
  # Dependency rauspatchen
  /usr/bin/perl -i -0pe 's|\.package\(\s*url: "https://github.com/lukepistrol/SwiftLintPlugin",\s*from: "0\.2\.2"\s*\),?||g' "$CESE"
fi

# 3. Patch CodeEditTextView — gleicher Plugin-Block
CETV="$CHECKOUTS/CodeEditTextView/Package.swift"
if grep -q 'plugin(name: "SwiftLint", package: "SwiftLintPlugin")' "$CETV" 2>/dev/null; then
  echo "→ Patche CodeEditTextView/Package.swift (SwiftLint-Plugin aus)"
  /usr/bin/perl -i -0pe 's|plugins: \[\s*\.plugin\(name: "SwiftLint", package: "SwiftLintPlugin"\)\s*\]|plugins: []|g' "$CETV"
  /usr/bin/perl -i -0pe 's|\.package\(\s*url: "https://github.com/lukepistrol/SwiftLintPlugin",\s*from: "0\.52\.2"\s*\),?||g' "$CETV"
fi

# 4. Patch CodeEditSymbols — `resources:` ergänzen, damit Bundle.module entsteht
CESYM="$CHECKOUTS/CodeEditSymbols/Package.swift"
if grep -q '"CodeEditSymbols",' "$CESYM" 2>/dev/null && ! grep -q 'Symbols.xcassets' "$CESYM" 2>/dev/null; then
  echo "→ Patche CodeEditSymbols/Package.swift (Symbols.xcassets-Resource ergänzen)"
  /usr/bin/perl -i -0pe 's|\.target\(\s*name: "CodeEditSymbols",\s*dependencies: \[\]\s*\)|.target(\n            name: "CodeEditSymbols",\n            dependencies: [],\n            resources: [.process("Symbols.xcassets")]\n        )|g' "$CESYM"
fi

# 4b. Patch CodeEditSourceEditor — Editor-eigenen CMD+F-Handler neutralisieren
#     (Zombie-Find-Bar deterministisch killen).
#
# Der Editor installiert beim Laden einen eigenen lokalen keyDown-Monitor, der
# bei CMD+F sein internes Find-Panel öffnet (TextViewController.handleCommand →
# showFindPanel). Das Rennen der konkurrierenden NSEvent-Monitore ist nicht
# zuverlässig gewinnbar — das Panel blitzt deshalb gelegentlich auf, bevor
# unsere Reconciliation in EditorView es wieder schließt ("Zombie"). Hier
# patchen wir den Handler so, dass CMD+F durchgereicht wird (return event)
# statt das Panel zu zeigen. Damit fängt CMD+F ausschließlich unser App-Monitor
# ab und öffnet unsere eigene Suchmaske — deterministisch, unabhängig von der
# Monitor-Reihenfolge. Siehe ../docs/BUILD-AND-TEST.md → QA-Strategie
# (Zombie-Find-Bar).
CESE_LC="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController+Lifecycle.swift"
if grep -q 'self.findViewController?.showFindPanel()' "$CESE_LC" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (CMD+F → eigene Suchmaske, Zombie-Kill)"
  /usr/bin/perl -i -0pe 's/case \(commandKey, "f"\):\s*\n\s*_ = self\.textView\.resignFirstResponder\(\)\s*\n\s*self\.findViewController\?\.showFindPanel\(\)\s*\n\s*return nil/case (commandKey, "f"):\n            return event  \/\/ Fastra-Patch: CMD+F oeffnet unsere Suchmaske statt des Editor-Find-Panels/' "$CESE_LC"
  # Verifizieren, dass der Patch wirklich gegriffen hat — sonst kehrt der
  # Zombie lautlos zurück (z.B. nach Versions-Bump mit geänderter Quelle).
  if grep -q 'self.findViewController?.showFindPanel()' "$CESE_LC" 2>/dev/null; then
    echo "✗ FEHLER: CMD+F-Zombie-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  # WICHTIG: SPM trackt Quell-Änderungen INNERHALB von .build/checkouts NICHT
  # (Dependencies gelten als immutable — nur ein `swift build` ohne Recompile).
  # Damit der Patch in die Binärdatei gelangt, die CESE-Build-Produkte
  # verwerfen → SPM muss das Modul neu übersetzen. Greift nur in diesem
  # Zweig, also nur direkt nach dem (Neu-)Patchen.
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4c. Patch CodeEditSourceEditor — toten cursorPositions-Reconcile reparieren.
#
# In SourceEditor.updateControllerWithState steht upstream:
#     if let cursorPositions = state.cursorPositions,
#        cursorPositions != state.cursorPositions { … }
# Die Bedingung vergleicht die lokale Kopie mit SICH SELBST → IMMER false.
# Folge: setCursorPositions() läuft nur einmal in makeNSViewController (bei
# Editor-Erzeugung); ein späteres Setzen von state.cursorPositions von außen
# (genau unser Treffer-Sprung CMD+G / Listen-Klick / „Voriger/Nächster")
# bewegt die Editor-Selektion NIE. Reine Unit-Tests sahen das nicht — der
# Selbsttest `-selftest jump` deckte es auf. Fix: gegen den IST-Stand des
# Controllers vergleichen (controller.cursorPositions) und beim Anwenden in
# Sicht scrollen (scrollToVisible), damit der Sprung auch sichtbar wird.
CESE_SE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditor/SourceEditor.swift"
if grep -q 'cursorPositions != state.cursorPositions' "$CESE_SE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (toten cursorPositions-Reconcile reparieren)"
  /usr/bin/perl -i -0pe 's/cursorPositions != state\.cursorPositions \{\s*\n\s*controller\.setCursorPositions\(cursorPositions\)/cursorPositions != controller.cursorPositions {  \/\/ Fastra-Patch: upstream verglich state.cursorPositions mit sich selbst (immer false) -> externer Sprung wirkte nie\n            controller.setCursorPositions(cursorPositions, scrollToVisible: true)/' "$CESE_SE"
  # Verifizieren, dass der Patch gegriffen hat — sonst bleibt der Sprung tot.
  if grep -q 'cursorPositions != state.cursorPositions' "$CESE_SE" 2>/dev/null; then
    echo "✗ FEHLER: cursorPositions-Reconcile-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
# Wie bei 4b: SPM trackt Quell-Änderungen in .build/checkouts NICHT →
# CESE-Build-Produkte verwerfen, damit der Patch neu übersetzt wird.
rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
      .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4c1. Patch CodeEditSourceEditor — verworfene Auto-Vervollständigung sauber
#       zurücksetzen.
#
# CESE fragt nach JEDEM Buchstaben an. Fastra zeigt 4D-Vorschläge beim Tippen
# aber bewusst erst ab zwei Zeichen. Beim ersten Zeichen liefert der Delegate
# daher `nil`. Upstream lässt in diesem Fall `activeTextView` dennoch gesetzt;
# der zweite Buchstabe aktualisiert dann nur eine unsichtbare Liste, statt sie
# über `presentIfNot` zu öffnen. `willClose()` räumt den abgebrochenen Versuch
# auf, damit das zweite Zeichen einen neuen, sichtbaren Vorschlagsversuch
# startet. Der In-App-Test `completion4d` reproduziert genau diese Reihenfolge.
CESE_SUGGESTIONS="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/CodeSuggestion/Model/SuggestionViewModel.swift"
if grep -q 'guard let completionItems = await delegate.completionSuggestionsRequested' "$CESE_SUGGESTIONS" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (verworfenes Auto-Completion zurücksetzen)"
  /usr/bin/perl -i -0pe 's|guard let completionItems = await delegate\.completionSuggestionsRequested\(\s*textView: textView,\s*cursorPosition: cursorPosition\s*\) else \{\s*return\s*\}|guard let completionItems = await delegate.completionSuggestionsRequested(\n                    textView: textView,\n                    cursorPosition: cursorPosition\n                ) else {\n                    self.willClose()  // Fastra-Patch: abgebrochene Ein-Zeichen-Anfrage darf den zweiten Buchstaben nicht unsichtbar aktualisieren\n                    return\n                }|g' "$CESE_SUGGESTIONS"
  # Der Kommentar ist zugleich der stabile Anker: Ändert Upstream den
  # Anfragepfad, darf der Build nicht still mit einem verlorenen Fix weiterlaufen.
  if ! grep -q 'Fastra-Patch: abgebrochene Ein-Zeichen-Anfrage' "$CESE_SUGGESTIONS" 2>/dev/null; then
    echo "✗ FEHLER: Auto-Completion-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  # SPM behandelt Checkout-Sources als unveränderlich. Deshalb wie bei den
  # anderen CESE-Patches das Modul löschen, damit der Produktbuild den Fix
  # wirklich enthält statt eine alte Binärdatei zu verwenden.
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4d. Patch CodeEditTextView — Drag-Selektion über die Gutter-Spalte reparieren.
#
# In TextView+Mouse.swift (mouseDragged) wird die Mausposition auf den TextView-
# Frame geclampt: `x: max(0.0, min(locationInWindow.x, frame.width))`. Der Gutter
# (Zeilennummern) ist ein FLOATING-Subview über der linken TextView-Kante; der Text
# beginnt erst rechts davon (Container-Inset = layoutManager.edgeInsets.left). Zieht
# man die Selektion schnell nach links in die Gutter-Spalte, landet x zwischen 0 und
# dem Inset — dort liefert `layoutManager.textOffsetAtPoint(...)` nil (kein Glyph),
# und das `guard let endPosition = … else { return }` in mouseDragged bricht ab: die
# Selektion „wächst nicht mehr" und stoppt vor der ersten Spalte (Daniel-Befund
# 2026-06-22). Fix: x mindestens auf den linken Text-Inset clampen, dann mappt der
# Punkt auf den Zeilenanfang statt auf nil — die Selektion reicht sauber bis Spalte 1.
CETV_MOUSE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Mouse.swift"
if grep -q 'x: max(0.0, min(locationInWindow.x, frame.width))' "$CETV_MOUSE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Drag-Selektion über Gutter clampen)"
  /usr/bin/perl -i -pe 's/x: max\(0\.0, min\(locationInWindow\.x, frame\.width\)\),/x: max(layoutManager.edgeInsets.left, min(locationInWindow.x, frame.width)),  \/\/ Fastra-Patch: im Gutter-Bereich auf Zeilenanfang clampen statt nil (Drag friert sonst ein)/' "$CETV_MOUSE"
  # Verifizieren, dass der Patch gegriffen hat — sonst kehrt der Bug lautlos zurück.
  if grep -q 'x: max(0.0, min(locationInWindow.x, frame.width))' "$CETV_MOUSE" 2>/dev/null; then
    echo "✗ FEHLER: Gutter-Drag-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  # Wie bei 4b/4c: SPM trackt Quell-Änderungen in .build/checkouts NICHT →
  # CETV-Build-Produkte verwerfen, damit der Patch neu übersetzt wird.
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
fi

# 4e. Patch CodeEditSourceEditor — horizontalen Scrollbalken + System-Scrollstil.
#
# `styleScrollView()` (TextViewController+StyleViews.swift) setzt nur
# `hasVerticalScroller = true` und erzwingt `scrollerStyle = .overlay`. Zwei
# Folgen (Daniel-Befund 2026-06-23):
#   1. `hasHorizontalScroller` wird bei der Erst-Erzeugung NIE gesetzt (nur im
#      Appearance-Config-Reconcile, der initial nicht greift). Ohne Umbruch ist
#      langer Text dann gar nicht erreichbar — kein Scrollbalken (Showstopper).
#   2. Das erzwungene `.overlay` überschreibt die System-Einstellung
#      „Rollbalken: immer einblenden" → Balken bleiben unsichtbar, obwohl der
#      Nutzer dauerhaft sichtbare will.
# Fix: H-Scroller passend zum Umbruch initial setzen und `.overlay` NICHT
# erzwingen (NSScrollView nutzt dann `NSScroller.preferredScrollerStyle`,
# respektiert also die System-Präferenz).
CESE_STYLE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController+StyleViews.swift"
if grep -q 'scrollView.scrollerStyle = .overlay' "$CESE_STYLE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (H-Scroller initial + System-Scrollstil)"
  /usr/bin/perl -i -0pe 's/scrollView\.hasVerticalScroller = true\s*\n\s*scrollView\.scrollerStyle = \.overlay/scrollView.hasVerticalScroller = true\n        scrollView.hasHorizontalScroller = !configuration.appearance.wrapLines  \/\/ Fastra-Patch: H-Scroller initial setzen (CESE tat das nur im Config-Reconcile)\n        \/\/ Fastra-Patch: kein erzwungenes .overlay -> System-Scrollbalken-Einstellung respektieren ("immer einblenden")/' "$CESE_STYLE"
  if grep -q 'scrollView.scrollerStyle = .overlay' "$CESE_STYLE" 2>/dev/null; then
    echo "✗ FEHLER: Scrollbalken-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4f. Patch CodeEditTextView — gemessene Zeilenbreite ging verloren (kein H-Scroll
# bei „Umbruch aus").
#
# In TextLayoutManager+Layout.swift bekommt `layoutLine(...)` die maximale gefundene
# Zeilenbreite als `inout maxFoundLineWidth` herein. Direkt nach dem Vermessen der
# Zeile deklariert der Code aber `var maxFoundLineWidth = maxFoundLineWidth` — eine
# LOKALE Kopie, die den inout-Parameter überschattet. Die Messung
# `if maxFoundLineWidth < lineSize.width { maxFoundLineWidth = lineSize.width }`
# schreibt damit nur in die Kopie; sie wird beim Return verworfen und nie in den
# inout zurückgeschrieben. Folge: `layoutLines` sieht die Zeilenbreite nie,
# `maxLineWidth` bleibt 0, `estimatedWidth()` liefert nur die EdgeInsets (~67 px) →
# die TextView wächst bei „Umbruch aus" nicht auf die Inhaltsbreite, es gibt keinen
# horizontalen Scrollbereich (Daniel-Befund 2026-06-23, per -selftest hscroll auf
# est=67->67 / docW=clipW eingegrenzt). Fix: die Shadow-Kopie entfernen, dann
# schreibt die Messung direkt in den inout-Parameter. Im Umbruch-AN-Fall unschädlich
# (Frame-Breite ist dort ohnehin die Clip-Breite).
CETV_LAYOUT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Layout.swift"
if grep -q 'var maxFoundLineWidth = maxFoundLineWidth' "$CETV_LAYOUT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Shadow-Kopie maxFoundLineWidth entfernen → H-Scroll)"
  /usr/bin/perl -i -pe 's|var maxFoundLineWidth = maxFoundLineWidth|// Fastra-Patch: Shadow-Kopie entfernt — sie verschluckte die gemessene Zeilenbreite (inout wurde nie zurückgeschrieben), maxLineWidth blieb 0 → kein H-Scroll bei „Umbruch aus".|' "$CETV_LAYOUT"
  if grep -q 'var maxFoundLineWidth = maxFoundLineWidth' "$CETV_LAYOUT" 2>/dev/null; then
    echo "✗ FEHLER: maxFoundLineWidth-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
fi

# 4g. Patch CodeEditLanguages — exotische Sprach-Grammatiken ausschneiden.
#
# CodeEditLanguages bindet ~40 Tree-sitter-Grammatiken über das prebuilt
# XCFramework CodeLanguagesContainer (binaryTarget, statisches ar-Archiv) ein.
# Jeder `case .X: return tree_sitter_X()` in CodeLanguage.swift referenziert
# die jeweilige C-Parser-Funktion — DAS zwingt den Linker, die zugehörige
# Grammatik-Objektdatei (TreeSitterX.o, einzelne teils zweistellige MB)
# statisch ins Fastra-Binary zu ziehen. Ersetzt man den Rückgabewert durch
# `return nil`, fällt die Referenz weg und der Linker lässt die .o draußen →
# das Binary schrumpft. Die Sprache verliert damit ihr Syntax-Highlighting
# (der Editor behandelt sie als Plaintext); alles andere bleibt unberührt
# (tsLanguage == nil wird in `.language` sauber abgefangen).
# Daniel-Entscheidung 2026-07-08: Bundle-Größe drücken, Apple-Silicon-only.
# Ausgeschnitten (moderate Liste, Dart bewusst BEHALTEN): Verilog, OCaml
# (+Interface), Julia, Haskell, Scala, Agda, Elixir, Zig — zusammen ~50 MB.
CEL_LANG="$CHECKOUTS/CodeEditLanguages/Sources/CodeEditLanguages/CodeLanguage.swift"
if grep -q 'return tree_sitter_verilog()' "$CEL_LANG" 2>/dev/null; then
  echo "→ Patche CodeEditLanguages (exotische Grammatiken ausschneiden)"
  # Nur den Rückgabe-Ausdruck ersetzen; die `case`-Labels + das Enum bleiben
  # unangetastet. Funktionsnamen sind eindeutig; `tree_sitter_ocaml()` matcht
  # dank der literalen `()` NICHT das längere `tree_sitter_ocaml_interface()`.
  for fn in agda elixir haskell julia ocaml ocaml_interface scala verilog zig; do
    /usr/bin/perl -i -pe "s/return tree_sitter_${fn}\\(\\)/return nil  \\/\\/ Fastra-Patch: exotische Sprache ausgeschnitten (Bundle-Groesse, Apple-Silicon-only)/" "$CEL_LANG"
  done
  # Verifizieren, dass ALLE Ziel-Referenzen weg sind — sonst zieht der Linker
  # die Grammatik doch wieder rein und die Ersparnis verpufft lautlos.
  if grep -qE 'return tree_sitter_(agda|elixir|haskell|julia|ocaml|ocaml_interface|scala|verilog|zig)\(\)' "$CEL_LANG" 2>/dev/null; then
    echo "✗ FEHLER: Sprach-Ausschnitt-Patch hat NICHT (vollständig) gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  # Wie 4b–4f: SPM trackt Quell-Änderungen in .build/checkouts NICHT →
  # CodeEditLanguages-Build-Produkte verwerfen, damit CodeLanguage.swift neu
  # übersetzt UND das Fastra-Binary neu gelinkt wird (nur beim Relink fallen
  # die nun unreferenzierten Grammatik-.o aus dem statischen Archiv weg).
  rm -rf .build/*/debug/CodeEditLanguages.build .build/*/release/CodeEditLanguages.build
  rm -f .build/*/debug/Modules/CodeEditLanguages.swiftmodule \
        .build/*/release/Modules/CodeEditLanguages.swiftmodule
fi

# 4h. Patch CodeEditLanguages — Highlight-Query-Pfad layout-robust auflösen.
#
# ROOT CAUSE „Sprache erkannt, aber alles monochrom" (Daniel-Befund
# 2026-07-10, Selbsttest `highlight`): `CodeLanguage.queryURL` baut den Pfad
# als `resourceURL + "Resources/tree-sitter-<name>/highlights.scm"`.
# `Bundle.module.resourceURL` zeigt bei unserem SPM-Resource-Bundle-Layout
# aber bereits auf `…bundle/Resources` → der Pfad wird zu
# `…/Resources/Resources/…` und existiert NIE. TreeSitterClient läuft dann
# ohne Highlight-Queries: kein Fehler, keine Farben. Der Patch prüft beide
# Layouts (Bundle-Wurzel wie upstream-dev vs. bereits-in-Resources wie bei
# uns) und nimmt den existierenden Pfad.
if ! grep -q 'Fastra-Patch: Query-Pfad layout-robust' "$CEL_LANG" 2>/dev/null; then
  echo "→ Patche CodeEditLanguages (Highlight-Query-Pfad layout-robust)"
  # SPM legt Checkout-Dateien read-only ab (444). perl -i (4b–4g) umgeht das
  # durch unlink+neu; Python schreibt in-place → Schreibrecht kurz geben.
  chmod u+w "$CEL_LANG"
  /usr/bin/python3 - "$CEL_LANG" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = '''    internal func queryURL(for highlights: String = "highlights") -> URL? {
        return resourceURL?
            .appendingPathComponent("Resources/tree-sitter-\\(tsName)/\\(highlights).scm")
    }'''
new = '''    internal func queryURL(for highlights: String = "highlights") -> URL? {
        // Fastra-Patch: Query-Pfad layout-robust aufloesen. resourceURL zeigt je
        // nach Bundle-Layout auf die Bundle-Wurzel ODER schon auf .../Resources —
        // das doppelte "Resources/Resources" liess highlights.scm nie finden
        // (Sprache erkannt, aber kein Highlighting).
        guard let base = resourceURL else { return nil }
        let nested = base.appendingPathComponent("Resources/tree-sitter-\\(tsName)/\\(highlights).scm")
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        return base.appendingPathComponent("tree-sitter-\\(tsName)/\\(highlights).scm")
    }'''
if old not in src:
    sys.exit("queryURL-Quelltext hat sich geaendert — Patch 4h passt nicht mehr")
open(path, "w").write(src.replace(old, new))
PYEOF
  # Verifizieren, dass der Patch drin ist — sonst bleibt Highlighting still tot.
  if ! grep -q 'Fastra-Patch: Query-Pfad layout-robust' "$CEL_LANG" 2>/dev/null; then
    echo "✗ FEHLER: Query-Pfad-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  # Wie 4b–4g: Checkout-Änderungen trackt SPM nicht → Build-Produkte verwerfen.
  rm -rf .build/*/debug/CodeEditLanguages.build .build/*/release/CodeEditLanguages.build
  rm -f .build/*/debug/Modules/CodeEditLanguages.swiftmodule \
        .build/*/release/Modules/CodeEditLanguages.swiftmodule
fi

# 4i. Patch CodeEditTextView — überlappende Umbruch-Fragmente reparieren
# („Text-Geist").
#
# ROOT CAUSE (Trace + Selbsttest `ghosttext`, 2026-07-12):
# `CTTypesetter+SuggestLineBreak` liefert den ABSOLUTEN Endindex innerhalb des
# Content-Runs. `Typesetter.layoutTextUntilLineBreak` setzte diesen Endindex aber
# direkt als LÄNGE der nächsten `CFRange` ein. Ab Fragment 2 begann der Bereich
# zwar korrekt am vorherigen Break, reichte aber um dessen kompletten Offset zu
# weit. Die CoreText-Fragmente überlappten dadurch immer stärker: Wörter wurden
# mehrfach gezeichnet und die Fragment-Views liefen trotz Umbruch rechts hinaus.
#
# Fix: Länge = Endindex - Startindex. Upstream `main` enthält denselben Fehler
# am 2026-07-12 weiterhin. Idempotent (Marker-Check); CETV-Build-Produkte
# verwerfen, weil SPM Änderungen in Checkouts nicht selbst erkennt.
CETV_TYPESETTER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/Typesetter.swift"
if ! grep -q 'Fastra-Patch: Break-Endindex in Fragmentlaenge umrechnen' "$CETV_TYPESETTER" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (überlappende Umbruch-Fragmente → Text-Geist-Fix)"
  chmod u+w "$CETV_TYPESETTER"
  /usr/bin/python3 - "$CETV_TYPESETTER" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = '''            let typesetSubrange = NSRange(location: context.currentPosition - range.location, length: lineBreak)
            let typesetData = typesetLine(typesetter: typesetter, range: typesetSubrange)'''
new = '''            // Fastra-Patch: Break-Endindex in Fragmentlaenge umrechnen.
            // `lineBreak` ist ein absoluter Endindex im Content-Run, waehrend
            // NSRange.length eine Laenge erwartet. Ohne die Subtraktion
            // ueberlappt jedes Folgefragment den bereits umbrochenen Text.
            let relativeStart = context.currentPosition - range.location
            let typesetSubrange = NSRange(
                location: relativeStart,
                length: lineBreak - relativeStart
            )
            let typesetData = typesetLine(typesetter: typesetter, range: typesetSubrange)'''
if old not in src:
    sys.exit("Typesetter-Quelltext hat sich geaendert — Patch 4i passt nicht mehr")
open(path, "w").write(src.replace(old, new))
PYEOF
  if ! grep -q 'Fastra-Patch: Break-Endindex in Fragmentlaenge umrechnen' "$CETV_TYPESETTER" 2>/dev/null; then
    echo "✗ FEHLER: Text-Geist-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
fi

# 4j. CodeEditSymbols — Bundle.module in einer gepackten App portabel machen.
# Der SwiftPM-CLI-Accessor sucht Ressourcen neben Fastra.app statt unter dem
# signierbaren Standardpfad Contents/Resources. Auf dem Build-Mac kaschiert
# sein absoluter .build-Fallback diesen Fehler; auf anderen Macs crasht er.
CESYM_SRC="$CHECKOUTS/CodeEditSymbols/Sources/CodeEditSymbols/CodeEditSymbols.swift"
if ! grep -q 'Fastra-Patch: portables CodeEditSymbols-Ressourcenbundle' "$CESYM_SRC" 2>/dev/null; then
  echo "→ Patche CodeEditSymbols (portables Ressourcenbundle)"
  chmod u+w "$CESYM_SRC"
  /usr/bin/python3 - "$CESYM_SRC" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
marker = '''import SwiftUI

// Fastra-Patch: portables CodeEditSymbols-Ressourcenbundle. In der gepackten
// App liegt es standardkonform unter Contents/Resources; Bundle.module bleibt
// der Fallback fuer SwiftPM-CLI-Builds und Tests.
private let fastraCodeEditSymbolsBundle: Bundle = {
    if let resources = Bundle.main.resourceURL,
       let packaged = Bundle(
           url: resources.appendingPathComponent("CodeEditSymbols_CodeEditSymbols.bundle")
       ) {
        return packaged
    }
    return Bundle.module
}()'''
if 'import SwiftUI' not in src:
    sys.exit("CodeEditSymbols-Import hat sich geaendert")
src = src.replace('import SwiftUI', marker, 1)
src = src.replace('Bundle.module', 'fastraCodeEditSymbolsBundle')
# Den absichtlich erhaltenen CLI-Fallback im neuen Helper wiederherstellen.
src = src.replace('return fastraCodeEditSymbolsBundle\n}()', 'return Bundle.module\n}()', 1)
open(path, 'w').write(src)
PYEOF
  rm -rf .build/*/debug/CodeEditSymbols.build .build/*/release/CodeEditSymbols.build
  rm -f .build/*/debug/Modules/CodeEditSymbols.swiftmodule \
        .build/*/release/Modules/CodeEditSymbols.swiftmodule
fi

# 4k. CodeEditLanguages — gleicher portabler Ressourcenpfad für Queries.
if ! grep -q 'Fastra-Patch: portables CodeEditLanguages-Ressourcenbundle' "$CEL_LANG" 2>/dev/null; then
  echo "→ Patche CodeEditLanguages (portables Ressourcenbundle)"
  chmod u+w "$CEL_LANG"
  /usr/bin/python3 - "$CEL_LANG" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
helper = '''import Foundation

// Fastra-Patch: portables CodeEditLanguages-Ressourcenbundle. In der
// gepackten App liegt es unter Contents/Resources; Bundle.module bleibt der
// Fallback fuer SwiftPM-CLI-Builds und Tests.
private let fastraCodeEditLanguagesResourceURL: URL? = {
    if let resources = Bundle.main.resourceURL,
       let packaged = Bundle(
           url: resources.appendingPathComponent("CodeEditLanguages_CodeEditLanguages.bundle")
       ) {
        return packaged.resourceURL
    }
    return Bundle.module.resourceURL
}()'''
if 'import Foundation' not in src:
    sys.exit("CodeEditLanguages-Import hat sich geaendert")
src = src.replace('import Foundation', helper, 1)
old = 'internal var resourceURL: URL? = Bundle.module.resourceURL'
if old not in src:
    sys.exit("CodeEditLanguages-resourceURL hat sich geaendert")
src = src.replace(old, 'internal var resourceURL: URL? = fastraCodeEditLanguagesResourceURL', 1)
open(path, 'w').write(src)
PYEOF
  rm -rf .build/*/debug/CodeEditLanguages.build .build/*/release/CodeEditLanguages.build
  rm -f .build/*/debug/Modules/CodeEditLanguages.swiftmodule \
        .build/*/release/Modules/CodeEditLanguages.swiftmodule
fi

# 4l. Patch CodeEditSourceEditor — Theme-Slots für 4D entkoppeln (Etappe 4
# Wunschpaket 2026-07).
#
# EditorTheme.mapCapture wirft upstream viele Capture-Klassen in dieselben
# Farb-Slots (function/method/property → variables, variableBuiltin →
# keywords); die Theme-Felder `commands`, `values` und `characters` sind
# dagegen KOMPLETT ungenutzt. Für die 4D-Farbkategorien (Befehle, Konstanten,
# Prozessvariablen) leiten wir drei Capture-Klassen auf diese freien Slots
# um. Die Fastra-Standardthemes setzen die vier Slots exakt auf die Farben
# ihrer bisherigen Sammel-Slots → alle bestehenden Sprachen sehen unverändert
# aus; nur die 4D-Themes nutzen die neuen Slots mit eigenen Farben. Der
# Methoden-Slot erhält einen optionalen Default auf `commands`, damit fremde
# Themes beim API-Zuwachs unverändert bleiben.
CESE_THEME="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Theme/EditorTheme.swift"
if ! grep -q 'Fastra-Patch: eigene Slots fuer 4D-Kategorien' "$CESE_THEME" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Theme-Slots für 4D entkoppeln)"
  chmod u+w "$CESE_THEME"
  /usr/bin/python3 - "$CESE_THEME" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = '''        case .include, .constructor, .keyword, .boolean, .variableBuiltin,
                .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            return keywords
        case .comment: return comments
        case .variable, .property: return variables
        case .function, .method: return variables'''
new = '''        // Fastra-Patch: eigene Slots fuer 4D-Kategorien (Etappe 4).
        // commands/values/characters waren upstream ungenutzt; die
        // Standard-Themes belegen sie mit den bisherigen Sammelfarben,
        // bestehende Sprachen aendern sich dadurch NICHT.
        case .include, .constructor, .keyword, .boolean,
                .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            return keywords
        case .variableBuiltin: return values
        case .comment: return comments
        case .variable: return variables
        case .property: return characters
        case .function, .method: return commands'''
if old not in src:
    sys.exit("EditorTheme.mapCapture hat sich geaendert — Patch 4l pruefen")
open(path, 'w').write(src.replace(old, new, 1))
PYEOF
  # Verifizieren + CESE-Build-Produkte verwerfen (SPM trackt Checkout-
  # Änderungen nicht — gleiche Begründung wie bei 4b).
  if ! grep -q 'Fastra-Patch: eigene Slots fuer 4D-Kategorien' "$CESE_THEME" 2>/dev/null; then
    echo "✗ FEHLER: Theme-Slot-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4m. Patch CodeEditSourceEditor — eigener Methoden-Slot für 4D.
#
# Patch 4l trennt bereits Befehle, Konstanten und Prozessvariablen. 4D
# definiert aber auch für Projektmethoden eine eigene Farbe und Schriftart.
# Der Slot wird am Ende des Initializers optional ergänzt, damit jedes
# bestehende Theme ohne Quelländerung weiter die Befehlsdarstellung erbt.
if ! grep -q 'Fastra-Patch: eigener Methoden-Slot fuer 4D' "$CESE_THEME" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (eigener Methoden-Slot für 4D)"
  chmod u+w "$CESE_THEME"
  /usr/bin/python3 - "$CESE_THEME" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

old_property = '''    public var commands: Attribute
    public var types: Attribute'''
new_property = '''    public var commands: Attribute
    // Fastra-Patch: eigener Methoden-Slot fuer 4D. Optional im Initializer,
    // damit bestehende Themes unveraendert den commands-Slot verwenden.
    public var methods: Attribute
    public var types: Attribute'''
if old_property not in src:
    sys.exit("EditorTheme-Properties haben sich geaendert — Patch 4m pruefen")
src = src.replace(old_property, new_property, 1)

old_init = '''        characters: Attribute,
        comments: Attribute
    ) {'''
new_init = '''        characters: Attribute,
        comments: Attribute,
        methods: Attribute? = nil
    ) {'''
if old_init not in src:
    sys.exit("EditorTheme-Initializer hat sich geaendert — Patch 4m pruefen")
src = src.replace(old_init, new_init, 1)

old_assignment = '''        self.commands = commands
        self.types = types'''
new_assignment = '''        self.commands = commands
        self.methods = methods ?? commands
        self.types = types'''
if old_assignment not in src:
    sys.exit("EditorTheme-Assignments haben sich geaendert — Patch 4m pruefen")
src = src.replace(old_assignment, new_assignment, 1)

old_mapping = '''        case .function, .method: return commands'''
new_mapping = '''        case .function: return commands
        case .method: return methods'''
if old_mapping not in src:
    sys.exit("EditorTheme-Methoden-Mapping hat sich geaendert — Patch 4m pruefen")
src = src.replace(old_mapping, new_mapping, 1)
open(path, 'w').write(src)
PYEOF
  # Wie bei 4l: Der immutable SPM-Checkout braucht nach einer Quelländerung
  # zwingend neue Artefakte, sonst wäre der neue Theme-Slot nur Text.
  if ! grep -q 'Fastra-Patch: eigener Methoden-Slot fuer 4D' "$CESE_THEME" \
     || ! grep -q 'case .method: return methods' "$CESE_THEME"; then
    echo "✗ FEHLER: Methoden-Slot-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4n. CodeEditTextView + CodeEditSourceEditor — feste Soft-Wrap-Spalten,
# exakte Page-Guide-Geometrie und stabiler oberer Zeilenanker.
#
# Upstream kennt nur Umbruch an der Viewportbreite. Die vorhandene Guide-Linie
# halbiert ausserdem Zeichenbreite und Text-Inset und liegt dadurch nicht an der
# konfigurierten Textspalte. Fastra ergänzt eine optionale maximale
# Umbruchbreite in Punkten, eine öffentliche `wrapAtColumn`-Konfiguration und
# eine gemeinsame Spaltengeometrie aus echter Editor-Schrift + Kern. Der
# Viewport bleibt die harte Obergrenze. Zusätzlich garantiert der
# Typesetter-Patch bei extrem schmalen Breiten mindestens ein vollständiges
# Graphem pro Fragment, damit CoreTexts 0-Ergebnis keine Endlosschleife erzeugt.
# Beim Umschalten bleibt die tatsächlich oberste logische Textzeile verankert.
# Begrenzte Layoutschritte konvergieren innerhalb desselben Runloops; nur die
# stabile Endposition wird sichtbar.
CETV_MANAGER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager.swift"
CETV_BREAK="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/Extensions/CTTypesetter+SuggestLineBreak.swift"
CESE_BEHAVIOR="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditorConfiguration/SourceEditorConfiguration+Behavior.swift"
CESE_APPEARANCE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditorConfiguration/SourceEditorConfiguration+Appearance.swift"
CESE_CONTROLLER="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController.swift"
CESE_GUIDE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/ReformattingGuide/ReformattingGuideView.swift"
if ! grep -q 'Fastra-Patch: optionale feste Umbruchbreite' "$CETV_MANAGER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: In extrem schmalen Viewports' "$CETV_BREAK" 2>/dev/null \
   || ! grep -q 'wrapAtColumn' "$CESE_BEHAVIOR" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: oberste sichtbare Textzeile' "$CESE_APPEARANCE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: stabiler Top-Zeilen-Anker' "$CESE_GUIDE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: dieselbe echte Spaltengeometrie' "$CESE_GUIDE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: In lokalen View-Koordinaten' "$CESE_GUIDE" 2>/dev/null; then
  echo "→ Patche CodeEdit (feste Soft-Wrap-Spalten + exakte Seitenlinie)"
  chmod u+w "$CETV_MANAGER" "$CETV_BREAK" "$CESE_BEHAVIOR" \
    "$CESE_APPEARANCE" "$CESE_CONTROLLER" "$CESE_GUIDE"
  /usr/bin/python3 - "$CETV_MANAGER" "$CETV_BREAK" "$CESE_BEHAVIOR" \
    "$CESE_APPEARANCE" "$CESE_CONTROLLER" "$CESE_GUIDE" <<'PYEOF'
import sys

manager, line_break, behavior, appearance, controller, guide = sys.argv[1:]

def replace_once(path, marker, old, new):
    src = open(path).read()
    if marker in src:
        return
    if old not in src:
        raise SystemExit(f"{path}: Quelltext hat sich geaendert — Patch 4n pruefen")
    open(path, "w").write(src.replace(old, new, 1))

replace_once(
    manager,
    "Fastra-Patch: optionale feste Umbruchbreite",
    '''    public var wrapLines: Bool {
        didSet {
            setNeedsLayout()
        }
    }''',
    '''    public var wrapLines: Bool {
        didSet {
            setNeedsLayout()
        }
    }
    // Fastra-Patch: optionale feste Umbruchbreite in Punkten. `nil` behaelt
    // das Upstream-Verhalten an der Viewportbreite.
    public var maximumWrapWidth: CGFloat? {
        didSet {
            setNeedsLayout()
        }
    }'''
)
replace_once(
    manager,
    "guard let maximumWrapWidth",
    '''    public var wrapLinesWidth: CGFloat {
        (delegate?.textViewportSize().width ?? .greatestFiniteMagnitude) - edgeInsets.horizontal
    }''',
    '''    public var wrapLinesWidth: CGFloat {
        let viewportWidth =
            (delegate?.textViewportSize().width ?? .greatestFiniteMagnitude)
            - edgeInsets.horizontal
        guard let maximumWrapWidth, maximumWrapWidth > 0 else {
            return viewportWidth
        }
        return min(viewportWidth, maximumWrapWidth)
    }'''
)

replace_once(
    line_break,
    "Fastra-Patch: In extrem schmalen Viewports",
    '''        switch strategy {
        case .character:
            return suggestLineBreakForCharacter(
                string: string,
                startingOffset: subrange.location,
                constrainingWidth: constrainingWidth
            )
        case .word:
            return suggestLineBreakForWord(
                string: string,
                subrange: subrange,
                constrainingWidth: constrainingWidth
            )
        }''',
    '''        let proposedBreak = switch strategy {
        case .character:
            suggestLineBreakForCharacter(
                string: string,
                startingOffset: subrange.location,
                constrainingWidth: constrainingWidth
            )
        case .word:
            suggestLineBreakForWord(
                string: string,
                subrange: subrange,
                constrainingWidth: constrainingWidth
            )
        }
        guard proposedBreak <= subrange.location,
              !subrange.isEmpty,
              subrange.location < string.length else {
            return proposedBreak
        }
        // Fastra-Patch: In extrem schmalen Viewports muss mindestens ein
        // vollstaendiges Graphem vorankommen. Sonst liefert CoreText 0 und
        // die Fragment-Schleife kann endlos auf derselben Position bleiben.
        let cluster = (string.string as NSString)
            .rangeOfComposedCharacterSequence(at: subrange.location)
        return min(cluster.max, subrange.max)'''
)

replace_once(
    behavior,
    "public var wrapAtColumn",
    '''        /// The column to reformat at.
        public var reformatAtColumn: Int = 80''',
    '''        /// The column to reformat at.
        public var reformatAtColumn: Int = 80

        /// Optional column at which soft wrapping should occur. `nil` wraps
        /// at the visible editor width.
        public var wrapAtColumn: Int?'''
)
replace_once(
    behavior,
    "wrapAtColumn: Int? = nil",
    '''            indentOption: IndentOption = .spaces(count: 4),
            reformatAtColumn: Int = 80''',
    '''            indentOption: IndentOption = .spaces(count: 4),
            reformatAtColumn: Int = 80,
            wrapAtColumn: Int? = nil'''
)
replace_once(
    behavior,
    "self.wrapAtColumn = wrapAtColumn",
    '''            self.indentOption = indentOption
            self.reformatAtColumn = reformatAtColumn''',
    '''            self.indentOption = indentOption
            self.reformatAtColumn = reformatAtColumn
            self.wrapAtColumn = wrapAtColumn'''
)
replace_once(
    behavior,
    "oldConfig?.wrapAtColumn",
    '''            if oldConfig?.reformatAtColumn != reformatAtColumn {
                controller.reformattingGuideView.column = reformatAtColumn
                controller.reformattingGuideView.updatePosition(in: controller)
                controller.view.updateConstraintsForSubtreeIfNeeded()
            }''',
    '''            if oldConfig?.reformatAtColumn != reformatAtColumn {
                controller.reformattingGuideView.column = reformatAtColumn
                controller.reformattingGuideView.updatePosition(in: controller)
                controller.view.updateConstraintsForSubtreeIfNeeded()
            }

            if oldConfig?.wrapAtColumn != wrapAtColumn {
                controller.updateFastraColumnGeometry()
            }'''
)

replace_once(
    controller,
    "public var wrapAtColumn",
    '''    /// The column at which to show the reformatting guide
    public var reformatAtColumn: Int { configuration.behavior.reformatAtColumn }''',
    '''    /// The column at which to show the reformatting guide
    public var reformatAtColumn: Int { configuration.behavior.reformatAtColumn }

    /// Optional fixed soft-wrap column; `nil` uses the viewport width.
    public var wrapAtColumn: Int? { configuration.behavior.wrapAtColumn }'''
)

replace_once(
    appearance,
    "Fastra-Patch: oberste sichtbare Textzeile",
    '''            if oldConfig?.wrapLines != wrapLines {
                controller.textView.layoutManager.wrapLines = wrapLines
                controller.minimapView.layoutManager?.wrapLines = wrapLines
                controller.scrollView.hasHorizontalScroller = !wrapLines
                controller.updateTextInsets()
            }''',
    '''            if oldConfig?.wrapLines != wrapLines {
                // Fastra-Patch: oberste sichtbare Textzeile vor der
                // Hoehenaenderung merken. Derselbe absolute Y-Wert zeigt nach
                // neuem Umbruch sonst eine andere logische Zeile.
                let topVisibleLine = controller.fastraTopVisibleLineIndex()
                controller.textView.layoutManager.wrapLines = wrapLines
                controller.minimapView.layoutManager?.wrapLines = wrapLines
                controller.scrollView.hasHorizontalScroller = !wrapLines
                controller.updateTextInsets()
                controller.restoreFastraTopVisibleLine(
                    topVisibleLine,
                    expectedWrapLines: wrapLines
                )
            }'''
)

replace_once(
    appearance,
    "controller.updateFastraColumnGeometry()",
    '''            if needsHighlighterInvalidation {
                controller.highlighter?.invalidate()
            }''',
    '''            if oldConfig?.font != font || oldConfig?.letterSpacing != letterSpacing {
                controller.updateFastraColumnGeometry()
            }

            if needsHighlighterInvalidation {
                controller.highlighter?.invalidate()
            }'''
)

replace_once(
    guide,
    "Fastra-Patch: dieselbe echte Spaltengeometrie",
    '''        // Calculate the x position based on the font's character width and column number
        let xPosition = (
            CGFloat(column) * (controller.font.charWidth / 2) // Divide by 2 to account for coordinate system
            + (controller.textViewInsets.left / 2)
        )''',
    '''        // Fastra-Patch: dieselbe echte Spaltengeometrie wie der Soft Wrap.
        // Die fruehere Halbierung von Zeichenbreite und Inset lag sichtbar
        // links von der konfigurierten Textspalte.
        let xPosition = controller.textView.layoutManager.edgeInsets.left
            + controller.fastraWidth(forColumn: column)'''
)
replace_once(
    guide,
    "let documentWidth = max(controller.textView.frame.width",
    '''        let maxWidth = max(0, contentSize.width - xPosition)''',
    '''        let documentWidth = max(controller.textView.frame.width, contentSize.width)
        let maxWidth = max(0, documentWidth - xPosition)'''
)
replace_once(
    guide,
    "Fastra-Patch: In lokalen View-Koordinaten zeichnen",
    '''        // Draw the vertical line (accounting for inverted Y coordinate system)
        lineColor.setStroke()
        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: frame.minX, y: frame.maxY))  // Start at top
        linePath.line(to: NSPoint(x: frame.minX, y: frame.minY))  // Draw down to bottom
        linePath.lineWidth = 1.0
        linePath.stroke()

        // Draw the shaded area to the right of the line
        shadedColor.setFill()
        let shadedRect = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )''',
    '''        // Fastra-Patch: In lokalen View-Koordinaten zeichnen. `frame` liegt
        // im Koordinatensystem des Eltern-Views und verschob Linie sowie
        // Schattierung ein zweites Mal nach rechts aus dem sichtbaren Bereich.
        lineColor.setStroke()
        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY))
        linePath.line(to: NSPoint(x: bounds.minX, y: bounds.minY))
        linePath.lineWidth = 1.0
        linePath.stroke()

        // Draw the shaded area to the right of the line
        shadedColor.setFill()
        let shadedRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: bounds.height
        )'''
)
src = open(guide).read()
if "func updateFastraColumnGeometry()" not in src:
    src += '''

extension TextViewController {
    /// Breite einer Textspalte mit der tatsaechlichen Editor-Schrift und
    /// Zeichenweite. Zoom und Fontwechsel laufen beide ueber diese Quelle.
    func fastraWidth(forColumn column: Int) -> CGFloat {
        let characterWidth = max(font.charWidth + textView.kern, 1)
        return CGFloat(max(column, 1)) * characterWidth
    }

    /// Haelt feste Umbruchbreite und Guide nach Konfigurationsaenderungen
    /// synchron. Der Viewport bleibt weiterhin die harte Obergrenze.
    func updateFastraColumnGeometry() {
        textView.layoutManager.maximumWrapWidth =
            wrapAtColumn.map { fastraWidth(forColumn: $0) }
        reformattingGuideView?.updatePosition(in: self)
        textView.updateFrameIfNeeded()
    }

    /// Fastra-Patch: Top-Zeilen-Anker statt absoluten Y-Wert sichern.
    func fastraTopVisibleLineIndex() -> Int? {
        textView.layoutManager.textLineForPosition(
            textView.visibleRect.minY
        )?.index
    }

    /// Nach einer Umbruchaenderung konvergiert CodeEdits Lazy-Layout erst
    /// schrittweise auf die echten Hoehen aller langen Zeilen vor dem Anker.
    /// Kleine, begrenzte Nachlaeufe erhalten die logische oberste Zeile, ohne
    /// das gesamte Dokument synchron auf dem Main-Thread auszulegen.
    func restoreFastraTopVisibleLine(
        _ lineIndex: Int?,
        expectedWrapLines: Bool,
        attempt: Int = 0
    ) {
        guard wrapLines == expectedWrapLines,
              let lineIndex,
              let scrollView,
              let line = textView.layoutManager.textLineForIndex(lineIndex),
              let rect = textView.layoutManager.rectForOffset(
                  line.range.location
              ) else {
            return
        }
        let targetY = max(
            rect.minY - scrollView.contentInsets.top + 1,
            0
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: targetY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutManager.layoutLines()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self,
                  self.wrapLines == expectedWrapLines,
                  attempt < 24,
                  self.fastraTopVisibleLineIndex() != lineIndex else {
                return
            }
            self.restoreFastraTopVisibleLine(
                lineIndex,
                expectedWrapLines: expectedWrapLines,
                attempt: attempt + 1
            )
        }
    }
}
'''
    open(guide, "w").write(src)
elif "Fastra-Patch: Top-Zeilen-Anker" not in src:
    old = '''    func updateFastraColumnGeometry() {
        textView.layoutManager.maximumWrapWidth =
            wrapAtColumn.map { fastraWidth(forColumn: $0) }
        reformattingGuideView?.updatePosition(in: self)
        textView.updateFrameIfNeeded()
    }
}'''
    new = '''    func updateFastraColumnGeometry() {
        textView.layoutManager.maximumWrapWidth =
            wrapAtColumn.map { fastraWidth(forColumn: $0) }
        reformattingGuideView?.updatePosition(in: self)
        textView.updateFrameIfNeeded()
    }

    /// Fastra-Patch: Top-Zeilen-Anker statt absoluten Y-Wert sichern.
    func fastraTopVisibleLineIndex() -> Int? {
        textView.layoutManager.textLineForPosition(
            textView.visibleRect.minY
        )?.index
    }

    /// Nach einer Umbruchaenderung konvergiert CodeEdits Lazy-Layout erst
    /// schrittweise auf die echten Hoehen aller langen Zeilen vor dem Anker.
    /// Kleine, begrenzte Nachlaeufe erhalten die logische oberste Zeile, ohne
    /// das gesamte Dokument synchron auf dem Main-Thread auszulegen.
    func restoreFastraTopVisibleLine(
        _ lineIndex: Int?,
        expectedWrapLines: Bool,
        attempt: Int = 0
    ) {
        guard wrapLines == expectedWrapLines,
              let lineIndex,
              let scrollView,
              let line = textView.layoutManager.textLineForIndex(lineIndex),
              let rect = textView.layoutManager.rectForOffset(
                  line.range.location
              ) else {
            return
        }
        let targetY = max(
            rect.minY - scrollView.contentInsets.top + 1,
            0
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: targetY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutManager.layoutLines()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self,
                  self.wrapLines == expectedWrapLines,
                  attempt < 24,
                  self.fastraTopVisibleLineIndex() != lineIndex else {
                return
            }
            self.restoreFastraTopVisibleLine(
                lineIndex,
                expectedWrapLines: expectedWrapLines,
                attempt: attempt + 1
            )
        }
    }
}'''
    if old not in src:
        raise SystemExit(f"{guide}: Quelltext hat sich geaendert — Top-Zeilen-Patch pruefen")
    open(guide, "w").write(src.replace(old, new, 1))

src = open(guide).read()
if "Fastra-Patch: stabiler Top-Zeilen-Anker" not in src:
    old = '''    /// Nach einer Umbruchaenderung konvergiert CodeEdits Lazy-Layout erst
    /// schrittweise auf die echten Hoehen aller langen Zeilen vor dem Anker.
    /// Kleine, begrenzte Nachlaeufe erhalten die logische oberste Zeile, ohne
    /// das gesamte Dokument synchron auf dem Main-Thread auszulegen.
    func restoreFastraTopVisibleLine(
        _ lineIndex: Int?,
        expectedWrapLines: Bool,
        attempt: Int = 0
    ) {
        guard wrapLines == expectedWrapLines,
              let lineIndex,
              let scrollView,
              let line = textView.layoutManager.textLineForIndex(lineIndex),
              let rect = textView.layoutManager.rectForOffset(
                  line.range.location
              ) else {
            return
        }
        let targetY = max(
            rect.minY - scrollView.contentInsets.top + 1,
            0
        )
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: targetY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutManager.layoutLines()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self,
                  self.wrapLines == expectedWrapLines,
                  attempt < 24,
                  self.fastraTopVisibleLineIndex() != lineIndex else {
                return
            }
            self.restoreFastraTopVisibleLine(
                lineIndex,
                expectedWrapLines: expectedWrapLines,
                attempt: attempt + 1
            )
        }
    }'''
    new = '''    /// CodeEdits Lazy-Layout kennt nach einer Umbruchaenderung die neuen
    /// Hoehen der Zeilen vor dem Anker noch nicht. Die Geometrie konvergiert
    /// deshalb in begrenzten Layoutschritten innerhalb desselben Runloops.
    /// Erst die stabile Endposition wird sichtbar; es gibt keine zeitlich
    /// versetzten Scrollkorrekturen mehr.
    func restoreFastraTopVisibleLine(
        _ lineIndex: Int?,
        expectedWrapLines: Bool
    ) {
        guard wrapLines == expectedWrapLines,
              let lineIndex,
              let scrollView,
              let line = textView.layoutManager.textLineForIndex(lineIndex),
              let rect = textView.layoutManager.rectForOffset(
                  line.range.location
              ) else {
            return
        }

        let inset = scrollView.contentInsets.top
        var targetY = max(rect.minY - inset + 1, 0)
        var pass = 0

        while wrapLines == expectedWrapLines, pass < 24 {
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: targetY
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let previousTargetY = targetY
            textView.layoutManager.layoutLines()
            textView.layoutSubtreeIfNeeded()

            guard let refreshedLine = textView.layoutManager.textLineForIndex(
                lineIndex
            ), let refreshedRect = textView.layoutManager.rectForOffset(
                refreshedLine.range.location
            ) else {
                return
            }
            targetY = max(refreshedRect.minY - inset + 1, 0)
            pass += 1

            if abs(targetY - previousTargetY) < 0.5 {
                break
            }
        }

        guard wrapLines == expectedWrapLines else { return }

        // Fastra-Patch: stabiler Top-Zeilen-Anker. Nur diese abschliessende
        // Position erreicht den naechsten sichtbaren Frame.
        scrollView.contentView.scroll(
            to: NSPoint(
                x: scrollView.contentView.bounds.origin.x,
                y: targetY
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }'''
    if old not in src:
        raise SystemExit(f"{guide}: Quelltext hat sich geaendert — stabilen Top-Zeilen-Patch pruefen")
    open(guide, "w").write(src.replace(old, new, 1))
PYEOF
  if ! grep -q 'Fastra-Patch: optionale feste Umbruchbreite' "$CETV_MANAGER" \
     || ! grep -q 'Fastra-Patch: In extrem schmalen Viewports' "$CETV_BREAK" \
     || ! grep -q 'wrapAtColumn' "$CESE_BEHAVIOR" \
     || ! grep -q 'Fastra-Patch: oberste sichtbare Textzeile' "$CESE_APPEARANCE" \
     || ! grep -q 'Fastra-Patch: stabiler Top-Zeilen-Anker' "$CESE_GUIDE" \
     || ! grep -q 'Fastra-Patch: dieselbe echte Spaltengeometrie' "$CESE_GUIDE" \
     || ! grep -q 'Fastra-Patch: In lokalen View-Koordinaten' "$CESE_GUIDE"; then
    echo "✗ FEHLER: Soft-Wrap-Spalten-Patch hat NICHT vollständig gegriffen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4o. CodeEditTextView — Rechteckauswahl auf logischen Zeilen.
#
# Upstreams Implementierung behandelt jedes sichtbare Soft-Wrap-Fragment wie
# eine eigene Rechteckzeile. Fastra ersetzt diese Datei deshalb durch einen
# versionierten Patch und verdrahtet Copy/Paste, Undo sowie die aktive Tab- und
# Einrückungsgeometrie. Jede Patchstelle besitzt einen Marker; ein veränderter
# Upstream bricht den Build verständlich ab, statt still anderes Verhalten zu
# liefern.
CETV_COLUMN="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+ColumnSelection.swift"
CETV_COPY_PASTE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+CopyPaste.swift"
CETV_DELETE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Delete.swift"
CETV_REPLACE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+ReplaceCharacters.swift"
COLUMN_PATCH_SOURCE="Patches/CodeEditTextView/TextView+ColumnSelection.swift"
if [ ! -f "$COLUMN_PATCH_SOURCE" ]; then
  echo "✗ FEHLER: Versionierter Rechteckauswahl-Patch fehlt." >&2
  exit 1
fi

COLUMN_PATCH_CHANGED=0
if ! cmp -s "$COLUMN_PATCH_SOURCE" "$CETV_COLUMN"; then
  echo "→ Patche CodeEditTextView (Rechteckauswahl auf logischen Zeilen)"
  chmod u+w "$CETV_COLUMN"
  cp "$COLUMN_PATCH_SOURCE" "$CETV_COLUMN"
  COLUMN_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Rechteck-Copy' "$CETV_COPY_PASTE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Rechteck-Paste' "$CETV_COPY_PASTE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Rechteck-Delete' "$CETV_DELETE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche' "$CETV_REPLACE" 2>/dev/null \
   || ! grep -q 'fastraColumnSelectionTabWidth = tabWidth' "$CESE_APPEARANCE" 2>/dev/null \
   || ! grep -q 'fastraColumnIndentationUnit' "$CESE_BEHAVIOR" 2>/dev/null; then
  echo "→ Verdrahte Rechteckauswahl mit Copy/Paste, Undo und Editorprofil"
  chmod u+w "$CETV_COPY_PASTE" "$CETV_DELETE" "$CETV_REPLACE" \
    "$CESE_APPEARANCE" "$CESE_BEHAVIOR"
  /usr/bin/python3 - "$CETV_COPY_PASTE" "$CETV_DELETE" "$CETV_REPLACE" \
    "$CESE_APPEARANCE" "$CESE_BEHAVIOR" <<'PYEOF'
import sys

copy_paste, delete, replace_characters, appearance, behavior = sys.argv[1:]

def replace_once(path, marker, old, new):
    src = open(path).read()
    if marker in src:
        return
    if old not in src:
        raise SystemExit(
            f"{path}: Quelltext hat sich geaendert — Patch 4o pruefen"
        )
    open(path, "w").write(src.replace(old, new, 1))

replace_once(
    copy_paste,
    "Fastra-Patch: Rechteck-Copy",
    '''    @objc open func copy(_ sender: AnyObject) {
        guard let textSelections = selectionManager?''',
    '''    @objc open func copy(_ sender: AnyObject) {
        // Fastra-Patch: Rechteck-Copy schreibt einen zeilenweisen Textwert.
        if fastraCopyColumnSelection() {
            return
        }
        guard let textSelections = selectionManager?'''
)
replace_once(
    copy_paste,
    "Fastra-Patch: Rechteck-Paste",
    '''    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }''',
    '''    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        // Fastra-Patch: Rechteck-Paste verteilt Zeilen auf logische Zeilen.
        if fastraPasteIntoColumnSelection(stringContents) {
            return
        }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }'''
)
replace_once(
    delete,
    "Fastra-Patch: Rechteck-Delete",
    '''    private func delete(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        decomposeCharacters: Bool = false
    ) {
        /// Extend each selection''',
    '''    private func delete(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        decomposeCharacters: Bool = false
    ) {
        // Fastra-Patch: Rechteck-Delete darf leere Bereiche kurzer Zeilen
        // nicht auf das benachbarte Zeichen ausweiten.
        if fastraDeleteColumnSelection() {
            return
        }
        /// Extend each selection'''
)
replace_once(
    replace_characters,
    "Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche",
    '''    ) {
        guard isEditable else { return }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)''',
    '''    ) {
        guard isEditable else { return }
        // Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche. Das betrifft
        // insbesondere Tippen, Delete und Cut auf einer Rechteckauswahl.
        let startsFastraUndoGrouping =
            ranges.count > 1 && !(_undoManager?.isGrouping ?? false)
        if startsFastraUndoGrouping {
            _undoManager?.beginUndoGrouping()
        }
        defer {
            if startsFastraUndoGrouping {
                _undoManager?.endUndoGrouping()
            }
        }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)'''
)
replace_once(
    appearance,
    "fastraColumnSelectionTabWidth = tabWidth",
    '''            if oldConfig?.tabWidth != tabWidth {
                controller.paragraphStyle = controller.generateParagraphStyle()''',
    '''            if oldConfig?.tabWidth != tabWidth {
                controller.textView.fastraColumnSelectionTabWidth = tabWidth
                controller.paragraphStyle = controller.generateParagraphStyle()'''
)
replace_once(
    behavior,
    "fastraColumnIndentationUnit",
    '''            if oldConfig?.indentOption != indentOption {
                controller.setUpTextFormation()''',
    '''            if oldConfig?.indentOption != indentOption {
                controller.textView.fastraColumnIndentationUnit =
                    indentOption.stringValue
                controller.setUpTextFormation()'''
)
PYEOF
  COLUMN_PATCH_CHANGED=1
fi

if ! grep -q 'FastraColumnSelectionSnapshot' "$CETV_COLUMN" \
   || ! grep -q 'Fastra-Patch: Rechteck-Copy' "$CETV_COPY_PASTE" \
   || ! grep -q 'Fastra-Patch: Rechteck-Paste' "$CETV_COPY_PASTE" \
   || ! grep -q 'Fastra-Patch: Rechteck-Delete' "$CETV_DELETE" \
   || ! grep -q 'Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche' "$CETV_REPLACE" \
   || ! grep -q 'fastraColumnSelectionTabWidth = tabWidth' "$CESE_APPEARANCE" \
   || ! grep -q 'fastraColumnIndentationUnit' "$CESE_BEHAVIOR"; then
  echo "✗ FEHLER: Rechteckauswahl-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi

if [ "$COLUMN_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4p. CodeEditTextView — Auswahl bis zum finalen Zeilenumbruch zeichnen.
#
# Endet eine Datei mit LF, CRLF oder CR, liefert `rectForOffset` für das
# Dokumentende bereits den Cursor in der leeren Dateiende-Zeile. Upstream
# verwendete dessen linke X-Position als rechte Kante der vorherigen
# Textzeile: Das Auswahlrechteck bekam Breite 0 und die letzte Zeile wirkte
# trotz korrekter ⌘A-Range unmarkiert.
CETV_SELECTION_FILL="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager+FillRects.swift"
SELECTION_EOL_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: finalen Zeilenumbruch bis zum rechten Rand markieren' \
    "$CETV_SELECTION_FILL" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Auswahl am Dateiende)"
  chmod u+w "$CETV_SELECTION_FILL"
  /usr/bin/python3 - "$CETV_SELECTION_FILL" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''            let endOfDocument = intersectionRange.max == layoutManager.lineStorage.length
            let emptyLine = linePosition.range.isEmpty

            // If the selection is at the end of the line, or contains the end of the fragment, and is not the end
            // of the document, we select the entire line to the right of the selection point.
            // true, !true = false, false
            // true, !true = false, true
            if endOfLine && !(endOfDocument && !emptyLine) {'''
new = '''            let endOfDocument = intersectionRange.max == layoutManager.lineStorage.length
            let emptyLine = linePosition.range.isEmpty
            let lineEndsWithLineEnding = textStorage
                .flatMap { $0.substring(from: linePosition.range) }
                .flatMap(LineEnding.init(line:)) != nil

            // Fastra-Patch: finalen Zeilenumbruch bis zum rechten Rand markieren.
            // `rectForOffset(documentEnd)` liegt dann schon links in der leeren
            // EOF-Zeile und würde für die letzte Textzeile Breite 0 ergeben.
            if endOfLine && (!endOfDocument || emptyLine || lineEndsWithLineEnding) {'''
if old not in src:
    raise SystemExit(
        f"{path}: Quelltext hat sich geaendert — Patch 4p pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
  SELECTION_EOL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: finalen Zeilenumbruch bis zum rechten Rand markieren' \
    "$CETV_SELECTION_FILL"; then
  echo "✗ FEHLER: Dateiende-Auswahl-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$SELECTION_EOL_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 5. Build-Cache invalidieren, sonst greift SPM auf das alte Plugin-Manifest zu
rm -f .build/build.db .build/plugin-tools.yaml .build/release.yaml

# 6. Build über Xcode-Toolchain (PreviewsMacros + SourceKit liegen dort)
CONFIG="${1:-debug}"
echo "→ Build (Konfiguration: $CONFIG)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swift build -c "$CONFIG"

# 7. Als .app-Bundle verpacken
#
# Ohne Bundle läuft das Binary zwar (Info.plist ist ins Binary einkompiliert),
# bekommt aber **keine reguläre Menüleiste** und CMD-Shortcuts landen im
# Terminal statt in der App. Erst der Bundle-Wrapper macht aus dem Binary
# eine vollwertige macOS-App.
APP=".build/$CONFIG/Fastra.app"
echo "→ Bundle bauen ($APP)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
cp ".build/$CONFIG/Fastra" "$APP/Contents/MacOS/Fastra"
cp Info.plist "$APP/Contents/Info.plist"

# App-Icon auf Bundle-Ebene. Info.plist verweist via CFBundleIconFile
# auf "AppIcon" → Contents/Resources/AppIcon.icns. Ohne diese Datei
# zeigt Finder/Dock nur das generische Platzhalter-Icon.
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ressourcen-Bundles (Assets.xcassets, CodeEdit-Symbols, ...) an den für
# signierbare macOS-Apps standardkonformen Ort kopieren. Fastras Locator und
# die beiden Fremdmodul-Patches bevorzugen dort `Bundle.main.resourceURL`.
for bundle in ".build/$CONFIG/"*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done

# SwiftPM linkt Sparkles Binär-Target, verpackt das dynamische Framework aber
# nicht in unser manuell gebautes App-Bundle. `ditto` erhält die für Frameworks
# wichtigen Symlinks und Rechte. Fastra ist nicht sandboxed; Sparkles XPC-Dienste
# sind daher weder aktiviert noch nötig und werden bewusst nicht ausgeliefert.
SPARKLE_SOURCE="$(find .build/artifacts/sparkle -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_SOURCE" ]; then
  echo "✗ FEHLER: Sparkle.framework fehlt nach dem SwiftPM-Build." >&2
  exit 1
fi
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE_FRAMEWORK"
rm -rf "$SPARKLE_FRAMEWORK/Versions/B/XPCServices" "$SPARKLE_FRAMEWORK/XPCServices"

# Lizenzhinweise gehören in die verteilte App, nicht nur ins Quell-Repository.
cp ../THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/Third-Party-Notices.md"
SPARKLE_LICENSE="$(find .build/artifacts/sparkle -type f -name LICENSE -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_LICENSE" ]; then
  echo "✗ FEHLER: Sparkles vollständige Lizenzdatei fehlt." >&2
  exit 1
fi
cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# Finder-/LaunchServices-Texte gehören ins Haupt-App-Bundle, nicht nur in das
# SwiftPM-Ressourcenbundle. So erscheint z. B. der Dokumenttyp auf englischen
# Systemen als „Text File“.
if [ -d Sources/Fastra/Resources/en.lproj ]; then
  mkdir -p "$APP/Contents/Resources/en.lproj"
  for localized_file in Localizable.strings InfoPlist.strings; do
    if [ -f "Sources/Fastra/Resources/en.lproj/$localized_file" ]; then
      cp "Sources/Fastra/Resources/en.lproj/$localized_file" \
        "$APP/Contents/Resources/en.lproj/$localized_file"
    fi
  done
fi

# CodeEditLanguages liefert seine Tree-sitter-Grammatiken als prebuilt
# XCFramework (CodeLanguagesContainer, binaryTarget). Das ist ein STATISCHES
# Archiv (früher universal x86_64+arm64, ~375 MB): es wird zur BUILD-Zeit ins
# Fastra-Binary gelinkt und zur Laufzeit NIE geladen — dyld kann ein ar-Archiv
# gar nicht laden, und das Binary hat keine passende Load-Command (nicht in
# `otool -L`). Früher wurde es dennoch nach Contents/Frameworks kopiert: reines
# totes Gewicht, das das Bundle vervierfachte. Wir kopieren es daher NICHT mehr.
# (Apple-Silicon-only — die x86_64-Hälfte des Archivs wäre ohnehin unnütz.)
# Sollte je ein ECHT dynamisches Framework (.dylib-Binary) dazukommen, müsste
# hier wieder selektiv kopiert werden — statische Archive aber bewusst nicht.

# Release-Bundle verschlanken: Debug-Symbole aus dem Binary strippen.
# strip entfernt hier nur wenige MB (der Löwenanteil des Binaries sind die
# einkompilierten Grammatiken, nicht Symbole), invalidiert aber auf Apple
# Silicon die (ad-hoc-)Signatur → danach ZWINGEND ad-hoc neu signieren, sonst
# killt Gatekeeper den Start ("code signature invalid"). Nur im Release-Build;
# Debug behält seine Symbole für die Crash-/lldb-Diagnose.
if [ "$CONFIG" = "release" ]; then
  echo "→ Release: Binary strippen"
  strip -x "$APP/Contents/MacOS/Fastra"
fi

# Auch lokale Builds brauchen nach dem Einbetten von Sparkle eine konsistente
# innere Signatur. Der Release-/Installationspfad signiert dasselbe Bundle
# später noch einmal mit Developer ID, Hardened Runtime und Zeitstempel.
./sign-bundle.sh "$APP" -

# Pflicht-Gate für verteilbare Bundles: Blendet die absoluten SwiftPM-
# Build-Fallbacks kurz aus und startet den fensterlosen Lokalisierungstest.
# So wird ein auf diesem Mac funktionierender, fremd-Mac-toter Build bereits
# hier abgewiesen und erreicht weder Notarisierung noch Installation.
./verify-portable-app.sh "$APP" ".build/$CONFIG"

# Fertiges Bundle zusätzlich ins Projekt-Hauptverzeichnis kopieren —
# dort ist es sichtbar und bequem doppelklickbar, statt im versteckten
# .build-Ordner zu stecken. Es liegt immer die ZULETZT gebaute Variante
# dort (debug oder release). ditto statt cp -R: ersetzt sauber in-place,
# erhält Rechte/Symlinks im Bundle.
ROOT_APP="../Fastra.app"
rm -rf "$ROOT_APP"
ditto "$APP" "$ROOT_APP"

# Jeder erfolgreiche Build soll sofort als produktive App vorliegen haben.
# Das Kopieren geschieht NACH dem Portabilitäts-Gate: Ein
# unvollständiges oder lokal-abhängiges Bundle kann /Applications damit nie
# überschreiben. Die laufende App wurde oben bereits beendet, damit macOS
# keine offene Binärdatei nur teilweise ersetzt.
APPLICATIONS_APP="/Applications/Fastra.app"
echo "→ App nach /Applications kopieren"
rm -rf "$APPLICATIONS_APP"
ditto "$APP" "$APPLICATIONS_APP"

echo
echo "✔ Fertig. App-Bundle: $APP"
echo "  Kopie zum Doppelklicken: $(cd .. && pwd)/Fastra.app ($CONFIG)"
echo "  Installiert: $APPLICATIONS_APP ($CONFIG)"
echo "  Start mit: open $APPLICATIONS_APP"
