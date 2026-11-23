import Darwin
import Foundation
import Testing
@testable import Fastra

@Test("Historische Wiederherstellung weist jede beobachtete zweite Fastra-Instanz ab")
func applyRecoveryProcessScopeUsesSessionBirth() throws {
    typealias Scope = ApplyRecoveryProcessScope
    let observation = Scope.Observation(
        current: Scope.Owner(pid: 30, startedAt: Date(timeIntervalSince1970: 30)),
        otherFastraProcesses: [Scope.Owner(pid: 20, startedAt: Date(timeIntervalSince1970: 20))])

    #expect(throws: Scope.Rejection.possibleLiveOwner) {
        try observation.validate(sessionCreatedAt: Date(timeIntervalSince1970: 19))
    }
    try Scope.Observation(current: observation.current, otherFastraProcesses: [])
        .validate(sessionCreatedAt: Date(timeIntervalSince1970: 19))
    #expect(throws: Scope.Rejection.possibleLiveOwner) {
        try observation.validate(sessionCreatedAt: Date(timeIntervalSince1970: 20))
    }
    #expect(throws: Scope.Rejection.currentProcessSession) {
        try observation.validate(sessionCreatedAt: Date(timeIntervalSince1970: 30))
    }
}

@Test("Kernel-Prozessliste findet einen eigenen direkt gestarteten Prozess")
func applyRecoveryProcessScopeObservesDirectLaunch() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    try child.run()
    defer {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }

    let observed = try ApplyRecoveryProcessScope.capture(processName: "sleep")
    #expect(observed.current.pid == getpid())
    let candidate = try #require(observed.otherFastraProcesses.first { $0.pid == child.processIdentifier })
    #expect(candidate.startedAt >= observed.current.startedAt)
}
