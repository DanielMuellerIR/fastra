import Darwin
import Foundation
import Testing
@testable import Fastra

private let menuRootAppDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func menuRootBinding() throws -> SelfTestMenuRootExchange.Binding {
    try SelfTestMenuRootExchange.Binding([
        "version": .integer(1), "test": .string("multisearch"), "runNonce": .string(UUID().uuidString),
        "runnerPid": .integer(101), "runnerToken": .string("runner start"),
        "appPid": .integer(102), "appToken": .string("app start"), "appExe": .string("/bin/echo"),
        "senderPid": .integer(103), "senderToken": .string("sender start"),
        "senderExe": .string("/bin/echo"), "senderScript": .string(URL(fileURLWithPath: "/tmp/sender.py").resolvingSymlinksInPath().path)])
}

private func menuRootReply(_ binding: SelfTestMenuRootExchange.Binding, nonce: String,
                           phase: String = "actionReturned", error: Int? = 0) -> [String: Any] {
    var result: [String: Any] = ["version": 1, "test": binding.test, "runNonce": binding.runNonce,
        "appPid": binding.appPid, "senderPid": binding.senderPid, "nonce": nonce, "rootTitle": "Datei",
        "binding": binding.fields.mapValues(\.json), "phase": phase]
    if let error { result["axError"] = error }
    return result
}

@Suite("Menüroot-Austausch")
struct SelfTestMenuRootTests {
    @Test("Gültige Antwort verlangt zurückgekehrte Actionphase und vollständige Identität")
    func validatesActionAndBinding() throws {
        let binding = try menuRootBinding(), nonce = UUID().uuidString
        let reply = menuRootReply(binding, nonce: nonce)
        let data = try JSONSerialization.data(withJSONObject: reply)
        #expect(try SelfTestMenuRootExchange.validateReply(data, binding: binding, nonce: nonce,
                                                        rootTitle: "Datei") == .actionReturned(0))
        for field in ["test", "runNonce", "appPid", "senderPid", "nonce", "rootTitle", "version"] {
            var wrong = reply
            wrong[field] = field.hasSuffix("Pid") || field == "version" ? 999 : "fremd"
            let changed = try JSONSerialization.data(withJSONObject: wrong)
            #expect(throws: (any Error).self) {
                try SelfTestMenuRootExchange.validateReply(changed, binding: binding, nonce: nonce, rootTitle: "Datei")
            }
        }
        for field in binding.fields.keys {
            var wrong = reply, nested = binding.fields.mapValues(\.json)
            nested[field] = 999
            wrong["binding"] = nested
            let changed = try JSONSerialization.data(withJSONObject: wrong)
            #expect(throws: (any Error).self) {
                try SelfTestMenuRootExchange.validateReply(changed, binding: binding, nonce: nonce, rootTitle: "Datei")
            }
        }
        for malformed in [
            menuRootReply(binding, nonce: nonce, phase: "ready"),
            menuRootReply(binding, nonce: nonce, error: nil),
            menuRootReply(binding, nonce: nonce, phase: "preInputEnvironment"),
            reply.merging(["axError": true]) { _, new in new },
            reply.merging(["version": 1.5]) { _, new in new },
            reply.merging(["extra": "field"]) { _, new in new },
        ] {
            let changed = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: (any Error).self) {
                try SelfTestMenuRootExchange.validateReply(changed, binding: binding, nonce: nonce, rootTitle: "Datei")
            }
        }
        var environment = menuRootReply(binding, nonce: nonce, phase: "preInputEnvironment", error: nil)
        environment["reason"] = "accessibilityNotTrusted"
        #expect(try SelfTestMenuRootExchange.validateReply(JSONSerialization.data(withJSONObject: environment),
            binding: binding, nonce: nonce, rootTitle: "Datei") == .environment("accessibilityNotTrusted"))
        environment["axError"] = 0
        #expect(throws: (any Error).self) {
            try SelfTestMenuRootExchange.validateReply(JSONSerialization.data(withJSONObject: environment),
                binding: binding, nonce: nonce, rootTitle: "Datei")
        }
        let duplicate = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"phase\":", with: "\"phase\":\"ready\",\"phase\":")
        #expect(throws: (any Error).self) {
            try SelfTestMenuRootExchange.validateReply(Data(duplicate.utf8), binding: binding, nonce: nonce, rootTitle: "Datei")
        }
        let duplicateBinding = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"runnerPid\":", with: "\"runnerPid\":99,\"runnerPid\":")
        #expect(throws: (any Error).self) {
            try SelfTestMenuRootExchange.validateReply(Data(duplicateBinding.utf8), binding: binding, nonce: nonce, rootTitle: "Datei")
        }
    }

    @Test("Echte Dateien: alte Antwort bleibt wirkungslos, aktuelle wird angenommen")
    func readsCurrentReplyAndRejectsUnsafeFiles() throws {
        let root = testTemporaryDirectory().appendingPathComponent("menu-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = try menuRootBinding()
        func write(_ name: String, _ object: Any) throws {
            let url = root.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let exchange = try SelfTestMenuRootExchange(directory: root.path, test: binding.test, appPid: binding.appPid)
        #expect(try exchange.requestIfReady(rootTitle: "Datei") == false)
        try write("binding.json", binding.fields.mapValues(\.json))
        #expect(try exchange.requestIfReady(rootTitle: "Datei"))
        let nonce = try #require(exchange.nonce)
        try write("reply.json", menuRootReply(binding, nonce: UUID().uuidString))
        #expect(exchange.reply() == nil)
        try write("reply.json", menuRootReply(binding, nonce: nonce))
        #expect(exchange.reply() == .actionReturned(0))
        try write("reply.json", menuRootReply(binding, nonce: nonce, error: -25204))
        #expect(exchange.reply() == .actionReturned(-25204))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("reply.json").path)
        #expect(exchange.reply() == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("reply.json"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("reply.json").path,
                                                 withDestinationPath: root.appendingPathComponent("binding.json").path)
        #expect(exchange.reply() == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try SelfTestMenuRootExchange(directory: root.path, test: binding.test) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try SelfTestMenuRootExchange(directory: link.path, test: binding.test) }
        let moved = root.appendingPathExtension("old")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        #expect(exchange.reply() == nil)
    }

    @Test("JSON-Feldtypen, Duplikate und unbekannte Versionen schlagen geschlossen fehl")
    func rejectsMalformedFields() throws {
        for text in ["{", "[]", "{\"a\":1,\"a\":2}", "{\"a\":true}", "{\"a\":1.25}",
                     "{\"a\":null}", "{\"a\":{\"b\":1}}", "{\"a\":99999999999999999999999}"] {
            #expect(throws: (any Error).self) { try SelfTestMenuRootExchange.fields(Data(text.utf8)) }
        }
        var fields = try menuRootBinding().fields
        fields["version"] = .integer(2)
        #expect(throws: (any Error).self) { try SelfTestMenuRootExchange.Binding(fields) }
    }
}

