import CodeEditTextView

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

    /// Native Eingaben sind bereits im CodeEdit-Verlauf registriert.
    func didEditInSource(_ text: String) { content = text }

    /// Modelländerungen (auch an unsichtbaren Tabs) brauchen einen eigenen
    /// Schritt. Ohne diesen Abgleich würden alte Undo-Ranges auf neuem Text wirken.
    func replace(_ before: String, with after: String) {
        _ = manager(for: before)
        synchronize(with: after)
    }

    private func synchronize(with text: String) {
        if let content, content != text {
            storage?.fastraRegisterDocumentReplacement(from: content, to: text)
        }
        content = text
    }

    static func == (lhs: DocumentUndoHistory, rhs: DocumentUndoHistory) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
