import AppKit
import Testing
@testable import Fastra

@Suite @MainActor struct DocumentTextStorageTests {
    @Test("Gemeinsamer Textspeicher erhält exakte Unicode-, NUL- und Zeilenendunterschiede", arguments: [
        ("é\r\n😀\0a", "e\u{301}\r\n😀\0a"),
        ("a\0b", "a\0c"), ("a\r\nb", "a\nb"), ("😀", "😃")
    ])
    func exactSource(_ texts: (String, String)) {
        let history = DocumentUndoHistory()
        let original = history.textStorage(for: texts.0)
        #expect(history.textStorage(for: String(texts.0)) === original)
        let changed = history.textStorage(for: texts.1)
        #expect(changed !== original)
        #expect(changed.string.utf8.elementsEqual(texts.1.utf8))
        #expect(original.string.utf8.elementsEqual(texts.0.utf8))
        changed.replaceCharacters(in: NSRange(location: 0, length: changed.length), with: texts.0)
        #expect(history.textStorage(for: texts.0) === changed)
    }

    @Test("Wiederholter Zugriff auf ein großes unverändertes Dokument erhält den gemeinsamen Speicher")
    func unchangedLargeSource() {
        let source = String(repeating: "A7+/qZ09_-?mN4xB", count: 272_357)
        let history = DocumentUndoHistory()
        let storage = history.textStorage(for: source)
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 { #expect(history.textStorage(for: source) === storage) }
        print("DOCUMENT_STORAGE_REPEAT seconds=\(ProcessInfo.processInfo.systemUptime-started) bytes=\(source.utf8.count) repeats=5")
        #expect(storage.string.utf8.elementsEqual(source.utf8))
    }
    @Test("Unveränderter NSString-Rückweg erhält den Undo-Verlauf auch bei großen Dokumenten")
    func unchangedNativeUndoSource() {
        let source = String(repeating: "A7+/qZ09_-?mN4xB", count: 272_357)
        let history = DocumentUndoHistory()
        let storage = history.textStorage(for: source)
        let manager = history.manager(for: source)
        history.didEditInSource(storage.string)
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 { #expect(history.manager(for: source) === manager) }
        print("DOCUMENT_UNDO_REPEAT seconds=\(ProcessInfo.processInfo.systemUptime-started) bytes=\(source.utf8.count) repeats=5")
        #expect(!manager.canUndo)
        history.replace(source, with: source + "changed")
        #expect(manager.canUndo)
    }

}
