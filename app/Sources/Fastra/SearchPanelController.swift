// SearchPanelController.swift
//
// Hostet den `FloatingSearchDialog` in einem **normalen NSWindow**
// (kein Floating-Panel). Begründung (Daniel, 2026-05-26):
// Ein dauerhaft schwebendes Suchfenster nervt, wenn man zu einer
// anderen App wechselt — es bleibt dann auch dort vorn. Ein normales
// Fenster verschwindet sauber in den Hintergrund. CMD+F holt es
// jederzeit wieder hervor.
//
// Eigenschaften:
// • Normaler Fenster-Style (titled, closable, resizable)
// • Frame wird über `setFrameAutosaveName` zwischen App-Starts gemerkt
// • Größe wächst automatisch, wenn beim Wechsel in den Ordner-Modus
//   nicht genug Platz für Trefferliste + Ordner-Block da ist — schrumpft
//   aber **nicht**, wenn der Nutzer das Fenster manuell vergrößert hat

import AppKit
import Combine
import SwiftUI

@MainActor
final class SearchPanelController {
    private weak var workspace: Workspace?
    private var window: NSWindow?
    private var scopeObserver: AnyCancellable?
    /// Strong reference, damit der WindowDelegate während der Lebenszeit
    /// nicht freigegeben wird.
    private var windowDelegate: WindowDelegate?

    /// Mindesthöhe der Maske, getrennt für kompakt (Datei/Geöffnet) und
    /// erweitert (Ordner). Werte am echten Layout abgemessen, knapp
    /// gehalten — der Nutzer kann das Fenster jederzeit größer ziehen,
    /// und die Größe bleibt erhalten.
    /// - kompakt: ~3 Trefferzeilen sichtbar
    /// - Ordner: ~4 Trefferzeilen sichtbar
    private let compactMinHeight: CGFloat = 424
    private let folderMinHeight: CGFloat = 624

    /// Mindestbreite der Maske. Bei unter ~620 px wickeln Toggles wie
    /// „Groß-/Kleinschreibung" auf mehrere Zeilen um — das Layout
    /// rutscht und sieht hässlich aus.
    private let minWidth: CGFloat = 640

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Suchfenster anzeigen — beim ersten Aufruf erzeugen, sonst nur
    /// nach vorne holen. Holt das Fenster auch dann nach vorn, wenn es
    /// von einem App-Wechsel im Hintergrund verschwunden war.
    func show() {
        if let workspace {
            Workspace.shared = workspace
        }
        if window == nil {
            createWindow()
        }
        guard let win = window else { return }
        ensureOnScreen(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    /// Sicherheits-Netz gegen ein autogespeichertes Frame, das vollständig
    /// außerhalb aller sichtbaren Bildschirme liegt (z.B. nach Wechsel
    /// von Multi- auf Single-Monitor-Setup) oder eine degenerierte Größe
    /// hat. In diesen Fällen wird die Position auf den Hauptbildschirm
    /// zurückgesetzt.
    private func ensureOnScreen(_ w: NSWindow) {
        let visible = NSScreen.screens.map(\.visibleFrame)
        let intersects = visible.contains { $0.intersects(w.frame) }
        let degenerateSize = w.frame.width < 200 || w.frame.height < 200

        if !intersects || degenerateSize {
            var f = w.frame
            f.size.width = max(minWidth, f.size.width)
            f.size.height = max(compactMinHeight, f.size.height)
            w.setFrame(f, display: false)
            w.center()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    // MARK: - Fenster-Erzeugung

    private func createWindow() {
        guard let workspace else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: compactMinHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Fenstertitel ist sichtbar (der interne Header ist weg, also
        // ist hier keine Doppelung mehr). Daniel: „Bitte den Fenstertitel
        // wieder setzen" — gibt dem Fenster eine eindeutige Beschriftung
        // in Window-Listen und Mission Control.
        w.title = "Suchen & Ersetzen"
        w.titlebarAppearsTransparent = false
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        WorkspaceWindowRegistry.register(workspace, for: w)

        // Frame zwischen App-Starts merken — der Nutzer kann das Fenster
        // einmal in passende Größe ziehen und es bleibt so.
        // Der Name muss zu `SearchWindow.frameAutosaveName` passen, damit
        // der globale ESC-Handler in AppDelegate das Fenster erkennt.
        w.setFrameAutosaveName(SearchWindow.frameAutosaveName)

        // SwiftUI-Inhalt einhängen.
        let host = NSHostingController(
            rootView: FloatingSearchDialog()
                .environmentObject(workspace)
                .fastraScalingRoot()
        )
        w.contentViewController = host
        w.contentMinSize = NSSize(width: minWidth, height: compactMinHeight)
        // Bewusst **kein** contentMaxSize — die Maske darf so groß
        // gezogen werden, wie der Nutzer möchte.

        // Schließen per roten Punkt: nur ausblenden, Workspace-State setzen.
        let delegate = WindowDelegate(
            onClose: { [weak self] in
                self?.workspace?.showSearchDialog = false
            },
            onBecomeKey: { [weak self] in
                if let workspace = self?.workspace {
                    Workspace.shared = workspace
                }
            }
        )
        self.windowDelegate = delegate
        w.delegate = delegate

        // Initial-Position (nur wenn keine gespeicherte Position
        // existiert — autosave kümmert sich danach selbst).
        if w.frame.origin == .zero {
            if let main = NSApp.mainWindow {
                let mf = main.frame
                let ws = w.frame.size
                w.setFrameTopLeftPoint(NSPoint(x: mf.maxX - ws.width - 16,
                                                y: mf.maxY - 16))
            } else {
                w.center()
            }
        }

        self.window = w

        // Auf Scope-Wechsel reagieren: bei Wechsel auf .folder ggf.
        // animiert wachsen — aber nie schrumpfen.
        scopeObserver = workspace.$scope.sink { [weak self] newScope in
            self?.growIfNeeded(for: newScope)
        }
    }

    /// Wachsen nur dann, wenn die aktuelle Fensterhöhe unter dem für
    /// den neuen Scope nötigen Minimum liegt. Sonst nichts tun (der
    /// Nutzer hat das Fenster vielleicht bewusst größer gezogen, das
    /// respektieren wir).
    private func growIfNeeded(for scope: Workspace.SearchScope) {
        guard let win = window else { return }
        let required: CGFloat = scope.isFolderLike ? folderMinHeight : compactMinHeight

        // Auch die contentMinSize anpassen, damit der Nutzer das
        // Fenster nicht unter das Minimum schrumpfen kann.
        win.contentMinSize.height = required

        if win.frame.height >= required { return }

        var f = win.frame
        let dh = required - f.height
        // Wachsen nach unten (origin.y senken), damit die top-left-Ecke
        // an Ort und Stelle bleibt.
        f.origin.y -= dh
        f.size.height = required
        // Bewusst ohne Animation: animierter Frame-Wechsel kollidierte
        // mit dem SwiftUI-Relayout, dadurch standen Scope-Tabs oben
        // halb außerhalb und die Action-Buttons unten unsichtbar.
        // Sofortiger Wechsel = stabile Geometrie für SwiftUI.
        win.setFrame(f, display: true, animate: false)
    }
}

// MARK: - WindowDelegate

private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    private let onBecomeKey: () -> Void

    init(onClose: @escaping () -> Void, onBecomeKey: @escaping () -> Void) {
        self.onClose = onClose
        self.onBecomeKey = onBecomeKey
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false   // wir blenden nur aus, schließen nicht
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey()
    }
}
