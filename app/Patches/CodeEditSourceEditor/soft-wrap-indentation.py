#!/usr/bin/env python3
"""Profil-Reconcile und Minimap teilen den Folgefragmentkern."""
import pathlib
import sys
root = pathlib.Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor'
changed = False

def replace(relative, old, new):
    global changed
    path = root / relative
    source = path.read_text()
    if new not in source:
        if source.count(old) != 1:
            raise SystemExit(f'{relative}: Einrückungsintegration passt nicht zur Quelle')
        path.chmod(path.stat().st_mode | 0o200)
        source = source.replace(old, new, 1)
        path.write_text(source)
        changed = True
    if source.count(new) != 1:
        raise SystemExit(f'{relative}: Einrückungsintegration unvollständig')

behavior = 'SourceEditorConfiguration/SourceEditorConfiguration+Behavior.swift'
replace(behavior, 'extension SourceEditorConfiguration {', 'import CodeEditTextView\n\nextension SourceEditorConfiguration {')
replace(behavior, '        public var wrapAtColumn: Int?\n', '''        public var wrapAtColumn: Int?
        public var softWrapIndentation: SoftWrapIndentation
        public var softWrapIndentationColumns: Int
''')
replace(behavior, '            wrapAtColumn: Int? = nil\n', '''            wrapAtColumn: Int? = nil,
            softWrapIndentation: SoftWrapIndentation = .flushLeft,
            softWrapIndentationColumns: Int = 4
''')
replace(behavior, '            self.wrapAtColumn = wrapAtColumn\n', '''            self.wrapAtColumn = wrapAtColumn
            self.softWrapIndentation = softWrapIndentation
            self.softWrapIndentationColumns = softWrapIndentationColumns
''')
replace(behavior, '            if oldConfig?.wrapAtColumn != wrapAtColumn {', '''            if oldConfig?.softWrapIndentation != softWrapIndentation
                || oldConfig?.softWrapIndentationColumns != softWrapIndentationColumns {
                controller.textView.layoutManager.softWrapIndentation = softWrapIndentation
                controller.textView.layoutManager.softWrapIndentationColumns = softWrapIndentationColumns
                controller.minimapView.synchronizeFastraFragmentGeometry()
                controller.textView.needsLayout = true
            }

            if oldConfig?.wrapAtColumn != wrapAtColumn {''')
replace('Minimap/MinimapView.swift', '''    var editorToMinimapWidthRatio: CGFloat {
        3.0 / (textView?.font.charWidth ?? 3.0)
    }''', '''    var editorToMinimapWidthRatio: CGFloat {
        lineRenderer.fastraHorizontalScale
    }

    // Der zweite Layoutmanager muss auch bei unsichtbarer Minimap die neue
    // Cache-Signatur kennen. Ausgelegt wird weiterhin erst beim Einblenden.
    public func synchronizeFastraFragmentGeometry() {
        guard let editor = textView?.layoutManager, let layoutManager else { return }
        let changed = layoutManager.softWrapIndentation != editor.softWrapIndentation
            || layoutManager.softWrapIndentationColumns != editor.softWrapIndentationColumns
            || layoutManager.lineBreakStrategy != editor.lineBreakStrategy
            || layoutManager.wrapLines != editor.wrapLines
        guard changed else { return }
        layoutManager.softWrapIndentation = editor.softWrapIndentation
        layoutManager.softWrapIndentationColumns = editor.softWrapIndentationColumns
        layoutManager.lineBreakStrategy = editor.lineBreakStrategy
        layoutManager.wrapLines = editor.wrapLines
        contentView.needsLayout = true
    }''')
replace('Minimap/MinimapContentView.swift', '        layoutManager?.layoutLines()', '''        (superview?.superview?.superview as? MinimapView)?.synchronizeFastraFragmentGeometry()
        layoutManager?.layoutLines()''')
# Renderer stellt die Signatur auch unmittelbar vor dem eigenen Typeset sicher.
replace('Minimap/MinimapLineRenderer.swift', '    func prepareForDisplay(', '''    var fastraHorizontalScale: CGFloat {
        guard let textView else { return 1 }
        let space = NSAttributedString(string: " ", attributes: textView.typingAttributes)
        let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
        return 1.5 / max(width, 1)
    }

    func prepareForDisplay(''')
