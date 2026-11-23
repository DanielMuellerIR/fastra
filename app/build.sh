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

# Vor Bundle-Kopieren nur eigene laufende Fastra-Instanzen beenden, deren
# Binary dieses Skript gleich überschreibt: der lokale .build-Baum oder
# Fastra.app im Projekt-Root. Installierte Apps und andere Worktrees bleiben
# unberührt. `pwd -P` deckt alternative Symlink-Pfade desselben Ortes ab.
kill_own_fastra_instances() {
  local build_tree build_tree_phys root_bin root_bin_phys pid comm killed=0
  build_tree="$(pwd)/.build"
  build_tree_phys="$(pwd -P)/.build"
  root_bin="$(cd .. && pwd)/Fastra.app/Contents/MacOS/Fastra"
  root_bin_phys="$(cd .. && pwd -P)/Fastra.app/Contents/MacOS/Fastra"
  for pid in $(pgrep -x Fastra 2>/dev/null || true); do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$comm" in
      "$build_tree"/*|"$build_tree_phys"/*|"$root_bin"|"$root_bin_phys")
        echo "→ Eigene laufende Fastra-Instanz beenden (PID $pid: $comm)"
        kill "$pid" 2>/dev/null || true
        killed=1
        ;;
    esac
  done
  # Erst nach dem Beenden kurz warten, damit die Binaries wirklich frei sind.
  if [ "$killed" -eq 1 ]; then
    sleep 1
  fi
}
kill_own_fastra_instances

CHECKOUTS=".build/checkouts"

# 1. Sources erst resolven, damit .build/checkouts/ existiert
if [ ! -d "$CHECKOUTS/CodeEditSourceEditor" ]; then
  echo "→ Dependencies werden gelöst…"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swift package resolve
fi

# 2. Patch CodeEditSourceEditor — SwiftLint-Plugin entfernen
CESE="$CHECKOUTS/CodeEditSourceEditor/Package.swift"
# Nur vollständige frische oder vorbereitete Manifeststellen akzeptieren.
# Eine geänderte Dependency darf nicht nach dem Entfernen der Plugins übrigbleiben.
if [ ! -f "$CESE" ] || [ ! -r "$CESE" ] || ! /usr/bin/perl -0777 -e '
  $_ = <>;
  $plugins = () = /plugins: \[\s*\.plugin\(name: "SwiftLint", package: "SwiftLintPlugin"\)\s*\]/g;
  $dependency = () = /\.package\(\s*url: "https:\/\/github\.com\/lukepistrol\/SwiftLintPlugin",\s*from: "0\.2\.2"\s*\),?/g;
  $references = () = /SwiftLintPlugin/g;
  $empty = () = /plugins: \[\]/g;
  exit !(($plugins == 2 && $dependency == 1 && $references == 3 && $empty == 0)
      || ($plugins == 0 && $dependency == 0 && $references == 0 && $empty == 2));
' "$CESE"; then
  echo "✗ FEHLER: CESE-SwiftLint-Manifest hat einen unbekannten Zustand. Build abgebrochen." >&2
  exit 1
fi
if grep -q 'plugin(name: "SwiftLint", package: "SwiftLintPlugin")' "$CESE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor/Package.swift (SwiftLint-Plugin aus)"
  # Plugin im Target rauspatchen (perl statt sed, weil sed-multiline auf macOS
  # brüchig ist — siehe LESSONS-LEARNED, Sektion F).
  /usr/bin/perl -i -0pe 's|plugins: \[\s*\.plugin\(name: "SwiftLint", package: "SwiftLintPlugin"\)\s*\]|plugins: []|g' "$CESE"
  # Dependency rauspatchen
  /usr/bin/perl -i -0pe 's|\.package\(\s*url: "https://github.com/lukepistrol/SwiftLintPlugin",\s*from: "0\.2\.2"\s*\),?||g' "$CESE"
fi

# Auch vorbereitete Checkouts vor dem nächsten Buildschritt prüfen.
if ! /usr/bin/perl -0777 -e '
  $_ = <>;
  $empty = () = /plugins: \[\]/g;
  exit !($empty == 2 && !/SwiftLintPlugin/);
' "$CESE"; then
  echo "✗ FEHLER: CESE-SwiftLint-Patch hat NICHT vollständig gegriffen. Build abgebrochen." >&2
  exit 1
fi

# 3. Patch CodeEditTextView — gleicher Plugin-Block
CETV="$CHECKOUTS/CodeEditTextView/Package.swift"
# Nur vollständige frische oder vorbereitete Manifeststellen akzeptieren.
# Eine geänderte Dependency darf nicht nach dem Entfernen der Plugins übrigbleiben.
if [ ! -f "$CETV" ] || [ ! -r "$CETV" ] || ! /usr/bin/perl -0777 -e '
  $_ = <>;
  $plugins = () = /plugins: \[\s*\.plugin\(name: "SwiftLint", package: "SwiftLintPlugin"\)\s*\]/g;
  $dependency = () = /\.package\(\s*url: "https:\/\/github\.com\/lukepistrol\/SwiftLintPlugin",\s*from: "0\.52\.2"\s*\),?/g;
  $references = () = /SwiftLintPlugin/g;
  $empty = () = /plugins: \[\]/g;
  exit !(($plugins == 2 && $dependency == 1 && $references == 3 && $empty == 0)
      || ($plugins == 0 && $dependency == 0 && $references == 0 && $empty == 2));
' "$CETV"; then
  echo "✗ FEHLER: CETV-SwiftLint-Manifest hat einen unbekannten Zustand. Build abgebrochen." >&2
  exit 1
fi
if grep -q 'plugin(name: "SwiftLint", package: "SwiftLintPlugin")' "$CETV" 2>/dev/null; then
  echo "→ Patche CodeEditTextView/Package.swift (SwiftLint-Plugin aus)"
  /usr/bin/perl -i -0pe 's|plugins: \[\s*\.plugin\(name: "SwiftLint", package: "SwiftLintPlugin"\)\s*\]|plugins: []|g' "$CETV"
  /usr/bin/perl -i -0pe 's|\.package\(\s*url: "https://github.com/lukepistrol/SwiftLintPlugin",\s*from: "0\.52\.2"\s*\),?||g' "$CETV"
fi

# Auch vorbereitete Checkouts vor dem nächsten Buildschritt prüfen.
if ! /usr/bin/perl -0777 -e '
  $_ = <>;
  $empty = () = /plugins: \[\]/g;
  exit !($empty == 2 && !/SwiftLintPlugin/);
' "$CETV"; then
  echo "✗ FEHLER: CETV-SwiftLint-Patch hat NICHT vollständig gegriffen. Build abgebrochen." >&2
  exit 1
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
  # Wichtig: SPM trackt Quell-Änderungen innerhalb von .build/checkouts nicht
  # (Dependencies gelten als immutable — nur ein `swift build` ohne Recompile).
  # Damit der Patch in die Binärdatei gelangt, die CESE-Build-Produkte
  # verwerfen → SPM muss das Modul neu übersetzen. Greift nur in diesem
  # Zweig, also nur direkt nach dem (Neu-)Patchen.
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4b-2. Patch CodeEditSourceEditor — manuellen Completion-Aufruf melden.
#
# `completionSuggestionsRequested` unterscheidet upstream nicht, ob die Liste
# automatisch (getippter Buchstabe) oder manuell (Esc/⌃Leertaste) angefordert
# wurde. Fastras Delegate braucht das aber: Der manuelle Aufruf darf schon ab
# einem Zeichen liefern, das Tipp-Popup bleibt ab zwei Zeichen unaufdringlich.
# Der Patch meldet den manuellen Weg über eine
# Notification, unmittelbar bevor CESE die Vorschläge anfordert.
if ! grep -q 'fastra.completion.manualTrigger' "$CESE_LC" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (manueller Completion-Aufruf meldet sich)"
  # Die Meldung erst nach dem isVisible-Zweig senden. Escape zum Schließen
  # eines offenen Popups ist kein manueller Öffnungswunsch und darf den
  # Ein-Zeichen-Modus nicht aktivieren.
  /usr/bin/perl -i -0pe 's/(if SuggestionController\.shared\.isVisible \{\s*\n\s*SuggestionController\.shared\.close\(\)\s*\n\s*return event\s*\n\s*\}\n)/$1            NotificationCenter.default.post(name: Notification.Name("fastra.completion.manualTrigger"), object: self)  \/\/ Fastra-Patch: manueller Aufruf (Esc\/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n/' "$CESE_LC"
  if ! grep -q 'fastra.completion.manualTrigger' "$CESE_LC" 2>/dev/null; then
    echo "✗ FEHLER: Manual-Completion-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4b-2-Nachzug: Checkouts, die Version 1.66.0 noch an der alten Stelle gepatcht
# hat (Meldung vor dem isVisible-Zweig), auf die neue Position migrieren.
#
# Der Block oben greift nur, wenn der Marker `fastra.completion.manualTrigger`
# ganz fehlt. Ein bereits alt gepatchter Checkout enthält ihn — er wurde also
# weder migriert noch neu übersetzt und behielt das alte Fehlverhalten: Ein
# Esc, das nur ein offenes Popup schliesst, schaltete den Ein-Zeichen-Modus
# für den nächsten Request scharf. Die Migration schiebt
# genau die eine Zeile hinter den isVisible-Zweig.
if /usr/bin/python3 Patches/CodeEditSourceEditor/manual-completion-trigger-migration.py "$CESE_LC"
then
  # SPM trackt Quell-Änderungen in .build/checkouts nicht → Build-Produkte
  # verwerfen, sonst bliebe die alte Fassung einkompiliert (wie bei 4b/4c).
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
else
  # Nur Status 3 bedeutet unveränderte Quelle; Interpreter-/Dateifehler abbrechen.
  MANUAL_COMPLETION_MIGRATION_STATUS=$?
  if [ "$MANUAL_COMPLETION_MIGRATION_STATUS" -ne 3 ]; then
    exit "$MANUAL_COMPLETION_MIGRATION_STATUS"
  fi
fi

# Endkontrolle für beide Wege (frischer Patch oder Migration): Die Meldung muss
# mit ihrem Kontext hinter dem isVisible-Zweig stehen und darf davor nicht mehr
# vorkommen. Fehlt sie oder steht sie noch vorn, hat Upstream die Stelle
# umgebaut und der Fix wäre lautlos verschwunden.
if ! /usr/bin/python3 Patches/CodeEditSourceEditor/manual-completion-trigger-verification.py "$CESE_LC"
then
  echo "✗ FEHLER: Manual-Completion-Patch steht nicht an der geprüften Stelle. Build abgebrochen." >&2
  exit 1
fi

# 4c. Patch CodeEditSourceEditor — toten cursorPositions-Reconcile reparieren.
#
# In SourceEditor.updateControllerWithState steht upstream:
#     if let cursorPositions = state.cursorPositions,
#        cursorPositions != state.cursorPositions { … }
# Die Bedingung vergleicht die lokale Kopie mit sich selbst → immer false.
# Folge: setCursorPositions() läuft nur einmal in makeNSViewController (bei
# Editor-Erzeugung); ein späteres Setzen von state.cursorPositions von außen
# (genau unser Treffer-Sprung CMD+G / Listen-Klick / „Voriger/Nächster")
# bewegt die Editor-Selektion nie. Reine Unit-Tests sahen das nicht — der
# Selbsttest `-selftest jump` deckte es auf. Fix: gegen den Ist-Stand des
# Controllers vergleichen (controller.cursorPositions) und beim Anwenden in
# Sicht scrollen (scrollToVisible), damit der Sprung auch sichtbar wird.
#
# Wichtig: Das Scrollen ist ans Key-Window
# gebunden. Der Vergleich oben feuert bei jeder SwiftUI-Neubewertung erneut,
# solange State und Controller divergieren — und nach einem Treffer-Sprung
# konvergieren sie nie: Der Sprung-Pfad schreibt eine CursorPosition mit
# range == .notFound, der Coordinator verwirft die aufgelöste Rückmeldung im
# isUpdatingFromRepresentable-Fenster. Mit bedingungslosem `scrollToVisible:
# true` scrollten dadurch auch Hintergrund-Fenster spontan, sobald irgendeine
# prozessweite Einstellung (z.B. Zoom) alle EditorViews neu bewertete.
# Selektion setzen bleibt für alle Fenster; nur das Scrollen gehört dem
# aktiven Fenster. Regressionstest: `-selftest bgscroll`.
CESE_SE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditor/SourceEditor.swift"
if grep -q 'cursorPositions != state.cursorPositions' "$CESE_SE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (toten cursorPositions-Reconcile reparieren)"
  /usr/bin/perl -i -0pe 's/cursorPositions != state\.cursorPositions \{\s*\n\s*controller\.setCursorPositions\(cursorPositions\)/cursorPositions != controller.cursorPositions {  \/\/ Fastra-Patch: upstream verglich state.cursorPositions mit sich selbst (immer false) -> externer Sprung wirkte nie\n            \/\/ Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n            controller.setCursorPositions(cursorPositions, scrollToVisible: controller.textView?.window?.isKeyWindow == true)/' "$CESE_SE"
  # Verifizieren, dass der Patch gegriffen hat — sonst bleibt der Sprung tot.
  if grep -q 'cursorPositions != state.cursorPositions' "$CESE_SE" 2>/dev/null; then
    echo "✗ FEHLER: cursorPositions-Reconcile-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
# Wie bei 4b: SPM trackt Quell-Änderungen in .build/checkouts nicht →
# CESE-Build-Produkte verwerfen, damit der Patch neu übersetzt wird.
rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
      .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4c-Nachzug: Checkouts mit der alten Patchfassung (`scrollToVisible: true`
# für alle Fenster) auf die Key-Window-Fassung migrieren, ohne den Checkout
# neu aufzulösen. Der Block oben greift nur bei frischem Upstream-Text; ein
# bereits gepatchter Checkout liefe sonst mit dem alten Fehlverhalten weiter.
if grep -qF 'controller.setCursorPositions(cursorPositions, scrollToVisible: true)' "$CESE_SE" 2>/dev/null; then
  echo "→ Migriere CodeEditSourceEditor (4c: Scrollen nur noch im Key-Window)"
  /usr/bin/perl -i -0pe 's/controller\.setCursorPositions\(cursorPositions, scrollToVisible: true\)/\/\/ Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n            controller.setCursorPositions(cursorPositions, scrollToVisible: controller.textView?.window?.isKeyWindow == true)/' "$CESE_SE"
  # Selbstprüfung: Die alte Form darf nicht mehr vorkommen — sonst hat die
  # Migration nicht gegriffen und Hintergrundfenster scrollten weiter.
  if grep -qF 'controller.setCursorPositions(cursorPositions, scrollToVisible: true)' "$CESE_SE" 2>/dev/null; then
    echo "✗ FEHLER: Key-Window-Migration des cursorPositions-Patches hat NICHT gegriffen. Build abgebrochen." >&2
    exit 1
  fi
  # SPM trackt Checkout-Änderungen nicht → Modul neu übersetzen lassen.
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# Endkontrolle für beide Wege (frischer Checkout oder Migration): Die
# Key-Window-Scrollbindung muss jetzt in der Quelle stehen. Fehlt sie, hat
# Upstream die Stelle umgebaut und der Fix wäre lautlos verschwunden.
if ! grep -qF 'scrollToVisible: controller.textView?.window?.isKeyWindow == true' "$CESE_SE" 2>/dev/null; then
  echo "✗ FEHLER: Key-Window-Scrollbindung fehlt in SourceEditor.swift — Quelle hat sich geändert. Build abgebrochen." >&2
  exit 1
fi

# 4c-2. Cursorpositionen vor dem Vergleich auflösen.
# Treffer-Sprünge adressieren driftfrei über Zeile/Spalte mit `.notFound`-
# Range. Der Coordinator verwirft Rückmeldungen während
# `isUpdatingFromRepresentable`; rohe State-/Controller-Werte können daher
# ungleich bleiben und bei jedem SwiftUI-Update erneut scrollen.
# `controller.resolveCursorPosition` erkennt bereits angewandte Sprünge.
if ! grep -qF 'Vergleich ueber resolveCursorPosition' "$CESE_SE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (4c-2: Sprungvergleich über resolveCursorPosition)"
  chmod u+w "$CESE_SE"
  /usr/bin/python3 Patches/CodeEditSourceEditor/cursor-reconcile-resolution.py "$CESE_SE"
  if ! grep -qF 'Vergleich ueber resolveCursorPosition' "$CESE_SE" 2>/dev/null; then
    echo "✗ FEHLER: 4c-2-Patch (resolveCursorPosition-Vergleich) hat NICHT gegriffen. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4c-3. Der Vergleich aus 4c-2 braucht dieselbe Range wie setCursorPositions.
# Upstream addierte die 1-basierte Spalte ohne -1 und benutzte das absolute
# Zeilenende als Auswahl-Länge. Späte Treffer wurden dadurch unauflösbar;
# compactMap verglich dann [] mit [] und übersprang den Suchsprung ganz.
CESE_CURSOR="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController+Cursor.swift"
if ! grep -qF 'Zeile/Spalte als exakte UTF-16-Auswahl aufloesen' "$CESE_CURSOR" 2>/dev/null; then
  chmod u+w "$CESE_CURSOR"
  /usr/bin/python3 Patches/CodeEditSourceEditor/cursor-position-resolution.py "$CESE_CURSOR"
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi
if ! grep -qF 'Zeile/Spalte als exakte UTF-16-Auswahl aufloesen' "$CESE_CURSOR" 2>/dev/null; then
  echo "✗ FEHLER: 4c-3-Patch fehlt in TextViewController+Cursor.swift. Build abgebrochen." >&2
  exit 1
fi

# 4c1. Patch CodeEditSourceEditor — verworfene Auto-Vervollständigung sauber
#       zurücksetzen.
#
# CESE fragt nach jedem Buchstaben an. Fastra zeigt 4D-Vorschläge beim Tippen
# aber bewusst erst ab zwei Zeichen. Beim ersten Zeichen liefert der Delegate
# daher `nil`. Upstream lässt in diesem Fall `activeTextView` dennoch gesetzt;
# der zweite Buchstabe aktualisiert dann nur eine unsichtbare Liste, statt sie
# über `presentIfNot` zu öffnen. `willClose()` räumt den abgebrochenen Versuch
# auf, damit das zweite Zeichen einen neuen, sichtbaren Vorschlagsversuch
# startet. Der In-App-Test `completion4d` reproduziert genau diese Reihenfolge.
CESE_SUGGESTIONS="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/CodeSuggestion/Model/SuggestionViewModel.swift"
if ! grep -qF 'Fastra-Patch: abgebrochene Ein-Zeichen-Anfrage' "$CESE_SUGGESTIONS" 2>/dev/null; then
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

# 4b-3. CodeEditSourceEditor — Schließen der Completion melden.
# CESE deklariert `completionWindowDidClose()`, ruft es aber nicht auf.
# Fastras `windowIsOpen` bliebe dadurch dauerhaft gesetzt und erlaubte
# Auto-Vorschläge schon ab einem Zeichen. Im zentralen `willClose()` des
# Modells idempotent melden.
if ! grep -q 'Fastra-Patch: Delegate erfaehrt vom Schliessen' "$CESE_SUGGESTIONS" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (completionWindowDidClose wird gemeldet)"
  chmod u+w "$CESE_SUGGESTIONS"
  /usr/bin/perl -i -0pe 's/    func willClose\(\) \{\n        items\.removeAll\(\)/    func willClose() {\n        delegate?.completionWindowDidClose()  \/\/ Fastra-Patch: Delegate erfaehrt vom Schliessen (upstream nie aufgerufen)\n        items.removeAll()/' "$CESE_SUGGESTIONS"
  if ! grep -q 'Fastra-Patch: Delegate erfaehrt vom Schliessen' "$CESE_SUGGESTIONS" 2>/dev/null; then
    echo "✗ FEHLER: willClose-Delegate-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4d. CodeEditTextView — Drag-Selektion bis zur ersten Textspalte.
# Gutter liegt über dem linken TextView-Bereich. Auf x=0 begrenzte Punkte
# können dort ohne Glyph bleiben; `textOffsetAtPoint` liefert nil und
# `mouseDragged` beendet die Auswahl. x deshalb mindestens auf
# `layoutManager.edgeInsets.left` begrenzen, damit der Zeilenanfang erreichbar ist.
CETV_MOUSE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Mouse.swift"
if grep -q 'x: max(0.0, min(locationInWindow.x, frame.width))' "$CETV_MOUSE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Drag-Selektion über Gutter clampen)"
  /usr/bin/perl -i -pe 's/x: max\(0\.0, min\(locationInWindow\.x, frame\.width\)\),/x: max(layoutManager.edgeInsets.left, min(locationInWindow.x, frame.width)),  \/\/ Fastra-Patch: im Gutter-Bereich auf Zeilenanfang clampen statt nil (Drag friert sonst ein)/' "$CETV_MOUSE"
  # Verifizieren, dass der Patch gegriffen hat — sonst kehrt der Bug lautlos zurück.
  if grep -q 'x: max(0.0, min(locationInWindow.x, frame.width))' "$CETV_MOUSE" 2>/dev/null; then
    echo "✗ FEHLER: Gutter-Drag-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  # Wie bei 4b/4c: SPM trackt Quell-Änderungen in .build/checkouts nicht →
  # CETV-Build-Produkte verwerfen, damit der Patch neu übersetzt wird.
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
fi

# 4e. Patch CodeEditSourceEditor — horizontalen Scrollbalken + System-Scrollstil.
#
# `styleScrollView()` (TextViewController+StyleViews.swift) setzt nur
# `hasVerticalScroller = true` und erzwingt `scrollerStyle = .overlay`. Zwei
# Folgen:
#   1. `hasHorizontalScroller` wird bei der Erst-Erzeugung nie gesetzt (nur im
#      Appearance-Config-Reconcile, der initial nicht greift). Ohne Umbruch ist
#      langer Text dann gar nicht erreichbar — kein Scrollbalken (Showstopper).
#   2. Das erzwungene `.overlay` überschreibt die System-Einstellung
#      „Rollbalken: immer einblenden" → Balken bleiben unsichtbar, obwohl der
#      Nutzer dauerhaft sichtbare will.
# Fix: H-Scroller passend zum Umbruch initial setzen und `.overlay` nicht
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

# 4f. CodeEditTextView — gemessene Zeilenbreite erhalten.
# `layoutLine` überschattet den `inout maxFoundLineWidth` durch eine lokale
# Kopie. Messungen gehen beim Return verloren; `maxLineWidth` bleibt 0 und
# die TextView bietet ohne Umbruch keinen horizontalen Scrollbereich.
# Die lokale Kopie entfernen, damit direkt der inout-Wert aktualisiert wird.
# Mit Umbruch bleibt die Clip-Breite maßgeblich.
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

# 4g. CodeEditLanguages — seltene Sprachgrammatiken entfernen.
# `CodeLanguagesContainer` enthält statische Parser. Eine Referenz wie
# `tree_sitter_X()` zieht die jeweilige Objektdatei ins Binary; `return nil`
# entfernt sie und behandelt die Sprache ohne Highlighting als Plaintext.
# Ausgeschnitten: Verilog, OCaml samt Interface, Julia, Haskell, Scala,
# Agda, Elixir und Zig (zusammen etwa 50 MB). Dart bleibt enthalten.
# Das Bundle wird ausschließlich für Apple Silicon gebaut.
CEL_LANG="$CHECKOUTS/CodeEditLanguages/Sources/CodeEditLanguages/CodeLanguage.swift"
# Jede Zielstelle muss frisch oder vollständig ausgeschnitten vorliegen.
# Nur Verilog zu prüfen übersähe teilweise zurückgesetzte andere Parser.
if [ ! -f "$CEL_LANG" ] || [ ! -r "$CEL_LANG" ]; then
  echo "✗ FEHLER: CodeLanguage.swift fehlt oder ist nicht lesbar. Build abgebrochen." >&2
  exit 1
fi
CEL_GRAMMARS_FRESH=$(/usr/bin/perl -0777 -e '
  $_ = <>;
  $fresh = 0;
  for $fn (qw(agda elixir haskell julia ocaml ocaml_interface scala verilog zig)) {
    $case = $fn eq "ocaml_interface" ? "ocamlInterface" : $fn;
    $old = "return tree_sitter_${fn}()";
    $new = "return nil  // Fastra-Patch: exotische Sprache ausgeschnitten (Bundle-Groesse, Apple-Silicon-only)";
    $matches = () = /^        case \.$case:\n            (?:\Q$old\E|\Q$new\E)$/mg;
    die "Unbekannte Grammatikstelle: $case\n" unless $matches == 1;
    $fresh += () = /\Q$old\E/g;
  }
  $markers = () = /Fastra-Patch: exotische Sprache ausgeschnitten/g;
  die "Unvollstaendiger Grammatikzustand\n" unless $fresh + $markers == 9;
  print $fresh;
' "$CEL_LANG")
if [ "$CEL_GRAMMARS_FRESH" -gt 0 ]; then
  echo "→ Patche CodeEditLanguages (exotische Grammatiken ausschneiden)"
  # Nur den Rückgabe-Ausdruck ersetzen; die `case`-Labels + das Enum bleiben
  # unangetastet. Funktionsnamen sind eindeutig; `tree_sitter_ocaml()` matcht
  # dank der literalen `()` nicht das längere `tree_sitter_ocaml_interface()`.
  for fn in agda elixir haskell julia ocaml ocaml_interface scala verilog zig; do
    /usr/bin/perl -i -pe "s/return tree_sitter_${fn}\\(\\)/return nil  \\/\\/ Fastra-Patch: exotische Sprache ausgeschnitten (Bundle-Groesse, Apple-Silicon-only)/" "$CEL_LANG"
  done
fi
# Unabhängig vom Eingangszustand alle neun Rückgaben und Parserreferenzen prüfen.
# Erst nach bestätigtem Zielzustand dürfen Cacheabbau und Build folgen.
/usr/bin/perl -0777 -e '
  $_ = <>;
  for $case (qw(agda elixir haskell julia ocaml ocamlInterface scala verilog zig)) {
    $matches = () = /^        case \.$case:\n            return nil  \/\/ Fastra-Patch: exotische Sprache ausgeschnitten \(Bundle-Groesse, Apple-Silicon-only\)$/mg;
    die "Grammatik nicht ausgeschnitten: $case\n" unless $matches == 1;
  }
  die "Zielparser noch referenziert\n" if /tree_sitter_(?:agda|elixir|haskell|julia|ocaml|ocaml_interface|scala|verilog|zig)\s*\(/;
' "$CEL_LANG"
if [ "$CEL_GRAMMARS_FRESH" -gt 0 ]; then
  # Wie 4b–4f: SPM trackt Quell-Änderungen in .build/checkouts nicht →
  # CodeEditLanguages-Build-Produkte verwerfen, damit CodeLanguage.swift neu
  # übersetzt und das Fastra-Binary neu gelinkt wird (nur beim Relink fallen
  # die nun unreferenzierten Grammatik-.o aus dem statischen Archiv weg).
  rm -rf .build/*/debug/CodeEditLanguages.build .build/*/release/CodeEditLanguages.build
  rm -f .build/*/debug/Modules/CodeEditLanguages.swiftmodule \
        .build/*/release/Modules/CodeEditLanguages.swiftmodule
fi

# 4h. CodeEditLanguages — Highlight-Query-Pfad auflösen.
# `Bundle.module.resourceURL` kann bereits auf `…bundle/Resources` zeigen.
# Ein nochmals angehängtes `Resources/` erzeugt dann einen ungültigen Pfad;
# TreeSitterClient erkennt die Sprache, färbt aber ohne Queries nichts ein.
# Beide Bundle-Layouts prüfen und den vorhandenen Query-Pfad verwenden.
# Der `highlight`-Selbsttest prüft echte Farben.
if ! grep -q 'Fastra-Patch: Query-Pfad layout-robust' "$CEL_LANG" 2>/dev/null; then
  echo "→ Patche CodeEditLanguages (Highlight-Query-Pfad layout-robust)"
  # SPM legt Checkout-Dateien read-only ab (444). perl -i (4b–4g) umgeht das
  # durch unlink+neu; Python schreibt in-place → Schreibrecht kurz geben.
  chmod u+w "$CEL_LANG"
  /usr/bin/python3 Patches/CodeEditLanguages/highlight-query-layout.py "$CEL_LANG"
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

# 4i. CodeEditTextView — überlappende Umbruchfragmente vermeiden.
# `CTTypesetter+SuggestLineBreak` liefert den absoluten Endindex im Content-
# Run. Als CFRange-Länge verwendet überlappt er ab dem zweiten Fragment den
# Folgetext. Die Länge als Endindex minus Startindex berechnen.
# Marker hält den Patch idempotent; CETV-Produkte des alten Buildsystems
# verwerfen, damit der geänderte Checkout neu übersetzt wird.
# Regression: `ghosttext`.
CETV_TYPESETTER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/Typesetter.swift"
if ! grep -q 'Fastra-Patch: Break-Endindex in Fragmentlaenge umrechnen' "$CETV_TYPESETTER" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (überlappende Umbruch-Fragmente → Text-Geist-Fix)"
  chmod u+w "$CETV_TYPESETTER"
  /usr/bin/python3 Patches/CodeEditTextView/wrap-fragment-length.py "$CETV_TYPESETTER"
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
if grep -q 'Fastra-Patch: portables CodeEditSymbols-Ressourcenbundle' "$CESYM_SRC" 2>/dev/null; then
  /usr/bin/python3 Patches/CodeEditSymbols/portable-resource-bundle.py --check "$CESYM_SRC"
else
  echo "→ Patche CodeEditSymbols (portables Ressourcenbundle)"
  chmod u+w "$CESYM_SRC"
  /usr/bin/python3 Patches/CodeEditSymbols/portable-resource-bundle.py "$CESYM_SRC"
  rm -rf .build/*/debug/CodeEditSymbols.build .build/*/release/CodeEditSymbols.build
  rm -f .build/*/debug/Modules/CodeEditSymbols.swiftmodule \
        .build/*/release/Modules/CodeEditSymbols.swiftmodule
fi

# 4k. CodeEditLanguages — gleicher portabler Ressourcenpfad für Queries.
if ! grep -q 'Fastra-Patch: portables CodeEditLanguages-Ressourcenbundle' "$CEL_LANG" 2>/dev/null; then
  echo "→ Patche CodeEditLanguages (portables Ressourcenbundle)"
  chmod u+w "$CEL_LANG"
  /usr/bin/python3 Patches/CodeEditLanguages/portable-resource-bundle.py "$CEL_LANG"
  if ! grep -q 'Fastra-Patch: portables CodeEditLanguages-Ressourcenbundle' "$CEL_LANG" 2>/dev/null; then
    echo "✗ FEHLER: CodeEditLanguages-Ressourcenbundle-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditLanguages.build .build/*/release/CodeEditLanguages.build
  rm -f .build/*/debug/Modules/CodeEditLanguages.swiftmodule \
        .build/*/release/Modules/CodeEditLanguages.swiftmodule
fi

# 4l. Patch CodeEditSourceEditor — Theme-Slots für 4D entkoppeln.
# EditorTheme.mapCapture wirft upstream viele Capture-Klassen in dieselben
# Farb-Slots (function/method/property → variables, variableBuiltin → keywords);
# die Theme-Felder `commands`, `values` und `characters` sind dagegen komplett
# ungenutzt. Für die 4D-Farbkategorien (Befehle, Konstanten, Prozessvariablen)
# leiten wir drei Capture-Klassen auf diese freien Slots um. Die
# Fastra-Standardthemes setzen die vier Slots exakt auf die Farben ihrer
# bisherigen Sammel-Slots → alle bestehenden Sprachen sehen unverändert aus; nur
# die 4D-Themes nutzen die neuen Slots mit eigenen Farben. Der Methoden-Slot
# erhält einen optionalen Default auf `commands`, damit fremde Themes beim
# API-Zuwachs unverändert bleiben.
CESE_THEME="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Theme/EditorTheme.swift"
if ! grep -q 'Fastra-Patch: eigene Slots fuer 4D-Kategorien' "$CESE_THEME" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Theme-Slots für 4D entkoppeln)"
  chmod u+w "$CESE_THEME"
  /usr/bin/python3 Patches/CodeEditSourceEditor/theme-four-d-categories.py "$CESE_THEME"
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
  /usr/bin/python3 Patches/CodeEditSourceEditor/theme-four-d-methods.py "$CESE_THEME"
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

