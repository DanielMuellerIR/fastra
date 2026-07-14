import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

// Trick aus Phase 2: SourceEditor.MinimapView.setTheme(...) ruft `brightnessComponent`
// auf jeder Theme-Farbe auf. Das ist nur im RGB-Colorspace definiert und wirft auf
// `NSColor.white` / `NSColor(white:alpha:)` (= Gray-Colorspace) eine NSInvalidArgumentException.
// Alle Theme-Farben unten via `rgb(...)`-Helper im sRGB-Space.

/// Phase-2-Editor: echter Text-Editor mit Sprach-Highlighting via CodeEditSourceEditor.
struct EditorView: View {
    @EnvironmentObject var workspace: Workspace
    @Environment(\.uiScale) private var uiScale
    @State private var editorState = SourceEditorState(cursorPositions: [], findPanelVisible: false)
    @StateObject private var minimapLayoutCoordinator = MinimapLayoutCoordinator()

    /// Anker-Offset der laufenden Selektion (Zeichen-Index der *fixen*
    /// Kante). Brauchen wir, weil `CursorPosition` nur den Bereich kennt
    /// (start = unten, end = oben), aber NICHT die Richtung, in die der
    /// Nutzer gerade zieht. Der Footer soll die *bewegte* Kante (am
    /// Mauszeiger) zeigen — dafür merken wir uns, welche Kante stillsteht.
    /// `nil` = aktuell keine Selektion (nur Cursor).
    @State private var selectionAnchor: Int?

    /// Aktueller Seitenleisten-Modus (Dateien / Änderungen / Graph). Nur bei
    /// Git-Repo umschaltbar; ohne Repo immer „Dateien".
    @State private var sidebarMode: SidebarMode = .files

    /// Zeilenumbruch am Fensterrand (BBEdit „Soft Wrap Text"). App-weite,
    /// persistente Einstellung — gesetzt über den Menüpunkt „Zeilen umbrechen"
    /// (FastraApp) bzw. später den Einstellungs-Dialog. Default AN: ohne
    /// Umbruch ist langer Text bei fehlendem Start-Scrollbalken sonst gar
    /// nicht erreichbar (siehe `syncHorizontalScroller`).
    @AppStorage("editor.wrapLines") private var wrapLines = true

    /// Rechter Vorschau-Streifen (CESE-Minimap) an/aus. App-weit und persistent,
    /// umschaltbar über „Darstellung → Minimap anzeigen". Default AUS
    /// (Daniel-Befund 2026-07-12): Die Minimap verdeckte rechts Text, bis ein
    /// Relayout griff, und stand im Verdacht, über eine Exception im
    /// Minimap-Layout-Pfad die Editor-Darstellung einfrieren zu lassen. Wie
    /// `wrapLines` reconciled CESE die Änderung live (`peripherals.showMinimap`).
    @AppStorage("editor.showMinimap") private var showMinimap = false
    @AppStorage(DocumentZoom.defaultsKey) private var documentZoomLevel = 0
    @AppStorage(EditorFonts.defaultsKey) private var editorFontName = EditorFonts.systemMonospacedName
    @AppStorage("markdown.integratedPreview") private var showMarkdownPreview = true
    @AppStorage("markdown.previewWidth") private var markdownPreviewWidth = 420.0
    /// Direkter Seitenleisten-Schalter im Fenster-Chrome, wie in Codex.
    /// AppStorage hält alle Dokumentfenster und den Menüpunkt synchron.
    @AppStorage("editor.sidebarVisible") private var showSidebar = true

    /// Breite der linken Seitenleiste (Dateibaum/„GEÖFFNET"). App-weit und
    /// persistent; über den Splitter zwischen Seitenleiste und Editor ziehbar
    /// (Daniel-Wunsch 2026-07-12). Geklemmt auf einen sinnvollen Bereich.
    @AppStorage("editor.sidebarWidth") private var sidebarWidth = 200.0

    /// Grenzen der Seitenleisten-Breite beim Ziehen des Splitters.
    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 480

