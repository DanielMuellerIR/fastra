import Foundation

/// Ladevorgänge der Git-Blob- und Diff-Vorschauen eines Fensters.
/// Der Workspace verwendet den Helfer wie seine Tabs auf dem Main-Thread;
/// Prozess-Callbacks wechseln vor dem Zugriff ausdrücklich dorthin.
final class GitPreviewLoads {
    enum Request: Equatable {
        case diff(GitDiffRequest)
        case snapshot(GitFileSnapshotRequest)

        fileprivate func matches(_ tab: EditorTab) -> Bool {
            switch self {
            case .diff(let request): return tab.gitDiffRequest == request
            case .snapshot(let request): return tab.gitSnapshotRequest == request
            }
        }
    }

    struct Ticket: Equatable {
        let id: UUID
        let tabID: UUID
        let documentID: UUID
        let request: Request
        let context: GitActionContext

        /// Auch nach dem Abbruch darf der Aufrufer die Ladeanzeige beenden,
        /// aber nur, wenn der Tabplatz noch dasselbe Dokument enthält.
        func matches(_ tab: EditorTab) -> Bool {
            tab.id == tabID && tab.documentID == documentID && request.matches(tab)
        }
    }

    private struct Load {
        let ticket: Ticket
        var lease: GitCancelling?
    }
    private var loads: [UUID: Load] = [:]

    func begin(tab: EditorTab, request: Request, context: GitActionContext) -> Ticket {
        cancel(tabID: tab.id)
        // Ein UUID-Ticket wird nie wiederverwendet: Auch A → B → A am selben
        // Vorschauplatz kann keine alte A-Completion erneut gültig machen.
        let ticket = Ticket(id: UUID(), tabID: tab.id, documentID: tab.documentID,
                            request: request, context: context)
        loads[tab.id] = Load(ticket: ticket)
        return ticket
    }

    func attach(_ lease: GitCancelling, to ticket: Ticket) {
        guard loads[ticket.tabID]?.ticket == ticket else {
            lease.cancel()
            return
        }
        loads[ticket.tabID]?.lease = lease
    }

    func currentIndex(for ticket: Ticket, in workspace: Workspace) -> Int? {
        guard loads[ticket.tabID]?.ticket == ticket,
              ticket.context.isCurrent(in: workspace) else { return nil }
        return workspace.tabs.firstIndex(where: ticket.matches)
    }

    func finish(_ ticket: Ticket) {
        guard loads[ticket.tabID]?.ticket == ticket else { return }
        loads.removeValue(forKey: ticket.tabID)
    }

    @discardableResult
    func cancel(tabID: UUID) -> Ticket? {
        // Erst entwerten, dann abbrechen: selbst ein synchroner Callback der
        // Lease kann so keine bereits verworfenen Ergebnisse mehr publizieren.
        guard let load = loads.removeValue(forKey: tabID) else { return nil }
        load.lease?.cancel()
        return load.ticket
    }

    @discardableResult
    func cancelAll() -> [Ticket] {
        let cancelled = Array(loads.values)
        loads.removeAll()
        cancelled.forEach { $0.lease?.cancel() }
        return cancelled.map(\.ticket)
    }

    deinit { cancelAll() }
}