replace('Minimap/MinimapLineRenderer.swift', '''            displayData: TextLine.DisplayData(maxWidth: maxWidth, lineHeightMultiplier: 1.0, estimatedLineHeight: 3.0),''', '''            displayData: TextLine.DisplayData(
                maxWidth: maxWidth, lineHeightMultiplier: 1.0, estimatedLineHeight: 3.0,
                breakStrategy: textView?.layoutManager.lineBreakStrategy ?? .character,
                softWrapIndentation: textView?.layoutManager.softWrapIndentation ?? .flushLeft,
                softWrapIndentationColumns: textView?.layoutManager.softWrapIndentationColumns ?? 4
            ),''')
replace('Minimap/MinimapLineRenderer.swift', '            fragmentPosition.data.height = 2.0', '''            // Die Nutzlast bleibt in Editorpunkten; nur Miniatur-Ursprung und
            // Ausdehnung werden skaliert. So stimmen Tabs und Graphemgrenzen.
            fragmentPosition.data.xOffset *= fastraHorizontalScale
            fragmentPosition.data.width *= fastraHorizontalScale
            fragmentPosition.data.height = 2.0''')
replace('Minimap/MinimapLineRenderer.swift', '        MinimapLineFragmentView(textStorage: textView?.textStorage)', '        MinimapLineFragmentView(textView: textView)')
renderer_position = '''        // Die exklusive Endposition enthält bereits die Miniaturskalierung.
        if offset >= lineFragment.documentRange.length { return 8 + lineFragment.width }
        return 8 + (textView?.layoutManager.characterXPosition(in: lineFragment, for: offset) ?? 0)
            * fastraHorizontalScale'''
legacy_renderer_position = '''        8 + (textView?.layoutManager.characterXPosition(in: lineFragment, for: offset) ?? 0)
            * fastraHorizontalScale'''
renderer = 'Minimap/MinimapLineRenderer.swift'
if legacy_renderer_position in (root / renderer).read_text():
    replace(renderer, legacy_renderer_position, renderer_position)
replace(renderer, '''        // Offset is relative to the whole line, the CTLine is too.
        guard let content = lineFragment.contents.first else { return 0.0 }
        switch content.data {
        case .text(let ctLine):
            return 8 + (CGFloat(offset - CTLineGetStringRange(ctLine).location) * 1.5)
        case .attachment:
            return 0.0
        }''', renderer_position)
mini = 'Minimap/MinimapLineFragmentView.swift'
replace(mini, '        let range: NSRange\n', '        let rect: CGRect\n')
replace(mini, '    private weak var textStorage: NSTextStorage?\n', '''    private weak var textStorage: NSTextStorage?
    private weak var textView: TextView?
''')
replace(mini, '''    init(textStorage: NSTextStorage?) {
        self.textStorage = textStorage''', '''    init(textView: TextView?) {
        self.textView = textView
        self.textStorage = textView?.textStorage''')
replace(mini, '''                range: NSRange(
                    location: range.location - fragmentRange.location,
                    length: range.length
                )''', '''                rect: fastraRunRect(range: range, fragmentRange: fragmentRange)''')
