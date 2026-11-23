import sys

gutter_path, fold_view_path, fold_draw_path = sys.argv[1:]

# Alle drei Quelldateien werden zuerst vollstaendig im Speicher
# transformiert und validiert; geschrieben wird erst ganz am Ende
# gemeinsam. Bricht eine Anker-Pruefung ab, bleibt der Checkout
# unveraendert und selbstheilend.
gutter = open(gutter_path).read()
fold_view = open(fold_view_path).read()
fold_draw = open(fold_draw_path).read()


def apply(source, probe, anchor, replacement, description):
    """Ersetzt `anchor` einmal durch `replacement`, sofern `probe` fehlt.

    `probe` macht den Schritt idempotent: Ist sein Text schon da, wurde
    dieser Teil des Patches bereits angewandt und bleibt unveraendert.
    """
    if probe in source:
        return source
    if anchor not in source:
        raise SystemExit(description)
    return source.replace(anchor, replacement, 1)


# ── GutterView ────────────────────────────────────────────────────────
flip_anchor = '''    override public var isFlipped: Bool {
        true
    }
'''
flip_replacement = '''    override public var isFlipped: Bool {
        true
    }

    // Fastra-Patch: Floating-Gutter in TextView-Koordinaten zeichnen.
    // Der Gutter ist eine geflippte, dokumenthohe Floating-View unter dem
    // ungeflippten NSScrollView. Seine lokale visibleRect ist deshalb zum
    // sichtbaren TextView-Ausschnitt gespiegelt. Die Auswahl sichtbarer
    // Zeilen muss direkt aus dem TextView kommen; nur die Zeichenposition
    // wird anschliessend in den Gutter umgerechnet.
    private var visibleLinePositionsForDrawing: [TextLineStorage<TextLine>.TextLinePosition] {
        guard let textView else { return [] }
        let visibleRect = textView.visibleRect
        return Array(
            textView.layoutManager.linesStartingAt(
                visibleRect.minY,
                until: visibleRect.maxY
            )
        )
    }

    public var visibleLineIndicesForDrawing: [Int] {
        visibleLinePositionsForDrawing.map(\\.index)
    }

    private func gutterY(forTextY yPosition: CGFloat) -> CGFloat {
        guard let textView else { return yPosition }
        return convert(NSPoint(x: 0, y: yPosition), from: textView).y
    }

    private func gutterRect(forTextRect textRect: NSRect) -> NSRect {
        guard let textView else { return textRect }
        return convert(textRect, from: textView).standardized
    }
'''
gutter = apply(
    gutter,
    'Fastra-Patch: Floating-Gutter in TextView-Koordinaten zeichnen',
    flip_anchor,
    flip_replacement,
    f"{gutter_path}: Gutter-Koordinatenanker fehlt — Patch 4z13 pruefen",
)

old_selection = '''            context.fill(
                CGRect(
                    x: xPos,
                    y: line.yPos,
                    width: width,
                    height: line.height
                ).pixelAligned
            )'''
new_selection = '''            let localLineRect = gutterRect(
                forTextRect: NSRect(
                    x: 0,
                    y: line.yPos,
                    width: 1,
                    height: line.height
                )
            )
            context.fill(
                CGRect(
                    x: xPos,
                    y: localLineRect.minY,
                    width: width,
                    height: localLineRect.height
                ).pixelAligned
            )'''
gutter = apply(
    gutter,
    'let localLineRect = gutterRect(',
    old_selection,
    new_selection,
    f"{gutter_path}: Auswahlrechteck hat sich geaendert — Patch 4z13 pruefen",
)

old_loop = '''        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for linePosition in textView.layoutManager.linesStartingAt(dirtyRect.minY, until: dirtyRect.maxY) {'''
new_loop = '''        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for linePosition in visibleLinePositionsForDrawing {'''
gutter = apply(
    gutter,
    'for linePosition in visibleLinePositionsForDrawing',
    old_loop,
    new_loop,
    f"{gutter_path}: Zeilennummern-Schleife hat sich geaendert — Patch 4z13 pruefen",
)

old_y = '''            let yPos = linePosition.yPos + ascent + (fragment?.heightDifference ?? 0)/2 + fontHeightDifference'''
new_y = '''            let textYPos = linePosition.yPos + ascent
                + (fragment?.heightDifference ?? 0)/2 + fontHeightDifference
            let yPos = gutterY(forTextY: textYPos)'''
