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

# Sicherheitshalber laufende EIGENE Fastra-Instanzen beenden — sonst kann
# das spätere Bundle-Kopieren auf ein offenes Binary treffen und nur
# halb überschreiben. Das hatte uns einmal eine Stunde Debug gekostet.
#
# Bewusst KEIN pauschales `pkill -x Fastra` mehr: Das beendete JEDE
# Fastra-Instanz auf dem Mac — auch die installierte App aus /Applications
# und die eines parallel bauenden Worktrees (dieselbe Falle wie das am
# 2026-08-09 in selftest.sh behobene `pkill -f`). Eigen ist eine Instanz
# nur, wenn ihr gestartetes Binary (Spalte „comm" von ps) an einem Ort
# liegt, den dieses Skript gleich überschreibt: im hiesigen .build/-Baum
# oder in der Doppelklick-Kopie Fastra.app im Projekt-Root. Die pwd-P-
# Varianten decken den Fall ab, dass derselbe Ort einmal über einen
# Symlink und einmal direkt betreten wurde.
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

# 4b-2. Patch CodeEditSourceEditor — manuellen Completion-Aufruf melden.
#
# `completionSuggestionsRequested` unterscheidet upstream nicht, ob die Liste
# automatisch (getippter Buchstabe) oder manuell (Esc/⌃Leertaste) angefordert
# wurde. Fastras Delegate braucht das aber: Der manuelle Aufruf darf schon ab
# EINEM Zeichen liefern, das Tipp-Popup bleibt ab zwei Zeichen unaufdringlich
# (Review 2026-08-02). Der Patch meldet den manuellen Weg über eine
# Notification, unmittelbar bevor CESE die Vorschläge anfordert.
if ! grep -q 'fastra.completion.manualTrigger' "$CESE_LC" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (manueller Completion-Aufruf meldet sich)"
  # WICHTIG: Die Meldung kommt erst NACH dem isVisible-Zweig — ein Esc, das
  # nur ein OFFENES Popup schliesst, ist KEIN manueller Oeffnen-Wunsch und
  # duerfe den Ein-Zeichen-Modus nicht scharfschalten (Selbsttestbefund
  # completion4d, 2026-08-09).
  /usr/bin/perl -i -0pe 's/(if SuggestionController\.shared\.isVisible \{\s*\n\s*SuggestionController\.shared\.close\(\)\s*\n\s*return event\s*\n\s*\}\n)/$1            NotificationCenter.default.post(name: Notification.Name("fastra.completion.manualTrigger"), object: self)  \/\/ Fastra-Patch: manueller Aufruf (Esc\/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n/' "$CESE_LC"
  if ! grep -q 'fastra.completion.manualTrigger' "$CESE_LC" 2>/dev/null; then
    echo "✗ FEHLER: Manual-Completion-Patch hat NICHT gegriffen — Quelle hat sich geändert. Build abgebrochen." >&2
    exit 1
  fi
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4b-2-Nachzug: Checkouts, die Version 1.66.0 noch an der ALTEN Stelle gepatcht
# hat (Meldung VOR dem isVisible-Zweig), auf die neue Position migrieren.
#
# Der Block oben greift nur, wenn der Marker `fastra.completion.manualTrigger`
# ganz fehlt. Ein bereits alt gepatchter Checkout enthält ihn — er wurde also
# weder migriert noch neu übersetzt und behielt das alte Fehlverhalten: Ein
# Esc, das nur ein offenes Popup schliesst, schaltete den Ein-Zeichen-Modus
# für den nächsten Request scharf (Review 2026-08-10). Die Migration schiebt
# genau die eine Zeile hinter den isVisible-Zweig.
if /usr/bin/python3 - "$CESE_LC" <<'PYEOF'
import os, stat, sys

path = sys.argv[1]
src = open(path).read()
note = ('            NotificationCenter.default.post(name: Notification.Name('
        '"fastra.completion.manualTrigger"), object: self)'
        '  // Fastra-Patch: manueller Aufruf (Esc/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n')
visible = ('            if SuggestionController.shared.isVisible {\n'
           '                SuggestionController.shared.close()\n'
           '                return event\n'
           '            }\n')
old = note + visible      # v1.66.0: Meldung VOR dem isVisible-Zweig
new = visible + note      # ab v1.68.1: Meldung DANACH
if old not in src:
    sys.exit(2)           # nichts zu migrieren
print("→ Migriere CodeEditSourceEditor (4b-2: Manuell-Trigger hinter den isVisible-Zweig)")
os.chmod(path, os.stat(path).st_mode | stat.S_IWUSR)
open(path, "w").write(src.replace(old, new, 1))
PYEOF
then
  # SPM trackt Quell-Änderungen in .build/checkouts NICHT → Build-Produkte
  # verwerfen, sonst bliebe die alte Fassung einkompiliert (wie bei 4b/4c).
  rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
  rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
        .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# Endkontrolle für beide Wege (frischer Patch ODER Migration): Die Meldung muss
# MIT ihrem Kontext hinter dem isVisible-Zweig stehen und darf davor nicht mehr
# vorkommen. Fehlt sie oder steht sie noch vorn, hat Upstream die Stelle
# umgebaut und der Fix wäre lautlos verschwunden.
if ! /usr/bin/python3 - "$CESE_LC" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
note = ('            NotificationCenter.default.post(name: Notification.Name('
        '"fastra.completion.manualTrigger"), object: self)'
        '  // Fastra-Patch: manueller Aufruf (Esc/Ctrl-Space) erlaubt Ein-Zeichen-Vorschlaege\n')
visible = ('            if SuggestionController.shared.isVisible {\n'
           '                SuggestionController.shared.close()\n'
           '                return event\n'
           '            }\n')
if note + visible in src:
    print("  Meldung steht noch VOR dem isVisible-Zweig.", file=sys.stderr)
    sys.exit(1)
if visible + note not in src:
    print("  Meldung samt isVisible-Kontext nicht gefunden.", file=sys.stderr)
    sys.exit(1)
PYEOF
then
  echo "✗ FEHLER: Manual-Completion-Patch steht nicht an der geprüften Stelle. Build abgebrochen." >&2
  exit 1
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
#
# WICHTIG (Dauertest-Befund 2026-08-09): Das Scrollen ist ans Key-Window
# gebunden. Der Vergleich oben feuert bei JEDER SwiftUI-Neubewertung erneut,
# solange State und Controller divergieren — und nach einem Treffer-Sprung
# konvergieren sie nie: Der Sprung-Pfad schreibt eine CursorPosition mit
# range == .notFound, der Coordinator verwirft die aufgelöste Rückmeldung im
# isUpdatingFromRepresentable-Fenster. Mit bedingungslosem `scrollToVisible:
# true` scrollten dadurch auch HINTERGRUND-Fenster spontan, sobald irgendeine
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
# Wie bei 4b: SPM trackt Quell-Änderungen in .build/checkouts NICHT →
# CESE-Build-Produkte verwerfen, damit der Patch neu übersetzt wird.
rm -rf .build/*/debug/CodeEditSourceEditor.build .build/*/release/CodeEditSourceEditor.build
rm -f .build/*/debug/Modules/CodeEditSourceEditor.swiftmodule \
      .build/*/release/Modules/CodeEditSourceEditor.swiftmodule
fi

# 4c-Nachzug: Checkouts mit der ALTEN Patchfassung (`scrollToVisible: true`
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

# Endkontrolle für beide Wege (frischer Checkout ODER Migration): Die
# Key-Window-Scrollbindung muss jetzt in der Quelle stehen. Fehlt sie, hat
# Upstream die Stelle umgebaut und der Fix wäre lautlos verschwunden.
if ! grep -qF 'scrollToVisible: controller.textView?.window?.isKeyWindow == true' "$CESE_SE" 2>/dev/null; then
  echo "✗ FEHLER: Key-Window-Scrollbindung fehlt in SourceEditor.swift — Quelle hat sich geändert. Build abgebrochen." >&2
  exit 1
fi

# 4c-2. Wurzelbehandlung des Nachzieh-Scrollens (Dauertest 2026-08-07/09):
# Nach einem Treffer-Sprung schreibt der Sprung-Pfad eine CursorPosition mit
# range == .notFound (nur Zeile/Spalte — bewusst, driftfreie Adressierung).
# Der Coordinator verwirft die aufgelöste Rückmeldung im
# isUpdatingFromRepresentable-Fenster, State und Controller konvergieren also
# NIE — der Zweig oben feuerte deshalb bei jeder SwiftUI-Neubewertung erneut
# und konnte die aktive Ansicht beim Markieren mit der Maus nachziehen. Der
# Vergleich läuft jetzt über controller.resolveCursorPosition: Ein bereits
# angewandter Sprung gilt damit als „gleich", der Zweig wird still.
if ! grep -qF 'Vergleich ueber resolveCursorPosition' "$CESE_SE" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (4c-2: Sprungvergleich über resolveCursorPosition)"
  chmod u+w "$CESE_SE"
  /usr/bin/python3 - "$CESE_SE" <<'PYEOF'
import sys, re

path = sys.argv[1]
src = open(path).read()
old = ('        if let cursorPositions = state.cursorPositions, '
       'cursorPositions != controller.cursorPositions {'
       '  // Fastra-Patch: upstream verglich state.cursorPositions mit sich selbst (immer false) -> externer Sprung wirkte nie')
new = ('        if let cursorPositions = state.cursorPositions,\n'
       '           cursorPositions.compactMap({ controller.resolveCursorPosition($0) }) != controller.cursorPositions {'
       '  // Fastra-Patch: Vergleich ueber resolveCursorPosition -- ein angewandter Sprung (nur Zeile/Spalte, range == .notFound) gilt sonst nie als gleich; der Zweig feuerte dann bei jeder SwiftUI-Neubewertung erneut und zog die aktive Ansicht nach (Dauertest-Wurzel 2026-08-07/09)')
