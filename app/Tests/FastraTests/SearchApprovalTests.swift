import Foundation
import Testing
@testable import Fastra

@Suite("Trefferfreigabe")
struct SearchApprovalTests {
    @Test("Neue Generationen und verspätete Checkbox-Aktionen geben keine anderen Treffer frei")
    func generation() {
        var approval = SearchApproval()
        let first = UUID(), second = UUID()
        approval.publish(matchIDs: [first], isComplete: true, generation: 0)
        #expect(approval.ticket == nil)
        let accepted1 = approval.setAllApproved(true, generation: 0)
        #expect(accepted1)
        let old = approval.ticket
        approval.invalidate()
        #expect(approval.ticket == nil)
        let accepted2 = approval.publish(matchIDs: [first], isComplete: true, generation: 0)
        #expect(!accepted2)
        let accepted3 = approval.publish(matchIDs: [second], isComplete: true, generation: 1)
        #expect(accepted3)
        let accepted4 = approval.setApproved(true, ids: [first], generation: 1)
        #expect(!accepted4)
        let accepted5 = approval.setApproved(true, ids: [second], generation: 0)
        #expect(!accepted5)
        #expect(approval.approvedIDs.isEmpty)
        let accepted6 = approval.setApproved(true, ids: [second], generation: 1)
        #expect(accepted6)
        #expect(approval.ticket != old)
    }

    @Test("Dateifreigabe und Alle/Keine ändern nur die aktuelle vollständige Teilmenge")
    func subsets() {
        var approval = SearchApproval()
        let ids = (0..<4).map { _ in UUID() }
        approval.publish(matchIDs: ids, isComplete: true, generation: 0)
        let accepted7 = approval.setApproved(true, ids: Set(ids.prefix(2)), generation: 0)
        #expect(accepted7)
        #expect(approval.approvedIDs == Set(ids.prefix(2)))
        let partial = approval.ticket
        approval.publish(matchIDs: ids, isComplete: true, generation: 0)
        #expect(approval.ticket == partial)
        let accepted8 = approval.setAllApproved(true, generation: 0)
        #expect(accepted8)
        #expect(approval.approvedIDs == Set(ids))
        let accepted9 = approval.setApproved(false, ids: [ids[1]], generation: 0)
        #expect(accepted9)
        #expect(approval.approvedIDs.count == 3)
        let accepted10 = approval.setAllApproved(false, generation: 0)
        #expect(accepted10)
        #expect(approval.ticket == nil)
    }

    @Test("Gekappte, fehlerhafte oder ersetzte Trefferbasen entwerten Freigaben")
    func incomplete() {
        var approval = SearchApproval()
        let first = UUID(), second = UUID()
        approval.publish(matchIDs: [first], isComplete: false, generation: 0)
        let accepted11 = approval.setAllApproved(true, generation: 0)
        #expect(!accepted11)
        approval.publish(matchIDs: [first], isComplete: true, generation: 0)
        approval.setAllApproved(true, generation: 0)
        approval.publish(matchIDs: [first, second], isComplete: true, generation: 0)
        #expect(approval.approvedIDs.isEmpty)
        approval.setAllApproved(true, generation: 0)
        approval.publish(matchIDs: [first, second], isComplete: false, generation: 0)
        #expect(approval.ticket == nil)
        approval.publish(matchIDs: [first, first], isComplete: true, generation: 0)
        #expect(!approval.isComplete)
        let accepted12 = approval.setAllApproved(true, generation: 0)
        #expect(!accepted12)
    }
}