gutter = apply(
    gutter,
    'gutterY(forTextY: textYPos)',
    old_y,
    new_y,
    f"{gutter_path}: Zeilennummern-Y hat sich geaendert — Patch 4z13 pruefen",
)

# Testhaken: Der echte Zeichenpfad protokolliert je Zeilennummer Index und
# lokale Y-Position. Regressionstests stossen ueber cacheDisplay das
# tatsaechliche Zeichnen an und pruefen das Protokoll — statt nur einer
# Vorberechnung, die den Zeichencode gar nicht durchlaeuft.
recorder_property = '''    // Fastra-Patch-Testhaken: haelt nach jedem echten Zeichenlauf fest,
    // welche Zeilennummer an welcher lokalen Y-Position gezeichnet wurde.
    public private(set) var lastDrawnLineNumbers: [(index: Int, yPosition: CGFloat)] = []

    private func gutterY(forTextY yPosition: CGFloat) -> CGFloat {'''
gutter = apply(
    gutter,
    'public private(set) var lastDrawnLineNumbers',
    '    private func gutterY(forTextY yPosition: CGFloat) -> CGFloat {',
    recorder_property,
    f"{gutter_path}: gutterY-Anker fuer Zeichenprotokoll fehlt — Patch 4z13 pruefen",
)

recorder_reset_anchor = '''        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for linePosition in visibleLinePositionsForDrawing {'''
recorder_reset = '''        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        lastDrawnLineNumbers.removeAll()
        for linePosition in visibleLinePositionsForDrawing {'''
gutter = apply(
    gutter,
    'lastDrawnLineNumbers.removeAll()',
    recorder_reset_anchor,
    recorder_reset,
    f"{gutter_path}: Schleifenanker fuer Zeichenprotokoll fehlt — Patch 4z13 pruefen",
)

recorder_append_anchor = '''            let yPos = gutterY(forTextY: textYPos)'''
recorder_append = '''            let yPos = gutterY(forTextY: textYPos)
            lastDrawnLineNumbers.append(
                (index: linePosition.index, yPosition: yPos)
            )'''
gutter = apply(
    gutter,
    'lastDrawnLineNumbers.append',
    recorder_append_anchor,
    recorder_append,
    f"{gutter_path}: Y-Anker fuer Zeichenprotokoll fehlt — Patch 4z13 pruefen",
)

# Testhaken: Klick-/Hover-Umrechnung der Faltleiste ueber den oeffentlichen
# GutterView erreichbar machen. Die Faltleisten-Klasse selbst bleibt intern:
# Waere sie public, muessten auch alle ihre AppKit-Overrides (mouseDown,
# mouseMoved, ...) public werden.
fold_probe_anchor = '''    public var visibleLineIndicesForDrawing: [Int] {'''
fold_probe_property = '''    // Fastra-Patch-Testhaken: Klick-/Hover-Umrechnung der internen
    // Faltleiste fuer Regressionstests erreichbar machen.
    public var foldRibbonVisibleRect: NSRect {
        foldingRibbon.visibleRect
    }

    public func foldRibbonTextPoint(forRibbonLocalPoint point: NSPoint) -> NSPoint? {
        foldingRibbon.textPoint(forLocalPoint: point)
    }

    public var visibleLineIndicesForDrawing: [Int] {'''
gutter = apply(
    gutter,
    'foldRibbonTextPoint(forRibbonLocalPoint',
    fold_probe_anchor,
    fold_probe_property,
    f"{gutter_path}: Anker fuer Faltleisten-Testhaken fehlt — Patch 4z13 pruefen",
)

