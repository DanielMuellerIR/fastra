import AppKit
import CodeEditTextView
import Testing
@testable import Fastra

@Test("Command-Shift-Pfeil erweitert die Auswahl bis zur sichtbaren Zeilengrenze", arguments: [123, 124])
@MainActor
func commandShiftArrowSelectsLineBoundary(keyCode: Int) throws {
    let source = "Vorher\nα Text 😀 Ende\nDanach\n"
    let line = (source as NSString).range(of: "α Text 😀 Ende")
    let cursor = (source as NSString).range(of: "😀").location
    let textView = TextView(string: source)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
    let window = NSWindow(contentRect: textView.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = textView
    defer { window.close() }
    textView.layoutManager.layoutLines()
    #expect(window.makeFirstResponder(textView))
    textView.selectionManager.setSelectedRange(NSRange(location: cursor, length: 0))
    let characters = keyCode == 123 ? "\u{F702}" : "\u{F703}"
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)))
    textView.keyDown(with: event)
    let expected = keyCode == 123 ? NSRange(location: line.location, length: cursor - line.location)
        : NSRange(location: cursor, length: NSMaxRange(line) - cursor)
    #expect(textView.selectionManager.textSelections.first?.range == expected)
    #expect(textView.string == source)
}
