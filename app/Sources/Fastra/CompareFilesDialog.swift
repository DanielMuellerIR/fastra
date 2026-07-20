// CompareFilesDialog.swift
//
// Dialog „Dateien vergleichen…" (Etappe 1 Wunschpaket 2026-07c; BBEdit
// „Find Differences"). Links/Rechts je: Dateiauswahl-Button, Drag-and-drop-
// Feld und ein Popup mit offenen Tabs und zuletzt geöffneten Dateien;
// darunter die Vergleichsoptionen. Vorbelegung: aktiver Tab links.
// Nicht vorhandene oder binäre Dateien melden sich verständlich AM FELD —
// die endgültige Prüfung übernimmt zusätzlich der Ladepfad des Diff-Tabs.

import SwiftUI
import UniformTypeIdentifiers

/// Pure, testbare Feld-Validierung des Vergleichs-Dialogs.
enum CompareDialogLogic {

    enum FieldProblem: Equatable {
        /// Datei existiert nicht (mehr).
        case missing
        /// Pfad ist ein Ordner — Ordner-Vergleich ist bewusst nicht Teil
        /// dieser Etappe.
        case directory
        /// Sieht nach Binärdatei aus (Nullbyte-Probe).
        case binary

        var message: String {
            switch self {
            case .missing: return L10n.string("Datei nicht gefunden.")
            case .directory: return L10n.string("Ordner lassen sich (noch) nicht vergleichen.")
            case .binary: return L10n.string("Binärdatei — ein Zeilenvergleich ist nicht möglich.")
            }
        }
    }

    /// Schnelle Plausibilitätsprüfung für die Anzeige am Feld.
    static func problem(forFileAt url: URL,
                        fileManager: FileManager = .default) -> FieldProblem? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue { return .directory }
        if looksBinary(url: url) { return .binary }
        return nil
    }

    /// Gleiche Heuristik wie `FileLoader` (Nullbyte in den ersten 8 KiB,
    /// UTF-16/32-BOMs ausgenommen) — hier nur als frühe Dialog-Warnung.
    /// Die verbindliche Erkennung läuft beim echten Laden des Diffs.
    static func looksBinary(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024),
              !data.isEmpty else { return false }
        // UTF-16/32-BOMs erlauben Nullbytes (FF FE deckt auch UTF-32 LE ab).
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return false
        }
        return data.contains(0)
    }

    /// Ermittelt die beiden Startfelder des Dialogs. Ein gültiges, explizites
    /// Tabpaar gewinnt; sonst bleibt die bisherige Vorbelegung des aktiven
    /// Dokuments links erhalten.
    static func prefill(
        tabIDs: [UUID],
        activeTabID: UUID?,
        tabs: [EditorTab]
    ) -> CompareDialogPrefill {
        let eligible = tabs.filter(\.isEligibleForFileComparison)
        let eligibleIDs = Set(eligible.map(\.id))
        let explicit = tabIDs.reduce(into: [UUID]()) { result, id in
            if eligibleIDs.contains(id), !result.contains(id) {
                result.append(id)
            }
        }
        if explicit.count == 2 {
            return CompareDialogPrefill(
                left: .tab(explicit[0]),
                right: .tab(explicit[1])
            )
        }
        if let activeTabID, eligibleIDs.contains(activeTabID) {
            return CompareDialogPrefill(
                left: .tab(activeTabID),
                right: .none
            )
        }
        return CompareDialogPrefill(left: .none, right: .none)
    }
}

/// Auswahlzustand einer Dialogseite: nichts, eine Datei oder ein offener Tab.
enum CompareSelection: Equatable {
    case none
    case file(URL)
    case tab(UUID)
}

struct CompareDialogPrefill: Equatable {
    let left: CompareSelection
    let right: CompareSelection
}

struct CompareFilesDialog: View {
    @ObservedObject var workspace: Workspace
    let preselectedTabIDs: [UUID]

    @State private var left: CompareSelection = .none
    @State private var right: CompareSelection = .none
    @State private var leftDropTargeted = false
    @State private var rightDropTargeted = false

