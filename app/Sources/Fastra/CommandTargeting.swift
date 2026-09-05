// CommandTargeting.swift
//
// EINZIGE Quelle für die Frage: „Welches Fenster meint ein globaler Befehl?"
//
// Warum es diese Datei gibt (Fehlerbericht aus dem Arbeitsbetrieb, 2026-08-07):
// Bei zwei offenen Dokumentfenstern formatierte ⌘B im HINTERGRUNDFENSTER, an
// einer Stelle, die der Nutzer nie angeklickt hatte. Die Ursache war eine
// Zeile, die harmlos aussieht:
//
//     for window in NSApp.windows where window.isVisible { … }   // FALSCH
//
// `NSApp.windows` ist eine ungeordnete Menge ALLER Fenster der Anwendung —
// nicht nach Vordergrund sortiert. Wer daraus „das erste sichtbare" nimmt,
// erwischt bei mehreren Fenstern ein zufälliges. Richtig ist
// `NSApp.orderedWindows`: von vorne nach hinten sortiert.
//
// Die zweite Falle war `Workspace.shared`. Der Wert wird bei jedem
// Fokuswechsel gesetzt, aber auch in `Workspace.init` — die
// Sitzungswiederherstellung erzeugt mehrere Workspaces nacheinander, und
// danach zeigt `shared` auf den ZULETZT erzeugten statt auf den vordersten.
// Ein Befehl, der sein Ziel aus `Workspace.shared` bestimmt, greift deshalb
// nach einem Neustart mit mehreren Fenstern ins Leere oder ins falsche
// Dokument.
//
// Deshalb: Befehle fragen ausschließlich hier nach ihrem Ziel. `app/
// window-targeting-audit.sh` hält die Regel maschinell durch und lässt
// `NSApp.windows` im Produktcode nur noch in dieser Datei zu.

import AppKit
import CodeEditTextView

/// Pure Auswahllogik — ohne AppKit prüfbar.
///
/// Bewusst von der AppKit-Schicht getrennt: Die eigentliche Entscheidung ist
/// eine Handvoll Regeln, die sich als Unit-Test festnageln lassen. Ein
/// Fenstertest kann eine Regressionsstelle zeigen, aber nicht alle
/// Kombinationen durchspielen.
enum WindowTargeting {
    /// Ein Fenster, so weit es für die Zielwahl zählt.
    struct Candidate: Equatable {
        /// Echtes Dokumentfenster? Such-, Hilfe- und Panel-Fenster nicht.
        let isDocumentWindow: Bool
        /// Hat dieses Fenster gerade die Tastatur?
        let isKey: Bool
        /// Darf dieses Hilfsfenster Befehle an das Dokument dahinter geben?
        /// Das gilt bewusst nur für Fastras Suchmaske. Ein unbekanntes oder
        /// noch nicht registriertes Vorderfenster darf niemals bewirken, dass
        /// ein Dokumentfenster im Hintergrund getroffen wird.
        let allowsDocumentFallback: Bool
        /// Ein Vergleich ohne Editor sperrt auch ohne aktives Key-Window
        /// den Rückfall auf ein dahinter liegendes Dokument.
        let blocksInactiveDocumentFallback: Bool

        init(isDocumentWindow: Bool, isKey: Bool,
             allowsDocumentFallback: Bool = false,
             blocksInactiveDocumentFallback: Bool = false) {
            self.isDocumentWindow = isDocumentWindow
            self.isKey = isKey
            self.allowsDocumentFallback = allowsDocumentFallback
            self.blocksInactiveDocumentFallback = blocksInactiveDocumentFallback
        }
    }

