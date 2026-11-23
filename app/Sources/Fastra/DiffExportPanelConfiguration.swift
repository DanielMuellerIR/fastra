// Enge Zielvorgabe für den vorhandenen Export-Selbsttest. Normale
// Produktaufrufe behalten die ursprünglichen Vorgaben des Speicherdialogs.
import AppKit

@MainActor
enum DiffExportPanelConfiguration {
    private static var destination: URL?

    static func setDestination(_ destination: URL) { self.destination = destination }
    static func clearFixture() { destination = nil }

    static func configure(_ panel: NSSavePanel) {
        guard AppDefaults.launch.requestedSelfTest == "diffexport", let destination else { return }
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
    }
}
