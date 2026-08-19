import SwiftUI
import UniformTypeIdentifiers

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
    /// Schwebende XPath-Leiste (Etappe 5) — gleiche Lebenszeit-Logik.
    @State private var xpathPanel: XPathPanelController?

    /// Sichtbarkeit des dezenten Donation-Banners (Donationware-Modell).
    /// Entscheidung beim Erscheinen über die pure DonationPrompt-Logik
    /// (ab dem 10. Start, 90 Tage Ruhe nach „Später").
    @State private var showDonationBanner = false
    /// Gemeinsames Drop-Ziel des ganzen Dokumentfensters — gilt dadurch auch
    /// auf der Willkommen-Seite, auf der noch kein `EditorView` existiert.
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
                .frame(height: 36 * uiScale)

            // Editor nimmt jetzt den ganzen Platz ein. Das untere
            // DiffPanelView ist mit v0.5 aus dem Hauptfenster entfernt
            // (Daniel-Entscheidung 2026-05-26): Die Sofort-Trefferliste
            // in der Suchmaske erfüllt den primären Bedarf. Eine
            // ausgewachsene Side-by-side-Diff-Vorschau erscheint bei Bedarf
            // als Sheet über diesem Hauptfenster.
            //
            // Willkommens-Platzhalter (Umbau 2026-07-30): Der Editor ist
            // IMMER montiert — der Willkommensinhalt liegt als Overlay über
            // der Editorfläche, solange der aktive Tab unberührt leer ist
            // (Bedingung pur in WelcomeLogic, getestet; Overlay in
            // EditorView). Der Cursor steht dabei tippbereit in Zeile 1.
            EditorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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

            // Mindest-, KEINE Festhöhe: Die Fußzeile ist mal höher als 24 pt —
            // der Ansichts-Umschalter (Text/Hex) erscheint nur bei einer
            // gespeicherten Datei und ist als Segmentregler höher als reiner
            // Text. Eine feste Höhe ließ den Inhalt über den Rahmen
            // hinauswachsen; unten schnitt ihn der Fensterrand ab, sodass die
            // Fußzeile beim Öffnen einer vorhandenen Datei nur halb zu sehen
            // war (Daniel-Befund 2026-08-06).
            StatusBarView()
                .frame(minHeight: 24 * uiScale)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Theme.surfaceBase)
        .foregroundColor(Theme.textPrimary)
        // Dateien → Tabs, Ordner → Projekt. Der Hook sitzt an der gemeinsamen
        // Fensterwurzel und funktioniert in jedem Inhaltszustand.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedItems(from: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Theme.accentReadable, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        )
        // Der eigene Chrome darf bis hinter die transparente macOS-Titelleiste
        // reichen. Die oberen 38 Punkte lassen dabei den Ampelknöpfen Platz.
        .ignoresSafeArea(.container, edges: .top)
        // Zero-Size-AppKit-Brücke: synchronisiert die aktive Datei mit dem
        // nativen Fenster. AppKit baut daraus das CMD-Klick-Pfadmenü und kann
        // dessen Ordner direkt im Finder öffnen.
        .background(
            MainWindowTitleBridge(metadata: .from(workspace.activeTab,
                                                  welcomeActive: workspace.isWelcomeScreen),
                                  workspace: workspace,
                                  chromeHeight: 36 * uiScale)
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
        // 4D-Makro-Vorschau (Idee #28): Diff „aktueller Puffer → Makro-
        // Ergebnis" mit Anwenden/Abbrechen. Ohne diese Vorschau schreibt kein
        // Makrolauf in den Puffer.
        .sheet(item: $workspace.fourDMacroPreview) { state in
            FourDMacroPreviewSheet(state: state)
                .environmentObject(workspace)
        }
        // „Dateien vergleichen…" (Etappe 1 Wunschpaket 2026-07c): Sheet mit
        // Links/Rechts-Auswahl und Vergleichsoptionen; das Ergebnis öffnet
        // als eigener Diff-Tab.
        .sheet(isPresented: $workspace.showCompareFilesDialog) {
            CompareFilesDialog(
                workspace: workspace,
                preselectedTabIDs: workspace.compareDialogPrefillTabIDs
            )
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
        // (siehe AppDelegate.installKeyMonitor). Eine bereits offene,
        // befüllte Suche wird nur nach vorn geholt und behält ihren Scope.
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFile)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            // „Nur in Auswahl" (K3) automatisch einschalten, wenn beim Öffnen
            // eine MEHRZEILIGE Selektion im Editor steht (BBEdit-Verhalten).
            workspace.presentSearch(requestedScope: .file, captureSelection: true)
            searchPanel?.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFolder)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            workspace.presentSearch(requestedScope: .folder)
            searchPanel?.show()
        }
        // Menüpunkt „In Ordnern suchen…": Sein sichtbarer Text verspricht die
        // Ordnersuche, deshalb wird der Bereich hier erzwungen — anders als
        // beim bereichserhaltenden Kurzbefehl darüber.
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowSearchFolderForced)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            workspace.presentSearch(requestedScope: .folder, forceScope: true)
            searchPanel?.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraHideSearch)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            workspace.showSearchDialog = false
        }
        // CMD+G / CMD+SHIFT+G: durch die Treffer im aktiven Buffer
        // navigieren. Wir bewegen `activeMatchIndex` und schicken
        // einen Range-Sprung an den Editor.
        .onReceive(NotificationCenter.default.publisher(for: .fastraGotoNextMatch)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            navigateMatch(action: .move(.next, wrapAround: workspace.wrapAround))
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraGotoPreviousMatch)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            navigateMatch(action: .move(.previous, wrapAround: workspace.wrapAround))
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraGotoFirstMatch)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            navigateMatch(action: .first)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowGotoLine)) { note in
            guard notificationTargetsThisWorkspace(note) else { return }
            showGotoLineDialog()
        }
        // ⇧⌘X — XPath-Leiste über dem Editor öffnen (Etappe 5). Nur für
        // XML-artige Dokumente; das Menü ist sonst bereits deaktiviert.
        .onReceive(NotificationCenter.default.publisher(for: .fastraShowXPathBar)) { note in
            guard notificationTargetsThisWorkspace(note),
                  workspace.activeTabSupportsXPath else { return }
            if xpathPanel == nil {
                xpathPanel = XPathPanelController(workspace: workspace)
            }
            xpathPanel?.show(over: CommandTargeting.documentWindow(for: workspace))
        }
    }

    /// Neuere Befehle tragen den beim Tastendruck oder Menüklick bestimmten
    /// Workspace direkt in der Notification. Ziellose Nachrichten bleiben für
    /// bestehende Selbsttests und interne Aufrufer kompatibel und folgen dann
    /// dem bisherigen `Workspace.shared`-Verhalten.
    private func notificationTargetsThisWorkspace(_ notification: Notification) -> Bool {
        if let target = notification.object as? Workspace {
            return target === workspace
        }
        return Workspace.shared === workspace
    }

    /// Holt die Datei-URLs asynchron aus den Drag-Providern und routet sie auf
    /// dem Main-Thread über denselben Einstieg wie ⌘O.
    private func loadDroppedItems(from providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    for item in DropHandling.openableItems(from: [url]) {
                        workspace.openFileOrFolder(at: item)
                    }
                }
            }
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
        // Wie postMatchJump: zusätzlich konsumierbar hinterlegen, damit ein
        // gerade neu erzeugter Editor den Sprung nicht verliert.
        workspace.pendingEditorJump = PendingEditorJump(
            documentID: workspace.activeTab?.documentID,
            startLine: nil, startColumn: nil, endLine: nil, endColumn: nil,
            range: range)
        NotificationCenter.default.post(name: .fastraJumpToRange,
                                        object: workspace,
                                        userInfo: ["range": NSValue(range: range)])
    }

    /// Wendet eine pure Auswahlaktion auf die aktuelle Workspace-Liste an und
    /// führt nur das daraus gelieferte Ziel aus. Return im Suchfeld verwendet
    /// `.first`; Chevron, Pfeiltasten und ⌘G verwenden `.move`.
    private func navigateMatch(action: SearchMatchSelection.Action) {
        let matches = workspace.navMatches
        let transition = SearchMatchSelection.transition(
            activeIndex: workspace.activeMatchIndex,
            matches: matches,
            action: action
        )
        guard case .activate(let target) = transition.output else { return }
        // Diskrete Such-Aktion → ins Such-History-Popup aufnehmen (K4).
        workspace.recordSearchHistory()
        workspace.activeMatchIndex = transition.state.index
        if let tabID = target.tabID {
            // Geöffnet-Scope: Ziel ist ein offener Tab (auch ungespeichert).
            // Tab aktivieren, Sprung einen Runloop-Tick später posten — der
            // Tab-Wechsel erzeugt den Editor neu (.id-Kopplung), der Sprung
            // braucht den fertigen Editor (gleiches Muster wie loadFile-
            // Completion im Ordner-Pfad).
            if workspace.activeTabID != tabID { workspace.selectTab(id: tabID) }
            DispatchQueue.main.async {
                NotificationCenter.default.postMatchJump(target.match, for: workspace)
            }
        } else if let url = target.url, workspace.activeTab?.url != url {
            // Datei asynchron laden — Editor-Sprung erst in der Completion,
            // damit der Tab mit fertigem Inhalt existiert (Race vermieden).
            workspace.loadFile(at: url) { ok in
                guard ok else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.postMatchJump(target.match, for: workspace)
                }
            }
        } else {
            // Datei ist schon offen — Sprung sofort ausführbar.
            DispatchQueue.main.async {
                NotificationCenter.default.postMatchJump(target.match, for: workspace)
            }
        }
    }
}

// (#Preview-Block entfernt, weil er beim `swift build` von Kommandozeile aus
//  einen Xcode-eigenen Macro-Plugin braucht. Beim Öffnen in Xcode 16+ funktionieren
//  normale SwiftUI-Previews automatisch.)
