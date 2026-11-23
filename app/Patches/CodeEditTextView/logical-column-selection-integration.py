import sys

copy_paste, delete, replace_characters, select, appearance, behavior = sys.argv[1:]

def replace_once(path, marker, old, new):
    src = open(path).read()
    if marker in src:
        return
    if old not in src:
        raise SystemExit(
            f"{path}: Quelltext hat sich geaendert — Patch 4o pruefen"
        )
    open(path, "w").write(src.replace(old, new, 1))

replace_once(
    copy_paste,
    "Fastra-Patch: Rechteck-Copy",
    '''    @objc open func copy(_ sender: AnyObject) {
        guard let textSelections = selectionManager?''',
    '''    @objc open func copy(_ sender: AnyObject) {
        // Fastra-Patch: Rechteck-Copy schreibt einen zeilenweisen Textwert.
        if fastraCopyColumnSelection() {
            return
        }
        guard let textSelections = selectionManager?'''
)
replace_once(
    copy_paste,
    "Fastra-Patch: Plain-Text-Copy",
    '''        guard let textSelections = selectionManager?
            .textSelections
            .compactMap({ textStorage.attributedSubstring(from: $0.range) }),
              !textSelections.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textSelections)''',
    '''        // Fastra-Patch: Plain-Text-Copy. Upstream legt attributierten Text
        // aufs Clipboard, wodurch RTF der oberste Flavor ist. Zielprogramme
        // mit Rich-Text-Vorrang uebernehmen dann Editorschrift und -farbe;
        // ihr RTF-nach-HTML-Umweg verliert ausserdem Emoji-
        // Variantenselektoren (U+FE0F). Ein Plaintext-Editor kopiert deshalb
        // reinen Text. Mehrere Cursor werden zeilenweise verbunden — als
        // getrennte Pasteboard-Objekte kam beim Einfuegen nur der erste
        // Bereich an.
        guard let ranges = selectionManager?.textSelections.map(\\.range),
              !ranges.isEmpty else {
            return
        }
        let document = NSRange(location: 0, length: textStorage.length)
        // Eine veraltete Selektion (Mutation vor dem Kopieren) darf keinen
        // Bereichsfehler werfen; geklemmt wird nur der Lesebereich.
        let values = ranges.compactMap { range -> String? in
            let safe = range.intersection(document) ?? NSRange(location: 0, length: 0)
            guard safe.length > 0 else { return nil }
            return textStorage.mutableString.substring(with: safe)
        }
        guard !values.isEmpty else { return }
        let separator = layoutManager.detectedLineEnding.rawValue
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(
            [values.joined(separator: separator) as NSString]
        )''',
)
replace_once(
    copy_paste,
    "Fastra-Patch: Rechteck-Paste",
    '''    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }''',
    '''    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        // Fastra-Patch: Rechteck-Paste verteilt Zeilen auf logische Zeilen.
        if fastraPasteIntoColumnSelection(stringContents) {
            return
        }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }'''
)
replace_once(
    select,
    "Fastra-Patch: Doppelklick auf Symbole",
    '''    internal func findWordBoundary(at position: Int) -> NSRange {
        guard position >= 0 && position < textStorage.length,''',
    '''    internal func findWordBoundary(at position: Int) -> NSRange {
        // Fastra-Patch: Doppelklick auf Symbole und Emojis markiert den ganzen
        // Graphem-Cluster. Upstream kennt nur Bezeichner, Leerraum,
        // Zeilenenden und Satzzeichen; ein Emoji markierte deshalb gar nichts.
        // Mehrteilige Cluster gewinnen sofort:
        // Ein Klick auf den Variantenselektor U+FE0F landete sonst in der
        // Wortlogik, weil Foundation ihn zu den alphanumerischen Zeichen
        // zaehlt, und markierte nur ihn allein.
        let fastraCluster = fastraGraphemeClusterRange(at: position)
        if fastraCluster.length > 1 {
            return fastraCluster
        }
        guard position >= 0 && position < textStorage.length,''',
)
replace_once(
    select,
    "Fastra-Patch: einzelnes Symbol",
    '''        } else {
            return NSRange(location: position, length: 0)
        }''',
    '''        } else {
            // Fastra-Patch: einzelnes Symbol (Pfeil, nacktes ⏸ ohne
            // Variantenselektor) markiert sich selbst statt nichts.
            return fastraCluster
        }''',
)
replace_once(
    delete,
    "Fastra-Patch: Rechteck-Delete",
    '''    private func delete(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        decomposeCharacters: Bool = false
    ) {
        /// Extend each selection''',
    '''    private func delete(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        decomposeCharacters: Bool = false
    ) {
        // Fastra-Patch: Rechteck-Delete darf leere Bereiche kurzer Zeilen
        // nicht auf das benachbarte Zeichen ausweiten.
        if fastraDeleteColumnSelection() {
            return
        }
        /// Extend each selection'''
)
replace_once(
    replace_characters,
    "Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche",
    '''    ) {
        guard isEditable else { return }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)''',
    '''    ) {
        guard isEditable else { return }
        // Fastra-Patch: eine Undo-Gruppe fuer Mehrfachbereiche. Das betrifft
        // insbesondere Tippen, Delete und Cut auf einer Rechteckauswahl.
        let startsFastraUndoGrouping =
            ranges.count > 1 && !(_undoManager?.isGrouping ?? false)
        if startsFastraUndoGrouping {
            _undoManager?.beginUndoGrouping()
        }
        defer {
            if startsFastraUndoGrouping {
                _undoManager?.endUndoGrouping()
            }
        }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)'''
)
replace_once(
    replace_characters,
    "Fastra-Patch: kein Scrollen waehrend gebuendeltem Undo/Redo",
    '''        if let selection = selectionManager.textSelections.first, !visibleRect.contains(selection.boundingRect) {
            scrollSelectionToVisible()
        }''',
    '''        // Fastra-Patch: kein Scrollen waehrend gebuendeltem Undo/Redo. Der
        // aeussere Undo-Manager scrollt erst nach textStorage.endEditing();
        // hier wuerde ein Bounds-Callback Layout gegen den Zwischenstand
        // ausloesen (Crash im 2.000-Runden-Dauertest).
        if !skipUpdateSelection,
           let selection = selectionManager.textSelections.first,
           !visibleRect.contains(selection.boundingRect) {
            scrollSelectionToVisible()
        }'''
)
replace_once(
    appearance,
    "fastraColumnSelectionTabWidth = tabWidth",
    '''            if oldConfig?.tabWidth != tabWidth {
                controller.paragraphStyle = controller.generateParagraphStyle()''',
    '''            if oldConfig?.tabWidth != tabWidth {
                controller.textView.fastraColumnSelectionTabWidth = tabWidth
                controller.paragraphStyle = controller.generateParagraphStyle()'''
)
replace_once(
    behavior,
    "fastraColumnIndentationUnit",
    '''            if oldConfig?.indentOption != indentOption {
                controller.setUpTextFormation()''',
    '''            if oldConfig?.indentOption != indentOption {
                controller.textView.fastraColumnIndentationUnit =
                    indentOption.stringValue
                controller.setUpTextFormation()'''
)
