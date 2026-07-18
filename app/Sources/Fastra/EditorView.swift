import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
import UniformTypeIdentifiers

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
    /// Eigener 4D-Highlighter (Etappe 4): ersetzt für .4dm-Dokumente die
    /// tree-sitter-Pipeline. Eine stabile Instanz pro Fenster — CESE ruft
    /// `setUp` bei jeder Editor-Neuerzeugung selbst auf.
    /// Highlight-Provider der Eigen-Sprachen (Registry, Etappe 3 Wunschpaket
    /// 2026-07b) — ein Provider je Sprache, überlebt Tab-Wechsel/Remounts.
    @StateObject private var customProviders = CustomLanguageProviders()

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

    /// Erst-Nutzungs-Hinweis des Markdown-Assistenten (Etappe 5 Wunschpaket
    /// 2026-07b): einmal bestätigt → dauerhaft aus (AppStorage-Flag).
    @AppStorage(MarkdownAssist.firstUseDefaultsKey)
    private var markdownAssistHintShown = false
    @State private var showMarkdownAssistHint = false

    /// Erst-Kontakt-Hinweis für 4D/tool4d (Etappe 4 Wunschpaket 2026-07c):
    /// erscheint beim ersten Öffnen einer `.4dm`-/`.4DProject`-Datei, bis er
    /// über einen der beiden Buttons quittiert ist (Persistenz in
    /// `Tool4DAssist.firstContactHintShown`, Mechanik wie Markdown-Assist).
    @State private var showTool4DHint = false

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

    /// Schmalste Breite, die dem Dokumentinhalt beim Ziehen des Markdown-
    /// Splitters bleiben muss. Kleiner darf der Editor nur werden, wenn das
    /// Fenster selbst zu schmal ist — dann drückt das Layout ihn zusammen.
    private let editorMinWidth: CGFloat = 240
    private let markdownPreviewMinWidth: CGFloat = 260

    /// Gemessene Breite des gesamten Editor-Fensterinhalts (Seitenleiste,
    /// Editor, Vorschau und die Splitter dazwischen). Erst damit lässt sich
    /// ausrechnen, wie breit die Vorschau höchstens werden darf.
    @State private var contentWidth: CGFloat = 0

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

            // Markdown-Tabs bekommen einen eigenen Drop-Bereich (Etappe 5
            // Wunschpaket 2026-07b): Bilddateien werden EINGEFÜGT, alles
            // andere weiterhin geöffnet. Außerhalb des Markdown-Editors
            // bleibt der Fenster-Drop in ContentView („öffnen“) unberührt.
            if activeTabIsMarkdown {
                sourceEditorColumn
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                        handleMarkdownDrop(providers)
                    }
            } else {
                sourceEditorColumn
            }
            if showsIntegratedMarkdownPreview {
                markdownSplitter
                MarkdownPreviewView(workspace: workspace)
                    .frame(width: effectiveMarkdownPreviewWidth)
                    .clipped()
            }
        }
        // Die Breite wird im Hintergrund gemessen statt über einen
        // GeometryReader um den HStack: Der Reader würde die Ausrichtung der
        // Bereiche verändern, diese Messung lässt das Layout unberührt.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in contentWidth = width }
            }
        )
        .onAppear {
            // Alte gespeicherte Werte konnten bis 140 pt reichen. Den Wert
            // selbst anheben, damit der erste Splitter-Drag nicht von einer
            // unsichtbaren 140-pt-Ausgangslage auf 180 pt springt.
            sidebarWidth = min(max(sidebarWidth, Double(sidebarMinWidth)),
                               Double(sidebarMaxWidth))
        }
        // Dieser Beobachter lebt absichtlich am stabilen Editor-Root. Die
        // Konfliktleiste selbst verschwindet bei einem normalen Zwischentab;
        // ein Wechsel Konflikt A → normal → Konflikt C muss C dennoch bei Block 1
        // beginnen und dessen Markerbreite neu prüfen.
        .onChange(of: workspace.activeTabID) {
            workspace.activeGitConflictFileDidChange()
        }
        // Erste Nutzung von Markdown-Toolbar/Bild-Einfügen → dezenten,
        // nicht-modalen Hinweis mit Hilfe-Sprung zeigen (einmalig).
        .onReceive(NotificationCenter.default.publisher(
            for: .fastraMarkdownAssistUsed)) { _ in
            if !markdownAssistHintShown { showMarkdownAssistHint = true }
        }
        // Erstes Öffnen einer 4D-Datei → tool4d-Erst-Kontakt-Hinweis
        // (Etappe 4 Wunschpaket 2026-07c).
        .onChange(of: workspace.activeTabID) { checkTool4DFirstContact() }
        .onAppear { checkTool4DFirstContact() }
    }

    /// Zeigt den tool4d-Hinweis, sobald der aktive Tab eine `.4dm`- oder
    /// `.4DProject`-Datei ist — bis er quittiert wurde. Auf Nicht-4D-Tabs
    /// verschwindet die Leiste (und kommt beim nächsten 4D-Tab wieder).
    private func checkTool4DFirstContact() {
        guard !Tool4DAssist.firstContactHintShown else {
            showTool4DHint = false
            return
        }
        let name = workspace.activeTab?.url?.lastPathComponent
            ?? workspace.activeTab?.title ?? ""
        showTool4DHint = Tool4DAssist.triggersFirstContactHint(fileName: name)
    }

    /// Beide Hinweis-Buttons quittieren dauerhaft („einmal pro Nutzer").
    private func acknowledgeTool4DHint() {
        Tool4DAssist.firstContactHintShown = true
        showTool4DHint = false
    }

    /// Dezenter, NICHT-modaler 4D-Erst-Kontakt-Hinweis mit Sprung in den
    /// Hilfe-Abschnitt „4D & tool4d" (Anker-API der Hilfe).
    private var tool4dHintBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .fastraFont(size: 11)
                .foregroundColor(Theme.accentReadable)
            Text("4D erkannt — Fastra kann mit tool4d beim Prüfen der Syntax helfen.")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Einrichtung anzeigen") {
                acknowledgeTool4DHint()
                HelpWindow.show(anchor: HelpSection.fourDTool.anchor())
            }
            .buttonStyle(.plain)
            .fastraFont(size: 11, weight: .semibold)
            .foregroundColor(Theme.accentReadable)
            // Klick-Anker für den Fenster-Selbsttest `tool4dhint`.
            .background(SelfTestMarker(id: "tool4dHintHelpButton")
                .frame(width: 0, height: 0))
            Button {
                acknowledgeTool4DHint()
            } label: {
                Image(systemName: "xmark")
                    .fastraFont(size: 9, weight: .semibold)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Nicht mehr zeigen")
            .accessibilityLabel("Nicht mehr zeigen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.surfaceSand.opacity(0.6))
        .background(SelfTestMarker(id: "tool4dHintBar").frame(width: 0, height: 0))
    }

    /// Kompakte Markdown-Toolbar: dieselben Befehle wie Menüleiste und
    /// Rechtsklickmenü, die häufigsten direkt klickbar (Etappe 5).
    private var markdownToolbar: some View {
        // Horizontal scrollbar: In einem schmalen Editor (Markdown-Split!)
        // würde ein überlaufender HStack von SwiftUI ZENTRIERT und vom
        // `.clipped()` der Spalte BEIDSEITIG beschnitten — ausgerechnet
        // Fett/Kursiv (vorn) und Link/Tabelle (hinten) verschwänden.
        // Im ScrollView bleiben alle Befehle erreichbar.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(MarkdownFormatCommand.allCases, id: \.rawValue) { command in
                    Button {
                        NotificationCenter.default.post(name: .fastraMarkdownFormat,
                                                        object: command.rawValue)
                    } label: {
                        Image(systemName: command.systemImage)
                            .fastraFont(size: 12)
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: command.menuTitle))
                    .accessibilityLabel(Text(verbatim: command.menuTitle))
                    if command == .code || command == .plainParagraph || command == .quote {
                        Divider().frame(height: 14).opacity(0.5)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised)
        // Marker für den Fenster-Selbsttest `mdassist`.
        .background(SelfTestMarker(id: "markdownToolbar").frame(width: 0, height: 0))
    }

    /// Dezenter, NICHT-modaler Erst-Nutzungs-Hinweis (Etappe 5 Punkt 6):
    /// erscheint einmalig beim ersten Formatbefehl bzw. Bild-Einfügen und
    /// springt über die Anker-API der Hilfe in den Markdown-Abschnitt.
    private var markdownAssistHintBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .fastraFont(size: 11)
                .foregroundColor(Theme.accentReadable)
            Text("Fastra legt eingefügte Bilder neben dem Dokument ab und verlinkt sie relativ — Details in der Hilfe.")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Hilfe öffnen") {
                markdownAssistHintShown = true
                showMarkdownAssistHint = false
                HelpWindow.show(anchor: HelpSection.markdownWriting.anchor())
            }
            .buttonStyle(.plain)
            .fastraFont(size: 11, weight: .semibold)
            .foregroundColor(Theme.accentReadable)
            Button {
                markdownAssistHintShown = true
                showMarkdownAssistHint = false
            } label: {
                Image(systemName: "xmark")
                    .fastraFont(size: 9, weight: .semibold)
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Hinweis ausblenden")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.surfaceSand.opacity(0.6))
    }

    /// Editor-Spalte mit ihren Layout-Modifikatoren (herausgezogen, damit
    /// der Markdown-Drop-Bereich sie bedingt umhüllen kann).
    /// Zum `.clipped()`: Gutter-Durchschuss-Fix (Daniel-Befund 2026-06-22) —
    /// CESEs Gutter ist ein FLOATING-Subview des ScrollViews und zeichnet
    /// sonst über den oberen Rand des Editor-Bereichs hinaus ins Tab-/
    /// Header-Band; `.clipped()` begrenzt die Darstellung hart auf den
    /// eigenen Rahmen, der bereits unter der Tab-Leiste liegt.
    private var sourceEditorColumn: some View {
        sourceEditor
            .frame(minWidth: 0, maxWidth: .infinity)
            .layoutPriority(1)
            .background(Theme.surfaceRaised)
            .clipped()
    }

    /// Aktiver Tab ist ein Markdown-Dokument (Etappe 5 Wunschpaket 2026-07b)?
    private var activeTabIsMarkdown: Bool {
        MarkdownAssist.isMarkdownTabActive(in: workspace)
    }

    /// Drop im Markdown-Editorbereich: Datei-URLs einsammeln (asynchron,
    /// Ergebnis auf dem Main-Thread bündeln) und an `MarkdownAssist`
    /// übergeben; ohne Datei-URLs zählt ein reiner Bilddaten-Drag
    /// (z. B. aus dem Browser) und verhält sich wie Paste.
    private func handleMarkdownDrop(_ providers: [NSItemProvider]) -> Bool {
        let target = workspace
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if !fileProviders.isEmpty {
            let collector = DroppedURLCollector(expected: fileProviders.count) { urls in
                MarkdownAssist.handleDroppedFileURLs(urls, workspace: target)
            }
            for provider in fileProviders {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async { collector.add(url) }
                }
            }
            return true
        }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) {
            let typeIdentifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.png.identifier
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async {
                    MarkdownAssist.handleDroppedImageData(
                        data, typeIdentifier: typeIdentifier, workspace: target
                    )
                }
            }
            return true
        }
        return false
    }

    /// Aktuell wirksame Breite der Seitenleiste inklusive ihres Splitters.
    private var sidebarOccupiedWidth: CGFloat {
        guard showSidebar else { return 0 }
        return min(max(CGFloat(sidebarWidth), sidebarMinWidth), sidebarMaxWidth)
            + ResizableDivider.thickness
    }

    /// Obergrenze der Vorschau (Daniel-Befund 2026-07-16): Früher war hier eine
    /// feste Breite von 760 pt verdrahtet. Auf einem breiten Fenster ließ sich
    /// der Editor deshalb per Splitter nicht schmal ziehen — die Vorschau
    /// konnte den freiwerdenden Platz gar nicht übernehmen, obwohl dasselbe
    /// schmale Layout beim Verkleinern des Fensters entstand. Die Grenze folgt
    /// jetzt dem echten Platzangebot: Die Vorschau darf alles einnehmen, was
    /// dem Editor über `editorMinWidth` hinaus bleibt.
    private var markdownPreviewMaxWidth: CGFloat {
        // Vor der ersten Messung bleibt die bisherige Breite gültig, damit der
        // erste Frame nicht mit einer Un-Breite erscheint.
        guard contentWidth > 0 else { return 760 }
        return CGFloat(SplitterSizing.trailingMaximum(
            total: Double(contentWidth),
            occupiedLeading: Double(sidebarOccupiedWidth),
            splitter: Double(ResizableDivider.thickness),
            minimumLeading: Double(editorMinWidth),
            minimumTrailing: Double(markdownPreviewMinWidth)
        ))
    }

    /// Gespeicherte Breite, geklemmt auf das, was im Fenster gerade möglich
    /// ist. Der gespeicherte Wert selbst bleibt unangetastet: Wird das Fenster
    /// wieder breiter, kehrt die Vorschau zu ihrer Wunschbreite zurück.
    private var effectiveMarkdownPreviewWidth: CGFloat {
        min(max(CGFloat(markdownPreviewWidth), markdownPreviewMinWidth), markdownPreviewMaxWidth)
    }

    private var showsIntegratedMarkdownPreview: Bool {
        guard showMarkdownPreview, let tab = workspace.activeTab else { return false }
        let name = tab.title.lowercased()
        return name.hasSuffix(".md") || name.hasSuffix(".markdown")
    }

    private var markdownSplitter: some View {
        // Der Splitter zieht an der *sichtbaren* Breite. Läse er den rohen
        // gespeicherten Wert, würde die Vorschau in einem zu schmalen Fenster
        // beim ersten Ziehen von der geklemmten auf die gespeicherte Breite
        // springen.
        let width = Binding<Double>(
            get: { Double(effectiveMarkdownPreviewWidth) },
            set: { markdownPreviewWidth = $0 }
        )
        return ResizableDivider(value: width,
                                range: Double(markdownPreviewMinWidth)...Double(markdownPreviewMaxWidth),
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
            if let tab = workspace.activeTab,
               let request = tab.fileDiffRequest {
                // Datei-Vergleichs-Tab (Etappe 1 Wunschpaket 2026-07c):
                // read-only Dual-Pane-Diff ohne Git.
                FileDiffView(request: request, document: tab.fileDiffDocument)
                    .id(tab.id)
            } else if let tab = workspace.activeTab,
               let request = tab.gitDiffRequest {
                // Git-Diff auf dem GEMEINSAMEN Dual-Pane-Renderer
                // (Etappe 2 Wunschpaket 2026-07c).
                GitDualPaneDiffView(request: request,
                                    document: tab.gitDiffDocument,
                                    fallbackText: tab.content)
                    .id(tab.id)
            } else if let kind = workspace.activeTab?.gitKind {
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
            } else {
                VStack(spacing: 0) {
                    if workspace.activeConflictSupport != .none {
                        GitConflictBar()
                    }
                    // tool4d-Erst-Kontakt-Hinweis (Etappe 4 Wunschpaket
                    // 2026-07c) — nur solange der aktive Tab 4D zeigt.
                    if showTool4DHint {
                        tool4dHintBar
                        Divider().opacity(0.3)
                    }
                    // Markdown-Toolbar (Etappe 5 Wunschpaket 2026-07b):
                    // Formatierungsbefehle auf den Quelltext, nur für
                    // Markdown-Tabs in der Text-Ansicht.
                    if activeTabIsMarkdown, workspace.activeViewMode == .text {
                        markdownToolbar
                        Divider().opacity(0.3)
                        if showMarkdownAssistHint {
                            markdownAssistHintBar
                            Divider().opacity(0.3)
                        }
                    }
                    // Der Ansichts-Umschalter (Text/Vorschau/Hex) sitzt seit
                    // Etappe 1 Wunschpaket 2026-07b in der Fußzeile
                    // (`StatusBarView`) — hier kostete er eine eigene Zeile.
                    switch workspace.activeViewMode {
                    case .preview:
                        if let tab = workspace.activeTab, let url = tab.url {
                            if ViewModeRouting.pdfExtensions.contains(
                                ViewModeRouting.normalizedExtension(url.pathExtension)
                            ) {
                                PDFPreviewView(url: url).id(tab.id)
                            } else {
                                ImagePreviewView(url: url, fileSize: tab.fileSize)
                                    .id(tab.id)
                            }
                        } else {
                            actualEditor
                        }
                    case .hex:
                        if let tab = workspace.activeTab, let url = tab.url {
                            // Der Hex-Modus liest direkt von der Platte. Hat der
                            // Text-Tab ungespeicherte Änderungen, muss das sichtbar
                            // sein — sonst wirkte die Ansicht still „falsch".
                            if tab.displayMode == .text && tab.isDirty {
                                Label("Hex zeigt den gespeicherten Stand auf der Platte — ungespeicherte Änderungen dieses Tabs sind hier nicht sichtbar.",
                                      systemImage: "exclamationmark.triangle")
                                    .fastraFont(.small)
                                    .foregroundColor(Theme.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                            HexFileView(url: url, fileSize: tab.fileSize) {
                                // Hex-Schreibvorgang → offene Text-Tabs derselben
                                // Datei über den Extern-Änderungs-Pfad abgleichen.
                                workspace.checkExternalChanges()
                            }
                            .id(tab.id)
                        } else {
                            actualEditor
                        }
                    case .text:
                        if let tab = workspace.activeTab,
                           tab.displayMode == .chunkedText, let url = tab.url {
                            ChunkedTextFileView(url: url, fileSize: tab.fileSize,
                                                encoding: tab.encoding, bom: tab.bom)
                                .id(tab.id)
                        } else {
                            actualEditor
                        }
                    }
                }
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
            // Eigen-Sprache aktiv (z. B. 4D): eigener leichter Tokenizer
            // statt tree-sitter — Provider kommt aus der Registry.
            highlightProviders: activeCustomLanguage.map { [customProviders.provider(for: $0)] },
            coordinators: [minimapLayoutCoordinator]
        )
        .background(GutterDimmingBridge().frame(width: 0, height: 0))
        // Frisch erscheinender Editor (neuer Tab ⌘T, Tab-Wechsel, fertig geladene
        // Datei, programmatischer Reload) soll sofort den Tastaturfokus bekommen —
        // sonst verpuffte nach ⌘T ein direktes ⌘V (Daniel-Befund 2026-06-25).
        .onAppear { Self.focusActiveEditor(in: workspace) }
        // Live-Trefferanzeige (Etappe 2 Wunschpaket 2026-07b): Markierungen
        // leben auf der TextView-Instanz und verschwinden bei jedem Remount
        // (Tab-Wechsel, Reload) von selbst — onAppear zeichnet sie für den
        // neuen Editor nach. Die übrigen Auslöser: neue Suchtreffer aus dem
        // Debounce, Scope-Wechsel, Öffnen/Schließen der Suchmaske.
        .onAppear { EditorView.updateSearchEmphasis(in: workspace) }
        .onReceive(workspace.$bufferMatches) { _ in
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

    /// Beobachtet das Scrollen der Editor-TextView und zeichnet die Live-
    /// Trefferanzeige gedrosselt nach. Nötig, weil der EmphasisManager nur
    /// für bereits AUSGELEGTE Zeilen einen Pfad bekommt — Treffer außerhalb
    /// des gelayouteten Bereichs hätten sonst dauerhaft keine Markierung.
    /// Der Relay hängt als Associated Object an der TextView und stirbt mit
    /// ihr (deinit meldet den Observer ab).
    private final class SearchEmphasisScrollRelay {
        private var token: NSObjectProtocol?
        private var pending: DispatchWorkItem?

        init(clipView: NSClipView, workspace: Workspace) {
            clipView.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView, queue: .main
            ) { [weak self, weak workspace] _ in
                guard let self, let workspace else { return }
                // Billiger Vorab-Check: ohne aktive Anzeige kein Nachzeichnen.
                guard SearchEmphasis.shouldShow(scope: workspace.scope,
                                                dialogOpen: workspace.showSearchDialog,
                                                viewMode: workspace.activeViewMode) else { return }
                // Trailing-Debounce (100 ms): beim Durchscrollen nur einmal
                // am Ende zeichnen statt bei jedem Bounds-Tick.
                self.pending?.cancel()
                let work = DispatchWorkItem { [weak workspace] in
                    guard let workspace else { return }
                    EditorView.updateSearchEmphasis(in: workspace)
                }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
        }

        deinit {
            pending?.cancel()
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private static var emphasisScrollRelayKey: UInt8 = 0

    /// Hängt (einmal pro TextView-Instanz) den Scroll-Relay an.
    private static func installEmphasisScrollRelay(on textView: CodeEditTextView.TextView,
                                                   workspace: Workspace) {
        guard objc_getAssociatedObject(textView, &emphasisScrollRelayKey) == nil,
              let clipView = textView.enclosingScrollView?.contentView else { return }
        let relay = SearchEmphasisScrollRelay(clipView: clipView, workspace: workspace)
        objc_setAssociatedObject(textView, &emphasisScrollRelayKey, relay,
                                 .OBJC_ASSOCIATION_RETAIN)
    }

    /// Zeichnet die Live-Trefferanzeige neu (Etappe 2 Wunschpaket 2026-07b):
    /// erst die eigene Emphasis-Gruppe räumen, dann — falls die pure
    /// Sichtbarkeitsbedingung (`SearchEmphasis.shouldShow`) gilt — die
    /// aktuellen Buffer-Treffer als flache Markierungen setzen.
    ///
    /// Läuft bewusst einen Tick später (`async`): Der `$bufferMatches`-
    /// Publisher feuert zum willSet-Zeitpunkt (Property noch alt), und nach
    /// einem Tab-Wechsel muss die frisch montierte TextView erst in der
    /// Hierarchie hängen. Reine Anzeige: kein Undo, kein Dirty, kein Einfluss
    /// auf Ersetzen oder die Vorschau-Trefferbasis.
    static func updateSearchEmphasis(in workspace: Workspace) {
        DispatchQueue.main.async {
            guard let mainWindow = NSApp.windows.first(where: {
                !SearchWindow.isSearchWindow($0)
                    && WorkspaceWindowRegistry.workspace(for: $0) === workspace
                    && $0.contentView != nil && $0.isVisible
            }), let root = mainWindow.contentView,
                  let textView = firstEditorTextView(in: root) as? CodeEditTextView.TextView,
                  let manager = textView.emphasisManager else { return }
            // Immer zuerst räumen (Musterwechsel vor Neuanzeige) — die
            // Markierungen dürfen sich niemals stapeln.
            manager.removeEmphases(for: SearchEmphasis.groupID)
            guard SearchEmphasis.shouldShow(scope: workspace.scope,
                                            dialogOpen: workspace.showSearchDialog,
                                            viewMode: workspace.activeViewMode) else { return }
            let plan = SearchEmphasis.plan(
                matchRanges: workspace.bufferMatches.map(\.range),
                totalMatches: workspace.bufferTotalMatches
            )
            // Treffer-Ranges stammen aus dem (debounce-alten) Suchlauf; nach
            // schnellem Weitertippen könnten sie hinter dem aktuellen Text
            // liegen. Out-of-Bounds-Ranges würden im EmphasisManager eine
            // NSRange-Exception auslösen — deshalb hart filtern.
            let documentLength = textView.textStorage?.length ?? 0
            let safeRanges = plan.ranges.filter { NSMaxRange($0) <= documentLength }
            guard !safeRanges.isEmpty else { return }
            // Der EmphasisManager kann nur AUSGELEGTE Zeilen zeichnen —
            // beim Scrollen legt CESE weitere Zeilen aus, der Relay zeichnet
            // dann gedrosselt nach (sonst blieben Treffer unter dem sichtbaren
            // Bereich dauerhaft unmarkiert).
            installEmphasisScrollRelay(on: textView, workspace: workspace)
            manager.addEmphases(SearchEmphasis.makeEmphases(for: safeRanges),
                                for: SearchEmphasis.groupID)
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
    static func focusActiveEditor(in workspace: Workspace) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let mainWindow = NSApp.windows.first(where: {
                !SearchWindow.isSearchWindow($0)
                    && WorkspaceWindowRegistry.workspace(for: $0) === workspace
                    && $0.contentView != nil && $0.isVisible
            }), let root = mainWindow.contentView,
                  let tv = firstEditorTextView(in: root) else { return }
            // Nur fokussieren, wenn das Hauptfenster Key ist — sonst (offene
            // Suchmaske vorne) würden wir der Maske den Tastaturfokus klauen.
            guard mainWindow.isKeyWindow else { return }
            guard mainWindow.makeFirstResponder(tv) else { return }
            // Eine frisch montierte CodeEdit-TextView kann noch keine
            // Textselektion besitzen. Dann ist sie zwar First Responder, aber
            // `paste(_:)` hat keinen Einfügepunkt und verwirft ein sofortiges
            // ⌘V. Nur in diesem leeren Initialzustand den Cursor an Position 0
            // anlegen; bestehende Cursor und Selektionen bleiben unangetastet.
            if let textView = tv as? CodeEditTextView.TextView,
               textView.selectionManager.textSelections.isEmpty {
                textView.selectionManager.setSelectedRange(
                    NSRange(location: 0, length: 0)
                )
            }
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
    /// Aktive Eigen-Sprache des Tabs (Registry, Etappe 3 Wunschpaket
    /// 2026-07b) — steuert Theme und Highlight-Provider. Rangfolge:
    /// 1. Manuelle Eigen-Sprachen-Wahl (Footer-Menü) gewinnt immer.
    /// 2. Eine manuelle GRAMMATIK-Wahl schaltet die Eigen-Sprache ab
    ///    (der Nutzer hat sich ausdrücklich anders entschieden).
    /// 3. Sonst Endungs-Automatik (Titel zählt mit, damit auch „Speichern
    ///    unter…“-Kandidaten ohne URL richtig eingefärbt werden).
    /// Pure Funktion → unit-testbar.
    static func customLanguage(for tab: EditorTab?) -> CustomLanguage? {
        guard let tab else { return nil }
        if let overrideID = tab.customLanguageOverrideID {
            return CustomLanguageRegistry.language(withID: overrideID)
        }
        if tab.languageOverride != nil { return nil }
        let name = tab.url?.lastPathComponent ?? tab.title
        return CustomLanguageRegistry.language(
            forExtension: (name as NSString).pathExtension
        )
    }

    private var activeCustomLanguage: CustomLanguage? {
        Self.customLanguage(for: workspace.activeTab)
    }

    private var editorConfiguration: SourceEditorConfiguration {
        .init(
            appearance: .init(
                theme: activeCustomLanguage.map {
                    colorScheme == .dark ? $0.darkTheme : $0.lightTheme
                } ?? (colorScheme == .dark ? Self.fastraThemeDark : Self.fastraTheme),
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
        guard let tab = workspace.activeTab else { return .default }
        // Aktive Eigen-Sprache (Registry) → deren Grammatik-Unterbau
        // (für 4D Plaintext; die Farben liefert der Provider).
        if let custom = Self.customLanguage(for: tab) { return custom.baseGrammar }
        // Manuelle Sprachwahl (Footer-Menü, Etappe 3) gewinnt IMMER —
        // sie ist das Sicherheitsventil gegen jede Fehlerkennung.
        if let manual = tab.languageOverride { return manual }
        if let url = tab.url {
            if let mapped = Self.grammarForSpecialExtension(url.pathExtension) {
                return mapped
            }
            // prefixBuffer aktiviert die Upstream-Shebang-/Modeline-Erkennung
            // für gespeicherte Dateien OHNE Endung (z. B. `deploy`-Skripte).
            return CodeLanguage.detectLanguageFrom(
                url: url,
                prefixBuffer: String(tab.content.prefix(512)),
                suffixBuffer: nil
            )
        }
        // Ohne URL: erst die angezeigte Dateiendung des Tabs, dann die
        // inhaltsbasierte Erkennung (Etappe 3, nur endungslose Tabs).
        let titleExtension = (tab.title as NSString).pathExtension
        if !titleExtension.isEmpty {
            if let mapped = Self.grammarForSpecialExtension(titleExtension) {
                return mapped
            }
            return CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: tab.title))
        }
        if let detected = tab.contentDetectedLanguage { return detected }
        return .default
    }

    /// Endungs-Sonderfälle, die keine eigene Grammatik besitzen:
    /// - XML-artige → HTML-Grammatik (CodeEditLanguages bündelt kein XML;
    ///   HTML zeichnet Tags/Attribute/Strings verlustfrei auch für XML).
    /// - 4D-Projektdateien (Etappe 4): .4DProject/.4DForm sind JSON,
    ///   .4DCatalog/.4DSettings sind XML (echte JSON-/XML-Dateien — bewusst
    ///   KEINE Eigen-Sprache; .4dm läuft seit Etappe 3 Wunschpaket 2026-07b
    ///   über die `CustomLanguageRegistry`).
    static func grammarForSpecialExtension(_ fileExtension: String) -> CodeLanguage? {
        switch fileExtension.lowercased() {
        case "xml", "xsd", "xsl", "xslt", "plist", "4dcatalog", "4dsettings":
            return .html
        case "4dproject", "4dform":
            return .json
        default:
            return nil
        }
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
            case .files:
                filesSidebar
            case .changes:
                // Gemeinsamer Projekt-Kopf auch auf den Git-Tabs (Etappe 1
                // Wunschpaket 2026-07b) — vorher wusste man dort nicht,
                // welches Projekt gerade offen ist.
                if let projectURL = workspace.projectURL {
                    SidebarProjectHeader(rootURL: projectURL)
                }
                GitChangesView()
            case .graph:
                if let projectURL = workspace.projectURL {
                    SidebarProjectHeader(rootURL: projectURL)
                }
                GitGraphView()
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
        // commands/values/characters: Seit dem EditorTheme-Patch (build.sh,
        // Etappe 4) bedienen diese Slots .function/.method, .variableBuiltin
        // und .property. Damit alle BESTEHENDEN Sprachen exakt gleich
        // aussehen wie vor dem Patch, tragen die Slots hier genau die Farben
        // ihrer früheren Sammel-Slots (variables bzw. keywords). Eigene
        // Farben nutzt nur das 4D-Theme unten.
        commands:   .init(color: rgb(0x36, 0x36, 0x36)),
        types:      .init(color: rgb(0x2A, 0x66, 0xB5), bold: true),
        attributes: .init(color: rgb(0xB5, 0x6C, 0x1A)),
        variables:  .init(color: rgb(0x36, 0x36, 0x36)),
        values:     .init(color: rgb(0xA3, 0x39, 0x2A), bold: true),
        numbers:    .init(color: rgb(0xB5, 0x6C, 0x1A)),
        strings:    .init(color: rgb(0x2F, 0x5D, 0x3A)),
        characters: .init(color: rgb(0x36, 0x36, 0x36)),
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
        // Gleiche Patch-Neutralität wie im hellen Theme (siehe Kommentar dort).
        commands:   .init(color: rgb(0xF2, 0xF2, 0xF2)),
        types:      .init(color: rgb(0x7F, 0xB0, 0xEE), bold: true),
        attributes: .init(color: rgb(0xDF, 0xA2, 0x5A)),
        variables:  .init(color: rgb(0xF2, 0xF2, 0xF2)),
        values:     .init(color: rgb(0xE8, 0x8D, 0x7C), bold: true),
        numbers:    .init(color: rgb(0xDF, 0xA2, 0x5A)),
        strings:    .init(color: rgb(0x94, 0xCE, 0x9F)),
        characters: .init(color: rgb(0xF2, 0xF2, 0xF2)),
        comments:   .init(color: rgb(0x9A, 0x9A, 0x9A), italic: true)
    )

    // MARK: - 4D-Themes (Etappe 4 Wunschpaket 2026-07)
    //
    // Statische Themes für .4dm-Dokumente. Token-Farben und Bold/Italic
    // stammen aus docs/wunschpaket-2026-07/light.json bzw. dark.json (nur
    // Vordergrundfarben; Hintergrund-/Auswahlfarben und Fonts kommen
    // bewusst aus den Fastra-Standardthemes). Underline (4D-Konstanten)
    // kennt CESEs Attribut-Modell nicht — Konstanten erhalten nur die Farbe.
    //
    // Slot-Belegung (nach dem EditorTheme-Patch in build.sh):
    //   text       ← plain_text          keywords ← keywords (bold)
    //   commands   ← commands (bold; Projektmethoden teilen den Slot)
    //   values     ← constants           variables ← local_variables (+$1…)
    //   characters ← process_variables (auch <>interprozess — dark.json
    //                kennt ohnehin keine eigene Interprozess-Farbe)
    //   types      ← tables              attributes ← fields
    //   numbers    ← plain_text (4D färbt Zahlen nicht ein)
    //   strings    ← Fastra-Fallback (die 4D-Themes definieren keine
    //                String-Farbe)      comments ← comments
    //   member `.x` bleibt plain; `.f()` nutzt den commands-Slot.
    //   errors/plug_ins aus den JSONs entfallen (kein Fehler-Parsing,
    //   Plugin-Befehle nicht unterscheidbar) — dokumentierter Verzicht.

    static let fourDTheme: EditorTheme = EditorTheme(
        text:           .init(color: rgb(0x00, 0x00, 0x00)),
        insertionPoint: rgb(0x00, 0x00, 0x00),
        invisibles:     .init(color: rgb(0x00, 0x00, 0x00, 0.18)),
        background:     rgb(0xFF, 0xFF, 0xFF),
        lineHighlight:  rgb(0xEC, 0xEC, 0xEC, 0.55),
        selection:      rgb(0x78, 0xA7, 0xE8, 0.42),
        keywords:   .init(color: rgb(0x03, 0x4D, 0x00), bold: true),
        commands:   .init(color: rgb(0x06, 0x8C, 0x00), bold: true),
        types:      .init(color: rgb(0x43, 0x99, 0xD0)),
        attributes: .init(color: rgb(0x39, 0x80, 0xB2)),
        variables:  .init(color: rgb(0x00, 0x70, 0xF5)),
        values:     .init(color: rgb(0xBF, 0x30, 0xB5)),
        numbers:    .init(color: rgb(0x00, 0x00, 0x00)),
        strings:    .init(color: rgb(0x2F, 0x5D, 0x3A)),
        characters: .init(color: rgb(0x9E, 0x60, 0x00), italic: true),
        comments:   .init(color: rgb(0x7F, 0x7E, 0x80))
    )

    static let fourDThemeDark: EditorTheme = EditorTheme(
        text:           .init(color: rgb(0xAE, 0xAE, 0xAE)),
        insertionPoint: rgb(0xAE, 0xAE, 0xAE),
        invisibles:     .init(color: rgb(0xAE, 0xAE, 0xAE, 0.22)),
        background:     rgb(0x17, 0x17, 0x17),
        lineHighlight:  rgb(0x33, 0x33, 0x33, 0.62),
        selection:      rgb(0x5E, 0x8E, 0xCC, 0.48),
        keywords:   .init(color: rgb(0xE1, 0xDC, 0x32), bold: true),
        commands:   .init(color: rgb(0xB5, 0xD6, 0xDD), bold: true),
        types:      .init(color: rgb(0xB7, 0x4D, 0x00)),
        attributes: .init(color: rgb(0xBA, 0xD8, 0x0A)),
        variables:  .init(color: rgb(0x00, 0xF9, 0xCC)),
        values:     .init(color: rgb(0xB7, 0x00, 0xB8)),
        numbers:    .init(color: rgb(0xAE, 0xAE, 0xAE)),
        strings:    .init(color: rgb(0x94, 0xCE, 0x9F)),
        characters: .init(color: rgb(0xD7, 0xF6, 0x92)),
        comments:   .init(color: rgb(0x74, 0xC5, 0xEA))
    )

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255.0,
                green:   CGFloat(g) / 255.0,
                blue:    CGFloat(b) / 255.0,
                alpha:   a)
    }
}
