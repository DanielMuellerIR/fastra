import SwiftUI

/// Lebenszyklus der vollständigen Ersetzungsvorschau. Das Modell kopiert nur
/// unveränderliche String-/Treffer-Snapshots aus dem Workspace und berechnet
/// sie außerhalb des Main-Threads. Dokumentgeneration plus exakte Treffer-IDs
/// verhindern, dass ein verspäteter alter Lauf im Sheet sichtbar wird.
@MainActor
final class ReplacePreviewModel: ObservableObject {
    struct Version: Hashable, Sendable {
        let documentID: UUID
        let contentRevision: UInt64
        let matchIDs: [UUID]
    }

    struct Request: Sendable {
        let version: Version
        let text: String
        let matches: [BufferSearch.Match]
    }

    enum State: Equatable {
        case idle
        case loading
        case result(ReplacePreview.SideBySideResult)
        case limitation(ReplacePreview.SideBySideLimitation)
    }

    typealias Builder = @Sendable (
        String, [BufferSearch.Match], Int, @Sendable () -> Bool
    ) -> ReplacePreview.SideBySideOutcome

    @Published private(set) var state: State = .idle
    private(set) var completedVersion: Version?
    var result: ReplacePreview.SideBySideResult? {
        guard case .result(let result) = state else { return nil }
        return result
    }

    private let builder: Builder
    private var requestedVersion: Version?
    private var generation: UInt64 = 0
    private var workTask: Task<ReplacePreview.SideBySideOutcome, Never>?
    private var completionTask: Task<Void, Never>?

    init(builder: @escaping Builder = { text, matches, maxRows, shouldCancel in
        ReplacePreview.buildSideBySide(
            text: text, matches: matches, maxRows: maxRows,
            shouldCancel: shouldCancel)
    }) {
        self.builder = builder
    }

    func load(_ request: Request, maxRows: Int = 5_000) {
        // Eine andere Workspace-Aktualisierung darf denselben Auftrag nicht neu
        // starten. Sowohl ein laufender als auch ein fertiger Stand bleibt.
        guard requestedVersion != request.version else { return }
        cancelTasks()
        generation &+= 1
        let expectedGeneration = generation
        requestedVersion = request.version
        completedVersion = nil
        state = .loading

        let builder = self.builder
        let work = Task.detached(priority: .userInitiated) {
            builder(request.text, request.matches, maxRows, { Task.isCancelled })
        }
        workTask = work
        completionTask = Task { [weak self] in
            let outcome = await work.value
            guard !Task.isCancelled, let self,
                  self.generation == expectedGeneration,
                  self.requestedVersion == request.version else { return }
            self.workTask = nil
            self.completionTask = nil
            switch outcome {
            case .result(let result):
                self.completedVersion = request.version
                self.state = .result(result)
            case .limitation(let limitation):
                self.completedVersion = request.version
                self.state = .limitation(limitation)
            case .cancelled:
                // Ein freiwillig beendeter aktueller Lauf besitzt kein
                // anzeigbares Teilergebnis und darf Apply nicht freigeben.
                self.completedVersion = nil
                self.state = .idle
            }
        }
    }

    func cancel() {
        cancelTasks()
        generation &+= 1
        requestedVersion = nil
        completedVersion = nil
        state = .idle
    }

    private func cancelTasks() {
        workTask?.cancel()
        completionTask?.cancel()
        workTask = nil
        completionTask = nil
    }

    deinit {
        workTask?.cancel()
        completionTask?.cancel()
    }
}

/// Vorher/Nachher-Vorschau der Ersetzungen (v0.10) — die „Vorschau der
/// Änderungen" aus der Suchmaske. Wird als Sheet über dem Hauptfenster gezeigt
/// (an `workspace.livePreview` gekoppelt) und liest die ECHTEN Treffer des
/// aktiven Buffers über die pure `ReplacePreview`-Logik. Ersetzt den früheren
/// No-Op-Button, dessen Flag niemand auswertete (Daniel-Befund 2026-06-23).
struct ReplacePreviewView: View {
    @EnvironmentObject var workspace: Workspace
    @StateObject private var model = ReplacePreviewModel()

    /// Obergrenze angezeigter Zeilen — bei mehr erscheint ein Hinweis.
    private let maxRows = 5_000

