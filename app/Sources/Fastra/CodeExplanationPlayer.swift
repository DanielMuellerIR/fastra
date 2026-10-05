import AppKit
import FastraControlProtocol

/// Der Player besitzt nur Darstellung und Fortschritt. Jede Quellennavigation
/// läuft als regulärer Auftrag durch denselben extern erreichbaren Controller.
@MainActor
final class CodeExplanationPlayer: NSObject {
    let package: CodeExplanationPackage
    let view = NSStackView()
    let footer = ExplanationFooterView()
    private let stepTitle = NSTextField(labelWithString: "")
    private let wrapButton = NSButton(checkboxWithTitle: "Soft Wrap", target: nil, action: nil)
    private weak var session: ControlSnapshotWindow?
    private weak var controller: LocalControlController?
    private var documents: [UUID: UUID] = [:]
    private var displayedSource: UUID
    private var observer: Task<Void, Never>?
    private var jobID: UUID?
    private(set) var index = 0
    private(set) var state = "loadingStep"
    private let progress = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let codeSizeLabel = NSTextField(labelWithString: "")
    private let textSizeLabel = NSTextField(labelWithString: "")
    private let stepList = NSPopUpButton(frame: .zero, pullsDown: false)
    private let explanation: NSTextView
    let previous = NSButton(title: L10n.string("Zurück"), target: nil, action: nil)
    let next = NSButton(title: L10n.string("Weiter"), target: nil, action: nil)
    let pauseButton = NSButton(title: L10n.string("Pause"), target: nil, action: nil)
    let end = NSButton(title: L10n.string("Beenden"), target: nil, action: nil)
    let returnButton = NSButton(title: L10n.string("Zur erklärten Stelle zurück"), target: nil, action: nil)
    private(set) var codeFontSize: CGFloat
    private(set) var explanationFontSize: CGFloat

