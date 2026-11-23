import sys

(
    textline_path,
    view_path,
    provider_path,
    minimap_path,
    peripherals_path,
) = sys.argv[1:]
textline = open(textline_path).read()
view = open(view_path).read()
provider = open(provider_path).read()
minimap = open(minimap_path).read()
peripherals = open(peripherals_path).read()

def replace_once(source, old, new, path, label):
    if old not in source:
        raise SystemExit(
            f"{path}: {label} hat sich geaendert — Patch 4z6 pruefen"
        )
    return source.replace(old, new, 1)

if "Fastra-Patch: Auch der Wechsel von unendlicher Startbreite" not in textline:
    old_width_check = '''    func needsLayout(maxWidth: CGFloat) -> Bool {
        needsLayout // Force layout
        || (
            // Both max widths we're comparing are finite
            maxWidth.isFinite
            && (self.maxWidth ?? 0.0).isFinite
            && maxWidth != (self.maxWidth ?? 0.0)
        )
    }'''
    new_width_check = '''    func needsLayout(maxWidth: CGFloat) -> Bool {
        // Fastra-Patch: Auch der Wechsel von unendlicher Startbreite zur
        // echten Viewportbreite braucht ein neues Layout. Andernfalls bleibt
        // die beim Initialisieren erzeugte, mehrere Millionen Pixel breite
        // Fragment-View trotz eingeschaltetem Soft Wrap bestehen.
        guard !maxWidth.isNaN else { return needsLayout }
        let previousMaxWidth = self.maxWidth ?? 0.0
        return needsLayout
            || (!previousMaxWidth.isNaN && maxWidth != previousMaxWidth)
    }'''
    textline = replace_once(
        textline, old_width_check, new_width_check, textline_path,
        "Startbreiten-Wechsel"
    )

if "Fastra-Patch: Bei Soft Wrap liefern die Fragment-Ranges" not in view:
    old_range_query = '''            if let first = layoutManager.textOffsetAtPoint(
                CGPoint(x: leftX, y: lineTop)
            ), let last = layoutManager.textOffsetAtPoint(
                CGPoint(x: rightX, y: lineBottom)
            ) {'''
    new_range_query = '''            if layoutManager.wrapLines,
               line.data.maxWidth?.isFinite == true,
               let firstFragment = line.data.lineFragments.getLine(
                   atPosition: max(lineTop - line.yPos, 0)
               ),
               let lastFragment = line.data.lineFragments.getLine(
                   atPosition: max(lineBottom - line.yPos, 0)
               ) {
                // Fastra-Patch: Bei Soft Wrap liefern die Fragment-Ranges den
                // sichtbaren Text direkt. CoreText fuer die linke und rechte
                // Kante zu befragen ist bei einer Megazeile linear teuer und
                // geschieht sonst reentrant bei jeder Frame-Benachrichtigung.
                let rawStart = line.range.location + firstFragment.range.location
                let rawEnd = line.range.location + lastFragment.range.max
                let start = min(max(rawStart, 0), textStorage.length)
                let end = min(max(rawEnd, start), textStorage.length)
                return NSRange(start: start, end: end)
            }
            if layoutManager.wrapLines {
                // Vor dem ersten Layout besteht eine Megazeile noch aus einem
                // einzigen Fragment mit unendlicher Breite. Diese provisorische
                // Range ist NICHT sichtbar und darf weder Parser noch
                // Textspeicher fuer das ganze Dokument anwerfen.
                let location = min(max(line.range.location, 0), textStorage.length)
                let available = textStorage.length - location
                return NSRange(
                    location: location,
                    length: min(max(line.range.length, 0), min(available, 16 * 1024))
                )
            }
            if let first = layoutManager.textOffsetAtPoint(
                CGPoint(x: leftX, y: lineTop)
            ), let last = layoutManager.textOffsetAtPoint(
                CGPoint(x: rightX, y: lineBottom)
            ) {'''
    view = replace_once(
        view, old_range_query, new_range_query, view_path,
        "sichtbare Soft-Wrap-Range"
    )

old_cached_width = '               line.data.maxWidth?.isFinite == true,'
new_cached_width = '''               let cachedWidth = line.data.maxWidth,
               cachedWidth.isFinite, cachedWidth < .greatestFiniteMagnitude,
               cachedWidth == layoutManager.maxLineLayoutWidth,'''
