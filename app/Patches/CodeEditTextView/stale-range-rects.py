import sys

layout_path = sys.argv[1]
layout_src = open(layout_path).read()

old_rects = '''    public func rectsFor(range: NSRange) -> [CGRect] {
        return linesInRange(range).flatMap { self.rectsFor(range: range, in: $0) }
    }'''
new_rects = '''    public func rectsFor(range: NSRange) -> [CGRect] {
        // Fastra-Patch: Bereich an den echten Dokumentgrenzen kappen. Statische
        // Suchmarkierungen können nach verkürzendem Edit hinter das Ende zeigen.
        // Der Schutz gilt auch für weitere rectsFor-Aufrufer; roundedPathForRange
        // reichte trotz validRange die ursprüngliche Range weiter.
        let documentBounds = NSRange(location: 0, length: textStorage?.length ?? 0)
        guard let clamped = range.intersection(documentBounds), clamped.length > 0 else {
            return []
        }
        return linesInRange(clamped).flatMap { self.rectsFor(range: clamped, in: $0) }
    }'''
if old_rects not in layout_src:
    raise SystemExit(
        f"{layout_path}: rectsFor(range:) hat sich geaendert — Patch 4z16 pruefen"
    )
layout_src = layout_src.replace(old_rects, new_rects, 1)

open(layout_path, "w").write(layout_src)
