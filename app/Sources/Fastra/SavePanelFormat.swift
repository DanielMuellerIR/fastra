import AppKit
import CodeEditLanguages

/// Ein sichtbares Dateiformat des „Speichern unter“-Dialogs. Die Liste wird
/// aus demselben Sprachkatalog wie der Footer gebaut; neue tatsächlich
/// gebündelte Syntaxsprachen erscheinen dadurch automatisch auch hier.
struct SaveFormatChoice: Equatable, Identifiable {
    let formatID: DocumentFormatID
    let displayName: String
    let fileExtension: String
    /// Sonderformate ohne Endung, deren Sprache nur über den vollständigen
    /// Dateinamen erkannt wird (derzeit `Dockerfile`).
    let exactFileName: String?

    init(formatID: DocumentFormatID, displayName: String, fileExtension: String,
         exactFileName: String? = nil) {
        self.formatID = formatID
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.exactFileName = exactFileName
    }

    var id: String { formatID.rawValue }

    var fileNameHint: String {
        exactFileName ?? ".\(fileExtension)"
    }
}

enum SavePanelFormatSupport {
    static var choices: [SaveFormatChoice] {
        let languageChoices = LanguageMenuSupport.selectableEntries.map { entry in
            let format = DocumentFormatResolver.format(for: entry)
            return SaveFormatChoice(
                formatID: format.id,
                displayName: format.displayName,
                fileExtension: preferredExtension(for: entry),
                exactFileName: exactFileName(for: entry)
            )
        }
        let extras = [
            SaveFormatChoice(formatID: .csv, displayName: "CSV", fileExtension: "csv"),
            SaveFormatChoice(formatID: .xml, displayName: "XML", fileExtension: "xml"),
        ]
        guard let plain = languageChoices.first(where: { $0.formatID == .plainText }) else {
            return (languageChoices + extras).sorted(by: sort)
        }
        return [plain] + (languageChoices.filter { $0.id != plain.id } + extras)
            .sorted(by: sort)
    }

    static func choice(for formatID: DocumentFormatID) -> SaveFormatChoice {
        choices.first(where: { $0.formatID == formatID })
            ?? choices.first(where: { $0.formatID == .plainText })!
    }

    /// Ein fehlender Suffix wird schon beim Öffnen des Panels ergänzt. Ein
    /// vorhandener manueller Suffix bleibt dagegen erhalten, bis der Nutzer
    /// ausdrücklich ein anderes Format aus der Liste auswählt.
    static func initialFileName(_ rawName: String, choice: SaveFormatChoice) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? L10n.string("Unbenannt") : trimmed
        if let exact = choice.exactFileName { return exact }
        guard (name as NSString).pathExtension.isEmpty else { return name }
        return replacingExtension(of: name, with: choice.fileExtension)
    }

    static func applying(_ choice: SaveFormatChoice, to rawName: String) -> String {
        choice.exactFileName
            ?? replacingExtension(of: rawName, with: choice.fileExtension)
    }

    static func replacingExtension(of rawName: String, with fileExtension: String) -> String {
        let name = rawName as NSString
        let stem = name.pathExtension.isEmpty ? rawName : name.deletingPathExtension
        guard !fileExtension.isEmpty else { return stem }
        return (stem as NSString).appendingPathExtension(fileExtension) ?? "\(stem).\(fileExtension)"
    }

    private static func sort(_ lhs: SaveFormatChoice, _ rhs: SaveFormatChoice) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private static func preferredExtension(for entry: LanguageMenuSupport.Entry) -> String {
        switch entry {
        case .custom(let language):
            if language.id == CustomLanguageRegistry.fourD.id { return "4dm" }
            return language.fileExtensions.sorted().first ?? "txt"
        case .grammar(let language):
            switch language.id {
            case .plainText: return "txt"
            case .agda: return "agda"
            case .bash: return "sh"
            case .c: return "c"
            case .cpp: return "cpp"
            case .cSharp: return "cs"
            case .css: return "css"
            case .dart: return "dart"
            case .dockerfile: return ""
            case .elixir: return "ex"
            case .go: return "go"
            case .goMod: return "mod"
            case .haskell: return "hs"
            case .html: return "html"
            case .java: return "java"
            case .javascript: return "js"
            case .jsdoc: return "js"
            case .json: return "json"
            case .jsx: return "jsx"
            case .julia: return "jl"
            case .kotlin: return "kt"
            case .lua: return "lua"
            case .markdown: return "md"
            case .markdownInline: return "md"
            case .objc: return "m"
            case .ocaml: return "ml"
            case .ocamlInterface: return "mli"
            case .perl: return "pl"
            case .php: return "php"
            case .python: return "py"
            case .regex: return "regex"
            case .ruby: return "rb"
            case .rust: return "rs"
            case .scala: return "scala"
            case .sql: return "sql"
            case .swift: return "swift"
            case .toml: return "toml"
            case .tsx: return "tsx"
            case .typescript: return "ts"
            case .verilog: return "v"
            case .yaml: return "yml"
            case .zig: return "zig"
            }
        }
    }

    private static func exactFileName(for entry: LanguageMenuSupport.Entry) -> String? {
        guard case .grammar(let language) = entry, language.id == .dockerfile else {
            return nil
        }
        return "Dockerfile"
    }
}

/// Behält Popup und Zielpanel während des modalen Laufs zusammen. Es werden
/// bewusst keine `allowedContentTypes` gesetzt: Nur so akzeptiert macOS neben
/// den Vorschlägen weiterhin jede manuell eingegebene Endung.
final class SavePanelFormatAccessory: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?
    private let choices: [SaveFormatChoice]

    init(panel: NSSavePanel, selectedFormatID: DocumentFormatID) {
        self.panel = panel
        choices = SavePanelFormatSupport.choices

        let label = NSTextField(labelWithString: L10n.string("Format:"))
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        super.init()

        for choice in choices {
            popup.addItem(withTitle: "\(choice.displayName) (\(choice.fileNameHint))")
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: L10n.string("Eigene Endung (manuell)"))
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        popup.selectItem(at: choices.firstIndex(where: { $0.formatID == selectedFormatID }) ?? 0)

        view.addSubview(label)
        view.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 70),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard choices.indices.contains(sender.indexOfSelectedItem), let panel else {
            return // „Eigene Endung“: den im Namensfeld getippten Suffix bewahren.
        }
        let choice = choices[sender.indexOfSelectedItem]
        panel.nameFieldStringValue = SavePanelFormatSupport.applying(
            choice, to: panel.nameFieldStringValue
        )
    }
}
