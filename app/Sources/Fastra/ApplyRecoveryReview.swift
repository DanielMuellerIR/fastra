import Foundation

/// Nur eine vollständig darstellbare Sitzung kann die Schreibaktion freigeben.
/// Die Einzeldateigrenzen des Readers ersetzen kein gemeinsames Diffbudget.
struct ApplyRecoveryReview {
    let preview: ApplyRecoveryPreview
    let differences: [Int: ApplyRecoveryPreview.Difference]

    static func build(observation: ApplyRecoverySessionReader.Observation, roots: [URL],
                      limits: ApplyRecoveryPreview.Limits = .init(),
                      maximumDisplayBytes: Int = 32 * 1024 * 1024,
                      isCancelled: @escaping () -> Bool = { false }) throws -> Self {
        let preview = try ApplyRecoveryPreview.build(observation: observation, selectedRoots: roots,
                                                     limits: limits, isCancelled: isCancelled)
        var differences: [Int: ApplyRecoveryPreview.Difference] = [:]
        var remaining = maximumDisplayBytes
        for (index, target) in preview.targets.enumerated() where target.state == .restore {
            if isCancelled() { throw CancellationError() }
            let difference = try preview.diff(forTargetAt: index, isCancelled: isCancelled)
            guard let result = difference.document.result else { throw ApplyRecoveryPreview.Failure.incompleteDiff }
            for row in result.rows {
                let bytes = (row.before?.utf8.count ?? 0) + (row.after?.utf8.count ?? 0)
                guard bytes <= remaining else { throw ApplyRecoveryPreview.Failure.limit }
                remaining -= bytes
            }
            differences[index] = difference
        }
        return Self(preview: preview, differences: differences)
    }
}
