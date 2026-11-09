import Foundation

func expectError(_ expected: SearchError, _ body: () throws -> Void) throws {
    do { try body(); fatalError("Expected \(expected)") }
    catch let error as SearchError { precondition(error == expected, "Unexpected \(error)") }
}

@main struct FfiCheck {
    static func main() throws {
        let cancellation = try Cancellation()
        let limits = try defaultSearchLimits()
        let source = "😀 café 12 café 34"
        let request = SearchRequest(pattern: "(café) ([0-9]+)", replacement: "$2:$1", mode: .regex, caseSensitive: true, range: nil)
        let preview = try createPreview(text: source, revision: 42, generation: 9, request: request, limits: limits, cancellation: cancellation)
        let snapshot = try preview.snapshot()
        precondition(snapshot.source == source && snapshot.revision == 42 && snapshot.generation == 9)
        precondition(snapshot.matches.count == 2)
        precondition(snapshot.matches[0].range == Utf16Range(location: 3, length: 7))
        precondition(snapshot.matches[0].captures[1] == Utf16Range(location: 3, length: 4))
        precondition(snapshot.matches[0].replacement == "12:café")
        let output = try preview.apply(current: source, revision: 42, generation: 9, approved: [0, 1], cancellation: cancellation)
        precondition(output == "😀 12:café 34:café")
        for (text, revision, generation) in [(source + "!", UInt64(42), UInt64(9)), (source, 43, 9), (source, 42, 10)] {
            try expectError(.Stale) { _ = try preview.apply(current: text, revision: revision, generation: generation, approved: [], cancellation: cancellation) }
        }
        try expectError(.InvalidApproval) { _ = try preview.apply(current: source, revision: 42, generation: 9, approved: [1, 0], cancellation: cancellation) }
        try expectError(.InvalidApproval) { _ = try preview.apply(current: source, revision: 42, generation: 9, approved: [2], cancellation: cancellation) }
        do {
            _ = try createPreview(text: source, revision: 42, generation: 9, request: SearchRequest(pattern: "(", replacement: "", mode: .regex, caseSensitive: true, range: nil), limits: limits, cancellation: cancellation)
            fatalError("Expected regex error")
        } catch SearchError.Regex(let code, _) { precondition(code != 0) }
        try cancellation.cancel()
        try expectError(.Cancelled) { _ = try preview.apply(current: source, revision: 42, generation: 9, approved: [], cancellation: cancellation) }
        try expectError(.Cancelled) { _ = try createPreview(text: source, revision: 42, generation: 9, request: request, limits: limits, cancellation: cancellation) }
        let runningCancellation = try Cancellation()
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.005)
            try! runningCancellation.cancel()
            cancelled.signal()
        }
        // Das Engine-Budget kann vor dem eingeplanten Abbruch gewinnen.
        do {
            _ = try createPreview(text: String(repeating: "a", count: 30_000) + "!", revision: 0, generation: 0,
                request: SearchRequest(pattern: "(a+)+$", replacement: "", mode: .regex, caseSensitive: true, range: nil),
                limits: limits, cancellation: runningCancellation)
            fatalError("Expected bounded search stop")
        } catch SearchError.Cancelled {
        } catch SearchError.Engine(let code) {
            precondition(code == 66322, "Unexpected engine error: \(code)")
        }
        precondition(cancelled.wait(timeout: .now() + 5) == .success)
        try expectError(.Cancelled) {
            _ = try createPreview(text: source, revision: 42, generation: 9, request: request, limits: limits, cancellation: runningCancellation)
        }
        let large = String(repeating: "😀", count: 262_144)
        let empty = try createPreview(text: large, revision: 0, generation: 0, request: SearchRequest(pattern: "", replacement: "", mode: .literal, caseSensitive: true, range: nil), limits: limits, cancellation: Cancellation())
        let largeSnapshot = try empty.snapshot()
        precondition(largeSnapshot.source == large)
        print("PASS Swift generated bindings: Unicode/captures, approval, stale text/revision/generation, regex error, cancellation, 1 MiB ownership")
    }
}
