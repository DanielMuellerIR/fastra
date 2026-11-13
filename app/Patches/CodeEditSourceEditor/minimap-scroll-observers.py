#!/usr/bin/env python3
"""Minimap-Beobachter nach dem späten Einhängen des Editors sicher installieren."""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'Sources/CodeEditSourceEditor/Minimap/MinimapView.swift'
source = path.read_text()
old = '''    /// Set up listeners for relevant frame and selection updates.
    private func setUpListeners() {
        guard let editorScrollView = textView?.enclosingScrollView else { return }
        // Need to listen to:
        // - ScrollView offset changed
        // - ScrollView frame changed
        // and update the document visible box to match.
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: editorScrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            // Scroll changed
            self?.updateDocumentVisibleViewPosition()
        }

        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: editorScrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            // Frame changed
            self?.updateContentViewHeight()
            self?.updateDocumentVisibleViewPosition()
        }

        NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView?.selectionManager,
            queue: .main
        ) { [weak self] _ in
            self?.selectionManager?.setSelectedRanges(
                self?.textView?.selectionManager.textSelections.map(\\.range) ?? []
            )
        }
    }'''
new = '''    // Beim Erzeugen der Minimap ist der Editor noch nicht in der ScrollView.
    // Das erste spätere Layout installiert die Beobachter genau einmal je Quelle.
    private weak var observedEditorScrollView: NSScrollView?
    private var scrollObserverTokens: [NSObjectProtocol] = []

    private func setUpListeners() {
        guard let editorScrollView = textView?.enclosingScrollView,
              observedEditorScrollView !== editorScrollView else { return }
        for token in scrollObserverTokens { NotificationCenter.default.removeObserver(token) }
        scrollObserverTokens.removeAll()
        observedEditorScrollView = editorScrollView
        let center = NotificationCenter.default
        scrollObserverTokens.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: editorScrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateDocumentVisibleViewPosition()
            // Die Miniatur scrollt erst in updateDocumentVisibleViewPosition.
            // Danach müssen ihre neu sichtbaren Fragment-Views montiert werden.
            self.contentView.needsLayout = true
        })
        scrollObserverTokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: editorScrollView.contentView, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateContentViewHeight()
            self.updateDocumentVisibleViewPosition()
            self.contentView.needsLayout = true
        })
        contentView.postsFrameChangedNotifications = true
        scrollObserverTokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Erst der angewendete Frame löst die alte Höhenbegrenzung der
            // ClipView. Jetzt kann die Miniatur dem Editor wirklich folgen.
            self.updateDocumentVisibleViewPosition()
            self.contentView.needsLayout = true
        })
        scrollObserverTokens.append(center.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView?.selectionManager, queue: .main
        ) { [weak self] _ in
            self?.selectionManager?.setSelectedRanges(
                self?.textView?.selectionManager.textSelections.map(\\.range) ?? []
            )
        })
    }'''
previous_observers = new.replace('        contentView.postsFrameChangedNotifications = true\n        scrollObserverTokens.append(center.addObserver(\n            forName: NSView.frameDidChangeNotification,\n            object: contentView, queue: .main\n        ) { [weak self] _ in\n            guard let self else { return }\n            // Erst der angewendete Frame löst die alte Höhenbegrenzung der\n            // ClipView. Jetzt kann die Miniatur dem Editor wirklich folgen.\n            self.updateDocumentVisibleViewPosition()\n            self.contentView.needsLayout = true\n        })\n', '')
replacements = [(old, new),
    ('''    override public func layout() {
        super.layout()
        updateContentViewHeight()''', '''    override public func layout() {
        super.layout()
        setUpListeners()
        updateContentViewHeight()'''),
    ('''    deinit {
        NotificationCenter.default.removeObserver(self)
    }''', '''    deinit {
        for token in scrollObserverTokens { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.removeObserver(self)
    }''')]
changed = False
for old, new in replacements:
    if new not in source:
        candidate = old
        if 'private weak var observedEditorScrollView' in new and source.count(previous_observers) == 1:
            candidate = previous_observers
        if source.count(candidate) != 1:
            raise SystemExit('Minimap-Scrollbeobachter: Anker fehlt oder ist mehrdeutig')
        source = source.replace(candidate, new, 1)
        changed = True
    if source.count(new) != 1:
        raise SystemExit('Minimap-Scrollbeobachter: Selbstprüfung fehlgeschlagen')
if changed:
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source)
if any(path.read_text().count(new) != 1 for _, new in replacements):
    raise SystemExit('Minimap-Scrollbeobachter: gespeicherte Selbstprüfung fehlgeschlagen')
print('changed' if changed else 'unchanged')
