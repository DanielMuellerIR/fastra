import AppKit
import CoreText

// Reproduzierbarer 2×-Master für die 600 × 420 Punkte große DMG-Inhaltsfläche.
// Finder legt App- und Programme-Icon später genau über die beiden Kreise.
let size = NSSize(width: 1200, height: 840)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }
bitmap.size = size

let fontURL = URL(fileURLWithPath: "Sources/Fastra/Resources/Sora-SemiBold.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

func centeredText(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let measured = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (size.width - measured.width) / 2, y: y),
              withAttributes: attributes)
}

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
let context = graphicsContext.cgContext

// Sehr dezenter warmer Verlauf wie in der App, ohne transparente Außenkante.
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0xFBF9F2).cgColor, color(0xF7F3E8).cgColor] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 600, y: 840),
                           end: CGPoint(x: 600, y: 0),
                           options: [])

let ink = color(0x292721)
let muted = color(0x746F63)
let gold = color(0xC79A27)
let dashed = color(0xB8B1A0)

let titleFont = NSFont(name: "Sora-SemiBold", size: 64)
    ?? NSFont.systemFont(ofSize: 64, weight: .semibold)
centeredText("Fastra", y: 686, font: titleFont, color: ink)
centeredText("Native macOS text editor", y: 618,
             font: .systemFont(ofSize: 26, weight: .regular), color: muted)

context.setStrokeColor(gold.cgColor)
context.setLineWidth(7)
context.setLineCap(.round)
context.move(to: CGPoint(x: 543, y: 581))
context.addLine(to: CGPoint(x: 657, y: 581))
context.strokePath()

context.setStrokeColor(dashed.cgColor)
context.setLineWidth(4)
context.setLineDash(phase: 0, lengths: [19, 17])
for centerX in [300.0, 900.0] {
    context.strokeEllipse(in: CGRect(x: centerX - 128, y: 128, width: 256, height: 256))
}
context.setLineDash(phase: 0, lengths: [])

// Pfeil zwischen App und Programme-Ordner.
context.setFillColor(gold.cgColor)
context.fill(CGRect(x: 476, y: 250, width: 207, height: 12))
context.beginPath()
context.move(to: CGPoint(x: 718, y: 256))
context.addLine(to: CGPoint(x: 680, y: 279))
context.addLine(to: CGPoint(x: 680, y: 233))
context.closePath()
context.fillPath()

centeredText("Zum Installieren in den Applications-Ordner ziehen · Drag to Applications to install",
             y: 36, font: .systemFont(ofSize: 20, weight: .regular), color: muted)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: "src/DmgBackground.png"), options: .atomic)