# ── LineFoldRibbonView ────────────────────────────────────────────────
fold_flip_replacement = '''    override public var isFlipped: Bool {
        true
    }

    // Fastra-Patch: Mauspositionen der Floating-Faltleiste gehoeren in das
    // Dokumentkoordinatensystem des TextView, nicht in die lokal gespiegelte
    // Koordinate der Leiste. Regressionstests erreichen die Umrechnung ueber
    // GutterView.foldRibbonTextPoint(forRibbonLocalPoint:).
    func textPoint(forLocalPoint point: NSPoint) -> NSPoint? {
        guard let textView = model?.controller?.textView else { return nil }
        return textView.convert(point, from: self)
    }

    // Zeichencode darf seine bestehenden Dokument-Y-Werte behalten. Diese
    // Transformation bildet nur die Y-Achse auf die lokale Faltleiste ab;
    // X bleibt lokal, damit die Marker in der schmalen Leiste liegen.
    func concatenateTextYTransform(in context: CGContext) {
        guard let textView = model?.controller?.textView else { return }
        let localZero = convert(NSPoint(x: 0, y: 0), from: textView).y
        let localOne = convert(NSPoint(x: 0, y: 1), from: textView).y
        context.concatenate(
            CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: localOne - localZero,
                tx: 0,
                ty: localZero
            )
        )
    }
'''
fold_view = apply(
    fold_view,
    'func textPoint(forLocalPoint',
    flip_anchor,
    fold_flip_replacement,
    f"{fold_view_path}: Faltleisten-Koordinatenanker fehlt — Patch 4z13 pruefen",
)

old_mouse_down = '''        let clickPoint = convert(event.locationInWindow, from: nil)
        guard let layoutManager = model?.controller?.textView.layoutManager,
              event.type == .leftMouseDown,
              let lineNumber = layoutManager.textLineForPosition(clickPoint.y)?.index,'''
new_mouse_down = '''        let clickPoint = convert(event.locationInWindow, from: nil)
        guard let layoutManager = model?.controller?.textView.layoutManager,
              event.type == .leftMouseDown,
              let textPoint = textPoint(forLocalPoint: clickPoint),
              let lineNumber = layoutManager.textLineForPosition(textPoint.y)?.index,'''
fold_view = apply(
    fold_view,
    'textPoint(forLocalPoint: clickPoint)',
    old_mouse_down,
    new_mouse_down,
    f"{fold_view_path}: Faltleisten-Klick hat sich geaendert — Patch 4z13 pruefen",
)

old_mouse_move = '''        let pointInView = convert(event.locationInWindow, from: nil)
        guard let lineNumber = model?.controller?.textView.layoutManager.textLineForPosition(pointInView.y)?.index,'''
new_mouse_move = '''        let pointInView = convert(event.locationInWindow, from: nil)
        guard let textPoint = textPoint(forLocalPoint: pointInView),
              let lineNumber = model?.controller?.textView.layoutManager.textLineForPosition(textPoint.y)?.index,'''
fold_view = apply(
    fold_view,
    'textPoint(forLocalPoint: pointInView)',
    old_mouse_move,
    new_mouse_move,
    f"{fold_view_path}: Faltleisten-Hover hat sich geaendert — Patch 4z13 pruefen",
)

# ── LineFoldRibbonView+Draw ───────────────────────────────────────────
old_draw_guard = '''        guard let context = NSGraphicsContext.current?.cgContext,
              let layoutManager = model?.controller?.textView.layoutManager,
              // Find the visible lines in the rect AppKit is asking us to draw.
              let rangeStart = layoutManager.textLineForPosition(dirtyRect.minY),
              let rangeEnd = layoutManager.textLineForPosition(dirtyRect.maxY) else {
            return
        }

        context.saveGState()
        context.clip(to: dirtyRect)'''
new_draw_guard = '''        guard let context = NSGraphicsContext.current?.cgContext,
              let textView = model?.controller?.textView,
              let layoutManager = textView.layoutManager else {
            return
        }
        let visibleRect = textView.visibleRect
        let visibleLines = Array(
            layoutManager.linesStartingAt(
                visibleRect.minY,
                until: visibleRect.maxY
            )
        )
        guard let rangeStart = visibleLines.first,
              let rangeEnd = visibleLines.last else {
            return
        }

        context.saveGState()
        context.clip(to: dirtyRect)
        concatenateTextYTransform(in: context)'''
fold_draw = apply(
    fold_draw,
    'concatenateTextYTransform(in: context)',
    old_draw_guard,
    new_draw_guard,
    f"{fold_draw_path}: Faltleisten-Zeichenbereich hat sich geaendert — Patch 4z13 pruefen",
)

# Erst nach allen Validierungen schreiben — gemeinsam fuer alle drei
# Dateien, damit kein halb gepatchter Checkout zurueckbleiben kann.
open(gutter_path, "w").write(gutter)
open(fold_view_path, "w").write(fold_view)
open(fold_draw_path, "w").write(fold_draw)
