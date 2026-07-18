// TabPathMenu.swift
//
// Cmd-Klick auf einen Dokument-Tab zeigt das macOS-typische Pfadmenü
// (Etappe 1 Wunschpaket 2026-07b): oberster Eintrag die Datei selbst,
// darunter jeder Elternordner bis zur Wurzel — wie das frühere Cmd-Klick-
// Menü am Fenstertitel (BBEdit-/macOS-Standardverhalten), das mit dem
// titellosen Fensterchrome unerreichbar wurde. Für ungespeicherte Tabs
// gibt es kein Menü (keine Datei, kein Pfad).

import AppKit

/// Reine, unit-testbare Logik: die Pfadkette einer Datei von der Datei
/// selbst (zuoberst) aufwärts bis zur Wurzel „/“.
enum TabPathMenuModel {
    static func pathChain(for url: URL) -> [URL] {
        var current = url.standardizedFileURL
        var chain = [current]
        // Sicherheitsnetz gegen pathologische URLs: mehr als 64 Ebenen hat
        // kein realer macOS-Pfad; lieber abbrechen als endlos schleifen.
        while current.path != "/", chain.count < 64 {
            current = current.deletingLastPathComponent()
            chain.append(current)
        }
        return chain
    }
}

/// Präsentiert das Pfadmenü als natives `NSMenu` an der Mausposition.
/// Singleton als Target, weil `NSMenuItem` seine Aktion erst nach dem Ende
/// des Menü-Trackings zustellt (gleiches Muster wie beim Geschwisterordner-
/// Menü in `SidebarProjectHeader.swift`).
@MainActor
final class TabPathMenuPresenter: NSObject {
    static let shared = TabPathMenuPresenter()

    func present(for fileURL: URL) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, url) in TabPathMenuModel.pathChain(for: fileURL).enumerated() {
            // Anzeigename wie im Finder (lokalisierte Ordnernamen, z. B.
            // „Schreibtisch“); Fallback ist der letzte Pfadbestandteil.
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: url.path),
                action: #selector(openEntry(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if index == 0 {
                item.toolTip = L10n.string("Im Finder zeigen…")
            }
            menu.addItem(item)
        }
        // `view: nil` → der Punkt gilt in Bildschirmkoordinaten.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openEntry(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path,
                                                    isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            // Ordner-Eintrag: den Ordner selbst im Finder öffnen —
            // macOS-Standardverhalten des Titelzeilen-Pfadmenüs.
            NSWorkspace.shared.open(url)
        } else {
            // Oberster Eintrag (die Datei): im Finder ZEIGEN, nicht öffnen —
            // sie ist ja bereits in Fastra offen.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