    /// Nur eine nachweislich aktuelle Datei-Trefferbasis darf gerechnet
    /// werden. Während SearchRunner nach Tippen oder Tabwechsel neu sucht,
    /// setzt er `visibleBufferResultsOptions` synchron auf `nil`; das Sheet
    /// zeigt dann einen Spinner statt alte Treffer mit neuem Text zu mischen.
    private var currentRequest: ReplacePreviewModel.Request? {
        guard workspace.scope == .file,
              workspace.visibleBufferResultsOptions == workspace.currentSearchOptions,
              let tab = workspace.activeTab else { return nil }
        return ReplacePreviewModel.Request(
            version: .init(
                documentID: tab.documentID,
                contentRevision: tab.contentRevision,
                matchIDs: workspace.bufferMatches.map(\.id)),
            text: tab.content,
            matches: workspace.bufferMatches)
    }

    var body: some View {
        let request = currentRequest
        let state = displayedState(for: request)
        return VStack(spacing: 0) {
            header(state: state)
            Divider().opacity(0.3)
            switch state {
            case .idle, .loading:
                loadingState
            case .limitation(let limitation):
                limitationState(limitation)
            case .result(let result) where result.rows.isEmpty:
                emptyState
            case .result(let result):
                columnHeader
                Divider().opacity(0.3)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(result.rows) { row in
                            DocumentDiffRow(row: row)
                        }
                    }
                }
                if result.truncated {
                    Text(verbatim: result.allChangedRowsVisible
                         ? L10n.format(
                            "Alle Änderungen sichtbar (%ld); %ld unveränderte Kontextzeilen ausgeblendet.",
                            result.changedRows, result.totalRows - result.rows.count
                         )
                         : L10n.format(
                            "Nur %ld von %ld Änderungen sichtbar — „Alle ersetzen“ bleibt gesperrt.",
                            result.visibleChangedRows, result.changedRows
                         ))
                        .fastraFont(.small)
                        .foregroundColor(result.allChangedRowsVisible
                                         ? Theme.textSecondary : .orange)
                        .padding(.vertical, 6)
                }
            }
            Divider().opacity(0.4)
            footer(result: readyResult(for: request))
        }
        .frame(width: 880, height: 560)
        .background(Theme.surfaceBase)
        .onAppear { updateModel(with: request) }
        .onChange(of: request?.version) { _, _ in
            updateModel(with: currentRequest)
        }
        .onDisappear { model.cancel() }
    }

    private func displayedState(
        for request: ReplacePreviewModel.Request?
    ) -> ReplacePreviewModel.State {
        guard let request,
              model.completedVersion == request.version else { return .loading }
        return model.state
    }

    private func readyResult(
        for request: ReplacePreviewModel.Request?
    ) -> ReplacePreview.SideBySideResult? {
        guard let request, model.completedVersion == request.version else { return nil }
        return model.result
    }

    private func updateModel(with request: ReplacePreviewModel.Request?) {
        if let request {
            model.load(request, maxRows: maxRows)
        } else {
            model.cancel()
        }
    }

    private func header(state: ReplacePreviewModel.State) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundColor(Theme.accentReadable)
            Text("Vorschau der Änderungen")
                .fastraFont(.headline)
            if let title = workspace.activeTab?.title {
                Text("· \(title)")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Text(summaryText(for: state))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surfaceSand.opacity(0.5))
    }

    private func summaryText(for state: ReplacePreviewModel.State) -> String {
        guard case .result(let result) = state else {
            switch state {
            case .limitation: return L10n.string("Vorschau nicht berechnet")
            case .idle, .loading: return L10n.string("Vorschau wird berechnet…")
            case .result: return ""
            }
        }
        let n = result.changedRows
        if n == 0 { return L10n.string("Keine Änderungen") }
        return n == 1 ? L10n.string("1 geänderte Zeile")
            : L10n.format("%ld geänderte Zeilen", n)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Vorschau wird berechnet…")
                .fastraFont(.headline)
                .foregroundColor(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func limitationState(
        _ limitation: ReplacePreview.SideBySideLimitation
    ) -> some View {
        let explanation: String = switch limitation {
        case .tooLarge(let maximumBytes):
            L10n.format(
                "Vorher- oder Nachher-Text überschreitet die Vorschaugrenze von %ld MiB. Kürze das Dokument oder den Ersetzen-Text.",
                maximumBytes / (1024 * 1024))
        case .tooManyLines(let maximumLines):
            L10n.format(
                "Das Dokument überschreitet die Vorschaugrenze von %ld Zeilen.",
                maximumLines)
        case .tooDifferent(let maximumLines):
            L10n.format(
                "Der unterschiedliche Bereich überschreitet die Rechengrenze von %ld Zeilen.",
                maximumLines)
        }
        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .fastraFont(size: 28)
                .foregroundColor(.orange)
            Text("Vorschau zu groß")
                .fastraFont(.headline)
            Text(verbatim: explanation)
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("„Alle ersetzen“ bleibt gesperrt.")
                .fastraFont(.small)
                .foregroundColor(.orange)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Vorher")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Nachher")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fastraFont(size: 10, weight: .semibold)
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.surfaceSand.opacity(0.3))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "eye.slash")
                .fastraFont(size: 28)
                .foregroundColor(Theme.textSecondary)
            Text("Keine Ersetzungen in der aktuellen Datei.")
                .fastraFont(.headline)
                .foregroundColor(Theme.textSecondary)
            Text(verbatim: L10n.string("Suchbegriff UND Ersetzen-Text eingeben — die Vorschau zeigt dann jede betroffene Zeile vorher und nachher."))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(result: ReplacePreview.SideBySideResult?) -> some View {
        HStack {
            Button("Schließen") { workspace.livePreview = false }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Alle ersetzen") {
                // Nur nach einer bestätigten Anwendung schließen. Kurz nach
                // einem Tastendruck gehören die hier gezeigten Treffer noch
                // zum vorigen Muster; der Workspace lehnt das Ersetzen dann
                // ab, und die Vorschau verschwand bisher trotzdem — ohne dass
                // irgendetwas ersetzt wurde (Review 2026-08-06).
                if workspace.applyAllInActiveBuffer() {
                    workspace.livePreview = false
                }
            }
            .keyboardShortcut(.defaultAction)
            // Ohne Zeilen gibt es nichts zu ersetzen. Bei mehr Änderungen als
            // Vorschauplätze sperrt `allChangedRowsVisible` außerdem jede
            // unsichtbare Anwendung. Der Workspace-Guard schützt zusätzlich
            // die Optionsbindung und eine gekappte Trefferliste.
            .disabled(result?.rows.isEmpty != false
                      || result?.allChangedRowsVisible != true
                      || !workspace.canApplyAllInActiveBuffer)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surfaceSand.opacity(0.4))
    }
}

