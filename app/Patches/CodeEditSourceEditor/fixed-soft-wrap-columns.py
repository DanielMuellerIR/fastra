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
