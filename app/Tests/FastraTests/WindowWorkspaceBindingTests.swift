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
    /// Baut ein Fenster mit montierter Titelbrücke, wie es das SwiftUI-
    /// Hauptfenster im Produkt trägt. Der Aufrufer räumt es über `teardown` ab.
    private func makeBridgedWindow(
        workspace: Workspace
    ) -> (window: NSWindow, teardown: () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // Ein programmatisch erzeugtes NSWindow gibt sich bei `close()` selbst
        // frei; ARC hält es dann noch einmal, und der Autorelease-Pool stürzt
        // beim Abbau mit SIGSEGV ab (gesehen 2026-09-05 im Filterlauf).
        window.isReleasedWhenClosed = false
        let metadataView = MainWindowTitleBridge.WindowMetadataView(
            metadata: .from(workspace.activeTab, welcomeActive: workspace.isWelcomeScreen),
            workspace: workspace,
            chromeHeight: 36
        )
        window.contentView = metadataView
        return (window, {
            WorkspaceWindowRegistry.unregister(window)
            window.contentView = nil
            window.close()
        })
    }

    /// Der produktive Rückfall ist der ÖFFENTLICHE Registry-Zugriff: Wer
    /// `workspace(for:)` fragt, bekommt die Zuordnung repariert, sofern das
    /// Fenster sichtbar ist. Der Test geht deshalb genau diesen Weg und ruft
    /// `restoreWindowBinding` nicht selbst auf — sonst bliebe er grün, obwohl
    /// der Rückfall in `workspace(for:)` defekt wäre (Review-Fund 2026-09-05).
    @Test("Sichtbares Fenster: der Registry-Zugriff repariert eine verlorene Bindung")
    func registryAccessRepairsMissingRegistrationForVisibleWindow() {
        let suite = "fastra-tests-window-binding-repair-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let (window, teardown) = makeBridgedWindow(workspace: workspace)
        defer { teardown() }
        // Der Rückfall setzt ein sichtbares Fenster voraus.
        window.orderFront(nil)
        #expect(window.isVisible)

        WorkspaceWindowRegistry.unregister(window)
        workspace.closeWindowHandler = nil
        #expect(!WorkspaceWindowRegistry.registeredWindows().contains { $0 === window })

        // Erster Wiederherstellungsschritt ist der öffentliche Zugriff selbst.
        #expect(WorkspaceWindowRegistry.workspace(for: window) === workspace)
        #expect(WorkspaceWindowRegistry.registeredWindows().contains { $0 === window })
        #expect(workspace.closeWindowHandler != nil)
    }

    /// Ein ausgeblendetes Fenster (etwa direkt nach `willClose`) darf sich
    /// nicht selbst wieder anmelden — sonst käme sein Fenster-Menü-Eintrag als
    /// Leiche zurück.
    @Test("Unsichtbares Fenster: der Registry-Zugriff repariert nichts")
    func registryAccessLeavesHiddenWindowUnbound() {
        let suite = "fastra-tests-window-binding-hidden-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        let (window, teardown) = makeBridgedWindow(workspace: workspace)
        defer { teardown() }
        #expect(!window.isVisible)

        WorkspaceWindowRegistry.unregister(window)
        workspace.closeWindowHandler = nil

        #expect(WorkspaceWindowRegistry.workspace(for: window) == nil)
        #expect(!WorkspaceWindowRegistry.registeredWindows().contains { $0 === window })
        #expect(workspace.closeWindowHandler == nil)
    }
}
