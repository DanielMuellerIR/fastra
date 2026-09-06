// SearchPerformanceProbeTests.swift
// Der Messlauf ohne Aufrufparameter muss sagen, WAS fehlt — nicht „Datei
// existiert nicht".

import Foundation
import Testing
@testable import Fastra

@Test("Suchmessung ohne Umgebungsvariablen nennt beide Variablen")
func searchPerformanceProbeNamesMissingVariables() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["FASTRA_SEARCH_PERF_INPUT"] == nil,
          environment["FASTRA_SEARCH_PERF_OUTPUT"] == nil else { return }
    let error = #expect(throws: SearchPerformanceProbe.ConfigurationError.self) {
        _ = try SearchPerformanceProbe.run()
    }
    let message = try #require(error?.errorDescription)
    #expect(message.contains("FASTRA_SEARCH_PERF_INPUT"))
    #expect(message.contains("FASTRA_SEARCH_PERF_OUTPUT"))
    #expect(!message.contains("doesn’t exist"))
}
