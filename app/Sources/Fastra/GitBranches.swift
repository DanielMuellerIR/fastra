import Foundation

struct GitBranch: Identifiable, Equatable {
    let name: String
    let isCurrent: Bool
    var id: String { name }
}

enum GitBranchList {
    /// Tab als Trennzeichen: Branchnamen dürfen Leerzeichen enthalten, Tabs
    /// jedoch nicht. Das Sternchen-Feld ist nur beim aktuellen Branch gesetzt.
    static let arguments = [
        "for-each-ref",
        "--format=%(refname:short)%09%(HEAD)",
        "--sort=refname",
        "refs/heads",
    ]

    static func parse(_ output: String) -> [GitBranch] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard let first = parts.first else { return nil }
            let name = String(first)
            guard !name.isEmpty else { return nil }
            let marker = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return GitBranch(name: name, isCurrent: marker == "*")
        }
    }
}
