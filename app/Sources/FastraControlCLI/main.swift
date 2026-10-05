import AppKit
import Darwin
import FastraControlProtocol
import FastraDiffProtocol

func output(_ reply: ControlReply) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(reply) + Data([10]))
}

func run() throws -> ControlReply {
    var args = Array(CommandLine.arguments.dropFirst())
    let noLaunch = args.first == "--no-launch"
    if noLaunch { args.removeFirst() }
    if args == ["--capabilities", "--json"] {
        return ControlReply(capabilities: ControlProtocol.capabilities)
    }
    guard args == ["--request", "-"] || (args.count == 2 && args[0] == "--request") else {
        throw ControlFailure.invalidRequest
    }
    let handle: FileHandle
    if args[1] == "-" { handle = .standardInput }
    else {
        let descriptor = open(args[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ControlFailure.invalidRequest }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor); throw ControlFailure.invalidRequest
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    defer { if args[1] != "-" { try? handle.close() } }
    var data = Data()
    while data.count <= ControlProtocol.maximumMessageBytes {
        let chunk = try handle.read(upToCount: min(4096, ControlProtocol.maximumMessageBytes + 1 - data.count)) ?? Data()
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    let request = try ControlRequest.decode(data)
    // Ein verloren bestätigter Auftrag darf mit derselben ID nachgefragt
    // werden. Nur der Controller weiß, ob er ihn bereits angenommen hat.
    try request.validate(allowExpired: true)
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { throw ControlFailure.delivery }
    let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let bundle = Bundle(url: appURL), let identifier = bundle.bundleIdentifier else { throw ControlFailure.delivery }
    let endpoint = ControlProtocol.endpoint(bundleIdentifier: identifier)
    let stopAt = ProcessInfo.processInfo.systemUptime + ControlProtocol.requestTimeout
    var launchRequested = false
    var launchFailed = false
    while ProcessInfo.processInfo.systemUptime < stopAt {
        let remaining = stopAt - ProcessInfo.processInfo.systemUptime
        if let bytes = DiffMessageClient.sendData(data, to: endpoint, timeout: remaining),
           let reply = try? JSONDecoder().decode(ControlReply.self, from: bytes) { return reply }
        if noLaunch && !DiffMessageClient.isAvailable(endpoint) { throw ControlFailure.delivery }
        if !noLaunch && !launchRequested && !DiffMessageClient.isAvailable(endpoint) {
            launchRequested = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                DispatchQueue.main.async { launchFailed = error != nil }
            }
        }
        if launchFailed { throw ControlFailure.delivery }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.05, max(0, remaining))))
    }
    throw ControlFailure.delivery
}

do {
    let reply = try run()
    try output(reply)
    exit(reply.error == nil ? 0 : 1)
} catch {
    try? output(ControlReply(error: error as? ControlFailure ?? .invalidRequest))
    exit(1)
}
