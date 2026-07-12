// RegexFieldView.swift
//
// Reiches, einzeiliges Texteingabe-Feld für Suchen- und Ersetzen-Pattern
// in der Suchmaske (FloatingSearchDialog). Ersetzt in Phase 3 (v0.7) die
// beiden schlichten SwiftUI-TextFields.
//
// Kern-Features:
//   - NSTextView-Basis (via NSViewRepresentable) — kein Zeilenumbruch,
//     horizontales Scrollen, Monospace-Font, Border ähnlich .roundedBorder
//   - Zwei-Wege-Binding: Tippen → Binding, Binding-Änderung → NSTextView
//   - Token-Highlighting: RegexTokenization von außen → pro Token-Range
//     farbige NSAttributedString-Attribute auf dem textStorage
//   - Caret-Einfügung von außen über RegexFieldController
//   - Return → onSubmit-Callback, Escape wird durchgereicht
//   - Placeholder-Text (eigene Subklasse — kein NSTextView-Nativ-Support)
//   - isEnabled: nicht editierbar + gedimmte Farbe
//   - accessibilityIdentifier für Selbsttests

import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// MARK: - RegexFieldController
// ---------------------------------------------------------------------------

/// Externer Steuer-Handle für ein `RegexFieldView`.
///
/// Der Dialog hält eine Instanz pro Feld (Find/Replace) und kann damit
/// von außen Text an der aktuellen Cursor-Position einfügen — z.B. beim
/// Klick auf einen Element-Picker-Knopf oder beim Droppen einer Capture-
/// Group-Pill.
///
/// Verwendung:
/// ```swift
/// let findController = RegexFieldController()
/// RegexFieldView(text: $pattern, controller: findController)
/// // ...
/// findController.insertAtCaret("\\d+")
/// ```
final class RegexFieldController {
    /// Schwache Referenz auf die interne NSTextView-Subklasse.
    /// Wird von `RegexFieldView.makeNSView` gesetzt, sobald die View
    /// gebaut wird, und beim Abbau (z.B. Fenster schließen) automatisch nil.
    weak var textView: RegexFieldTextView?

