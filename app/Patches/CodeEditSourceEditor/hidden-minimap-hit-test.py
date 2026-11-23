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