@Suite("Menüroot-Runner", .serialized)
struct SerialRunnerIntegrationMenuRootTests {
    @Test("AX-Guards und Betriebssystemfrist mit internem FakeAX")
    func pythonRequestRegressions() throws {
        let result = try runTestProcess("/usr/bin/python3", arguments: [
            menuRootAppDirectory.appendingPathComponent("tools/tests/test_selftest_menu_root.py").path,
            "--unit-only"])
        #expect(result.status == 0, "Menüroot-Sender: \(result.output)")
        #expect(result.output.contains("\nOK\n"))
    }

    @Test("Echter Runner besitzt App und Sender; fremde Prozesse bleiben unberührt",
           arguments: ["success", "app-dies", "sender-hangs", "sender-identity", "app-identity", "term-start", "term-adopt", "cleanup-failure", "sender-exits", "app-dies-cleanup-failure", "early-fail"])
    func ownedProcesses(mode: String) throws {
        let root = testTemporaryDirectory().appendingPathComponent("menu-root-runner-\(UUID().uuidString)")
        let sandbox = root.appendingPathComponent("sandboxes")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runTestProcess("/usr/bin/python3", arguments: [
            menuRootAppDirectory.appendingPathComponent("tools/tests/test_selftest_menu_root.py").path,
            "--runner-case", mode, root.path], environment: [
                "PATH": try pathIgnoringForeignFastraProcess(in: root),
                "FASTRA_SELFTEST_PRODUCT_DEFAULTS_DOMAIN": throwawayProductDefaultsDomain(),
                "FASTRA_SELFTEST_PRODUCT_SAVED_STATE_DIR": throwawayProductSavedStateDirectory(in: sandbox).path,
            ])
        #expect(result.status == 0, "Menüroot-Owned-Process \(mode): \(result.output)")
    }
}
