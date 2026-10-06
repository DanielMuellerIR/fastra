import AppKit
import FastraControlProtocol

/// Eine Sitzung zeigt ausschließlich eingefrorene Texte. Sie steht außerhalb
/// der Dokument-Registry und kann deshalb keine Arbeitsdateien speichern.
@MainActor
final class ControlSnapshotWindow: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    let sessionID: UUID
    let windowID: UUID
    private(set) var documentID: UUID
    let window: NSWindow
    let textView: ReadOnlySnapshotTextView
    private let statusLabel = NSTextField(wrappingLabelWithString: L10n.string("Snapshot wird geladen…"))
    var loaded: FileLoader.LoadedFile?
    var generation = 0
    var onClose: (() -> Void)?
    var onUserSelection: (() -> Void)?
    var explanationPlayer: CodeExplanationPlayer?
    private var editorBottom: NSLayoutConstraint!
    private var editorTop: NSLayoutConstraint!
    private let filenameLabel = NSTextField(labelWithString: "")
    private var sourceName: String
    private var splitView: NSSplitView?
    private var highlighter: SnapshotSyntaxHighlighter!
    private var selectionObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var userEventMonitor: Any?
    private var applyingSelection = false

    init(sessionID: UUID, windowID: UUID, documentID: UUID, name: String) {
        self.sessionID = sessionID; self.windowID = windowID; self.documentID = documentID
        sourceName = name
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        let scroll = ReadOnlySnapshotTextView.makeScrollView(
            content: "", reason: L10n.string("Schreibgeschützter Snapshot"))
        textView = scroll.documentView as! ReadOnlySnapshotTextView
        super.init()
        window.identifier = NSUserInterfaceItemIdentifier("Fastra.ControlSnapshot.\(windowID)")
        window.title = L10n.format("Snapshot: %@", name)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 400, height: 240)
        window.delegate = self
        let label = statusLabel
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.maximumNumberOfLines = 3
        filenameLabel.stringValue = name
        filenameLabel.font = .boldSystemFont(ofSize: 12)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let root = NSView()
        root.addSubview(filenameLabel); root.addSubview(label); root.addSubview(scroll)
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            filenameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            filenameLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            filenameLabel.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        editorTop = scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8)
        editorTop.isActive = true
        editorBottom = scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        editorBottom.isActive = true
        window.contentView = root
        window.center()
        highlighter = SnapshotSyntaxHighlighter(textView: textView)
        textView.onAppearanceChange = { [weak self] in self?.highlighter?.applyColors() }
        filenameLabel.setAccessibilityIdentifier("controlSnapshotFilename")
        textView.setAccessibilityIdentifier("controlSnapshotEditor")
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applyingSelection else { return }
                self.onUserSelection?()
            }
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUserSelection?() }
        }
        textView.onUserNavigation = { [weak self] in self?.onUserSelection?() }
        userEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            for panel in [self.explanationPlayer?.view, self.explanationPlayer?.footer].compactMap({ $0 }) {
                let point = panel.convert(event.locationInWindow, from: nil)
                if event.type != .keyDown, panel.bounds.contains(point) { return event }
                if event.type == .keyDown, let responder = self.window.firstResponder as? NSView,
                   responder.isDescendant(of: panel) { return event }
            }
            MainActor.assumeIsolated { self.onUserSelection?() }
            return event
        }
    }

    func show() { window.orderFront(nil) }

    func install(_ loaded: FileLoader.LoadedFile, documentID: UUID? = nil, sourceName: String? = nil) {
        // Name und Inhalt wechseln gemeinsam; erst danach die Syntax analysieren.
        if let sourceName { setSourceName(sourceName) }
        self.loaded = loaded
        if let documentID { self.documentID = documentID }
        applyingSelection = true
        textView.string = loaded.content
        highlighter.analyze(filename: self.sourceName)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        window.contentView?.layoutSubtreeIfNeeded()
        applyingSelection = false
        statusLabel.stringValue = L10n.string("Schreibgeschützter Snapshot")
    }

    func attach(_ player: CodeExplanationPlayer) {
        explanationPlayer = player
        guard let root = window.contentView, let scroll = textView.enclosingScrollView else { return }
        editorBottom.isActive = false
        editorTop.isActive = false
        scroll.removeFromSuperview()
        scroll.translatesAutoresizingMaskIntoConstraints = true
        let split = NSSplitView()
        split.isVertical = false; split.dividerStyle = .thin; split.delegate = self
        split.setAccessibilityIdentifier("explanationSplitter")
        split.addArrangedSubview(scroll)
        let pane = NSView()
        let panel = player.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            panel.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8),
        ])
        split.addArrangedSubview(pane)
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        let footer = player.footer
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        splitView = split
        window.contentMinSize = NSSize(width: 400, height: 480)
        window.title = L10n.format("Code-Erklärung: %@", player.package.manifest.title)
        root.layoutSubtreeIfNeeded()
        split.setPosition(max(120, split.bounds.height * 0.44), ofDividerAt: 0)
    }

    private func setSourceName(_ name: String) {
        filenameLabel.stringValue = (name as NSString).lastPathComponent
        filenameLabel.toolTip = name
        guard sourceName != name else { return }
        sourceName = name
    }

    func setCodeFontSize(_ size: CGFloat) {
        highlighter?.setBaseFont(.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { max(120, proposedMinimumPosition) }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 150)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === splitView.arrangedSubviews.last
    }

    func select(_ selection: ControlSelection) {
        applyingSelection = true
        textView.setSelectedRange(selection.range)
        textView.scrollRangeToVisible(selection.range)
        applyingSelection = false
    }

    func confirms(_ selection: ControlSelection) -> Bool {
        guard let loaded else { return false }
        window.contentView?.layoutSubtreeIfNeeded()
        return textView.string == loaded.content && textView.selectedRange() == selection.range
            && selectionIsVisible(selection)
    }

    private func selectionIsVisible(_ selection: ControlSelection) -> Bool {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return false }
        layout.ensureLayout(forCharacterRange: selection.range)
        let glyphs = layout.glyphRange(forCharacterRange: selection.range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        if selection.length == 0 {
            // Die native Caret-Geometrie gilt auch für leeren Text und EOF
            // ohne Schlussumbruch; eine leere Glyphrange besitzt dort kein Rect.
            let screen = textView.firstRect(forCharacterRange: selection.range, actualRange: nil)
            rect = textView.convert(window.convertFromScreen(screen), from: nil)
        } else {
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
        }
        rect.size.width = max(rect.width, 1)
        rect.size.height = max(rect.height, 1)
        return textView.visibleRect.intersects(rect)
    }

    func showReady() { statusLabel.stringValue = L10n.string("Schreibgeschützter Snapshot") }

    func showFailure(_ failure: ControlFailure? = nil) {
        statusLabel.stringValue = switch failure?.code {
        case "sourceUnavailable": L10n.string("Snapshot-Datei ist nicht verfügbar oder überschreitet die Textgrenze.")
        case "stale": L10n.string("Snapshot-Inhalt stimmt nicht mit dem erwarteten SHA-256 überein.")
        case "invalidRange": L10n.string("Die Auswahl liegt außerhalb vollständiger Zeichen des Snapshots.")
        case "expired": L10n.string("Snapshot-Auftrag hat seine Zeitgrenze überschritten.")
        case "invalidRequest": L10n.string("Das Erklärungspaket hat ein ungültiges Format.")
        case "capacity": L10n.string("Zu viele Steuerungsaufträge oder Quellen. Bitte später erneut versuchen.")
        default: L10n.string("Snapshot-Navigation wurde abgebrochen.")
        }
    }

    static func isSnapshotWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix("Fastra.ControlSnapshot.") == true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ActiveDocumentContext.shared.activate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        onClose?()
    }

    deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let userEventMonitor { NSEvent.removeMonitor(userEventMonitor) }
    }
}
