import Foundation

/// Empfänger und Ausgabe der Ausschnittdiagnose eines Workspace.
/// Die Nachricht wird für jeden tatsächlich aktiven Ausgang neu ausgewertet.
final class ScrollRestoreDiagnostics {
    var observer: ((String) -> Void)?
    private let isStandardErrorEnabled: () -> Bool
    private let writeStandardError: (String) -> Void

    init(isStandardErrorEnabled: @escaping () -> Bool = { DiagnosticsFlags.scrollRestore },
         writeStandardError: @escaping (String) -> Void = {
             FileHandle.standardError.write(Data($0.utf8))
         }) {
        self.isStandardErrorEnabled = isStandardErrorEnabled
        self.writeStandardError = writeStandardError
    }

    func emit(_ message: @autoclosure () -> String) {
        if let observer { observer(message()) }
        guard isStandardErrorEnabled() else { return }
        writeStandardError("SCROLLRESTORE \(message())\n")
    }
}
