import AppKit
import CoreText
import SwiftUI

/// Lädt die ausschließlich für die Fastra-Wortmarke gebündelte Schrift.
/// Die normale Bedienoberfläche bleibt bewusst bei der macOS-Systemschrift.
enum BrandFont {
    static let postScriptName = "Sora-SemiBold"

    /// Core Text registriert App-Schriften pro Prozess. Die statische
    /// Initialisierung ist threadsicher und läuft höchstens einmal.
    private static let registrationSucceeded: Bool = {
        let bundle = AppResources.bundle
        guard let url = bundle.url(forResource: "Sora-SemiBold",
                                   withExtension: "ttf",
                                   subdirectory: "Brand")
                ?? bundle.url(forResource: "Sora-SemiBold", withExtension: "ttf") else {
            return false
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }

        // Mehrere Fenster können die Wortmarke nahezu gleichzeitig anlegen.
        // Falls die Schrift bereits registriert ist, ist das ebenfalls Erfolg.
        return NSFont(name: postScriptName, size: 12) != nil
    }()

    @discardableResult
    static func register() -> Bool {
        registrationSucceeded
    }

    static func font(size: CGFloat) -> Font {
        _ = register()
        return .custom(postScriptName, size: size)
    }
}

/// Einheitliche Wortmarke für Willkommen, Seitenleiste und Über-Dialog.
/// Das kleine hochgestellte Sternchen verweist dezent auf Fastras
/// Platzhaltersuche, ohne die Lesbarkeit des Namens zu verändern.
struct BrandWordmark: View {
    let size: CGFloat

    var body: some View {
        Text(verbatim: "Fastra")
            .font(BrandFont.font(size: size))
            .overlay(alignment: .topTrailing) {
                Text(verbatim: "*")
                    .font(BrandFont.font(size: size * 0.4))
                    .offset(x: size * 0.4, y: size * 0.03)
            }
            .padding(.trailing, size * 0.4)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fastra")
    }
}