if new_cached_width not in view:
    view = replace_once(view, old_cached_width, new_cached_width, view_path,
                        "sichtbare Bereiche nach Umbruchwechsel")

if "private func installScrollObserversIfNeeded" not in provider:
    old_properties = '''    private weak var textView: TextView?
    private weak var minimapView: MinimapView?
    weak var delegate: VisibleRangeProviderDelegate?'''
    new_properties = '''    private weak var textView: TextView?
    private weak var minimapView: MinimapView?
    private weak var observedScrollView: NSScrollView?
    weak var delegate: VisibleRangeProviderDelegate?'''
    provider = replace_once(
        provider, old_properties, new_properties, provider_path,
        "ScrollView-Speicher"
    )

    old_observers = '''        if let scrollView = textView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleTextChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleTextChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }'''
    provider = replace_once(
        provider, old_observers, "        installScrollObserversIfNeeded()",
        provider_path, "spaete Scroll-Beobachter"
    )

    old_update_start = '''    @objc func visibleTextChanged() {
        guard let textView else { return }
        var ranges = textView.visibleTextRanges'''
    new_update_start = '''    @objc func visibleTextChanged() {
        guard let textView else { return }
        installScrollObserversIfNeeded()
        var ranges = textView.visibleTextRanges'''
    provider = replace_once(
        provider, old_update_start, new_update_start, provider_path,
        "Scroll-Beobachter nachziehen"
    )

    old_clamp_comment = '''    /// Fastra-Patch: Nur echte Dokumentindizes an `IndexSet` weitergeben.'''
    new_observer_method = '''    /// Fastra haengt den TextView erst nach dem Aufbau des Highlighters in die
    /// ScrollView. Darum koennen die Scroll-Beobachter beim Initialisieren noch
    /// fehlen und muessen beim ersten Frame-Ereignis nachgezogen werden.
    private func installScrollObserversIfNeeded() {
        guard let scrollView = textView?.enclosingScrollView,
              scrollView !== observedScrollView else { return }
        if let observedScrollView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedScrollView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedScrollView.contentView
            )
        }
        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        observedScrollView = scrollView
    }

    /// Fastra-Patch: Nur echte Dokumentindizes an `IndexSet` weitergeben.'''
    provider = replace_once(
        provider, old_clamp_comment, new_observer_method, provider_path,
        "Scroll-Beobachter-Methode"
    )

if "Fastra-Patch: Eine unsichtbare Minimap darf keine zweite Kopie" not in minimap:
    old_minimap_layout = '''    override public func layout() {
        super.layout()
        layoutManager?.layoutLines()
    }'''
    new_minimap_layout = '''    override public func layout() {
        super.layout()
        // Fastra-Patch: Eine unsichtbare Minimap darf keine zweite Kopie der
        // gesamten Dokumentgeometrie berechnen. Beim Einblenden wird dieser
        // View ausdruecklich wieder als layoutbeduerftig markiert.
        guard !isHiddenOrHasHiddenAncestor else { return }
        layoutManager?.layoutLines()
    }'''
    minimap = replace_once(
        minimap, old_minimap_layout, new_minimap_layout, minimap_path,
        "verborgene Minimap"
    )

if "controller.minimapView?.contentView.needsLayout = true" not in peripherals:
    old_minimap_toggle = '''            if oldConfig?.showMinimap != showMinimap {
                controller.minimapView?.isHidden = !showMinimap
                shouldUpdateInsets = true
            }'''
    new_minimap_toggle = '''            if oldConfig?.showMinimap != showMinimap {
                controller.minimapView?.isHidden = !showMinimap
                if showMinimap {
                    controller.minimapView?.needsLayout = true
                    controller.minimapView?.contentView.needsLayout = true
                }
                shouldUpdateInsets = true
            }'''
    peripherals = replace_once(
        peripherals, old_minimap_toggle, new_minimap_toggle, peripherals_path,
        "Minimap-Wiedereinblendung"
    )

open(textline_path, "w").write(textline)
open(view_path, "w").write(view)
open(provider_path, "w").write(provider)
open(minimap_path, "w").write(minimap)
open(peripherals_path, "w").write(peripherals)
