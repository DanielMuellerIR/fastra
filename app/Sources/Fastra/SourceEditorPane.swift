import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

struct SourceEditorPane: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var panes: SourcePaneRegistry
    @ObservedObject var memory: SourcePaneMemory
    let pane: SourcePaneID
    let language: CodeLanguage
    let configuration: SourceEditorConfiguration
    @StateObject private var sourceCoordinator: SourcePaneCoordinator

    init(workspace: Workspace, pane: SourcePaneID, language: CodeLanguage,
         configuration: SourceEditorConfiguration) {
        self.workspace = workspace; self.panes = workspace.sourcePanes
        self.memory = workspace.sourcePanes.memory(for: pane)
        self.pane = pane; self.language = language; self.configuration = configuration
        _sourceCoordinator = StateObject(wrappedValue: SourcePaneCoordinator(workspace: workspace, pane: pane))
    }
    private var isActive: Bool { (workspace.sourceSplitEnabled && workspace.canSplitSourceEditor ? panes.activePane : .primary) == pane }
    private var detectedLanguage: CodeLanguage { language }
    private var editorConfiguration: SourceEditorConfiguration { configuration }
    private var activeCustomLanguage: CustomLanguage? { EditorView.customLanguage(for: workspace.activeTab) }
    private var activeTabIsMarkdown: Bool { workspace.activeTabIsMarkdown }
    @StateObject private var minimapLayoutCoordinator = MinimapLayoutCoordinator()
    /// Highlight-Provider der Eigen-Sprachen (Registry, Etappe 3 Wunschpaket
    /// 2026-07b) — ein Provider je Sprache, überlebt Tab-Wechsel/Remounts.
    @StateObject private var customProviders = CustomLanguageProviders()

    /// 4D-Vervollständigung (Etappe 6 Wunschpaket 2026-07c). Stark gehalten —
    /// der `completionDelegate` des Editors ist nur eine weak-Referenz.
    @StateObject private var fourDCompletion = FourDCompletionDelegate()
    @StateObject private var foldProviders = CodeFoldProviders()
    /// Parameterhilfe für 4D-Aufrufe (Panel unter der Aufrufzeile). Lebt wie
    /// der Completion-Delegate pro Editor-Ansicht und wirkt nur bei aktiver
    /// 4D-Sprache.
    @StateObject private var fourDSignatureHelp = FourDSignatureHelpController()

    /// Der eigentliche CodeEditSourceEditor — nur gezeigt, wenn isLoading = false.
    var body: some View {
        SourceEditor(
            workspace.activeTab.map { $0.undoHistory.textStorage(for: $0.content) } ?? TextView.fastraMakeTextStorage(""),
            language: detectedLanguage,
            configuration: editorConfiguration,
            // Hinweis Scroll-Verhalten: CESEs State-Reconcile drehte mit der
            // stets einen Runloop alten `state.scrollPosition` frische
            // Tipp-Scrolls zurück (F.23). Der Reconcile-Zweig ist per
            // build.sh-Patch 4x deaktiviert — Fastra scrollt ausschließlich
            // selbst (convergeScroll) und setzt nie ein Scroll-Soll über den
            // State. Ein Filter-Binding mit eigenen get/set-Closures war die
            // erste Fassung und crashte in SwiftUIs Zugriffsverfolgung
            // (SIGSEGV in swift_beginAccess) — daher bewusst das normale
            // Binding des fenstergebundenen Zustands.
            state: $memory.editorState,
            // Eigen-Sprache aktiv (z. B. 4D): eigener leichter Tokenizer
            // statt tree-sitter — Provider kommt aus der Registry.
            highlightProviders: activeCustomLanguage.map { language in
                [customProviders.provider(
                    for: language,
                    projectMethodNames: language.id == CustomLanguageRegistry.fourD.id
                        ? workspace.fourDMethodIndexSnapshot.projectMethodNames : [],
                    componentMethodNames: language.id == CustomLanguageRegistry.fourD.id
                        ? Set(workspace.fourDMethodIndexSnapshot.componentMethods.keys) : []
                )]
            },
            foldProvider: foldProviders.provider(language: detectedLanguage,
                isFourD: activeCustomLanguage?.id == CustomLanguageRegistry.fourD.id),
            undoManager: workspace.activeTab.map { $0.undoHistory.manager(for: $0.content) },
            coordinators: [minimapLayoutCoordinator, sourceCoordinator],
            // 4D-Vervollständigung (Etappe 6 Wunschpaket 2026-07c) — NUR
            // bei aktiver 4D-Sprache; sonst bleibt das Vorschlagsfenster
            // komplett aus (Delegate nil).
            completionDelegate: activeCustomLanguage?.id == CustomLanguageRegistry.fourD.id
                ? fourDCompletion : nil
        )
        .background(GutterDimmingBridge().frame(width: 0, height: 0))
        // Frisch erscheinender Editor (neuer Tab ⌘T, Tab-Wechsel, fertig geladene
        // Datei, programmatischer Reload) soll sofort den Tastaturfokus bekommen —
        // sonst verpuffte nach ⌘T ein direktes ⌘V (Daniel-Befund 2026-06-25).
        .onAppear { if isActive { EditorView.focusActiveEditor(in: workspace) } }
        .onChange(of: activeTabIsMarkdown) { _, _ in
            EditorView.configureMarkdownDrop(in: workspace)
        }
        // Gemerkten Ausschnitt des Tabs zurückholen. Ohne das riss CESEs
        // „Einfügemarke sichtbar machen" die Cursorzeile beim Zurückwechseln in
        // die oberste Bildschirmzeile.
        .onAppear {
            if memory.cursorMemoryTabID != workspace.activeDocumentID {
                switchDocument(to: workspace.activeDocumentID)
            }
            guard let target = memory.pendingScrollRestore else {
                EditorView.scrollRestoreDebug("onAppear ohne Restore-Ziel")
                return
            }
            // Das Ziel-Dokument festhalten: Wechselt der Nutzer währenddessen
            // erneut den Tab, darf weder weiter auf dessen ScrollView
            // gescrollt noch sein frischer Auftrag gelöscht werden.
            let restoreDocumentID = workspace.activeDocumentID
            EditorView.scrollRestoreDebug("onAppear startet Restore auf y=\(Int(target.y))")
            EditorView.restoreScrollOffset(target, in: workspace,
                                           pane: pane, documentID: restoreDocumentID) {
                guard workspace.activeDocumentID == restoreDocumentID else { return }
                memory.pendingScrollRestore = nil
            }
        }
        // Scrollen des Nutzers pro Tab mitschreiben. Während eine
        // Wiederherstellung aussteht, absichtlich nicht: die Startposition des
        // frisch montierten Editors darf den gemerkten Wert nicht ersetzen.
        .onChange(of: memory.editorState.scrollPosition) { _, position in
            guard memory.pendingScrollRestore == nil else { return }
            memory.scrollMemory.remember(position,
                                  for: memory.cursorMemoryTabID ?? workspace.activeDocumentID)
        }
        // Typeahead kennt die Projektmethoden: Der Provider liest den
        // Workspace erst beim Aufruf, damit ein Index-Refresh (neue Methode
        // angelegt) ohne Editor-Neuaufbau wirkt.
        .onAppear {
            fourDCompletion.projectMethodProvider = { [weak workspace] in
                workspace?.fourDMethodIndexSnapshot.projectMethodDisplayNames ?? []
            }
            fourDCompletion.componentMethodProvider = { [weak workspace] in
                guard let workspace else { return [] }
                let snapshot = workspace.fourDMethodIndexSnapshot
                return snapshot.componentMethodDisplayNames.map { name in
                    FourDCompletionLogic.ComponentMethodEntry(
                        name: name,
                        componentName: snapshot
                            .componentMethods[name.lowercased()]?
                            .componentName ?? ""
                    )
                }
            }
        }
        // Live-Trefferanzeige (Etappe 2 Wunschpaket 2026-07b): Markierungen
        // leben auf der TextView-Instanz und verschwinden bei jedem Remount
        // (Tab-Wechsel, Reload) von selbst — onAppear zeichnet sie für den
        // neuen Editor nach. Die übrigen Auslöser: neue Suchtreffer aus dem
        // Debounce, Scope-Wechsel, Öffnen/Schließen der Suchmaske.
        .onAppear { EditorView.updateSearchEmphasis(in: workspace) }
        .onReceive(workspace.$bufferMatches) { _ in
            EditorView.updateSearchEmphasis(in: workspace)
        }
        .onReceive(workspace.$folderResults) { _ in
            EditorView.updateSearchEmphasis(in: workspace)
        }
        .onReceive(workspace.$openResults) { _ in
            EditorView.updateSearchEmphasis(in: workspace)
        }
        .onChange(of: workspace.activeTabID) {
            EditorView.updateSearchEmphasis(in: workspace)
        }
        .onChange(of: workspace.scope) {
            EditorView.updateSearchEmphasis(in: workspace)
        }
        .onChange(of: workspace.showSearchDialog) {
            EditorView.updateSearchEmphasis(in: workspace)
        }
        // Cursor-Position aus dem Editor-State in den Workspace spiegeln,
        // damit der Footer (StatusBarView) Zeile/Spalte zeigen kann.
        .onChange(of: panes.activePane) { _, active in
            guard active == pane else { return }
            EditorView.updateSearchEmphasis(in: workspace)
            EditorView.configureMarkdownDrop(in: workspace)
            updateFooterCursor(from: memory.editorState.cursorPositions ?? [])
            scheduleStats(for: memory.editorState.cursorPositions ?? [])
        }
        .onChange(of: memory.editorState.cursorPositions) { _, positions in
            let list = positions ?? []
            memory.cursorMemory.remember(list,
                                  for: memory.cursorMemoryTabID ?? workspace.activeDocumentID)
            guard isActive else { return }
            updateFooterCursor(from: list)
            scheduleStats(for: list)
            // 4D-Parameterhilfe folgt jeder Cursorbewegung; außerhalb eines
            // Aufrufs (oder ohne 4D) blendet sie sich selbst aus.
            fourDSignatureHelp.update(
                workspace: workspace,
                cursorPositions: list,
                isFourDActive: activeCustomLanguage?.id
                    == CustomLanguageRegistry.fourD.id
            )
        }
        .onChange(of: workspace.activeTabID) {
            fourDSignatureHelp.hide()
        }
        .onDisappear {
            fourDSignatureHelp.hide()
        }
        // Zombie-Find-Bar deterministisch verhindern: Wenn der Editor sein
        // eigenes Find-Panel öffnet (CMD+F bei fokussiertem Editor), schreibt
        // CodeEditSourceEditor `findPanelVisible = true` in den State zurück.
        // Wir fangen das ab, schließen das Editor-Panel sofort wieder
        // (findPanelVisible = false → der Editor reconciled und blendet aus)
        // und öffnen STATTDESSEN unsere eigene Suchmaske. Das ist unabhängig
        // von der (nicht steuerbaren) Reihenfolge der Event-Monitore.
        .onChange(of: memory.editorState.findPanelVisible) { _, visible in
            guard visible == true else { return }
            memory.editorState.findPanelVisible = false
            NotificationCenter.default.post(name: .fastraShowSearchFile,
                                            object: workspace)
        }
        // Inhalts-Änderungen (Tippen, Datei-Wechsel) lösen ebenfalls eine
        // Neuberechnung aus — sonst hinkt die Zeichen-/Wort-/Zeilen-Zahl.
        .onChange(of: workspace.activeTabContent.wrappedValue) { _, _ in
            if isActive { scheduleStats(for: memory.editorState.cursorPositions ?? []) }
        }
        .onAppear {
            if isActive { scheduleStats(for: memory.editorState.cursorPositions ?? []) }
            // Ein Sprung, dessen Notification in die Editor-Neuerzeugung
            // fiel (alter Empfänger abgehängt, neuer noch nicht abonniert),
            // wird hier nachgeholt. Ohne dieses Nachholen wirkte der Klick
            // auf einen Suchtreffer unter Last gelegentlich „folgenlos"
            // (reproduziert 2026-08-19 im jump-Selbsttest, 1 von 3 Läufen).
            guard isActive, let pending = workspace.pendingEditorJump,
                  pending.documentID == workspace.activeTab?.documentID else {
                return
            }
            applyEditorJump(pending)
        }
        // Editor-Sprung zur Treffer-Range (CMD+G / List-Klick / Chevron-
        // Button). Wir schreiben die Range direkt in cursorPositions —
        // CodeEditSourceEditor synchronisiert das in eine Selektion +
        // scrollt automatisch in die sichtbare Region.
        .onReceive(NotificationCenter.default.publisher(for: .fastraJumpToRange)) { note in
            // NotificationCenter ist app-weit. Jedes Dokumentfenster besitzt
            // aber einen eigenen Workspace und darf ausschließlich seine
            // eigenen Suchtreffer verarbeiten.
            guard isActive, EditorView.jumpNotification(note, targets: workspace) else { return }
            let info = note.userInfo
            let jump = PendingEditorJump(
                documentID: workspace.activeTab?.documentID,
                startLine: info?["startLine"] as? Int,
                startColumn: info?["startColumn"] as? Int,
                endLine: info?["endLine"] as? Int,
                endColumn: info?["endColumn"] as? Int,
                range: (info?["range"] as? NSValue)?.rangeValue)
            applyEditorJump(jump)
        }
        // Beide Ansichten erhalten denselben dokumentgebundenen Textspeicher.
        // Programmatische Modelländerungen erzeugen beim Remount einen neuen
        // gemeinsamen Speicher; native Edits melden sich nach endEditing über
        // den Coordinator an den bestehenden Workspace-Binding-Pfad zurück.
        // Bei einem Tab-Wechsel UND nach abgeschlossenem
        // asynchronen Laden (isLoading wechselt false → sourceEditor wechselt
        // auf actualEditor) wird der Editor neu erzeugt → `makeNSViewController`
        // läuft mit dem bereits vollständig geladenen Inhalt. Die ID bleibt
        // beim Tippen konstant — Eingaben werden NICHT unterbrochen.
        //
        // `editorReloadNonce` hängt zusätzlich an der ID: ein PROGRAMMATISCHER
        // Buffer-Replace (Alle/Einzel-Ersetzen) zählt ihn hoch → der Editor wird
        // mit dem ersetzten Inhalt neu erzeugt und zeigt die Änderung sofort
        // (sonst bliebe der alte Text stehen — „Ersetzen wirkt folgenlos“).
        // Der dokumentgebundene Undo-Manager überlebt diesen Neuaufbau.
        .id(EditorView.editorIdentity(tabID: workspace.activeTab?.documentID,
                                      reloadNonce: workspace.editorReloadNonce))
        .onChange(of: workspace.activeDocumentID) { _, newTabID in switchDocument(to: newTabID) }
        // Willkommens-Platzhalter (Umbau 2026-07-30, ersetzt den früheren
        // Einzeilen-Hinweis): Solange der aktive Tab ein unberührter leerer
        // Tab ist, liegt der Willkommensinhalt über der Editorfläche —
        // Cursor und Tastatur gehören weiter dem Editor dahinter. Beim
        // ersten getippten Zeichen ist der Tab nicht mehr unberührt →
        // SwiftUI blendet das Overlay automatisch aus; der Editor wird dabei
        // NICHT neu erzeugt, weil .id(tab.id) konstant bleibt. Die
        // Willkommens-Knöpfe bleiben klickbar; freie Flächen reichen Klicks
        // an den Editor durch (WelcomeView hat bewusst keinen Hintergrund).
        .overlay(
            Group {
                if workspace.isWelcomeScreen {
                    WelcomeView()
                }
            }
        )
    }

    private func switchDocument(to newTabID: UUID?) {
        guard memory.cursorMemoryTabID != newTabID else { return }
        let restoredPositions = memory.cursorMemory.switchTab(
            from: memory.cursorMemoryTabID,
            currentPositions: memory.editorState.cursorPositions ?? [],
            to: newTabID
        )
        // Ausschnitt des verlassenen Tabs sichern und den des neuen
        // vormerken. Der Live-Wert aus der noch montierten ScrollView hat
        // Vorrang: `memory.editorState.scrollPosition` kommt einen Runloop
        // versetzt zurück und wäre nach schnellem Scrollen + Tab-Wechsel
        // veraltet.
        let liveOffset = memory.scrollMemory.offset(for: memory.cursorMemoryTabID)
        memory.pendingScrollRestore = memory.scrollMemory.switchTab(
            from: memory.cursorMemoryTabID,
            currentOffset: liveOffset ?? memory.editorState.scrollPosition,
            to: newTabID
        )
        EditorView.scrollRestoreDebug("switchTab gemerkt="
            + "\(Int((liveOffset ?? memory.editorState.scrollPosition ?? .zero).y)) "
            + "live=\(liveOffset != nil) "
            + "restore=\(memory.pendingScrollRestore.map { Int($0.y) }.map(String.init) ?? "nil")")
        memory.cursorMemoryTabID = newTabID
        memory.selectionAnchor = nil
        memory.editorState.cursorPositions = restoredPositions
        // Der State-Wechsel wird normalerweise über den Beobachter am
        // Editor gespiegelt. Diese direkte Aktualisierung schließt auch
        // den kurzen Remount-Moment ohne montierten SourceEditor ab.
        if isActive { updateFooterCursor(from: memory.editorState.cursorPositions ?? []) }
        if isActive { scheduleStats(for: memory.editorState.cursorPositions ?? []) }
    }


    /// Wendet einen Editor-Sprung an und verbraucht den hinterlegten
    /// Pending-Zustand. Gemeinsamer Pfad für die Notification (Normalfall)
    /// und das Nachholen in `onAppear` (Editor wurde währenddessen neu
    /// erzeugt). Bevorzugt Zeile/Spalte (robust gegen Offset-Drift, siehe
    /// `NotificationCenter.postMatchJump`); die absolute Range bleibt der
    /// Fallback für Sprünge ohne Treffer-Kontext („Zu Zeile springen").
    private func applyEditorJump(_ jump: PendingEditorJump) {
        workspace.pendingEditorJump = nil
        var jumpLine: Int? = nil
        if let sl = jump.startLine, let sc = jump.startColumn,
           let el = jump.endLine, let ec = jump.endColumn {
            memory.editorState.cursorPositions = [CursorPosition(
                start: CursorPosition.Position(line: sl, column: sc),
                end: CursorPosition.Position(line: el, column: ec))]
            jumpLine = sl
        } else if let range = jump.range {
            let requested = CursorPosition(range: range)
            // Während eines SwiftUI-Sprungs unterdrückt CodeEdit die Rückmeldung
            // des Controllers. Deshalb Zeile/Spalte vor dem State-Update auflösen.
            memory.editorState.cursorPositions = [sourceCoordinator.resolveCursorPosition(requested) ?? requested]
        } else {
            return
        }
        // Sichtbar scrollen, aber den Fokus in der Suchmaske lassen. Der
        // nächste Tastendruck darf das Dokument niemals verändern.
        EditorView.scrollEditorForVisibleJump(in: workspace,
                                              targetLine: jumpLine,
                                              fallbackRange: jump.range,
                                              cursorPositions: memory.editorState.cursorPositions ?? [])
    }

    /// Footer-Statistik neu anstoßen: bei aktiver Selektion auf die
    /// Selektion bezogen, sonst auf die ganze Datei.
    private func scheduleStats(for positions: [CursorPosition]) {
        let primaryRange = positions.last?.range
        let selection = !workspace.activeMarkdownIsVisual && (primaryRange?.length ?? 0) > 0 ? primaryRange : nil
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
    /// `memory.selectionAnchor` die *stillstehende* Kante und zeigen die andere.
    private func updateFooterCursor(from positions: [CursorPosition]) {
        // Für den Footer zählt der primäre (letzte) Cursor.
        guard let primary = positions.last else {
            workspace.cursorLine = nil
            workspace.cursorColumn = nil
            memory.selectionAnchor = nil
            return
        }

        let resolved = CursorFooter.resolve(
            rangeLocation: primary.range.location,
            rangeLength: primary.range.length,
            startLine: primary.start.line,
            startColumn: primary.start.column,
            endLine: primary.end?.line,
            endColumn: primary.end?.column,
            previousAnchor: memory.selectionAnchor
        )
        setFooter(line: resolved.line, column: resolved.column)
        memory.selectionAnchor = resolved.anchor
    }

    private func setFooter(line: Int, column: Int) {
        guard line > 0, column > 0 else { return }
        workspace.cursorLine = line
        workspace.cursorColumn = column
    }

}