    /// Fügt `text` an der aktuellen Cursor-Position ein.
    ///
    /// Hat das Feld keinen Fokus (selectedRange ungültig oder kein
    /// firstResponder), wird der Text ans Ende angehängt.
    func insertAtCaret(_ text: String) {
        guard let tv = textView else { return }
        // Zwei Fälle:
        // - Feld HAT Fokus → an der aktuellen Selektion einfügen
        //   (NSRange(location: NSNotFound, …) = „aktuelle Selektion ersetzen").
        // - Feld hat KEINEN Fokus → ans ENDE anhängen. Ohne diese
        //   Unterscheidung würde der Text an der letzten (unsichtbaren)
        //   Cursor-Position landen — typisch Position 0, also VOR dem
        //   bestehenden Pattern. Genau das war der Bug-Kandidat beim
        //   Element-Picker-Klick ohne Feld-Fokus.
        let hasFocus = tv.window?.firstResponder === tv
        let insertRange = hasFocus
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: (tv.string as NSString).length, length: 0)
        // insertText(_:replacementRange:) berücksichtigt Undo-Manager und
        // Delegate-Callbacks — verhält sich wie eine echte Nutzereingabe.
        tv.insertText(text, replacementRange: insertRange)
        if !hasFocus {
            tv.scrollToEndOfDocument(nil)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - RegexFieldTextView (NSTextView-Subklasse)
// ---------------------------------------------------------------------------

/// Eigene NSTextView-Subklasse für das RegexFieldView.
///
/// Warum eine Subklasse?
/// 1. `-selftest fields` und zukünftige Selbsttests können sie per
///    Klassen-Check (`view is RegexFieldTextView`) zuverlässig im
///    NSView-Baum finden.
/// 2. Placeholder-Zeichnung via `draw(_:)` Override — NSTextView bietet
///    keinen nativ unterstützten Placeholder (anders als NSTextField).
/// 3. `insertNewline:`-Override für den Return→onSubmit-Callback.
final class RegexFieldTextView: NSTextView {

    // MARK: Feld-Farben (dynamisch hell/dunkel, v1.1 Dark Mode)
    //
    // Alle früher hartkodierten Feld-Farben an EINER Stelle, je mit heller
    // und dunkler Ausprägung (`Theme.dynamicNSColor` löst zur Zeichenzeit
    // über die effektive Appearance auf). Grundfarben sRGB (F.6b).

    /// Ink ↔ warmes Off-White — Standard-Textfarbe (== Theme.textPrimary).
    static let inkColor = Theme.dynamicNSColor(
        light: NSColor(srgbRed: 0x1A/255.0, green: 0x18/255.0, blue: 0x10/255.0, alpha: 1),
        dark:  NSColor(srgbRed: 0xEC/255.0, green: 0xE7/255.0, blue: 0xDB/255.0, alpha: 1))

    /// Gedimmte Ink-Variante für deaktivierte Felder (ca. 40 % Opazität).
    static let inkDimmedColor = Theme.dynamicNSColor(
        light: NSColor(srgbRed: 0x1A/255.0, green: 0x18/255.0, blue: 0x10/255.0, alpha: 0.38),
        dark:  NSColor(srgbRed: 0xEC/255.0, green: 0xE7/255.0, blue: 0xDB/255.0, alpha: 0.38))

    /// Feld-Hintergrund: Weiß ↔ erhöhte dunkle Fläche (== Theme.surfaceRaised,
    /// dieselbe Farbe wie die SwiftUI-RoundedRectangle dahinter — die
    /// rechteckige NSTextView-Füllung bleibt dadurch unsichtbar).
    static let fieldBackground = Theme.dynamicNSColor(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark:  NSColor(srgbRed: 0x1E/255.0, green: 0x20/255.0, blue: 0x26/255.0, alpha: 1))

    /// Platzhalter — gedimmt wie NSTextField-Placeholder (~40–55 % Opazität).
    static let placeholderColor = Theme.dynamicNSColor(
        light: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.36, alpha: 0.55),
        dark:  NSColor(srgbRed: 0.78, green: 0.76, blue: 0.71, alpha: 0.55))

    /// Fehler-Token-Hintergrund (rötlich, analog Theme.diffRemovedBG).
    static let errorBackground = Theme.dynamicNSColor(
        light: NSColor(srgbRed: 0xF7/255.0, green: 0xE4/255.0, blue: 0xE0/255.0, alpha: 0.7),
        dark:  NSColor(srgbRed: 0x46/255.0, green: 0x24/255.0, blue: 0x1F/255.0, alpha: 0.8))

    // MARK: Konfiguration (wird von makeNSView gesetzt)

    /// Platzhaltertext, wenn das Feld leer ist.
    var placeholder: String = ""

    /// Callback bei Return-Taste (statt Newline einzufügen).
    var onSubmit: (() -> Void)?

    // MARK: Placeholder zeichnen

    /// Zeichnet den Platzhaltertext, wenn das Feld leer ist.
    ///
    /// Implementierungsweg: `draw(_:)` override in der NSTextView-Subklasse.
    /// Alternativen wären ein SwiftUI-Overlay-Label oder eine proprietäre
    /// NSTextField-Lösung — `draw`-Override ist minimal und bleibt nah am
    /// nativen macOS-Aussehen (gleiche Font, Position, Farbe).
    ///
    /// Timing: draw läuft nach jeder Texteingabe automatisch (NSTextView
    /// markiert sich selbst als needsDisplay) — kein manuelles Triggern nötig.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Nur zeichnen, wenn kein Text vorhanden.
        // codereview-ok: Standard-Placeholder-Idiom — draw(_:) malt NUR den Placeholder bei leerem Feld, keine übersprungene Layout-/Höhenberechnung (Höhe nur lokal zum Positionieren) (2026-07-01)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        // Schriftart aus dem typingAttributes übernehmen, damit Placeholder
        // und eingetippter Text dieselbe Basis-Schrift haben.
        let font = typingAttributes[.font] as? NSFont
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Gedimmte Textfarbe — wie NSTextField-Placeholder, dynamisch
        // hell/dunkel (Grundfarben sRGB, LESSONS-LEARNED F.6b).
        let color = Self.placeholderColor

        // Textposition: EXAKT dort, wo auch der echte Text beginnt — also am
        // textContainerInset plus dem lineFragmentPadding des Containers
        // (nicht vertikal zentriert: das saß einen Tick tiefer als der
        // getippte Text, Daniel-Befund 2026-07-10).
        let inset = textContainerInset
        let x = inset.width + (textContainer?.lineFragmentPadding ?? 5)
        let y = inset.height

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        placeholder.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    // MARK: Return-Taste → onSubmit

    /// Fängt `insertNewline:` ab und leitet es an den onSubmit-Callback weiter.
    ///
    /// NSTextView delegiert Kommandos (Return, Tab, …) über
    /// `textView(_:doCommandBy:)` im Delegate an die View; es ist aber auch
    /// möglich, den Action-Selector direkt zu überschreiben. Wir nutzen den
    /// Delegate-Weg (`doCommandBy`) über den Coordinator — ABER als Fallback
    /// überschreiben wir hier zusätzlich `insertNewline:`, damit kein Newline
    /// je eingefügt wird, unabhängig davon ob ein Delegate gesetzt ist.
    ///
    /// Hinweis: Der tatsächliche Return-Callback läuft im Coordinator via
    /// `textView(_:doCommandBy:)` — diese Override ist nur ein Sicherheitsnetz
    /// gegen echte Newline-Einfügungen.
    override func insertNewline(_ sender: Any?) {
        onSubmit?()
        // NICHT super.insertNewline aufrufen — verhindert Zeilenumbruch.
    }

    // MARK: Drag & Drop von Capture-Group-Pillen (auch bei Fokus)

    /// Liefert den gedroppten Plain-String, sofern der Drag einen externen
    /// String mitbringt (Gruppen-Pillen liefern `$N` als NSString). `nil`,
    /// wenn der Drag aus diesem Feld selbst stammt (Text-Move innerhalb des
    /// Feldes → Standard-Verhalten) oder gar keinen String trägt.
    fileprivate func droppedPillString(from sender: NSDraggingInfo) -> String? {
        // Selbst-Drag (markierten Text im Feld verschieben) dem Standard
        // überlassen — wir mischen uns nur in EXTERNE String-Drops ein.
        if let src = sender.draggingSource as? NSView, src === self { return nil }
        guard let s = sender.draggingPasteboard.string(forType: .string),
              !s.isEmpty else { return nil }
        return s
    }

    /// Akzeptiert einen gedraggten String AUCH, wenn das Feld gerade den Fokus
    /// hat.
    ///
    /// Hintergrund (Daniel-Befund 2026-06-24): NSTextViews eingebaute Drag-
    /// Destination nimmt einen String-Drop nur an, wenn das Feld NICHT First
    /// Responder ist — bei fokussiertem Feld liefert `draggingEntered`
    /// `[]` zurück, der Drop verpufft („man muss erst ein anderes Feld
    /// anklicken"). Wir überschreiben die Destination-Methoden, damit ein
    /// externer String-Drop IMMER als Copy akzeptiert und an der Maus-Position
    /// eingefügt wird, unabhängig vom Fokus.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPillString(from: sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedPillString(from: sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedPillString(from: sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropped = droppedPillString(from: sender) else {
            return super.performDragOperation(sender)
        }
        // Einfügeposition aus der Maus-Position bestimmen (Fenster- →
        // View-Koordinaten → Zeichen-Index unter dem Cursor).
        let point = convert(sender.draggingLocation, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        let insertRange = NSRange(location: charIndex, length: 0)
        // Feld fokussieren, damit der eingefügte Text + Cursor sichtbar sind
        // (im unfokussierten Fall holt das den Cursor sichtbar ins Feld).
        window?.makeFirstResponder(self)
        // insertText(_:replacementRange:) ist Undo-fähig und triggert den
        // Delegate (textDidChange → Binding) wie eine echte Eingabe.
        insertText(dropped, replacementRange: insertRange)
        return true
    }
}

