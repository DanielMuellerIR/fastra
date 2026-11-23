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
    /// Im Produkt wechselt der Fokus auf dem Main-Thread. Die parallele
    /// Testsuite erzeugt Workspaces auch auf anderen Threads; `Workspace.shared`
    /// reicht sie hierher weiter. Die Zugriffe werden serialisiert, damit
    /// konkurrierende Zuweisungen dieselbe alte Referenz nicht doppelt freigeben.
    private let lock = NSLock()

    var workspace: Workspace? { lock.withLock { activeWorkspace } }

    func activate(_ workspace: Workspace?) {
        // Nur der Referenzwechsel läuft unter dem Lock. Das Veröffentlichen
        // bleibt bewusst draußen: Beobachter dürfen dabei zurücklesen.
        lock.withLock {
            guard activeWorkspace !== workspace else { return }
            activeWorkspace = workspace
            workspaceObservation = workspace?.objectWillChange.sink {
                [weak self, weak workspace] _ in
                // @Published meldet vor der Mutation. Der nächste Main-Loop liest
                // deshalb garantiert den neuen aktiven Tab bzw. das neue Profil.
                DispatchQueue.main.async {
                    guard let self, self.workspace === workspace else { return }
                    self.publishChange()
                }
            }
        }
        publishChange()
    }

    /// Hilfsfenster behalten den letzten Dokumentkontext für Einstellungen,
    /// sperren aber Dokumentbefehle. Auch ohne Referenzwechsel neu auswerten.
    func commandTargetDidChange() {
        publishChange()
    }

    private func publishChange() {
        revision &+= 1
        NotificationCenter.default.post(
            name: .fastraActiveDocumentContextChanged,
            object: workspace
        )
    }
}