if old not in src:
    raise SystemExit(f"{path}: 4c-Vergleichszeile nicht gefunden — Patch 4c-2 pruefen")
src = src.replace(old, new, 1)
# Doppelten Kommentar aus einer frueheren Migration einmalig deduplizieren.
dup = ('            // Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n'
       '            // Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n')
single = ('            // Fastra-Patch: Scrollen nur im Key-Window -- ein Hintergrundfenster darf bei SwiftUI-Neubewertungen nie ungefragt scrollen (Dauertest-Befund 2026-08-09)\n')
src = src.replace(dup, single)
open(path, "w").write(src)
PYEOF
  if ! grep -qF 'Vergleich ueber resolveCursorPosition' "$CESE_SE" 2>/dev/null; then
    echo "✗ FEHLER: 4c-2-Patch (resolveCursorPosition-Vergleich) hat NICHT gegriffen. Build abgebrochen." >&2
    exit 1
  fi
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

# 4b-3. Patch CodeEditSourceEditor — Delegate erfährt vom Fenster-Schließen.
#
# `CodeSuggestionDelegate.completionWindowDidClose()` ist im Protokoll
# deklariert, wird von CESE aber NIRGENDS aufgerufen. Fastras Delegate hält
# darüber seinen `windowIsOpen`-Zustand — ohne den Aufruf blieb er nach dem
# ERSTEN Popup für immer wahr, und die Ein-Zeichen-Mindestlänge des offenen
# Fensters galt ab da dauerhaft (Selbsttestbefund completion4d, 2026-08-09:
# Auto-Popup schon bei einem Zeichen). Der Patch meldet das Schließen im
# zentralen willClose() des Modells; der Aufruf ist idempotent.
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
  /usr/bin/python3 - "$CESE_THEME" "$CESE_CAPTURE" <<'PYEOF'
import sys
theme_path, capture_path = sys.argv[1], sys.argv[2]
theme = open(theme_path).read()
capture = open(capture_path).read()

old_property = '''    public var methods: Attribute
    public var types: Attribute'''
new_property = '''    public var methods: Attribute
    // Fastra-Patch: eigener Component-Methoden-Slot fuer 4D. Der optionale
    // Initializer-Parameter erbt fuer bestehende Themes den commands-Slot.
    public var componentMethods: Attribute
    public var types: Attribute'''
