import CodeEditTextView
import Foundation

/// Der Verlauf gehört zum Dokument, nicht zur kurzlebigen SwiftUI-Editoransicht.
/// Tabkopien teilen ihn wie die Hex-Sitzung; neue Dokumente beginnen unabhängig.
final class DocumentUndoHistory: Hashable {
    private var storage: CEUndoManager?
    private var content: String?

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
        // Kanonische String-Gleichheit würde geänderte Unicode-Bytes verlieren.
        if let content, !content.utf8.elementsEqual(text.utf8) {
            storage?.fastraRegisterDocumentReplacement(from: content, to: text)
        }
        content = text
    }

    static func == (lhs: DocumentUndoHistory, rhs: DocumentUndoHistory) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
