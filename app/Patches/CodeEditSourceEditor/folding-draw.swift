import AppKit
import CodeEditTextView

extension LineFoldRibbonView {
    struct DrawingFoldInfo {
        let fold: FoldRange
        let startLine: TextLineStorage<TextLine>.TextLinePosition
        let endLine: TextLineStorage<TextLine>.TextLinePosition
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let textView = model?.controller?.textView,
              let layoutManager = textView.layoutManager else { return }
        let visible = textView.visibleRect
        let lines = Array(layoutManager.linesStartingAt(visible.minY, until: visible.maxY))
        guard let first = lines.first, let last = lines.last else { return }
        let folds = model?.getFolds(in: first.range.location..<last.range.upperBound) ?? []
        context.saveGState()
        context.clip(to: dirtyRect)
        concatenateTextYTransform(in: context)
        let collapsed = folds.filter(\.isCollapsed)
        for fold in folds {
            guard !collapsed.contains(where: {
                $0.range.lowerBound < fold.range.lowerBound && $0.range.contains(fold.range.lowerBound)
            }), let line = layoutManager.textLineForOffset(fold.range.lowerBound),
                  line.height > 0, line.yPos >= visible.minY - line.height,
                  line.yPos <= visible.maxY else { continue }
            let x: CGFloat = 3
            let y = line.yPos + min(line.height, textView.font.lineHeight) / 2
            context.setFillColor(NSColor.secondaryLabelColor.cgColor)
            let path = CGMutablePath()
            if fold.isCollapsed {
                path.move(to: CGPoint(x: x, y: y - 4))
                path.addLine(to: CGPoint(x: x + 6, y: y))
                path.addLine(to: CGPoint(x: x, y: y + 4))
            } else {
                path.move(to: CGPoint(x: x - 1, y: y - 3))
                path.addLine(to: CGPoint(x: x + 7, y: y - 3))
                path.addLine(to: CGPoint(x: x + 3, y: y + 3))
            }
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()
    }
}