# 4m2. Patch CodeEditSourceEditor — eigener Component-Methoden-Slot für 4D.
#
# Die vorhandenen `.function`- und `.method`-Captures sind bereits für normale
# Befehle beziehungsweise Projektmethoden belegt. Ein eigener Capture-Name
# verhindert, dass Component-Methoden nach der Typeahead-Übernahme wieder in
# den Befehls-Slot fallen. Der neue Theme-Parameter bleibt optional und erbt
# standardmäßig `commands`: Fremdthemes und alle vorhandenen Sprachen behalten
# damit ohne Quelländerung exakt ihre bisherige Darstellung.
CESE_CAPTURE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Enums/CaptureName.swift"
if ! grep -q 'Fastra-Patch: eigener Component-Methoden-Slot fuer 4D' "$CESE_THEME" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (eigener Component-Methoden-Slot für 4D)"
  chmod u+w "$CESE_THEME" "$CESE_CAPTURE"
  /usr/bin/python3 Patches/CodeEditSourceEditor/theme-four-d-component-methods.py "$CESE_THEME" "$CESE_CAPTURE"
  if ! grep -q 'Fastra-Patch: eigener Component-Methoden-Slot fuer 4D' "$CESE_THEME" \
     || ! grep -q 'case .componentMethod: return componentMethods' "$CESE_THEME" \
     || ! grep -q 'case componentMethod' "$CESE_CAPTURE"; then
    echo "✗ FEHLER: Component-Methoden-Slot-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
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
  /usr/bin/python3 Patches/CodeEditSourceEditor/fixed-soft-wrap-columns.py "$CETV_MANAGER" "$CETV_BREAK" "$CESE_BEHAVIOR" \
    "$CESE_APPEARANCE" "$CESE_CONTROLLER" "$CESE_GUIDE"
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
CETV_SELECT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Select.swift"
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
   || ! grep -q 'Fastra-Patch: Plain-Text-Copy' "$CETV_COPY_PASTE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Rechteck-Paste' "$CETV_COPY_PASTE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Rechteck-Delete' "$CETV_DELETE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche' "$CETV_REPLACE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: kein Scrollen waehrend gebuendeltem Undo/Redo' "$CETV_REPLACE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Doppelklick auf Symbole' "$CETV_SELECT" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: einzelnes Symbol' "$CETV_SELECT" 2>/dev/null \
   || ! grep -q 'fastraColumnSelectionTabWidth = tabWidth' "$CESE_APPEARANCE" 2>/dev/null \
   || ! grep -q 'fastraColumnIndentationUnit' "$CESE_BEHAVIOR" 2>/dev/null; then
  echo "→ Verdrahte Rechteckauswahl mit Copy/Paste, Undo und Editorprofil"
  chmod u+w "$CETV_COPY_PASTE" "$CETV_DELETE" "$CETV_REPLACE" "$CETV_SELECT" \
    "$CESE_APPEARANCE" "$CESE_BEHAVIOR"
  /usr/bin/python3 Patches/CodeEditTextView/logical-column-selection-integration.py "$CETV_COPY_PASTE" "$CETV_DELETE" "$CETV_REPLACE" "$CETV_SELECT" \
    "$CESE_APPEARANCE" "$CESE_BEHAVIOR"
  COLUMN_PATCH_CHANGED=1
