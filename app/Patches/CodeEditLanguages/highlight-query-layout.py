import sys
path = sys.argv[1]
src = open(path).read()
old = '''    internal func queryURL(for highlights: String = "highlights") -> URL? {
        return resourceURL?
            .appendingPathComponent("Resources/tree-sitter-\\(tsName)/\\(highlights).scm")
    }'''
new = '''    internal func queryURL(for highlights: String = "highlights") -> URL? {
        // Fastra-Patch: Query-Pfad layout-robust aufloesen. resourceURL zeigt je
        // nach Bundle-Layout auf die Bundle-Wurzel oder schon auf .../Resources —
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
