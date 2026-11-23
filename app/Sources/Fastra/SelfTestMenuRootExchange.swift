import CoreFoundation
import Darwin
import Foundation

/// Nur der dateigebundene Austausch der drei Menüproben. Der Runner besitzt
/// beide Prozesse; dieser Typ startet nichts und stellt keine Produkt-API bereit.
final class SelfTestMenuRootExchange {
    static let tests: Set<String> = ["multisearch", "softwrapprofiles", "textworkflow"]

    struct EnvironmentFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { "Menüroot vor Eingabe: " + reason }
    }

    struct Binding: Equatable {
        let fields: [String: Value]
        var appPid: Int { fields["appPid"]!.integer! }
        var senderPid: Int { fields["senderPid"]!.integer! }
        var runNonce: String { fields["runNonce"]!.string! }
        var test: String { fields["test"]!.string! }

        init(_ fields: [String: Value]) throws {
            let strings = Set(["test", "runNonce", "runnerToken", "appToken", "appExe", "senderToken", "senderExe", "senderScript"])
            let integers = Set(["version", "runnerPid", "appPid", "senderPid"])
            guard Set(fields.keys) == strings.union(integers), fields["version"] == .integer(1),
                  strings.allSatisfy({ fields[$0]?.string?.isEmpty == false }),
                  ["runnerPid", "appPid", "senderPid"].allSatisfy({ (fields[$0]?.integer ?? 0) > 1 }),
                  let test = fields["test"]?.string, SelfTestMenuRootExchange.tests.contains(test),
                  let nonce = fields["runNonce"]?.string, UUID(uuidString: nonce) != nil,
                  ["appExe", "senderExe", "senderScript"].allSatisfy({ key in
                      guard let path = fields[key]?.string else { return false }
                      return path.hasPrefix("/") && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
                  }) else { throw invalid("Bindung") }
            self.fields = fields
        }
    }

    enum Value: Equatable {
        case string(String), integer(Int)
        var string: String? { if case let .string(value) = self { value } else { nil } }
        var integer: Int? { if case let .integer(value) = self { value } else { nil } }
        var json: Any { switch self { case let .string(value): value; case let .integer(value): value } }
    }

    enum Reply: Equatable {
        case actionReturned(Int)
        case environment(String)
    }

    private let descriptor: Int32
    private let directory: String
    private let identity: stat
    private let test: String
    private let appPid: Int
    private(set) var binding: Binding?
    private(set) var nonce: String?
    private var rootTitle: String?

    init(directory: String, test: String, appPid: Int = Int(getpid())) throws {
        guard Self.tests.contains(test) else { throw invalid("Testname") }
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw invalid("Verzeichnis öffnen") }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw invalid("Verzeichnis lesen") }
        self.descriptor = fd
        self.directory = directory
        self.identity = info
        self.test = test
        self.appPid = appPid
        do { try checkDirectory() } catch { close(fd); throw error }
    }

    deinit { close(descriptor) }

    private func checkDirectory() throws {
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o7777) == 0o700,
              info.st_dev == identity.st_dev, info.st_ino == identity.st_ino else {
            throw invalid("unsicheres Verzeichnis")
        }
    }

    private func read(_ name: String) throws -> Data? {
        try checkDirectory()
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("Datei öffnen") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o7777) == 0o600,
              info.st_nlink == 1, info.st_size <= 16384 else { throw invalid("unsichere Datei") }
        var bytes = [UInt8](repeating: 0, count: 16385)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0, count <= 16384 else { throw invalid("Dateigröße") }
        return Data(bytes.prefix(count))
    }

    private func write(_ name: String, fields: [String: Value]) throws {
        try checkDirectory()
        let data = try JSONSerialization.data(withJSONObject: fields.mapValues(\.json), options: [.sortedKeys])
        let temporary = "." + UUID().uuidString
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw invalid("temporäre Datei") }
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0 else { throw invalid("Datei schreiben") }
        try checkDirectory()
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw invalid("Datei veröffentlichen") }
    }

    /// Flache Datensätze, exakte Feldmengen und Typen. Foundation akzeptiert
    /// doppelte Schlüssel; deshalb zählen wir zusätzlich die echten JSON-Keys.
    static func fields(_ data: Data) throws -> [String: Value] {
        guard data.count <= 16384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = String(data: data, encoding: .utf8) else { throw invalid("JSON") }
        let pattern = #""(?:\\.|[^"\\])*"\s*:"#
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == object.count else { throw invalid("doppelte/verschachtelte Felder") }
        return try values(object)
    }

    private static func values(_ object: [String: Any]) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, value) in object {
            if let string = value as? String { result[key] = .string(string) }
            else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    CFNumberIsFloatType(number) == false, let integer = Int(number.stringValue) {
                result[key] = .integer(integer)
            } else { throw invalid("Feldtyp") }
        }
        return result
    }

    /// Fehlende Bindung ist während des Runner-Handshakes normal. Der bereits
    /// laufende Menütimer bleibt die einzige appseitige Frist.
    func requestIfReady(rootTitle: String) throws -> Bool {
        if nonce != nil { return true }
        guard let data = try read("binding.json") else { return false }
        let binding = try Binding(Self.fields(data))
        guard binding.test == test, binding.appPid == appPid else { throw invalid("Appbindung") }
        let requestNonce = UUID().uuidString
        try write("request.json", fields: ["version": .integer(1), "test": .string(test),
            "runNonce": .string(binding.runNonce), "appPid": .integer(appPid),
            "nonce": .string(requestNonce), "rootTitle": .string(rootTitle)])
        self.binding = binding
        self.nonce = requestNonce
        self.rootTitle = rootTitle
        return true
    }

    static func validateReply(_ data: Data, binding: Binding, nonce: String, rootTitle: String) throws -> Reply {
        // Nur Reply enthält eine verschachtelte vollständige Bindung.
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bindingObject = object.removeValue(forKey: "binding") as? [String: Any],
              let text = String(data: data, encoding: .utf8), data.count <= 16384 else { throw invalid("Antwortbindung") }
        let keyExpression = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"\s*:"#)
        guard keyExpression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                == object.count + 1 + bindingObject.count else { throw invalid("doppelte Antwortfelder") }
        let nested = try values(bindingObject)
        guard try Binding(nested) == binding else { throw invalid("fremde Antwortbindung") }
        let flat = try values(object)
        let common: [String: Value] = ["version": .integer(1), "test": .string(binding.test),
            "runNonce": .string(binding.runNonce), "appPid": .integer(binding.appPid),
            "senderPid": .integer(binding.senderPid), "nonce": .string(nonce), "rootTitle": .string(rootTitle)]
        guard common.allSatisfy({ flat[$0.key] == $0.value }) else { throw invalid("veraltete Antwort") }
        let keys = Set(common.keys).union(["phase"])
        if flat["phase"] == .string("actionReturned"), Set(flat.keys) == keys.union(["axError"]),
           let error = flat["axError"]?.integer { return .actionReturned(error) }
        let reasons: Set<String> = ["processIdentityChanged", "accessibilityNotTrusted", "foreignForeground", "rootNotUnique", "actionNamesUnavailable", "pressUnsupported"]
        if flat["phase"] == .string("preInputEnvironment"), Set(flat.keys) == keys.union(["reason"]),
           let reason = flat["reason"]?.string, reasons.contains(reason) { return .environment(reason) }
        throw invalid("Antwortphase")
    }

    func reply() -> Reply? {
        guard let binding, let nonce, let rootTitle else { return nil }
        // Alte oder beschädigte Antworten lassen die Flags unverändert. Keine
        // Wiederholung: Die bestehende Menüfrist entscheidet anschließend.
        do {
            guard let data = try read("reply.json") else { return nil }
            return try Self.validateReply(data, binding: binding, nonce: nonce, rootTitle: rootTitle)
        } catch { return nil }
    }
}

private func invalid(_ detail: String) -> NSError {
    NSError(domain: "SelfTestMenuRootExchange", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Ungültiger Menüroot-Austausch: " + detail])
}
