import Foundation
import Testing
@testable import Fastra

@Suite("Push-Vorschau")
struct GitPushPreviewTests {
    private let target = GitPushTarget(
        remote: "origin",
        addresses: ["ssh://example.test/project.git"]
    )

    @Test("Fast-Forward-Plan bindet Remote, Branch, OID und Zähler")
    func fastForwardPlan() {
        let plan = GitPushPlan(
            target: target,
            branch: "main",
            sourceOID: String(repeating: "a", count: 40),
            remoteRef: "refs/heads/main",
            remoteOID: String(repeating: "b", count: 40),
            localAhead: 3,
            localBehind: 0,
            tracksTarget: true
        )

        #expect(plan.canFastForward)
        #expect(plan.hasChangesToPush)
        #expect(plan.confirmation.title == L10n.string("Push prüfen"))
        #expect(plan.confirmation.explanation.contains("origin"))
        #expect(plan.confirmation.explanation.contains("refs/heads/main"))
        #expect(plan.confirmation.explanation.contains("aaaaaaaaaaaa"))
        #expect(plan.confirmation.explanation.contains("3"))
    }

    @Test("Divergenz blockiert normalen Push und kennzeichnet die Folgeprüfung")
    func divergentPlan() {
        let plan = GitPushPlan(
            target: target,
            branch: "main",
            sourceOID: "local",
            remoteRef: "refs/heads/main",
            remoteOID: "remote",
            localAhead: 2,
            localBehind: 4,
            tracksTarget: true
        )

        #expect(!plan.canFastForward)
        #expect(plan.confirmation.isDestructive)
        #expect(plan.confirmation.confirmTitle
                == L10n.string("Force Push with Lease prüfen"))
        #expect(plan.confirmation.explanation.contains("2"))
        #expect(plan.confirmation.explanation.contains("4"))
    }

    @Test("Parser akzeptiert ausschließlich eindeutige OIDs und Zähler")
    func parsing() {
        let oid = String(repeating: "a", count: 40)
        #expect(GitPushPlanParsing.oid(GitResult(
            exitCode: 0, stdout: oid + "\n", stderr: "")) == oid)
        #expect(GitPushPlanParsing.oid(GitResult(
            exitCode: 1, stdout: oid + "\n", stderr: "")) == nil)
        #expect(GitPushPlanParsing.oid(GitResult(
            exitCode: 0, stdout: "abc\n", stderr: "")) == nil)
        let counts = GitPushPlanParsing.counts(GitResult(
            exitCode: 0, stdout: "7\t5\n", stderr: ""))
        #expect(counts?.ahead == 7)
        #expect(counts?.behind == 5)
        #expect(GitPushPlanParsing.count(GitResult(
            exitCode: 0, stdout: "9\n", stderr: "")) == 9)
        #expect(GitPushPlanParsing.remoteOID(GitResult(
            exitCode: 0,
            stdout: "\(oid)\trefs/heads/main\n",
            stderr: ""
        ), expectedRef: "refs/heads/main") == oid)
        #expect(GitPushPlanParsing.remoteOID(GitResult(
            exitCode: 0,
            stdout: "\(oid)\trefs/heads/other\n",
            stderr: ""
        ), expectedRef: "refs/heads/main") == nil)
    }

    @Test("Non-Fast-Forward-Erkennung bewahrt unterschiedliche Git-Ausgaben")
    func failureClassification() {
        #expect(GitPushFailureClassification.isNonFastForward(GitResult(
            exitCode: 1,
            stdout: "! [rejected] main -> main (non-fast-forward)",
            stderr: "")))
        #expect(GitPushFailureClassification.isNonFastForward(GitResult(
            exitCode: 1,
            stdout: "! [rejected] main -> main (fetch first)",
            stderr: "hint: Updates were rejected")))
        #expect(GitPushFailureClassification.isNonFastForward(GitResult(
            exitCode: 1,
            stdout: "! [zurückgewiesen] main -> main (kein Vorspulen)",
            stderr: "Hinweis: Aktualisierungen wurden zurückgewiesen")))
        #expect(GitPushFailureClassification.isLeaseStale(GitResult(
            exitCode: 1,
            stdout: "! [rejected] main -> main (stale info)",
            stderr: "error: failed to push some refs")))
        #expect(!GitPushFailureClassification.isNonFastForward(GitResult(
            exitCode: 128, stdout: "", stderr: "Could not resolve host")))
    }

    @Test("Ein fehlender Ziel-Ref ist auch ohne neue Commit-Objekte ein Push")
    func newRemoteRefIsAChange() {
        let plan = GitPushPlan(
            target: target,
            branch: "feature",
            sourceOID: String(repeating: "c", count: 40),
            remoteRef: "refs/heads/feature",
            remoteOID: nil,
            localAhead: 0,
            localBehind: 0,
            tracksTarget: false
        )
        #expect(plan.hasChangesToPush)
        #expect(plan.confirmation.explanation.contains("cccccccccccc"))
    }
}
