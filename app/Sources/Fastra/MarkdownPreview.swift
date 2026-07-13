// MarkdownPreview.swift
//
// Read-only Markdown-Vorschau in einem eigenen Fenster (Roadmap H, v0.8).
//
// Zwei Typen in dieser Datei:
//   • MarkdownPreviewController  — hält das NSWindow am Leben, zeigt/versteckt es,
//                                  hält den Fenstertitel aktuell.
//   • MarkdownPreviewView        — die SwiftUI-Inhaltsansicht darin.
//
// Design-Entscheidungen:
//   • Normales NSWindow (kein NSPanel). Begründung identisch zu
//     SearchPanelController: ein schwebendes Panel bleibt beim App-Wechsel
//     stets vorn — das nervt. Ein normales Fenster verschwindet sauber.
//   • Schließen = ausblenden (WindowDelegate gibt `false` zurück).
//     Das Fenster bleibt im Speicher und öffnet beim nächsten Aufruf sofort,
//     ohne SwiftUI-View-Tree neu aufzubauen.
//   • Frame-Autosave unter „fastraMarkdownPreviewFrame" — merkt Position
//     und Größe über App-Neustarts hinweg.
//   • Live-Aktualisierung über @ObservedObject Workspace: der Inhalt des
//     aktiven Tabs ist @Published, jede Änderung aktualisiert die Vorschau
//     automatisch ohne eigene Subscription in der View.
//   • Fenstertitel: der Controller beobachtet den Workspace über Combine
//     und schreibt bei Tab-Wechsel/Umbenennungen `window.title` direkt.
//     (`.navigationTitle` würde nur innerhalb eines NavigationStack wirken;
//     hier haben wir ein nacktes NSHostingController ohne NavigationStack.)

import AppKit
import Combine
import SwiftUI
import MarkdownUI

// MARK: - Konstante für den Autosave-Namen

/// Bezeichner für NSWindow.setFrameAutosaveName — muss in der App eindeutig sein.
/// Analogon zu `SearchWindow.frameAutosaveName` in AppDelegate.swift.
enum MarkdownPreviewWindow {
    static let frameAutosaveName = "fastraMarkdownPreviewFrame"
}

// MARK: - Controller

/// Verwaltet das Markdown-Vorschau-Fenster.
///
/// Einstiegspunkte für AppDelegate / Menü-Handler:
/// ```swift
/// markdownPreviewController.show(for: workspace)
/// markdownPreviewController.hide()
/// markdownPreviewController.toggle(for: workspace)
/// ```
///
/// Hält das Fenster als starke Referenz (`window`), so dass es nach dem
/// ersten Erzeugen nicht freigegeben wird. Der Workspace wird schwach
/// gehalten, damit der Controller keinen Retain-Cycle erzeugt.
@MainActor
final class MarkdownPreviewController {

    // Schwache Referenz: der Workspace gehört der App-Szene, nicht uns.
    private weak var workspace: Workspace?

    // Das Fenster selbst — nil bis zum ersten `show`-Aufruf.
    private var window: NSWindow?

    // Delegate muss stark gehalten werden — NSWindow.delegate ist `weak`.
    private var windowDelegate: MarkdownPreviewWindowDelegate?

    // Combine-Subscription für den Fenstertitel.
    // AnyCancellable hält die Subscription am Leben; wird in deinit
    // automatisch freigegeben.
    private var titleSubscription: AnyCancellable?

    // Mindest- und Standardgrößen.
    private let defaultWidth:  CGFloat = 640
    private let defaultHeight: CGFloat = 560
    private let minWidth:      CGFloat = 400
    private let minHeight:     CGFloat = 300

    // MARK: Öffentliche API

    /// Fenster anzeigen (beim ersten Aufruf erzeugen).
    /// Hat ein Workspace-Wechsel stattgefunden, wird der neue Workspace
    /// als Kontext verwendet — das Fenster aktualisiert sich automatisch,
    /// da `MarkdownPreviewView` den Workspace via @ObservedObject beobachtet.
    func show(for workspace: Workspace) {
        let workspaceChanged = self.workspace !== workspace
        self.workspace = workspace
        if window == nil {
            createWindow(workspace: workspace)
        } else if workspaceChanged {
            installContent(for: workspace)
        }
        guard let win = window else { return }
        ensureOnScreen(win)
        win.makeKeyAndOrderFront(nil)
        // `ignoringOtherApps: false` ist höflicher: kein Vordrängen,
        // wenn der Nutzer gerade in einer anderen App arbeitet.
        NSApp.activate(ignoringOtherApps: false)
    }

    /// Fenster ausblenden (nicht schließen — Inhalt bleibt im Speicher).
    func hide() {
        window?.orderOut(nil)
    }

    /// Sichtbarkeit umschalten (zeigen wenn versteckt, verstecken wenn sichtbar).
    func toggle(for workspace: Workspace) {
        // Ist die Vorschau für ein ANDERES Dokumentfenster sichtbar, beim
        // Shortcut nicht bloß ausblenden: zuerst auf den neuen Workspace
        // umschalten und sichtbar lassen.
        if let win = window, win.isVisible, self.workspace === workspace {
            hide()
        } else {
            show(for: workspace)
        }
    }