fi

if ! grep -q 'FastraColumnSelectionSnapshot' "$CETV_COLUMN" \
   || ! grep -q 'Fastra-Patch: Rechteck-Copy' "$CETV_COPY_PASTE" \
   || ! grep -q 'Fastra-Patch: Rechteck-Paste' "$CETV_COPY_PASTE" \
   || ! grep -q 'Fastra-Patch: Rechteck-Delete' "$CETV_DELETE" \
   || ! grep -q 'Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche' "$CETV_REPLACE" \
   || ! grep -q 'Fastra-Patch: kein Scrollen waehrend gebuendeltem Undo/Redo' "$CETV_REPLACE" \
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
  /usr/bin/python3 Patches/CodeEditTextView/final-newline-selection.py "$CETV_SELECTION_FILL"
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

# 4q. CodeEditTextView — Auswahlzustand für große Textoperationen sichern.
#
# CodeEditTextViews Undo-Manager leitet die Auswahl nach einer Ersetzung allein
# aus der Mutationsrange ab. Ersetzt eine Fastra-Textoperation einen großen
# Bereich, markiert Undo deshalb den gesamten alten Text. Außerdem springt die
# Auswahl nach der Operation zunächst ans Ende einer möglicherweise extrem
# langen Soft-Wrap-Zeile. Eine kleine Opt-in-API erlaubt Fastra, für genau diese
# Operationen die sinnvollen Auswahlzustände vor/nach der Mutation zu hinterlegen.
CETV_UNDO="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/Utils/CEUndoManager.swift"
TEXT_OPERATION_UNDO_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Auswahlzustand grosser Textoperationen' \
    "$CETV_UNDO" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Auswahl bei Textoperation/Undo)"
  chmod u+w "$CETV_UNDO"
  /usr/bin/python3 Patches/CodeEditTextView/undo-operation-selections.py "$CETV_UNDO"
  TEXT_OPERATION_UNDO_PATCH_CHANGED=1
fi

# Bestehende Checkouts können bereits die erste 4q-Fassung ohne das
# abschließende Layout-Rebuild enthalten. Frische Checkouts erhalten beide
# Teile oben in einem Schritt; dieser Zweig migriert nur den lokalen Zwischenstand.
if ! grep -q 'Fastra-Patch: Layout nach grosser Textoperation' \
    "$CETV_UNDO" 2>/dev/null; then
  echo "→ Ergänze CodeEditTextView-Patch (Layout nach Textoperation/Undo)"
  chmod u+w "$CETV_UNDO"
  /usr/bin/python3 Patches/CodeEditTextView/undo-operation-scroll.py "$CETV_UNDO"
  TEXT_OPERATION_UNDO_PATCH_CHANGED=1
fi

# Bilddateien, die zusammen mit einem Markdown-Link entstanden sind, gehören
# an exakt dieselbe Undo-Gruppe. Globale NSUndoManager-Beobachter können bei
# gleichen Linktexten nicht unterscheiden, welche Einfügung gemeint war, und
# bleiben außerdem über die Lebenszeit verworfener Redo-Zweige hängen.
if ! grep -q 'Fastra-Patch: dateibezogene Nebenwirkungen' \
    "$CETV_UNDO" 2>/dev/null; then
  echo "→ Ergänze CodeEditTextView-Patch (Nebenwirkungen je Undo-Gruppe)"
  chmod u+w "$CETV_UNDO"
  /usr/bin/python3 Patches/CodeEditTextView/undo-operation-finalization.py "$CETV_UNDO"
  TEXT_OPERATION_UNDO_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Auswahlzustand grosser Textoperationen' \
    "$CETV_UNDO" \
   || ! grep -q 'Fastra-Patch: Layout nach grosser Textoperation' \
    "$CETV_UNDO" \
   || ! grep -q 'Fastra-Patch: dateibezogene Nebenwirkungen' \
    "$CETV_UNDO"; then
  echo "✗ FEHLER: Textoperations-Undo-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$TEXT_OPERATION_UNDO_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4r. CodeEditTextView — bewegte Kante einer Tastaturauswahl sichtbar halten.
#
# `scrollSelectionToVisible()` scrollt upstream auf das berechnete Bounding-Rect
# der Auswahl. Dessen Fill-Rects sind auf den sichtbaren Textbereich begrenzt;
# sobald Shift+Pfeil die bewegte Kante aus dem Viewport schiebt, beschreibt das
# Scrollziel daher weiter den sichtbaren oberen Ausschnitt statt der aktiven
# Kante. CodeEdit besitzt bereits `offsetNotPivot`, nutzt den Helfer dort aber
# nicht. Fastra scrollt auf das kleine Zeichenrechteck der aktiven, vom Pivot
# entfernten Auswahlkante. In langen Soft-Wrap-Dokumenten kann dieses Rechteck
# zunächst noch auf geschätzten Zeilenhöhen beruhen. Ein zweiter Abgleich im
# folgenden Main-Runloop scrollt nach dem faulen Layout auf die echte Position.
# Cursorbewegungen ohne Auswahl behalten damit dasselbe Verhalten.
CETV_SCROLL_SELECTION="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+ScrollToVisible.swift"
CETV_MOVE_SELECTION="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Move.swift"
SELECTION_SCROLL_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: bewegte Auswahlkante statt Gesamtauswahl' \
    "$CETV_SCROLL_SELECTION" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Shift-Auswahl scrollt mit)"
  chmod u+w "$CETV_SCROLL_SELECTION"
  /usr/bin/python3 Patches/CodeEditTextView/selection-active-edge.py "$CETV_SCROLL_SELECTION"
  SELECTION_SCROLL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Pixelreserve fuer die aktive Auswahlkante' \
    "$CETV_SCROLL_SELECTION" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Shift-Auswahl vollständig sichtbar)"
  chmod u+w "$CETV_SCROLL_SELECTION"
  /usr/bin/python3 Patches/CodeEditTextView/selection-scroll-padding.py "$CETV_SCROLL_SELECTION"
  SELECTION_SCROLL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: verzoegerter Scroll-Abgleich fuer Auswahlen' \
    "$CETV_MOVE_SELECTION" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Shift-Auswahl nach Layout nachführen)"
  chmod u+w "$CETV_MOVE_SELECTION"
  /usr/bin/python3 Patches/CodeEditTextView/selection-scroll-reconcile.py "$CETV_MOVE_SELECTION"
  SELECTION_SCROLL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: bewegte Auswahlkante statt Gesamtauswahl' \
    "$CETV_SCROLL_SELECTION" \
  || ! grep -q 'Fastra-Patch: Pixelreserve fuer die aktive Auswahlkante' \
    "$CETV_SCROLL_SELECTION" \
  || ! grep -q 'Fastra-Patch: verzoegerter Scroll-Abgleich fuer Auswahlen' \
    "$CETV_MOVE_SELECTION"; then
  echo "✗ FEHLER: Tastaturauswahl-Scroll-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$SELECTION_SCROLL_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4s. CodeEditTextView — Layout nach Texteinfuegungen fuer den neuen Bereich
