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
            // Segmente zerlegen, aber in einem visuellen Fragment behalten.
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
