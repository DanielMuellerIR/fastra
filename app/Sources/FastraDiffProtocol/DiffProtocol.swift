import Foundation
import CoreFoundation
import Darwin

/// Der öffentliche Aufrufvertrag ist unabhängig von der Produktversion.
public enum DiffProtocol {
    public static let version = 1
    public static let timeout: TimeInterval = 10
    public static let maximumMessageSize = 65_536
    public static let capabilities = "{\"protocol\":1,\"fileDiff\":true,\"readOnly\":true,\"focusDiff\":true,\"labels\":true,\"existingInstanceIpc\":true}"

    public static func endpoint(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).diff.v1.\(getuid())"
    }
}

public struct DiffFailure: Error, Equatable {
    public let code: Int32
    public let diagnostic: String
    public init(_ code: Int32, _ diagnostic: String) {
        self.code = code
        self.diagnostic = diagnostic
    }
    public static let arguments = DiffFailure(2, "Expected options followed by -- and exactly two file paths.")
    public static let file = DiffFailure(3, "An input is missing, unreadable, or not a regular file.")
    public static let unsupported = DiffFailure(4, "Unsupported protocol option or version.")
    public static let launch = DiffFailure(5, "Fastra could not be started.")
    public static let delivery = DiffFailure(6, "Fastra rejected the request or did not confirm it before the deadline.")
}

public struct DiffInvocation: Equatable {
    public let leftPath: String
    public let rightPath: String
    public let leftLabel: String
    public let rightLabel: String
    public let readOnly: Bool
    public let focusDiff: Bool

    public static func parse(_ arguments: [String], directory: URL) throws -> DiffInvocation? {
        if arguments == ["--capabilities", "--json"] { return nil }
        var labels: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < arguments.count, arguments[index] != "--" {
            let option = arguments[index]
            switch option {
            case "--read-only", "--focus-diff":
                guard flags.insert(option).inserted else { throw DiffFailure.arguments }
                index += 1
            case "--left-label", "--right-label":
                guard labels[option] == nil, index + 1 < arguments.count else {
                    throw DiffFailure.arguments
                }
                labels[option] = arguments[index + 1]
                index += 2
            default:
                throw option.hasPrefix("--") ? DiffFailure.unsupported : DiffFailure.arguments
            }
        }
        guard index < arguments.count, arguments.count - index == 3 else {
            throw DiffFailure.arguments
        }
        let paths = Array(arguments.suffix(2))
        guard paths.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
              labels.values.allSatisfy({ !$0.contains("\0") }) else { throw DiffFailure.arguments }
        // Relative Pfade gehören zum Aufrufer, nie zum Arbeitsordner der App.
        let urls = paths.map { URL(fileURLWithPath: $0, relativeTo: directory).absoluteURL }
        return DiffInvocation(leftPath: urls[0].path, rightPath: urls[1].path,
                              leftLabel: labels["--left-label"] ?? urls[0].lastPathComponent,
                              rightLabel: labels["--right-label"] ?? urls[1].lastPathComponent,
                              readOnly: flags.contains("--read-only"),
                              focusDiff: flags.contains("--focus-diff"))
    }
}

public struct DiffWireRequest: Codable, Equatable {
    public var version: Int
    public var id: UUID
    public var deadline: TimeInterval
    public var leftPath: String
    public var rightPath: String
    public var leftLabel: String
    public var rightLabel: String
    public var readOnly: Bool
    public var focusDiff: Bool

    public init(_ invocation: DiffInvocation, now: Date = Date()) {
        version = DiffProtocol.version
        id = UUID()
        deadline = now.timeIntervalSince1970 + DiffProtocol.timeout
        leftPath = invocation.leftPath
        rightPath = invocation.rightPath
        leftLabel = invocation.leftLabel
        rightLabel = invocation.rightLabel
        readOnly = invocation.readOnly
        focusDiff = invocation.focusDiff
    }

    public func validate(now: Date = Date()) throws {
        guard version == DiffProtocol.version else { throw DiffFailure.unsupported }
        guard deadline.isFinite, deadline > now.timeIntervalSince1970,
              deadline <= now.timeIntervalSince1970 + DiffProtocol.timeout + 1 else {
            throw DiffFailure.delivery
        }
        for path in [leftPath, rightPath] {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw DiffFailure.arguments }
            // open + fstat folgt Symlinks und weist FIFO/Verzeichnis ab, ohne
            // an einer FIFO auf einen Schreiber zu warten oder Inhalte zu laden.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw DiffFailure.file }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw DiffFailure.file
            }
        }
    }
}

public struct DiffWireReply: Codable {
    public let code: Int32
    public let processIdentifier: Int32
    public init(code: Int32) { self.code = code; processIdentifier = getpid() }
}

/// Benannter Mach-Port innerhalb der Nutzersitzung: kein Netzwerk-Socket.
public final class DiffMessageServer {
    private var port: CFMessagePort?
    private let handler: (Data) -> Data
    private let queue = DispatchQueue(label: "Fastra.externalDiff.ipc")

    public init(name: String, handler: @escaping (Data) -> Data) {
        self.handler = handler
        var context = CFMessagePortContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var shouldFree = DarwinBoolean(false)
        port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            guard let data, let info else { return nil }
            let server = Unmanaged<DiffMessageServer>.fromOpaque(info).takeUnretainedValue()
            let bytes = data as Data
            guard bytes.count <= DiffProtocol.maximumMessageSize else { return nil }
            return Unmanaged.passRetained(server.handler(bytes) as CFData)
        }, &context, &shouldFree)
        if let port { CFMessagePortSetDispatchQueue(port, queue) }
    }
    public var isListening: Bool { port != nil }
    deinit { if let port { CFMessagePortInvalidate(port) } }
}

public enum DiffMessageClient {
    public static func isAvailable(_ name: String) -> Bool {
        CFMessagePortCreateRemote(nil, name as CFString) != nil
    }

    public static func send(_ data: Data, to name: String, timeout: TimeInterval) -> DiffWireReply? {
        guard timeout > 0, data.count <= DiffProtocol.maximumMessageSize,
              let port = CFMessagePortCreateRemote(nil, name as CFString) else { return nil }
        var response: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 1, data as CFData, min(timeout / 2, 0.25),
                                             min(timeout / 2, 0.25), CFRunLoopMode.defaultMode.rawValue, &response)
        guard status == kCFMessagePortSuccess, let response else { return nil }
        return try? JSONDecoder().decode(DiffWireReply.self, from: response.takeRetainedValue() as Data)
    }
}
