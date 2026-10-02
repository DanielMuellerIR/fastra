import Foundation
import Testing
import WebKit
@testable import Fastra

private final class DeferredSchemeDelivery {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    var isReady: Bool { lock.withLock { !pending.isEmpty } }
    func enqueue(_ action: @escaping () -> Void) { lock.withLock { pending.append(action) } }
    func run() {
        let actions = lock.withLock { let result = pending; pending = []; return result }
        actions.forEach { $0() }
    }
}

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request = URLRequest(url: URL(string: "fastra-preview://image/test.png")!)
    var callbacks: [String] = []
    var bytes = Data()
    var allCallbacksOnMain = true
    private func record(_ name: String) {
        callbacks.append(name)
        allCallbacksOnMain = allCallbacksOnMain && Thread.isMainThread
    }
    func didReceive(_ response: URLResponse) { record("response") }
    func didReceive(_ data: Data) { bytes.append(data); record("data") }
    func didFinish() { record("finish") }
    func didFailWithError(_ error: Error) { record("error") }
}

@MainActor
@Suite("Markdown-Bildantworten nach Abbruch", .serialized)
struct MarkdownPreviewSchemeHandlerTests {
    @Test("Abbruch nach dem Lesen unterdrückt Erfolg und Fehler", arguments: [true, false])
    func stoppedTaskReceivesNothing(fileExists: Bool) async throws {
        let file = testTemporaryDirectory().appendingPathComponent("scheme-\(UUID()).png")
        if fileExists { try Data([1, 2, 3]).write(to: file) }
        defer { try? FileManager.default.removeItem(at: file) }
        let scheduler = DeferredSchemeDelivery()
        let handler = MarkdownPreviewSchemeHandler(deliver: scheduler.enqueue)
        handler.setImageURLs(["test.png": file])
        let task = RecordingSchemeTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        #expect(await waitUntil { scheduler.isReady })
        handler.webView(webView, stop: task)
        scheduler.run()
        #expect(task.callbacks.isEmpty)
    }

    @Test("Aktive Bildantwort liefert Bytes und Abschluss auf Main")
    func liveTaskReceivesImage() async throws {
        let file = testTemporaryDirectory().appendingPathComponent("scheme-\(UUID()).png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handler = MarkdownPreviewSchemeHandler()
        handler.setImageURLs(["test.png": file])
        let task = RecordingSchemeTask()
        let webView = WKWebView()
        handler.webView(webView, start: task)
        #expect(await waitUntil { !task.callbacks.isEmpty })
        #expect(task.callbacks == ["response", "data", "finish"])
        #expect(task.bytes == bytes)
        #expect(task.allCallbacksOnMain)
    }
}