// ---------------------------------------------------------------------------
// MARK: - RegexFieldScrollView (vollflächiges Drop-Ziel)
// ---------------------------------------------------------------------------

/// Erweitert das Drop-Ziel auf die komplette sichtbare Feldhöhe.
///
/// Die innere `NSTextView` endet durch AppKits Clip-View-Geometrie manchmal
/// knapp oberhalb des unteren Feldrands. Der äußere ScrollView nimmt dort den
/// gleichen Pillen-Drop an und übergibt die eigentliche Einfügung wieder an
/// die TextView. Cursor-Berechnung und Undo-Verhalten bleiben dadurch zentral.
final class RegexFieldScrollView: NSScrollView {
    private var fieldTextView: RegexFieldTextView? {
        documentView as? RegexFieldTextView
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fieldTextView?.droppedPillString(from: sender) != nil
            ? .copy
            : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fieldTextView?.droppedPillString(from: sender) != nil
            ? .copy
            : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fieldTextView?.droppedPillString(from: sender) != nil
            ? true
            : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let fieldTextView,
              fieldTextView.droppedPillString(from: sender) != nil else {
            return super.performDragOperation(sender)
        }
        return fieldTextView.performDragOperation(sender)
    }
}

// ---------------------------------------------------------------------------
// MARK: - RegexFieldView (NSViewRepresentable)
// ---------------------------------------------------------------------------

