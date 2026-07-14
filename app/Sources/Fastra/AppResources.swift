import Foundation

/// Zentraler, portabler Zugriff auf Fastras SwiftPM-Ressourcenbundle.
/// Im Entwicklungs-Build liefert SwiftPM `Bundle.module`; in der gepackten
/// App liegt dasselbe Bundle unter `Contents/Resources`.
enum AppResources {
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent("Fastra_Fastra.bundle")
           ) {
            return packaged
        }
        return Bundle.module
    }()
}
