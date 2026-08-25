// TestWaitingCancellationTests.swift
//
// Regressionstest für den Abbruch des gemeinsamen async-Wartehelfers.

import Testing

@Test("waitUntil beendet einen abgebrochenen Task ohne weitere Prüfungen")
@MainActor
func waitUntilStopsPollingAfterCancellation() async {
    var pollCount = 0

    let result = await Task { @MainActor in
        await waitUntil(timeout: 0.05) {
            pollCount += 1
            if pollCount == 1 {
                // Der Abbruch während der ersten Prüfung macht den Test
                // unabhängig von Scheduler- und Maschinenlast.
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
            return false
        }
    }.value

    #expect(!result)
    #expect(pollCount == 1,
            "Nach dem Abbruch darf waitUntil die Bedingung nicht erneut prüfen")

    var preCancelledPollCount = 0
    let preCancelledResult = await Task { @MainActor in
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return await waitUntil(timeout: 0.05) {
            preCancelledPollCount += 1
            return false
        }
    }.value

    #expect(!preCancelledResult)
    #expect(preCancelledPollCount == 0,
            "Ein bereits abgebrochener Task darf die Bedingung nicht mehr prüfen")

    var cancellingSuccessPollCount = 0
    let cancellingSuccessResult = await Task { @MainActor in
        await waitUntil(timeout: 0.05) {
            cancellingSuccessPollCount += 1
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return true
        }
    }.value

    #expect(!cancellingSuccessResult)
    #expect(cancellingSuccessPollCount == 1,
            "Abbruch während eines erfolgreichen Polls darf nicht als Erfolg gelten")
}