    init(package: CodeExplanationPackage, session: ControlSnapshotWindow, controller: LocalControlController) {
        self.package = package; self.session = session; self.controller = controller
        displayedSource = package.manifest.steps[0].sourceID
        documents[displayedSource] = session.documentID
        codeFontSize = package.manifest.codeFontSize
        explanationFontSize = package.manifest.explanationFontSize
        let scroll = ReadOnlySnapshotTextView.makeScrollView(content: "", reason: L10n.string("Gespeicherte Erklärung"))
        explanation = scroll.documentView as! NSTextView
        super.init()
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        stepTitle.font = .boldSystemFont(ofSize: 14)
        stepTitle.lineBreakMode = .byTruncatingTail
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stepList.addItems(withTitles: package.manifest.steps.enumerated().map { "\($0.offset + 1). \($0.element.title)" })
        stepList.target = self; stepList.action = #selector(chooseStep)
        stepList.setAccessibilityIdentifier("explanationSteps")
        stepList.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let digits = max(2, String(package.manifest.steps.count).count)
        let counter = String(repeating: "8", count: digits) + " / " + String(repeating: "8", count: digits)
        let counterWidth = (counter as NSString).size(withAttributes: [.font: progress.font!]).width + 4
        progress.widthAnchor.constraint(equalToConstant: counterWidth).isActive = true
        returnButton.title = L10n.string("Zur Stelle")
        previous.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        next.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        returnButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
        for (button, selector) in [(previous, #selector(back)), (next, #selector(forward)),
                                  (pauseButton, #selector(pauseAction)), (end, #selector(finish)),
                                  (returnButton, #selector(returnToStep))] {
            button.target = self; button.action = selector; button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.imagePosition = .imageLeading
            button.toolTip = button.title
        }
        let codeSmaller = fontButton("−", #selector(smallerCode), "explanationCodeSmaller")
        let codeLarger = fontButton("+", #selector(largerCode), "explanationCodeLarger")
        let textSmaller = fontButton("−", #selector(smallerText), "explanationTextSmaller")
        let textLarger = fontButton("+", #selector(largerText), "explanationTextLarger")
        let fonts = NSStackView(views: [codeSizeLabel, codeSmaller, codeLarger, textSizeLabel, textSmaller, textLarger])
        fonts.spacing = 3
        codeSizeLabel.font = .systemFont(ofSize: 11); textSizeLabel.font = .systemFont(ofSize: 11)
        let fontMenu = NSPopUpButton(frame: .zero, pullsDown: true)
        fontMenu.controlSize = .small
        fontMenu.addItem(withTitle: L10n.string("Schrift"))
        for (title, action) in [("Codeschrift verkleinern", #selector(smallerCode)),
                                ("Codeschrift vergrößern", #selector(largerCode)),
                                ("Erklärschrift verkleinern", #selector(smallerText)),
                                ("Erklärschrift vergrößern", #selector(largerText))] {
            let item = NSMenuItem(title: L10n.string(title), action: action, keyEquivalent: "")
            item.target = self; fontMenu.menu?.addItem(item)
        }
        wrapButton.target = self; wrapButton.action = #selector(toggleWrap)
        wrapButton.state = .on; wrapButton.controlSize = .small
        wrapButton.font = .systemFont(ofSize: 11)
        wrapButton.setAccessibilityIdentifier("explanationSoftWrap")
        let firstRow = NSStackView(views: [stepList, progress, fonts, fontMenu])
        firstRow.spacing = 7
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let secondRow = NSStackView(views: [previous, next, pauseButton, returnButton, spacer, wrapButton, end])
        secondRow.spacing = 5
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 3
        for row in [firstRow, secondRow] {
            footer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        footer.onWidthChange = { [weak self] width in
            let compact = width < 580
            fonts.isHidden = compact; fontMenu.isHidden = !compact
            for button in [self?.previous, self?.next, self?.returnButton].compactMap({ $0 }) {
                button.imagePosition = width < 470 ? .imageOnly : .imageLeading
            }
        }
        fonts.isHidden = true
        for item in [stepTitle, scroll] {
            view.addArrangedSubview(item)
            item.translatesAutoresizingMaskIntoConstraints = false
            item.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        explanation.setAccessibilityIdentifier("codeExplanationText")
        view.setAccessibilityIdentifier("codeExplanationPanel")
        footer.setAccessibilityIdentifier("codeExplanationFooter")
        previous.setAccessibilityIdentifier("explanationPrevious")
        next.setAccessibilityIdentifier("explanationNext")
        pauseButton.setAccessibilityIdentifier("explanationPause")
        end.setAccessibilityIdentifier("explanationEnd")
        returnButton.setAccessibilityIdentifier("explanationReturn")
        applyFonts(); update()
    }

    private func fontButton(_ title: String, _ selector: Selector, _ identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded; button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func watch(_ id: UUID, index: Int) {
        observer?.cancel(); self.index = index; jobID = id; state = "loadingStep"; update()
        observer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let controller = self.controller else { return }
                do {
                    let job = try controller.execute(ControlRequest(operation: "status", jobID: id)).job
                    if let job, job.isTerminal {
                        guard !Task.isCancelled, self.jobID == id else { return }
                        self.state = job.state == "ready" ? (self.index == self.package.manifest.steps.count - 1 ? "completed" : "ready")
                            : (job.state == "cancelled" ? "paused" : "failed")
                        self.update(); return
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.state = "failed"; self.update(); return
                }
            }
        }
    }

    func pause() {
        guard state != "cancelled" else { return }
        observer?.cancel(); observer = nil
        if let id = jobID, let controller {
            _ = try? controller.execute(ControlRequest(operation: "cancel", jobID: id))
        }
        jobID = nil; state = "paused"; update()
    }

    func go(to target: Int) {
        guard state != "cancelled", package.manifest.steps.indices.contains(target),
              let session, let controller else { return }
        pause()
        let step = package.manifest.steps[target]
        index = target; update()
        guard let loaded = package.loadedSources[step.sourceID] else { state = "failed"; update(); return }
        do {
            if displayedSource != step.sourceID {
                let id = documents[step.sourceID] ?? UUID()
                try controller.installExplanationSource(loaded, documentID: id, in: session)
                documents[step.sourceID] = id; displayedSource = step.sourceID
                applyFonts()
            }
            let request = ControlRequest(operation: "navigate", sha256: loaded.diskSnapshot?.sha256,
                location: step.location, length: step.length, sessionID: session.sessionID, documentID: session.documentID)
            guard let job = try controller.execute(request).job else { throw ControlFailure.invalidID }
            watch(job.id, index: target)
        } catch { state = "failed"; session.showFailure(error as? ControlFailure); update() }
    }

    func closed() { observer?.cancel(); observer = nil; jobID = nil; state = "cancelled" }
    @objc private func back() { go(to: index - 1) }
    @objc private func forward() { go(to: index + 1) }
    @objc private func toggleWrap() {
        pause()
        session?.textView.setSoftWrap(wrapButton.state == .on)
    }
    @objc private func pauseAction() { pause() }
    @objc private func returnToStep() { go(to: index) }
    @objc private func chooseStep() { go(to: stepList.indexOfSelectedItem) }
    @objc private func finish() {
        pause()
        if let session, let controller {
            _ = try? controller.execute(ControlRequest(operation: "close", sessionID: session.sessionID))
        }
    }
    @objc private func smallerCode() { resize(code: -1, text: 0) }
    @objc private func largerCode() { resize(code: 1, text: 0) }
    @objc private func smallerText() { resize(code: 0, text: -1) }
    @objc private func largerText() { resize(code: 0, text: 1) }
    func resize(code: CGFloat, text: CGFloat) {
        pause()
        codeFontSize = min(32, max(8, codeFontSize + code))
        explanationFontSize = min(32, max(8, explanationFontSize + text))
        applyFonts()
    }
    private func applyFonts() {
        session?.setCodeFontSize(codeFontSize)
        explanation.font = .systemFont(ofSize: explanationFontSize)
        codeSizeLabel.stringValue = L10n.format("Code: %d pt", Int(codeFontSize))
        textSizeLabel.stringValue = L10n.format("Erklärung: %d pt", Int(explanationFontSize))
    }
    private func update() {
        let step = package.manifest.steps[index]
        if explanation.string != step.text { explanation.string = step.text }
        let source = package.manifest.sources.first { $0.id == step.sourceID }!
        sourceLabel.stringValue = "\(package.manifest.projectName) · \(source.path) · SHA-256 \(source.sha256.prefix(12))"
        sourceLabel.toolTip = "\(source.path)\nSHA-256 \(source.sha256)\n\(package.manifest.createdAt)"
        let caption = switch state {
        case "loadingStep": L10n.string("Schritt wird geladen…")
        case "paused": L10n.string("Pausiert – selbst erkunden oder bewusst zurückkehren.")
        case "failed": L10n.string("Schritt konnte nicht angezeigt werden.")
        case "completed": L10n.string("Letzter Schritt erreicht.")
        default: L10n.string("Schritt bereit.")
        }
        stepTitle.stringValue = step.title
        stepTitle.toolTip = "\(package.manifest.title)\n\(package.manifest.question)\n\(sourceLabel.toolTip ?? "")"
        progress.stringValue = "\(index + 1) / \(package.manifest.steps.count)"
        progress.toolTip = caption
        progress.setAccessibilityValue(L10n.format("Schritt %d/%d: %@", index + 1, package.manifest.steps.count, caption))
        pauseButton.toolTip = caption
        pauseButton.state = state == "paused" ? .on : .off
        pauseButton.title = L10n.string(state == "paused" ? "Pausiert" : "Pause")
        session?.setSourceName(source.path)
        previous.isEnabled = index > 0 && state != "loadingStep"
        stepList.selectItem(at: index); stepList.isEnabled = state != "loadingStep"
        next.isEnabled = index + 1 < package.manifest.steps.count && state != "loadingStep"
        returnButton.isEnabled = state != "loadingStep"
    }

    static func openPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L10n.string("Code-Erklärung öffnen…")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do { _ = try LocalControlController.shared.execute(ControlRequest(operation: "explanation", path: url.path)) }
                catch {
                    let alert = NSAlert(); alert.messageText = L10n.string("Code-Erklärung konnte nicht geöffnet werden.")
                    alert.runModal()
                }
            }
        }
    }
}

/// Der Fuß behält genau zwei Zeilen. Bei knapper Breite wechseln nur die
/// Schriftaktionen ins Menü und die Navigation auf beschriftete Symbolknöpfe.
@MainActor
final class ExplanationFooterView: NSStackView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = -1
    override func layout() {
        super.layout()
        guard abs(bounds.width - lastWidth) > 0.5 else { return }
        lastWidth = bounds.width
        onWidthChange?(bounds.width)
    }
}