# invalidieren.
#
# `didProcessEditing` berechnet aus `editedRange` und `delta` korrekt den
# vorher ersetzten Bereich. Upstream verwendet diesen Bereich aber nicht nur
# zum Entfernen alter Zeilen, sondern auch nach dem Einfuegen zur Layout-
# Invalidierung. Bei einer reinen Einfuegung ist er leer; an Zeilen- und
# Fragmentgrenzen kann dadurch eine andere Zeile getroffen werden. Die
# logische Zeilenlaenge ist dann neu, ihre alten Soft-Wrap-Fragmente bleiben
# aber bestehen: Der angehaengte Text wird gezeichnet, besitzt jedoch keine
# Trefferflaeche. Entfernen arbeitet weiter mit dem alten Bereich, nach dem
# Aufbau wird dagegen der von NSTextStorage gelieferte neue Bereich
# invalidiert. Bei Loeschungen bleibt `editedRange` leer; CodeEdits bestehender
# Leerbereichspfad markiert die Zeile am Editierpunkt bzw. die letzte Zeile.
CETV_EDITS="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Edits.swift"
TEXT_EDIT_LAYOUT_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: neuen Editierbereich invalidieren' \
    "$CETV_EDITS" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Text-Einfügung invalidiert neue Fragmente)"
  chmod u+w "$CETV_EDITS"
  /usr/bin/python3 Patches/CodeEditTextView/post-edit-layout-range.py "$CETV_EDITS"
  TEXT_EDIT_LAYOUT_PATCH_CHANGED=1
fi

if ! grep -q 'let replacedStringRange = NSRange' "$CETV_EDITS" \
  || ! grep -q 'invalidateLayoutForRange(editedRange)' "$CETV_EDITS" \
  || ! grep -q 'Fastra-Patch: neuen Editierbereich invalidieren' "$CETV_EDITS"; then
  echo "✗ FEHLER: Text-Einfügungs-Layout-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$TEXT_EDIT_LAYOUT_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4t. CodeEditSourceEditor — ausgeblendete Minimap darf keine Klicks schlucken.
#
# `MinimapView.hitTest` prüft `isHidden` nicht und beantwortet Treffer im
# eigenen sichtbaren Bereich immer selbst; `mouseDown`/`mouseDragged` sind
# bewusst leere Überschreibungen („Eat mouse events“). AppKits Default-hitTest
# würde eine verborgene View selbst aussortieren — genau dieser Default ist
# hier aber überschrieben. Folge: Bei ausgeblendeter
# Minimap (Fastra-Default) liegt eine unsichtbare, ~90 pt breite Fläche über
# der rechten Editorkante. Klicks und Doppelklicks auf Text in diesem Band
# kommen nie im Editor an — besonders auffällig im Markdown-Split, wo der
# Editor schmal ist und umbrochene Zeilen bis an den Scrollbalken reichen.
CESE_MINIMAP="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Minimap/MinimapView.swift"
MINIMAP_HITTEST_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: verborgene Minimap darf keine Klicks schlucken' \
    "$CESE_MINIMAP" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (verborgene Minimap schluckt keine Klicks)"
  chmod u+w "$CESE_MINIMAP"
  /usr/bin/python3 Patches/CodeEditSourceEditor/hidden-minimap-hit-test.py "$CESE_MINIMAP"
  MINIMAP_HITTEST_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: verborgene Minimap darf keine Klicks schlucken' \
    "$CESE_MINIMAP"; then
  echo "✗ FEHLER: Minimap-hitTest-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$MINIMAP_HITTEST_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4t-2. CodeEditTextView — setSelectedRange weist ungültige Bereiche ab.
#
# `setSelectedRanges` (Plural) filtert ungültige Bereiche bereits heraus,
# `setSelectedRange` (Singular) übernahm sie ungeprüft. Ein {NSNotFound, 0}
# aus veraltetem SwiftUI-State wanderte so in die Selektion; der
# Attachment-Beobachter baut daraus ein IndexSet und trappt
# (`IndexSet.insert(range:)` mit NSNotFound — zweimal beobachtet, Roadmap
# „Bekannte Fehler"). Der Patch weist ungültige Bereiche ab und behält die
# bestehende Auswahl.
CETV_SELMGR="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager.swift"
SELRANGE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: ungueltigen Bereich abweisen' "$CETV_SELMGR" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (setSelectedRange weist ungültige Bereiche ab)"
  chmod u+w "$CETV_SELMGR"
  /usr/bin/python3 Patches/CodeEditTextView/selection-range-validation.py "$CETV_SELMGR"
  SELRANGE_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: ungueltigen Bereich abweisen' "$CETV_SELMGR"; then
  echo "✗ FEHLER: setSelectedRange-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$SELRANGE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
fi

# 4u. CodeEditTextView — Doppelklick-Wortauswahl zellenbasiert wie NSTextView.
#
# `textOffsetAtPoint` rundet wie eine Einfüge-Position: Ein Klick auf die
# rechte Hälfte eines Zeichens liefert den Offset danach. Für den einfachen
# Klick ist das korrektes Caret-Verhalten. Beim Doppelklick führt es aber
# dazu, dass ein Klick auf die rechte Hälfte des letzten Zeichens eines
# Wortes das Leerzeichen dahinter markiert statt des Wortes. NSTextView und
# BBEdit wählen das Wort über die tatsächlich getroffene Zeichenzelle. Der
# Patch rückt die Auswahlbasis vor `selectWord` auf das Zeichen, dessen
# Zelle den Klickpunkt wirklich enthält.
CETV_MOUSE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Mouse.swift"
DOUBLECLICK_CELL_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle (zusammengesetzt)' \
    "$CETV_MOUSE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Doppelklick-Wortauswahl zellenbasiert, zusammengesetzt)"
  chmod u+w "$CETV_MOUSE"
  /usr/bin/python3 Patches/CodeEditTextView/mouse-double-click-cell.py "$CETV_MOUSE"
  DOUBLECLICK_CELL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle (zusammengesetzt)' \
    "$CETV_MOUSE"; then
  echo "✗ FEHLER: Doppelklick-Zellen-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$DOUBLECLICK_CELL_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4v. CodeEditTextView — Drag-Anker beim Mouse-down setzen.
# Das erste Drag-Event kann bei schnellen Bewegungen schon weit vom Klickpunkt
# liegen. Erst dort gesetzter `mouseDragAnchor` würde die Auswahl am falschen
# Zeichen beginnen lassen.
CETV_MOUSE_ANCHOR="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Mouse.swift"
DRAG_ANCHOR_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Drag-Anker am Maus-Down verankern' \
    "$CETV_MOUSE_ANCHOR" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Drag-Anker am Maus-Down)"
  chmod u+w "$CETV_MOUSE_ANCHOR"
  /usr/bin/python3 Patches/CodeEditTextView/mouse-down-drag-anchor.py "$CETV_MOUSE_ANCHOR"
  DRAG_ANCHOR_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Drag-Anker am Maus-Down verankern' \
    "$CETV_MOUSE_ANCHOR"; then
  echo "✗ FEHLER: Drag-Anker-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$DRAG_ANCHOR_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4w. CodeEditTextView — rectForOffset bei veraltetem Zeilen-Storage schützen.
# Während Undo/Redo kann Zeilen-Storage länger sein als der bereits verkürzte
# Text. Ein reentranter Scroll darf `rangeOfComposedCharacterSequence` dann
# nicht hinter dem echten Textende aufrufen. Ungültige Offsets liefern ein
# nullbreites Rechteck statt einer NSRangeException.
# Regression: `TextLayoutManagerStaleOffsetTests`.
CETV_RECT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Public.swift"
RECT_STALE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Offset gegen den ECHTEN Storage clampen' \
    "$CETV_RECT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (rectForOffset crash-fest bei Undo-Fenster)"
  chmod u+w "$CETV_RECT"
  /usr/bin/python3 Patches/CodeEditTextView/stale-offset-rect.py "$CETV_RECT"
  RECT_STALE_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Offset gegen den ECHTEN Storage clampen' "$CETV_RECT"; then
  echo "✗ FEHLER: rectForOffset-Crash-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$RECT_STALE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4x. CodeEditSourceEditor — Scroll-Reconcile des SwiftUI-State deaktivieren.
# Der Coordinator schreibt die Position erst im nächsten RunLoop zurück.
# Ein paralleles SwiftUI-Update könnte `state.scrollPosition` daher über einen
# frischen Tipp-Scroll zurückschreiben. Fastra setzt kein externes Scrollziel
# über diesen State; Treffer-Sprünge laufen über `convergeScroll`.
CESE_SOURCE_EDITOR="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditor/SourceEditor.swift"
SCROLL_RECONCILE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Scroll-Reconcile deaktiviert' \
    "$CESE_SOURCE_EDITOR" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Scroll-Reconcile des States aus)"
  chmod u+w "$CESE_SOURCE_EDITOR"
  /usr/bin/python3 Patches/CodeEditSourceEditor/disable-scroll-state-reconcile.py "$CESE_SOURCE_EDITOR"
  SCROLL_RECONCILE_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Scroll-Reconcile deaktiviert' "$CESE_SOURCE_EDITOR"; then
  echo "✗ FEHLER: Scroll-Reconcile-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$SCROLL_RECONCILE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4y. CodeEditTextView/SourceEditor — aktuelle Zeile auch bei Auswahl.
#
# Upstream zeichnet den Zeilenhintergrund nur fuer leere Cursor-Ranges. Sobald
# ein Suchtreffer oder normaler Text selektiert ist, verschwindet deshalb die
# wichtigste Orientierung. Bei mehrzeiliger oder rechteckiger Auswahl duerfen
# aber nicht alle Teil-Ranges eine ganze Zeile faerben: genau die aktive Range
# liefert eine Zeile, alle Auswahlrechtecke bleiben zusaetzlich sichtbar.
# Regressionstest: SoftWrapLayoutTests.selectedRangesKeepOneCurrentLine und
# SoftWrapLayoutTests.backwardColumnSelectionHighlightsHeadLine.
CETV_SELECTION_DRAW="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager+Draw.swift"
CESE_GUTTER="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Gutter/GutterView.swift"
CURRENT_LINE_SELECTION_PATCH_CHANGED=0
# Zwei Marker: der erste zeigt, dass ueberhaupt gepatcht wurde, der zweite,
# dass es die aktuelle Fassung ist. Ein Checkout mit der alten Fassung wird
# zuerst aus Git zurueckgesetzt — sonst faende der Patch seinen Ankertext
# nicht mehr und der Build braeche mit einer irrefuehrenden Meldung ab.
if ! grep -q 'Fastra-Patch: aktuelle Zeile bleibt auch bei Textauswahl sichtbar' \
    "$CETV_SELECTION_DRAW" 2>/dev/null \
   || ! grep -q 'fastraColumnSelectionHeadOffset' "$CETV_SELECTION_DRAW" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (aktuelle Zeile auch bei Auswahl)"
  chmod u+w "$CETV_SELECTION_DRAW"
  if grep -q 'Fastra-Patch: aktuelle Zeile bleibt auch bei Textauswahl sichtbar' \
      "$CETV_SELECTION_DRAW" 2>/dev/null; then
    echo "  (aeltere Patchfassung gefunden — Datei wird zuerst zurueckgesetzt)"
    git -C "$CHECKOUTS/CodeEditTextView" checkout -- \
      Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager+Draw.swift
    chmod u+w "$CETV_SELECTION_DRAW"
  fi
  /usr/bin/python3 Patches/CodeEditTextView/current-line-selection-highlights.py "$CETV_SELECTION_DRAW"
  CURRENT_LINE_SELECTION_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Gutter folgt derselben aktiven Auswahlzeile' \
    "$CESE_GUTTER" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Gutter-Zeile auch bei Auswahl)"
  chmod u+w "$CESE_GUTTER"
  /usr/bin/python3 Patches/CodeEditSourceEditor/current-line-gutter-highlight.py "$CESE_GUTTER"
  CURRENT_LINE_SELECTION_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: aktuelle Zeile bleibt auch bei Textauswahl sichtbar' \
       "$CETV_SELECTION_DRAW" \
   || ! grep -q 'public var fastraHighlightedLineOffsets' "$CETV_SELECTION_DRAW" \
   || ! grep -q 'fastraColumnSelectionHeadOffset' "$CETV_SELECTION_DRAW" \
   || ! grep -q 'Fastra-Patch: Gutter folgt derselben aktiven Auswahlzeile' \
       "$CESE_GUTTER"; then
  echo "✗ FEHLER: Patch für aktuelle Zeile bei Auswahl hat NICHT vollständig gegriffen." >&2
  exit 1
fi