    // Optionen überleben App-Neustarts (BBEdit-Verhalten); Erstzustand:
    // nichts ignorieren (Produktvorgabe).
    @AppStorage("fastra.fileDiff.ignoreTrailingWhitespace")
    private var ignoreTrailingWhitespace = false
    @AppStorage("fastra.fileDiff.ignoreAllWhitespace")
    private var ignoreAllWhitespace = false
    @AppStorage("fastra.fileDiff.ignoreBlankLines")
    private var ignoreBlankLines = false
    @AppStorage("fastra.fileDiff.ignoreCase")
    private var ignoreCase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dateien vergleichen")
                .fastraFont(.headline)
                .foregroundColor(Theme.textPrimary)
            HStack(alignment: .top, spacing: 12) {
                sidePanel(role: .left, selection: $left, targeted: $leftDropTargeted)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 44)
                sidePanel(role: .right, selection: $right, targeted: $rightDropTargeted)
            }
            optionsSection
            HStack {
                Spacer()
                Button("Abbrechen") {
                    workspace.showCompareFilesDialog = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Vergleichen") { compare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCompare)
            }
        }
        .padding(20)
        .frame(width: 640)
        .fastraScalingRoot()
        .onAppear(perform: prefillSelections)
    }

    // MARK: - Seiten

    /// Ein über die Tab-Leiste gewähltes Paar füllt beide Seiten. Der normale
    /// Menübefehl übergibt keine IDs und behält „aktiver Tab links“ bei.
    private func prefillSelections() {
        guard case .none = left, case .none = right else { return }
        let prefill = CompareDialogLogic.prefill(
            tabIDs: preselectedTabIDs,
            activeTabID: workspace.activeTabID,
            tabs: workspace.tabs
        )
        left = prefill.left
        right = prefill.right
    }

    private var eligibleTabs: [EditorTab] {
        workspace.tabs.filter(\.isEligibleForFileComparison)
    }

    /// Zuletzt geöffnete Dateien aus dem bestehenden Store (K2).
    private var recentFileURLs: [URL] {
        workspace.recentFiles.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
    }

    private func sidePanel(role: FileDiffSideRole,
                           selection: Binding<CompareSelection>,
                           targeted: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role == .left ? L10n.string("Links") : L10n.string("Rechts"))
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
            selectionBox(role: role, selection: selection, targeted: targeted)
            HStack(spacing: 6) {
                Button("Auswählen…") { chooseFile(into: selection) }
                sourceMenu(selection: selection)
            }
            if let problem = problem(for: selection.wrappedValue) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .fastraFont(.small)
                    .foregroundColor(Theme.diffRemovedFG)
                    .accessibilityLabel(problem)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Das Drag-and-drop-Feld mit der aktuellen Auswahl.
    private func selectionBox(role: FileDiffSideRole,
                              selection: Binding<CompareSelection>,
                              targeted: Binding<Bool>) -> some View {
        VStack(spacing: 4) {
            switch selection.wrappedValue {
            case .none:
                Image(systemName: "doc.badge.plus")
                    .fastraFont(size: 18)
                    .foregroundColor(Theme.textSecondary)
                Text("Datei hierher ziehen")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
            case .file(let url):
                Image(systemName: "doc.text")
                    .fastraFont(size: 18)
                    .foregroundColor(Theme.textPrimary)
                Text(url.lastPathComponent)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .fastraFont(size: 10)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            case .tab(let id):
                if let tab = workspace.tabs.first(where: { $0.id == id }) {
                    Image(systemName: "macwindow")
                        .fastraFont(size: 18)
                        .foregroundColor(Theme.textPrimary)
                    Text(tab.title)
                        .fastraFont(.small)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tab.isDirty
                         ? L10n.string("Offener Tab (ungespeicherte Änderungen)")
                         : L10n.string("Offener Tab"))
                        .fastraFont(size: 10)
                        .foregroundColor(Theme.textSecondary)
                } else {
                    Text("Tab ist nicht mehr geöffnet.")
                        .fastraFont(.small)
                        .foregroundColor(Theme.diffRemovedFG)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(Theme.surfaceBase)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(targeted.wrappedValue ? Theme.accentReadable : Theme.stroke,
                              style: StrokeStyle(lineWidth: targeted.wrappedValue ? 2 : 1,
                                                 dash: [5, 3]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier(
            selectionIdentifier(role: role, selection: selection.wrappedValue)
        )
        .background(
            SelfTestMarker(
                id: selectionIdentifier(
                    role: role,
                    selection: selection.wrappedValue
                )
            ).frame(width: 0, height: 0)
        )
        .onDrop(of: [.fileURL], isTargeted: targeted) { providers in
            acceptDrop(providers: providers, into: selection)
        }
    }

    private func selectionIdentifier(
        role: FileDiffSideRole,
        selection: CompareSelection
    ) -> String {
        let side = role == .left ? "left" : "right"
        switch selection {
        case .none:
            return "compare-\(side)-none"
        case .file(let url):
            return "compare-\(side)-file-\(url.lastPathComponent)"
        case .tab(let id):
            return "compare-\(side)-tab-\(id.uuidString)"
        }
    }

    /// Popup mit offenen Tabs und zuletzt geöffneten Dateien.
    private func sourceMenu(selection: Binding<CompareSelection>) -> some View {
        Menu {
            if !eligibleTabs.isEmpty {
                Section("Offene Tabs") {
                    ForEach(eligibleTabs) { tab in
                        Button(tab.title) { selection.wrappedValue = .tab(tab.id) }
                    }
                }
            }
            if !recentFileURLs.isEmpty {
                Section("Zuletzt geöffnet") {
                    ForEach(recentFileURLs, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            selection.wrappedValue = .file(url)
                        }
                    }
                }
            }
            if eligibleTabs.isEmpty && recentFileURLs.isEmpty {
                Button("Keine offenen Tabs oder zuletzt geöffneten Dateien") {}
                    .disabled(true)
            }
        } label: {
            Label(L10n.string("Tabs & zuletzt geöffnet"), systemImage: "clock")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chooseFile(into selection: Binding<CompareSelection>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Datei zum Vergleichen auswählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selection.wrappedValue = .file(url)
    }

    /// Nimmt die erste regulär existierende Datei aus dem Drop an
    /// (gleiche Filterlogik wie das Fenster-Drop: `DropHandling`).
    private func acceptDrop(providers: [NSItemProvider],
                            into selection: Binding<CompareSelection>) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let files = DropHandling.loadableFiles(from: [url])
            DispatchQueue.main.async {
                // Auch eine nicht ladbare Datei WIRD gesetzt — das Feld
                // zeigt dann seine verständliche Meldung, statt den Drop
                // still zu verschlucken.
                selection.wrappedValue = .file(files.first ?? url)
            }
        }
        return true
    }

    /// Feld-Meldung zur aktuellen Auswahl (nil = in Ordnung).
    private func problem(for selection: CompareSelection) -> String? {
        switch selection {
        case .none:
            return nil
        case .file(let url):
            return CompareDialogLogic.problem(forFileAt: url)?.message
        case .tab(let id):
            return workspace.tabs.contains(where: { $0.id == id })
                ? nil : L10n.string("Tab ist nicht mehr geöffnet.")
        }
    }

    // MARK: - Optionen

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Beim Vergleichen ignorieren")
                .fastraFont(size: 10)
                .foregroundColor(Theme.textSecondary)
            Toggle("Leerraum am Zeilenende", isOn: $ignoreTrailingWhitespace)
                .disabled(ignoreAllWhitespace)
                .help("Unterschiede, die nur aus Leerzeichen/Tabs am Zeilenende bestehen, zählen nicht.")
            Toggle("Alle Leerraum-Unterschiede", isOn: $ignoreAllWhitespace)
                .help("Sämtliche Leerzeichen und Tabs werden vor dem Vergleich entfernt — Einrückung und Ausrichtung zählen nicht.")
            Toggle("Leerzeilen", isOn: $ignoreBlankLines)
                .help("Leerzeilen, die nur auf einer Seite stehen, zählen nicht als Unterschied. Sie bleiben in der Ansicht sichtbar.")
            Toggle("Groß-/Kleinschreibung", isOn: $ignoreCase)
                .help("„Wort“ und „wort“ gelten als gleich.")
        }
        .toggleStyle(.checkbox)
        .fastraFont(.small)
    }

    // MARK: - Vergleichen

    private var canCompare: Bool {
        side(for: left, role: .left) != nil
            && side(for: right, role: .right) != nil
            && problem(for: left) == nil
            && problem(for: right) == nil
    }

    /// Auswahl → Vergleichsseite. Saubere Tabs mit Datei vergleichen den
    /// Plattenstand; dirty Tabs und unbenannte Tabs den Editor-Inhalt —
    /// verglichen wird immer das, was der Nutzer gerade sieht.
    private func side(for selection: CompareSelection,
                      role: FileDiffSideRole) -> FileDiffSide? {
        switch selection {
        case .none:
            return nil
        case .file(let url):
            return .file(url)
        case .tab(let id):
            guard let tab = workspace.tabs.first(where: { $0.id == id }) else {
                return nil
            }
            if let url = tab.url, !tab.isDirty {
                return .file(url)
            }
            let name = tab.isDirty && tab.url != nil
                ? L10n.format("%@ (ungespeichert)", tab.title)
                : tab.title
            return .text(tab.content, name: name, path: tab.url?.path)
        }
    }

    private func compare() {
        guard let leftSide = side(for: left, role: .left),
              let rightSide = side(for: right, role: .right) else { return }
        var options = FileDiffOptions()
        options.ignoreTrailingWhitespace = ignoreTrailingWhitespace
        options.ignoreAllWhitespace = ignoreAllWhitespace
        options.ignoreBlankLines = ignoreBlankLines
        options.ignoreCase = ignoreCase
        workspace.showCompareFilesDialog = false
        workspace.openFileDiffTab(request: FileDiffRequest(
            left: leftSide, right: rightSide, options: options
        ))
    }
}
