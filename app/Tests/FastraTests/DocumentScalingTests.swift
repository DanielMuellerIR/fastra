import Testing
import AppKit
@testable import Fastra

@Suite("Dokument-Schrift und Skalierung")
struct DocumentScalingTests {
    @Test("Dokument-Zoom ist unabhängig geklemmt")
    func zoomBounds() {
        #expect(DocumentZoom.scale(for: 0) == 1)
        #expect(DocumentZoom.clamped(-999) == DocumentZoom.minimumLevel)
        #expect(DocumentZoom.clamped(999) == DocumentZoom.maximumLevel)
    }

    @Test("Editor-Liste beginnt mit der aktuellen Wahl und enthält nur Monospace")
    func editorFontsAreMonospaced() {
        let current = "Fastra-Test-Font"
        let names = EditorFonts.monospacedNames(current: current)
        #expect(names.first == current)
        for name in names.dropFirst() {
            #expect(NSFont(name: name, size: 12)?.isFixedPitch == true)
        }
    }

    @Test("Vorschau-Liste beginnt mit der aktuellen Wahl und enthält Leseschriften")
    func previewFontsAreProportional() {
        let current = "Fastra-Test-Preview"
        let names = PreviewFonts.readingNames(current: current)
        #expect(names.first == current)
        for name in names.dropFirst() where name != PreviewFonts.systemName {
            #expect(NSFont(name: name, size: 12)?.isFixedPitch == false)
        }
    }
}