    // MARK: Fenster-Erzeugung (privat)

    private func createWindow(workspace: Workspace) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: defaultWidth, height: defaultHeight),
            // titled       → Titelleiste sichtbar (Dateiname steht darin)
            // closable     → roter Schließen-Knopf (blendet nur aus, s. Delegate)
            // miniaturizable → gelber Minimieren-Knopf
            // resizable    → Nutzer kann das Fenster nach Belieben ziehen
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Basis-Titel; wird sofort via Combine-Subscription überschrieben.
        w.title = "Markdown-Vorschau"
        w.titlebarAppearsTransparent = false
        w.isMovableByWindowBackground = false
        // Fenster bleibt im Speicher wenn geschlossen (wir blenden nur aus).
        w.isReleasedWhenClosed = false

        // Frame-Autosave: Größe und Position werden zwischen Starts gespeichert.
        w.setFrameAutosaveName(MarkdownPreviewWindow.frameAutosaveName)

        // SwiftUI-Inhalt einhängen via NSHostingController.
        // NSHostingController statt NSHostingView, damit AppKit-Sizing und
        // Accessibility korrekt funktionieren (analog SearchPanelController).
        w.contentMinSize = NSSize(width: minWidth, height: minHeight)
        // Kein contentMaxSize — Fenster darf beliebig groß gezogen werden.

        // Schließen über roten Knopf: nur ausblenden, nicht wirklich schließen.
        let delegate = MarkdownPreviewWindowDelegate { [weak self] in
            if let workspace = self?.workspace {
                Workspace.shared = workspace
            }
        }
        self.windowDelegate = delegate
        w.delegate = delegate

        // Initiale Position: rechts neben dem Hauptfenster, wenn möglich.
        // Danach übernimmt der Autosave die Positionierung.
        if w.frame.origin == .zero {
            if let main = NSApp.mainWindow {
                let mf = main.frame
                // Direkt rechts vom Hauptfenster, bündig mit dessen Oberkante.
                w.setFrameTopLeftPoint(NSPoint(x: mf.maxX + 8, y: mf.maxY))
            } else {
                w.center()
            }
        }

        self.window = w

        installContent(for: workspace)

    }

    /// Tauscht Inhalt und Titelbeobachtung aus, wenn der Nutzer die globale
    /// Markdown-Vorschau aus einem anderen Dokumentfenster aufruft.
    private func installContent(for workspace: Workspace) {
        guard let window else { return }
        WorkspaceWindowRegistry.register(workspace, for: window)
        window.contentViewController = NSHostingController(
            rootView: MarkdownPreviewView(workspace: workspace)
                .fastraScalingRoot()
        )

        // Fenstertitel via Combine aktuell halten.
        // Wir beobachten sowohl `tabs` (Inhalt/Umbenennung) als auch
        // `activeTabID` (Tab-Wechsel) — jede der beiden @Published-Properties
        // löst einen neuen Titelstring aus.
        // `combineLatest` liefert ein Paar; wir brauchen nur einen der Werte,
        // deshalb mappen wir auf den berechneten Titel.
        titleSubscription = workspace.$tabs
            .combineLatest(workspace.$activeTabID)
            .map { [weak workspace] _, _ -> String in
                // Workspace schwach halten, um Retain-Cycle zu vermeiden.
                guard let ws = workspace,
                      let tab = ws.activeTab else {
                    return L10n.string("Markdown-Vorschau")
                }
                let lower = tab.title.lowercased()
                guard lower.hasSuffix(".md") || lower.hasSuffix(".markdown") else {
                    return L10n.string("Markdown-Vorschau")
                }
                return L10n.format("Markdown-Vorschau — %@", tab.title)
            }
            // Auf den MainActor wechseln, bevor wir window.title schreiben.
            .receive(on: DispatchQueue.main)
            .sink { [weak window] title in
                window?.title = title
            }
    }

    /// Stellt sicher, dass das Fenster auf einem sichtbaren Bildschirm liegt
    /// und keine degenerierte Größe hat (passiert z.B. nach einem Monitor-
    /// Wechsel, wenn die gespeicherte Position außerhalb aller Displays liegt).
    private func ensureOnScreen(_ w: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let isOnScreen = visibleFrames.contains { $0.intersects(w.frame) }
        let isDegenerate = w.frame.width < 200 || w.frame.height < 200

        if !isOnScreen || isDegenerate {
            // Mindestgröße sicherstellen und Fenster auf Hauptbildschirm zentrieren.
            var f = w.frame
            f.size.width  = max(minWidth,  f.size.width)
            f.size.height = max(minHeight, f.size.height)
            w.setFrame(f, display: false)
            w.center()
        }
    }
}

// MARK: - Window-Delegate (privat)

/// Abfangen des Schließens: wir blenden das Fenster nur aus (orderOut),
/// schließen es nicht wirklich. Damit bleibt der SwiftUI-View-Tree im
/// Speicher und öffnet sich beim nächsten CMD+SHIFT+M sofort ohne
/// Neuaufbau-Flackern.
private final class MarkdownPreviewWindowDelegate: NSObject, NSWindowDelegate {
    private let onBecomeKey: () -> Void