/// Einzeiliges, reiches Texteingabe-Feld für RegEx-Pattern-Eingabe.
///
/// Verwendet NSTextView statt SwiftUI-TextField, um:
///   - Token-Highlighting direkt auf dem NSTextStorage anzuwenden
///     (NSAttributedString-Attribute, kein Text-Rebuild, kein Cursor-Sprung)
///   - Horizontales Scrollen bei langen Mustern zu ermöglichen
///   - Caret-Einfügung von außen (Element-Picker, Drag & Drop von Pills)
///
/// Einbindung im Dialog:
/// ```swift
/// @StateObject var findController = RegexFieldController()
/// RegexFieldView(
///     text: $workspace.findPattern,
///     tokenization: tokenization,   // nil = RegEx-Modus aus
///     placeholder: "Suchausdruck…",
///     controller: findController,
///     onSubmit: { workspace.findNext() },
///     accessibilityID: "findField"
/// )
/// ```
struct RegexFieldView: NSViewRepresentable {

    @Environment(\.uiScale) private var uiScale

    // MARK: Parameter

    /// Bidirektionales Binding zum Pattern-String.
    @Binding var text: String

    /// Token-Ergebnis vom Tokenizer (von außen debounced berechnet).
    /// `nil` = RegEx-Modus deaktiviert → kein Highlighting.
    var tokenization: RegexTokenization? = nil

    /// Platzhaltertext bei leerem Feld.
    var placeholder: String = ""

    /// `false` = nicht editierbar + gedimmte Schriftfarbe.
    var isEnabled: Bool = true

    /// Externer Controller für `insertAtCaret` (Element-Picker, Pills).
    var controller: RegexFieldController? = nil

    /// Callback bei Return-Taste (statt Zeilenumbruch).
    var onSubmit: (() -> Void)? = nil

    /// Accessibility-Identifier — damit `-selftest fields` und Tests
    /// das Feld per `accessibilityIdentifier` finden können.
    var accessibilityID: String = ""

    // MARK: NSViewRepresentable

    typealias NSViewType = NSScrollView

