import AppKit

/// Dieselbe Remote-Auswahl für Fetch und Pull; die Quelle bleibt im Dialog sichtbar.
enum GitRemoteActionChoice: Equatable {
    case all
    case remote(String, branch: String)
}

final class GitRemoteActionAccessory: NSView {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let branchField = NSTextField(string: "")
    private let branchLabel = NSTextField(labelWithString: L10n.string("Branch"))
    private let remotes: [String]
    private let status: GitStatusSummary?
    private let isPull: Bool

    init(remotes: [String], status: GitStatusSummary?, isPull: Bool,
         allowAll: Bool = true) {
        self.remotes = remotes
        self.status = status
        self.isPull = isPull
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: isPull ? 72 : 32))
        popup.identifier = NSUserInterfaceItemIdentifier("gitRemoteChoice")
        popup.setAccessibilityLabel(L10n.string("Remote"))
        if allowAll {
            popup.addItem(withTitle: isPull ? L10n.string("Alle abrufen, dann Pull-Quelle wählen") : L10n.string("Alle Remotes"))
            popup.lastItem?.representedObject = NSNull()
        }
        for remote in remotes {
            popup.addItem(withTitle: remote)
            popup.lastItem?.representedObject = remote
        }
        if isPull, let upstream = status?.upstream,
           let remote = remotes.sorted(by: { $0.count > $1.count }).first(where: {
               upstream.hasPrefix($0 + "/")
           }), let item = popup.itemArray.first(where: { $0.representedObject as? String == remote }) {
            popup.select(item)
        }
        popup.target = self
        popup.action = #selector(selectionChanged)
        popup.frame = NSRect(x: 0, y: isPull ? 40 : 0, width: 360, height: 28)
        addSubview(popup)
        if isPull {
            branchLabel.frame = NSRect(x: 0, y: 5, width: 62, height: 20)
            branchField.frame = NSRect(x: 68, y: 2, width: 292, height: 26)
            branchField.identifier = NSUserInterfaceItemIdentifier("gitPullBranch")
            branchField.setAccessibilityLabel(L10n.string("Branch"))
            addSubview(branchLabel)
            addSubview(branchField)
        }
        selectionChanged()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectionChanged() {
        let remote = popup.selectedItem?.representedObject as? String
        branchField.isEnabled = remote != nil
        if let remote, let status {
            branchField.stringValue = GitPullSource.defaultBranch(
                remote: remote, remotes: remotes, status: status
            )
        } else { branchField.stringValue = "" }
    }

    var choice: GitRemoteActionChoice {
        guard let remote = popup.selectedItem?.representedObject as? String else { return .all }
        return .remote(remote, branch: branchField.stringValue)
    }
}

enum GitRemoteActionDialog {
    static func makeAlert(remotes: [String], status: GitStatusSummary?, isPull: Bool,
                          allowAll: Bool = true) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = isPull
            ? L10n.format("Pull in lokalen Branch „%@“", status?.branch ?? L10n.string("Detached HEAD"))
            : L10n.string("Fetch-Quelle wählen")
        alert.informativeText = isPull
            ? L10n.string("Pull bindet den gewählten Remote-Branch in den aktuellen lokalen Branch ein. Der konfigurierte Upstream bleibt erhalten. Bei „Alle“ werden zuerst alle Remotes abgerufen; danach wählst du eine Quelle.")
            : L10n.string("Fetch aktualisiert Remote-Tracking-Refs und ändert keine Arbeitsdateien. Wähle einen Remote oder rufe alle ab.")
        alert.accessoryView = GitRemoteActionAccessory(remotes: remotes, status: status,
                                                       isPull: isPull, allowAll: allowAll)
        alert.addButton(withTitle: isPull ? L10n.string("Weiter") : L10n.string("Abrufen"))
        alert.addButton(withTitle: L10n.string("Abbrechen"))
        return alert
    }

    static func choose(remotes: [String], status: GitStatusSummary?, isPull: Bool,
                       allowAll: Bool = true) -> GitRemoteActionChoice? {
        let alert = makeAlert(remotes: remotes, status: status, isPull: isPull,
                              allowAll: allowAll)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (alert.accessoryView as? GitRemoteActionAccessory)?.choice
    }
}
