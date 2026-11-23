// Enge Vorgaben für den vorhandenen Dateidialog-Selbsttest. Normale
// Produktaufrufe erhalten weder Fixturepfade noch eine Panelbeobachtung.
import AppKit

@MainActor
enum TextSnippetPanelConfiguration {
    private static var snippetExportDestination: URL?
    private static var snippetImportDirectory: URL?
    private static weak var snippetFilePanel: NSSavePanel?

    static var observedPanel: NSSavePanel? { snippetFilePanel }
    static func clearObservedPanel() { snippetFilePanel = nil }
    static func setExportDestination(_ destination: URL) { snippetExportDestination = destination }
    static func setImportDirectory(_ directory: URL) { snippetImportDirectory = directory }
    static func clearFixture() {
        snippetExportDestination = nil; snippetImportDirectory = nil
    }

    static func configure(_ panel: NSSavePanel, importing: Bool) {
        guard AppDefaults.launch.requestedSelfTest == "snippetfiles" else { return }
        snippetFilePanel = panel
        if importing { panel.directoryURL = snippetImportDirectory }
        else if let destination = snippetExportDestination {
            panel.directoryURL = destination.deletingLastPathComponent()
            panel.nameFieldStringValue = destination.lastPathComponent
        }
    }
}