    /// Index des Fensters, das ein globaler Befehl treffen muss.
    ///
    /// `candidates` kommt in AppKits Vordergrund-Reihenfolge (vorne zuerst).
    ///
    /// Die Regeln, in dieser Reihenfolge:
    /// 1. Bedient der Nutzer gerade ein Dokumentfenster, gilt dieses.
    /// 2. Hält die BEKANNTE Suchmaske die Tastatur, gilt das vorderste
    ///    Dokumentfenster dahinter.
    /// 3. Hält ein anderes Fenster die Tastatur, gibt es kein Dokumentziel.
    ///    Besonders ⌘W darf dann niemals ein Fenster dahinter schließen.
    /// 4. Ohne Key-Window gilt das vorderste Dokumentfenster.
    static func targetIndex(in candidates: [Candidate]) -> Int? {
        if let keyed = candidates.firstIndex(where: \.isKey) {
            if candidates[keyed].isDocumentWindow { return keyed }
            guard candidates[keyed].allowsDocumentFallback else { return nil }
        } else if candidates.first?.blocksInactiveDocumentFallback == true {
            return nil
        }
        return candidates.firstIndex(where: { $0.isDocumentWindow })
    }
}

/// AppKit-Schicht: dünn gehalten, damit die Regeln oben die ganze Entscheidung
/// tragen.
@MainActor
enum CommandTargeting {
    // MARK: - Das Fenster, das der Nutzer bedient

    /// Dokumentfenster, das ein globaler Befehl trifft.
    static func targetDocumentWindow() -> NSWindow? {
        let windows = orderedWindows().filter(\.isVisible)
        let candidates = windows.map {
            WindowTargeting.Candidate(isDocumentWindow: isDocumentWindow($0),
                                      isKey: $0.isKeyWindow,
                                      allowsDocumentFallback: SearchWindow.isSearchWindow($0),
                                      blocksInactiveDocumentFallback:
                                        ExternalDiffWindow.isExternalDiffWindow($0))
        }
        guard let index = WindowTargeting.targetIndex(in: candidates) else { return nil }
        return windows[index]
    }

    /// Editor-TextView des Fensters, das der Nutzer bedient.
    static func targetEditorTextView() -> TextView? {
        guard let window = targetDocumentWindow(),
              let content = window.contentView else { return nil }
        return descendantTextView(in: content)
    }

    /// Workspace des Fensters, das der Nutzer gerade bedient.
    ///
    /// Menübefehle wie „Neuer Tab“ brauchen keinen bereits montierten Editor.
    /// Sie dürfen ihr Ziel trotzdem nicht aus `Workspace.shared` lesen: Nach
    /// einer Sitzungswiederherstellung kann dieser Wert auf dem zuletzt
    /// erzeugten statt auf dem vordersten Fenster stehen.
    static func targetWorkspace() -> Workspace? {
        guard let window = targetDocumentWindow() else { return nil }
        return WorkspaceWindowRegistry.workspace(for: window)
    }

    /// Fenster und Workspace in einem Zugriff — ohne Editor.
    ///
    /// Für Befehle, die auch auf Tabs ohne Texteditor wirken: Die Bild-, PDF-
    /// und Hex-Ansicht enthält keine `TextView`, `target()` unten würde dort
    /// also `nil` liefern. Drucken muss trotzdem funktionieren.
    static func targetDocument() -> (window: NSWindow, workspace: Workspace)? {
        guard let window = targetDocumentWindow(),
              let workspace = WorkspaceWindowRegistry.workspace(for: window) else {
            return nil
        }
        return (window, workspace)
    }

    /// Fenster, Workspace und Editor in EINEM Zugriff.
    ///
    /// Wer Inhalt liest und Text schreibt, muss beides aus DEMSELBEN Fenster
    /// nehmen. Genau daran scheiterte „Dokument formatieren": Es las den
    /// Tabinhalt aus `Workspace.shared` und schrieb in einen Editor, der aus
    /// einer zweiten, unabhängigen Suche stammte — bei zwei Fenstern konnten
    /// das verschiedene Dokumente sein.
    static func target() -> (window: NSWindow, workspace: Workspace, textView: TextView)? {
        guard let window = targetDocumentWindow(),
              let workspace = WorkspaceWindowRegistry.workspace(for: window),
              let content = window.contentView,
              let textView = descendantTextView(in: content) else { return nil }
        return (window, workspace, textView)
    }

    // MARK: - Ein bestimmter Workspace

