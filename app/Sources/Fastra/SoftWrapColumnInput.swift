import AppKit

/// Kleine native Zahleneingabe für feste Umbruch- und Seitenlinienspalten.
///
/// Die Validierung bleibt absichtlich außerhalb der SwiftUI-Menüs testbar.
/// Ungültige Werte werden nicht still geklemmt, sondern im Dialog erklärt.
enum SoftWrapColumnInput {
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed),
              SoftWrapProfileStore.validColumnRange.contains(value) else {
            return nil
        }
        return value
    }

    @MainActor
    static func prompt(title: String, currentValue: Int) -> Int? {
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = L10n.format(
                "Gib eine Spalte zwischen %ld und %ld ein.",
                SoftWrapProfileStore.validColumnRange.lowerBound,
                SoftWrapProfileStore.validColumnRange.upperBound
            )
            alert.addButton(withTitle: L10n.string("Übernehmen"))
            alert.addButton(withTitle: L10n.string("Abbrechen"))

            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(
                value: SoftWrapProfileStore.validColumnRange.lowerBound
            )
            formatter.maximum = NSNumber(
                value: SoftWrapProfileStore.validColumnRange.upperBound
            )

            let field = NSTextField(
                frame: NSRect(x: 0, y: 0, width: 180, height: 24)
            )
            field.formatter = formatter
            field.integerValue = currentValue
            field.alignment = .right
            field.setAccessibilityLabel(L10n.string("Textspalte"))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            if let value = parse(field.stringValue) {
                return value
            }

            let error = NSAlert()
            error.alertStyle = .warning
            error.messageText = L10n.string("Ungültige Spalte")
            error.informativeText = L10n.format(
                "Die Spalte muss als ganze Zahl zwischen %ld und %ld angegeben werden.",
                SoftWrapProfileStore.validColumnRange.lowerBound,
                SoftWrapProfileStore.validColumnRange.upperBound
            )
            error.runModal()
        }
    }
}