    /// Effektives Erscheinungsbild des Fensters (hell/dunkel) — wählt das
    /// CESE-Editor-Theme. Ändert sich die Appearance (System-Wechsel oder
    /// Einstellungs-Dialog), rendert SwiftUI neu → `editorConfiguration`
    /// wird ungleich → CESE reconcilet das Theme live (gleicher Mechanismus
    /// wie bei `wrapLines`).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                VStack(spacing: 0) {
                    // Wie in Codex gehört die Marke zur Seitenleiste, nicht zu
                    // einem fensterbreiten zweiten Header. Rechts kann der
                    // Editor deshalb direkt unter den obersten Tabs beginnen.
                    SidebarBrandView()
                        .frame(height: 44 * uiScale)
                    Divider().opacity(0.4)
                    sidebar
                }
                // Breite kommt aus der persistenten Einstellung; per Splitter
                // ziehbar (siehe `sidebarSplitter`). Klemmen schützt vor einer
                // gespeicherten Un-Breite (z.B. 0) aus einer früheren Version.
                .frame(width: min(max(CGFloat(sidebarWidth), sidebarMinWidth), sidebarMaxWidth))
                .frame(maxHeight: .infinity)
                .background(Theme.surfaceBase)
                // AppKit-Editor und Vorschau besitzen kräftige Idealgrößen.
                // Die linke Navigation bleibt dennoch stets am Fensterrand.
                .layoutPriority(2)

                sidebarSplitter
            }

            sourceEditor
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)
                .background(Theme.surfaceRaised)
                // Gutter-Durchschuss-Fix (Daniel-Befund 2026-06-22): CESEs
                // Gutter ist ein FLOATING-Subview des ScrollViews und zeichnet
                // über den oberen Rand des Editor-Bereichs hinaus ins Tab-/
                // Header-Band (nicht vom Titelleisten-Inset verursacht — das
                // Setzen von contentInsets=0 änderte den Überstand nicht).
                // `.clipped()` begrenzt die Editor-Darstellung hart auf ihren
                // eigenen Rahmen, der bereits unter der Tab-Leiste liegt.
                .clipped()
            if showsIntegratedMarkdownPreview {
                markdownSplitter
                MarkdownPreviewView(workspace: workspace)
                    .frame(width: min(max(CGFloat(markdownPreviewWidth), 260), 760))
                    .clipped()
            }
        }
        .onAppear {
            // Alte gespeicherte Werte konnten bis 140 pt reichen. Den Wert
            // selbst anheben, damit der erste Splitter-Drag nicht von einer
            // unsichtbaren 140-pt-Ausgangslage auf 180 pt springt.
            sidebarWidth = min(max(sidebarWidth, Double(sidebarMinWidth)),
                               Double(sidebarMaxWidth))
        }
    }

    private var showsIntegratedMarkdownPreview: Bool {
        guard showMarkdownPreview, let tab = workspace.activeTab else { return false }
        let name = tab.title.lowercased()
        return name.hasSuffix(".md") || name.hasSuffix(".markdown")
    }

    private var markdownSplitter: some View {
        ResizableDivider(value: $markdownPreviewWidth,
                         range: 260...760,
                         direction: -1,
                         surface: Theme.surfaceRaised,
                         help: "Ziehen, um die Breite der Markdown-Vorschau anzupassen")
    }

    // MARK: Source-Editor-Pane

    /// Zeigt entweder einen Lade-Spinner (während isLoading = true) oder den
    /// eigentlichen SourceEditor. Das Umschalten auf isLoading = false erzwingt
    /// via `.id(activeTab.id)` eine Neuerzeugung des Editors — dadurch ruft
    /// `makeNSViewController` mit dem bereits geladenen Inhalt auf, und die
    /// CESE-Falle (Editor übernimmt Binding-Änderungen nicht nach dem Init)
    /// greift nicht.
    private var sourceEditor: some View {
        Group {
            if let kind = workspace.activeTab?.gitKind {
                // Git-Text-Tab (Etappe 2): read-only Verlauf/Diff statt CESE.
                GitTextView(kind: kind, content: workspace.activeTab?.content ?? "")
                    .id(workspace.activeTab?.id)
            } else if workspace.activeTab?.isLoading == true {
                // Lade-Zustand: Spinner + Dateiname, kein Editor.
                // Der Editor wird erst nach Completion neu eingeblendet.
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(verbatim: L10n.format("Lade %@", workspace.activeTab?.title ?? "…"))
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surfaceRaised)
                // ID an die Tab-ID koppeln — wenn isLoading wechselt, ändert
                // sich die Tab-ID NICHT, aber die `Group`-Verzweigung wechselt.
                // Das `.id` hier ist nur Sicherheitsnetz für den Editor unten.
                .id(workspace.activeTab?.id)
            } else if let tab = workspace.activeTab, tab.displayMode == .hex,
                      let url = tab.url {
                HexFileView(url: url, fileSize: tab.fileSize)
                    .id(tab.id)
            } else if let tab = workspace.activeTab, tab.displayMode == .chunkedText,
                      let url = tab.url {
                ChunkedTextFileView(url: url, fileSize: tab.fileSize)
                    .id(tab.id)
            } else {
                actualEditor
            }
        }
    }

    /// Der eigentliche CodeEditSourceEditor — nur gezeigt, wenn isLoading = false.
    private var actualEditor: some View {
        SourceEditor(
            workspace.activeTabContent,
            language: detectedLanguage,
            configuration: editorConfiguration,
            state: $editorState,
            coordinators: [minimapLayoutCoordinator]
        )
        .background(GutterDimmingBridge().frame(width: 0, height: 0))
        // Frisch erscheinender Editor (neuer Tab ⌘T, Tab-Wechsel, fertig geladene
        // Datei, programmatischer Reload) soll sofort den Tastaturfokus bekommen —
        // sonst verpuffte nach ⌘T ein direktes ⌘V (Daniel-Befund 2026-06-25).
        .onAppear { Self.focusActiveEditor() }
        // Cursor-Position aus dem Editor-State in den Workspace spiegeln,
        // damit der Footer (StatusBarView) Zeile/Spalte zeigen kann.
        .onChange(of: editorState.cursorPositions) { _, positions in
            let list = positions ?? []
            updateFooterCursor(from: list)
            scheduleStats(for: list)
        }
        // Zombie-Find-Bar deterministisch verhindern: Wenn der Editor sein
        // eigenes Find-Panel öffnet (CMD+F bei fokussiertem Editor), schreibt
        // CodeEditSourceEditor `findPanelVisible = true` in den State zurück.
        // Wir fangen das ab, schließen das Editor-Panel sofort wieder
        // (findPanelVisible = false → der Editor reconciled und blendet aus)
        // und öffnen STATTDESSEN unsere eigene Suchmaske. Das ist unabhängig
        // von der (nicht steuerbaren) Reihenfolge der Event-Monitore.
        .onChange(of: editorState.findPanelVisible) { _, visible in
            guard visible == true else { return }
            editorState.findPanelVisible = false
            NotificationCenter.default.post(name: .fastraShowSearchFile, object: nil)
        }
        // Inhalts-Änderungen (Tippen, Datei-Wechsel) lösen ebenfalls eine
        // Neuberechnung aus — sonst hinkt die Zeichen-/Wort-/Zeilen-Zahl.
        .onChange(of: workspace.activeTabContent.wrappedValue) { _, _ in
            scheduleStats(for: editorState.cursorPositions ?? [])
        }
        .onAppear {
            scheduleStats(for: editorState.cursorPositions ?? [])
        }
        // Editor-Sprung zur Treffer-Range (CMD+G / List-Klick / Chevron-
        // Button). Wir schreiben die Range direkt in cursorPositions —
        // CodeEditSourceEditor synchronisiert das in eine Selektion +
        // scrollt automatisch in die sichtbare Region.
        .onReceive(NotificationCenter.default.publisher(for: .fastraJumpToRange)) { note in
            // NotificationCenter ist app-weit. Jedes Dokumentfenster besitzt
            // aber einen eigenen Workspace und darf ausschließlich seine
            // eigenen Suchtreffer verarbeiten.
            guard Self.jumpNotification(note, targets: workspace) else { return }
            let info = note.userInfo
            // Absolute Range als Fallback fürs Scrollen (z.B. „Zu Zeile
            // springen", CMD+J, ohne Zeile/Spalte im userInfo).
            let fallbackRange = (info?["range"] as? NSValue)?.rangeValue
            var jumpLine: Int? = nil
            // Bevorzugter Pfad: Zeile/Spalte (start + end). CESE mappt das
            // gegen sein eigenes Zeilen-Layout → robust gegen Offset-Drift
            // zwischen Such-Inhalt und Editor-Storage (siehe
            // NotificationCenter.postMatchJump).
            if let sl = info?["startLine"] as? Int, let sc = info?["startColumn"] as? Int,
               let el = info?["endLine"] as? Int, let ec = info?["endColumn"] as? Int {
                editorState.cursorPositions = [CursorPosition(
                    start: CursorPosition.Position(line: sl, column: sc),
                    end: CursorPosition.Position(line: el, column: ec))]
                jumpLine = sl
            } else if let value = info?["range"] as? NSValue {
                editorState.cursorPositions = [CursorPosition(range: value.rangeValue)]
            }
            // Sichtbar scrollen, aber den Fokus in der Suchmaske lassen. Der
            // nächste Tastendruck darf das Dokument niemals verändern.
            EditorView.scrollEditorForVisibleJump(in: workspace,
                                                  targetLine: jumpLine,
                                                  fallbackRange: fallbackRange)
        }
        // WICHTIG: CodeEditSourceEditor setzt den Text NUR EINMAL in
        // `makeNSViewController`. Sein `updateNSViewController` schiebt
        // Binding-Änderungen NICHT in die TextView zurück (Text fließt nur
        // TextView → Binding). Bei einem Tab-Wechsel UND nach abgeschlossenem
        // asynchronen Laden (isLoading wechselt false → sourceEditor wechselt
        // auf actualEditor) wird der Editor neu erzeugt → `makeNSViewController`
        // läuft mit dem bereits vollständig geladenen Inhalt. Die ID bleibt
        // beim Tippen konstant — Eingaben werden NICHT unterbrochen.
        //
        // `editorReloadNonce` hängt zusätzlich an der ID: ein PROGRAMMATISCHER
        // Buffer-Replace (Alle/Einzel-Ersetzen) zählt ihn hoch → der Editor wird
        // mit dem ersetzten Inhalt neu erzeugt und zeigt die Änderung sofort
        // (sonst bliebe der alte Text stehen — „Ersetzen wirkt folgenlos").
        .id(EditorView.editorIdentity(tabID: workspace.activeTab?.id,
                                      reloadNonce: workspace.editorReloadNonce))
        // Empty-State-Overlay: zentrierter Hinweis, wenn der Tab geladen
        // ist, aber noch keinen Inhalt hat. allowsHitTesting(false) ist
        // ZWINGEND — Klicks und Tastatureingaben sollen den Editor (der im
        // Hintergrund liegt) ungehindert erreichen. Beim ersten getippten
        // Zeichen ist content nicht mehr leer → SwiftUI blendet das Overlay
        // automatisch aus; der Editor wird dabei NICHT neu erzeugt, weil
        // .id(tab.id) konstant bleibt.
        .overlay(
            Group {
                if workspace.activeTab != nil
                    && workspace.activeTabContent.wrappedValue.isEmpty {
                    VStack(spacing: 6) {
                        Text("Datei öffnen (⌘O), Text eingeben oder Datei hierher ziehen")
                            .fastraFont(.small)
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .allowsHitTesting(false)
                }
            }
        )
    }

    /// Stabile, hashbare Editor-Identität aus Tab-ID + Reload-Nonce. Ändert
    /// sich die Tab-ID (Tab-Wechsel) ODER der Nonce (programmatischer Buffer-
    /// Replace), erzeugt SwiftUI den Editor neu — der einzige Weg, auf dem
    /// CodeEditSourceEditor frischen Inhalt übernimmt. Pur → unit-testbar.
    // codereview-ok: doppelter Identitätswechsel bei isLoading-Flip + Nonce-Inkrement ist bewusstes Design (Editor-Neuerzeugung ist der einzige Reload-Weg); kein sichtbares Fehlverhalten (2026-07-06)
    static func editorIdentity(tabID: UUID?, reloadNonce: Int) -> String {
        "\(tabID?.uuidString ?? "none")#\(reloadNonce)"
    }

    /// Footer-Statistik neu anstoßen: bei aktiver Selektion auf die
    /// Selektion bezogen, sonst auf die ganze Datei.
    private func scheduleStats(for positions: [CursorPosition]) {
        let primaryRange = positions.last?.range
        let selection = (primaryRange?.length ?? 0) > 0 ? primaryRange : nil
        // Selektion in den Workspace spiegeln — Quelle für „Nur in Auswahl"
        // (K3) und „Auswahl als Suchbegriff" (⌘E, K5). Bewusst die LIVE-
        // Selektion; das Einfrieren für die Suche macht der Workspace selbst
        // (setSearchInSelectionOnly), damit ein Treffer-Sprung den Such-
        // Bereich nicht zusammenschrumpft.
        workspace.selectionRange = selection
        workspace.recomputeDocumentStats(
            fullText: workspace.activeTabContent.wrappedValue,
            selectionNSRange: selection
        )
    }

    /// Bestimmt aus den Selektionen die Position der *bewegten* Kante und
    /// schreibt sie in den Workspace (Footer-Anzeige).
    ///
    /// Hintergrund: `CursorPosition` liefert `start` (untere Offset-Kante)
    /// und `end` (obere Kante) eines Bereichs, aber keine Information
    /// darüber, in welche Richtung gerade gezogen wird. BBEdit zeigt im
    /// Footer immer die Kante am Mauszeiger. Dafür merken wir uns in
    /// `selectionAnchor` die *stillstehende* Kante und zeigen die andere.
    private func updateFooterCursor(from positions: [CursorPosition]) {
        // Für den Footer zählt der primäre (letzte) Cursor.
        guard let primary = positions.last else {
            workspace.cursorLine = nil
            workspace.cursorColumn = nil
            selectionAnchor = nil
            return
        }

        let resolved = CursorFooter.resolve(
            rangeLocation: primary.range.location,
            rangeLength: primary.range.length,
            startLine: primary.start.line,
            startColumn: primary.start.column,
            endLine: primary.end?.line,
            endColumn: primary.end?.column,
            previousAnchor: selectionAnchor
        )
        setFooter(line: resolved.line, column: resolved.column)
        selectionAnchor = resolved.anchor
    }

    private func setFooter(line: Int, column: Int) {
        guard line > 0, column > 0 else { return }
        workspace.cursorLine = line
        workspace.cursorColumn = column
    }

    /// Prüft die Fensteradresse eines Editor-Sprungs unabhängig von SwiftUI.
    /// Diese kleine Grenze ist unit-testbar; die tatsächliche Selektion und das
    /// Scrollen bleiben Aufgabe des In-App-Selbsttests.
    static func jumpNotification(_ notification: Notification,
                                 targets workspace: Workspace) -> Bool {
        guard let targetWorkspace = notification.object as? Workspace else { return false }
        return targetWorkspace === workspace
    }

    /// Scrollt den Editor sichtbar zum Suchtreffer, ohne dem Suchfenster den
    /// Tastaturfokus zu entreißen. Die TextView darf dabei ausdrücklich NICHT
    /// First Responder werden: Sonst landet das nächste Return unbemerkt im
    /// Dokument. Leicht verzögert (`async`), damit CESE die neue Cursor-
    /// Position schon übernommen hat, bevor wir scrollen.
    static func scrollEditorForVisibleJump(in workspace: Workspace,
                                           targetLine: Int?, fallbackRange: NSRange?) {
        DispatchQueue.main.async {
            guard let mainWindow = NSApp.windows.first(where: {
                !SearchWindow.isSearchWindow($0)
                    && WorkspaceWindowRegistry.workspace(for: $0) === workspace
                    && $0.contentView != nil && $0.isVisible
            }), let root = mainWindow.contentView,
                  let tv = firstEditorTextView(in: root) else { return }
            guard let textView = tv as? CodeEditTextView.TextView else { return }
            // Robust zum Treffer scrollen (Daniel-Befund 2026-06-22: Treffer
            // markiert, aber Dokument scrollte in einer 41k-Zeilen-Datei NICHT
            // hin). CESEs `setCursorPositions(scrollToVisible:)` ruft
            // `scrollSelectionToVisible()`, das bei großen Dokumenten versagt:
            // ist die Ziel-Zeile noch nicht ausgelegt, ist der Selektions-
            // `boundingRect` == .zero und die innere `while`-Schleife läuft gar
            // nicht erst an (Henne-Ei). `scrollToRange(_:)` umgeht das über
            // `rectForOffset` (schätzt die y-Position auch ungelegter Zeilen).
            //
            // WICHTIG: Ziel aus der ZEILENNUMMER rechnen, NICHT aus
            // `selectedRange()`. Der CESE-Reconcile, der die Selektion aus
            // Zeile/Spalte setzt, ist zu diesem async-Zeitpunkt NICHT garantiert
            // durch — ein zu früher `selectedRange()`-Read lieferte (0,0) und
            // scrollte an den Datei-Anfang (genau der Regressions-Bug aus der
            // Vorrunde). `textLineForIndex` kennt die Zeile aus dem Line-Storage
            // (samt geschätzter y-Position), auch wenn sie noch nicht ausgelegt
            // ist — unabhängig vom Selektions-Timing.
            let target: NSRange
            if let targetLine, targetLine > 0,
               let linePos = textView.layoutManager.textLineForIndex(targetLine - 1) {
                target = NSRange(location: linePos.range.lowerBound, length: 0)
            } else if let fallbackRange {
                target = fallbackRange
            } else {
                return
            }
            // Konvergierend scrollen statt one-shot (Daniel-Befund 2026-06-23):
            // bei Umbruch wrappen lange Zeilen mehrzeilig → variable Höhen. Die
            // y-Position aus `rectForOffset` summiert für noch nicht ausgelegte
            // Zeilen die GESCHÄTZTE 1-Zeilen-Höhe → der Sprung landet zu kurz
            // (Fehler wächst mit der Tiefe; Treffer in Zeile 1256 landete bei
            // ~485). Jeder Scroll legt den neu sichtbaren Bereich aus (echte
            // Höhen), wodurch die Ziel-Schätzung nach unten wandert; iteratives
            // Nachscrollen konvergiert so auf die echte Position.
            convergeScroll(textView, targetLine: targetLine, fallback: target)
        }
    }

    /// Macht die Editor-TextView des Hauptfensters zum First Responder, sobald ein
    /// (neuer) Editor erscheint — neuer Tab (⌘T), Tab-Wechsel, abgeschlossenes
    /// Laden oder ein programmatischer Reload (jeweils ein `.id`-Remount des
    /// SourceEditors). Ohne das blieb nach ⌘T der Editor unfokussiert, und ein
    /// sofortiges ⌘V verpuffte, bis man einmal in den Text klickte (Daniel-Befund
    /// 2026-06-25).
    ///
    /// Anders als `scrollEditorForVisibleJump` wird diese Methode nur beim
    /// normalen Editor-Aufbau verwendet:
    /// Ist gerade die schwebende Suchmaske vorne (der Nutzer tippt dort), darf der
    /// Editor ihr den Tastaturfokus NICHT entreißen — wir fokussieren nur, wenn das
    /// Hauptfenster ohnehin schon Key ist (der Normalfall direkt nach ⌘T/Tab-Klick).
    /// Leicht verzögert (`async` + kleiner Delay), damit die frisch erzeugte
    /// TextView schon in der View-Hierarchie hängt, bevor wir sie fokussieren.
    static func focusActiveEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let mainWindow = NSApp.windows.first(where: {
                !SearchWindow.isSearchWindow($0)
                    && $0.contentView != nil && $0.isVisible
            }), let root = mainWindow.contentView,
                  let tv = firstEditorTextView(in: root) else { return }
            // Nur fokussieren, wenn das Hauptfenster Key ist — sonst (offene
            // Suchmaske vorne) würden wir der Maske den Tastaturfokus klauen.
            guard mainWindow.isKeyWindow else { return }
            mainWindow.makeFirstResponder(tv)
        }
    }

    /// Scrollt iterativ zur Ziel-Zeile, bis die TATSÄCHLICH zentrierte Zeile
    /// (unabhängig über `textLineForPosition` gemessen, NICHT über die
    /// `rectForOffset`-Schätzung) nahe genug am Ziel ist. Nötig, weil
    /// `scrollToRange` bei mehrzeilig gewrappten Zeilen wegen geschätzter
    /// Zeilenhöhen zu kurz scrollt; jeder Lauf legt mehr Zeilen aus und
    /// korrigiert die Schätzung. Abbruch bei Toleranz, Stillstand oder
    /// Versuchs-Limit (kein Endlos-Loop).
    private static func convergeScroll(_ tv: CodeEditTextView.TextView,
                                       targetLine: Int?, fallback: NSRange,
                                       attempt: Int = 0, lastShown: Int = -1) {
        // Ziel-Offset bei jedem Lauf NEU aus der Zeile bestimmen (die
        // ausgelegten Höhen ändern die Position nicht, aber so bleibt es robust).
        let targetRange: NSRange
        if let targetLine, targetLine > 0,
           let lp = tv.layoutManager.textLineForIndex(targetLine - 1) {
            targetRange = NSRange(location: lp.range.lowerBound, length: 0)
        } else {
            targetRange = fallback
        }
        tv.scrollToRange(targetRange)

        // Ohne Zeilennummer (z.B. reiner Range-Sprung) keine Konvergenz nötig.
        guard let targetLine, targetLine > 0, attempt < 16 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
            guard let shown = tv.layoutManager.textLineForPosition(tv.visibleRect.midY)?.index else { return }
            let shownLine = shown + 1
            // Nah genug → fertig. Kein Fortschritt mehr (Stillstand) → aufhören.
            if abs(shownLine - targetLine) <= 2 || shownLine == lastShown { return }
            convergeScroll(tv, targetLine: targetLine, fallback: fallback,
                           attempt: attempt + 1, lastShown: shownLine)
        }
    }

    /// Findet die Haupt-Textfläche des Editors. CodeEditSourceEditor nutzt
    /// keine `NSTextView`, sondern eine eigene `TextView: NSView` (Modul
    /// CodeEditTextView) — daher Suche über den Klassennamen (gleiche Heuristik
    /// wie im Selbsttest `editorTextView`).
    private static func firstEditorTextView(in view: NSView) -> NSView? {
        let name = String(describing: type(of: view))
        if name.contains("TextView"), view.acceptsFirstResponder, view.frame.height > 50 {
            return view
        }
        for sub in view.subviews {
            if let found = firstEditorTextView(in: sub) { return found }
        }
        return nil
    }

    /// Konfiguration stabil halten — sonst wird der SourceEditor bei jedem Render
    /// neu konfiguriert, was Layout-Pass-Reentry und einen QuartzCore-Crash auslösen kann.
    ///
    /// `layout.contentInsets` explizit auf 0 setzen (2026-06-22): Ohne gesetzte
    /// `contentInsets` schaltet CodeEditSourceEditor seinen ScrollView auf
    /// `automaticallyAdjustsContentInsets = true` (siehe CESE
    /// `TextViewController+StyleViews.swift`). In unserem Fenster mit
    /// `.windowStyle(.hiddenTitleBar)` meldet AppKit dann einen Titelleisten-
    /// Top-Inset (~28 pt) als Phantom-Polsterung über dem Text — den wollen wir
    /// nicht, weil der Editor ohnehin schon unter unserer Tab-Leiste sitzt; mit
    /// 0-Inset starten Gutter und Text bündig am oberen Editor-Rand.
    /// HINWEIS: Anfangs als Ursache für den Gutter-Durchschuss ins Header-Band
    /// vermutet — war es NICHT (der Überstand blieb mit 0-Inset unverändert).
    /// Den behebt das `.clipped()` oben in `body`. Der 0-Inset bleibt als
    /// sinnvolle Konfig für den versteckten Titelleisten-Modus.
    /// `additionalTextInsets` bleibt beim CESE-Default (1 pt oben/unten).
    /// Instanz-Property (nicht mehr `static`), damit der Zeilenumbruch
    /// reaktiv aus `wrapLines` kommt. Stabilität bleibt gewahrt: CESEs
    /// `paramsAreEqual` vergleicht die `configuration` per `==`
    /// (Equatable) — ein wertgleicher Neuaufbau pro Render löst KEINEN
    /// Reload aus (kein Layout-Reentry/QuartzCore-Crash). Nur eine echte
    /// `wrapLines`-Änderung erzeugt eine ungleiche Config → CESE-Reconcile
    /// setzt Umbruch + `hasHorizontalScroller` live.
    private var editorConfiguration: SourceEditorConfiguration {
        .init(
            appearance: .init(
                theme: colorScheme == .dark ? Self.fastraThemeDark : Self.fastraTheme,
                font: .fastraEditorFont(name: editorFontName, size: 13,
                                        scale: DocumentZoom.scale(for: documentZoomLevel)),
                wrapLines: wrapLines,
                tabWidth: 4
            ),
            layout: .init(contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
            // Rechter Vorschau-Streifen (Minimap) reaktiv aus `showMinimap`.
            // Eine echte Änderung erzeugt eine ungleiche Config → CESE
            // reconciled `minimapView.isHidden` + Text-Insets live (gleicher
            // Mechanismus wie bei `wrapLines`).
            peripherals: .init(showMinimap: showMinimap)
        )
    }

    private var detectedLanguage: CodeLanguage {
        if let url = workspace.activeTab?.url {
            if ["xml", "xsd", "xsl", "xslt", "plist"].contains(url.pathExtension.lowercased()) {
                // CodeEditLanguages bündelt keine separate XML-Grammatik.
                // Die HTML-Grammatik zeichnet Tags, Attribute und Strings
                // jedoch verlustfrei auch für XML und ist der passende
                // robuste Syntax-Fallback für Finder-geöffnete XML-Dateien.
                return .html
            }
            return CodeLanguage.detectLanguageFrom(url: url)
        }
        // Ohne URL: Sprache aus der angezeigten Dateiendung des Tabs raten.
        if let title = workspace.activeTab?.title {
            if DocumentKind.isXML(filename: title) { return .html }
            let fakeURL = URL(fileURLWithPath: title)
            return CodeLanguage.detectLanguageFrom(url: fakeURL)
        }
        return .default
    }

    // MARK: Sidebar (Projekt-Dateibaum + geöffnete Dateien)

    /// Ziehbarer Splitter zwischen Seitenleiste und Editor. Die gemeinsame
    /// Komponente besitzt eine breite Trefferfläche, einen stabilen Cursor und
    /// misst im globalen Koordinatenraum gegen das frühere Zappeln.
    private var sidebarSplitter: some View {
        ResizableDivider(value: $sidebarWidth,
                         range: Double(sidebarMinWidth)...Double(sidebarMaxWidth),
                         surface: Theme.surfaceBase,
                         trailingSurface: Theme.surfaceRaised,
                         help: "Ziehen, um die Breite der Seitenleiste anzupassen")
    }

    /// Ein Git-Repo ist geladen? (Nur dann erscheinen Änderungen/Graph.) Der
    /// Status wird für Repos asynchron gefüllt und ist für Nicht-Repos `nil`.
    private var isGitRepo: Bool { workspace.gitStatus != nil }

    /// Verfügbare Modi: ohne Repo nur „Dateien", mit Repo zusätzlich
    /// „Änderungen" und „Graph".
    private var availableModes: [SidebarMode] {
        isGitRepo ? [.files, .changes, .graph] : [.files]
    }

    /// Effektiver Modus — fällt auf „Dateien" zurück, wenn der gewählte Modus
    /// gerade nicht verfügbar ist (z.B. Projekt/Git geschlossen).
    private var effectiveMode: SidebarMode {
        availableModes.contains(sidebarMode) ? sidebarMode : .files
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Umschalter nur zeigen, wenn es überhaupt etwas umzuschalten gibt.
            if availableModes.count > 1 {
                SidebarModePicker(modes: availableModes, selection: $sidebarMode)
                Divider().opacity(0.3)
            }

            switch effectiveMode {
            case .files:   filesSidebar
            case .changes: GitChangesView()
            case .graph:   GitGraphView()
            }
        }
        // Test-Hook (nur Selbsttests): Seitenleisten-Modus vorwählen, damit ein
        // Screenshot gezielt „Änderungen"/„Graph" zeigen kann. Im Normalbetrieb
        // ist FASTRA_SIDEBAR nicht gesetzt → kein Effekt.
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["FASTRA_SIDEBAR"],
               let mode = SidebarMode.allCases.first(where: { $0.rawValue == raw || "\($0)" == raw }) {
                sidebarMode = mode
            }
        }
    }

    /// Bisheriger Seitenleisten-Inhalt: Projekt-Dateibaum (falls geladen) plus
    /// die „GEÖFFNET"-Liste der offenen Tabs.
    private var filesSidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Projekt geladen → hierarchischer Dateibaum oben, er bekommt
            // den flexiblen Platz; die „GEÖFFNET"-Liste rückt kompakt nach
            // unten. Ohne Projekt bleibt die Seitenleiste wie bisher.
            if let projectURL = workspace.projectURL {
                FileTreeSidebar(rootURL: projectURL)
                    .frame(maxHeight: .infinity)
                Divider().opacity(0.3)
            }

            Text("GEÖFFNET")
                .fastraFont(size: 10, weight: .semibold)
                .tracking(0.6)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ForEach(workspace.tabs) { tab in
                FileRow(tab: tab, isActive: tab.id == workspace.activeTab?.id)
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.activeTabID = tab.id }
            }

            if workspace.projectURL == nil {
                Spacer()
            }

            Button {
                workspace.openFile()
            } label: {
                Label("Datei öffnen…", systemImage: "plus")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Datei oder Ordner öffnen (⌘O)")
        }
    }
}