run_rect = '''    func fastraRunRect(range: NSRange, fragmentRange: NSRange) -> CGRect {
        guard let textView, let fragment = lineFragment else { return .zero }
        let space = NSAttributedString(string: " ", attributes: textView.typingAttributes)
        let cell = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
        let scale = 1.5 / max(cell, 1)
        func miniatureX(at offset: Int) -> CGFloat {
            // Am exklusiven Ende liefert LineFragment bereits seine skalierte
            // Breite. Nur Positionen innerhalb der CoreText-Nutzlast skalieren.
            if offset >= fragmentRange.length { return fragment.width }
            return textView.layoutManager.characterXPosition(in: fragment, for: offset) * scale
        }
        let lower = miniatureX(at: range.location - fragmentRange.location)
        let upper = miniatureX(at: range.max - fragmentRange.location)
        return CGRect(x: 8 + lower, y: 0.25, width: max(upper - lower, 0), height: 2)
    }

'''
legacy_run_rect = '''    private func fastraRunRect(range: NSRange, fragmentRange: NSRange) -> CGRect {
        guard let textView, let fragment = lineFragment else { return .zero }
        let space = NSAttributedString(string: " ", attributes: textView.typingAttributes)
        let cell = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
        let scale = 1.5 / max(cell, 1)
        let lower = textView.layoutManager.characterXPosition(in: fragment, for: range.location - fragmentRange.location)
        let upper = textView.layoutManager.characterXPosition(in: fragment, for: range.max - fragmentRange.location)
        return CGRect(x: 8 + lower * scale, y: 0.25, width: max(upper - lower, 0) * scale, height: 2)
    }

'''
# Bereits gepatchte Checkouts auf dieselbe Geometrie bringen wie frische.
if legacy_run_rect in (root / mini).read_text():
    replace(mini, legacy_run_rect, run_rect)
replace(mini, '    /// Draw our cached drawing runs in the current graphics context.',
        run_rect + '    /// Draw our cached drawing runs in the current graphics context.')
replace(mini, '''            let rect = CGRect(
                x: 8 + (CGFloat(run.range.location) * 1.5),
                y: 0.25,
                width: CGFloat(run.range.length) * 1.5,
                height: 2.0
            )''', '            let rect = run.rect')
replace('ReformattingGuide/ReformattingGuideView.swift',
        '        reformattingGuideView?.updatePosition(in: self)\n        textView.updateFrameIfNeeded()',
        '''        reformattingGuideView?.updatePosition(in: self)
        minimapView.synchronizeFastraFragmentGeometry()
        minimapView.layoutManager?.setNeedsLayout()
        minimapView.contentView.needsLayout = true
        textView.updateFrameIfNeeded()''')
helper = root / 'Minimap/MinimapView+FastraVerticalGeometry.swift'
expected = pathlib.Path(__file__).with_name(helper.name).read_text()
if not helper.exists() or helper.read_text() != expected:
    if helper.exists():
        helper.chmod(helper.stat().st_mode | 0o200)
    helper.write_text(expected)
    changed = True
if helper.read_text() != expected:
    raise SystemExit('Vertikale Minimap-Geometrie wurde nicht übernommen')
replace('Minimap/MinimapView+DocumentVisibleView.swift',
        '    func updateDocumentVisibleViewPosition() {',
        '''    func updateDocumentVisibleViewPosition() {
        guard !isHiddenOrHasHiddenAncestor else { return }''')
replace('Minimap/MinimapView+DocumentVisibleView.swift',
        '        let availableHeight = min(minimapHeight, containerHeight)',
        '''        synchronizeFastraFragmentGeometry()
        layoutManager?.layoutLines()
        if let top = fastraMinimapY(forEditorY: max(textView.visibleRect.minY, 0)),
           let bottom = fastraMinimapY(forEditorY: min(textView.visibleRect.maxY, textView.layoutManager.estimatedHeight())) {
            let height = max(bottom - top, 3)
            let offset = min(max(top - (containerHeight - height) / 2, 0),
                             max(contentView.frame.height - containerHeight, 0))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset - scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            documentVisibleView.frame = CGRect(x: documentVisibleView.frame.minX,
                y: scrollView.contentInsets.top + top - offset,
                width: documentVisibleView.frame.width, height: height)
            return
        }
        let availableHeight = min(minimapHeight, containerHeight)''')
replace('Minimap/MinimapView+DragVisibleView.swift',
        '        let editorTranslation = translation.y / ratio',
        '''        let top = textView.map { max($0.visibleRect.minY, 0) } ?? 0
        let mapped = fastraMinimapY(forEditorY: top).flatMap {
            fastraEditorY(forMinimapY: max($0 - translation.y, 0))
        }
        let editorTranslation = mapped.map { top - $0 } ?? (translation.y / ratio)''')
replace('Minimap/MinimapView+TextAttachmentManagerDelegate.swift',
        'MinimapAttachment(attachment, widthRatio: editorToMinimapWidthRatio)',
        'MinimapAttachment(attachment, widthRatio: 1)')
print('changed' if changed else 'verified')
