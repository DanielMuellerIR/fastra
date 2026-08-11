import Foundation

/// Exakter Vergleich des ausgecheckten Commits mit einer lokalen
/// Remote-Tracking-Referenz. Die Werte stammen ausschließlich aus lokalen
/// Git-Refs; wann sie zuletzt vom Server aktualisiert wurden, zeigt der
/// vorhandene Fetch-Zeitstempel im Repository-Snapshot.
struct GitRemoteTrackingState: Equatable, Identifiable {
    let remote: String
    let branch: String
    let refName: String
    let oid: String
    let localAhead: Int
    let localBehind: Int

    var id: String { refName }
    var shortName: String { "\(remote)/\(branch)" }

    var compactCounts: String {
        if localAhead == 0 && localBehind == 0 { return "✓" }
        var parts: [String] = []
        if localAhead > 0 { parts.append("↑\(localAhead)") }
        if localBehind > 0 { parts.append("↓\(localBehind)") }
        return parts.joined(separator: " ")
    }
}

struct GitRemoteTrackingSnapshot: Equatable {
    let headOID: String?
    let states: [GitRemoteTrackingState]

    static let empty = GitRemoteTrackingSnapshot(headOID: nil, states: [])
}

/// Kompatible Ref-Liste für Git-Versionen vor 2.41. Erst ab 2.41 kann
/// `for-each-ref` Ahead/Behind selbst ausgeben; ältere System-Gits bekommen
/// dieselben Zähler über je ein `rev-list` auf den eingefrorenen OIDs.
enum GitRemoteTrackingRefList {
    struct Ref: Equatable {
        let refName: String
        let remote: String
        let branch: String
        let oid: String
    }

    struct Listing: Equatable {
        let headOID: String?
        let refs: [Ref]
    }

    static let arguments = [
        "for-each-ref",
        "--format=%(refname)%09%(objectname)%09%(symref)%09%(HEAD)",
        "refs/heads",
        "refs/remotes",
    ]
    static let headArguments = ["rev-parse", "--verify", "HEAD"]

    static func frozenHeadOID(_ result: GitResult) -> String? {
        guard result.ok else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 40 || value.count == 64,
              value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    static func parse(_ output: String) -> Listing {
        var headOID: String?
        var refs: [Ref] = []
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(
                separator: "\t", maxSplits: 3,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 4 else { continue }
            if fields[0].hasPrefix("refs/heads/"),
               fields[3].trimmingCharacters(in: .whitespaces) == "*" {
                headOID = fields[1]
                continue
            }
            guard fields[0].hasPrefix("refs/remotes/"), fields[2].isEmpty else {
                continue
            }
            let short = String(fields[0].dropFirst("refs/remotes/".count))
            guard let slash = short.firstIndex(of: "/") else { continue }
            let remote = String(short[..<slash])
            let branch = String(short[short.index(after: slash)...])
            guard !remote.isEmpty, !branch.isEmpty else { continue }
            refs.append(Ref(refName: fields[0], remote: remote,
                            branch: branch, oid: fields[1]))
        }
        return Listing(headOID: headOID,
                       refs: refs.sorted { $0.refName < $1.refName })
    }

    static func renderedResult(listing: Listing,
                               counts: [String: (remoteOnly: Int,
                                                 headOnly: Int)]) -> GitResult {
        var lines: [String] = []
        if let headOID = listing.headOID {
            lines.append("refs/heads/current\t\(headOID)\t\t*\t0 0")
        }
        for ref in listing.refs {
            guard let count = counts[ref.refName] else { continue }
            lines.append("\(ref.refName)\t\(ref.oid)\t\t\t"
                         + "\(count.remoteOnly) \(count.headOnly)")
        }
        return GitResult(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n",
                         stderr: "")
    }
}

enum GitRemoteTrackingList {
    /// `ahead-behind:HEAD` liefert pro Ref zuerst dessen Commits, die HEAD
    /// fehlen, und danach HEAD-Commits, die dem Ref fehlen. Für die Oberfläche
    /// werden diese beiden Zahlen zu lokal Behind beziehungsweise Ahead.
    /// `symref` filtert Remote-HEAD-Aliasse wie `origin/HEAD` aus.
    static var arguments: [String] { arguments(headOID: "HEAD") }

    static func arguments(headOID: String) -> [String] {
        [
            "for-each-ref",
            "--format=%(refname)%09%(objectname)%09%(symref)%09%(HEAD)%09%(ahead-behind:\(headOID))",
            "refs/heads",
            "refs/remotes",
        ]
    }