if [ "$CURRENT_LINE_SELECTION_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z. CodeEditTextView — TextLine.prepareForDisplay bei veralteter Range schützen.
# Reentrantes Layout während Undo kann eine zu lange lineStorage-Range an
# `attributedSubstring(from:)` übergeben. Gegen den tatsächlichen Text klemmen.
# Bleibt nichts übrig, ohne Typeset zurückkehren und neues Layout anfordern;
# der nächste Lauf verwendet aktualisierten lineStorage.
# Regression: `TextLinePrepareForDisplayClampTests`.
CETV_TEXTLINE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/TextLine.swift"
TEXTLINE_CLAMP_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Zeilen-Range gegen das aktuelle Textende clampen' \
    "$CETV_TEXTLINE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (prepareForDisplay crash-fest bei Undo-Fenster)"
  chmod u+w "$CETV_TEXTLINE"
  /usr/bin/python3 Patches/CodeEditTextView/stale-text-line-display-range.py "$CETV_TEXTLINE"
  TEXTLINE_CLAMP_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Zeilen-Range gegen das aktuelle Textende clampen' "$CETV_TEXTLINE"; then
  echo "✗ FEHLER: prepareForDisplay-Clamp-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$TEXTLINE_CLAMP_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z1. CodeEditTextView — inkonsistentes Layout überspringen.
# `transactionCounter` wird im Paket nicht erhöht; `isInTransaction` bleibt
# false und schützt den Zwischenstand nicht. Stattdessen lineStorage.length
# mit textStorage.length vergleichen und bei Abweichung auf den nächsten
# Layout-Durchlauf mit aktualisiertem Storage warten.
CETV_LAYOUT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Layout.swift"
LAYOUT_CONSISTENCY_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: toter Transaktionsschutz durch Laengenvergleich ersetzt' \
    "$CETV_LAYOUT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (layoutLines: Konsistenz-Ausstieg statt totem Transaktionsschutz)"
  chmod u+w "$CETV_LAYOUT"
  /usr/bin/python3 Patches/CodeEditTextView/inconsistent-line-layout.py "$CETV_LAYOUT"
  LAYOUT_CONSISTENCY_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: toter Transaktionsschutz durch Laengenvergleich ersetzt' "$CETV_LAYOUT"; then
  echo "✗ FEHLER: layoutLines-Konsistenz-Patch hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$LAYOUT_CONSISTENCY_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z2. CodeEditSourceEditor — Fließtext nicht wie Klammer-Code einrücken.
#
# TextFormations allgemeine Grundmuster behandeln jede Zeile, die mit `(`
# beginnt, wie einen geöffneten Codeblock. Nach einer bewusst geleerten Zeile
# sucht der Standard-Indenter zusätzlich rückwärts weiter und übernimmt den
# alten Treffer erneut. In reinem Text und Markdown gelten diese Klammermuster
# nicht; erhalten bleibt nur die Einrückung der unmittelbaren Vorzeile.
# Regression: gepackter Selbsttest `mdindent` mit dem Größen-/Formabbild der
# gemeldeten Desktop-Datei.
CESE_TEXT_FORMATION="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController+TextFormation.swift"
MARKDOWN_INDENT_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Markdown verwendet keine Code-Klammermuster' \
    "$CESE_TEXT_FORMATION" 2>/dev/null \
   || ! grep -q 'case .plainText, .markdown:' "$CESE_TEXT_FORMATION" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Fließtext ohne Code-Klammermuster)"
  chmod u+w "$CESE_TEXT_FORMATION"
  if grep -q 'Fastra-Patch: Markdown verwendet keine Code-Klammermuster' \
      "$CESE_TEXT_FORMATION" 2>/dev/null; then
    echo "  (ältere Patchfassung gefunden — Datei wird zuerst zurückgesetzt)"
    git -C "$CHECKOUTS/CodeEditSourceEditor" checkout -- \
      Sources/CodeEditSourceEditor/Controller/TextViewController+TextFormation.swift
    chmod u+w "$CESE_TEXT_FORMATION"
  fi
  /usr/bin/python3 Patches/CodeEditSourceEditor/prose-indentation.py "$CESE_TEXT_FORMATION"
  MARKDOWN_INDENT_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: Markdown verwendet keine Code-Klammermuster' \
    "$CESE_TEXT_FORMATION" \
   || ! grep -q 'case .plainText, .markdown:' "$CESE_TEXT_FORMATION"; then
  echo "✗ FEHLER: Fließtext-Einrückungs-Patch hat NICHT gegriffen." >&2
  exit 1
fi
if [ "$MARKDOWN_INDENT_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z3. CodeEditTextView — externer Bild-Drop mit sichtbarer Einfügemarke.
#
# SwiftUIs onDrop liefert keine Dokumentposition. Die TextView ist daher
# selbst Drag-Ziel: Sie zeichnet den Cursor an der Mausposition, scrollt bei
# stillstehender Maus am oberen/unteren Rand weiter und übergibt den exakten
# Offset erst beim Loslassen an Fastra. CodeEdits eigener Text-Drag bleibt
# für alle nicht von Fastra akzeptierten Pasteboards unverändert.
CETV_EXTERNAL_DROP_SOURCE="Patches/CodeEditTextView/TextView+FastraExternalDrop.swift"
CETV_EXTERNAL_DROP_TARGET="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+FastraExternalDrop.swift"
CETV_DRAG="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Drag.swift"
EXTERNAL_DROP_PATCH_CHANGED=0
if [ ! -f "$CETV_EXTERNAL_DROP_SOURCE" ]; then
  echo "✗ FEHLER: externer Drop-Patch fehlt: $CETV_EXTERNAL_DROP_SOURCE" >&2
  exit 1
fi
if ! cmp -s "$CETV_EXTERNAL_DROP_SOURCE" "$CETV_EXTERNAL_DROP_TARGET"; then
  echo "→ Ergänze CodeEditTextView (externer Drop-Cursor + Autoscroll)"
  cp "$CETV_EXTERNAL_DROP_SOURCE" "$CETV_EXTERNAL_DROP_TARGET"
  EXTERNAL_DROP_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: externer Drop wird vor dem Standard-Textdrag geroutet' \
    "$CETV_DRAG" 2>/dev/null; then
  chmod u+w "$CETV_DRAG"
  /usr/bin/python3 Patches/CodeEditTextView/external-image-drop-routing.py "$CETV_DRAG"
  EXTERNAL_DROP_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: externer Drop wird vor dem Standard-Textdrag geroutet' "$CETV_DRAG" \
   || ! grep -q 'public func fastraConfigureExternalDrop' "$CETV_EXTERNAL_DROP_TARGET" \
   || ! grep -q 'fastraExternalAutoscrollStep' "$CETV_EXTERNAL_DROP_TARGET"; then
  echo "✗ FEHLER: externer Drop-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi
if [ "$EXTERNAL_DROP_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z4. CodeEditTextView — sichtbarer Text ist auch horizontal begrenzt.
#
# Upstream liefert bei einer einzigen sehr langen logischen Zeile die komplette
# Zeile als `visibleTextRange` — auch ohne Soft Wrap, obwohl horizontal nur ein
# kleiner Ausschnitt sichtbar ist. CodeEditSourceEditor plant daraufhin fuer
# jedes Zeichen Highlight-Auftraege. Der Patch ermittelt Anfang und Ende ueber
# echte Viewport-Punkte. Das eigentliche Langzeilen-Layout wird unten durch
# virtuelle Fragment-Views auch mit eingeschaltetem Soft Wrap begrenzt.
# Regression: `LongLineEditorPerformanceTests` prueft die echte Range.
CETV_TEXT_VIEW_LAYOUT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Layout.swift"
CETV_LAYOUT_MANAGER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager.swift"
CETV_TYPESETTER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/Typesetter.swift"
CETV_FRAGMENT_RENDERER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/LineFragmentRenderer.swift"
CESE_VISIBLE_RANGE_PROVIDER="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Highlighting/VisibleRangeProvider.swift"
CESE_HIGHLIGHTER="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Highlighting/Highlighter.swift"
CESE_LIFECYCLE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController+Lifecycle.swift"
CESE_LONG_LINE_APPEARANCE="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditorConfiguration/SourceEditorConfiguration+Appearance.swift"
LONG_LINE_LAYOUT_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: mehrere sichtbare Textbereiche pro Viewport' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: vor dem Einhaengen in eine ScrollView' \
    "$CETV_LAYOUT_MANAGER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: ungebrochene Megazeilen in handliche CoreText-' \
    "$CETV_TYPESETTER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: interne Segmente ungebrochener Megazeilen nur' \
    "$CETV_FRAGMENT_RENDERER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: getrennte sichtbare Bereiche beibehalten' \
    "$CESE_VISIBLE_RANGE_PROVIDER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: nur sichtbare Altattribute synchron entfernen' \
    "$CESE_HIGHLIGHTER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Anfangskonfiguration noch ohne angehaengtes' \
    "$CESE_LIFECYCLE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: beim ersten Aufbau keine identischen Textattribute' \
    "$CESE_LONG_LINE_APPEARANCE" 2>/dev/null; then
  echo "→ Patche CodeEdit (Langzeilen-Layout und Highlight-Bereich begrenzen)"
  chmod u+w "$CETV_TEXT_VIEW_LAYOUT" "$CETV_LAYOUT_MANAGER" \
    "$CETV_TYPESETTER" "$CETV_FRAGMENT_RENDERER" \
    "$CESE_VISIBLE_RANGE_PROVIDER" "$CESE_HIGHLIGHTER" \
    "$CESE_LIFECYCLE" "$CESE_LONG_LINE_APPEARANCE"
  /usr/bin/python3 Patches/CodeEditTextView/horizontal-text-viewport.py "$CETV_TEXT_VIEW_LAYOUT" "$CETV_LAYOUT_MANAGER" \
    "$CETV_TYPESETTER" "$CETV_FRAGMENT_RENDERER" \
    "$CESE_VISIBLE_RANGE_PROVIDER" "$CESE_HIGHLIGHTER" \
    "$CESE_LIFECYCLE" "$CESE_LONG_LINE_APPEARANCE"
  LONG_LINE_LAYOUT_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: mehrere sichtbare Textbereiche pro Viewport' \
    "$CETV_TEXT_VIEW_LAYOUT" \
   || ! grep -q 'Fastra-Patch: vor dem Einhaengen in eine ScrollView' \
    "$CETV_LAYOUT_MANAGER" \
   || ! grep -q 'Fastra-Patch: ungebrochene Megazeilen in handliche CoreText-' \
    "$CETV_TYPESETTER" \
   || ! grep -q 'Fastra-Patch: interne Segmente ungebrochener Megazeilen nur' \
    "$CETV_FRAGMENT_RENDERER" \
   || ! grep -q 'Fastra-Patch: getrennte sichtbare Bereiche beibehalten' \
    "$CESE_VISIBLE_RANGE_PROVIDER" \
   || ! grep -q 'Fastra-Patch: nur sichtbare Altattribute synchron entfernen' \
    "$CESE_HIGHLIGHTER" \
   || ! grep -q 'Fastra-Patch: Anfangskonfiguration noch ohne angehaengtes' \
    "$CESE_LIFECYCLE" \
   || ! grep -q 'Fastra-Patch: beim ersten Aufbau keine identischen Textattribute' \
    "$CESE_LONG_LINE_APPEARANCE"; then
  echo "✗ FEHLER: Langzeilen-Highlight-Patch hat NICHT gegriffen." >&2
  exit 1
fi
if [ "$LONG_LINE_LAYOUT_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z5. CodeEditTextView — Soft Wrap fuer Megazeilen virtualisieren.
#
# Der Typesetter muss alle Umbruchpositionen kennen, damit Scrollhoehe,
# Cursorpositionen und Auswahl exakt bleiben. AppKit-Views duerfen daraus aber
# nur fuer den sichtbaren Ausschnitt entstehen. Upstream hatte den passenden
# Iterator bereits vorbereitet, nutzte stattdessen jedoch bewusst die gesamte
# Fragmentliste. Eine 4,36-MB-Zeile erzeugte dadurch zehntausende NSViews.
# Zusaetzlich werden sichtbare Highlight-Ranges defensiv auf das aktuelle
# Dokument geklemmt: Frame-Benachrichtigungen koennen waehrend des JSON-Wechsels
# noch Geometrie aus dem vorherigen Layout liefern; ein ungeklemmtes IndexSet
# brach Fastra 1.75.0 dann mit SIGTRAP ab.
CETV_VIRTUAL_LINE_LAYOUT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Layout.swift"
VIRTUAL_WRAP_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Das Fragmentmodell bleibt vollständig' \
    "$CETV_VIRTUAL_LINE_LAYOUT" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Geometrieabfragen koennen' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Nur echte Dokumentindizes' \
    "$CESE_VISIBLE_RANGE_PROVIDER" 2>/dev/null; then
  echo "→ Patche CodeEdit (Soft-Wrap-Views virtualisieren und Ranges klemmen)"
  chmod u+w "$CETV_VIRTUAL_LINE_LAYOUT" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CESE_VISIBLE_RANGE_PROVIDER"
  /usr/bin/python3 Patches/CodeEditTextView/virtual-soft-wrap-fragments.py "$CETV_VIRTUAL_LINE_LAYOUT" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CESE_VISIBLE_RANGE_PROVIDER"
  VIRTUAL_WRAP_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: Das Fragmentmodell bleibt vollständig' \
    "$CETV_VIRTUAL_LINE_LAYOUT" \
   || ! grep -q 'Fastra-Patch: Geometrieabfragen koennen' \
    "$CETV_TEXT_VIEW_LAYOUT" \
   || ! grep -q 'Fastra-Patch: Nur echte Dokumentindizes' \
    "$CESE_VISIBLE_RANGE_PROVIDER"; then
  echo "✗ FEHLER: Soft-Wrap-Virtualisierung hat NICHT gegriffen." >&2
  exit 1
fi
if [ "$VIRTUAL_WRAP_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z6. CodeEdit — Startlayout, sichtbare Syntaxbereiche und verborgene Minimap.
#
# Der Editor erzeugt eine TextLine zuerst mit unendlicher Breite und kennt die
# echte Viewportbreite erst nach dem Einhaengen in die ScrollView. Upstream
# wertete genau diesen Wechsel nicht als neues Layout: Soft Wrap behielt dann
# das mehrere Millionen Pixel breite Startfragment. Vor dem ersten endlichen
# Layout darf dieses provisorische Fragment ausserdem nicht als vollstaendig
# sichtbar an den Highlighter gehen; sonst werden vier Millionen Zeichen in
# 4-KB-Auftraegen auf den Main-Thread zurueckgeschrieben. Eine verborgene
# Minimap darf schliesslich kein zweites Voll-Layout berechnen.
# Regression: DifficultDocumentCorpusTests und LongLineEditorPerformanceTests.
CESE_MINIMAP_CONTENT="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Minimap/MinimapContentView.swift"
CESE_PERIPHERALS="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditorConfiguration/SourceEditorConfiguration+Peripherals.swift"
RESPONSIVE_WRAP_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Auch der Wechsel von unendlicher Startbreite' \
    "$CETV_TEXTLINE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Bei Soft Wrap liefern die Fragment-Ranges' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null \
   || ! grep -q 'cachedWidth == layoutManager.maxLineLayoutWidth' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null \
   || ! grep -q 'Range ist NICHT sichtbar' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null \
   || ! grep -q 'private func installScrollObserversIfNeeded' \
    "$CESE_VISIBLE_RANGE_PROVIDER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Eine unsichtbare Minimap darf keine zweite Kopie' \
    "$CESE_MINIMAP_CONTENT" 2>/dev/null \
   || ! grep -q 'controller.minimapView?.contentView.needsLayout = true' \
    "$CESE_PERIPHERALS" 2>/dev/null; then
  echo "→ Patche CodeEdit (Soft Wrap und sichtbare Syntaxbereiche responsiv halten)"
  chmod u+w "$CETV_TEXTLINE" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CESE_VISIBLE_RANGE_PROVIDER" \
    "$CESE_MINIMAP_CONTENT" "$CESE_PERIPHERALS"
  /usr/bin/python3 Patches/CodeEditTextView/initial-layout-highlight-ranges.py "$CETV_TEXTLINE" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CESE_VISIBLE_RANGE_PROVIDER" "$CESE_MINIMAP_CONTENT" \
    "$CESE_PERIPHERALS"
  RESPONSIVE_WRAP_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: Auch der Wechsel von unendlicher Startbreite' \
    "$CETV_TEXTLINE" \
   || ! grep -q 'Fastra-Patch: Bei Soft Wrap liefern die Fragment-Ranges' \
    "$CETV_TEXT_VIEW_LAYOUT" \
   || ! grep -q 'cachedWidth == layoutManager.maxLineLayoutWidth' \
    "$CETV_TEXT_VIEW_LAYOUT" \
   || ! grep -q 'Range ist NICHT sichtbar' \
    "$CETV_TEXT_VIEW_LAYOUT" \
   || ! grep -q 'private func installScrollObserversIfNeeded' \
    "$CESE_VISIBLE_RANGE_PROVIDER" \
   || ! grep -q 'Fastra-Patch: Eine unsichtbare Minimap darf keine zweite Kopie' \
    "$CESE_MINIMAP_CONTENT" \
   || ! grep -q 'controller.minimapView?.contentView.needsLayout = true' \
    "$CESE_PERIPHERALS"; then
  echo "✗ FEHLER: responsiver Soft-Wrap-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi
if [ "$RESPONSIVE_WRAP_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z7. CodeEditTextView — Wortumbruch bei langen alphanumerischen Tokens.
#
# Fuer jedes visuelle Fragment lief Upstream bis zu 100 Zeichen rueckwaerts
# und erzeugte dabei je Zeichen einen NSString-Substring plus CharacterSet.
# Eine 4,36-MB-Zeile nur aus Buchstaben brauchte deshalb rund 17 Sekunden.
# Der haeufige ASCII-Pfad prueft UTF-16-Codeeinheiten mit direkten Vergleichen
# und ohne Foundation-Zeichensatzobjekte. Auch die CRLF-Pruefung liest nur die
# beiden Codeeinheiten. Sobald Unicode oder ein zusammengesetztes Graphem im
# Suchfenster liegt, greift unveraendert die allgemeine Unicode-Pruefung.
FAST_WORD_BREAK_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: ASCII-Wortumbruch mit direkter UTF-16-Prüfung' \
    "$CETV_BREAK" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Wortumbruch langer Tokens beschleunigen)"
  chmod u+w "$CETV_BREAK"
  /usr/bin/python3 Patches/CodeEditTextView/long-token-word-wrap.py "$CETV_BREAK"
  FAST_WORD_BREAK_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: ASCII-Wortumbruch mit direkter UTF-16-Prüfung' \
    "$CETV_BREAK" \
   || ! grep -q 'private static func fastASCIIWordBreak' "$CETV_BREAK" \
   || grep -q 'attributedSubstring(from: substringRange)' "$CETV_BREAK" \
   || grep -q 'private func ensureCharacterCanBreakLine' "$CETV_BREAK"; then
  echo "✗ FEHLER: schneller Wortumbruch-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi
if [ "$FAST_WORD_BREAK_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z8. CodeEditTextView — Vollkopien einer dokumentweiten Megazeile vermeiden.
#
# `TextLine.prepareForDisplay`, `createContentRuns` und
# `layoutTextUntilLineBreak` erzeugten nacheinander drei vollständige
# NSAttributedString-Kopien derselben 4,36-MB-Zeile. AppKit repariert beim
# Kopieren die Attribute und Schriften synchron auf dem Main-Thread; genau
# dieser Pfad dominierte das reale Öffnungsprofil. Ist die Zeile zugleich das
# ganze Dokument, darf der unveränderte Speicher direkt an CoreText gehen.
# Teilbereiche und Zeilen mit Attachments behalten den bisherigen Kopierpfad.
# Regression: DifficultDocumentCorpusTests und LongLineEditorPerformanceTests.
CETV_COPY_FREE_TEXTLINE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/TextLine.swift"
CETV_COPY_FREE_TYPESETTER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/Typesetter.swift"
COPY_FREE_MEGALINE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: dokumentweite Megazeile ohne Attributkopie' \
    "$CETV_COPY_FREE_TEXTLINE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: vollstaendigen Content-Run direkt an CoreText' \
    "$CETV_COPY_FREE_TYPESETTER" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: vollstaendigen Layout-Run nicht erneut kopieren' \
    "$CETV_COPY_FREE_TYPESETTER" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Megazeile ohne drei vollständige Attributkopien)"
  chmod u+w "$CETV_COPY_FREE_TEXTLINE" "$CETV_COPY_FREE_TYPESETTER"
  /usr/bin/python3 Patches/CodeEditTextView/copy-free-megaline.py "$CETV_COPY_FREE_TEXTLINE" "$CETV_COPY_FREE_TYPESETTER"
  COPY_FREE_MEGALINE_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: dokumentweite Megazeile ohne Attributkopie' \
    "$CETV_COPY_FREE_TEXTLINE" \
   || ! grep -q 'Fastra-Patch: vollstaendigen Content-Run direkt an CoreText' \
    "$CETV_COPY_FREE_TYPESETTER" \
   || ! grep -q 'Fastra-Patch: vollstaendigen Layout-Run nicht erneut kopieren' \
    "$CETV_COPY_FREE_TYPESETTER"; then
  echo "✗ FEHLER: kopierfreier Megazeilen-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi
if [ "$COPY_FREE_MEGALINE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z9. CodeEditTextView — geplante Startlayouts zusammenfassen.
#
# `viewWillMove(toWindow:)` läuft beim Einhängen der TextView, bevor AppKit die
# endgültige Scrollbreite gesetzt hat. Der dortige synchrone `layoutLines()`-
# Aufruf bricht eine dokumentweite Megazeile deshalb mit einer vorläufigen
# Breite um; der normale `layout()`-Durchlauf wiederholt dieselbe Arbeit direkt
# danach mit der echten Breite. Auch eine Viewport-Benachrichtigung darf diesen
# bereits geplanten AppKit-Durchlauf nicht synchron vorwegnehmen. Beim normalen
# Scrollen ohne ausstehendes Layout bleibt der unmittelbare Pfad erhalten.
# Regression: `./selftest.sh loadperf` misst den Main-Thread bis eine Sekunde
# nach dem sichtbaren Editor und `DifficultDocumentCorpusTests` prüft Soft Wrap.
CETV_WINDOW_LIFECYCLE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Lifecycle.swift"
CETV_TEXT_VIEW_CORE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView.swift"
WINDOW_LIFECYCLE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Fensterwechsel nicht mit provisorischer Geometrie layouten' \
    "$CETV_WINDOW_LIFECYCLE" 2>/dev/null \
   || ! grep -q 'hasCompletedLayoutInCurrentWindow = false' \
    "$CETV_WINDOW_LIFECYCLE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: erstes Fensterlayout explizit verfolgen' \
    "$CETV_TEXT_VIEW_CORE" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: regulären Fenster-Layoutlauf merken' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: erstes Fensterlayout nicht synchron vorwegnehmen' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (vorzeitige Startlayouts zusammenfassen)"
  chmod u+w "$CETV_WINDOW_LIFECYCLE" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CETV_TEXT_VIEW_CORE"
  /usr/bin/python3 Patches/CodeEditTextView/window-layout-lifecycle.py "$CETV_WINDOW_LIFECYCLE" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CETV_TEXT_VIEW_CORE"
  WINDOW_LIFECYCLE_PATCH_CHANGED=1
fi
/usr/bin/python3 Patches/CodeEditTextView/window-layout-lifecycle-verification.py "$CETV_WINDOW_LIFECYCLE" "$CETV_TEXT_VIEW_LAYOUT" \
  "$CETV_TEXT_VIEW_CORE"
if [ "$WINDOW_LIFECYCLE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z10. CodeEditTextView — erste Fensteraktualisierungen vor dem Umbruch bündeln.
#
# SwiftUI setzt beim Einhängen Text, Attribute, Insets und Editorzustand in
# mehreren dicht aufeinanderfolgenden Aktualisierungen. Ein sofortiger
# Soft-Wrap-Lauf kann dieselbe Megazeile dadurch mehrfach vollständig umbrechen
# und hängt außerdem im selben Main-Runloop-Durchlauf wie der Editoraufbau.
# Ein kurzer, fenstergebundener Aufschub bündelt diese Invalidierungen zu genau
# einem Layoutlauf. Normales Scrollen sowie spätere Layouts bleiben synchron.
# Regression: `./selftest.sh loadperf` hält einen 10-ms-Main-Thread-Herzschlag
# bis eine Sekunde nach dem echten Editor-Mount am Leben.
INITIAL_WINDOW_LAYOUT_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: initiales Fensterlayout kurz bündeln' \
    "$CETV_TEXT_VIEW_LAYOUT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (erste Fensteraktualisierungen bündeln)"
  chmod u+w "$CETV_WINDOW_LIFECYCLE" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CETV_TEXT_VIEW_CORE"
  /usr/bin/python3 Patches/CodeEditTextView/initial-window-layout.py "$CETV_WINDOW_LIFECYCLE" "$CETV_TEXT_VIEW_LAYOUT" \
    "$CETV_TEXT_VIEW_CORE"
  INITIAL_WINDOW_LAYOUT_PATCH_CHANGED=1
fi
/usr/bin/python3 Patches/CodeEditTextView/initial-window-layout-verification.py "$CETV_WINDOW_LIFECYCLE" "$CETV_TEXT_VIEW_LAYOUT" \
  "$CETV_TEXT_VIEW_CORE"
if [ "$INITIAL_WINDOW_LAYOUT_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z11. CodeEditTextView — Fragmentkennungen fuer Megazeilen billig erzeugen.
#
# Upstream erzeugt fuer jedes visuelle Fragment eine kryptographisch zufaellige
# UUID. Bei einer 4,36-MB-Zeile mit Soft Wrap sind das rund 50.000 UUIDs im
# ersten Main-Thread-Layout. Die Kennung muss nur innerhalb der Lebensdauer des
# Typesetters eindeutig sein. Deshalb bekommt jeder Typesetter eine UUID und
# seine Fragmente einen fortlaufenden Index. Das behaelt die Eindeutigkeit fuer
# View-Reuse und spart die tausenden Zufallszahl-Aufrufe.
# Regression: `./selftest.sh loadperf` misst weiterhin den Main-Thread-
# Herzschlag und `softwrapanchor`/`hscroll` treiben Wiederlayout und View-Reuse.
CETV_LINE_FRAGMENT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/LineFragment.swift"
CETV_TYPESET_CONTEXT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/TypesetContext.swift"
CHEAP_FRAGMENT_ID_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: eine UUID pro Typesetter statt pro Fragment' \
    "$CETV_LINE_FRAGMENT" 2>/dev/null \
   || ! grep -q 'private lazy var fragmentGeneration = UUID()' \
    "$CETV_TYPESETTER" 2>/dev/null \
   || ! grep -q 'fragmentGeneration: fragmentGeneration' \
    "$CETV_TYPESETTER" 2>/dev/null \
   || ! grep -q 'nextFragmentIndex &+= 1' \
    "$CETV_TYPESET_CONTEXT" 2>/dev/null \
   || grep -q 'Fastra-Patch: Fragmentarray fuer Megazeilen vorab reservieren' \
    "$CETV_TYPESET_CONTEXT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (billige eindeutige Fragmentkennungen)"
  chmod u+w "$CETV_LINE_FRAGMENT" "$CETV_TYPESETTER" \
    "$CETV_TYPESET_CONTEXT"
  /usr/bin/python3 Patches/CodeEditTextView/fragment-identifiers.py "$CETV_LINE_FRAGMENT" "$CETV_TYPESETTER" \
    "$CETV_TYPESET_CONTEXT"
  CHEAP_FRAGMENT_ID_PATCH_CHANGED=1
fi
if ! grep -q 'Fastra-Patch: eine UUID pro Typesetter statt pro Fragment' \
    "$CETV_LINE_FRAGMENT" \
   || ! grep -q 'private lazy var fragmentGeneration = UUID()' \
    "$CETV_TYPESETTER" \
   || ! grep -q 'fragmentGeneration: fragmentGeneration' \
    "$CETV_TYPESETTER" \
   || ! grep -q 'nextFragmentIndex &+= 1' \
    "$CETV_TYPESET_CONTEXT" \
   || grep -q 'Fastra-Patch: Fragmentarray fuer Megazeilen vorab reservieren' \
    "$CETV_TYPESET_CONTEXT"; then
  echo "✗ FEHLER: Fragmentkennungs-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi
if [ "$CHEAP_FRAGMENT_ID_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z12. CodeEditTextView — vollstaendige Quelltextattribute nicht erneut fixen.
#
# Der konkrete NSTextStorage aus AppKit meldet Attribute als "lazy": Beim
# ersten CTTypesetter ueber eine 4,36-MB-Zeile durchsucht AppKit deshalb den
# gesamten Speicher nach vermeintlich zu reparierenden Schriftattributen,
# obwohl CodeEditSourceEditor jedem Zeichen bereits Schrift und Farbe gegeben
# hat. Ein kleiner regulaerer NSTextStorage-Untertyp mit eigenem
# NSMutableAttributedString-Backing meldet diese vollstaendigen Attribute als
# sofort gueltig. Auch das unmittelbare AppKit-Fixing muss ausbleiben: Bei
# Syntaxfarben auf Megazeilen sucht es sonst je Lauf erneut die Absatzgrenzen.
# CoreText uebernimmt weiterhin Glyphen-Fallback und Umbruch;
# externe, vom Aufrufer uebergebene NSTextStorage-Instanzen bleiben unveraendert.
# Regression: `./selftest.sh loadperf` misst den realen Fensterpfad; der
# prozedurale schwierige Dokumentkorpus prueft Bearbeitung und Unicode-Layout.
CETV_IMMEDIATE_STORAGE_SWIFT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/ImmediateAttributeTextStorage.swift"
CETV_IMMEDIATE_STORAGE_HEADER="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextViewObjC/include/ImmediateAttributeTextStorage.h"
CETV_IMMEDIATE_STORAGE_IMPL="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextViewObjC/ImmediateAttributeTextStorage.m"
CETV_OBJC_MODULEMAP="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextViewObjC/include/module.modulemap"
CETV_SET_TEXT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+SetText.swift"
IMMEDIATE_ATTRIBUTE_STORAGE_PATCH_CHANGED=0
if [ -e "$CETV_IMMEDIATE_STORAGE_SWIFT" ] \
   || ! grep -q 'Fastra-Patch: vollstaendige Attribute ohne spaetes AppKit-Fixing' \
    "$CETV_IMMEDIATE_STORAGE_IMPL" 2>/dev/null \
   || ! grep -q 'Fastra-Patch: Editorattribute brauchen keine Absatzkorrektur' \
    "$CETV_IMMEDIATE_STORAGE_IMPL" 2>/dev/null \
   || ! grep -q '@interface ImmediateAttributeTextStorage : NSTextStorage' \
    "$CETV_IMMEDIATE_STORAGE_HEADER" 2>/dev/null \
   || ! grep -q 'header "ImmediateAttributeTextStorage.h"' \
    "$CETV_OBJC_MODULEMAP" 2>/dev/null \
   || ! grep -q 'attributes: initialTypingAttributes' \
    "$CETV_TEXT_VIEW_CORE" 2>/dev/null \
   || ! grep -q 'attributes: typingAttributes' \
    "$CETV_SET_TEXT" 2>/dev/null \
   || ! grep -q 'if !(textStorage is ImmediateAttributeTextStorage)' \
    "$CETV_SET_TEXT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (vollständige Attribute sofort gültig)"
  chmod u+w "$CETV_TEXT_VIEW_CORE" "$CETV_SET_TEXT" "$CETV_OBJC_MODULEMAP"
  /usr/bin/python3 Patches/CodeEditTextView/immediate-text-storage.py "$CETV_IMMEDIATE_STORAGE_SWIFT" \
    "$CETV_IMMEDIATE_STORAGE_HEADER" "$CETV_IMMEDIATE_STORAGE_IMPL" \
    "$CETV_OBJC_MODULEMAP" "$CETV_TEXT_VIEW_CORE" "$CETV_SET_TEXT"
  IMMEDIATE_ATTRIBUTE_STORAGE_PATCH_CHANGED=1
fi
if [ -e "$CETV_IMMEDIATE_STORAGE_SWIFT" ] \
   || ! grep -q 'Fastra-Patch: vollstaendige Attribute ohne spaetes AppKit-Fixing' \
    "$CETV_IMMEDIATE_STORAGE_IMPL" \
   || ! grep -q -- '- (BOOL)fixesAttributesLazily' \
    "$CETV_IMMEDIATE_STORAGE_IMPL" \
   || ! grep -q -- '- (void)fixAttributesInRange:(NSRange)range' \
    "$CETV_IMMEDIATE_STORAGE_IMPL" \
   || ! grep -q 'Fastra-Patch: Editorattribute brauchen keine Absatzkorrektur' \
    "$CETV_IMMEDIATE_STORAGE_IMPL" \
   || ! grep -q '@interface ImmediateAttributeTextStorage : NSTextStorage' \
    "$CETV_IMMEDIATE_STORAGE_HEADER" \
   || ! grep -q 'header "ImmediateAttributeTextStorage.h"' \
    "$CETV_OBJC_MODULEMAP" \
   || ! grep -q 'import CodeEditTextViewObjC' \
    "$CETV_TEXT_VIEW_CORE" \
   || ! grep -q 'import CodeEditTextViewObjC' \
    "$CETV_SET_TEXT" \
   || ! grep -q 'attributes: initialTypingAttributes' \
    "$CETV_TEXT_VIEW_CORE" \
   || ! grep -q 'attributes: typingAttributes' \
    "$CETV_SET_TEXT" \
   || ! grep -q 'if !(textStorage is ImmediateAttributeTextStorage)' \
    "$CETV_SET_TEXT" \
   || grep -q 'self.textStorage = NSTextStorage(string: string)' \
    "$CETV_TEXT_VIEW_CORE"; then
  echo "✗ FEHLER: Sofortattribut-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi
if [ "$IMMEDIATE_ATTRIBUTE_STORAGE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextViewObjC.build \
         .build/*/release/CodeEditTextViewObjC.build
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z13. CodeEditSourceEditor — Gutter und Faltleiste in die
# Dokumentkoordinaten des TextView umrechnen.
#
# NSScrollView haengt horizontale Floating-Views direkt unter seine
# ungeflippte Ansicht. GutterView und TextView sind dagegen beide geflippt.
# Bei einem dokumenthohen Gutter ist dessen sichtbares lokales Y deshalb zum
# TextView-Y gespiegelt: oben fragte der Gutter die letzten Zeilen ab, unten
# die ersten. Kurze Dokumente verdecken das, weil dort Viewport und Dokument
# fast gleich hoch sind. Der Patch waehlt sichtbare Zeilen ausdruecklich im
# TextView und rechnet nur ihre Zeichenposition in die lokale Gutter-Ansicht
# um. Die Faltleiste erhaelt dieselbe Umrechnung fuer Zeichnen und Mausziele.
# Regressionstest: DifficultDocumentCorpusTests.
#
# Der Wächter prueft die Marker aller drei Dateien, und der Pythonblock
# schreibt erst, wenn saemtliche Anker validiert sind: Ein frueherer Stand
# schrieb GutterView.swift vor der Pruefung der Faltleisten-Anker — schlug
# dort etwas fehl, blieb der Gutter-Marker stehen, jeder Folgelauf
# uebersprang den Patch und scheiterte dauerhaft erst an der
# Abschlusspruefung. Jeder Einzelschritt ist ausserdem idempotent (schon
# vorhandenes Ergebnis wird uebersprungen), damit ein bereits gepatchter
# Checkout bei Patch-Erweiterungen in place aufgewertet werden kann.
CESE_GUTTER_SCROLL="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/Gutter/GutterView.swift"
CESE_FOLD_VIEW="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/LineFolding/View/LineFoldRibbonView.swift"
CESE_FOLD_DRAW="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/LineFolding/View/LineFoldRibbonView+Draw.swift"
GUTTER_COORDINATE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Floating-Gutter in TextView-Koordinaten zeichnen' \
    "$CESE_GUTTER_SCROLL" 2>/dev/null \
   || ! grep -q 'lastDrawnLineNumbers.append' "$CESE_GUTTER_SCROLL" 2>/dev/null \
   || ! grep -q 'foldRibbonTextPoint(forRibbonLocalPoint' \
    "$CESE_GUTTER_SCROLL" 2>/dev/null \
   || ! grep -q 'func textPoint(forLocalPoint' "$CESE_FOLD_VIEW" 2>/dev/null \
   || ! grep -q 'concatenateTextYTransform(in: context)' "$CESE_FOLD_DRAW" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Gutter-Scrollrichtung synchronisieren)"
  chmod u+w "$CESE_GUTTER_SCROLL" "$CESE_FOLD_VIEW" "$CESE_FOLD_DRAW"
  /usr/bin/python3 Patches/CodeEditSourceEditor/gutter-fold-overlay.py "$CESE_GUTTER_SCROLL" "$CESE_FOLD_VIEW" "$CESE_FOLD_DRAW"
  GUTTER_COORDINATE_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Floating-Gutter in TextView-Koordinaten zeichnen' \
       "$CESE_GUTTER_SCROLL" \
   || ! grep -q 'public var visibleLineIndicesForDrawing' \
       "$CESE_GUTTER_SCROLL" \
   || ! grep -q 'gutterY(forTextY: textYPos)' "$CESE_GUTTER_SCROLL" \
   || ! grep -q 'lastDrawnLineNumbers.append' "$CESE_GUTTER_SCROLL" \
   || ! grep -q 'foldRibbonTextPoint(forRibbonLocalPoint' "$CESE_GUTTER_SCROLL" \
   || ! grep -q 'func textPoint(forLocalPoint point: NSPoint)' \
       "$CESE_FOLD_VIEW" \
   || ! grep -q 'concatenateTextYTransform(in: context)' "$CESE_FOLD_DRAW"; then
  echo "✗ FEHLER: Gutter-Koordinaten-Patch hat NICHT vollständig gegriffen." >&2
  exit 1
fi

if [ "$GUTTER_COORDINATE_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditSourceEditor.build \
         .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z14. CodeEditTextView — Auswahl-Anker und ungültige Ranges schützen.
# Nach Edit kann ein alter `TextSelection.pivot` rechts vom Cursor stehen.
# Shift+→ erzeugt dann über den Schrumpf-Zweig eine negative Länge, die der
# nächste Tastendruck an den Undo-Manager weiterreichen würde.
#   a) `didReplaceCharacters` verwirft den Anker für eine neue Shift-Auswahl.
#   b) `replaceCharacters` überspringt negative oder außerhalb liegende Ranges.
#   c) Beide Auswahl-Setter weisen negative Längen ab; location/max allein
#      erkennen sie nicht sicher.
# Regression über öffentliche Eingaben: `StaleSelectionPivotTests`.
CETV_SELUPDATE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager+Update.swift"
CETV_REPLACE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+ReplaceCharacters.swift"
STALE_PIVOT_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: veralteten Auswahl-Anker verwerfen' \
    "$CETV_SELUPDATE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (veralteter Auswahl-Anker / negative Auswahl-Länge)"
  chmod u+w "$CETV_SELUPDATE" "$CETV_REPLACE" "$CETV_SELMGR"
  /usr/bin/python3 Patches/CodeEditTextView/selection-pivot-validation.py "$CETV_SELUPDATE" "$CETV_REPLACE" "$CETV_SELMGR"
  STALE_PIVOT_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: veralteten Auswahl-Anker verwerfen' "$CETV_SELUPDATE" \
   || ! grep -q 'Fastra-Patch: korrupten Bereich nicht mutieren' "$CETV_REPLACE" \
   || ! grep -q 'Fastra-Patch: negative Laenge abweisen — location und max' \
       "$CETV_SELMGR" \
   || ! grep -q 'Fastra-Patch: negative Laenge abweisen (Crash 2026-08-24)' \
       "$CETV_SELMGR"; then
  echo "✗ FEHLER: Auswahl-Anker-Patch (4z14) hat NICHT vollständig gegriffen." >&2
  exit 1
fi

if [ "$STALE_PIVOT_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z15. CodeEditTextView — Cursor-Delta bei Ersetzungen korrigieren.
# `didReplaceCharacters` muss Einfügelänge minus gelöschte Länge verwenden.
# Die volle Einfügelänge verschiebt bei Rechteckersetzungen nachfolgende
# Cursor kumulativ an falsche Positionen; weiteres Tippen verändert dann
# falsche Textstellen.
# Regression: `ColumnTypingDriftTests` über Rechteckauswahl und Tippen.
CURSOR_DELTA_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: echte Verschiebung auch beim ERSETZEN' \
    "$CETV_SELUPDATE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Cursor-Delta beim Ersetzen nicht-leerer Bereiche)"
  chmod u+w "$CETV_SELUPDATE"
  /usr/bin/python3 Patches/CodeEditTextView/cursor-replacement-delta.py "$CETV_SELUPDATE"
  CURSOR_DELTA_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: echte Verschiebung auch beim ERSETZEN' "$CETV_SELUPDATE"; then
  echo "✗ FEHLER: Cursor-Delta-Patch (4z15) hat NICHT gegriffen." >&2
  exit 1
fi

# 4z16. CodeEditTextView — veraltete Zeichenbereiche klemmen.
# Statische Emphasis-Ranges können nach verkürzendem Edit hinter das
# Dokumentende zeigen. `roundedPathForRange` berechnet zwar validRange,
# reicht aber die ursprüngliche Range an `rectsFor` weiter.
# Deshalb in `rectsFor(range:)` selbst klemmen; das schützt auch
# Unterstreichungen und Drag vor NSRangeException.
# Regression: `EmphasisStaleRangeTests` durchläuft den echten Zeichenpfad.
CETV_LAYOUT_PUBLIC="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Public.swift"
RECTSFOR_CLAMP_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Bereich an den echten Dokumentgrenzen kappen' \
    "$CETV_LAYOUT_PUBLIC" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (rectsFor kappt Bereiche am Dokumentende)"
  chmod u+w "$CETV_LAYOUT_PUBLIC"
  /usr/bin/python3 Patches/CodeEditTextView/stale-range-rects.py "$CETV_LAYOUT_PUBLIC"
  RECTSFOR_CLAMP_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Bereich an den echten Dokumentgrenzen kappen' \
    "$CETV_LAYOUT_PUBLIC"; then
  echo "✗ FEHLER: rectsFor-Clamp-Patch (4z16) hat NICHT gegriffen." >&2
  exit 1
fi

# 4z17. CodeEditTextView — jede Cursor-View aktualisieren.
# `didUpdate = didUpdate || reposition…` überspringt nach dem ersten true
# alle weiteren Aufrufe. Erst repositionieren, dann das Ergebnis verodern,
# damit auch gleichzeitig geänderte Rechteckselektionen vollständige
# Cursor-Views erhalten. Regression: `ColumnCursorViewTests`.
CETV_SELMGR_MAIN="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextSelectionManager/TextSelectionManager.swift"
CURSOR_VIEWS_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: jede Selektion repositionieren' \
    "$CETV_SELMGR_MAIN" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Cursor-Views aller Selektionen aktualisieren)"
  chmod u+w "$CETV_SELMGR_MAIN"
  /usr/bin/python3 Patches/CodeEditTextView/all-selection-cursor-views.py "$CETV_SELMGR_MAIN"
  CURSOR_VIEWS_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: jede Selektion repositionieren' "$CETV_SELMGR_MAIN"; then
  echo "✗ FEHLER: Cursor-View-Patch (4z17) hat NICHT gegriffen." >&2
  exit 1
fi

if [ "$CURSOR_DELTA_PATCH_CHANGED" -eq 1 ] || [ "$RECTSFOR_CLAMP_PATCH_CHANGED" -eq 1 ] \
   || [ "$CURSOR_VIEWS_PATCH_CHANGED" -eq 1 ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z18. Folgefragment-Ursprung und Umbruchraum gemeinsam berechnen.
# Nach allen älteren Typesetter-Patches; der Helfer prüft jede Integrationsstelle.
SOFT_WRAP_INDENT_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/soft-wrap-indentation.py "$CHECKOUTS/CodeEditTextView")
if [ "$SOFT_WRAP_INDENT_PATCH" = "changed" ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule \
        .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z19. Profil-Reconcile und eigene Minimap-Geometrie.
SOFT_WRAP_UI_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/soft-wrap-indentation.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$SOFT_WRAP_UI_PATCH" = "changed" ]; then
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z20. Syntax-Folding: Revisionen, verschachtelte Platzhalter und Edit-Ranges.
FOLDING_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/code-folding.py "$CHECKOUTS/CodeEditSourceEditor" "$CHECKOUTS/CodeEditTextView")
if [ "$FOLDING_PATCH" = "changed" ]; then
  rm -rf .build/*/debug/CodeEditTextView.build .build/*/release/CodeEditTextView.build
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditTextView.swiftmodule .build/*/release/Modules/CodeEditTextView.swiftmodule
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z21. Tatsächliche Einrückungsbreite und dokumenteigene Zeilenenden.
MARKDOWN_EDIT_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/markdown-editing.py "$CHECKOUTS/CodeEditSourceEditor" "$CHECKOUTS/TextFormation")
if [ "$MARKDOWN_EDIT_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/{CodeEditSourceEditor,TextFormation}.build
  rm -f .build/*/{debug,release}/Modules/{CodeEditSourceEditor,TextFormation}.swiftmodule
fi

# 4z22. Redo darf bei fehlgeschlagener Bildwiederherstellung keinen Link einsetzen.
REDO_PREFLIGHT_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/redo-preflight.py "$CHECKOUTS/CodeEditTextView")
if [ "$REDO_PREFLIGHT_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditTextView.build
  rm -f .build/*/{debug,release}/Modules/CodeEditTextView.swiftmodule
fi

# 4z23. Zeichenmarkierungen folgen Farben, Schrift und Darstellungsschaltern.
INVISIBLES_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/invisible-characters.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$INVISIBLES_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z24. Dokumentgebundener Undo-Verlauf über Ersetzungen und Editor-Neuaufbau.
DOCUMENT_UNDO_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/document-undo.py "$CHECKOUTS/CodeEditSourceEditor" "$CHECKOUTS/CodeEditTextView")
if [ "$DOCUMENT_UNDO_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/{CodeEditSourceEditor,CodeEditTextView}.build
  rm -f .build/*/{debug,release}/Modules/{CodeEditSourceEditor,CodeEditTextView}.swiftmodule
fi

# 4z25. Bild-Undo im begrenzten RAM-Puffer, große Dateioperationen asynchron.
IMAGE_UNDO_MEMORY_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/image-undo-memory.py "$CHECKOUTS/CodeEditTextView")
if [ "$IMAGE_UNDO_MEMORY_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditTextView.build
  rm -f .build/*/{debug,release}/Modules/CodeEditTextView.swiftmodule
fi

# 4z26. Verspätete Syntaxfarben bleiben innerhalb des aktuellen Textspeichers.
HIGHLIGHT_STYLE_BOUNDS_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/highlight-style-bounds.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$HIGHLIGHT_STYLE_BOUNDS_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z27. Zwei Quellansichten teilen Text und Undo, behalten eigene Auswahlen.
SHARED_SOURCE_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/shared-source.py "$CHECKOUTS/CodeEditTextView")
if [ "$SHARED_SOURCE_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditTextView.build
  rm -f .build/*/{debug,release}/Modules/CodeEditTextView.swiftmodule
fi

# 4z28. Theme-Wechsel dürfen die Farben des anderen Ausschnitts nicht löschen.
SHARED_APPEARANCE_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/shared-source-appearance.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$SHARED_APPEARANCE_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z29. Programmatische Einzelauswahl zeichnet die Auswahlfläche sofort neu.
SELECTION_REDRAW_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/selection-redraw.py "$CHECKOUTS/CodeEditTextView")
if [ "$SELECTION_REDRAW_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditTextView.build
  rm -f .build/*/{debug,release}/Modules/CodeEditTextView.swiftmodule
fi

# 4z30. Asynchrone Parser-Edits ändern Highlight-Zustand ausschließlich auf Main.
HIGHLIGHT_EDIT_THREAD_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/highlight-edit-main-thread.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$HIGHLIGHT_EDIT_THREAD_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z31. Große Festbreitenzeilen erzeugen Glyphen nur für benötigte Ausschnitte.
LAZY_ASCII_LAYOUT_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/lazy-ascii-layout.py "$CHECKOUTS/CodeEditTextView")
if [ "$LAZY_ASCII_LAYOUT_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditTextView.build
  rm -f .build/*/{debug,release}/Modules/CodeEditTextView.swiftmodule
fi

# 4z32. Minimap-Layout und Zeichnung bleiben auf benötigte Ausschnitte begrenzt.
LAZY_MINIMAP_LAYOUT_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/lazy-minimap-layout.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$LAZY_MINIMAP_LAYOUT_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z33. Auch die Minimap meldet nur tatsächlich sichtbare Syntaxbereiche.
MINIMAP_VISIBLE_RANGES_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/minimap-visible-ranges.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$MINIMAP_VISIBLE_RANGES_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z34. Minimap-Scrollbeobachter erst nach Anschluss an die ScrollView aufbauen.
MINIMAP_SCROLL_OBSERVERS_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/minimap-scroll-observers.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$MINIMAP_SCROLL_OBSERVERS_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4z35. Minimap-Hoehen im vorhandenen Zeilenbaum statt in einem zweiten abgleichen.
BATCH_LINE_HEIGHTS_PATCH=$(/usr/bin/python3 Patches/CodeEditTextView/batch-line-heights.py "$CHECKOUTS/CodeEditTextView")
if [ "$BATCH_LINE_HEIGHTS_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditTextView.build
  rm -f .build/*/{debug,release}/Modules/CodeEditTextView.swiftmodule
fi

# 4z36. Dekorative Klammermarkierung bleibt auch vor dem Scrollen cursornahe.
BRACKET_EMPHASIS_WINDOW_PATCH=$(/usr/bin/python3 Patches/CodeEditSourceEditor/bracket-emphasis-window.py "$CHECKOUTS/CodeEditSourceEditor")
if [ "$BRACKET_EMPHASIS_WINDOW_PATCH" = "changed" ]; then
  rm -rf .build/*/{debug,release}/CodeEditSourceEditor.build
  rm -f .build/*/{debug,release}/Modules/CodeEditSourceEditor.swiftmodule
fi

# Die `rm .build/*/{debug,release}/<Modul>.build`-Zeilen gelten für das alte
# Buildsystem `native`. Swift 6.4 verwendet standardmäßig `swiftbuild`
# (`.build/out/Intermediates.noindex/`), das Checkout-Änderungen selbst neu
# übersetzt; dort ist keine manuelle Invalidierung nötig.
# Verifizierte Grundlage: `LESSONS-LEARNED.md`, A.6.

# 5. Build-Cache invalidieren, sonst greift SPM auf das alte Plugin-Manifest zu
rm -f .build/build.db .build/plugin-tools.yaml .build/release.yaml

# 5b. Fenster-Zielwahl vor dem Kompilieren per Quellprüfung absichern.
# `window-targeting-audit.sh` schützt die gemeinsame Zuordnung von Fenster,
# Workspace und Editor.
./window-targeting-audit.sh

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
cp Fastra.sdef "$APP/Contents/Resources/Fastra.sdef"
mkdir -p "$APP/Contents/Helpers"
cp ".build/$CONFIG/fastra-diff" "$APP/Contents/Helpers/fastra-diff"
chmod 755 "$APP/Contents/Helpers/fastra-diff"
cp ".build/$CONFIG/fastra-control" "$APP/Contents/Helpers/fastra-control"
chmod 755 "$APP/Contents/Helpers/fastra-control"

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
# XCFramework (CodeLanguagesContainer, binaryTarget). Das ist ein statisches
# Archiv (früher universal x86_64+arm64, ~375 MB): es wird zur Build-Zeit ins
# Fastra-Binary gelinkt und zur Laufzeit nie geladen — dyld kann ein ar-Archiv
# gar nicht laden, und das Binary hat keine passende Load-Command (nicht in
# `otool -L`). Früher wurde es dennoch nach Contents/Frameworks kopiert: reines
# totes Gewicht, das das Bundle vervierfachte. Wir kopieren es daher nicht mehr.
# (Apple-Silicon-only — die x86_64-Hälfte des Archivs wäre ohnehin unnütz.)
# Sollte je ein echt dynamisches Framework (.dylib-Binary) dazukommen, müsste
# hier wieder selektiv kopiert werden — statische Archive aber bewusst nicht.

# Release-Bundle verschlanken: Debug-Symbole aus dem Binary strippen.
# strip entfernt hier nur wenige MB (der Löwenanteil des Binaries sind die
# einkompilierten Grammatiken, nicht Symbole), invalidiert aber auf Apple
# Silicon die (ad-hoc-)Signatur → danach zwingend ad-hoc neu signieren, sonst
# killt Gatekeeper den Start ("code signature invalid"). Nur im Release-Build;
# Debug behält seine Symbole für die Crash-/lldb-Diagnose.
if [ "$CONFIG" = "release" ]; then
  echo "→ Release: Binary strippen"
  strip -x "$APP/Contents/MacOS/Fastra"
fi

# Auch lokale Builds brauchen nach dem Einbetten von Sparkle eine konsistente
# innere Signatur. Der Release-/Installationspfad signiert dasselbe Bundle
# später noch einmal mit Developer ID, Hardened Runtime und Zeitstempel.
#
# `sign-bundle.sh` strippt vor dem Signieren die Debug-Map. Für ein
# Debug-Bundle wäre das falsch — genau diese Symbole braucht lldb, und die
# Zeile oben sagt ausdrücklich, dass Debug sie behält. Deshalb bekommt nur der
# Release-Build den strippenden Aufruf.
if [ "$CONFIG" = "release" ]; then
  ./sign-bundle.sh "$APP" -
else
  ./sign-bundle.sh "$APP" - --keep-debug-symbols
fi

# Pflicht-Gate für verteilbare Bundles: Blendet die absoluten SwiftPM-
# Build-Fallbacks kurz aus und startet den fensterlosen Lokalisierungstest.
# Direkte Builds prüfen hier; der Installer prüft das signierte fertige Bundle
# vor der Installation. Ein fehlender Ressourcenpfad darf das Ziel nie erreichen.
if [ "${FASTRA_DEFER_PORTABILITY_CHECK:-0}" = "1" ]; then
  # Der Installer holt den echten App-Start nach Signierung und Notarisierung
  # nach. So startet sein Build noch kein Bundle mit wechselnder Ad-hoc-Identität.
  echo "→ Portabilitätsprüfung ausstehend; wird vom Installer nachgeholt."
else
  ./verify-portable-app.sh "$APP" ".build/$CONFIG"
fi

# Fertiges Bundle zusätzlich ins Projekt-Hauptverzeichnis kopieren —
# dort ist es sichtbar und bequem doppelklickbar, statt im versteckten
# .build-Ordner zu stecken. Es liegt immer die zuletzt gebaute Variante
# dort (debug oder release). ditto statt cp -R: ersetzt sauber in-place,
# erhält Rechte/Symlinks im Bundle.
ROOT_APP="../Fastra.app"
rm -rf "$ROOT_APP"
ditto "$APP" "$ROOT_APP"

echo
echo "✔ Fertig. App-Bundle: $APP"
echo "  Kopie zum Doppelklicken: $(cd .. && pwd)/Fastra.app ($CONFIG)"
echo "  Nicht installiert: /Applications ist notarisierten Builds vorbehalten."
echo "  Start mit: open $(cd .. && pwd)/Fastra.app"
