import Foundation

/// Statische Demo-Daten für gezielte Selbsttests und Screenshots.
enum DemoData {
    static func editorContent(for title: String?) -> String {
        switch title {
        case "contacts.md":
            let german = """
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
            return L10n.string("demo.contacts", defaultValue: german)
        default:
            return L10n.format(
                "demo.placeholder.%@",
                defaultValue: "// Datei: %@\n\nDies ist ein Placeholder. Der echte Editor (CodeEditSourceEditor + tree-sitter) wird in Phase 2 integriert.",
                title ?? "—"
            )
        }
    }
}
