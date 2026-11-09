import Foundation
@main struct Probe {
    static func main() throws {
        for input in [Data(), Data("Grüße e\u{301} 😀\r\n".utf8), Data(repeating: 65, count: 1024*1024)] {
            let output = try copyBytes(input: input, mode: 0)
            precondition(output == input)
            print("PASS UniFFI owned bytes \(input.count)")
        }
        let token = ProbeCancellation()
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { _ = try slowCopy(input: Data("active request".utf8), cancellation: token) }
            catch { cancelled.signal() }
        }
        let deadline = Date().addingTimeInterval(2)
        while !token.wasStarted() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        precondition(token.wasStarted())
        token.cancel()
        precondition(cancelled.wait(timeout: .now() + 2) == .success)
        print("PASS UniFFI cancellation during active Rust request")
        for (input,mode) in [(Data([255]), UInt8(0)),(Data([65]),1),(Data([65]),2)] {
            var caught = false
            do { _ = try copyBytes(input: input, mode: mode) } catch { caught = true }
            precondition(caught)
            print("PASS UniFFI invalid/cancel/panic \(mode)")
        }
    }
}
