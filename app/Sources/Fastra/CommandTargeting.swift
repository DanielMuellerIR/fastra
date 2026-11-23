// CommandTargeting.swift
//
// Dokumentbefehle bestimmen Fenster, Workspace und Editor gemeinsam.
// AppKit liefert die Fensterreihenfolge über `orderedWindows`;
// `NSApp.windows` ist unsortiert, `Workspace.shared` kann nach einer
// Sitzungswiederherstellung auf ein anderes Fenster zeigen.
// `app/window-targeting-audit.sh` sichert den zentralen Zugriff ab.

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
        /// Suchmaske und Dokument müssen demselben registrierten Workspace
        /// gehören; die Fensterreihenfolge allein belegt diese Bindung nicht.
        let documentOwnerID: ObjectIdentifier?
        /// Ein Vergleich ohne Editor sperrt auch ohne aktives Key-Window
        /// den Rückfall auf ein dahinter liegendes Dokument.
        let blocksInactiveDocumentFallback: Bool

        init(isDocumentWindow: Bool, isKey: Bool,
             allowsDocumentFallback: Bool = false,
             documentOwnerID: ObjectIdentifier? = nil,
             blocksInactiveDocumentFallback: Bool = false) {
            self.isDocumentWindow = isDocumentWindow
            self.isKey = isKey
            self.allowsDocumentFallback = allowsDocumentFallback
            self.documentOwnerID = documentOwnerID
            self.blocksInactiveDocumentFallback = blocksInactiveDocumentFallback
        }
    }

    /// Index des Fensters, das ein globaler Befehl treffen muss.
    ///
    /// `candidates` kommt in AppKits Vordergrund-Reihenfolge (vorne zuerst).
    ///
    /// Die Regeln, in dieser Reihenfolge:
    /// 1. Bedient der Nutzer gerade ein Dokumentfenster, gilt dieses.
    /// 2. Hält die bekannte Suchmaske die Tastatur, gilt ausschließlich ihr
    ///    noch sichtbares, registriertes Dokumentfenster.
    /// 3. Hält ein anderes Fenster die Tastatur, gibt es kein Dokumentziel.
    ///    Besonders ⌘W darf dann niemals ein Fenster dahinter schließen.
    /// 4. Ohne Key-Window gilt das vorderste Dokumentfenster.
    static func targetIndex(in candidates: [Candidate]) -> Int? {
        if let keyed = candidates.firstIndex(where: \.isKey) {
            if candidates[keyed].isDocumentWindow { return keyed }
            guard candidates[keyed].allowsDocumentFallback,
                  let owner = candidates[keyed].documentOwnerID else { return nil }
            return candidates.firstIndex {
                $0.isDocumentWindow && $0.documentOwnerID == owner
            }
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
                                      documentOwnerID: WorkspaceWindowRegistry.workspace(for: $0)
                                        .map(ObjectIdentifier.init),
                                      blocksInactiveDocumentFallback:
                                        ExternalDiffWindow.isExternalDiffWindow($0)
                                        || ControlSnapshotWindow.isSnapshotWindow($0))
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

    /// Fenster, Workspace und Editor in einem Zugriff.
    ///
    /// Wer Inhalt liest und Text schreibt, muss beides aus demselben Fenster
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
    /// Liefert diese Funktion `nil`, gehört der Workspace zu keinem Fenster
    /// mehr — er ist verwaist und darf nichts mehr melden.
    static func registeredWindow(for workspace: Workspace) -> NSWindow? {
        if let visible = documentWindow(for: workspace) { return visible }
        return WorkspaceWindowRegistry.registeredWindows().first {
            // Der Rückfall darf die Sichtbarkeit bewusst nicht verlangen:
            // AppKit kann hintere Dokumentfenster beim Beenden ausblenden.
            // Such- und Hilfefenster kennen teils denselben Workspace, sind
            // aber niemals der sichtbare Gegenstand einer Sicherungsfrage.
            !SearchWindow.isSearchWindow($0)
                && !HelpWindow.isHelpWindow($0)
                && WorkspaceWindowRegistry.workspace(for: $0) === workspace
        }
    }

    /// Der Workspace, zu dem dieser Editor gehört.
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
    /// `NSApp.windows` wäre es nicht (siehe Dateikopf).
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
        if let window = view.window, let workspace = WorkspaceWindowRegistry.workspace(for: window),
           let preferred = workspace.sourcePanes.preferred(in: view, documentID: workspace.activeDocumentID) {
            return preferred
        }
        if let textView = view as? TextView {
            // Während SwiftUI den neuen Tab montiert, kann der alte Editor
            // noch im Fenster liegen und sogar denselben Text anzeigen.
            if let window = view.window, let workspace = WorkspaceWindowRegistry.workspace(for: window),
               !workspace.sourcePanes.allowsTargeting(textView, documentID: workspace.activeDocumentID) { return nil }
            return textView
        }
        for sub in view.subviews {
            if let found = descendantTextView(in: sub) { return found }
        }
        return nil
    }
}
