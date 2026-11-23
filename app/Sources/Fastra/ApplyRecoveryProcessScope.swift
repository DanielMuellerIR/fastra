import Darwin
import Foundation

/// Frühere Fastra-Fassungen kennen keinen Anspruch auf das Sitzungsverzeichnis.
/// Ein Prozess, der bei dessen Anlage bereits lief, kann es noch im RAM halten.
/// Auch später gestartete alte Fassungen können die Ablage ohne unseren Claim
/// bereinigen. Historische Wiederherstellung verlangt daher eine Einzelinstanz.
enum ApplyRecoveryProcessScope {
    enum Rejection: Error, Equatable {
        case unreadableProcessList
        case currentProcessSession
        case possibleLiveOwner
    }

    struct Owner: Equatable {
        let pid: pid_t
        let startedAt: Date
    }

    struct Observation {
        let current: Owner
        let otherFastraProcesses: [Owner]

        func validate(sessionCreatedAt: Date) throws {
            guard sessionCreatedAt < current.startedAt else {
                throw Rejection.currentProcessSession
            }
            guard otherFastraProcesses.isEmpty else {
                throw Rejection.possibleLiveOwner
            }
        }
    }

    // Der ausgelieferte App-Prozess heißt auch beim direkten Start des
    // Bundle-Executables "Fastra". Die UID-Abfrage erfasst ihn ohne AppKit.
    static func capture(processName: String = "Fastra") throws -> Observation {
        let entries = try localProcessList()
        let currentPID = getpid()
        guard let currentEntry = entries.first(where: { $0.kp_proc.p_pid == currentPID }),
              let current = owner(currentEntry) else {
            throw Rejection.unreadableProcessList
        }
        var others: [Owner] = []
        for entry in entries where entry.kp_proc.p_pid != currentPID && entry.kp_proc.p_stat != SZOMB {
            var command = entry.kp_proc.p_comm
            let name = withUnsafeBytes(of: &command) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard name == processName else { continue }
            guard let candidate = owner(entry) else { throw Rejection.unreadableProcessList }
            others.append(candidate)
        }
        return Observation(current: current, otherFastraProcesses: others)
    }

    private static func localProcessList() throws -> ArraySlice<kinfo_proc> {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: geteuid())]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var byteCount = 0
            guard sysctl(&query, UInt32(query.count), nil, &byteCount, nil, 0) == 0,
                  byteCount > 0 else { break }
            // Zwischen den beiden Aufrufen können Prozesse hinzukommen.
            let capacity = byteCount / stride + 32
            var entries = [kinfo_proc](repeating: .init(), count: capacity)
            byteCount = capacity * stride
            if sysctl(&query, UInt32(query.count), &entries, &byteCount, nil, 0) == 0 {
                guard byteCount.isMultiple(of: stride), byteCount > 0,
                      byteCount / stride <= capacity else { break }
                return entries.prefix(byteCount / stride)
            }
            guard errno == ENOMEM else { break }
        }
        throw Rejection.unreadableProcessList
    }

    private static func owner(_ entry: kinfo_proc) -> Owner? {
        let seconds = entry.kp_proc.p_starttime.tv_sec
        let microseconds = entry.kp_proc.p_starttime.tv_usec
        guard entry.kp_proc.p_pid > 0, seconds > 0, (0..<1_000_000).contains(microseconds) else {
            return nil
        }
        return Owner(pid: entry.kp_proc.p_pid,
            startedAt: Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000))
    }
}
