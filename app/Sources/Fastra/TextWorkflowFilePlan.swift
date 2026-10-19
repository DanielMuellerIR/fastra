import Foundation

/// Unveränderliche Vorschau für einen vollständigen Satz von Plattendateien.
/// Auch wirkungslose Eingaben bleiben Teil der späteren Konfliktprüfung.
struct TextWorkflowFilePlan: Sendable {
    struct Input: Sendable {
        let url: URL
        var encoding: String.Encoding? = nil
    }

    struct File: Sendable {
        let requestedURL: URL
        let url: URL
        let snapshot: FileSnapshot
        let originalBytes: Data
        let newBytes: Data
        let encoding: String.Encoding
        let bom: Data
        let preview: TextWorkflowEngine.Preview
        var changed: Bool { originalBytes != newBytes }
    }

    struct Limits: Sendable {
        var files = 500
        var originalBytes = 64 * 1024 * 1024
        var outputBytes = 64 * 1024 * 1024
        var previewBytes = 64 * 1024 * 1024
        var seconds: TimeInterval = 60
        var engine = TextWorkflowEngine.Limits.standard
        static let standard = Limits()
    }

    enum Failure: Error, LocalizedError, Equatable {
        case empty, noChanges, sizeLimit, cancelled, timeout
        case duplicateInput(URL)
        case unreadable(URL)
        case readOnly(URL)
        case binary(URL)
        case encodingConflict(URL)
        case unsupportedEncoding(URL)
        case undecodable(URL)
        case unrepresentable(URL)
        case processing(URL, TextWorkflowError)
        var errorDescription: String? { TextWorkflowFailure.message(self) }
    }

    let workflow: TextWorkflow
    let files: [File]
    var changedFileCount: Int { files.filter(\.changed).count }

    private init(workflow: TextWorkflow, files: [File]) {
        self.workflow = workflow
        self.files = files
    }

    /// Nur bereits geprüfte Pläne dürfen zur gemeinsamen Schreibbasis
    /// werden. Der Aufrufer kann keine freien Nachherbytes einschleusen.
    static func combining(_ plans: [Self]) throws -> Self {
        guard let first = plans.first else { throw Failure.empty }
        let files = plans.flatMap(\.files), limits = Limits.standard
        guard plans.allSatisfy({ $0.workflow == first.workflow }), files.count <= limits.files,
              Set(files.map(\.url)).count == files.count else { throw Failure.sizeLimit }
        let identities = files.compactMap { $0.snapshot.identity }
        guard Set(identities).count == identities.count else { throw Failure.duplicateInput(files[0].requestedURL) }
        var original = limits.originalBytes, output = limits.outputBytes, preview = limits.previewBytes
        for file in files {
            guard let retained = file.preview.retainedUTF8Bytes, file.originalBytes.count <= original,
                  file.newBytes.count <= output, retained <= preview else { throw Failure.sizeLimit }
            original -= file.originalBytes.count; output -= file.newBytes.count; preview -= retained
        }
        return Self(workflow: first.workflow, files: files)
    }

