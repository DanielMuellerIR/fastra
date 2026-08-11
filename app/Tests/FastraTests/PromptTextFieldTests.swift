import AppKit
import Testing
@testable import Fastra

@Test("Umbenennen befüllt den alten Namen und wählt ihn vollständig aus")
@MainActor
func renamePromptPrefillsAndSelectsExistingName() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    let field = Workspace.promptTextField(
        placeholder: "Vorher.md", initialValue: "Vorher.md"
    )
    window.contentView = field

    let selection = Workspace.focusAndSelectPromptText(field)

    #expect(field.stringValue == "Vorher.md")
    #expect(selection == NSRange(location: 0, length: 9))
}
