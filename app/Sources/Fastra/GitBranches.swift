import Foundation

struct GitBranch: Identifiable, Equatable {
    let name: String
    let isCurrent: Bool
    /// Pfad eines ANDEREN Arbeitsverzeichnisses (`git worktree`), das diesen
    /// Branch bereits ausgecheckt hat. `nil`, wenn der Branch frei ist oder im
    /// eigenen Arbeitsverzeichnis liegt. Git lässt denselben Branch nur einmal
    /// auschecken; ohne dieses Feld böte die Branch-Auswahl einen Wechsel an,
    /// den git anschließend mit „is already used by worktree at …" abweist.
    let blockingWorktree: String?
    var id: String { name }

    init(name: String, isCurrent: Bool, blockingWorktree: String? = nil) {
        self.name = name
        self.isCurrent = isCurrent
        self.blockingWorktree = blockingWorktree
    }
}

enum GitBranchList {
    /// Tab als Trennzeichen: Branchnamen dürfen Leerzeichen enthalten, Tabs
    /// jedoch nicht. Das Sternchen-Feld ist nur beim aktuellen Branch gesetzt.
    /// `%(worktreepath)` steht bewusst am Ende — ein Verzeichnisname darf ein
    /// Tabulatorzeichen enthalten, und als letztes Feld nimmt er den Rest der
    /// Zeile auf. Das Feld gibt es seit git 2.23 (2019); die von macOS 14
    /// gelieferten git-Fassungen liegen weit darüber.
    static let arguments = [
        "for-each-ref",
        "--format=%(refname:short)%09%(HEAD)%09%(worktreepath)",
        "--sort=refname",
        "refs/heads",
    ]

    static func parse(_ output: String) -> [GitBranch] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            guard let first = parts.first else { return nil }
            let name = String(first)
            guard !name.isEmpty else { return nil }
            let marker = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let isCurrent = marker == "*"
            // Der eigene Worktree steht ebenfalls in `%(worktreepath)`. Er
            // blockiert nichts, deshalb zählt nur ein FREMDES Verzeichnis.
            let worktree = parts.count > 2 ? String(parts[2]) : ""
            let blocking = (isCurrent || worktree.isEmpty) ? nil : worktree
            return GitBranch(name: name, isCurrent: isCurrent,
                             blockingWorktree: blocking)
        }
    }
}

/// Beschreibt die Absage eines Branch-Wechsels, den git strukturell verbietet,
/// weil derselbe Branch schon in einem anderen Arbeitsverzeichnis ausgecheckt
/// ist. Bewusst als eigener Wert: Der Text ist ohne AppKit prüfbar, und
/// Selbsttests können den Dialog durch einen eigenen Handler ersetzen.
struct GitBranchWorktreeBlock: Equatable {
    let branch: String
    let worktree: String
    /// Ein abgemeldeter Worktree-Ordner kann gelöscht worden sein, ohne dass
    /// git ihn schon vergessen hat. Dann hilft nur `git worktree prune`.
    let worktreeExists: Bool

    var informativeText: String {
        let explanation = L10n.format(
            "Der Branch „%@“ ist bereits im Arbeitsverzeichnis „%@“ ausgecheckt. Git lässt denselben Branch nur an einer Stelle gleichzeitig zu.",
            branch, worktree
        )
        let advice = worktreeExists
            ? L10n.string("Du kannst dieses Arbeitsverzeichnis als Projekt öffnen — der gesuchte Stand liegt dort schon.")
            : L10n.string("Der Ordner existiert nicht mehr. Melde ihn mit „git worktree prune“ ab, danach ist der Branch wieder frei.")
        return explanation + "\n\n" + advice
    }
}
