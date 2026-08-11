import Foundation
import Testing
@testable import Fastra

@Suite("Git-Remote-Vergleiche")
struct GitRemoteTrackingTests {
    @Test("Parser ordnet Ahead und Behind aus Sicht des lokalen HEAD zu")
    func parsesPerRemoteCountsAndSkipsSymbolicHeads() {
        let output = """
        refs/heads/main\tlocaloid\t\t*\t0 0
        refs/remotes/github/HEAD\tghoid\trefs/remotes/github/main\t \t0 2
        refs/remotes/github/main\tghoid\t\t \t0 2
        refs/remotes/backup/main\tlocaloid\t\t \t0 0
        refs/remotes/team/main\tteamoid\t\t \t3 1
        """

        let snapshot = GitRemoteTrackingList.parse(output)

        #expect(snapshot.headOID == "localoid")
        #expect(snapshot.states == [
            GitRemoteTrackingState(
                remote: "github", branch: "main",
                refName: "refs/remotes/github/main", oid: "ghoid",
                localAhead: 2, localBehind: 0
            ),
            GitRemoteTrackingState(
                remote: "backup", branch: "main",
                refName: "refs/remotes/backup/main", oid: "localoid",
                localAhead: 0, localBehind: 0
            ),
            GitRemoteTrackingState(
                remote: "team", branch: "main",
                refName: "refs/remotes/team/main", oid: "teamoid",
                localAhead: 1, localBehind: 3
            ),
        ])
    }

    @Test("Kompatibler Parser braucht den erst ab Git 2.41 verfügbaren Atom nicht")
    func compatibleRefListingRendersTheSameSnapshot() {
        #expect(!GitRemoteTrackingRefList.arguments.joined()
            .contains("ahead-behind"))
        let listing = GitRemoteTrackingRefList.parse("""
        refs/heads/main\tlocaloid\t\t*
        refs/remotes/origin/HEAD\tremoteoid\trefs/remotes/origin/main\t\u{20}
        refs/remotes/origin/main\tremoteoid\t\t\u{20}
        """)
        let result = GitRemoteTrackingRefList.renderedResult(
            listing: listing,
            counts: [
                "refs/remotes/origin/main": (remoteOnly: 2, headOnly: 5),
            ]
        )
        let snapshot = GitRemoteTrackingList.parse(result.stdout)
        #expect(snapshot.headOID == "localoid")
        #expect(snapshot.states.first?.localAhead == 5)
        #expect(snapshot.states.first?.localBehind == 2)
        let detached = String(repeating: "d", count: 40)
        #expect(GitRemoteTrackingRefList.frozenHeadOID(GitResult(
            exitCode: 0, stdout: detached + "\n", stderr: ""
        )) == detached)
        #expect(GitRemoteTrackingRefList.frozenHeadOID(GitResult(
            exitCode: 0, stdout: "kein-oid\n", stderr: ""
        )) == nil)
    }

    @Test("Seitenleiste wählt pro Remote denselben Branch und dann den Upstream")
    func choosesRelevantStatePerRemote() {
        let states = [
            state("github", "main", ahead: 2, behind: 0),
            state("github", "release", ahead: 0, behind: 4),
            state("team", "integration", ahead: 1, behind: 1),
            state("team", "release", ahead: 3, behind: 0),
        ]

        let relevant = GitRemoteTrackingPresentation.relevantStates(
            states,
            branch: "main",
            upstream: "team/integration"
        )

        #expect(relevant.map(\.shortName) == ["github/main", "team/integration"])
        #expect(relevant.map(\.compactCounts) == ["↑2", "↑1 ↓1"])
    }

    @Test("Graph unterscheidet lokale Branches, Remote-Refs und Tags")
    func graphPresentationClassifiesKnownRefs() {
        let tracking = [state("github", "main", ahead: 2, behind: 0)]

        #expect(GitGraphRefPresentation.make(
            ref: "main", remoteTracking: tracking
        ).kind == .localBranch)
        let remote = GitGraphRefPresentation.make(
            ref: "github/main", remoteTracking: tracking
        )
        #expect(remote.kind == .remoteBranch)
        #expect(remote.tracking?.localAhead == 2)
        #expect(GitGraphRefPresentation.make(
            ref: "github/HEAD", remoteTracking: tracking
        ).kind == .remoteBranch)
        #expect(GitGraphRefPresentation.make(
            ref: "tag: v1.0", remoteTracking: tracking
        ).kind == .tag)
        #expect(GitGraphRefPresentation.make(
            ref: "HEAD -> main", remoteTracking: tracking
        ).kind == .head)
    }

    @Test("Remote-Farben bleiben über Prozesse hinweg deterministisch")
    func stableRemoteColors() {
        let first = GitRemoteColorIndex.index(for: "origin", colorCount: 3)
        #expect(first == GitRemoteColorIndex.index(for: "origin", colorCount: 3))
        #expect(first >= 0 && first < 3)
        let indices = Set(["origin", "github", "company", "backup"].map {
            GitRemoteColorIndex.index(for: $0, colorCount: 3)
        })
        #expect(indices.count > 1)
    }

    @Test("Vier Remotes bleiben sichtbar angekündigt und haben eigene Frische")
    func fourRemoteSummaryShowsOverflowAndPerRemoteFreshness() {
        let states = [
            state("a", "main", ahead: 1, behind: 0),
            state("b", "main", ahead: 0, behind: 1),
            state("c", "main", ahead: 1, behind: 1),
            state("d", "main", ahead: 0, behind: 0),
        ]
        #expect(FileTreeSidebar.visibleRemoteComparisons(states).count == 3)
        #expect(FileTreeSidebar.additionalRemoteComparisonCount(states) == 1)

        var fetch = GitFetchSnapshot.none
        let now = Date(timeIntervalSince1970: 10_000)
        fetch.lastSuccessByRemote["a"] = now.addingTimeInterval(-120)
        let description = FileTreeSidebar.remoteComparisonDescription(
            states, fetch: fetch, now: now
        )
        #expect(description.contains("a/main"))
        #expect(description.contains(
            FileTreeSidebar.ageDescription(
                since: now.addingTimeInterval(-120), now: now
            )
        ))
        #expect(description.contains("d/main"))
        #expect(description.contains(
            L10n.string("für diesen Remote noch nicht abgerufen")
        ))
    }

    private func state(_ remote: String, _ branch: String,
                       ahead: Int, behind: Int) -> GitRemoteTrackingState {
        GitRemoteTrackingState(
            remote: remote,
            branch: branch,
            refName: "refs/remotes/\(remote)/\(branch)",
            oid: "\(remote)-\(branch)",
            localAhead: ahead,
            localBehind: behind
        )
    }
}
