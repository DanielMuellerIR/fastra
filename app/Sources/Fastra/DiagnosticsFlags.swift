import Foundation

/// Explizite stderr-Diagnosen; die Umgebung bleibt bei jedem Zugriff aktuell.
enum DiagnosticsFlags {
    static var scrollRestore: Bool {
        ProcessInfo.processInfo.environment["FASTRA_SCROLLRESTORE_DEBUG"] == "1"
    }

    static var sidebarScroll: Bool {
        ProcessInfo.processInfo.environment["FASTRA_SIDEBARSCROLL_DEBUG"] == "1"
    }
}
