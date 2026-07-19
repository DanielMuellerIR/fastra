import Foundation
import Combine

extension Notification.Name {
    /// AppKit-Menübrücken aktualisieren ihren sichtbaren Haken, sobald sich
    /// Fokus, Tab, manuelle Sprache oder Formatprofil ändert.
    static let fastraActiveDocumentContextChanged =
        Notification.Name("fastra.activeDocumentContext.changed")
}

/// Beobachtbare Adresse des vordersten Dokumentfensters für globale Menüs.
///
/// `Workspace.shared` bleibt der bewährte Routing-Hook. Dieses Objekt ergänzt
/// lediglich eine Änderungsspur für SwiftUI: Tab-/Formatwechsel in einem
/// zusätzlichen Fenster müssen den checkbaren Soft-Wrap-Menüpunkt ebenso
/// aktualisieren wie Wechsel im Startfenster.
final class ActiveDocumentContext: ObservableObject {
    static let shared = ActiveDocumentContext()

    @Published private(set) var revision: UInt64 = 0

    private weak var activeWorkspace: Workspace?
    private var workspaceObservation: AnyCancellable?

    var workspace: Workspace? { activeWorkspace }

    func activate(_ workspace: Workspace?) {
        if activeWorkspace === workspace {
            publishChange()
            return
        }
        activeWorkspace = workspace
        workspaceObservation = workspace?.objectWillChange.sink {
            [weak self, weak workspace] _ in
            // @Published meldet vor der Mutation. Der nächste Main-Loop liest
            // deshalb garantiert den neuen aktiven Tab bzw. das neue Profil.
            DispatchQueue.main.async {
                guard let self, self.activeWorkspace === workspace else { return }
                self.publishChange()
            }
        }
        publishChange()
    }

    private func publishChange() {
        revision &+= 1
        NotificationCenter.default.post(
            name: .fastraActiveDocumentContextChanged,
            object: activeWorkspace
        )
    }
}
