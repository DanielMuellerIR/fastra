import AppKit
import SwiftUI
import Testing
@testable import Fastra

@MainActor
struct SelectableMatchTextTests {
    @Test("Treffertext bleibt mit allen Gruppenfarben im hellen und dunklen Detailfeld lesbar")
    func contrastAcrossAppearances() async throws {
        let sample = "ABC Texte"
        let groups = [1, 2, 3].map { (number: $0, range: NSRange(location: $0 - 1, length: 1)) }
        let host = NSHostingView(rootView: SelectableMatchText(
            matchText: sample, groupRanges: groups, selection: .constant(NSRange(location: 4, length: 1))
        ).background(Theme.surfaceSand))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 270, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func findTextView(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, textView.string == sample { return textView }
            return view.subviews.lazy.compactMap(findTextView).first
        }
        for name: NSAppearance.Name in [.darkAqua, .aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            try #require(await waitUntil {
                host.layoutSubtreeIfNeeded()
                return findTextView(host) != nil
            })
            let textView = try #require(findTextView(host))
            let storage = try #require(textView.textStorage)
            #expect(textView.isSelectable)
            #expect(!textView.isEditable)
            #expect(textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name)
            var colors: [(foreground: NSColor, background: NSColor)] = []
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let surface = NSColor(cgColor: NSColor(Theme.surfaceSand).cgColor)?.usingColorSpace(.sRGB)
                else { return }
                for index in [4, 0, 1, 2] {
                    let attributes = storage.attributes(at: index, effectiveRange: nil)
                    guard let ink = attributes[.foregroundColor] as? NSColor,
                          let foreground = NSColor(cgColor: ink.cgColor)?.usingColorSpace(.sRGB)
                    else { continue }
                    if index < 3 {
                        guard let fill = attributes[.backgroundColor] as? NSColor,
                              let tint = NSColor(cgColor: fill.cgColor)?.usingColorSpace(.sRGB),
                              let background = surface.blended(withFraction: tint.alphaComponent,
                                                               of: tint.withAlphaComponent(1))
                        else { continue }
                        colors.append((foreground, background))
                    } else if attributes[.backgroundColor] == nil {
                        colors.append((foreground, surface))
                    }
                }
            }
            try #require(colors.count == 4)
            for (index, color) in colors.enumerated() {
                let ink = try #require(color.background.blended(withFraction: color.foreground.alphaComponent,
                                                                  of: color.foreground.withAlphaComponent(1)))
                let a = luminance(ink)
                let b = luminance(color.background)
                let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                #expect(contrast >= 4.5, "\(name.rawValue), Textprobe \(index): \(contrast)")
            }
        }
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
             + 0.0722 * linear(color.blueComponent)
    }
}