/// Kleine Symbol-Leiste über der Seitenleiste (Dateien / Änderungen / Graph).
private struct SidebarModePicker: View {
    let modes: [SidebarMode]
    @Binding var selection: SidebarMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    selection = mode
                } label: {
                    ZStack {
                        // Eine echte Fläche statt nur des Symbols: Bei
                        // `.plain` wäre sonst lediglich der gezeichnete Teil
                        // des SF Symbols als Klickziel zuverlässig aktiv.
                        Color.clear
                        Image(systemName: mode.systemImage)
                            .fastraFont(size: 12, weight: .medium)
                            .foregroundColor(selection == mode ? Theme.textPrimary : Theme.textSecondary)
                    }
                        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == mode ? Theme.surfaceRaised : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(L10n.string(mode.rawValue))
                .accessibilityLabel(Text(L10n.string(mode.rawValue)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FileRow: View {
    let tab: EditorTab
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            // accentReadable statt accent: kleines Icon auf hellem Hintergrund
            // braucht ausreichend Kontrast (~4,0:1 statt ~1,4:1 mit Goldgelb).
            Image(systemName: "doc")
                .foregroundColor(isActive ? Theme.accentReadable : Theme.textSecondary)
                .fastraFont(size: 11)
            // Willkommen-Tab konsistent zur Tab-Leiste als „Willkommen"
            // beschriften (nicht mit seinem Unterbau-Titel „Ohne Titel").
            Text(verbatim: tab.isWelcome ? L10n.string("Willkommen") : tab.title)
                .fastraFont(.small)
                .foregroundColor(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if tab.isDirty {
                // Dirty-Punkt: accentReadable statt accent — kleines
                // Zeichen auf hellem Grund braucht besseren Kontrast.
                Text("•")
                    .fastraFont(.small)
                    .foregroundColor(Theme.accentReadable)
            }
            Spacer()
            if tab.hits > 0 {
                Text("\(tab.hits)")
                    .fastraFont(size: 10, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isActive ? Theme.surfaceRaised : Color.clear)
    }
}

// MARK: - Theme

extension EditorView {
    /// Helles, neutrales Editor-Theme passend zum Codex-nahen Fenster-Chrome.
    /// Token-Farben sind bewusst dezent — der Editor soll lesbar bleiben, nicht überfärbt.
    ///
    /// **Wichtig:** Alle NSColor-Werte werden mit `srgbRed:green:blue:alpha:` konstruiert.
    /// `NSColor.white` und `NSColor(white:alpha:)` liegen im Grayscale-Colorspace, und
    /// `MinimapView.setTheme()` ruft auf jeder Theme-Farbe `brightnessComponent` auf —
    /// das wirft auf Gray-Colorspace-Farben eine NSInvalidArgumentException
    /// ("not valid for the NSColor Generic Gray Profile colorspace; need to convert").
    static let fastraTheme: EditorTheme = EditorTheme(
        text:           .init(color: rgb(0x36, 0x36, 0x36)),
        insertionPoint: rgb(0x36, 0x36, 0x36),
        invisibles:     .init(color: rgb(0x36, 0x36, 0x36, 0.18)),
        background:     rgb(0xFF, 0xFF, 0xFF),
        lineHighlight:  rgb(0xEC, 0xEC, 0xEC, 0.55),
        selection:      rgb(0x78, 0xA7, 0xE8, 0.42),
        keywords:   .init(color: rgb(0xA3, 0x39, 0x2A), bold: true),
        commands:   .init(color: rgb(0x2A, 0x66, 0xB5)),
        types:      .init(color: rgb(0x2A, 0x66, 0xB5), bold: true),
        attributes: .init(color: rgb(0xB5, 0x6C, 0x1A)),
        variables:  .init(color: rgb(0x36, 0x36, 0x36)),
        values:     .init(color: rgb(0xB5, 0x6C, 0x1A)),
        numbers:    .init(color: rgb(0xB5, 0x6C, 0x1A)),
        strings:    .init(color: rgb(0x2F, 0x5D, 0x3A)),
        characters: .init(color: rgb(0x2F, 0x5D, 0x3A)),
        comments:   .init(color: rgb(0x78, 0x78, 0x78), italic: true)
    )

    /// Dunkles Editor-Theme — neutrales Pendant zu `fastraTheme` (gleiche
    /// Token-Semantik, aufgehellte Farbwerte für dunklen Grund). Hintergrund
    /// = `Theme.surfaceRaised` (dunkel), damit Editor und umgebendes UI wie
    /// im Light-Mode dieselbe erhöhte Fläche teilen. Die Selektion verwendet
    /// denselben gedämpften Blauton wie das übrige UI.
    /// Bewusst STATISCHE sRGB-Farben, keine dynamischen Provider-Farben —
    /// CESEs Minimap ruft `brightnessComponent` auf (siehe Kommentar oben);
    /// die Umschaltung passiert in `editorConfiguration` über `colorScheme`.
    static let fastraThemeDark: EditorTheme = EditorTheme(
        text:           .init(color: rgb(0xF2, 0xF2, 0xF2)),
        insertionPoint: rgb(0xF2, 0xF2, 0xF2),
        invisibles:     .init(color: rgb(0xF2, 0xF2, 0xF2, 0.22)),
        background:     rgb(0x17, 0x17, 0x17),
        lineHighlight:  rgb(0x33, 0x33, 0x33, 0.62),
        selection:      rgb(0x5E, 0x8E, 0xCC, 0.48),
        keywords:   .init(color: rgb(0xE8, 0x8D, 0x7C), bold: true),
        commands:   .init(color: rgb(0x7F, 0xB0, 0xEE)),
        types:      .init(color: rgb(0x7F, 0xB0, 0xEE), bold: true),
        attributes: .init(color: rgb(0xDF, 0xA2, 0x5A)),
        variables:  .init(color: rgb(0xF2, 0xF2, 0xF2)),
        values:     .init(color: rgb(0xDF, 0xA2, 0x5A)),
        numbers:    .init(color: rgb(0xDF, 0xA2, 0x5A)),
        strings:    .init(color: rgb(0x94, 0xCE, 0x9F)),
        characters: .init(color: rgb(0x94, 0xCE, 0x9F)),
        comments:   .init(color: rgb(0x9A, 0x9A, 0x9A), italic: true)
    )

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0,
                green:   CGFloat(g) / 255.0,
                blue:    CGFloat(b) / 255.0,
                alpha:   a)
    }
}