    /// Normalisiert das moderne Ergebnis auf dieselbe Textform wie den
    /// Kompatibilitätspfad. Der künstliche lokale Ref trägt die VOR dem
    /// Zählen eingefrorene HEAD-OID; ein externer Checkout während des
    /// `for-each-ref`-Prozesses kann den Batch dadurch nicht schönreden.
    static func renderedResult(headOID: String,
                               states: [GitRemoteTrackingState]) -> GitResult {
        var lines = ["refs/heads/current\t\(headOID)\t\t*\t0 0"]
        lines.append(contentsOf: states.map {
            "\($0.refName)\t\($0.oid)\t\t\t\($0.localBehind) \($0.localAhead)"
        })
        return GitResult(exitCode: 0,
                         stdout: lines.joined(separator: "\n") + "\n",
                         stderr: "")
    }

    static func parse(_ output: String) -> GitRemoteTrackingSnapshot {
        var headOID: String?
        var states: [GitRemoteTrackingState] = []

        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(
                separator: "\t",
                maxSplits: 4,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 5 else { continue }
            let refName = fields[0]
            let oid = fields[1]
            let symref = fields[2]
            let headMarker = fields[3].trimmingCharacters(in: .whitespaces)

            if refName.hasPrefix("refs/heads/"), headMarker == "*" {
                headOID = oid
                continue
            }
            guard refName.hasPrefix("refs/remotes/"), symref.isEmpty else {
                continue
            }
            let short = String(refName.dropFirst("refs/remotes/".count))
            guard let slash = short.firstIndex(of: "/") else { continue }
            let remote = String(short[..<slash])
            let branch = String(short[short.index(after: slash)...])
            let counts = fields[4].split(whereSeparator: \Character.isWhitespace)
            guard !remote.isEmpty, !branch.isEmpty, counts.count == 2,
                  let commitsOnlyInRemote = Int(counts[0]),
                  let commitsOnlyInHead = Int(counts[1]) else { continue }
            states.append(GitRemoteTrackingState(
                remote: remote,
                branch: branch,
                refName: refName,
                oid: oid,
                localAhead: commitsOnlyInHead,
                localBehind: commitsOnlyInRemote
            ))
        }

        return GitRemoteTrackingSnapshot(
            headOID: headOID,
            states: states.sorted { $0.shortName < $1.shortName }
        )
    }
}

enum GitRemoteTrackingPresentation {
    /// Pro Remote erscheint in der kompakten Branch-Zeile höchstens ein
    /// Vergleich: bevorzugt derselbe Branchname, danach der echte Upstream.
    /// Andere Remote-Branches bleiben im Graph sichtbar, überfrachten aber
    /// nicht die Seitenleiste.
    static func relevantStates(
        _ states: [GitRemoteTrackingState],
        branch: String?,
        upstream: String?
    ) -> [GitRemoteTrackingState] {
        let grouped = Dictionary(grouping: states, by: \GitRemoteTrackingState.remote)
        return grouped.keys.sorted().compactMap { remote in
            let candidates = grouped[remote] ?? []
            if let branch,
               let sameBranch = candidates.first(where: { $0.branch == branch }) {
                return sameBranch
            }
            if let upstream,
               let exactUpstream = candidates.first(where: { $0.shortName == upstream }) {
                return exactUpstream
            }
            return nil
        }
    }
}

enum GitGraphRefKind: Equatable {
    case head
    case localBranch
    case remoteBranch
    case tag
}

enum GitRemoteColorIndex {
    /// Swift `Hasher` ist absichtlich pro Prozess zufällig. Für dieselbe Farbe
    /// eines Remotes über App-Starts hinweg braucht die Oberfläche deshalb
    /// einen kleinen festen Byte-Hash.
    static func index(for remote: String, colorCount: Int) -> Int {
        guard colorCount > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in remote.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(colorCount))
    }
}

struct GitGraphRefPresentation: Equatable {
    let label: String
    let kind: GitGraphRefKind
    let tracking: GitRemoteTrackingState?

    static func make(
        ref: String,
        remoteTracking: [GitRemoteTrackingState]
    ) -> GitGraphRefPresentation {
        if ref.hasPrefix("tag: ") {
            return GitGraphRefPresentation(
                label: String(ref.dropFirst("tag: ".count)),
                kind: .tag,
                tracking: nil
            )
        }
        if ref.hasPrefix("HEAD") {
            return GitGraphRefPresentation(
                label: ref.replacingOccurrences(of: "HEAD -> ", with: ""),
                kind: .head,
                tracking: nil
            )
        }
        if let tracking = remoteTracking.first(where: { $0.shortName == ref }) {
            return GitGraphRefPresentation(
                label: ref,
                kind: .remoteBranch,
                tracking: tracking
            )
        }
        let remoteNames = Set(remoteTracking.map(\.remote))
        if remoteNames.contains(where: { ref.hasPrefix($0 + "/") }) {
            return GitGraphRefPresentation(
                label: ref,
                kind: .remoteBranch,
                tracking: nil
            )
        }
        return GitGraphRefPresentation(
            label: ref,
            kind: .localBranch,
            tracking: nil
        )
    }
}
