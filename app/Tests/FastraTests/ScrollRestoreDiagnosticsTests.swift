import Foundation
import Testing
@testable import Fastra

@Suite("Fensterlokale Ausschnittdiagnose")
struct ScrollRestoreDiagnosticsTests {
    @Test("Nachricht entsteht nur für tatsächliche Ausgänge",
          arguments: [false, true], [false, true])
    func evaluatesEachActiveOutput(observerEnabled: Bool, stderrEnabled: Bool) {
        var evaluations = 0
        var events: [String] = []
        let diagnostics = ScrollRestoreDiagnostics(isStandardErrorEnabled: {
            events.append("flag")
            return stderrEnabled
        }, writeStandardError: { events.append($0) })
        if observerEnabled {
            diagnostics.observer = { events.append("observer:" + $0) }
        }
        func message() -> String {
            evaluations += 1
            return "message-\(evaluations)"
        }

        diagnostics.emit(message())

        #expect(evaluations == (observerEnabled ? 1 : 0) + (stderrEnabled ? 1 : 0))
        var expected: [String] = []
        if observerEnabled { expected.append("observer:message-1") }
        expected.append("flag")
        if stderrEnabled {
            expected.append("SCROLLRESTORE message-\(observerEnabled ? 2 : 1)\n")
        }
        #expect(events == expected)
    }

    @Test("Observerwechsel und stderr-Entscheidung bleiben aktuell")
    func observerRunsBeforeDynamicStderrDecision() {
        var enabled = false
        var messages: [String] = []
        let diagnostics = ScrollRestoreDiagnostics(isStandardErrorEnabled: { enabled },
            writeStandardError: { messages.append($0) })
        diagnostics.observer = { message in
            messages.append("first:" + message)
            enabled = true
        }
        diagnostics.emit("one")
        diagnostics.observer = { messages.append("second:" + $0) }
        diagnostics.emit("two")
        diagnostics.observer = nil
        enabled = false
        diagnostics.emit("unused")
        #expect(messages == ["first:one", "SCROLLRESTORE one\n",
                             "second:two", "SCROLLRESTORE two\n"])
    }

    @Test("Unabhängige Empfänger verändern einander nicht")
    func observersAreIndependent() {
        let first = ScrollRestoreDiagnostics(isStandardErrorEnabled: { false })
        let second = ScrollRestoreDiagnostics(isStandardErrorEnabled: { false })
        var firstMessages: [String] = [], secondMessages: [String] = []
        first.observer = { firstMessages.append($0) }
        second.observer = { secondMessages.append($0) }
        first.emit("first")
        first.observer = nil
        second.emit("second")
        #expect(firstMessages == ["first"])
        #expect(secondMessages == ["second"])
    }
}
