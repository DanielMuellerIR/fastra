#!/usr/bin/env python3
"""Reproduzierbarer Folgefragment-Kern; jede Ersetzung prüft ihren Zielzustand."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / 'Sources/CodeEditTextView'
changed = False


def replace(relative, old, new):
    global changed
    path = root / relative
    source = path.read_text()
    if new not in source:
        if source.count(old) != 1:
            raise SystemExit(f'{relative}: Soft-Wrap-Einrückung passt nicht zur Quelle')
        path.chmod(path.stat().st_mode | 0o200)
        source = source.replace(old, new, 1)
        path.write_text(source)
        changed = True
    if source.count(new) != 1:
        raise SystemExit(f'{relative}: Soft-Wrap-Einrückung unvollständig')


helper = root / 'TextLine/SoftWrapIndentation.swift'
expected = pathlib.Path(__file__).with_name('SoftWrapIndentation.swift').read_text()
if not helper.exists() or helper.read_text() != expected:
    if helper.exists():
        helper.chmod(helper.stat().st_mode | 0o200)
    helper.write_text(expected)
    changed = True
if helper.read_text() != expected:
    raise SystemExit('Soft-Wrap-Geometriekern wurde nicht übernommen')

replace('TextLine/LineFragment.swift', '    public var width: CGFloat\n', '''    /// Ursprung relativ zum allgemeinen Text-Inset; Zeichenpositionen bleiben lokal.
    public var xOffset: CGFloat = 0
    public var width: CGFloat
''')
replace('TextLayoutManager/TextLayoutManager.swift', '    public var detectedLineEnding:', '''    // Der normale Editor aktiviert das Profil erst mit der Bedienintegration.
    public var softWrapIndentation: SoftWrapIndentation = .flushLeft {
        didSet { if oldValue != softWrapIndentation { setNeedsLayout() } }
    }
    public var softWrapIndentationColumns: Int = 4 {
        didSet { if oldValue != softWrapIndentationColumns { setNeedsLayout() } }
    }
    public func fragmentOriginX(for fragment: LineFragment) -> CGFloat {
        edgeInsets.left + fragment.xOffset
    }
    public var detectedLineEnding:''')
replace('TextLine/TextLine.swift', '    var maxWidth: CGFloat?\n', '''    var maxWidth: CGFloat?
    private var lastSoftWrapIndentation: SoftWrapIndentation = .flushLeft
    private var lastSoftWrapIndentationColumns: Int = 4
''')
replace('TextLine/TextLine.swift', '    func needsLayout(maxWidth: CGFloat) -> Bool {',
        '''    func needsLayout(maxWidth: CGFloat, softWrapIndentation: SoftWrapIndentation = .flushLeft,
                     softWrapIndentationColumns: Int = 4) -> Bool {''')
replace('TextLine/TextLine.swift', '        return needsLayout\n', '''        return needsLayout
            || lastSoftWrapIndentation != softWrapIndentation
            || lastSoftWrapIndentationColumns != softWrapIndentationColumns
''')
replace('TextLine/TextLine.swift', '        self.maxWidth = displayData.maxWidth\n', '''        self.maxWidth = displayData.maxWidth
        lastSoftWrapIndentation = displayData.softWrapIndentation
        lastSoftWrapIndentationColumns = displayData.softWrapIndentationColumns
''')
replace('TextLayoutManager/TextLayoutManager+Layout.swift',
        '        if line.needsLayout(maxWidth: layoutData.maxWidth) {',
        '''        if line.needsLayout(maxWidth: layoutData.maxWidth,
                            softWrapIndentation: softWrapIndentation,
                            softWrapIndentationColumns: softWrapIndentationColumns) {''')
replace('TextLayoutManager/TextLayoutManager+Layout.swift',
        'linePosition.data.needsLayout(maxWidth: maxLineLayoutWidth)',
        '''linePosition.data.needsLayout(maxWidth: maxLineLayoutWidth,
                                             softWrapIndentation: softWrapIndentation,
                                             softWrapIndentationColumns: softWrapIndentationColumns)''')
replace('TextLine/TextLine.swift', '        public let breakStrategy: LineBreakStrategy\n', '''        public let breakStrategy: LineBreakStrategy
        public let softWrapIndentation: SoftWrapIndentation
        public let softWrapIndentationColumns: Int
''')
replace('TextLine/TextLine.swift', '            breakStrategy: LineBreakStrategy = .character\n', '''            breakStrategy: LineBreakStrategy = .character,
            softWrapIndentation: SoftWrapIndentation = .flushLeft,
            softWrapIndentationColumns: Int = 4
''')
replace('TextLine/TextLine.swift', '            self.breakStrategy = breakStrategy\n', '''            self.breakStrategy = breakStrategy
            self.softWrapIndentation = softWrapIndentation
            self.softWrapIndentationColumns = softWrapIndentationColumns
''')
replace('TextLayoutManager/TextLayoutManager+Layout.swift', '            breakStrategy: lineBreakStrategy\n', '''            breakStrategy: lineBreakStrategy,
            softWrapIndentation: softWrapIndentation,
            softWrapIndentationColumns: softWrapIndentationColumns
''')
replace('TextLine/Typesetter/TypesetContext.swift', '    let fragmentGeneration: UUID\n', '''    let fragmentGeneration: UUID
    let continuationOffset: CGFloat

    var fragmentOffset: CGFloat { lines.isEmpty ? 0 : continuationOffset }
    var availableWidth: CGFloat { max(displayData.maxWidth - fragmentOffset, 1) }
''')
replace('TextLine/Typesetter/TypesetContext.swift', '        if fragmentContext.width + attachment.width > displayData.maxWidth {', '''        if !fragmentContext.contents.isEmpty,
           fragmentContext.width + attachment.width > availableWidth {''')
replace('TextLine/Typesetter/TypesetContext.swift', '        lines.append(\n', '''        fragment.xOffset = fragmentOffset
        lines.append(
''')
replace('TextLine/Typesetter/TypesetContext.swift', '    mutating func popCurrentData() {\n', '''    mutating func popCurrentData() {
        guard !fragmentContext.contents.isEmpty else { return }
''')
replace('TextLine/Typesetter/Typesetter.swift', '        if string.length == 0 || displayData.maxWidth <= 0 {', '        if string.length == 0 {')
replace('TextLine/Typesetter/Typesetter.swift', '            fragmentGeneration: fragmentGeneration\n', '''            fragmentGeneration: fragmentGeneration,
            continuationOffset: SoftWrapFragmentGeometry.continuationOffset(
                in: string, maxWidth: displayData.maxWidth,
                mode: displayData.softWrapIndentation,
                indentationColumns: displayData.softWrapIndentationColumns
            )
''')
replace('TextLine/Typesetter/Typesetter.swift', '                    constrainingWidth: displayData.maxWidth - context.fragmentContext.width', '                    constrainingWidth: context.availableWidth - context.fragmentContext.width')
replace('TextLine/Typesetter/Typesetter.swift', '            if lineBreak == 1 && context.fragmentContext.width + typesetData.width > displayData.maxWidth {', '''            // Ein zu breites erstes Graphem muss trotzdem Fortschritt machen.
            if !context.fragmentContext.contents.isEmpty,
               context.fragmentContext.width + typesetData.width > context.availableWidth {''')
replace('TextLayoutManager/TextLayoutManager+Layout.swift', '            width = max(width, lineFragment.width)', '            width = max(width, lineFragment.xOffset + lineFragment.width)')
replace('TextLayoutManager/TextLayoutManager+Layout.swift', '        view.frame.origin = CGPoint(x: edgeInsets.left, y: yPos)', '        view.frame.origin = CGPoint(x: fragmentOriginX(for: lineFragment.data), y: yPos)')
replace('TextLayoutManager/TextLayoutManager+Layout.swift', '            view.frame.origin = CGPoint(x: edgeInsets.left, y: position.yPos + lineFragmentPosition.yPos)', '            view.frame.origin = CGPoint(x: fragmentOriginX(for: lineFragmentPosition.data), y: position.yPos + lineFragmentPosition.yPos)')
replace('TextLayoutManager/TextLayoutManager+Public.swift', '''        } else if fragment.width <= point.x - edgeInsets.left {''', '''        } else if point.x <= fragmentOriginX(for: fragment) {
            return linePosition.range.location + fragmentPosition.range.location
        } else if fragment.width <= point.x - fragmentOriginX(for: fragment) {''')
replace('TextLayoutManager/TextLayoutManager+Public.swift', 'fragment.findContent(atX: xPos - edgeInsets.left)', 'fragment.findContent(atX: xPos - fragmentOriginX(for: fragment))')
replace('TextLayoutManager/TextLayoutManager+Public.swift', 'CGPoint(x: xPos - edgeInsets.left - contentPosition.xPos, y: fragment.height/2)', 'CGPoint(x: xPos - fragmentOriginX(for: fragment) - contentPosition.xPos, y: fragment.height/2)')
replace('TextLayoutManager/TextLayoutManager+Public.swift', '            x: minXPos + edgeInsets.left,', '            x: minXPos + fragmentOriginX(for: fragmentPosition.data),')
replace('TextLayoutManager/TextLayoutManager+Public.swift', '                    x: fragmentRect.minX + edgeInsets.left,', '                    x: fragmentRect.minX + fragmentOriginX(for: fragmentPosition.data),')
replace('TextLayoutManager/TextLayoutManager+Public.swift',
        '            let fragmentRect = characterRect(in: fragmentPosition.data, for: intersectingRange)',
        '''            let fragmentRange = intersectingRange.translate(location: -fragmentPosition.range.location)
            let fragmentRect = characterRect(in: fragmentPosition.data, for: fragmentRange)''')
replace('Extensions/CTTypesetter+SuggestLineBreak.swift',
        '        guard breakIndex < string.length else {',
        '''        // Vor der CRLF-Probe muss der äußere Graphem-Fallback erreichbar sein.
        guard breakIndex > startingOffset, breakIndex < string.length else {''')
replace('TextView/DraggingTextRenderer.swift', '            renderer.draw(lineFragment: fragment.data, in: context, yPos: fragmentYPos)', '''            context.saveGState()
            context.translateBy(x: fragment.data.xOffset, y: 0)
            renderer.draw(lineFragment: fragment.data, in: context, yPos: fragmentYPos)
            context.restoreGState()''')
# Die Masken bleiben in lokalen Drag-View-Koordinaten. Zeichenoffsets sind fragmentlokal.
replace('TextView/DraggingTextRenderer.swift', '''                let relativeOffset = selectedRange.lowerBound - line.range.lowerBound
                let selectionXPos = layoutManager.characterXPosition(in: fragment.data, for: relativeOffset)''', '''                let relativeOffset = selectedRange.lowerBound - fragmentRange.lowerBound
                let selectionXPos = fragment.data.xOffset
                    + layoutManager.characterXPosition(in: fragment.data, for: relativeOffset)''')
replace('TextView/DraggingTextRenderer.swift', '''                let relativeOffset = selectedRange.upperBound - line.range.lowerBound
                let selectionXPos = layoutManager.characterXPosition(in: fragment.data, for: relativeOffset)''', '''                let relativeOffset = selectedRange.upperBound - fragmentRange.lowerBound
                let selectionXPos = fragment.data.xOffset
                    + layoutManager.characterXPosition(in: fragment.data, for: relativeOffset)''')
# Der vorherige Patch kopiert die versionierte Rechteckquelle; auch diesen Verbraucher prüfen.
column = (root / 'TextView/TextView+ColumnSelection.swift').read_text()
if 'layoutManager.fragmentOriginX(for: fragment.data)' not in column:
    raise SystemExit('Rechteckauswahl nutzt nicht den gemeinsamen Fragmentursprung')
print('changed' if changed else 'verified')