if old_property not in theme:
    sys.exit("EditorTheme-Properties haben sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_property, new_property, 1)

old_init = '''        comments: Attribute,
        methods: Attribute? = nil
    ) {'''
new_init = '''        comments: Attribute,
        methods: Attribute? = nil,
        componentMethods: Attribute? = nil
    ) {'''
if old_init not in theme:
    sys.exit("EditorTheme-Initializer hat sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_init, new_init, 1)

old_assignment = '''        self.methods = methods ?? commands
        self.types = types'''
new_assignment = '''        self.methods = methods ?? commands
        self.componentMethods = componentMethods ?? commands
        self.types = types'''
if old_assignment not in theme:
    sys.exit("EditorTheme-Assignments haben sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_assignment, new_assignment, 1)

old_mapping = '''        case .method: return methods
        case .number, .float: return numbers'''
new_mapping = '''        case .method: return methods
        case .componentMethod: return componentMethods
        case .number, .float: return numbers'''
if old_mapping not in theme:
    sys.exit("EditorTheme-Component-Mapping hat sich geaendert — Patch 4m2 pruefen")
theme = theme.replace(old_mapping, new_mapping, 1)

old_cases = '''    case keywordReturn
    case keywordFunction'''
new_cases = '''    case keywordReturn
    case keywordFunction
    // Fastra-Patch: eigener Component-Methoden-Slot fuer 4D.
    // Am Ende angehaengt, damit alle vorhandenen Int8-Rohwerte stabil bleiben.
    case componentMethod'''
if old_cases not in capture:
    sys.exit("CaptureName-Cases haben sich geaendert — Patch 4m2 pruefen")
capture = capture.replace(old_cases, new_cases, 1)

old_from_string = '''        case "keyword.function":
            return .keywordFunction
        default:'''
new_from_string = '''        case "keyword.function":
            return .keywordFunction
        case "component.method":
            return .componentMethod
        default:'''
if old_from_string not in capture:
    sys.exit("CaptureName.fromString hat sich geaendert — Patch 4m2 pruefen")
capture = capture.replace(old_from_string, new_from_string, 1)

old_string_value = '''        case .keywordFunction:
            return "keywordFunction"
        }'''
new_string_value = '''        case .keywordFunction:
            return "keywordFunction"
        case .componentMethod:
            return "component.method"
        }'''
if old_string_value not in capture:
    sys.exit("CaptureName.stringValue hat sich geaendert — Patch 4m2 pruefen")
capture = capture.replace(old_string_value, new_string_value, 1)

open(theme_path, 'w').write(theme)
open(capture_path, 'w').write(capture)
PYEOF
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
  /usr/bin/python3 - "$CETV_COPY_PASTE" "$CETV_DELETE" "$CETV_REPLACE" "$CETV_SELECT" \
    "$CESE_APPEARANCE" "$CESE_BEHAVIOR" <<'PYEOF'
import sys

copy_paste, delete, replace_characters, select, appearance, behavior = sys.argv[1:]

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
    "Fastra-Patch: Plain-Text-Copy",
    '''        guard let textSelections = selectionManager?
            .textSelections
            .compactMap({ textStorage.attributedSubstring(from: $0.range) }),
              !textSelections.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textSelections)''',
    '''        // Fastra-Patch: Plain-Text-Copy. Upstream legt attributierten Text
        // aufs Clipboard, wodurch RTF der oberste Flavor ist. Zielprogramme
        // mit Rich-Text-Vorrang uebernehmen dann Editorschrift und -farbe;
        // ihr RTF-nach-HTML-Umweg verliert ausserdem Emoji-
        // Variantenselektoren (U+FE0F). Ein Plaintext-Editor kopiert deshalb
        // reinen Text. Mehrere Cursor werden zeilenweise verbunden — als
        // getrennte Pasteboard-Objekte kam beim Einfuegen nur der erste
        // Bereich an.
        guard let ranges = selectionManager?.textSelections.map(\\.range),
              !ranges.isEmpty else {
            return
        }
        let document = NSRange(location: 0, length: textStorage.length)
        // Eine veraltete Selektion (Mutation vor dem Kopieren) darf keinen
        // Bereichsfehler werfen; geklemmt wird nur der Lesebereich.
        let values = ranges.compactMap { range -> String? in
            let safe = range.intersection(document) ?? NSRange(location: 0, length: 0)
            guard safe.length > 0 else { return nil }
            return textStorage.mutableString.substring(with: safe)
        }
        guard !values.isEmpty else { return }
        let separator = layoutManager.detectedLineEnding.rawValue
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(
            [values.joined(separator: separator) as NSString]
        )''',
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
    select,
    "Fastra-Patch: Doppelklick auf Symbole",
    '''    internal func findWordBoundary(at position: Int) -> NSRange {
        guard position >= 0 && position < textStorage.length,''',
    '''    internal func findWordBoundary(at position: Int) -> NSRange {
        // Fastra-Patch: Doppelklick auf Symbole und Emojis markiert den ganzen
        // Graphem-Cluster. Upstream kennt nur Bezeichner, Leerraum,
        // Zeilenenden und Satzzeichen; ein Emoji markierte deshalb gar nichts
        // (Daniel-Befund 2026-07-27). Mehrteilige Cluster gewinnen sofort:
        // Ein Klick auf den Variantenselektor U+FE0F landete sonst in der
        // Wortlogik, weil Foundation ihn zu den alphanumerischen Zeichen
        // zaehlt, und markierte nur ihn allein.
        let fastraCluster = fastraGraphemeClusterRange(at: position)
        if fastraCluster.length > 1 {
            return fastraCluster
        }
        guard position >= 0 && position < textStorage.length,''',
)
replace_once(
    select,
    "Fastra-Patch: einzelnes Symbol",
    '''        } else {
            return NSRange(location: position, length: 0)
        }''',
    '''        } else {
            // Fastra-Patch: einzelnes Symbol (Pfeil, nacktes ⏸ ohne
            // Variantenselektor) markiert sich selbst statt nichts.
            return fastraCluster
        }''',
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
    replace_characters,
    "Fastra-Patch: kein Scrollen waehrend gebuendeltem Undo/Redo",
    '''        if let selection = selectionManager.textSelections.first, !visibleRect.contains(selection.boundingRect) {
            scrollSelectionToVisible()
        }''',
    '''        // Fastra-Patch: kein Scrollen waehrend gebuendeltem Undo/Redo. Der
        // aeussere Undo-Manager scrollt erst nach textStorage.endEditing();
        // hier wuerde ein Bounds-Callback Layout gegen den Zwischenstand
        // ausloesen (Crash im 2.000-Runden-Dauertest).
        if !skipUpdateSelection,
           let selection = selectionManager.textSelections.first,
           !visibleRect.contains(selection.boundingRect) {
            scrollSelectionToVisible()
        }'''
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
  /usr/bin/python3 - "$CETV_UNDO" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()

old_group = '''    private struct UndoGroup {
        var mutations: [Mutation]
    }'''
new_group = '''    private struct UndoGroup {
        var mutations: [Mutation]
        // Fastra-Patch: Auswahlzustand grosser Textoperationen. Optional,
        // damit CodeEdits Standardverhalten fuer alle anderen Edits bleibt.
        var fastraSelectionsBefore: [NSRange]?
        var fastraSelectionsAfter: [NSRange]?
    }'''
if old_group not in src:
    raise SystemExit(
        f"{path}: UndoGroup hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_group, new_group, 1)

old_undo = '''        updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        textView.scrollSelectionToVisible()'''
new_undo = '''        if let selections = item.fastraSelectionsBefore {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        }
        textView.scrollSelectionToVisible()'''
if old_undo not in src:
    raise SystemExit(
        f"{path}: Undo-Auswahlpfad hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_undo, new_undo, 1)

old_redo = '''        updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        textView.scrollSelectionToVisible()'''
new_redo = '''        if let selections = item.fastraSelectionsAfter {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        }
        textView.scrollSelectionToVisible()'''
if old_redo not in src:
    raise SystemExit(
        f"{path}: Redo-Auswahlpfad hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_redo, new_redo, 1)

old_group_init = '''            undoStack.append(UndoGroup(mutations: [newMutation]))
            shouldBreakNextGroup = false'''
new_group_init = '''            undoStack.append(UndoGroup(
                mutations: [newMutation],
                fastraSelectionsBefore: nil,
                fastraSelectionsAfter: nil
            ))
            shouldBreakNextGroup = false'''
if old_group_init not in src:
    raise SystemExit(
        f"{path}: UndoGroup-Initialisierung hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(old_group_init, new_group_init, 1)

anchor = '''    /// Clears the undo/redo stacks.
    public func clearStack() {'''
method = '''    /// Fastra-Patch: Auswahlzustand grosser Textoperationen opt-in
    /// hinterlegen. So stellt Undo den Cursor vor der Transformation und Redo
    /// die Auswahl danach wieder her, statt die komplette Mutationsrange zu
    /// markieren.
    public func fastraSetSelectionSnapshotsForLatestUndo(
        before: [NSRange],
        after: [NSRange]
    ) {
        guard !isUndoing, !isRedoing, !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].fastraSelectionsBefore = before
        undoStack[undoStack.count - 1].fastraSelectionsAfter = after
    }

    /// Clears the undo/redo stacks.
    public func clearStack() {'''
if anchor not in src:
    raise SystemExit(
        f"{path}: clearStack-Anker hat sich geaendert — Patch 4q pruefen"
    )
src = src.replace(anchor, method, 1)

open(path, "w").write(src)
PYEOF
  TEXT_OPERATION_UNDO_PATCH_CHANGED=1
fi

# Bestehende Checkouts können bereits die erste 4q-Fassung ohne das
# abschließende Layout-Rebuild enthalten. Frische Checkouts erhalten beide
# Teile oben in einem Schritt; dieser Zweig migriert nur den lokalen Zwischenstand.
if ! grep -q 'Fastra-Patch: Layout nach grosser Textoperation' \
    "$CETV_UNDO" 2>/dev/null; then
  echo "→ Ergänze CodeEditTextView-Patch (Layout nach Textoperation/Undo)"
  chmod u+w "$CETV_UNDO"
  /usr/bin/python3 - "$CETV_UNDO" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old_undo = '''        if let selections = item.fastraSelectionsBefore {
            textView.selectionManager.setSelectedRanges(selections)
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        }'''
new_undo = '''        if let selections = item.fastraSelectionsBefore {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        }'''
old_redo = '''        if let selections = item.fastraSelectionsAfter {
            textView.selectionManager.setSelectedRanges(selections)
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        }'''
new_redo = '''        if let selections = item.fastraSelectionsAfter {
            textView.selectionManager.setSelectedRanges(selections)
            // Fastra-Patch: Layout nach grosser Textoperation synchron am
            // wiederhergestellten Auswahlanker aufbauen.
            textView.layoutManager.setNeedsLayout()
            textView.layoutManager.layoutLines()
            textView.needsDisplay = true
        } else {
            updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        }'''
if old_undo not in src or old_redo not in src:
    raise SystemExit(
        f"{path}: bestehender 4q-Auswahlpfad hat sich geaendert"
    )
src = src.replace(old_undo, new_undo, 1)
src = src.replace(old_redo, new_redo, 1)
open(path, "w").write(src)
PYEOF
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
  /usr/bin/python3 - "$CETV_UNDO" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()

def replace_once(old, new, label):
    global src
    if old not in src:
        raise SystemExit(f"{path}: {label} hat sich geaendert — Patch 4q pruefen")
    src = src.replace(old, new, 1)

replace_once(
    '''import AppKit
import TextStory
''',
    '''import AppKit
import TextStory

/// Eine kleine, an eine konkrete Undo-Gruppe gebundene Fastra-Nebenwirkung.
/// `discard` laeuft hoechstens einmal, auch wenn Stack-Cleanup und `deinit`
/// denselben verworfenen Redo-Zweig erreichen.
public final class FastraUndoSideEffect {
    private let undoAction: () -> Void
    private let redoAction: () -> Void
    private let discardAction: () -> Void
    private var wasDiscarded = false

    init(undo: @escaping () -> Void,
         redo: @escaping () -> Void,
         discard: @escaping () -> Void) {
        undoAction = undo
        redoAction = redo
        discardAction = discard
    }

    func performUndo() { if !wasDiscarded { undoAction() } }
    func performRedo() { if !wasDiscarded { redoAction() } }
    func discard() {
        guard !wasDiscarded else { return }
        wasDiscarded = true
        discardAction()
    }

    deinit { discard() }
}
''',
    "Import-Anker"
)
replace_once(
    '''        var fastraSelectionsBefore: [NSRange]?
        var fastraSelectionsAfter: [NSRange]?
    }''',
    '''        var fastraSelectionsBefore: [NSRange]?
        var fastraSelectionsAfter: [NSRange]?
        // Fastra-Patch: dateibezogene Nebenwirkungen gehoeren direkt zur
        // konkreten Undo-Gruppe statt zu globalen Undo-Benachrichtigungen.
        var fastraSideEffects: [FastraUndoSideEffect]
    }''',
    "UndoGroup"
)
replace_once(
    '''        textView.scrollSelectionToVisible()

        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)''',
    '''        textView.scrollSelectionToVisible()
        item.fastraSideEffects.forEach { $0.performUndo() }

        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)''',
    "Undo-Abschluss"
)
replace_once(
    '''        textView.scrollSelectionToVisible()

        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)''',
    '''        textView.scrollSelectionToVisible()
        item.fastraSideEffects.forEach { $0.performRedo() }

        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)''',
    "Redo-Abschluss"
)
replace_once(
    '''    /// Clears the undo/redo stacks.
    public func clearStack() {
        undoStack.removeAll()
        redoStack.removeAll()
    }''',
    '''    /// Haengt eine Fastra-Nebenwirkung an exakt die zuletzt registrierte
    /// Textaenderung. Ein neuer Edit nach Undo verwirft den Redo-Zweig.
    @discardableResult
    public func fastraRegisterSideEffectForLatestUndo(
        undo: @escaping () -> Void,
        redo: @escaping () -> Void,
        discard: @escaping () -> Void
    ) -> Bool {
        guard !isUndoing, !isRedoing, !undoStack.isEmpty else { return false }
        undoStack[undoStack.count - 1].fastraSideEffects.append(
            FastraUndoSideEffect(undo: undo, redo: redo, discard: discard)
        )
        return true
    }

    /// Clears the undo/redo stacks.
    public func clearStack() {
        (undoStack + redoStack).flatMap(\\.fastraSideEffects)
            .forEach { $0.discard() }
        undoStack.removeAll()
        redoStack.removeAll()
    }''',
    "clearStack"
)
replace_once(
    '''                fastraSelectionsBefore: nil,
                fastraSelectionsAfter: nil
            ))''',
    '''                fastraSelectionsBefore: nil,
                fastraSelectionsAfter: nil,
                fastraSideEffects: []
            ))''',
    "UndoGroup-Initialisierung"
)
replace_once(
    '''        redoStack.removeAll()
    }

    // MARK: - Grouping''',
    '''        redoStack.flatMap(\\.fastraSideEffects).forEach { $0.discard() }
        redoStack.removeAll()
    }

    // MARK: - Grouping''',
    "Redo-Verwerfen"
)
open(path, "w").write(src)
PYEOF
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
  /usr/bin/python3 - "$CETV_SCROLL_SELECTION" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        var lastFrame: CGRect = .zero
        while let boundingRect = getSelection()?.boundingRect, lastFrame != boundingRect {
            lastFrame = boundingRect'''
new = '''        var lastFrame: CGRect = .zero
        while let selection = getSelection(),
              let activeRect = layoutManager.rectForOffset(offsetNotPivot(selection)),
              lastFrame != activeRect {
            // Fastra-Patch: bewegte Auswahlkante statt Gesamtauswahl. Deren
            // sichtbarer Ausschnitt verankert sonst die Oberkante und laesst
            // Shift+Pfeil unten aus dem Viewport laufen.
            lastFrame = activeRect'''
if old not in src:
    raise SystemExit(
        f"{path}: Scroll-Auswahlpfad hat sich geaendert — Patch 4r pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
  SELECTION_SCROLL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Pixelreserve fuer die aktive Auswahlkante' \
    "$CETV_SCROLL_SELECTION" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Shift-Auswahl vollständig sichtbar)"
  chmod u+w "$CETV_SCROLL_SELECTION"
  /usr/bin/python3 - "$CETV_SCROLL_SELECTION" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''            if lastFrame != .zero {
                scrollView.contentView.scrollToVisible(lastFrame)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }'''
new = '''            if lastFrame != .zero {
                // Fastra-Patch: Pixelreserve fuer die aktive Auswahlkante.
                // AppKit rundet den Scrollursprung auf Geraetepixel; ohne
                // Reserve kann ein Bruchteil eines Punkts unsichtbar bleiben.
                let scrollTarget = lastFrame.insetBy(dx: 0, dy: -1)
                scrollView.contentView.scrollToVisible(scrollTarget)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }'''
if old not in src:
    raise SystemExit(
        f"{path}: Pixelreserve fuer Scroll-Auswahl hat sich geaendert — Patch 4r pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
  SELECTION_SCROLL_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: verzoegerter Scroll-Abgleich fuer Auswahlen' \
    "$CETV_MOVE_SELECTION" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Shift-Auswahl nach Layout nachführen)"
  chmod u+w "$CETV_MOVE_SELECTION"
  /usr/bin/python3 - "$CETV_MOVE_SELECTION" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''    fileprivate func updateAfterMove() {
        unmarkTextIfNeeded()
        scrollSelectionToVisible()
    }'''
new = '''    fileprivate func updateAfterMove() {
        unmarkTextIfNeeded()
        scrollSelectionToVisible()
        // Fastra-Patch: verzoegerter Scroll-Abgleich fuer Auswahlen. In langen
        // Soft-Wrap-Dokumenten kann der erste Aufruf noch mit geschaetzten
        // Zeilenhoehen arbeiten. Nach dem aktuellen Runloop ist der neue
        // Bereich ausgelegt; dann die aktive Kante nochmals sichtbar machen.
        guard selectionManager.textSelections.contains(where: {
            !$0.range.isEmpty
        }) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollSelectionToVisible()
        }
    }'''
if old not in src:
    raise SystemExit(
        f"{path}: Bewegungs-Abgleich hat sich geaendert — Patch 4r pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
# VORHER ersetzten Bereich. Upstream verwendet diesen Bereich aber nicht nur
# zum Entfernen alter Zeilen, sondern auch nach dem Einfuegen zur Layout-
# Invalidierung. Bei einer reinen Einfuegung ist er leer; an Zeilen- und
# Fragmentgrenzen kann dadurch eine andere Zeile getroffen werden. Die
# logische Zeilenlaenge ist dann neu, ihre alten Soft-Wrap-Fragmente bleiben
# aber bestehen: Der angehaengte Text wird gezeichnet, besitzt jedoch keine
# Trefferflaeche. Entfernen arbeitet weiter mit dem alten Bereich, nach dem
# Aufbau wird dagegen der von NSTextStorage gelieferte NEUE Bereich
# invalidiert. Bei Loeschungen bleibt `editedRange` leer; CodeEdits bestehender
# Leerbereichspfad markiert die Zeile am Editierpunkt bzw. die letzte Zeile.
CETV_EDITS="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Edits.swift"
TEXT_EDIT_LAYOUT_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: neuen Editierbereich invalidieren' \
    "$CETV_EDITS" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Text-Einfügung invalidiert neue Fragmente)"
  chmod u+w "$CETV_EDITS"
  /usr/bin/python3 - "$CETV_EDITS" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let insertedStringRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        removeLayoutLinesIn(range: insertedStringRange)
        insertNewLines(for: editedRange)

        attachments.textUpdated(atOffset: editedRange.location, delta: delta)

        invalidateLayoutForRange(insertedStringRange)'''
new = '''        let replacedStringRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        removeLayoutLinesIn(range: replacedStringRange)
        insertNewLines(for: editedRange)

        attachments.textUpdated(atOffset: editedRange.location, delta: delta)

        // Fastra-Patch: neuen Editierbereich invalidieren. Der zuvor ersetzte
        // Bereich ist bei reinen Einfuegungen leer und kann nach dem Umbau der
        // Zeilenstruktur auf die falschen alten Fragmente zeigen.
        invalidateLayoutForRange(editedRange)'''
if old not in src:
    raise SystemExit(
        f"{path}: Editierbereichs-Invalidierung hat sich geaendert — Patch 4s pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
# `MinimapView.hitTest` prüft `isHidden` NICHT und beantwortet Treffer im
# eigenen sichtbaren Bereich immer selbst; `mouseDown`/`mouseDragged` sind
# bewusst leere Überschreibungen („Eat mouse events“). AppKits Default-hitTest
# würde eine verborgene View selbst aussortieren — genau dieser Default ist
# hier aber überschrieben. Folge (Befund 2026-07-24): Bei ausgeblendeter
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
  /usr/bin/python3 - "$CESE_MINIMAP" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let point = superview?.convert(point, to: self) else { return nil }'''
new = '''    override public func hitTest(_ point: NSPoint) -> NSView? {
        // Fastra-Patch: verborgene Minimap darf keine Klicks schlucken.
        // Diese Überschreibung ersetzt AppKits Default-hitTest, der hidden
        // Views selbst aussortieren würde; ohne diese Prüfung fängt die
        // unsichtbare Minimap alle Klicks am rechten Editorrand ab.
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        guard let point = superview?.convert(point, to: self) else { return nil }'''
if old not in src:
    raise SystemExit(
        f"{path}: MinimapView.hitTest hat sich geaendert — Patch 4t pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
  /usr/bin/python3 - "$CETV_SELMGR" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''    public func setSelectedRange(_ range: NSRange) {
        textSelections.forEach { $0.view?.removeFromSuperview() }'''
new = '''    public func setSelectedRange(_ range: NSRange) {
        // Fastra-Patch: ungueltigen Bereich abweisen — dieselbe Pruefung wie
        // in setSelectedRanges. Ein {NSNotFound, 0} aus veraltetem State
        // wanderte sonst in die Selektion; der Attachment-Beobachter baut
        // daraus ein IndexSet und trappt (IndexSet.insert mit NSNotFound).
        // Die bestehende Auswahl bleibt in dem Fall unveraendert stehen.
        let fastraLimit = textStorage?.length ?? 0
        guard range.location != NSNotFound,
              (0...fastraLimit).contains(range.location),
              (0...fastraLimit).contains(range.max) else {
            return
        }
        textSelections.forEach { $0.view?.removeFromSuperview() }'''
if old not in src:
    raise SystemExit(f"{path}: setSelectedRange hat sich geaendert — Patch 4t-2 pruefen")
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
# rechte Hälfte eines Zeichens liefert den Offset DANACH. Für den einfachen
# Klick ist das korrektes Caret-Verhalten. Beim Doppelklick führt es aber
# dazu, dass ein Klick auf die rechte Hälfte des LETZTEN Zeichens eines
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
  /usr/bin/python3 - "$CETV_MOUSE" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
pristine = '''    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        selectWord(nil)
    }'''
# Vorgaengerfassung dieses Patches (rueckte um genau EINE UTF-16-Einheit
# zurueck — bei Emoji/kombinierenden Zeichen mitten in den Cluster).
previous = '''    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle.
        // `textOffsetAtPoint` rundet als Einfuege-Position auf; ein Klick auf
        // die rechte Haelfte des letzten Wortzeichens landet dadurch auf dem
        // Folgezeichen und wuerde dessen Leerraum markieren. Liegt der
        // Klickpunkt tatsaechlich in der Zelle des Vorgaengerzeichens, wird
        // die Auswahlbasis dorthin verschoben (NSTextView-Verhalten).
        let clickPoint = convert(event.locationInWindow, from: nil)
        if let caretOffset = layoutManager.textOffsetAtPoint(clickPoint),
           caretOffset > 0,
           let previousRect = layoutManager.rectForOffset(caretOffset - 1),
           previousRect.contains(clickPoint) {
            selectionManager.setSelectedRange(
                NSRange(location: caretOffset - 1, length: 0)
            )
        }
        selectWord(nil)
    }'''
new = '''    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle (zusammengesetzt).
        // `textOffsetAtPoint` rundet als Einfuege-Position auf; ein Klick auf
        // die rechte Haelfte des letzten Wortzeichens landet dadurch auf dem
        // Folgezeichen und wuerde dessen Leerraum markieren. Das
        // Vorgaengerzeichen kann aus MEHREREN UTF-16-Einheiten bestehen
        // (Emoji, kombinierende Akzente) — die Auswahlbasis rueckt deshalb an
        // den ANFANG seiner zusammengesetzten Sequenz, nie mitten hinein
        // (Review 2026-08-02).
        let clickPoint = convert(event.locationInWindow, from: nil)
        if let caretOffset = layoutManager.textOffsetAtPoint(clickPoint),
           caretOffset > 0 {
            let previousStart = (string as NSString)
                .rangeOfComposedCharacterSequence(at: caretOffset - 1).location
            if let previousRect = layoutManager.rectForOffset(previousStart),
               previousRect.contains(clickPoint) {
                selectionManager.setSelectedRange(
                    NSRange(location: previousStart, length: 0)
                )
            }
        }
        selectWord(nil)
    }'''
interim_head = """        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle —
        // zusammengesetzte Sequenz."""
if pristine in src:
    src = src.replace(pristine, new, 1)
elif previous in src:
    src = src.replace(previous, new, 1)
elif interim_head in src:
    # Zwischenstand mit umbrochenem Marker: nur den Kommentarkopf auf die
    # einzeilige, grep-bare Form heben — der Code selbst ist bereits richtig.
    src = src.replace(interim_head,
        """        // Fastra-Patch: Wortauswahl trifft die geklickte Zeichenzelle (zusammengesetzt).
        // Hinweis: siehe Patch 4u in build.sh.""", 1)
else:
    raise SystemExit(
        f"{path}: handleDoubleClick hat sich geaendert — Patch 4u pruefen"
    )
open(path, "w").write(src)
PYEOF
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

# 4v. CodeEditTextView — Drag-Anker am Maus-Down verankern.
#
# Upstream setzt `mouseDragAnchor` erst beim ERSTEN Drag-Ereignis. Schnelle
# Mausbewegungen liefern grob gerasterte Events: Das erste Drag-Ereignis kann
# bereits weit vom Klickpunkt entfernt liegen — unterhalb des Fensters wird
# es sogar auf das Dokumentende geklemmt. Die Auswahl beginnt dann nicht am
# angeklickten Zeichen, sondern irgendwo auf dem Weg (Befund 2026-07-24 im
# dragscroll-Selbsttest: Klick bei Offset 10, Auswahl begann bei 2040).
CETV_MOUSE_ANCHOR="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextView/TextView+Mouse.swift"
DRAG_ANCHOR_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Drag-Anker am Maus-Down verankern' \
    "$CETV_MOUSE_ANCHOR" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (Drag-Anker am Maus-Down)"
  chmod u+w "$CETV_MOUSE_ANCHOR"
  /usr/bin/python3 - "$CETV_MOUSE_ANCHOR" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)'''
new = '''        // Fastra-Patch: Drag-Anker am Maus-Down verankern. Upstream setzt
        // ihn erst beim ersten Drag-Ereignis; bei schnellen Bewegungen liegt
        // das bereits weit vom Klickpunkt entfernt (unterhalb des Fensters
        // nach dem Clamping sogar am Dokumentende), und die Auswahl beginnt
        // an der falschen Stelle.
        let anchorInView = self.convert(event.locationInWindow, from: nil)
        mouseDragAnchor = CGPoint(
            x: max(layoutManager.edgeInsets.left, min(anchorInView.x, frame.width)),
            y: max(0.0, min(anchorInView.y, frame.height))
        )

        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)'''
if old not in src:
    raise SystemExit(
        f"{path}: mouseDown hat sich geaendert — Patch 4v pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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

# 4w. CodeEditTextView — rectForOffset darf bei veraltetem Zeilen-Storage
# nicht crashen.
#
# Waehrend Undo/Redo schrumpft der Text, der Zeilen-Storage des Layout-
# Managers hinkt einen Moment hinterher. Ein in dieses Fenster fallender
# Scroll (macOS-„Concurrent Scrolling“-Synchronizer) positioniert die noch
# nicht geclampte Cursor-Selektion neu und fragt `rectForOffset` mit einem
# Offset HINTER dem neuen Textende. `rangeOfComposedCharacterSequence(at:)`
# wirft dann eine NSRangeException → Abort (Daniel-Befund 2026-07-24,
# Crash nach ⌘V + ⌘Z). Der Patch clampt ehrlich: Offsets ausserhalb des
# echten Storage liefern ein 0-breites Rechteck statt eines Absturzes.
# Regressionstest: TextLayoutManagerStaleOffsetTests.
CETV_RECT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Public.swift"
RECT_STALE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Offset gegen den ECHTEN Storage clampen' \
    "$CETV_RECT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (rectForOffset crash-fest bei Undo-Fenster)"
  chmod u+w "$CETV_RECT"
  /usr/bin/python3 - "$CETV_RECT" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let realRange = if textStorage?.length == 0 {
            NSRange(location: offset, length: 0)
        } else if let string = textStorage?.string as? NSString {
            string.rangeOfComposedCharacterSequence(at: offset)
        } else {
            NSRange(location: offset, length: 0)
        }'''
new = '''        // Fastra-Patch: Offset gegen den ECHTEN Storage clampen. Waehrend
        // Undo/Redo kann der Zeilen-Storage kurz laenger sein als der schon
        // geschrumpfte Text; ein zwischengeschobener Scroll fragt dann eine
        // veraltete Cursorposition ab und rangeOfComposedCharacterSequence
        // wirft eine NSRangeException (Crash, Daniel-Befund 2026-07-24).
        let realRange = if textStorage?.length == 0 {
            NSRange(location: offset, length: 0)
        } else if let string = textStorage?.string as? NSString,
                  offset < string.length {
            string.rangeOfComposedCharacterSequence(at: offset)
        } else {
            NSRange(location: offset, length: 0)
        }'''
if old not in src:
    raise SystemExit(
        f"{path}: rectForOffset-Struktur hat sich geaendert — Patch 4w pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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

# 4x. CodeEditSourceEditor — Scroll-Reconcile des SwiftUI-States deaktivieren.
#
# `updateControllerWithState` scrollt bei jedem SwiftUI-Update auf
# `state.scrollPosition`, sobald sie von der echten ClipView-Position
# abweicht. Der Rueckschreiber des Coordinators laeuft aber via
# `receive(on: RunLoop.main)` erst im NAECHSTEN Runloop. Loest ein
# Tastendruck neben dem Tipp-Scroll ein weiteres SwiftUI-Update aus (bei
# Fastra: Fusszeile mit Zeile/Spalte), gewinnt der Reconcile mit der
# veralteten Position: Der frische Scroll wird zurueckgedreht, der Cursor
# verschwindet unter dem Fensterrand (Daniel-Befund 2026-07-24, F.23).
# Fastra setzt nie ein externes Scroll-Soll ueber den State (Spruenge
# laufen ueber convergeScroll) — der Zweig wird deshalb deaktiviert.
CESE_SOURCE_EDITOR="$CHECKOUTS/CodeEditSourceEditor/Sources/CodeEditSourceEditor/SourceEditor/SourceEditor.swift"
SCROLL_RECONCILE_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Scroll-Reconcile deaktiviert' \
    "$CESE_SOURCE_EDITOR" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Scroll-Reconcile des States aus)"
  chmod u+w "$CESE_SOURCE_EDITOR"
  /usr/bin/python3 - "$CESE_SOURCE_EDITOR" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let scrollView = controller.scrollView
        if let scrollPosition = state.scrollPosition, scrollPosition != scrollView?.contentView.bounds.origin {'''
new = '''        let scrollView = controller.scrollView
        // Fastra-Patch: Scroll-Reconcile deaktiviert. `state.scrollPosition`
        // ist wegen des Runloop-versetzten Rueckschreibers praktisch immer
        // einen Schritt alt; der Vergleich unten drehte deshalb frische
        // Tipp-Scrolls zurueck (Cursor verschwand unter dem Fensterrand).
        // Fastra steuert Scrollen ausschliesslich selbst.
        if false, let scrollPosition = state.scrollPosition, scrollPosition != scrollView?.contentView.bounds.origin {'''
if old not in src:
    raise SystemExit(
        f"{path}: Scroll-Reconcile-Struktur hat sich geaendert — Patch 4x pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
# dass es die AKTUELLE Fassung ist. Ein Checkout mit der alten Fassung wird
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
  /usr/bin/python3 - "$CETV_SELECTION_DRAW" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old_loop = '''        var highlightedLines: Set<TextLine.ID> = []
        // For each selection in the rect
        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                drawHighlightedLine(
                    in: rect,
                    for: textSelection,
                    context: context,
                    highlightedLines: &highlightedLines
                )
            } else {
                drawSelectedRange(in: rect, for: textSelection, context: context)
            }
        }'''
new_loop = '''        var highlightedLines: Set<TextLine.ID> = []
        // Fastra-Patch: aktuelle Zeile bleibt auch bei Textauswahl sichtbar.
        // Mehrfach-Cursor markieren weiterhin alle Cursorzeilen; sobald echte
        // Selektionen existieren, markiert nur deren primaere/letzte Range
        // genau eine aktive Zeile (wichtig fuer Rechteckauswahl).
        for offset in fastraHighlightedLineOffsets {
            drawHighlightedLine(
                in: rect,
                at: offset,
                context: context,
                highlightedLines: &highlightedLines
            )
        }
        for textSelection in textSelections where !textSelection.range.isEmpty {
            drawSelectedRange(in: rect, for: textSelection, context: context)
        }'''
old_signature = '''    private func drawHighlightedLine(
        in rect: NSRect,
        for textSelection: TextSelection,
        context: CGContext,
        highlightedLines: inout Set<TextLine.ID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(textSelection.range.location),'''
new_signature = '''    private func drawHighlightedLine(
        in rect: NSRect,
        at offset: Int,
        context: CGContext,
        highlightedLines: inout Set<TextLine.ID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(offset),'''
if old_loop not in src or old_signature not in src:
    raise SystemExit(
        f"{path}: Auswahl-Zeichenstruktur hat sich geaendert — Patch 4y pruefen"
    )
src = src.replace(old_loop, new_loop, 1).replace(old_signature, new_signature, 1)

anchor = '''extension TextSelectionManager {
    /// Draws line backgrounds and selection rects for each selection in the given rect.'''
replacement = '''extension TextSelectionManager {
    /// Offsets der Zeilen, die als aktuelle Zeile gezeichnet werden. Leere
    /// Mehrfach-Cursor behalten je eine Zeile. Bei echter Auswahl gibt es
    /// genau eine aktive Zeile; sonst ist die letzte Range die primaere.
    /// `pivot` bezeichnet den festen Anker, daher ist das jeweils andere
    /// Range-Ende die aktive Kante.
    public var fastraHighlightedLineOffsets: [Int] {
        let selections = textSelections.filter { !$0.range.isEmpty }
        guard let primary = selections.last else {
            return textSelections.map { $0.range.location }
        }
        // Eine Rechteckauswahl kennt ihre aktive Kopfzeile selbst. Ihre
        // Zeilenbereiche entstehen immer von oben nach unten, bei einem nach
        // oben gezogenen Rechteck ist die Kopfzeile also die ERSTE Range.
        // Ohne diese Nachfrage leuchtete dort die unterste Zeile.
        if let head = textView?.fastraColumnSelectionHeadOffset {
            return [head]
        }
        guard let pivot = primary.pivot else {
            return [primary.range.location]
        }
        return [pivot == primary.range.location ? primary.range.max : primary.range.location]
    }

    /// Draws line backgrounds and selection rects for each selection in the given rect.'''
if anchor not in src:
    raise SystemExit(f"{path}: Extension-Anker fehlt — Patch 4y pruefen")
src = src.replace(anchor, replacement, 1)
open(path, "w").write(src)
PYEOF
  CURRENT_LINE_SELECTION_PATCH_CHANGED=1
fi

if ! grep -q 'Fastra-Patch: Gutter folgt derselben aktiven Auswahlzeile' \
    "$CESE_GUTTER" 2>/dev/null; then
  echo "→ Patche CodeEditSourceEditor (Gutter-Zeile auch bei Auswahl)"
  chmod u+w "$CESE_GUTTER"
  /usr/bin/python3 - "$CESE_GUTTER" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        for selection in selectionManager.textSelections where selection.range.isEmpty {
            guard let line = textView.layoutManager.textLineForOffset(selection.range.location),
                  visibleRange.intersection(line.range) != nil || selection.range.location == textView.length,
                  !highlightedLines.contains(line.data.id) else {'''
new = '''        // Fastra-Patch: Gutter folgt derselben aktiven Auswahlzeile
        // wie die Textflaeche; Rechteck-/Mehrzeilenauswahl faerbt nie jede
        // betroffene Zeile als aktuelle Zeile ein.
        for offset in selectionManager.fastraHighlightedLineOffsets {
            guard let line = textView.layoutManager.textLineForOffset(offset),
                  visibleRange.intersection(line.range) != nil || offset == textView.length,
                  !highlightedLines.contains(line.data.id) else {'''
if old not in src:
    raise SystemExit(
        f"{path}: Gutter-Auswahlstruktur hat sich geaendert — Patch 4y pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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

# 4z. CodeEditTextView — TextLine.prepareForDisplay darf bei veralteter
# Zeilen-Range nicht crashen.
#
# Waehrend einer Undo-Klammer beschreibt lineStorage noch den ALTEN (laengeren)
# Text. Loest in diesem Fenster ein reentranter Scroll-Callback ein Layout aus
# (scrollSelectionToVisible → synchroner Bounds-Beobachter → layoutLines),
# reicht layoutLine eine Range aus dem veralteten lineStorage an
# `stringRef.attributedSubstring(from:)` weiter, die ueber das aktuelle
# Textende hinausreicht — NSRangeException, SIGABRT (belegt im Dauertest,
# Crash-Report 2026-08-09, nach ~1600 Aktionen). Der Patch clampt die Range
# ehrlich gegen das echte Textende; bleibt nichts uebrig, kehrt die Funktion
# ohne Typeset zurueck und meldet die Zeile erneut layoutbeduerftig — der
# naechste Layout-Lauf arbeitet dann mit nachgezogenem lineStorage.
# Regressionstest: TextLinePrepareForDisplayClampTests.
CETV_TEXTLINE="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLine/TextLine.swift"
TEXTLINE_CLAMP_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: Zeilen-Range gegen das aktuelle Textende clampen' \
    "$CETV_TEXTLINE" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (prepareForDisplay crash-fest bei Undo-Fenster)"
  chmod u+w "$CETV_TEXTLINE"
  /usr/bin/python3 - "$CETV_TEXTLINE" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        let string = stringRef.attributedSubstring(from: range)
        let maxWidth = typesetter.typeset(
            string,
            documentRange: range,'''
new = '''        // Fastra-Patch: Zeilen-Range gegen das aktuelle Textende clampen.
        // Waehrend einer Undo-Klammer beschreibt lineStorage noch den alten
        // Text; ein reentranter Scroll-Callback (scrollSelectionToVisible ->
        // synchroner Bounds-Beobachter -> layoutLines) layoutet dann gegen
        // den schon kuerzeren Speicher. Ungeklemmt wirft attributedSubstring
        // eine NSRangeException und die App bricht mit SIGABRT ab (belegt im
        // Dauertest, Crash-Report 2026-08-09). Liegt die Zeile ganz hinter
        // dem Textende, kehren wir ohne Typeset zurueck; setNeedsLayout()
        // loescht die alten Fragmente und der naechste Layout-Lauf arbeitet
        // mit nachgezogenem lineStorage.
        let clampedLocation = min(range.location, stringRef.length)
        let clampedRange = NSRange(
            location: clampedLocation,
            length: min(range.length, stringRef.length - clampedLocation)
        )
        if clampedRange != range && clampedRange.length == 0 {
            setNeedsLayout()
            return
        }
        let string = stringRef.attributedSubstring(from: clampedRange)
        let maxWidth = typesetter.typeset(
            string,
            documentRange: clampedRange,'''
if old not in src:
    raise SystemExit(
        f"{path}: prepareForDisplay-Struktur hat sich geaendert — Patch 4z pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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

# 4z1. CodeEditTextView — layoutLines nicht gegen inkonsistente Zwischenstaende
# laufen lassen.
#
# Der vorgesehene Schutz `guard !isInTransaction` in layoutLines ist TOT:
# `transactionCounter` wird nirgends im Paket erhoeht (per grep verifiziert
# 2026-08-09), `isInTransaction` ist damit immer false. Genau das Fenster, das
# er abschirmen sollte — lineStorage beschreibt waehrend einer Undo-Klammer
# noch den alten Text — erreicht layoutLines deshalb ungebremst (siehe 4z).
# Ersatz: ein billiger Laengenvergleich. Weicht lineStorage.length vom echten
# textStorage.length ab, ist der Zustand mitten in einer Mutation; dann kein
# Layout — der naechste Durchlauf laeuft mit nachgezogenem lineStorage.
CETV_LAYOUT="$CHECKOUTS/CodeEditTextView/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager+Layout.swift"
LAYOUT_CONSISTENCY_PATCH_CHANGED=0
if ! grep -q 'Fastra-Patch: toter Transaktionsschutz durch Laengenvergleich ersetzt' \
    "$CETV_LAYOUT" 2>/dev/null; then
  echo "→ Patche CodeEditTextView (layoutLines: Konsistenz-Ausstieg statt totem Transaktionsschutz)"
  chmod u+w "$CETV_LAYOUT"
  /usr/bin/python3 - "$CETV_LAYOUT" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage else {
            return []
        }'''
new = '''        // Fastra-Patch: toter Transaktionsschutz durch Laengenvergleich ersetzt.
        // `isInTransaction` ist immer false (transactionCounter wird nirgends
        // erhoeht). Weicht die Laenge des Zeilen-Storage vom echten Text ab
        // (Undo-Klammer, reentranter Scroll-Callback), layouten wir NICHT
        // gegen den inkonsistenten Zwischenstand — der naechste Durchlauf
        // laeuft mit nachgezogenem lineStorage (Dauertest-Befund 2026-08-09).
        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage,
              lineStorage.length == textStorage.length else {
            return []
        }'''
if old not in src:
    raise SystemExit(
        f"{path}: layoutLines-Guard hat sich geaendert — Patch 4z1 pruefen"
    )
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
  /usr/bin/python3 - "$CESE_TEXT_FORMATION" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old = '''        switch language.id {
        case .python:
            return TextualIndenter(patterns: TextualIndenter.pythonPatterns)'''
new = '''        switch language.id {
        case .plainText, .markdown:
            // Fastra-Patch: Markdown verwendet keine Code-Klammermuster;
            // dasselbe gilt fuer echten Fliesstext.
            // Eine leere unmittelbare Vorzeile ist zudem ein bewusster
            // Einrueckungs-Reset und darf nicht uebersprungen werden.
            return TextualIndenter(patterns: [], referenceLinePredicate: { _, _ in true })
        case .python:
            return TextualIndenter(patterns: TextualIndenter.pythonPatterns)'''
if old not in src:
    raise SystemExit(f"{path}: Indenter-Switch hat sich geaendert — Patch 4z2 pruefen")
open(path, "w").write(src.replace(old, new, 1))
PYEOF
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
  /usr/bin/python3 - "$CETV_DRAG" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path).read()
old_entered = '''    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        determineDragOperation(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        determineDragOperation(sender)
    }'''
new_entered = '''    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Fastra-Patch: externer Drop wird vor dem Standard-Textdrag geroutet.
        fastraExternalDraggingUpdated(sender) ?? determineDragOperation(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fastraExternalDraggingUpdated(sender) ?? determineDragOperation(sender)
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fastraCleanUpExternalDrop()
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        fastraCleanUpExternalDrop()
    }'''
old_perform = '''    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: pasteboardObjects)?'''
new_perform = '''    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let externalResult = fastraPerformExternalDrop(sender) {
            return externalResult
        }
        guard let objects = sender.draggingPasteboard.readObjects(forClasses: pasteboardObjects)?'''
if old_entered not in src or old_perform not in src:
    raise SystemExit(f"{path}: Drag-Zielstruktur hat sich geaendert — Patch 4z3 pruefen")
src = src.replace(old_entered, new_entered, 1).replace(old_perform, new_perform, 1)
open(path, "w").write(src)
PYEOF
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
# echte Viewport-Punkte. Das eigentliche Langzeilen-Layout schuetzt Fastra im
# Produktcode, indem Soft Wrap fuer solche Dokumente automatisch aus bleibt.
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
  /usr/bin/python3 - "$CETV_TEXT_VIEW_LAYOUT" "$CETV_LAYOUT_MANAGER" \
    "$CETV_TYPESETTER" "$CETV_FRAGMENT_RENDERER" \
    "$CESE_VISIBLE_RANGE_PROVIDER" "$CESE_HIGHLIGHTER" \
    "$CESE_LIFECYCLE" "$CESE_LONG_LINE_APPEARANCE" <<'PYEOF'
import sys

(
    view_path,
    manager_path,
    typesetter_path,
    renderer_path,
    provider_path,
    highlighter_path,
    lifecycle_path,
    appearance_path,
) = sys.argv[1:]
view = open(view_path).read()
manager = open(manager_path).read()
typesetter = open(typesetter_path).read()
renderer = open(renderer_path).read()
provider = open(provider_path).read()
highlighter = open(highlighter_path).read()
lifecycle = open(lifecycle_path).read()
appearance = open(appearance_path).read()

old_visible = '''    public var visibleTextRange: NSRange? {
        let minY = max(visibleRect.minY, 0)
        let maxY = min(visibleRect.maxY, layoutManager.estimatedHeight())
        guard let minYLine = layoutManager.textLineForPosition(minY),
              let maxYLine = layoutManager.textLineForPosition(maxY) else {
            return nil
        }
        return NSRange(
            location: minYLine.range.location,
            length: (maxYLine.range.location - minYLine.range.location) + maxYLine.range.length
        )
    }'''
new_visible = '''    // Fastra-Patch: mehrere sichtbare Textbereiche pro Viewport.
    // Ein Rechteck ueber mehreren ungebrochenen Zeilen ist kein einzelner
    // Textbereich: Dazwischen koennen horizontal unsichtbare Megazeilen liegen.
    // Der Highlighter erhaelt deshalb eine Range je sichtbarer logischer Zeile.
    public var visibleTextRanges: [NSRange] {
        let minY = max(visibleRect.minY, 0)
        let maxY = min(visibleRect.maxY, layoutManager.estimatedHeight())
        let leftX = max(visibleRect.minX, layoutManager.edgeInsets.left)
        let rightX = max(visibleRect.maxX, leftX)

        return layoutManager.visibleLines().map { line in
            let lineTop = max(minY, line.yPos)
            let lineBottom = max(
                lineTop,
                min(maxY, line.yPos + line.height) - 0.5
            )
            if let first = layoutManager.textOffsetAtPoint(
                CGPoint(x: leftX, y: lineTop)
            ), let last = layoutManager.textOffsetAtPoint(
                CGPoint(x: rightX, y: lineBottom)
            ) {
                let start = min(first, last)
                let end = max(first, last)
                return NSRange(
                    start: start,
                    end: min(end + 1, documentRange.max)
                )
            }
            // Vor dem ersten Layout ist die genaue Geometrie noch nicht da.
            // Ein kleiner Zeilenanfang ist dann die sichere obere Grenze.
            return NSRange(
                location: line.range.location,
                length: min(line.range.length, 16 * 1024)
            )
        }
    }

    public var visibleTextRange: NSRange? {
        let ranges = visibleTextRanges
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return NSRange(start: first.location, end: last.max)
    }'''
old_markers = [
    "        // Fastra-Patch: sichtbaren Bereich auf Umbruchfragmente begrenzen.",
    "        // Fastra-Patch: sichtbaren Bereich horizontal und vertikal begrenzen.",
]
old_marker = next((marker for marker in old_markers if marker in view), None)
if old_marker:
    start = view.index(old_marker)
    function_start = view.rfind("    public var visibleTextRange: NSRange? {", 0, start)
    function_end = view.index("\n    public func updatedViewport", start)
    view = view[:function_start] + new_visible + "\n" + view[function_end:]
elif "Fastra-Patch: mehrere sichtbare Textbereiche pro Viewport" not in view:
    if old_visible not in view:
        raise SystemExit(
            f"{view_path}: visibleTextRange hat sich geaendert — Patch 4z4 pruefen"
        )
    view = view.replace(old_visible, new_visible, 1)

old_provider_lazy = '''    lazy var visibleSet: IndexSet = {
        return IndexSet(integersIn: textView?.visibleTextRange ?? NSRange())
    }()'''
new_provider_lazy = '''    lazy var visibleSet: IndexSet = {
        // Fastra-Patch: getrennte sichtbare Bereiche beibehalten.
        // Ein umschliessender NSRange wuerde horizontal unsichtbare
        // Megazeilen zwischen zwei kurzen Zeilen wieder voll aufnehmen.
        var result = IndexSet()
        for range in textView?.visibleTextRanges ?? [] {
            result.insert(integersIn: range.location..<range.max)
        }
        return result
    }()'''
if "Fastra-Patch: getrennte sichtbare Bereiche beibehalten" not in provider:
    if old_provider_lazy not in provider:
        raise SystemExit(
            f"{provider_path}: visibleSet-Initialisierung hat sich geaendert — Patch 4z4 pruefen"
        )
    provider = provider.replace(old_provider_lazy, new_provider_lazy, 1)

old_provider_update = '''        guard let textViewVisibleRange = textView?.visibleTextRange else {
            return
        }
        var visibleSet = IndexSet(integersIn: textViewVisibleRange)'''
new_provider_update = '''        guard let textView else { return }
        var visibleSet = IndexSet()
        for range in textView.visibleTextRanges {
            visibleSet.insert(integersIn: range.location..<range.max)
        }'''
if old_provider_update in provider:
    provider = provider.replace(old_provider_update, new_provider_update, 1)

old_clear = '''        textView.textStorage.setAttributes(
            attributeProvider?.attributesFor(nil) ?? [:],
            range: NSRange(location: 0, length: textView.textStorage.length)
        )'''
new_clear = '''        // Fastra-Patch: nur sichtbare Altattribute synchron entfernen.
        // `setAttributes` ueber eine 4,36-MB-Zeile invalidierte das komplette
        // Editorlayout und blockierte den naechsten UI-Turn mehrere Sekunden.
        // Unsichtbare Bereiche werden beim Scrollen ohnehin neu angefragt.
        for range in visibleRangeProvider.visibleSet.rangeView {
            textView.textStorage.setAttributes(
                attributeProvider?.attributesFor(nil) ?? [:],
                range: NSRange(range)
            )
        }'''
if "Fastra-Patch: nur sichtbare Altattribute synchron entfernen" not in highlighter:
    if old_clear not in highlighter:
        raise SystemExit(
            f"{highlighter_path}: Sprachwechsel-Reset hat sich geaendert — Patch 4z4 pruefen"
        )
    highlighter = highlighter.replace(old_clear, new_clear, 1)

old_manager_insets = '''    public var edgeInsets: HorizontalEdgeInsets = .zero {
        didSet {
            delegate?.layoutManagerMaxWidthDidChange(newWidth: maxLineWidth + edgeInsets.horizontal)
            setNeedsLayout()
        }
    }'''
new_manager_insets = '''    public var edgeInsets: HorizontalEdgeInsets = .zero {
        didSet {
            // Fastra-Patch: vor dem Einhaengen in eine ScrollView keine
            // Frame-Aktualisierung erzwingen. Der Controller setzt Insets
            // bewusst vor `documentView`; danach folgt genau ein Frame-Update.
            if layoutView?.superview != nil {
                delegate?.layoutManagerMaxWidthDidChange(newWidth: maxLineWidth + edgeInsets.horizontal)
            }
            setNeedsLayout()
        }
    }'''
if "Fastra-Patch: vor dem Einhaengen in eine ScrollView" not in manager:
    if old_manager_insets not in manager:
        raise SystemExit(
            f"{manager_path}: edgeInsets hat sich geaendert — Patch 4z4 pruefen"
        )
    manager = manager.replace(old_manager_insets, new_manager_insets, 1)

if "Fastra-Patch: ungebrochene Megazeilen in handliche CoreText-" not in typesetter:
    old_header = '''        let substring = string.attributedSubstring(from: range)

        // Layout as many fragments as possible in this content run'''
    new_header = '''        let substring = string.attributedSubstring(from: range)
        let isUnwrapped = displayData.maxWidth == .greatestFiniteMagnitude
        let plainSubstring = substring.string as NSString

        // Layout as many fragments as possible in this content run'''
    old_break = '''            let lineBreak = typesetter.suggestLineBreak(
                using: substring,
                strategy: displayData.breakStrategy,
                subrange: NSRange(start: context.currentPosition - range.location, end: range.length),
                constrainingWidth: displayData.maxWidth - context.fragmentContext.width
            )'''
    new_break = '''            let relativeStart = context.currentPosition - range.location
            // Fastra-Patch: ungebrochene Megazeilen in handliche CoreText-
            // Segmente zerlegen, aber in EINEM visuellen Fragment behalten.
            // Ein einzelnes CTLine ueber 4,36 MB blockierte den UI-Thread
            // sekundenlang; die Segmentgrenze ist kein sichtbarer Umbruch.
            let lineBreak = if isUnwrapped {
                unwrappedSegmentEnd(
                    in: plainSubstring,
                    start: relativeStart,
                    limit: 16 * 1024
                )
            } else {
                typesetter.suggestLineBreak(
                    using: substring,
                    strategy: displayData.breakStrategy,
                    subrange: NSRange(start: relativeStart, end: range.length),
                    constrainingWidth: displayData.maxWidth - context.fragmentContext.width
                )
            }'''
    old_relative_start = '''            let relativeStart = context.currentPosition - range.location
            let typesetSubrange = NSRange('''
    new_relative_start = '''            let typesetSubrange = NSRange('''
    old_pop = '''            if context.currentPosition != range.max {
                context.popCurrentData()
            }
        }
    }

    // MARK: - Typeset CTLines'''
    new_pop = '''            if context.currentPosition != range.max && !isUnwrapped {
                context.popCurrentData()
            }
        }
    }

    /// Trennt niemals mitten in einem zusammengesetzten Unicode-Zeichen.
    /// Die Grenze ist nur eine interne CoreText-Portion und kein Zeilenumbruch.
    private func unwrappedSegmentEnd(
        in string: NSString,
        start: Int,
        limit: Int
    ) -> Int {
        let proposedEnd = min(start + limit, string.length)
        guard proposedEnd < string.length else { return string.length }
        let cluster = string.rangeOfComposedCharacterSequence(at: proposedEnd)
        return cluster.location > start ? cluster.location : cluster.max
    }

    // MARK: - Typeset CTLines'''
    for old, new, label in [
        (old_header, new_header, "Typesetter-Kopf"),
        (old_relative_start, new_relative_start, "Typesetter-Range"),
        (old_break, new_break, "Typesetter-Umbruch"),
        (old_pop, new_pop, "Typesetter-Abschluss"),
    ]:
        if old not in typesetter:
            raise SystemExit(
                f"{typesetter_path}: {label} hat sich geaendert — Patch 4z4 pruefen"
            )
        typesetter = typesetter.replace(old, new, 1)

old_renderer_loop = '''        var currentPosition: CGFloat = 0.0
        var currentLocation = 0
        for content in lineFragment.contents {
            context.saveGState()
            switch content.data {
            case .text(let ctLine):
                context.textPosition = CGPoint(
                    x: currentPosition,
                    y: yPos + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
                ).pixelAligned
                CTLineDraw(ctLine, context)

                drawInvisibles(
                    lineFragment: lineFragment,
                    for: ctLine,
                    contentOffset: currentLocation,
                    position: CGPoint(x: currentPosition, y: yPos),
                    in: context
                )
            case .attachment(let attachment):
                attachment.attachment.draw(
                    in: context,
                    rect: NSRect(
                        x: currentPosition,
                        y: yPos + (lineFragment.heightDifference/2),
                        width: attachment.width,
                        height: lineFragment.height
                    )
                )
            }
            context.restoreGState()
            currentPosition += content.width
            currentLocation += content.length
        }'''
new_renderer_loop = '''        var currentPosition: CGFloat = 0.0
        var currentLocation = 0
        let visibleX = context.boundingBoxOfClipPath
        for content in lineFragment.contents {
            let contentMaxX = currentPosition + content.width
            // Fastra-Patch: interne Segmente ungebrochener Megazeilen nur
            // zeichnen, wenn sie den echten Grafik-Ausschnitt schneiden.
            if visibleX.isNull
                || (contentMaxX >= visibleX.minX && currentPosition <= visibleX.maxX) {
                context.saveGState()
                switch content.data {
                case .text(let ctLine):
                    context.textPosition = CGPoint(
                        x: currentPosition,
                        y: yPos + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
                    ).pixelAligned
                    CTLineDraw(ctLine, context)

                    drawInvisibles(
                        lineFragment: lineFragment,
                        for: ctLine,
                        contentOffset: currentLocation,
                        position: CGPoint(x: currentPosition, y: yPos),
                        in: context
                    )
                case .attachment(let attachment):
                    attachment.attachment.draw(
                        in: context,
                        rect: NSRect(
                            x: currentPosition,
                            y: yPos + (lineFragment.heightDifference/2),
                            width: attachment.width,
                            height: lineFragment.height
                        )
                    )
                }
                context.restoreGState()
            }
            currentPosition += content.width
            currentLocation += content.length
        }'''
old_invisible_range = '''    private func createTextRange(for drawingContext: InvisibleDrawingContext) -> NSRange {
        return NSRange(
            start: drawingContext.lineFragment.documentRange.location + drawingContext.contentOffset,
            end: drawingContext.lineFragment.documentRange.max
        )
    }'''
new_invisible_range = '''    private func createTextRange(for drawingContext: InvisibleDrawingContext) -> NSRange {
        let lineRange = CTLineGetStringRange(drawingContext.ctLine)
        return NSRange(
            location: drawingContext.lineFragment.documentRange.location
                + drawingContext.contentOffset,
            length: lineRange.length
        )
    }'''
if "Fastra-Patch: interne Segmente ungebrochener Megazeilen nur" not in renderer:
    for old, new, label in [
        (old_renderer_loop, new_renderer_loop, "Fragment-Zeichnung"),
        (old_invisible_range, new_invisible_range, "Invisible-Range"),
    ]:
        if old not in renderer:
            raise SystemExit(
                f"{renderer_path}: {label} hat sich geaendert — Patch 4z4 pruefen"
            )
        renderer = renderer.replace(old, new, 1)

if "Fastra-Patch: Anfangskonfiguration noch ohne angehaengtes" not in lifecycle:
    old_document_attach = '''        scrollView = NSScrollView()
        scrollView.documentView = textView'''
    new_document_attach = '''        scrollView = NSScrollView()'''
    old_lifecycle_tail = '''        setUpConstraints()
        setUpOberservers()

        textView.updateFrameIfNeeded()

        if let localEventMonitor = self.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        setUpKeyBindings(eventMonitor: &self.localEventMonitor)
        updateContentInsets()

        configuration.didSetOnController(controller: self, oldConfig: nil)'''
    new_lifecycle_tail = '''        setUpConstraints()
        setUpOberservers()

        // Fastra-Patch: Anfangskonfiguration noch ohne angehaengtes
        // Dokument anwenden. Insets und unveraenderte Startwerte loesten
        // sonst bei einer 4,36-MB-Zeile mehrere volle synchrone Layouts aus.
        configuration.didSetOnController(controller: self, oldConfig: nil)
        scrollView.documentView = textView
        textView.updateFrameIfNeeded()

        if let localEventMonitor = self.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        setUpKeyBindings(eventMonitor: &self.localEventMonitor)'''
    for old, new, label in [
        (old_document_attach, new_document_attach, "Document-Anhaengen"),
        (old_lifecycle_tail, new_lifecycle_tail, "Controller-Startreihenfolge"),
    ]:
        if old not in lifecycle:
            raise SystemExit(
                f"{lifecycle_path}: {label} hat sich geaendert — Patch 4z4 pruefen"
            )
        lifecycle = lifecycle.replace(old, new, 1)

if "Fastra-Patch: beim ersten Aufbau keine identischen Textattribute" not in appearance:
    old_theme_call = '''                updateControllerNewTheme(controller: controller)
                needsHighlighterInvalidation = true'''
    new_theme_call = '''                updateControllerNewTheme(
                    controller: controller,
                    updateExistingTextAttributes: oldConfig != nil
                )
                needsHighlighterInvalidation = true'''
    old_theme_function = '''        private func updateControllerNewTheme(controller: TextViewController) {
            controller.textView.layoutManager.setNeedsLayout()
            controller.textView.textStorage.setAttributes(
                controller.attributesFor(nil),
                range: NSRange(location: 0, length: controller.textView.textStorage.length)
            )'''
    new_theme_function = '''        private func updateControllerNewTheme(
            controller: TextViewController,
            updateExistingTextAttributes: Bool
        ) {
            controller.textView.layoutManager.setNeedsLayout()
            // Fastra-Patch: beim ersten Aufbau keine identischen Textattribute
            // erneut ueber das gesamte Dokument schreiben. TextView erhielt
            // Schrift und Farbe bereits im Initializer; auf einer 4,36-MB-
            // Zeile kostete dieses Wiederholen rund zehn Sekunden.
            if updateExistingTextAttributes {
                controller.textView.textStorage.setAttributes(
                    controller.attributesFor(nil),
                    range: NSRange(location: 0, length: controller.textView.textStorage.length)
                )
            }'''
    for old, new, label in [
        (old_theme_call, new_theme_call, "Theme-Aufruf"),
        (old_theme_function, new_theme_function, "Theme-Startattribute"),
        ("            if oldConfig?.wrapLines != wrapLines {",
         "            if let oldConfig, oldConfig.wrapLines != wrapLines {",
         "Initialer Soft-Wrap-Abgleich"),
        ("            if needsHighlighterInvalidation {\n                controller.highlighter?.invalidate()",
         "            if needsHighlighterInvalidation, oldConfig != nil {\n                controller.highlighter?.invalidate()",
         "Initiale Highlighter-Invalidierung"),
    ]:
        if old not in appearance:
            raise SystemExit(
                f"{appearance_path}: {label} hat sich geaendert — Patch 4z4 pruefen"
            )
        appearance = appearance.replace(old, new, 1)

open(view_path, "w").write(view)
open(manager_path, "w").write(manager)
open(typesetter_path, "w").write(typesetter)
open(renderer_path, "w").write(renderer)
open(provider_path, "w").write(provider)
open(highlighter_path, "w").write(highlighter)
open(lifecycle_path, "w").write(lifecycle)
open(appearance_path, "w").write(appearance)
PYEOF
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

# 5. Build-Cache invalidieren, sonst greift SPM auf das alte Plugin-Manifest zu
rm -f .build/build.db .build/plugin-tools.yaml .build/release.yaml

# 5b. Fenster-Zielwahl prüfen — VOR dem Kompilieren, weil es ein reiner
# Quelltext-Check ist und in Sekunden abbricht, statt den Fehler erst nach
# Minuten Bauzeit zu zeigen. Der Wächter verhindert die Rückkehr eines
# Fehlers, der die Anwendung unbenutzbar macht: ein Befehl, der im falschen
# Fenster wirkt (Fehlerbericht 2026-08-07). Begründung im Skript selbst.
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
#
# `sign-bundle.sh` strippt vor dem Signieren die Debug-Map. Für ein
# Debug-Bundle wäre das falsch — genau diese Symbole braucht lldb, und die
# Zeile oben sagt ausdrücklich, dass Debug sie behält. Deshalb bekommt nur der
# Release-Build den strippenden Aufruf (Review 2026-08-06).
if [ "$CONFIG" = "release" ]; then
  ./sign-bundle.sh "$APP" -
else
  ./sign-bundle.sh "$APP" - --keep-debug-symbols
fi

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

echo
echo "✔ Fertig. App-Bundle: $APP"
echo "  Kopie zum Doppelklicken: $(cd .. && pwd)/Fastra.app ($CONFIG)"
echo "  Nicht installiert: /Applications ist notarisierten Builds vorbehalten."
echo "  Start mit: open $(cd .. && pwd)/Fastra.app"
