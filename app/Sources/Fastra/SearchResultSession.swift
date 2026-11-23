import Foundation

/// Identität der Eingaben, ohne erneutes Lesen von Plattendateien auf Main.
struct SearchBasis: Equatable {
    struct Document: Equatable {
        let tabID: UUID
        let documentID: UUID
        let revision: UInt64
        let title: String
        let isLoading: Bool
        let isText: Bool
    }
    let scope: Workspace.SearchScope
    let options: SearchOptions
    let documents: [Document]
    let selection: NSRange?
    let sources: [URL]
    let filter: FileTypeFilter?
    let exclusions: [String]
    let projectRoot: URL?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.options == rhs.options
            && lhs.options.find.utf8.elementsEqual(rhs.options.find.utf8)
            && lhs.options.replace.utf8.elementsEqual(rhs.options.replace.utf8)
            && lhs.documents == rhs.documents && lhs.selection == rhs.selection
            && lhs.sources == rhs.sources && lhs.filter == rhs.filter
            && lhs.exclusions == rhs.exclusions && lhs.projectRoot == rhs.projectRoot
    }
}

enum SearchWindowBinding: Equatable {
    case document(ObjectIdentifier)
    /// Fensterlose Tests müssen ihre Bindung ausdrücklich herstellen.
    case test(UUID)
}

enum SearchPhase: Equatable {
    case closed, empty, waiting, debouncing, running, ready, stale
}

/// Ausschließlich ein Ausgabeabbild. Mutationen gehören dem MainActor-Besitzer.
struct SearchResultState: Equatable {
    var phase: SearchPhase = .closed
    var scope: Workspace.SearchScope?
    var approval = SearchApproval()
    var error: String?
    var options: SearchOptions?

    var bufferSearching = false
    var folderSearching = false
    var folderNeedsSearch = false
    var folderResultsAreStale = false
}

/// Bericht eines abgeschlossenen Suchlaufs; keine Freigabe aus UI-Flags.
struct SearchCompletionReport {
    let matchIDs: [UUID]
    let total: Int
    let wasCapped: Bool
    let error: String?
    let sourcesComplete: Bool
    var folderSourceBasis: FolderSearch.SourceBasis? = nil

    var isComplete: Bool {
        !wasCapped && error == nil && sourcesComplete && total == matchIDs.count
    }
}

/// Ein Besitzer pro Dokumentfenster für Basis, Laufepoch und Teilfreigaben.
@MainActor
final class SearchResultSession {
    struct RunToken: Equatable {
        fileprivate let sessionID: UUID
        fileprivate let generation: UInt64
        let basis: SearchBasis
        fileprivate let window: SearchWindowBinding
    }

    enum InvalidationReason { case inputs, visibility, rescan, ownMutation, documentClosed }

    private let id = UUID()
    private var basis: SearchBasis?
    private var window: SearchWindowBinding?
    private var folderRunHasSources = false
    private(set) var folderSourceBasis: FolderSearch.SourceBasis?
    private(set) var state = SearchResultState()
    private let publish: (SearchResultState) -> Void

    init(publish: @escaping (SearchResultState) -> Void) { self.publish = publish }

    func invalidate(_ reason: InvalidationReason, next phase: SearchPhase,
                    scope: Workspace.SearchScope?, error: String? = nil) {
        basis = nil
        folderSourceBasis = nil
        window = nil
        state.approval.invalidate()
        state.phase = phase
        state.scope = scope
        state.error = error
        state.options = nil
        // Entwertung startet noch keine Buffer-Arbeit. Während des Debounce
        // bleibt nur ein bereits laufender Buffer-Spinner erhalten; Ordner
        // unterscheiden dagegen sofort Live-Debounce und explizites Warten.
        switch reason {
        case .inputs, .ownMutation:
            break
        case .rescan where phase == .debouncing && scope?.isFolderLike == false:
            break
        default:
            state.bufferSearching = scope?.isFolderLike == false && phase == .running
        }
        state.folderSearching = scope?.isFolderLike == true
            && (phase == .debouncing || (phase == .running && folderRunHasSources))
        if phase != .closed {
            state.folderNeedsSearch = scope?.isFolderLike == true && (phase == .waiting || phase == .stale)
        } else if case .documentClosed = reason {
            state.folderNeedsSearch = false
        }
        switch reason {
        case .ownMutation:
            state.folderResultsAreStale = true
        case .rescan where phase == .closed:
            break
        default:
            state.folderResultsAreStale = false
        }
        publish(state)
    }

