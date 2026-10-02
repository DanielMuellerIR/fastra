import AppKit
import CoreText

/// Stabile Werte für die rein visuelle Einrückung von Folgefragmenten.
public enum SoftWrapIndentation: String, CaseIterable {
    case flushLeft
    case firstLine
    case reverse
}

enum SoftWrapFragmentGeometry {
    static func continuationOffset(
        in string: NSAttributedString,
        maxWidth: CGFloat,
        mode: SoftWrapIndentation,
        indentationColumns: Int
    ) -> CGFloat {
        guard mode != .flushLeft, maxWidth > 0,
              maxWidth < .greatestFiniteMagnitude, string.length > 0 else { return 0 }
        let attributes = string.attributes(at: 0, effectiveRange: nil)
        let space = NSAttributedString(string: " ", attributes: attributes)
        let spaceLine = CTLineCreateWithAttributedString(space)
        let spaceWidth = max(CGFloat(CTLineGetTypographicBounds(spaceLine, nil, nil, nil)), 1)
        let text = string.string as NSString
        // Mehr Einrückung als die gesamte Breite wird ohnehin geklemmt.
        // Auch eine Megazeile aus Leerzeichen braucht daher nur einen kurzen Scan.
        let limit = min(text.length, Int(min(ceil(maxWidth / spaceWidth) + 1, CGFloat(Int.max / 2))))
        var end = 0
        while end < limit {
            let character = text.character(at: end)
            guard character == 32 || character == 9 else { break }
            end += 1
        }
        let prefix = string.attributedSubstring(from: NSRange(location: 0, length: end))
        let line = CTLineCreateWithAttributedString(prefix)
        let leadingWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let extra = mode == .reverse ? CGFloat(max(indentationColumns, 1)) * spaceWidth : 0
        // Ein positiver Rest lässt den Graphem-Fortschritt des Typesetters greifen.
        return min(max(leadingWidth + extra, 0), max(maxWidth - 1, 0))
    }
}
