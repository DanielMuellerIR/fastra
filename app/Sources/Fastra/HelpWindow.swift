// HelpWindow.swift
//
// Eigenes Hilfe-Fenster (Etappe 4 Wunschpaket 2026-07b). Entscheidung
// FENSTER statt Tab, kurz begründet: Die Hilfe soll NEBEN dem Dokument
// lesbar bleiben (nachschlagen beim Arbeiten), ohne an der Tab-Verwaltung
// eines Workspaces teilzunehmen (Projektwechsel, „Andere Tabs schließen“,
// Sitzungslogik) — und Anker-Sprünge brauchen eine stabile, wiederfindbare
// Instanz. Muster wie `AboutWindow`: ein Fenster, beim zweiten Aufruf nur
// nach vorn holen.
//
// Gerendert wird read-only über den vorhandenen Markdown-Renderer
// (`MarkdownRichText`) in einer WKWebView — gleiche lokale Bibliotheken,
// gleiche CSP, kein Netzzugriff.

import AppKit
import WebKit

enum HelpWindow {

    static let frameAutosaveName = "FastraHelpWindow"
    private static weak var window: NSWindow?
    /// Für den Selbsttest `help`: echte DOM-Beobachtung der gerenderten
    /// Hilfe (gleiches Muster wie `XPathPanelController.lastShown`).
    private(set) static weak var currentWebView: WKWebView?
    private static var coordinator: HelpWebCoordinator?

    /// Öffnet die Hilfe (oder holt sie nach vorn). Mit `anchor` scrollt sie
    /// zum Abschnitt — der API-Punkt „Hilfe öffnen bei Anker X“ für die
    /// Erst-Nutzungs-Hinweise ab Etappe 5.
    @MainActor
    static func show(anchor: String? = nil) {
        if let existing = window, let webView = currentWebView {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            if let anchor { coordinator?.scroll(to: anchor, in: webView) }
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = L10n.string("Fastra-Hilfe")
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 380, height: 400)
        w.setFrameAutosaveName(frameAutosaveName)

        let helpCoordinator = HelpWebCoordinator()
        coordinator = helpCoordinator

        let configuration = WKWebViewConfiguration()
        // Wie die Markdown-Vorschau: rein lokaler Renderer ohne Cookies,
        // Cache oder persistente Website-Daten.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(helpCoordinator.assetHandler,
                                          forURLScheme: MarkdownPreviewAssets.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = helpCoordinator
        w.contentView = webView
        currentWebView = webView

        helpCoordinator.pendingAnchor = anchor
        loadContent(into: webView)

        // Hell-/Dunkel-Wechsel im laufenden Betrieb: neu rendern (die Hilfe
        // ist statisch — ein Reload ist billig und hält die Farben korrekt).
        helpCoordinator.observeAppearance { [weak webView] in
            guard let webView else { return }
            loadContent(into: webView)
        }

        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    /// Enger Fenster-Typ-Check für das globale ⌘W-Routing. Der feste
    /// Autosave-Name ist zugleich die stabile Identität für Selbsttests;
    /// andere Hilfsfenster bleiben davon ausdrücklich unberührt.
    static func isHelpWindow(_ candidate: NSWindow?) -> Bool {
        candidate?.frameAutosaveName == frameAutosaveName
    }

    /// Schließt nur das Hilfe-Fenster. Der Dokument-Workspace und seine Tabs
    /// kennen dieses Fenster nicht und werden deshalb nicht verändert.
    @MainActor
    static func close() {
        window?.close()
    }

    @MainActor
    private static func loadContent(into webView: WKWebView) {
        let markdown = HelpContent.markdown()
            ?? L10n.string("Die Hilfe-Datei fehlt im App-Paket. Bitte Fastra neu installieren.")
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let document = MarkdownRichText.htmlDocument(
            markdown: markdown,
            documentURL: nil,
            fontName: PreviewFonts.systemName,
            fontSize: 14,
            darkMode: dark
        )
        webView.loadHTMLString(HelpContent.addingHeadingAnchors(to: document),
                               baseURL: nil)
    }
}

/// Navigation + Anker-Sprung + Hell/Dunkel-Beobachtung des Hilfe-Fensters.
private final class HelpWebCoordinator: NSObject, WKNavigationDelegate {
    let assetHandler = MarkdownPreviewSchemeHandler()
    var pendingAnchor: String?
    private var appearanceObservation: NSKeyValueObservation?

    func observeAppearance(_ onChange: @escaping () -> Void) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { onChange() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let anchor = pendingAnchor {
            pendingAnchor = nil
            scroll(to: anchor, in: webView)
        }
    }

    /// Scrollt zum Überschriften-Anker (die IDs schreibt
    /// `HelpContent.addingHeadingAnchors` ins HTML).
    func scroll(to anchor: String, in webView: WKWebView) {
        let escaped = anchor.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript(
            "document.getElementById('\(escaped)')?.scrollIntoView(true)",
            completionHandler: nil
        )
    }

    /// Links in der Hilfe öffnen im Standardbrowser; das Dokument selbst
    /// lädt nur über `loadHTMLString`.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