    func begin(_ basis: SearchBasis, window: SearchWindowBinding) -> RunToken {
        folderRunHasSources = !basis.sources.isEmpty
        invalidate(.rescan, next: .running, scope: basis.scope,
                   error: basis.scope.isFolderLike ? nil : state.error)
        self.basis = basis
        self.window = window
        return RunToken(sessionID: id, generation: state.approval.generation,
                        basis: basis, window: window)
    }

    func accepts(_ token: RunToken, current: SearchBasis, window: SearchWindowBinding) -> Bool {
        state.phase == .running && token.sessionID == id
            && token.generation == state.approval.generation
            && token.basis == basis && token.basis == current
            && token.window == self.window && token.window == window
    }

    func isCurrent(_ current: SearchBasis, window: SearchWindowBinding) -> Bool {
        state.phase == .ready && basis == current && self.window == window
    }

    @discardableResult
    func commit(_ token: RunToken, report: SearchCompletionReport) -> Bool {
        guard accepts(token, current: token.basis, window: token.window) else { return false }
        state.approval.publish(matchIDs: report.matchIDs, isComplete: report.isComplete,
                               generation: token.generation)
        folderSourceBasis = report.isComplete ? report.folderSourceBasis : nil
        state.phase = .ready
        state.bufferSearching = false
        state.folderSearching = false
        state.folderNeedsSearch = false
        state.folderResultsAreStale = false
        state.error = report.error
        state.options = token.basis.scope.isFolderLike ? nil : token.basis.options
        publish(state)
        return true
    }

    @discardableResult
    func setApproved(_ approved: Bool, ids: Set<UUID>, generation: UInt64) -> Bool {
        guard state.phase == .ready,
              state.approval.setApproved(approved, ids: ids, generation: generation) else { return false }
        publish(state)
        return true
    }

    func close() { invalidate(.documentClosed, next: .closed, scope: nil) }
}

/// Daten und Vollständigkeitsbericht werden aus demselben Ergebnis gebildet.
enum SearchResultPublication {
    case buffer(BufferSearch.SearchResult)
    case open(OpenTabsSearch.Result)
    case folder(FolderSearch.Result)

    func report(options: SearchOptions) -> SearchCompletionReport {
        switch self {
        case .buffer(let result):
            return .init(matchIDs: result.matches.map(\.id), total: result.totalMatches,
                         wasCapped: result.wasCapped, error: result.invalidPatternMessage, sourcesComplete: true)
        case .open(let result):
            return .init(matchIDs: result.perTab.flatMap { $0.matches.map(\.id) }, total: result.totalMatches,
                         wasCapped: result.wasCapped, error: result.invalidPatternMessage, sourcesComplete: true)
        case .folder(let result):
            return .init(matchIDs: result.perFile.flatMap { $0.matches.map(\.id) }, total: result.totalMatches,
                         wasCapped: result.wasCapped, error: result.invalidPatternMessage,
                         sourcesComplete: result.sourceBasis != nil && result.perFile.allSatisfy {
                if $0.skipped == .binary { return true }
                return $0.skipped == nil && $0.snapshot != nil
                    && $0.totalMatches == $0.matches.count && $0.searchOptions == options
            }, folderSourceBasis: result.sourceBasis)
        }
    }
}