    /// Baut die NSView-Hierarchie: NSScrollView → NSTextView.
    ///
    /// Struktur: NSScrollView als Wurzel (regelt horizontales Scrollen),
    /// darin eine `RegexFieldTextView` als documentView.
    /// NSScrollView ist die äußere View, die SwiftUI einbettet — so
    /// bekommt SwiftUI eine feste Größe und der Scroll-Content kann
    /// länger sein.
    func makeNSView(context: Context) -> NSScrollView {
        // ---- NSScrollView-Konfiguration ----
        // Auch der äußere ScrollView ist ein Drop-Ziel. So reagiert nicht nur
        // die Textzeile selbst, sondern jeder sichtbare Pixel des Feldes.
        let scrollView = RegexFieldScrollView()
        scrollView.registerForDraggedTypes([.string])
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false  // kein sichtbarer Scroller
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false        // Hintergrund via SwiftUI

        // ---- RegexFieldTextView-Konfiguration ----
        let textView = RegexFieldTextView()

        // Kein Zeilenumbruch: Container-Breite unbegrenzt, kein Word-Wrap.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false    // feste Höhe
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: 1_000_000
        )
        textView.minSize = CGSize(width: 0, height: 0)

        // Autoresize: Breite folgt dem ScrollView-Clip; Höhe fix.
        textView.autoresizingMask = [.width]

        // Font: Monospaced, wie Theme.monoSmall (11 pt) — passt zur Maske.
        textView.font = .fastraMonospaced(size: 11, scale: uiScale)

        // Text und Hintergrund — dynamisch hell/dunkel (Dark Mode v1.1);
        // Insertion-Point mitziehen, sonst bliebe er im Dunkeln schwarz.
        textView.textColor = RegexFieldTextView.inkColor
        textView.insertionPointColor = RegexFieldTextView.inkColor
        textView.backgroundColor = RegexFieldTextView.fieldBackground
        textView.drawsBackground = true

        // Kein Zeilenumbruch als Trennzeichen — Return geht an onSubmit.
        textView.usesFindPanel = false
        textView.usesFindBar = false
        textView.isRichText = false               // nur Plain Text, keine RTF-Paste
        textView.allowsUndo = true
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Einzug: TextContainerInset für optisches Padding (wie .roundedBorder).
        textView.textContainerInset = NSSize(width: 6 * uiScale, height: 4 * uiScale)

        // Delegate: der Coordinator übernimmt textDidChange + doCommandBy.
        textView.delegate = context.coordinator

        // Accessibility-Identifier setzen, damit Selbsttests das Feld finden.
        if !accessibilityID.isEmpty {
            textView.setAccessibilityIdentifier(accessibilityID)
        }

        // Initialen Text laden.
        textView.string = text

        // Placeholder und onSubmit in die Subklasse übergeben.
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit

        // Controller mit dieser TextView verknüpfen.
        controller?.textView = textView

        // Drag & Drop: NSTextView akzeptiert NSString-Drags nativ.
        // `.registerForDraggedTypes([.string])` ist bereits in
        // NSTextView vordefiniert und wird bei isEditable=true automatisch
        // aktiv. Ein gedraggter String ("$1") wird an der Maus-Position
        // eingefügt — exakt das gewünschte Verhalten für Capture-Group-Pills.
        // KEIN eigener NSDraggingDestination nötig.
        // Wichtig: isEditable/isSelectable NICHT vor registerForDraggedTypes
        // setzen, da NSTextView intern beim Setzen von isEditable=true die
        // Drag-Types registriert. Deshalb isEditable hier als letztes.
        textView.isEditable = isEnabled
        textView.isSelectable = true

        // NSScrollView zusammensetzen.
        scrollView.documentView = textView

        // Fokus-Ring: AppKit-Standard-Focus-Ring via NSScrollView-Subklasse
        // ist nicht trivial einzubauen. Wir emulieren ihn mit einem
        // SwiftUI-Overlay in `body` — aber da wir hier ein reines
        // NSViewRepresentable sind (kein umhüllender View-Body), bleibt das
        // dem integrierenden Dialog überlassen. Der ScrollView selbst
        // bekommt keinen eigenen Fokus-Ring; die NSTextView zeigt den
        // Standard-Cursor-Strich aber korrekt.
        //
        // Für einen Border ähnlich `.roundedBorder` wird die aufrufende Stelle
        // in FloatingSearchDialog einen RoundedRectangle-Stroke-Overlay
        // verwenden (wie bei FindFieldView bereits der Fall).