    /// Dokumentfenster eines bestimmten Workspace.
    ///
    /// Für gezielte Wege, die ihr Dokument schon kennen (Suchtreffer,
    /// Vorschau, Signaturhilfe). Ein Workspace besitzt genau ein
    /// Dokumentfenster; die Reihenfolge entscheidet hier also nichts, die
    /// Suche läuft trotzdem über `orderedWindows`, damit es in der ganzen
    /// Anwendung nur einen Weg gibt, an Fenster zu kommen.
    static func documentWindow(for workspace: Workspace) -> NSWindow? {
        orderedWindows().first {
            isDocumentWindow($0) && WorkspaceWindowRegistry.workspace(for: $0) === workspace
        }
    }

    /// Editor-TextView eines bestimmten Workspace.
    static func editorTextView(for workspace: Workspace) -> TextView? {
        guard let window = documentWindow(for: workspace),
              let content = window.contentView else { return nil }
        return descendantTextView(in: content)
    }

    /// Fenster eines Workspace — auch wenn es gerade nicht sichtbar ist.
    ///
    /// Für den Beenden-Pfad: Sobald ⌘Q läuft, kann AppKit hintere Fenster
    /// bereits `orderOut` gesetzt haben. `isVisible` würde dann nur noch das
    /// Vorderfenster finden, und für die übrigen Dokumente entstünde eine
    /// Rückfrage ohne zugehöriges Fenster. Die Registry kennt dagegen jedes
    /// noch nicht geschlossene Fenster.
    ///
    /// Liefert diese Funktion `nil`, gehört der Workspace zu KEINEM Fenster
    /// mehr — er ist verwaist und darf nichts mehr melden.
    static func registeredWindow(for workspace: Workspace) -> NSWindow? {
        if let visible = documentWindow(for: workspace) { return visible }
        return WorkspaceWindowRegistry.registeredWindows().first {
            // Der Rückfall darf die Sichtbarkeit bewusst NICHT verlangen:
            // AppKit kann hintere Dokumentfenster beim Beenden ausblenden.
            // Such- und Hilfefenster kennen teils denselben Workspace, sind
            // aber niemals der sichtbare Gegenstand einer Sicherungsfrage.
            !SearchWindow.isSearchWindow($0)
                && !HelpWindow.isHelpWindow($0)
                && WorkspaceWindowRegistry.workspace(for: $0) === workspace
        }
    }

    /// Der Workspace, zu dem DIESER Editor gehört.
    ///
    /// Die Umkehrung ist das Mittel gegen die gefährlichste Spielart des
    /// Fensterfehlers: Eine Operation liest den Tabinhalt aus einer Quelle und
    /// schreibt in einen Editor aus einer anderen. Genau so bestimmten
    /// „Dokument formatieren", „minifizieren" und „prüfen" ihre Dateiendung
    /// aus `Workspace.shared`, während der Text aus einem womöglich anderen
    /// Fenster kam. Wer den Editor hat, holt seinen Workspace ab jetzt hier.
    static func workspace(for textView: TextView) -> Workspace? {
        guard let window = textView.window else { return nil }
        return WorkspaceWindowRegistry.workspace(for: window)
    }

    // MARK: - Bausteine

    /// Alle Fenster in Vordergrund-Reihenfolge.
    ///
    /// Die einzige Stelle im Produktcode, die AppKit direkt nach Fenstern
    /// fragt. `orderedWindows` ist von vorne nach hinten sortiert;
    /// `NSApp.windows` wäre es NICHT (siehe Dateikopf).
    private static func orderedWindows() -> [NSWindow] {
        NSApp?.orderedWindows ?? []
    }

    /// Echtes Dokumentfenster? Dieselbe Klassifikation wie in
    /// `DocumentWindowController` — Such-, Hilfe- und Panel-Fenster gehören
    /// nicht dazu, auch wenn sie für ihr Routing einen Workspace kennen.
    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible, !SearchWindow.isSearchWindow(window) else { return false }
        if HelpWindow.isHelpWindow(window) { return false }
        if window.identifier?.rawValue == "Fastra.DocumentWindow" { return true }
        return WorkspaceWindowRegistry.workspace(for: window) != nil
    }

    private static func descendantTextView(in view: NSView) -> TextView? {
        if let textView = view as? TextView { return textView }
        for sub in view.subviews {
            if let found = descendantTextView(in: sub) { return found }
        }
        return nil
    }
}
