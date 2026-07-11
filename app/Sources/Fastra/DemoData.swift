import Foundation

/// Statische Demo-Daten, damit das UI ohne echten Editor / echte Suche Sinn ergibt.
enum DemoData {
    /// UserDefaults-Schlüssel, der nach dem allerersten App-Start gesetzt
    /// wird. Solange er fehlt, gilt der Start als „erster Start".
    static let hasLaunchedBeforeKey = "fastra.hasLaunchedBefore"

    /// Liefert `true` GENAU beim ersten Start (Schlüssel fehlt noch) und
    /// setzt den Schlüssel dabei sofort — jeder weitere Aufruf liefert
    /// `false`. „Consume", weil Abfrage und Verbrauch ein Schritt sind:
    /// So kann kein zweiter Code-Pfad versehentlich auch noch „erster
    /// Start" sehen. Der `defaults`-Parameter ist für Tests injizierbar
    /// (eigene Suite statt der echten App-Defaults).
    ///
    /// Hintergrund (Interview-Erkenntnis 4, AGENTS.md): Ein LEERER
    /// Start-Zustand verhindert den Einstieg — neue Nutzer brechen ab.
    /// Deshalb lädt der allererste Start einen Demo-Tab mit vorbelegtem
    /// Beispiel-Pattern. Alle folgenden Starts beginnen wie ein normaler
    /// Editor mit leerem, unbenanntem Tab.
    static func consumeFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: hasLaunchedBeforeKey) { return false }
        defaults.set(true, forKey: hasLaunchedBeforeKey)
        return true
    }

    static func editorContent(for title: String?) -> String {
        switch title {
        case "contacts.md":
            return """
            # Adressbuch — Team Q2

            ## Vertrieb

            - Anna Huber — anna.huber@gmail.com — Tel. 030/12345
            - Max Mustermann — max@mustermann-firma.de — Tel. 040/67890
            - Lisa Schäfer — lisa.schaefer@gmx.de — Tel. 089/13579
            - Tom Mendel — tmendel@yahoo.com — Tel. 040/24680
            - Petra Lang — petra.lang@web.de

            ## Support

            - support@example.com — Hauptpostfach
            - billing@example.com — Buchhaltung
            - admin@example.de — Administration

            ## Marketing

            - newsletter@example.com
            - presse@example.com
            """
        default:
            return "// Datei: \(title ?? "—")\n\nDies ist ein Placeholder. Der echte Editor (CodeEditSourceEditor + tree-sitter) wird in Phase 2 integriert."
        }
    }
}
