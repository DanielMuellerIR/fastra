import AppKit
import CodeEditTextView

extension MinimapView {
    // Geschätzte Gesamthöhen können sich zwischen den beiden faulen Layouts
    // unterscheiden. Die sichtbare Fläche wird deshalb über dieselbe logische
    // Zeile und das konkrete Fragment abgebildet. Dessen Höhenanteil bleibt
    // erhalten, auch wenn nur ein Editorfragment eine große Schrift enthält.
    func fastraMinimapY(forEditorY y: CGFloat) -> CGFloat? {
        guard let editor = textView?.layoutManager, let layoutManager,
              let line = editor.textLineForPosition(y),
              let mini = layoutManager.textLineForIndex(line.index) else { return nil }
        let localY = min(max(y - line.yPos, 0), line.height)
        guard let fragment = line.data.lineFragments.getLine(atPosition: localY),
              let target = mini.data.lineFragments.getLine(atIndex: fragment.index),
              fragment.range == target.range else { return nil }
        let fraction = min(max((localY - fragment.yPos) / max(fragment.height, 1), 0), 1)
        return mini.yPos + target.yPos + fraction * target.height
    }

    func fastraEditorY(forMinimapY y: CGFloat) -> CGFloat? {
        guard let editor = textView?.layoutManager, let layoutManager,
              let mini = layoutManager.textLineForPosition(y),
              let line = editor.textLineForIndex(mini.index) else { return nil }
        let localY = min(max(y - mini.yPos, 0), mini.height)
        guard let fragment = mini.data.lineFragments.getLine(atPosition: localY),
              let target = line.data.lineFragments.getLine(atIndex: fragment.index),
              fragment.range == target.range else { return nil }
        let fraction = min(max((localY - fragment.yPos) / max(fragment.height, 1), 0), 1)
        return line.yPos + target.yPos + fraction * target.height
    }
}
