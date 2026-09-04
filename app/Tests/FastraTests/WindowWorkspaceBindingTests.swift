// WindowWorkspaceBindingTests.swift
//
// Schützt die Verbindung zwischen sichtbarem NSWindow und seinem Workspace.
// Ohne sie finden globale Befehle wie ⌘W kein Ziel; zugleich verschwindet der
// Dokumenteintrag aus dem Fenster-Menü.

import AppKit
import Testing
@testable import Fastra

@Suite("Fenster-Workspace-Bindung")
@MainActor
struct WindowWorkspaceBindingTests {
    @Test("Eine montierte Titelbrücke repariert eine verlorene Registry-Bindung")
    func mountedBridgeRepairsMissingRegistration() {
        let suite = "fastra-tests-window-binding-repair-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled],
                              backing: .buffered, defer: true)
        let metadataView = MainWindowTitleBridge.WindowMetadataView(
            metadata: .from(workspace.activeTab, welcomeActive: workspace.isWelcomeScreen),
            workspace: workspace,
            chromeHeight: 36
        )
        window.contentView = metadataView
        defer {
            WorkspaceWindowRegistry.unregister(window)
            window.contentView = nil
        }

        WorkspaceWindowRegistry.unregister(window)
        workspace.closeWindowHandler = nil

        #expect(MainWindowTitleBridge.restoreWindowBinding(for: window) === workspace)
        #expect(WorkspaceWindowRegistry.workspace(for: window) === workspace)
        #expect(workspace.closeWindowHandler != nil)
        #expect(WorkspaceWindowRegistry.registeredWindows().contains { $0 === window })
    }
}
