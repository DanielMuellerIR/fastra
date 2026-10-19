import AppKit
import CodeEditTextView
import Foundation

/// Der Verlauf gehört zum Dokument, nicht zur kurzlebigen SwiftUI-Editoransicht.
/// Tabkopien teilen ihn wie die Hex-Sitzung; neue Dokumente beginnen unabhängig.
final class DocumentUndoHistory: Hashable {
    private var storage: CEUndoManager?
    private var content: String?
    private var sourceStorage: NSTextStorage?

    @MainActor func textStorage(for text: String) -> NSTextStorage {
        // UTF8Sequence iteriert den NSString-Speicher zeichenweise. Der
        // literale UTF-16-Vergleich bleibt auch bei kanonisch gleichen,
        // verschieden codierten Zeichen exakt und vermeidet diese Kosten.
        if sourceStorage == nil || (sourceStorage!.string as NSString).compare(text, options: .literal) != .orderedSame {
            sourceStorage = TextView.fastraMakeTextStorage(text)
        }
        return sourceStorage!
    }

    func manager(for text: String) -> CEUndoManager {
        if storage == nil { storage = CEUndoManager() }
        synchronize(with: text)
        return storage!
    }

    var isPerformingAction: Bool { storage?.isUndoing == true || storage?.isRedoing == true }

    func whenIdle(_ action: @escaping () -> Void) {
        if let storage { storage.fastraWhenIdle(action) }
        else { action() }
    }

    func owns(_ manager: CEUndoManager) -> Bool { storage === manager }

    func reset(to text: String) {
        storage?.clearStack()
        content = text
    }

    func documentSaved(_ text: String, at url: URL) {
        storage?.fastraDocumentSaved(text, at: url)
    }

    /// Native Eingaben sind bereits im CodeEdit-Verlauf registriert.
    func didEditInSource(_ text: String) { content = text }

    /// Modelländerungen (auch an unsichtbaren Tabs) brauchen einen eigenen
    /// Schritt. Ohne diesen Abgleich würden alte Undo-Ranges auf neuem Text wirken.
    func replace(_ before: String, with after: String) {
        _ = manager(for: before)
        synchronize(with: after)
    }

    private func synchronize(with text: String) {
        // Literal bleibt bytegenau; UTF8Sequence kopiert beim NSString-Rückweg
        // aus dem Editor sonst jedes unveränderte große Dokument.
        if let content, (content as NSString).compare(text, options: .literal) != .orderedSame {
            storage?.fastraRegisterDocumentReplacement(from: content, to: text)
        }
        content = text
    }

    static func == (lhs: DocumentUndoHistory, rhs: DocumentUndoHistory) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
