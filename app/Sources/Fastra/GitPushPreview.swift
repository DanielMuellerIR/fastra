import Foundation

/// Vollständig gebundene Grundlage einer sichtbaren Push-Vorschau. Die
/// Mutation darf später nur mit denselben OIDs, demselben Ziel und derselben
/// geprüften Adresse starten.
struct GitPushPlan: Equatable {
    let target: GitPushTarget
    let branch: String
    let sourceOID: String
    let remoteRef: String
    let remoteOID: String?
    let localAhead: Int
    let localBehind: Int
    let tracksTarget: Bool

    var canFastForward: Bool { remoteOID == nil || localBehind == 0 }
    /// Auch ein neuer Ref auf einen bereits im Remote vorhandenen Commit ist
    /// eine echte Push-Änderung, obwohl Git dafür kein neues Commit-Objekt
    /// übertragen muss.
    var hasChangesToPush: Bool { remoteOID == nil || localAhead > 0 }

    private static func commitCount(_ value: Int) -> String {
        value == 1 ? L10n.string("1 Commit") : L10n.format("%ld Commits", value)
    }

    var confirmation: GitMutationConfirmation {
        let comparison: String
        if remoteOID == nil {
            comparison = L10n.format(
                "Der Remote-Branch existiert noch nicht. Fastra würde ihn am Commit %@ anlegen.",
                String(sourceOID.prefix(12))
            )
        } else if localBehind > 0 {
            comparison = L10n.format(
                "Lokaler Vorsprung: %@; lokal fehlend: %@. Ein normaler Fast-Forward-Push ist nicht möglich.",
                Self.commitCount(localAhead),
                Self.commitCount(localBehind)
            )
        } else {
            comparison = L10n.format(
                "Fastra würde %@ übertragen; lokal fehlen keine Commits dieses Remote-Branches.",
                Self.commitCount(localAhead)
            )
        }
        let explanation = L10n.format(
            "Remote: %@\nAdresse: %@\nZiel: %@\nQuell-Commit: %@\n\n%@",
            target.remote,
            target.displayAddress,
            remoteRef,
            String(sourceOID.prefix(12)),
            comparison
        )
        return GitMutationConfirmation(
            title: canFastForward
                ? L10n.string("Push prüfen")
                : L10n.string("Normaler Push nicht möglich"),
            explanation: explanation,
            confirmTitle: canFastForward
                ? (localAhead == 1
                    ? L10n.string("1 Commit pushen")
                    : L10n.format("%ld Commits pushen", localAhead))
                : L10n.string("Force Push with Lease prüfen"),
            isDestructive: !canFastForward
        )
    }
}

enum GitPushPlanParsing {
    static func oid(_ result: GitResult) -> String? {
        guard result.ok else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 40 || value.count == 64,
              value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    static func counts(_ result: GitResult) -> (ahead: Int, behind: Int)? {
        guard result.ok else { return nil }
        let values = result.stdout.split(whereSeparator: \Character.isWhitespace)
        guard values.count == 2,
              let ahead = Int(values[0]),
              let behind = Int(values[1]), ahead >= 0, behind >= 0 else {
            return nil
        }
        return (ahead, behind)
    }

    static func count(_ result: GitResult) -> Int? {
        guard result.ok else { return nil }
        guard let value = Int(result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )), value >= 0 else { return nil }
        return value
    }

    static func remoteOID(_ result: GitResult, expectedRef: String) -> String? {
        guard result.ok else { return nil }
        let lines = result.stdout.split(whereSeparator: \Character.isNewline)
        guard lines.count == 1 else { return nil }
        let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, String(fields[1]) == expectedRef else { return nil }
        return oid(GitResult(exitCode: 0, stdout: String(fields[0]), stderr: ""))
    }
}

enum GitPushFailureClassification {
    static func isLeaseStale(_ result: GitResult) -> Bool {
        let text = (result.stdoutForDisplay + "\n" + result.stderrForDisplay)
            .lowercased()
        return text.contains("[rejected]") && text.contains("stale info")
    }

    static func isNonFastForward(_ result: GitResult) -> Bool {
        let text = (result.stdoutForDisplay + "\n" + result.stderrForDisplay)
            .lowercased()
        return text.contains("non-fast-forward")
            || text.contains("kein vorspulen")
            || (text.contains("[rejected]")
                && (text.contains("fetch first") || text.contains("behind")))
            || (text.contains("[zurückgewiesen]")
                && (text.contains("zuerst holen") || text.contains("hinterher")))
    }
}
