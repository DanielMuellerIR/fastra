// FilePreview.swift
//
// Read-only-Vorschau für Bilder (ImageIO, mit Downsampling) und PDF (PDFKit)
// — Etappe 2 Wunschpaket 2026-07. Beide Vorschauen sind reine Anzeigen:
// Sie verändern nie die Datei und halten nie unkontrolliert das Vollbild
// im Speicher.

import SwiftUI
import AppKit
import PDFKit
import ImageIO

// MARK: - Lade-Logik (pure, testbar)

enum ImagePreviewLoader {
    /// Obergrenze der längsten Kante des dekodierten Vorschaubildes. Reicht
    /// für scharfe Darstellung auf Retina-Displays; ein 100-Megapixel-Foto
    /// wird trotzdem nie vollständig dekodiert.
    static let maxThumbnailPixelSize = 3200

    /// Dekodiert ein downgesampeltes Vorschaubild DIREKT auf Zielgröße.
    /// `CGImageSourceCreateThumbnailAtIndex` liest dabei nur die nötigen
    /// Daten — das Vollbild landet nie im Speicher (Leitplanke Etappe 2).
    /// `kCGImageSourceCreateThumbnailWithTransform` übernimmt die
    /// EXIF-Rotation, damit Fotos nicht gekippt erscheinen.
    static func loadDownsampled(url: URL,
                                maxPixel: Int = maxThumbnailPixelSize) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Echte Pixelmaße aus den Metadaten — ohne das Bild zu dekodieren.
    static func pixelDimensions(url: URL) -> (width: Int, height: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// SVG ist ein Vektorformat — ImageIO dekodiert es nicht, aber `NSImage`
    /// rendert es nativ (macOS 11+). Kein Downsampling nötig: Es wird erst
    /// beim Zeichnen in Zielgröße gerastert.
    static func loadSVG(url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }

    /// Wählt den passenden Lade-Pfad anhand der Dateiendung.
    static func loadPreviewImage(url: URL,
                                 maxPixel: Int = maxThumbnailPixelSize) -> NSImage? {
        let ext = ViewModeRouting.normalizedExtension(url.pathExtension)
        if ViewModeRouting.svgExtensions.contains(ext) { return loadSVG(url: url) }
        return loadDownsampled(url: url, maxPixel: maxPixel)
    }
}

// MARK: - Bild-Vorschau

/// Lädt das Vorschaubild asynchron; die View zeigt bis dahin einen Spinner.
final class ImagePreviewModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var infoText: String = ""
    @Published private(set) var isLoading = true

    init(url: URL, fileSize: UInt64) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = ImagePreviewLoader.loadPreviewImage(url: url)
            let dimensions = ImagePreviewLoader.pixelDimensions(url: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                guard let image else {
                    self.errorMessage = L10n.string("Dieses Bild kann nicht angezeigt werden. Die Datei ist möglicherweise beschädigt oder kein unterstütztes Bildformat.")
                    return
                }
                self.image = image
                var parts: [String] = []
                if let dimensions {
                    parts.append("\(dimensions.width) × \(dimensions.height) px")
                }
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize),
                                                       countStyle: .file))
                self.infoText = parts.joined(separator: " · ")
            }
        }
    }
}

/// AppKit-`NSImageView` statt SwiftUI-`Image`: proportionales Herunterskalieren
/// auf die Fenstergröße, und der Selbsttest kann das tatsächlich gerenderte
/// Bild in der View-Hierarchie beobachten (Muster `highlight`-Selbsttest).
private struct ImagePreviewSurface: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyDown
        view.isEditable = false
        view.animates = false
        view.setAccessibilityIdentifier("imagePreviewSurface")
        // Ohne niedrige Priorität würde das Bild das Fenster aufziehen wollen.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
    }
}

/// Read-only-Bildvorschau mit Kopfzeile (Maße, Dateigröße).
struct ImagePreviewView: View {
    @StateObject private var model: ImagePreviewModel

    init(url: URL, fileSize: UInt64) {
        _model = StateObject(wrappedValue: ImagePreviewModel(url: url,
                                                             fileSize: fileSize))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Bildvorschau · schreibgeschützt", systemImage: "photo")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(verbatim: model.infoText)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            content
        }
        .background(Theme.surfaceRaised)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            Text(verbatim: error)
                .fastraFont(.ui)
                .foregroundColor(Theme.diffRemovedFG)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let image = model.image {
            ImagePreviewSurface(image: image)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - PDF-Vorschau

/// Lädt das PDF-Dokument asynchron — `PDFDocument(url:)` liest synchron
/// und gehört deshalb nicht auf den Main-Thread.
final class PDFPreviewModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = true

    init(url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let document = PDFDocument(url: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                guard let document else {
                    self.errorMessage = L10n.string("Dieses PDF kann nicht angezeigt werden. Die Datei ist möglicherweise beschädigt oder passwortgeschützt.")
                    return
                }
                self.document = document
            }
        }
    }
}

/// PDFKit-View, read-only. `autoScales` passt die Seite an die Fensterbreite
/// an; Blättern/Zoomen übernimmt PDFKit.
private struct PDFPreviewSurface: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.setAccessibilityIdentifier("pdfPreviewSurface")
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// Read-only-PDF-Vorschau mit Kopfzeile (Seitenzahl).
struct PDFPreviewView: View {
    @StateObject private var model: PDFPreviewModel

    init(url: URL) {
        _model = StateObject(wrappedValue: PDFPreviewModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("PDF-Vorschau · schreibgeschützt", systemImage: "doc.richtext")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if let document = model.document {
                    Text(verbatim: L10n.format("%ld Seiten", document.pageCount))
                        .fastraFont(.small)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            content
        }
        .background(Theme.surfaceRaised)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            Text(verbatim: error)
                .fastraFont(.ui)
                .foregroundColor(Theme.diffRemovedFG)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let document = model.document {
            PDFPreviewSurface(document: document)
        }
    }
}
