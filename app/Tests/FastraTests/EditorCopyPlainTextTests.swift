// EditorCopyPlainTextTests.swift
//
// Regressionstest für den build.sh-Patch 4o („Plain-Text-Copy"). Upstream legt
// beim Kopieren einen attributierten Text aufs Clipboard; oberster Flavor ist
// dann RTF. Programme mit Rich-Text-Vorrang übernehmen so nicht nur
// Editorschrift und -farbe — ihr Weg über RTF/HTML verliert außerdem den
// Emoji-Variantenselektor U+FE0F, aus ⏸️ wird ⏸ (Daniel-Befund 2026-07-27).
//
// Der Test prüft das reale Verhalten, nicht die Patch-Zeile: Was landet nach
// einem echten `copy(_:)` auf dem Pasteboard?

import AppKit
import Testing
import CodeEditTextView
@testable import Fastra

/// Kopiert über ein eigenes Pasteboard-Fenster: Das allgemeine Pasteboard
/// gehört dem Nutzer und wird gesichert und wiederhergestellt.
@MainActor
private func copyingToPasteboard(_ body: (NSPasteboard) -> Void) {
    let pasteboard = NSPasteboard.general
    let backup: [(NSPasteboard.PasteboardType, Data)] = (pasteboard.types ?? [])
        .compactMap { type in pasteboard.data(forType: type).map { (type, $0) } }
    defer {
        pasteboard.clearContents()
        if !backup.isEmpty {
            pasteboard.declareTypes(backup.map(\.0), owner: nil)
            for (type, data) in backup { pasteboard.setData(data, forType: type) }
        }
    }
    body(pasteboard)
}

@Test("Editor-Copy legt reinen Text ohne RTF aufs Clipboard")
@MainActor
func editorCopyWritesPlainText() {
    let textView = CodeEditTextView.TextView(string: "Pause ⏸️ Ende\n")
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    textView.layoutManager.layoutLines()
    textView.selectionManager.setSelectedRange(NSRange(location: 6, length: 2))

    copyingToPasteboard { pasteboard in
        textView.copy(textView)
        let types = pasteboard.types ?? []
        #expect(!types.contains(.rtf), "Ein Plaintext-Editor darf kein RTF anbieten")
        #expect(pasteboard.string(forType: .string) == "\u{23F8}\u{FE0F}")
    }
}

@Test("Mehrere Einfügemarken kommen zeilenweise verbunden an")
@MainActor
func editorCopyJoinsMultipleSelections() {
    let textView = CodeEditTextView.TextView(string: "alpha\nbeta\ngamma\n")
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    textView.layoutManager.layoutLines()
    textView.selectionManager.setSelectedRanges([
        NSRange(location: 0, length: 5),    // alpha
        NSRange(location: 11, length: 5)    // gamma
    ])

    copyingToPasteboard { pasteboard in
        textView.copy(textView)
        // Upstream schrieb hier zwei getrennte Pasteboard-Objekte; beim
        // Einfügen kam nur das erste an.
        #expect(pasteboard.string(forType: .string) == "alpha\ngamma")
    }
}

@Test("Copy ohne Auswahl lässt das Clipboard unangetastet")
@MainActor
func editorCopyKeepsClipboardWithoutSelection() {
    let textView = CodeEditTextView.TextView(string: "alpha\n")
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    textView.layoutManager.layoutLines()
    textView.selectionManager.setSelectedRange(NSRange(location: 2, length: 0))

    copyingToPasteboard { pasteboard in
        pasteboard.clearContents()
        pasteboard.setString("vorher", forType: .string)
        textView.copy(textView)
        #expect(pasteboard.string(forType: .string) == "vorher")
    }
}