    init(onBecomeKey: @escaping () -> Void) {
        self.onBecomeKey = onBecomeKey
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false   // false = AppKit schließt das Fenster NICHT
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey()
    }
}

// MARK: - SwiftUI-Ansicht

/// Inhaltsansicht des Markdown-Vorschau-Fensters.
///
/// Beobachtet den `Workspace` als ObservedObject — jede Änderung an
/// `workspace.tabs` oder `workspace.activeTabID` löst ein automatisches
/// Neuzeichnen aus. Das schließt Live-Aktualisierung beim Tippen ein,
/// da `EditorTab.content` über `tabs` @Published ist.
///
/// - Ist der aktive Tab eine Markdown-Datei (.md / .markdown): Vorschau.
/// - Ist er es nicht: freundlicher Platzhalter.
struct MarkdownPreviewView: View {

    /// Workspace wird NICHT als @EnvironmentObject erwartet, sondern direkt
    /// übergeben — der Controller erzeugt die View mit dem konkreten Workspace,
    /// unabhängig davon ob er im SwiftUI-Environment registriert ist.
    @ObservedObject var workspace: Workspace
    @AppStorage(DocumentZoom.defaultsKey) private var documentZoomLevel = 0
    @AppStorage(PreviewFonts.defaultsKey) private var previewFontName = PreviewFonts.systemName

    var body: some View {
        Group {
            if let tab = workspace.activeTab, isMarkdown(tab.title) {
                // Markdown-Tab: Vorschau mit GFM-Thema.
                markdownContent(tab: tab)
            } else {
                // Kein Markdown-Tab aktiv: freundlicher Platzhalter.
                placeholderView
            }
        }
        // Hintergrundfarbe: Theme.surfaceRaised (reines Weiß in sRGB) für
        // den äußeren Rahmen. MarkdownUI bringt sein eigenes Farbschema
        // mit; der Rahmen außen bleibt neutral hell.
        // LESSONS-LEARNED F.6b: kein Gray-Colorspace — Theme.surfaceRaised
        // ist als sRGB-Wert definiert, passt also für beide Appearance-Modi.
        .background(Theme.surfaceRaised)
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: Teilansichten

    /// Die eigentliche Markdown-Vorschau mit Scrollbarkeit.
    /// Bei leerem Tab-Inhalt zeigt sie statt `Markdown("")` einen
    /// informativen Platzhalter im gleichen Stil wie `placeholderView`.
    @ViewBuilder
    private func markdownContent(tab: EditorTab) -> some View {
        if tab.content.isEmpty {
            // Leere .md-Datei: Platzhalter statt leerem ScrollView.
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .fastraFont(size: 40)
                    .foregroundColor(Theme.textSecondary)
                Text("Diese Markdown-Datei ist noch leer.")
                    .fastraFont(.ui)
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceRaised)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                // Markdown(String) ist die direkte String-Variante aus der
                // echten MarkdownUI-API (Markdown.swift Extension, Zeile 237).
                //
                // .markdownTheme(.gitHub) — der Compiler löst `.gitHub` als
                // MarkdownUI.Theme.gitHub auf, weil der Argument-Typ des Modifiers
                // `markdownTheme(_:)` explizit `MarkdownUI.Theme` ist (nicht
                // `Fastra.Theme`, der ein enum ist).
                Markdown(tab.content)
                    .markdownTheme(.gitHub)
                    .font(previewFont)
                    // 20 pt Innenabstand auf allen Seiten: Text klebt nicht am Rand.
                    .padding(20)
                    // Volle Breite ausnutzen; Höhe wächst mit dem Inhalt (→ ScrollView).
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Hintergrund auch innerhalb des ScrollViews weiß.
            .background(Theme.surfaceRaised)
        }
    }

    private var previewFont: Font {
        let size = 14 * DocumentZoom.scale(for: documentZoomLevel)
        return previewFontName == PreviewFonts.systemName
            ? .system(size: size)
            : .custom(previewFontName, size: size)
    }

    /// Platzhalter, wenn der aktive Tab keine Markdown-Datei ist.
    private var placeholderView: some View {
        VStack(spacing: 12) {
            // SF-Symbol als visuellen Anker — kein Emoji.
            Image(systemName: "doc.text")
                .fastraFont(size: 40)
                // textSecondary: sRGB-Wert aus Theme.swift, kein Gray-Colorspace.
                .foregroundColor(Theme.textSecondary)
            Text("Die Vorschau zeigt Markdown-Dateien (.md)")
                .fastraFont(.ui)
                .foregroundColor(Theme.textSecondary)
            Text("Der aktive Tab ist keine Markdown-Datei.")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceRaised)
    }

    // MARK: Hilfsmethoden

    /// Prüft, ob ein Dateiname als Markdown gilt.
    /// Erkannte Endungen: .md und .markdown (Groß-/Kleinschreibung egal).
    private func isMarkdown(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }
}