        return scrollView
    }

    /// Synchronisiert Änderungen von SwiftUI in die NSView.
    ///
    /// Läuft bei jeder SwiftUI-Render-Runde. Wichtige Regeln:
    /// 1. Text nur aktualisieren, wenn er sich WIRKLICH geändert hat —
    ///    sonst springt der Cursor bei jedem Tastendruck an den Anfang.
    /// 2. Nach dem Text-Update die Attribute neu anwenden (Tokenisierung
    ///    kann sich geändert haben, z.B. debounced vom Dialog).
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? RegexFieldTextView else {
            return
        }

        // Coordinator-Referenz aktuell halten (Swift-Closures und Callbacks
        // brauchen den aktuellen Coordinator, nicht den aus makeNSView).
        context.coordinator.parent = self
        textView.delegate = context.coordinator

        // Environment-Änderungen erreichen NSViewRepresentable über diesen
        // Update-Pfad. So skaliert ein bereits fokussiertes Feld live, ohne
        // Text, Auswahl oder Undo-Historie neu aufzubauen.
        let scaledFont = NSFont.fastraMonospaced(size: 11, scale: uiScale)
        if textView.font?.pointSize != scaledFont.pointSize {
            textView.font = scaledFont
            textView.typingAttributes[.font] = scaledFont
            textView.textContainerInset = NSSize(width: 6 * uiScale, height: 4 * uiScale)
        }

        // Placeholder und onSubmit aktualisieren (können sich ändern).
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit

        // isEnabled → isEditable + Textfarbe dimmen.
        // Nur setzen wenn geändert — NSTextView hat sonst einen Layout-Pass.
        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }
        // Aktiv: Ink/Off-White; deaktiviert: gedimmt (beide dynamisch).
        textView.textColor = isEnabled
            ? RegexFieldTextView.inkColor
            : RegexFieldTextView.inkDimmedColor

        // Controller-Referenz aktuell halten.
        controller?.textView = textView

        // Text nur setzen, wenn verschieden. `.string` ist ein Plain-Text-
        // Snapshot; `==`-Vergleich ist O(n) aber zuverlässig.
        if textView.string != text {
            // Cursor-Position für spätere Wiederherstellung merken —
            // NSTextView setzt `selectedRange` beim Überschreiben des
            // Contents leider auf (0,0) zurück.
            let savedRange = textView.selectedRange()

            // `string` direkt setzen löscht alle Attribute. Deshalb
            // danach sofort applyHighlighting aufrufen.
            textView.string = text

            // Cursor-Position wiederherstellen, falls noch im gültigen Bereich.
            let newLen = (text as NSString).length
            if savedRange.location <= newLen {
                let safeRange = NSRange(
                    location: min(savedRange.location, newLen),
                    length: min(savedRange.length, max(0, newLen - savedRange.location))
                )
                textView.setSelectedRange(safeRange)
            }
        }

        // Highlighting immer aktualisieren, unabhängig davon ob sich der
        // Text geändert hat — die tokenization kann sich geändert haben
        // (debounced-Ergebnis vom Dialog).
        applyHighlighting(to: textView)

        // Placeholder-Neuzeichnung anstoßen (leeres Feld: Placeholder zeigen).
        textView.needsDisplay = true
    }

    // MARK: Coordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Coordinator: NSTextViewDelegate + Brücke Swift → SwiftUI-Binding.
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Referenz auf die umgebende SwiftUI-View (wird in updateNSView aktuell gehalten).
        var parent: RegexFieldView

        init(parent: RegexFieldView) {
            self.parent = parent
        }

        // MARK: NSTextViewDelegate

        /// Tippen → Binding aktualisieren + Highlighting neu anwenden.
        ///
        /// textDidChange wird nach JEDER Änderung des NSTextStorage gerufen
        /// (Tippen, Einfügen, Löschen). Wir schieben den neuen String ins
        /// Binding; der Dialog kann daraufhin (debounced) den Tokenizer starten.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RegexFieldTextView else { return }
            let newText = textView.string
            // Verhindert Feedback-Schleife: Binding nur setzen, wenn wirklich
            // anders (updateNSView würde sonst sofort zurückschreiben).
            if parent.text != newText {
                parent.text = newText
            }
            // Highlighting nach Tippen sofort neu anwenden — vor dem nächsten
            // SwiftUI-Render-Zyklus, damit kein „Flash" ohne Farbe auftritt.
            parent.applyHighlighting(to: textView)
            // Placeholder-Neuzeichnung (leeres Feld zeigt Placeholder).
            textView.needsDisplay = true
        }

        /// Fängt Return-Tastendruck ab → onSubmit, verhindert Newline.
        ///
        /// NSTextView ruft `textView(_:doCommandBy:)` für Sonder-Selektoren
        /// wie `insertNewline:`, `cancelOperation:` (Escape), `insertTab:` …
        /// Return `true` heißt: „ich habe das Kommando behandelt, nichts
        /// weiteres tun". Return `false` heißt: „standard-Verhalten bitte".
        func textView(_ textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSStandardKeyBindingResponding.insertNewline(_:)) {
                // Return → onSubmit-Callback, KEIN Zeilenumbruch.
                parent.onSubmit?()
                return true
            }
            // Escape (cancelOperation:) NICHT abfangen — geht an die App-
            // Logik (AppDelegate-Monitor → Suchmaske ausblenden).
            return false
        }
    }

    // MARK: - Token-Highlighting

    /// Wendet Token-Farben auf das NSTextStorage der übergebenen TextView an.
    ///
    /// Drei Regeln für korrekte Attribut-Anwendung ohne Cursor-Sprung:
    /// 1. NSTextStorage.beginEditing / endEditing klammern: Verhindert, dass
    ///    NSLayoutManager bei jedem einzelnen setAttribute neu zeichnet —
    ///    Rendering erst nach endEditing, ein atomarer Pass.
    /// 2. Attribute setzen statt `string` ersetzen: Der String bleibt identisch;
    ///    nur visuelle Eigenschaften ändern sich. NSTextView verändert deshalb
    ///    `selectedRange` NICHT.
    /// 3. Zuerst Basis-Farbe auf den ganzen String, dann Token-Farben obendrauf:
    ///    so bleiben Lücken zwischen Tokens korrekt eingefärbt.
    ///
    /// Fallback (tokenization == nil): kompletter Text in Standard-Ink-Farbe.
    private func applyHighlighting(to textView: RegexFieldTextView) {
        guard let storage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        // Standard-Textfarbe (isEnabled bestimmt Opazität), dynamisch.
        let baseColor: NSColor = isEnabled
            ? RegexFieldTextView.inkColor
            : RegexFieldTextView.inkDimmedColor

        storage.beginEditing()

        // Schritt 1: Basis-Farbe + Hintergrund-Reset auf den ganzen Text.
        storage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
        storage.removeAttribute(.backgroundColor, range: fullRange)

        // Schritt 2: Token-Farben (nur wenn Tokenisierung vorhanden).
        if let tok = tokenization {
            for token in tok.tokens {
                // Sicherheitsprüfung: Range muss im String liegen.
                guard token.range.location != NSNotFound,
                      token.range.location + token.range.length <= fullRange.length
                else { continue }

                let fg = Self.color(for: token.kind)
                storage.addAttribute(.foregroundColor, value: fg, range: token.range)

                // Fehler-Token: zusätzlich rötlicher Hintergrund (dynamisch).
                if token.kind == .error {
                    storage.addAttribute(.backgroundColor,
                                         value: RegexFieldTextView.errorBackground,
                                         range: token.range)
                }
            }
        }

        storage.endEditing()
    }

    // MARK: - Farbzuordnung

    /// Gibt die Vordergrundfarbe für eine Token-Kategorie zurück.
    ///
    /// Farben analog zu Theme.swift und dem Konzept-Dokument:
    ///   - anchor:          Rötlich (= Theme.tokenAnchor, wie diffRemovedFG)
    ///   - characterClass:  Bläulich (= Theme.tokenCharClass)
    ///   - quantifier:      Ocker/Braun (= Theme.tokenQuant)
    ///   - groupDelimiter:  Kräftiges Violett
    ///   - alternation:     Dunkles Blau (kräftig, auffällig)
    ///   - escape:          Dunkelgrün (wie diffAddedFG)
    ///   - backreference:   Violett (wie groupColors[2])
    ///   - literal:         Standard-Ink (kein visueller Akzent)
    ///   - error:           Leuchtendes Rot
    ///
    /// Seit v1.1 DYNAMISCH (hell/dunkel): jede Kategorie hat eine helle und
    /// eine aufgehellte dunkle Ausprägung (`Theme.dynamicNSColor`) — die
    /// NSAttributedString-Färbung löst sich beim Zeichnen über die effektive
    /// Appearance auf, das Feld bleibt im Dark Mode lesbar.
    /// ALLE Grundfarben via sRGB — kein Gray-Colorspace (LESSONS-LEARNED F.6b).
    static func color(for kind: RegexTokenKind) -> NSColor {
        /// Kurzhelfer: sRGB-Paar hell/dunkel → dynamische NSColor.
        func pair(_ lr: Int, _ lg: Int, _ lb: Int,
                  _ dr: Int, _ dg: Int, _ db: Int) -> NSColor {
            Theme.dynamicNSColor(
                light: NSColor(srgbRed: CGFloat(lr)/255.0, green: CGFloat(lg)/255.0,
                               blue: CGFloat(lb)/255.0, alpha: 1),
                dark:  NSColor(srgbRed: CGFloat(dr)/255.0, green: CGFloat(dg)/255.0,
                               blue: CGFloat(db)/255.0, alpha: 1))
        }

        switch kind {
        case .anchor:
            // Rötlich — Position im String, kein Zeichen.
            // Hell = Theme.tokenAnchor (diffRemovedFG), dunkel dessen Pendant.
            return pair(0xA3, 0x39, 0x2A, 0xE8, 0x8D, 0x7C)

        case .characterClass:
            // Bläulich — „welche Zeichen?". Hell = Theme.tokenCharClass.
            return pair(0x2A, 0x66, 0xB5, 0x7F, 0xB0, 0xEE)

        case .quantifier:
            // Ocker/Braun — „wie oft?". Hell = Theme.tokenQuant.
            return pair(0xB5, 0x6C, 0x1A, 0xDF, 0xA2, 0x5A)

        case .groupDelimiter:
            // Kräftiges Violett — Klammern fallen optisch stark auf.
            return pair(0x70, 0x20, 0xA0, 0xC0, 0x8A, 0xE8)

        case .alternation:
            // Blau — das `|` als strukturelles Element hervorheben
            // (hell: dunkles Blau, dunkel: aufgehelltes Stahlblau).
            return pair(0x1A, 0x40, 0x80, 0x86, 0xA9, 0xE0)

        case .escape:
            // Grün — analog Theme.diffAddedFG.
            return pair(0x2F, 0x5D, 0x3A, 0x94, 0xCE, 0x9F)

        case .backreference:
            // Violett — analog Theme.groupColors[2] (0.65/0.40/0.85).
            return pair(0xA4, 0x66, 0xD9, 0xC0, 0x9A, 0xE8)

        case .literal:
            // Standard-Ink ↔ warmes Off-White — Basis-Lesbarkeit, kein Akzent.
            return pair(0x1A, 0x18, 0x10, 0xEC, 0xE7, 0xDB)

        case .error:
            // Leuchtendes Rot — deutlich als fehlerhafte Stelle markieren.
            return pair(0xCC, 0x00, 0x00, 0xFF, 0x6B, 0x5E)
        }
    }
}
