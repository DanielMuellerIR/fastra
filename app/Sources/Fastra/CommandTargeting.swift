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

        init(isDocumentWindow: Bool, isKey: Bool) {
            self.isDocumentWindow = isDocumentWindow
            self.isKey = isKey
        }
    }

    /// Index des Fensters, das ein globaler Befehl treffen muss.
    ///
    /// `candidates` kommt in AppKits Vordergrund-Reihenfolge (vorne zuerst).
    ///
    /// Die Regeln, in dieser Reihenfolge:
    /// 1. Bedient der Nutzer gerade ein Dokumentfenster, gilt dieses. Das ist
    ///    der Normalfall und die einzige Regel, die der alte Code verletzte.
    /// 2. Liegt ein anderes Fenster vorne — typisch die schwebende Suchmaske,
    ///    die den Tastaturfokus hält —, gilt das vorderste Dokumentfenster
    ///    dahinter. Ein Befehl aus der Menüleiste soll wirken, ohne dass der
    ///    Nutzer erst das Dokument anklicken muss.
    /// 3. Ohne Dokumentfenster gibt es kein Ziel.
    static func targetIndex(in candidates: [Candidate]) -> Int? {
        if let keyed = candidates.firstIndex(where: { $0.isDocumentWindow && $0.isKey }) {
            return keyed
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
        let windows = orderedWindows()
        let candidates = windows.map {
            WindowTargeting.Candidate(isDocumentWindow: isDocumentWindow($0),
                                      isKey: $0.isKeyWindow)
        }
        guard let index = WindowTargeting.targetIndex(in: candidates) else { return nil }
        return windows[index]
    }

    /// Workspace des Fensters, das der Nutzer bedient.
    ///
    /// Ersetzt `Workspace.shared` überall dort, wo ein BEFEHL sein Ziel sucht.
    /// `Workspace.shared` bleibt für alles zulässig, was nicht an ein Fenster
    /// gebunden ist (etwa das Ausliefern gepufferter Öffnen-Anfragen).
    static func targetWorkspace() -> Workspace? {
        guard let window = targetDocumentWindow() else { return nil }
        return WorkspaceWindowRegistry.workspace(for: window)
    }

    /// Editor-TextView des Fensters, das der Nutzer bedient.
    static func targetEditorTextView() -> TextView? {
        guard let window = targetDocumentWindow(),
              let content = window.contentView else { return nil }
        return descendantTextView(in: content)
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
            WorkspaceWindowRegistry.workspace(for: $0) === workspace
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
        NSApp.orderedWindows
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
