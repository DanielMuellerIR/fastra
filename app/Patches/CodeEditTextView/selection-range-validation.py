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