    static func build(_ workflow: TextWorkflow, inputs: [Input], limits: Limits = .standard,
                      shouldCancel: () -> Bool = { false },
                      progress: (ApplyTransaction.Progress) -> Void = { _ in }) throws -> Self {
        guard !inputs.isEmpty else { throw Failure.empty }
        let standard = Limits.standard
        guard inputs.count <= min(limits.files, standard.files),
              limits.originalBytes >= 0, limits.outputBytes >= 0, limits.previewBytes >= 0,
              limits.engine.textBytes >= 0 else { throw Failure.sizeLimit }
        try TextWorkflowEngine.validate(workflow)
        let deadline = ProcessInfo.processInfo.systemUptime + min(limits.seconds, standard.seconds)
        func check() throws {
            if shouldCancel() { throw Failure.cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { throw Failure.timeout }
        }
        var remainingOriginal = min(limits.originalBytes, standard.originalBytes)
        var remainingOutput = min(limits.outputBytes, standard.outputBytes)
        var remainingPreview = min(limits.previewBytes, standard.previewBytes)
        var engineLimits = limits.engine
        engineLimits.textBytes = min(engineLimits.textBytes, standard.engine.textBytes)
        engineLimits.intermediateBytes = min(engineLimits.intermediateBytes, standard.engine.intermediateBytes)
        engineLimits.retainedBytes = min(engineLimits.retainedBytes, standard.engine.retainedBytes)
        engineLimits.matches = min(engineLimits.matches, standard.engine.matches)
        engineLimits.seconds = min(engineLimits.seconds, standard.engine.seconds)
        var paths = Set<URL>(), identities = Set<FileIdentity>(), files: [File] = []
        for (index, input) in inputs.enumerated() {
            try check()
            let requested = input.url.standardizedFileURL, url = requested.canonicalFileURL
            guard input.url.isFileURL else { throw Failure.unreadable(requested) }
            guard paths.insert(url).inserted else { throw Failure.duplicateInput(requested) }
            // UTF-32 braucht für denselben Text bis zu viermal so viele Bytes.
            // Der sichere Reader prüft die Grenze vor seiner Allokation.
            let readLimit = min(remainingOriginal, engineLimits.textBytes * 4 + 4)
            let original: (data: Data, snapshot: FileSnapshot)
            do { original = try FileSnapshot.read(from: url, byteLimit: UInt64(readLimit)) }
            catch FileSnapshotReadError.tooLarge { throw Failure.sizeLimit }
            catch { throw Failure.unreadable(requested) }
            guard requested.canonicalFileURL == url else { throw Failure.unreadable(requested) }
            if let identity = original.snapshot.identity, !identities.insert(identity).inserted {
                throw Failure.duplicateInput(requested)
            }
            remainingOriginal -= original.data.count
            let (bom, bomEncoding) = ApplyEngine.detectBOM(in: original.data)
            let payload = Data(original.data.dropFirst(bom.count))
            let text: String, encoding: String.Encoding
            if let forced = input.encoding {
                encoding = FileLoader.explicitBodyEncoding(forced, bomEncoding: bomEncoding)
                guard supported(encoding) else { throw Failure.unsupportedEncoding(requested) }
                guard bomEncoding == nil || bomEncoding == encoding else { throw Failure.encodingConflict(requested) }
                guard payload.count <= engineLimits.textBytes * width(encoding) else { throw Failure.sizeLimit }
                guard width(encoding) > 1 || !payload.contains(0) else { throw Failure.binary(requested) }
                guard let decoded = ApplyEngine.decode(payload: payload, encoding: encoding) else { throw Failure.undecodable(requested) }
                text = decoded
            } else {
                guard bomEncoding != nil || !payload.contains(0) else { throw Failure.binary(requested) }
                guard payload.count <= engineLimits.textBytes * width(bomEncoding ?? .utf8) else { throw Failure.sizeLimit }
                guard let decoded = ApplyEngine.decode(payload: payload, bomEncoding: bomEncoding) else { throw Failure.undecodable(requested) }
                (text, encoding) = decoded
            }
            guard let roundTrip = text.data(using: encoding, allowLossyConversion: false), roundTrip == payload else {
                throw Failure.undecodable(requested)
            }
            try check()
            engineLimits.previewBytes = min(remainingPreview, limits.engine.previewBytes ?? remainingPreview)
            let preview: TextWorkflowEngine.Preview
            do {
                preview = try TextWorkflowEngine.preview(workflow, source: text, limits: engineLimits,
                    shouldCancel: { shouldCancel() || ProcessInfo.processInfo.systemUptime > deadline })
            } catch let error as TextWorkflowError {
                try check()
                throw Failure.processing(requested, error)
            }
            guard let retained = preview.retainedUTF8Bytes, retained <= remainingPreview else { throw Failure.sizeLimit }
            remainingPreview -= retained
            // Die Ausgabegrenze gilt schon vor der Kodierung; eine nicht
            // darstellbare Ersetzung darf keine verlustbehafteten Bytes liefern.
            let outputSize = ApplyEngine.encodedSize(preview.output, encoding: encoding) + bom.count
            guard outputSize <= remainingOutput else { throw Failure.sizeLimit }
            guard let body = preview.output.data(using: encoding, allowLossyConversion: false),
                  let decoded = ApplyEngine.decode(payload: body, encoding: encoding),
                  decoded.utf8.elementsEqual(preview.output.utf8) else { throw Failure.unrepresentable(requested) }
            var bytes = bom
            bytes.append(body)
            guard bytes.count == outputSize else { throw Failure.unrepresentable(requested) }
            if bytes != original.data { try requireWritable(url) }
            remainingOutput -= bytes.count
            files.append(File(requestedURL: requested, url: url, snapshot: original.snapshot,
                              originalBytes: original.data, newBytes: bytes, encoding: encoding,
                              bom: bom, preview: preview))
            progress(ApplyTransaction.Progress(phase: .planned, completedFiles: index + 1,
                                              totalFiles: inputs.count, fileName: requested.lastPathComponent))
        }
        try check()
        return Self(workflow: workflow, files: files)
    }

    static func requireWritable(_ url: URL) throws {
        let manager = FileManager.default
        guard manager.isWritableFile(atPath: url.path),
              manager.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw Failure.readOnly(url)
        }
    }

    private static func supported(_ encoding: String.Encoding) -> Bool {
        [.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian,
         .windowsCP1252, .isoLatin1, .macOSRoman, .ascii].contains(encoding)
    }

    private static func width(_ encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf16LittleEndian, .utf16BigEndian: return 2
        case .utf32LittleEndian, .utf32BigEndian: return 4
        default: return 1
        }
    }

}
