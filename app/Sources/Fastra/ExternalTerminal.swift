import AppKit
import Foundation

enum TerminalOpenError: LocalizedError, Equatable {
    case noDirectory
    case directoryUnavailable(String)
    case terminalUnavailable
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDirectory:
            return L10n.string("Kein Projekt und keine aktive Datei liefern einen Ordner.")
        case .directoryUnavailable(let path):
            return L10n.format("Der Ordner ist nicht verfügbar: %@", path)
        case .terminalUnavailable:
            return L10n.string("Terminal.app wurde auf diesem Mac nicht gefunden.")
        case .openFailed(let details):
            return L10n.format("Terminal konnte nicht geöffnet werden: %@", details)
        }
    }
}

protocol TerminalDirectoryResolving {
    func resolve(projectURL: URL?, activeFileURL: URL?) -> URL?
}

struct DefaultTerminalDirectoryResolver: TerminalDirectoryResolving {
    /// Produktreihenfolge: Projektroot vor Dateiverzeichnis. Git-Tabs und
    /// unbenannte Dokumente besitzen keine URL und werden nicht als Pfadquelle
    /// missverstanden.
    func resolve(projectURL: URL?, activeFileURL: URL?) -> URL? {
        if let projectURL { return projectURL.standardizedFileURL }
        return activeFileURL?.deletingLastPathComponent().standardizedFileURL
    }
}

/// Statischer Komfortzugriff für pure Tests und Stellen ohne Workspace.
enum TerminalDirectoryResolver {
    static func resolve(projectURL: URL?, activeFileURL: URL?) -> URL? {
        DefaultTerminalDirectoryResolver().resolve(projectURL: projectURL,
                                                   activeFileURL: activeFileURL)
    }
}

protocol TerminalOpening: AnyObject {
    func open(directory: URL, completion: @escaping (Result<Void, TerminalOpenError>) -> Void)
}

/// Native AppKit-Implementierung. macOS bietet keine stabile öffentliche API,
/// um eine beliebige „Standard-Terminal-App“ samt Arbeitsverzeichnis zu
/// ermitteln. Deshalb wird Terminal.app anhand seiner Bundle-ID als klarer,
/// deterministischer Fallback geöffnet. Keine Shell, kein AppleScript und kein
/// Quoting sind beteiligt; der Ordner bleibt eine URL.
final class ExternalTerminalLauncher: TerminalOpening {
    typealias ApplicationLocator = () -> URL?
    typealias NativeOpen = (URL, URL, @escaping (Error?) -> Void) -> Void
    typealias FileInspection = (URL) -> Bool
    typealias Dispatcher = (@escaping () -> Void) -> Void

    private let fileInspection: FileInspection
    private let applicationLocator: ApplicationLocator
    private let nativeOpen: NativeOpen
    private let utilityDispatch: Dispatcher
    private let mainDispatch: Dispatcher

    init(fileManager: FileManager = .default,
         fileInspection: FileInspection? = nil,
         applicationLocator: @escaping ApplicationLocator = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
         },
         nativeOpen: @escaping NativeOpen = { directory, application, completion in
             let configuration = NSWorkspace.OpenConfiguration()
             configuration.activates = true
             NSWorkspace.shared.open([directory], withApplicationAt: application,
                                     configuration: configuration) { _, error in
                 completion(error)
             }
         },
         utilityDispatch: @escaping Dispatcher = { work in
             DispatchQueue.global(qos: .utility).async(execute: work)
         },
         mainDispatch: @escaping Dispatcher = { work in
             DispatchQueue.main.async(execute: work)
         }) {
        self.fileInspection = fileInspection ?? { directory in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        self.applicationLocator = applicationLocator
        self.nativeOpen = nativeOpen
        self.utilityDispatch = utilityDispatch
        self.mainDispatch = mainDispatch
    }

    func open(directory: URL,
              completion: @escaping (Result<Void, TerminalOpenError>) -> Void) {
        utilityDispatch { [fileInspection, applicationLocator, nativeOpen,
                           mainDispatch] in
            let isDirectory = fileInspection(directory)
            mainDispatch {
                guard isDirectory else {
                    completion(.failure(.directoryUnavailable(directory.path)))
                    return
                }
                // NSWorkspace und die App-Auflösung bleiben kontrolliert auf
                // dem Main-Thread; nur das potenziell blockierende Volume-I/O
                // lief auf der Utility-Queue.
                guard let application = applicationLocator() else {
                    completion(.failure(.terminalUnavailable))
                    return
                }
                nativeOpen(directory, application) { error in
                    mainDispatch {
                        if let error {
                            completion(.failure(.openFailed(error.localizedDescription)))
                        } else {
                            completion(.success(()))
                        }
                    }
                }
            }
        }
    }
}
