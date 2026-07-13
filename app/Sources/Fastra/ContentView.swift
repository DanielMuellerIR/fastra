import SwiftUI

/// Variante 1: Editor oben (45 %), Vorschau-Hero unten (55 %).
/// Die Suchmaske ist seit v0.5 ein eigenes, draggbares NSPanel —
/// das Hauptfenster bleibt während der Suche bedienbar.
struct ContentView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.uiScale) private var uiScale

    /// Lebenszeit des Panel-Controllers an die ContentView gebunden.
    /// `@State` reicht — der Controller selbst ist keine ObservableObject,
    /// nur ein Halter für das NSPanel.
    @State private var searchPanel: SearchPanelController?

    /// Sichtbarkeit des dezenten Donation-Banners (Donationware-Modell).
    /// Entscheidung beim Erscheinen über die pure DonationPrompt-Logik
    /// (ab dem 10. Start, 90 Tage Ruhe nach „Später").
    @State private var showDonationBanner = false

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
                .frame(height: 38 * uiScale)

            Divider().opacity(0.4)

            // Editor nimmt jetzt den ganzen Platz ein. Das untere
            // DiffPanelView ist mit v0.5 aus dem Hauptfenster entfernt
            // (Daniel-Entscheidung 2026-05-26): Die Sofort-Trefferliste
            // in der Suchmaske erfüllt den primären Bedarf. Eine
            // ausgewachsene Side-by-side-Diff-Vorschau erscheint bei Bedarf
            // als Sheet über diesem Hauptfenster.
            //
            // Willkommensbildschirm (Projekt- & Git-Ausbau, Etappe 1):
            // ersetzt den Editor-Bereich, solange nichts geöffnet ist
            // (Bedingung pur in WelcomeLogic, getestet). Tab-Leiste und
            // Footer bleiben stehen — nur die Editor-Fläche wechselt.
            if workspace.isWelcomeScreen {
                WelcomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EditorView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.5)

            // Dezenter Donation-Aufruf (AGENTS.md → Monetarisierung):
            // kein Modal, kein Nag — eine schmale Zeile über dem Footer,
            // nur wenn die DonationPrompt-Regeln es erlauben.
            if showDonationBanner {
                DonationBannerView(onDismiss: {
                    DonationPrompt.recordDismiss(defaults: SelfTest.workspaceDefaults())
                    showDonationBanner = false
                })
            }

            StatusBarView()
                .frame(height: 24 * uiScale)
        }
        .background(Theme.surfaceBase)
        .foregroundColor(Theme.textPrimary)
        // Der eigene Chrome darf bis hinter die transparente macOS-Titelleiste
        // reichen. Die oberen 38 Punkte lassen dabei den Ampelknöpfen Platz.
        .ignoresSafeArea(.container, edges: .top)
        // Zero-Size-AppKit-Brücke: synchronisiert die aktive Datei mit dem
        // nativen Fenster. AppKit baut daraus das CMD-Klick-Pfadmenü und kann
        // dessen Ordner direkt im Finder öffnen.
        .background(
            MainWindowTitleBridge(metadata: .from(workspace.activeTab,
                                                  welcomeActive: workspace.isWelcomeScreen),
                                  workspace: workspace)
                .frame(width: 0, height: 0)
        )
        // „Vorschau der Änderungen" (v0.10): Sheet mit echtem Vorher/Nachher-Diff
        // des aktiven Buffers. Wird aus der Suchmaske über `livePreview` ausgelöst
        // und erscheint hier im Hauptfenster (wo Daniel es erwartet hat). Der frühere
        // Button setzte das Flag nur — niemand zeigte etwas an. EnvironmentObject
        // explizit weiterreichen (Sheets erben es nicht zuverlässig).
        .sheet(isPresented: $workspace.livePreview) {
            ReplacePreviewView()
                .environmentObject(workspace)
        }
        .onAppear {
            // Beim ersten Erscheinen Controller anlegen und — falls per
            // Default sichtbar — gleich öffnen.
            let controller = SearchPanelController(workspace: workspace)
            self.searchPanel = controller
            if workspace.showSearchDialog {
                controller.show()
            }
            // Donation-Banner-Entscheidung (pure Logik, getestet).
            // `isEnabled` ist der Hauptschalter (derzeit AUS, Daniel
            // 2026-07-10) — die Regel-Logik dahinter bleibt intakt.
            let state = DonationPrompt.currentState(defaults: SelfTest.workspaceDefaults())
            showDonationBanner = DonationPrompt.isEnabled
                && DonationPrompt.shouldShow(launchCount: state.launchCount,
                                             dismissedAt: state.dismissedAt)
        }
        .onChange(of: workspace.showSearchDialog) { _, newValue in
            if newValue {
                searchPanel?.show()
            } else {
                searchPanel?.close()
            }
        }
        // Auf die globalen CMD+F / CMD+SHIFT+F-Shortcuts reagieren
        // (siehe AppDelegate.installKeyMonitor). Wir setzen den Scope
        // entsprechend und öffnen die Maske.
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFile)) { _ in
            guard Workspace.shared === workspace else { return }
            workspace.scope = .file
            // „Nur in Auswahl" (K3) automatisch einschalten, wenn beim Öffnen
            // eine MEHRZEILIGE Selektion im Editor steht (BBEdit-Verhalten).
            workspace.captureSelectionForSearch()
            workspace.showSearchDialog = true
            searchPanel?.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFolder)) { _ in
            guard Workspace.shared === workspace else { return }
            workspace.scope = .folder
            workspace.showSearchDialog = true
            searchPanel?.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraHideSearch)) { _ in
            guard Workspace.shared === workspace else { return }
            workspace.showSearchDialog = false
        }
        // CMD+G / CMD+SHIFT+G: durch die Treffer im aktiven Buffer
        // navigieren. Wir bewegen `activeMatchIndex` und schicken
        // einen Range-Sprung an den Editor.
        .onReceive(NotificationCenter.default.publisher(for: .fastraGotoNextMatch)) { _ in
            guard Workspace.shared === workspace else { return }
            navigateMatch(direction: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraGotoPreviousMatch)) { _ in
            guard Workspace.shared === workspace else { return }
            navigateMatch(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowGotoLine)) { _ in
            guard Workspace.shared === workspace else { return }
            showGotoLineDialog()
        }
    }

    /// Modaler Mini-Dialog für CMD+J. NSAlert + NSTextField reicht — ein
    /// eigenes SwiftUI-Sheet wäre für diesen einen Eingabe-Slot Overkill.
    private func showGotoLineDialog() {
        let alert = NSAlert()
        alert.messageText = L10n.string("Zu Zeile springen")
        alert.informativeText = L10n.string("Eingabe: Zeile oder Zeile:Spalte")
        alert.addButton(withTitle: L10n.string("Springen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L10n.string("z.B. 42 oder 42:8")
        alert.accessoryView = field
        // Initial-Fokus aufs Textfeld setzen, damit der Nutzer direkt
        // tippen kann; sonst müsste er erst klicken.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let (line, col) = GotoLineParse.parse(field.stringValue) else {
            NSSound.beep()
            return
        }
        let text = workspace.activeTabContent.wrappedValue
        let range = BufferSearch.nsRange(forLine: line, column: col, in: text)
        NotificationCenter.default.post(name: .fastraJumpToRange,
                                        object: nil,
                                        userInfo: ["range": NSValue(range: range)])
    }

    /// Schaltet `activeMatchIndex` weiter und postet einen Editor-Sprung.
    /// Funktioniert in beiden Scopes: im Folder-Scope lädt der Sprung bei
    /// Bedarf die Ziel-Datei in einen Tab, bevor zur Range gesprungen wird.
    private func navigateMatch(direction: Int) {
        let list = workspace.navMatches
        let count = list.count
        guard count > 0 else { return }
        // Diskrete Such-Aktion → ins Such-History-Popup aufnehmen (K4).
        workspace.recordSearchHistory()
        var next = workspace.activeMatchIndex + direction
        if workspace.wrapAround {
            next = ((next % count) + count) % count
        } else {
            next = max(0, min(count - 1, next))
        }
        workspace.activeMatchIndex = next
        let target = list[next]
        if let tabID = target.tabID {
            // Geöffnet-Scope: Ziel ist ein offener Tab (auch ungespeichert).
            // Tab aktivieren, Sprung einen Runloop-Tick später posten — der
            // Tab-Wechsel erzeugt den Editor neu (.id-Kopplung), der Sprung
            // braucht den fertigen Editor (gleiches Muster wie loadFile-
            // Completion im Ordner-Pfad).
            if workspace.activeTabID != tabID { workspace.activeTabID = tabID }
            DispatchQueue.main.async {
                NotificationCenter.default.postMatchJump(target.match)
            }
        } else if let url = target.url, workspace.activeTab?.url != url {
            // Datei asynchron laden — Editor-Sprung erst in der Completion,
            // damit der Tab mit fertigem Inhalt existiert (Race vermieden).
            workspace.loadFile(at: url) { ok in
                guard ok else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.postMatchJump(target.match)
                }
            }
        } else {
            // Datei ist schon offen — Sprung sofort ausführbar.
            DispatchQueue.main.async {
                NotificationCenter.default.postMatchJump(target.match)
            }
        }
    }
}

// (#Preview-Block entfernt, weil er beim `swift build` von Kommandozeile aus
//  einen Xcode-eigenen Macro-Plugin braucht. Beim Öffnen in Xcode 16+ funktionieren
//  normale SwiftUI-Previews automatisch.)
