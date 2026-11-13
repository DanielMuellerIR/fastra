import AppKit
import CodeEditTextViewObjC
import Testing

@Suite("Vollständige Quelltextattribute ohne Absatzkorrektur")
struct ImmediateAttributeStorageTests {
    private final class Storage: ImmediateAttributeTextStorage {
        var paragraphFixes = 0
        override func fixParagraphStyleAttribute(in range: NSRange) {
            paragraphFixes += 1
            super.fixParagraphStyleAttribute(in: range)
        }
    }

    private final class Edits: NSObject, NSTextStorageDelegate {
        var characterEdits = 0, attributeEdits = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            if editedMask.contains(.editedCharacters) { characterEdits += 1 }
            if editedMask.contains(.editedAttributes) { attributeEdits += 1 }
        }
    }

    @Test("Kleine Syntaxänderungen lösen keine dokumentweite Absatzsuche aus und melden weiter Edits")
    @MainActor func syntaxEditsPreserveControlledAttributesAndNotifications() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let source = "{\"blob\":\"" + String(repeating: "AB9+/q", count: 64 * 1024) + "\"}"
        let storage = Storage(string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let edits = Edits()
        storage.delegate = edits
        for index in 0..<32 {
            let range = NSRange(location: storage.length - 64 + index, length: 1)
            storage.setAttributes([.font: font, .foregroundColor: NSColor.systemGreen], range: range)
        }
        storage.replaceCharacters(in: NSRange(location: storage.length - 2, length: 0), with: "😀")
        #expect(storage.paragraphFixes == 0,
                "fixesAttributesLazily=false allein lässt AppKit bei jedem Farbwechsel sofort Absätze durchsuchen")
        #expect(edits.attributeEdits >= 32 && edits.characterEdits == 1)
        #expect(storage.string == String(source.dropLast(2)) + "😀\"}")
        #expect((storage.attribute(.font, at: storage.length / 2, effectiveRange: nil) as? NSFont) == font)
        #expect((storage.attribute(.foregroundColor, at: storage.length - 66, effectiveRange: nil) as? NSColor) == .systemGreen)
    }
}
