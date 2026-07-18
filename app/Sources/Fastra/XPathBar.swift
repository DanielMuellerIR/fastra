// XPathBar.swift
//
// Schwebende XPath-Leiste (Etappe 5 Wunschpaket 2026-07): Spotlight-artiges
// NSPanel über dem Editor für XML-artige Dokumente. Live-Springen beim
// Tippen (erste Fundstelle), Enter/Pfeile für weitere Treffer,
// Autovervollständigung der Kind-Element- und Attributnamen aus dem Index.
//
// Der Index (XPathSupport.swift) wird asynchron im Hintergrund gebaut und
// bei Dokumentänderungen debounced erneuert; bei kaputtem XML bleibt der
// letzte gültige Index aktiv und der Fehler erscheint dezent in der Leiste.

import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// ⇧⌘X — XPath-Leiste für das aktive XML-Dokument öffnen.
    static let fastraShowXPathBar = Notification.Name("fastra.show.xpath.bar")
}

// MARK: - Modell

@MainActor
final class XPathBarModel: ObservableObject {
    @Published var query: String = "" {
        didSet { queryDidChange() }
    }
    /// Trefferanzeige („3 von 7“) bzw. Leerlauf-Hinweis.
    @Published private(set) var statusText: String = ""
    /// Dezenter Fehlerhinweis (Teilset-Verstoß oder kaputtes XML).
    @Published private(set) var errorText: String?
    @Published private(set) var completions: [String] = []

    private weak var workspace: Workspace?
    private(set) var index: XPathIndex?
    private var matches: [XPathEvaluator.Match] = []
    private var matchCursor = 0
    private var indexedContent: String?
    private var rebuildWork: DispatchWorkItem?
    private var contentObserver: AnyCancellable?
    private var buildGeneration = 0
    /// Eine Eingabe, die mangels fertigem Index noch nicht springen konnte.
    /// Siehe `evaluate(jump:)`.
    private var pendingJump = false

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Beim Öffnen der Leiste: Index (neu) aufbauen und Änderungen des
    /// Dokuments beobachten (debounced — Tippen im Editor kostet nichts).
    func activate() {
        rebuildIndexSoon(delay: 0)
        contentObserver = workspace?.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildIndexIfContentChanged()
            }
    }

    func deactivate() {
        contentObserver = nil
        rebuildWork?.cancel()
    }

    private func rebuildIndexIfContentChanged() {
        guard let content = workspace?.activeTabContent.wrappedValue,
              content != indexedContent else { return }
        rebuildIndexSoon(delay: 0)
    }

    /// Baut den Index asynchron im Hintergrund. Bei Fehlern bleibt der
    /// letzte gültige Index stehen; nur der Hinweis wechselt.
    private func rebuildIndexSoon(delay: TimeInterval) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            let content = workspace.activeTabContent.wrappedValue
            self.indexedContent = content
            self.buildGeneration += 1
            let generation = self.buildGeneration
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = XPathIndex.build(from: content)
                DispatchQueue.main.async {
                    guard let self, self.buildGeneration == generation else { return }
                    switch result {
                    case .success(let index):
                        self.index = index
                        self.errorText = nil
                    case .failure(let error):
                        // Letzten gültigen Index behalten (Spezifikation).
                        self.errorText = error.userMessage
                    }
                    self.evaluate(jump: false)
                }
            }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func queryDidChange() {
        evaluate(jump: true)
        updateCompletions()
    }

    /// Wertet die aktuelle Query gegen den Index aus; `jump` springt zur
    /// ersten Fundstelle (Live-Springen beim Tippen).
    private func evaluate(jump: Bool) {
        guard let index else {
            matches = []
            statusText = ""
            // Der Index entsteht asynchron im Hintergrund. Wer die Leiste
            // öffnet und sofort tippt, ist schneller — der Sprung darf dabei
            // nicht verloren gehen. Ohne dieses Vormerken zeigte die Leiste
            // nach dem Indexbau zwar die Treffer an, der Editor blieb aber
            // stehen (der Bau selbst wertet bewusst ohne Sprung aus).
            if jump { pendingJump = true }
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            matches = []
            statusText = L10n.string("XPath eingeben — z. B. //buch[@id='42']/titel")
            if errorText == nil { }
            pendingJump = false
            return
        }
        switch XPathQuery.parse(trimmed) {
        case .failure(let error):
            matches = []
            statusText = error.userMessage
            pendingJump = false
        case .success(let parsed):
            matches = XPathEvaluator.evaluate(parsed, in: index)
            matchCursor = 0
            statusText = matches.isEmpty
                ? L10n.string("Keine Fundstelle")
                : L10n.format("%ld von %ld", 1, matches.count)
            // `pendingJump` holt genau einen verpassten Sprung nach. Ein
            // späterer Index-Neubau (Dokument geändert) springt weiterhin
            // nicht von selbst — das wäre für den Nutzer überraschend.
            if jump || pendingJump {
                pendingJump = false
                jumpToCurrentMatch()
            }
        }
    }

    /// Enter/Pfeil-Navigation durch die Fundstellen.
    func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchCursor = ((matchCursor + direction) % matches.count + matches.count)
            % matches.count
        statusText = L10n.format("%ld von %ld", matchCursor + 1, matches.count)
        jumpToCurrentMatch()
    }

    private func jumpToCurrentMatch() {
        guard let workspace, matches.indices.contains(matchCursor) else { return }
        NotificationCenter.default.post(
            name: .fastraJumpToRange, object: workspace,
            userInfo: ["range": NSValue(range: matches[matchCursor].range)]
        )
    }

    private func updateCompletions() {
        guard let index else {
            completions = []
            return
        }
        completions = XPathAutocomplete.completions(for: query, index: index)
    }

    /// Übernimmt einen Vorschlag: ersetzt das angefangene letzte Teilstück.
    func accept(completion: String) {
        let (path, _) = XPathAutocomplete.splitForCompletion(query)
        if path.isEmpty {
            query = completion
        } else if path.hasSuffix("/") {
            query = path + completion
        } else {
            query = path + "/" + completion
        }
    }
}

