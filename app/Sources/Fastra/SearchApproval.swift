import Foundation

struct SearchApproval: Equatable, Sendable {
    struct Ticket: Hashable, Sendable {
        let generation: UInt64
        let matchIDs: [UUID]
        let approvedIDs: Set<UUID>
    }

    private(set) var generation: UInt64 = 0
    private(set) var matchIDs: [UUID] = []
    private(set) var approvedIDs: Set<UUID> = []
    private(set) var isComplete = false

    var ticket: Ticket? {
        guard isComplete, !approvedIDs.isEmpty else { return nil }
        return Ticket(generation: generation, matchIDs: matchIDs, approvedIDs: approvedIDs)
    }

    mutating func invalidate() {
        generation &+= 1
        matchIDs = []
        approvedIDs = []
        isComplete = false
    }

    @discardableResult
    mutating func publish(matchIDs: [UUID], isComplete: Bool, generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        let complete = isComplete && Set(matchIDs).count == matchIDs.count
        if self.matchIDs != matchIDs || !complete { approvedIDs = [] }
        self.matchIDs = matchIDs
        self.isComplete = complete
        return true
    }

    @discardableResult
    mutating func setApproved(_ approved: Bool, ids: Set<UUID>, generation: UInt64) -> Bool {
        // Auch ein verspäteter Checkbox-Klick muss noch zu derselben
        // vollständigen Trefferbasis gehören wie die dargestellte Zeile.
        guard isComplete, generation == self.generation,
              !ids.isEmpty, ids.isSubset(of: Set(matchIDs)) else { return false }
        if approved { approvedIDs.formUnion(ids) }
        else { approvedIDs.subtract(ids) }
        return true
    }

    @discardableResult
    mutating func setAllApproved(_ approved: Bool, generation: UInt64) -> Bool {
        setApproved(approved, ids: Set(matchIDs), generation: generation)
    }
}
