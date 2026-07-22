//
// RipgrepFileEnumerator.swift
//
// Der gebündelte `rg` liefert ausschließlich Kandidatpfade. Der robuste
// Prozesskern leert stdout/stderr gleichzeitig, begrenzt den behaltenen
// Speicher und besitzt Abbruch sowie Timeout; ein Fehler darf niemals als
// vollständige, still gekürzte Dateiliste erscheinen.

import Foundation

enum RipgrepFileEnumerator {
    enum Failure: Error, Equatable {
        case unavailable
        case failed(String)
        case cancelled
        case timedOut
        case outputLimit
        case captureFailed(String)
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: GitExecutionOutcome?

        func store(_ outcome: GitExecutionOutcome) {
            lock.lock(); value = outcome; lock.unlock()
        }

        func take() -> GitExecutionOutcome? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Liefert reguläre, nicht versteckte Dateien. Nur ein echter
    /// Start-/Ressourcenfehler (`unavailable`) erlaubt dem Aufrufer den
    /// FileManager-Fallback; Abbruch/Timeout dürfen keinen zweiten Vollscan
    /// starten.
    static func files(in root: URL,
                      executableURL override: URL? = nil,
                      timeout: TimeInterval = 30,
                      outputLimit: GitOutputLimit = GitOutputLimit(
                        stdoutBytes: 64 * 1024 * 1024,
                        stderrBytes: 1 * 1024 * 1024),
                      shouldCancel: @escaping @Sendable () -> Bool = { false }) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path,
                                             isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [root] }
        guard let executable = override ?? executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.unavailable
        }
        if shouldCancel() { throw Failure.cancelled }

        let completed = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        let policy = GitExecutionPolicy(timeout: timeout, terminationGracePeriod: 0.25)
        let token = GitRunner.runExecutable(
            executable,
            arguments: ["--files", "--null", "--no-ignore", "--glob", "!.git/**", root.path],
            in: root,
            outputLimit: outputLimit,
            policy: policy,
            completionQueue: DispatchQueue.global(qos: .userInitiated)
        ) { result in
            outcome.store(result)
            completed.signal()
        }

        while completed.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if shouldCancel() { token.cancel() }
        }
        guard let result = outcome.take() else {
            throw Failure.captureFailed("ripgrep lieferte kein Prozessergebnis")
        }
        switch result {
        case .cancelled:
            throw Failure.cancelled
        case .timedOut:
            throw Failure.timedOut
        case .startFailed:
            throw Failure.unavailable
        case .captureFailed(let failure):
            let details = [failure.stdoutError, failure.stderrError]
                .compactMap { $0 }.joined(separator: "\n")
            throw Failure.captureFailed(details)
        case .completed(let processResult):
            guard !processResult.stdoutWasTruncated else { throw Failure.outputLimit }
            // ripgrep verwendet Exit 1 auch für „keine Dateien gefunden“.
            // Nur die vollständig leere, ungekürzte Ausgabe ist deshalb ein
            // gültiger leerer Erfolg; jede Diagnose bleibt ein echter Fehler.
            if processResult.exitCode == 1,
               processResult.stdoutData.isEmpty,
               processResult.stderrData.isEmpty,
               !processResult.stderrWasTruncated {
                return []
            }
            guard processResult.exitCode == 0 else {
                var message = processResult.stderr
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if processResult.stderrWasTruncated {
                    message += message.isEmpty ? "stderr gekürzt" : "\n… stderr gekürzt"
                }
                throw Failure.failed(message)
            }
            var urls: [URL] = []
            for bytes in processResult.stdoutData.split(separator: 0) {
                guard let path = String(bytes: bytes, encoding: .utf8) else {
                    throw Failure.captureFailed("ripgrep lieferte einen ungültigen UTF-8-Pfad")
                }
                urls.append(URL(fileURLWithPath: path))
            }
            return urls
        }
    }

    private static var executableURL: URL? {
        let bundles = [Bundle.main, Bundle.module]
        return bundles.lazy.compactMap {
            $0.url(forResource: "rg", withExtension: nil, subdirectory: "ripgrep")
                ?? $0.url(forResource: "rg", withExtension: nil)
        }.first
    }
}
