import AppKit
import CodeEditTextView
import Foundation

struct SelfTestProjectPerformance {
    private let finish: (SelfTestOutcome, String) -> Never
    private let editorTextView: (NSView) -> NSView?

    init(finish: @escaping (SelfTestOutcome, String) -> Never,
         editorTextView: @escaping (NSView) -> NSView?) {
        self.finish = finish
        self.editorTextView = editorTextView
    }

    private struct PerformanceResourceSnapshot {
        let userSeconds: Double
        let systemSeconds: Double
        let maximumRSSMiB: Double
    }

    private func performanceResourceSnapshot() -> PerformanceResourceSnapshot {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return PerformanceResourceSnapshot(
                userSeconds: 0, systemSeconds: 0, maximumRSSMiB: 0
            )
        }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return PerformanceResourceSnapshot(
            userSeconds: seconds(usage.ru_utime),
            systemSeconds: seconds(usage.ru_stime),
            // Auf Darwin ist ru_maxrss die maximale Resident-Menge in Bytes.
            maximumRSSMiB: Double(usage.ru_maxrss) / 1_048_576
        )
    }

    private func projectPerformanceRoot() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["FASTRA_PROJECT_PERF_ROOT"],
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).canonicalFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return url
    }

    /// Ein Warm-up plus drei echte Läufe durch denselben FolderSearch-Pfad,
    /// den die Projekt-Suche verwendet. Dieser Diagnosemodus schreibt nichts
    /// ins übergebene Projekt und liegt absichtlich außerhalb von ALL_TESTS.
    func runSearch() {
        guard let root = projectPerformanceRoot() else {
            // Fehlender Realbestand verhindert den Test (Umgebung, Exit 2), wie bei
            // `tool4dlsp`; er ist kein Produkt-FAIL.
            finish(.environment, "Umgebungsproblem: FASTRA_PROJECT_PERF_ROOT fehlt oder ist kein Ordner")
        }
        let exclusions = [".json", "userPreferences.*", "DerivedData"]
        let matcher = PathExclusion.Matcher(patterns: exclusions, relativeTo: root)
        let allFiles: [URL]
        let ripgrepFiltered: [URL]
        do {
            allFiles = try RipgrepFileEnumerator.files(in: root)
            ripgrepFiltered = try RipgrepFileEnumerator.files(
                in: root, excludedPatterns: exclusions
            )
        } catch {
            finish(.fail, "Kandidatenliste fehlgeschlagen: \(error)")
        }
        let candidates = ripgrepFiltered.filter { !matcher.matches($0) }
        let textCandidates = candidates.filter {
            FolderSearch.passesFilter(url: $0, filter: .knownText)
        }
        func hasDerivedData(_ url: URL) -> Bool {
            url.pathComponents.contains("DerivedData")
        }
        let jsonCount = allFiles.filter { $0.pathExtension == "json" }.count
        let preferencesCount = allFiles.filter {
            $0.pathComponents.contains {
                $0.hasPrefix("userPreferences.")
            }
        }.count
        let derivedDataCount = allFiles.filter(hasDerivedData).count
        let leakedJSON = candidates.contains { $0.pathExtension == "json" }
        let leakedPreferences = candidates.contains {
            $0.pathComponents.contains {
                $0.hasPrefix("userPreferences.")
            }
        }
        let leakedDerivedData = candidates.contains(where: hasDerivedData)
        guard !allFiles.isEmpty, candidates.count < allFiles.count,
              jsonCount > 0, preferencesCount > 0, derivedDataCount > 0,
              !leakedJSON, !leakedPreferences, !leakedDerivedData else {
            finish(.fail, "Ausschlussinventar fehlerhaft: alle=\(allFiles.count), "
                + "Kandidaten=\(candidates.count), json=\(jsonCount), "
                + "userPreferences=\(preferencesCount), DerivedData=\(derivedDataCount), "
                + "Leaks=\(leakedJSON)/\(leakedPreferences)/\(leakedDerivedData)")
        }

        let inventory = String(
            format: "PROJECTPERF inventory all=%d candidates=%d text_candidates=%d "
                + "search_filter=all "
                + "json_excluded=%d user_preferences_excluded=%d "
                + "derived_data_excluded=%d\n",
            allFiles.count, candidates.count, textCandidates.count, jsonCount,
            preferencesCount, derivedDataCount
        )
        FileHandle.standardError.write(Data(inventory.utf8))

        let options = SearchOptions(
            find: "util_*", replace: "", isRegex: false,
            caseSensitive: false, wholeWord: false,
            treatWildcardLiterally: false
        )
        let warmupError: String? = autoreleasepool {
            FolderSearch.find(
                in: [root], filter: .all, options: options,
                excludedPatterns: exclusions, relativeTo: root
            ).invalidPatternMessage
        }
        guard warmupError == nil else {
            finish(.fail, "Warm-up fehlgeschlagen: \(warmupError ?? "")")
        }

        var wallTimes: [Double] = []
        var lastMatches = 0
        for run in 1...3 {
            let measurement = autoreleasepool { () -> (
                wall: Double, matches: Int, capped: Bool, error: String?,
                userCPU: Double, systemCPU: Double, maximumRSSMiB: Double
            ) in
                let resourcesBefore = performanceResourceSnapshot()
                let started = ProcessInfo.processInfo.systemUptime
                let result = FolderSearch.find(
                    in: [root], filter: .all, options: options,
                    excludedPatterns: exclusions, relativeTo: root
                )
                let wall = ProcessInfo.processInfo.systemUptime - started
                let resourcesAfter = performanceResourceSnapshot()
                return (
                    wall, result.totalMatches, result.wasCapped,
                    result.invalidPatternMessage,
                    resourcesAfter.userSeconds - resourcesBefore.userSeconds,
                    resourcesAfter.systemSeconds - resourcesBefore.systemSeconds,
                    resourcesAfter.maximumRSSMiB
                )
            }
            guard measurement.error == nil else {
                finish(.fail, "Lauf \(run) fehlgeschlagen: "
                    + (measurement.error ?? "unbekannt"))
            }
            wallTimes.append(measurement.wall)
            lastMatches = measurement.matches
            let line = String(
                format: "PROJECTPERF run=%d candidates=%d matches=%d capped=%@ "
                    + "wall_s=%.4f user_cpu_s=%.4f system_cpu_s=%.4f "
                    + "max_rss_mib=%.1f\n",
                run, candidates.count, measurement.matches,
                measurement.capped ? "yes" : "no", measurement.wall,
                measurement.userCPU, measurement.systemCPU,
                measurement.maximumRSSMiB
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
        let median = wallTimes.sorted()[1]
        guard median < 1.5 else {
            finish(.fail, String(
                format: "Median %.4f s verfehlt Ziel <1,5 s "
                    + "(Kandidaten=%d, Treffer=%d)",
                median, candidates.count, lastMatches
            ))
        }
        finish(.pass, String(
            format: "3 warme Realprojekt-Läufe, Median %.4f s (<1,5 s), "
                + "%d Kandidaten, %d Treffer; Ausschlüsse leakfrei",
            median, candidates.count, lastMatches
        ))
    }

    /// Misst `folders.json` unabhängig vom Suchlauf vom Workspace-Aufruf bis
    /// zum tatsächlich montierten Editor-Text. Ein schneller Befund belegt,
    /// dass die beobachtete Wartezeit aus dem Suchscan statt aus FileLoader/
    /// Editor stammt; nur eine eigenständig langsame Messung rechtfertigt hier
    /// einen zusätzlichen Ladepfad-Fix.
    func runOpen(workspace ws: Workspace, contentView: () -> NSView?) {
        guard let root = projectPerformanceRoot() else {
            finish(.environment, "Umgebungsproblem: FASTRA_PROJECT_PERF_ROOT "
                   + "fehlt oder ist kein Ordner")
        }
        guard let view = contentView() else {
            finish(.fail, "sichtbares Hauptfenster mit contentView fehlt")
        }
        let file = root.appendingPathComponent("Project/Sources/folders.json")
            .canonicalFileURL
        guard let expected = try? String(contentsOf: file, encoding: .utf8) else {
            finish(.fail, "Project/Sources/folders.json ist nicht UTF-8-lesbar")
        }

        ws.openProject(at: root)
        let resourcesBefore = performanceResourceSnapshot()
        let started = ProcessInfo.processInfo.systemUptime
        ws.loadFile(at: file) { ok in
            let callbackSeconds = ProcessInfo.processInfo.systemUptime - started
            guard ok else {
                ws.closeProject()
                finish(.fail, "Workspace.loadFile meldete Fehler")
            }
            pollProjectOpenPerformance(
                ws: ws, root: view, expected: expected, file: file,
                started: started, callbackSeconds: callbackSeconds,
                resourcesBefore: resourcesBefore, tick: 0
            )
        }
    }

    private func pollProjectOpenPerformance(
        ws: Workspace,
        root: NSView,
        expected: String,
        file: URL,
        started: TimeInterval,
        callbackSeconds: TimeInterval,
        resourcesBefore: PerformanceResourceSnapshot,
        tick: Int
    ) {
        if ws.activeTab?.url == file, ws.activeTab?.isLoading == false,
           let textView = editorTextView(root) as? TextView,
           textView.string == expected {
            let renderedSeconds = ProcessInfo.processInfo.systemUptime - started
            let resourcesAfter = performanceResourceSnapshot()
            let line = String(
                format: "PROJECTOPEN file_bytes=%d load_callback_s=%.4f "
                    + "editor_rendered_s=%.4f user_cpu_s=%.4f "
                    + "system_cpu_s=%.4f max_rss_mib=%.1f\n",
                expected.utf8.count, callbackSeconds, renderedSeconds,
                resourcesAfter.userSeconds - resourcesBefore.userSeconds,
                resourcesAfter.systemSeconds - resourcesBefore.systemSeconds,
                resourcesAfter.maximumRSSMiB
            )
            FileHandle.standardError.write(Data(line.utf8))
            ws.closeProject()
            guard renderedSeconds < 1.5 else {
                finish(.fail, String(
                    format: "folders.json brauchte bis zum Editor %.4f s", renderedSeconds
                ))
            }
            finish(.pass, String(
                format: "folders.json separat: Load %.4f s, Editor %.4f s (<1,5 s)",
                callbackSeconds, renderedSeconds
            ))
        }
        if tick >= 200 {
            ws.closeProject()
            finish(.fail, "folders.json nach 5 s nicht im Editor montiert")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            pollProjectOpenPerformance(
                ws: ws, root: root, expected: expected, file: file,
                started: started, callbackSeconds: callbackSeconds,
                resourcesBefore: resourcesBefore, tick: tick + 1
            )
        }
    }
}
