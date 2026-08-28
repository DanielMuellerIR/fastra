// ColumnCursorViewTests.swift
//
// Regressionstest für den Tester-Nachbefund vom 2026-08-28 (v1.113.0):
// Nach Tippen in eine Rechteckauswahl wurden zwar in ALLEN Zeilen Zeichen
// eingefügt (Modell korrekt, siehe ColumnTypingDriftTests), sichtbar blinkte
// danach aber nur in einem Teil der Zeilen ein Cursor — teils zusätzlich an
// der falschen x-Position (am linken Rand statt hinter dem eingefügten
// Zeichen).
//
// Geprüft wird die VIEW-Schicht: Nach dem Tippen und dem nächsten
// Layout-Durchlauf muss jede (leere) Selektion eine Cursor-View besitzen,
// deren Position mit der echten Textgeometrie übereinstimmt.

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
@testable import CodeEditTextView
import Testing
@testable import Fastra

@Test("Nach Tippen in eine Rechteckauswahl hat jede Zeile eine korrekt platzierte Cursor-View")
@MainActor
func columnTypingKeepsOneCursorViewPerLine() throws {
    // Die Zutatenliste aus dem Befund: 13 Zeilen, führender Leerraum gemischt
    // aus Tabs und Leerzeichen.
    let lines = [
        "\t500 g Pasta",
        "  500 g Haehnchenbrust",
        "    2 EL Olivenoel",
        "\t1 kleine Zwiebel",
        "  3 Knoblauchzehen",
        "    200 g Cherrytomaten",
        "\t100 g frischer Spinat",
        "  250 ml Kochsahne",
        "    100 ml Gemuesebruehe",
        "\t100 g Frischkaese",
        "  60 g Parmesan",
        "    1 TL italienische Kraeuter",
        "  Salz und Pfeffer",
    ]
    let configuration = SourceEditorConfiguration(
        appearance: .init(
            theme: EditorView.fastraTheme,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            wrapLines: true,
            tabWidth: 4
        )
    )
    let controller = TextViewController(
        string: lines.joined(separator: "\n"),
        language: .default,
        configuration: configuration,
        cursorPositions: []
    )
    controller.loadView()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    controller.view.frame = window.contentView?.bounds ?? .zero
    controller.view.layoutSubtreeIfNeeded()

    let textView = try #require(controller.textView)
    textView.layoutManager.layoutLines()
    textView.updateFrameIfNeeded()
    controller.view.layoutSubtreeIfNeeded()
    #expect(window.makeFirstResponder(textView))

    // Rechteck über den führenden Leerraum aller 13 Zeilen aufziehen —
    // wie im Befund per Auswahl der ersten Zeile plus Select Down.
    textView.selectionManager.setSelectedRanges([NSRange(location: 0, length: 1)])
    for _ in 1..<lines.count {
        #expect(textView.fastraSelectColumn(upwards: false))
    }
    #expect(textView.fastraColumnSelectionSnapshot?.ranges.count == lines.count)

    // Leertaste: ersetzt jeden Teilbereich durch ein Leerzeichen.
    textView.insertText(" ")

    // Der nächste reguläre Layout-Durchlauf (AppKit ruft layout() nach dem
    // Edit) positioniert die Cursor-Views.
    textView.layout()
    controller.view.layoutSubtreeIfNeeded()

    let selections = textView.selectionManager.textSelections
        .sorted { $0.range.location < $1.range.location }
    #expect(selections.count == lines.count,
            "erwartet \(lines.count) Cursor, ist \(selections.count)")

    for (index, selection) in selections.enumerated() {
        #expect(selection.range.isEmpty)
        let view = selection.view
        #expect(view != nil, "Zeile \(index + 1): keine Cursor-View")
        guard let view else { continue }
        #expect(view.superview === textView,
                "Zeile \(index + 1): Cursor-View hängt nicht in der TextView")
        let expected = try #require(
            textView.layoutManager.rectForOffset(selection.range.location),
            "Zeile \(index + 1): keine Geometrie für Offset \(selection.range.location)"
        )
        #expect(abs(view.frame.origin.x - expected.origin.x) <= 0.5
                    && abs(view.frame.origin.y - expected.origin.y) <= 0.5,
                "Zeile \(index + 1): Cursor-View bei \(view.frame.origin), Text erwartet \(expected.origin)")
    }
}