// MARK: - Panel-Inhalt

struct XPathBarView: View {
    @ObservedObject var model: XPathBarModel
    let onClose: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.slash.chevron.right")
                    .fastraFont(size: 13)
                    .foregroundColor(Theme.accentReadable)
                TextField("XPath — z. B. //buch[@id='42']/titel", text: $model.query)
                    .textFieldStyle(.plain)
                    .fastraFont(size: 15, design: .monospaced)
                    .focused($fieldFocused)
                    .onSubmit { model.step(1) }
                    .accessibilityIdentifier("xpathField")
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("XPath-Leiste schließen (Esc)")
            }
            HStack(spacing: 10) {
                Text(verbatim: model.errorText ?? model.statusText)
                    .fastraFont(.small)
                    .foregroundColor(model.errorText == nil
                                     ? Theme.textSecondary : Theme.diffRemovedFG)
                    .lineLimit(1)
                    .accessibilityIdentifier("xpathStatus")
                Spacer(minLength: 0)
                Text("↩ weiter · ⇧↩ zurück")
                    .fastraFont(size: 10)
                    .foregroundColor(Theme.textSecondary.opacity(0.7))
            }
            if !model.completions.isEmpty {
                // Vorschläge aus dem Index (Kind-Elemente bzw. Attribute).
                HStack(spacing: 6) {
                    ForEach(model.completions, id: \.self) { name in
                        Button {
                            model.accept(completion: name)
                        } label: {
                            Text(verbatim: name)
                                .fastraFont(size: 11, design: .monospaced)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.surfaceSand)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("xpathCompletions")
            }
        }
        .padding(12)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceRaised)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.textSecondary.opacity(0.25), lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
        .onExitCommand { onClose() }
        // ⇧↩ rückwärts; ↓/↑ als Alternative zu Enter (Spezifikation:
        // „weitere per Enter/Pfeile").
        .onKeyPress(.downArrow) { model.step(1); return .handled }
        .onKeyPress(.upArrow) { model.step(-1); return .handled }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            model.step(-1)
            return .handled
        }
    }
}

// MARK: - Panel-Controller

/// Randloses Panel, das trotzdem Key werden darf (Texteingabe).
private final class KeyableXPathPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class XPathPanelController {
    private weak var workspace: Workspace?
    private var panel: NSPanel?
    private(set) var model: XPathBarModel?

    /// Fenster-Identifier für Selbsttests und Debugging.
    static let panelIdentifier = NSUserInterfaceItemIdentifier("Fastra.XPathPanel")
    /// Zuletzt gezeigter Controller — NUR für den `xpath`-Selbsttest, der
    /// das Modell des echten Panels steuern und beobachten muss.
    private(set) static weak var lastShown: XPathPanelController?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Öffnet die Leiste Spotlight-artig oben mittig über dem Dokumentfenster.
    func show(over window: NSWindow?) {
        guard let workspace else { return }
        if panel == nil {
            let model = XPathBarModel(workspace: workspace)
            self.model = model
            let panel = KeyableXPathPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = Self.panelIdentifier
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false   // Schatten zeichnet die SwiftUI-Form
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(
                rootView: XPathBarView(model: model) { [weak self] in
                    self?.close()
                }
                .fastraScalingRoot()
            )
            self.panel = panel
        }
        guard let panel else { return }
        // Position: horizontal zentriert, knapp unter der Tab-Leiste.
        if let host = window ?? NSApp.mainWindow {
            let frame = host.frame
            let x = frame.midX - panel.frame.width / 2
            let y = frame.maxY - 120 - panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        model?.activate()
        panel.makeKeyAndOrderFront(nil)
        Self.lastShown = self
    }

    func close() {
        model?.deactivate()
        panel?.orderOut(nil)
        // Fokus zurück in den Editor des Dokumentfensters.
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}
