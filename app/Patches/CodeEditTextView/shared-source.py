#!/usr/bin/env python3
"""Gemeinsamer Textspeicher mit unabhängigen Auswahlen und aktivem Undo-Ziel."""
from pathlib import Path
import sys

root = Path(sys.argv[1]) / 'Sources/CodeEditTextView'
changed = False

def patch(name, old, new):
    global changed
    path = root / name
    source = path.read_text()
    if new not in source:
        candidates = old if isinstance(old, list) else [old]
        anchors = sorted((item for item in candidates if source.count(item) == 1), key=len, reverse=True)
        if not anchors or (len(anchors) > 1 and len(anchors[0]) == len(anchors[1])):
            raise SystemExit(f'Geteilte Quelle: Anker fehlt oder ist mehrdeutig: {name}')
        source = source.replace(anchors[0], new, 1)
        path.chmod(path.stat().st_mode | 0o200)
        path.write_text(source)
        changed = True
    if path.read_text().count(new) != 1:
        raise SystemExit(f'Geteilte Quelle: Selbstprüfung fehlgeschlagen: {name}')

patch('Utils/MultiStorageDelegate.swift',
      '    private var delegates = NSHashTable<NSTextStorageDelegate>.weakObjects()',
      '''    private var delegates = NSHashTable<NSTextStorageDelegate>.weakObjects()
    // Nur Ansichten desselben Speichers teilen Text; Auswahl und Layout bleiben lokal.
    let fastraTextViews = NSHashTable<TextView>.weakObjects()''')
patch('TextView/TextView.swift',
      '    // MARK: - Configuration',
      '''    public static func fastraMakeTextStorage(_ string: String) -> NSTextStorage {
        ImmediateAttributeTextStorage(string: string, attributes: defaultTypingAttributes)
    }

    // MARK: - Configuration''')
previous_focus = '        isFirstResponder = true\n        _undoManager?.setTextView(self)\n'
focus_source = (root / 'TextView/TextView+FirstResponder.swift').read_text()
patch('TextView/TextView+FirstResponder.swift',
      previous_focus if previous_focus in focus_source else '        isFirstResponder = true\n',
      '''        isFirstResponder = true
        _undoManager?.setTextView(self)
        NotificationCenter.default.post(name: .init("com.CodeEdit.TextView.TextDidBecomeFirstResponder"), object: self)
''')
old_peer_prefix = '''        guard isEditable else { return }
        if _undoManager?.isUndoing != true && _undoManager?.isRedoing != true {
            _undoManager?.setTextView(self)
        }
        var fastraPeers = storageDelegate.fastraTextViews.allObjects
            .filter { $0 !== self && $0.textStorage === textStorage }
            .map { (view: $0, ranges: $0.selectionManager.textSelections.map(\\.range)) }
'''
peer_source = (root / 'TextView/TextView+ReplaceCharacters.swift').read_text()
patch('TextView/TextView+ReplaceCharacters.swift',
      old_peer_prefix if old_peer_prefix in peer_source else '        guard isEditable else { return }\n',
      '''        guard isEditable else { return }
        if _undoManager?.isUndoing != true && _undoManager?.isRedoing != true {
            _undoManager?.setTextView(self)
        }
        var fastraPeers = fastraSharedStorageDelegate.fastraTextViews.allObjects
            .filter { $0 !== self && $0.textStorage === textStorage }
            .map { (view: $0, ranges: $0.selectionManager.textSelections.map(\\.range)) }
''')
patch('TextView/TextView+ReplaceCharacters.swift',
      '            delegate?.textView(self, didReplaceContentsIn: range, with: string)',
      '''            // Fremde Auswahlen erst nach dem vollständigen Speicher-Edit publizieren.
            let insertedLength = (string as NSString).length
            func shifted(_ position: Int) -> Int {
                if position <= range.location { return position }
                if position >= range.max { return position + insertedLength - range.length }
                return range.location + insertedLength
            }
            for index in fastraPeers.indices {
                fastraPeers[index].ranges = fastraPeers[index].ranges.map { selection in
                    let start = shifted(selection.location), end = shifted(selection.max)
                    return NSRange(location: start, length: max(0, end - start))
                }
            }
            delegate?.textView(self, didReplaceContentsIn: range, with: string)''')
patch('TextView/TextView+ReplaceCharacters.swift',
      '        textStorage.endEditing()\n\n        if !skipUpdateSelection {',
      '''        textStorage.endEditing()
        for peer in fastraPeers where peer.view.textStorage === textStorage {
            peer.view.selectionManager.setSelectedRanges(peer.ranges)
            peer.view.selectionManager.notifyAfterEdit()
            peer.view.updateFrameIfNeeded()
            peer.view.needsLayout = true
            peer.view.needsDisplay = true
        }

        if !skipUpdateSelection {''')
# Die lokalen Beobachter einer zweiten Ansicht dürfen beim Anschließen nicht
# durch die erste Ansicht ersetzt werden. Der gemeinsame Verteiler bleibt separat.
patch('TextView/TextView.swift', '    var storageDelegate: MultiStorageDelegate!',
      '    var storageDelegate: MultiStorageDelegate!\n    var fastraSharedStorageDelegate: MultiStorageDelegate!')
patch('TextView/TextView.swift',
      """        if let storageDelegate = textStorage.delegate as? MultiStorageDelegate {
            self.storageDelegate = storageDelegate
        } else {
            self.storageDelegate = MultiStorageDelegate()
        }""",
      """        self.storageDelegate = MultiStorageDelegate()
        self.fastraSharedStorageDelegate = MultiStorageDelegate()
        self.fastraSharedStorageDelegate.addDelegate(storageDelegate)""")
patch('TextView/TextView.swift',
      ['        textStorage.delegate = storageDelegate\n\n        layoutManager =',
       '        textStorage.delegate = storageDelegate\n        storageDelegate.fastraTextViews.add(self)\n\n        layoutManager ='],
      '        textStorage.delegate = fastraSharedStorageDelegate\n        fastraSharedStorageDelegate.fastraTextViews.add(self)\n\n        layoutManager =')
patch('TextView/TextView+SetText.swift',
      ["""        self.textStorage = textStorage

        if let storageDelegate = textStorage.delegate as? MultiStorageDelegate {
            self.storageDelegate = storageDelegate
        }""", """        storageDelegate.fastraTextViews.remove(self)
        self.textStorage = textStorage

        if let storageDelegate = textStorage.delegate as? MultiStorageDelegate {
            self.storageDelegate = storageDelegate
        }"""],
      """        fastraSharedStorageDelegate.removeDelegate(storageDelegate)
        fastraSharedStorageDelegate.fastraTextViews.remove(self)
        self.textStorage = textStorage
        fastraSharedStorageDelegate = textStorage.delegate as? MultiStorageDelegate ?? MultiStorageDelegate()
        fastraSharedStorageDelegate.addDelegate(storageDelegate)""")
patch('TextView/TextView+SetText.swift',
      ['        textStorage.delegate = storageDelegate\n        needsDisplay = true',
       '        textStorage.delegate = storageDelegate\n        storageDelegate.fastraTextViews.add(self)\n        needsDisplay = true'],
      '        textStorage.delegate = fastraSharedStorageDelegate\n        fastraSharedStorageDelegate.fastraTextViews.add(self)\n        needsDisplay = true')
print('changed' if changed else 'unchanged')
