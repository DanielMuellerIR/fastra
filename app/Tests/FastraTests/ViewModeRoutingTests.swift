// ViewModeRoutingTests.swift
//
// Tests für den Ansichts-Umschalter Text/Vorschau/Hex (Etappe 2 Wunschpaket
// 2026-07): Routing Dateityp → verfügbare Ansichten + Standardansicht, und
// das Bild-Downsampling (nie das Vollbild dekodieren).

import AppKit
import Foundation
import Testing
@testable import Fastra

// MARK: - Routing: Dateityp → Ansichten

@Test("Bilddateien: Vorschau + Hex, Standard Vorschau")
func routing_imageDefaultsToPreview() {
    for ext in ["png", "JPG", "jpeg", "gif", "heic", "tiff", "webp"] {
        #expect(ViewModeRouting.availableModes(
            fileExtension: ext, loadedDisplayMode: .hex, hasURL: true
        ) == [.preview, .hex], "Endung \(ext)")
        #expect(ViewModeRouting.defaultMode(
            fileExtension: ext, loadedDisplayMode: .hex, hasURL: true
        ) == .preview, "Endung \(ext)")
    }
}

@Test("PDF: Vorschau + Hex, Standard Vorschau")
func routing_pdfDefaultsToPreview() {
    #expect(ViewModeRouting.availableModes(
        fileExtension: "pdf", loadedDisplayMode: .hex, hasURL: true
    ) == [.preview, .hex])
    #expect(ViewModeRouting.defaultMode(
        fileExtension: "pdf", loadedDisplayMode: .hex, hasURL: true
    ) == .preview)
}

@Test("SVG: Text + Vorschau + Hex, Standard Vorschau")
func routing_svgOffersAllThreeModes() {
    #expect(ViewModeRouting.availableModes(
        fileExtension: "svg", loadedDisplayMode: .text, hasURL: true
    ) == [.text, .preview, .hex])
    #expect(ViewModeRouting.defaultMode(
        fileExtension: "svg", loadedDisplayMode: .text, hasURL: true
    ) == .preview)
}

@Test("Textdatei: Text + Hex, Standard Text")
func routing_textFileDefaultsToText() {
    #expect(ViewModeRouting.availableModes(
        fileExtension: "txt", loadedDisplayMode: .text, hasURL: true
    ) == [.text, .hex])
    #expect(ViewModeRouting.defaultMode(
        fileExtension: "txt", loadedDisplayMode: .text, hasURL: true
    ) == .text)
}

@Test("Große Textdatei (Abschnittsansicht): Text + Hex, Standard Text")
func routing_chunkedTextKeepsTextDefault() {
    #expect(ViewModeRouting.availableModes(
        fileExtension: "log", loadedDisplayMode: .chunkedText, hasURL: true
    ) == [.text, .hex])
    #expect(ViewModeRouting.defaultMode(
        fileExtension: "log", loadedDisplayMode: .chunkedText, hasURL: true
    ) == .text)
}

@Test("Erkannte Binärdatei ohne Vorschau-Endung: nur Hex")
func routing_binaryOffersOnlyHex() {
    #expect(ViewModeRouting.availableModes(
        fileExtension: "bin", loadedDisplayMode: .hex, hasURL: true
    ) == [.hex])
    #expect(ViewModeRouting.defaultMode(
        fileExtension: "bin", loadedDisplayMode: .hex, hasURL: true
    ) == .hex)
}

@Test("Ungespeicherter Tab: nur der Editor")
func routing_unsavedTabHasOnlyText() {
    #expect(ViewModeRouting.availableModes(
        fileExtension: nil, loadedDisplayMode: .text, hasURL: false
    ) == [.text])
    #expect(ViewModeRouting.defaultMode(
        fileExtension: nil, loadedDisplayMode: .text, hasURL: false
    ) == .text)
}

@Test("Effektive Ansicht: manuelle Wahl gewinnt, unpassende Wahl fällt zurück")
func routing_effectiveModePrefersValidChoice() {
    // Manuell Hex für ein Bild → bleibt Hex.
    #expect(ViewModeRouting.effectiveMode(
        chosen: .hex, fileExtension: "png", loadedDisplayMode: .hex, hasURL: true
    ) == .hex)
    // Unpassende Alt-Wahl (Vorschau für .txt) → Standard Text.
    #expect(ViewModeRouting.effectiveMode(
        chosen: .preview, fileExtension: "txt", loadedDisplayMode: .text, hasURL: true
    ) == .text)
    // Keine Wahl → Standard (Bild → Vorschau).
    #expect(ViewModeRouting.effectiveMode(
        chosen: nil, fileExtension: "png", loadedDisplayMode: .hex, hasURL: true
    ) == .preview)
}

// MARK: - Downsampling

/// Schreibt ein einfarbiges PNG mit den gewünschten Pixelmaßen.
private func writePNG(width: Int, height: Int,
                      color: NSColor = .systemRed) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-viewmode-\(UUID().uuidString).png")
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
    return url
}

@Test("Downsampling: großes Bild wird nie in voller Auflösung dekodiert")
func downsampling_capsDecodedDimensions() throws {
    let url = try writePNG(width: 2400, height: 1200)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = ImagePreviewLoader.loadDownsampled(url: url, maxPixel: 320)
    let unwrapped = try #require(image)
    #expect(unwrapped.size.width <= 320)
    #expect(unwrapped.size.height <= 320)
    // Seitenverhältnis bleibt erhalten (2:1).
    #expect(abs(unwrapped.size.width / unwrapped.size.height - 2.0) < 0.05)

    // Die Metadaten liefern weiterhin die ECHTEN Pixelmaße für die Kopfzeile.
    let dims = try #require(ImagePreviewLoader.pixelDimensions(url: url))
    #expect(dims.width == 2400)
    #expect(dims.height == 1200)
}

@Test("Kleines Bild bleibt beim Downsampling unter der Obergrenze unverändert")
func downsampling_keepsSmallImage() throws {
    let url = try writePNG(width: 64, height: 32)
    defer { try? FileManager.default.removeItem(at: url) }

    let image = try #require(ImagePreviewLoader.loadDownsampled(url: url,
                                                                maxPixel: 320))
    #expect(Int(image.size.width) == 64)
    #expect(Int(image.size.height) == 32)
}

@Test("Speichern greift für Binär-Tabs nicht (Trunkierungsschutz bleibt)")
@MainActor
func saving_refusesBinaryDisplayModes() throws {
    let suite = "fastra-viewmode-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-viewmode-save-\(UUID().uuidString).png")

    let ws = Workspace(defaults: defaults)
    // Binär geladener Tab (Hex-Ansicht hält bewusst keinen Voll-Buffer):
    // ⌘S darf die Datei niemals aus dem leeren String-Buffer überschreiben.
    var tab = EditorTab(title: target.lastPathComponent,
                        path: target.deletingLastPathComponent().path,
                        url: target, content: "", isDirty: true)
    tab.displayMode = .hex
    ws.tabs = [tab]
    ws.activeTabID = tab.id

    ws.saveActiveTab()

    #expect(!FileManager.default.fileExists(atPath: target.path),
            "Ein Hex-/Binär-Tab darf nie über den Text-Save-Pfad schreiben")
}

@Test("Kaputte Bilddatei → nil statt Crash oder Platzhalter")
func downsampling_rejectsCorruptData() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastra-viewmode-broken-\(UUID().uuidString).png")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(ImagePreviewLoader.loadDownsampled(url: url, maxPixel: 320) == nil)
}
