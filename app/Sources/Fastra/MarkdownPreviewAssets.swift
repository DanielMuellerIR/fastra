import Foundation
import WebKit

/// Lokale Ressourcen der Markdown-Vorschau. Das eigene URL-Schema hält
/// JavaScript-Bibliotheken und Bilder von WebKit getrennt vom Netz: Nur diese
/// Allowlist und zuvor aufgelöste Bilddateien können geladen werden.
enum MarkdownPreviewAssets {
    static let scheme = "fastra-preview"
    static let maximumImageBytes = 32 * 1024 * 1024

    private static let resources: [String: (file: String, mimeType: String)] = [
        "katex.js": ("katex-0.17.0.min.js", "text/javascript"),
        "highlight.js": ("highlight-11.11.1.min.js", "text/javascript"),
        "highlight.css": ("highlight-11.11.1.min.css", "text/css"),
        "mermaid.js": ("mermaid-11.16.0.min.js", "text/javascript")
    ]

    static func resource(named name: String) -> (url: URL, mimeType: String)? {
        guard let resource = resources[name],
              let url = AppResources.bundle.url(
                forResource: resource.file,
                withExtension: nil,
                subdirectory: "MarkdownVendor"
              ) ?? AppResources.bundle.url(forResource: resource.file, withExtension: nil)
        else { return nil }
        return (url, resource.mimeType)
    }

    /// SVG bleibt bewusst außen vor: Eine SVG-Datei kann selbst weitere
    /// Ressourcen referenzieren. Rasterbilder sind dagegen rein darstellbare
    /// Nutzdaten und lösen keine versteckten Netzabrufe aus.
    static func imageMIMEType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }
}

/// Liefert ausschließlich die von `MarkdownRichText` freigegebenen lokalen
/// Dateien. Datei-I/O läuft auf einer Hintergrundqueue, damit große Bilder den
/// Main-Thread nicht blockieren.
final class MarkdownPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var imageURLs: [String: URL] = [:]
    private var cancelledTasks: Set<ObjectIdentifier> = []

    func setImageURLs(_ urls: [String: URL]) {
        lock.lock()
        imageURLs = urls
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == MarkdownPreviewAssets.scheme else {
            fail(urlSchemeTask, code: .unsupportedURL)
            return
        }

        let source: (url: URL, mimeType: String)?
        switch requestURL.host {
        case "resource":
            source = MarkdownPreviewAssets.resource(named: requestURL.lastPathComponent)
        case "image":
            let key = requestURL.lastPathComponent
            lock.lock()
            let imageURL = imageURLs[key]
            lock.unlock()
            source = imageURL.flatMap { url in
                MarkdownPreviewAssets.imageMIMEType(for: url).map { (url, $0) }
            }
        default:
            source = nil
        }

        guard let source else {
            fail(urlSchemeTask, code: .fileDoesNotExist)
            return
        }

        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        cancelledTasks.remove(taskID)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if requestURL.host == "image" {
                    let values = try source.url.resourceValues(forKeys: [
                        .isRegularFileKey, .fileSizeKey
                    ])
                    guard values.isRegularFile == true,
                          let size = values.fileSize,
                          size <= MarkdownPreviewAssets.maximumImageBytes else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                }
                let data = try Data(contentsOf: source.url, options: [.mappedIfSafe])
                guard !self.isCancelled(taskID) else {
                    self.forget(taskID)
                    return
                }
                let response = URLResponse(
                    url: requestURL,
                    mimeType: source.mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: source.mimeType.hasPrefix("text/") ? "utf-8" : nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                self.forget(taskID)
            } catch {
                guard !self.isCancelled(taskID) else {
                    self.forget(taskID)
                    return
                }
                urlSchemeTask.didFailWithError(error)
                self.forget(taskID)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        cancelledTasks.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    private func isCancelled(_ taskID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledTasks.contains(taskID)
    }

    private func forget(_ taskID: ObjectIdentifier) {
        lock.lock()
        cancelledTasks.remove(taskID)
        lock.unlock()
    }

    private func fail(_ task: WKURLSchemeTask, code: URLError.Code) {
        task.didFailWithError(URLError(code))
    }
}