/// Eine Diff-Zeile: Zeilennummer · Vorher (getönt entfernt) · Nachher (getönt
/// hinzugefügt). Monospaced, beide Spalten gleich breit.
private struct DocumentDiffRow: View {
    let row: ReplacePreview.SideBySideRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            pane(line: row.beforeLine, text: row.before, before: true)
            Divider()
            pane(line: row.afterLine, text: row.after, before: false)
        }
        .padding(.horizontal, 8)
    }

    private func pane(line: Int?, text: String?, before: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.map(String.init) ?? "")
                .fastraFont(size: 10, design: .monospaced)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 44, alignment: .trailing)
            Text(text ?? " ")
                .fastraFont(.monoSmall)
                .foregroundColor(foreground(before: before))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(background(before: before))
    }

    private func foreground(before: Bool) -> Color {
        switch row.kind {
        case .unchanged: return Theme.textSecondary
        case .added: return before ? Theme.textSecondary : Theme.diffAddedFG
        case .removed: return before ? Theme.diffRemovedFG : Theme.textSecondary
        case .changed: return before ? Theme.diffRemovedFG : Theme.diffAddedFG
        }
    }

    private func background(before: Bool) -> Color {
        switch row.kind {
        case .unchanged: return .clear
        case .added: return before ? Theme.surfaceSand.opacity(0.2) : Theme.diffAddedBG
        case .removed: return before ? Theme.diffRemovedBG : Theme.surfaceSand.opacity(0.2)
        case .changed: return before ? Theme.diffRemovedBG : Theme.diffAddedBG
        }
    }
}
