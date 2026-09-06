import AppKit
import Darwin
import FastraDiffProtocol

func run() throws {
    guard let invocation = try DiffInvocation.parse(Array(CommandLine.arguments.dropFirst()),
        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) else {
        print(DiffProtocol.capabilities)
        return
    }
    let request = DiffWireRequest(invocation)
    try request.validate()
    let data = try JSONEncoder().encode(request)
    guard data.count <= DiffProtocol.maximumMessageSize else { throw DiffFailure.arguments }
    // Der Helfer findet ausschließlich sein umgebendes Bundle; kein Build-Pfad.
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { throw DiffFailure.launch }
    let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let bundle = Bundle(url: appURL), let identifier = bundle.bundleIdentifier else {
        throw DiffFailure.launch
    }
    let endpoint = DiffProtocol.endpoint(bundleIdentifier: identifier)
    let stopAt = ProcessInfo.processInfo.systemUptime + max(0, request.deadline - Date().timeIntervalSince1970)
    var launchRequested = false
    var launchFailed = false
    while ProcessInfo.processInfo.systemUptime < stopAt {
        let remaining = stopAt - ProcessInfo.processInfo.systemUptime
        if let reply = DiffMessageClient.send(data, to: endpoint, timeout: remaining) {
            guard reply.code == 0 else {
                switch reply.code {
                case 2: throw DiffFailure.arguments
                case 3: throw DiffFailure.file
                case 4: throw DiffFailure.unsupported
                default: throw DiffFailure.delivery
                }
            }
            if invocation.focusDiff {
                NSRunningApplication(processIdentifier: reply.processIdentifier)?.activate()
            }
            return
        }
        // Fehlt der Endpunkt JETZT — beim ersten Blick oder weil sich die App
        // zwischen zwei Versuchen beendet hat —, wird genau einmal gestartet.
        // Ein einmaliger Blick vor der Schleife hätte den zweiten Fall
        // verpasst und zehn Sekunden ins Leere gesendet.
        if !launchRequested && !DiffMessageClient.isAvailable(endpoint) {
            launchRequested = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // LaunchServices bündelt gleichzeitige Starts derselben App.
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                DispatchQueue.main.async { launchFailed = error != nil }
            }
        }
        if launchFailed { throw DiffFailure.launch }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.05, max(0, remaining))))
    }
    throw DiffFailure.delivery
}

do {
    try run()
} catch {
    let failure = error as? DiffFailure ?? DiffFailure.delivery
    FileHandle.standardError.write(Data("fastra-diff: \(failure.diagnostic)\n".utf8))
    exit(failure.code)
}
