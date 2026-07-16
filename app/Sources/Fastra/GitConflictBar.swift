import SwiftUI

enum GitOperationControlText {
    static func continueHelp(hasConflicts: Bool, isBusy: Bool = false) -> String {
        if isBusy { return L10n.string("Warte, bis der laufende Git-Befehl beendet ist.") }
        return hasConflicts
            ? L10n.string("Löse und markiere zuerst alle Konfliktdateien als gelöst.")
            : L10n.string("Prüft Zustand, Identität und vorbereitete Commit-Nachricht erneut und setzt erst nach Bestätigung fort.")
    }

    static func abortHelp(isBusy: Bool = false) -> String {
        isBusy
            ? L10n.string("Warte, bis der laufende Git-Befehl beendet ist.")
            : L10n.string("Stellt den Zustand vor dem erkannten Git-Vorgang wieder her; Fastra prüft den Vorgang erneut und fragt vorher nach.")
    }

    static func resolvedHelp(isBusy: Bool, isDirty: Bool?) -> String {
        if isBusy { return L10n.string("Warte, bis der laufende Git-Befehl beendet ist.") }
        return isDirty == false
            ? L10n.string("Prüft Datei, Marker und Index erneut und staged ausschließlich die zuvor verifizierten Bytes.")
            : L10n.string("Speichere die Datei zuerst.")
    }
}

enum GitOperationControlAvailability {
    static func continueEnabled(isBusy: Bool, hasConflicts: Bool) -> Bool {
        !isBusy && !hasConflicts
    }

    static func abortEnabled(isBusy: Bool) -> Bool { !isBusy }

    static func resolvedEnabled(isBusy: Bool, isDirty: Bool?) -> Bool {
        !isBusy && isDirty == false
    }
}

/// Kompakte Hilfe über dem normalen Fastra-Editor. Der Editor bleibt darunter
/// vollständig editierbar; nur die gezielten Übernahmen laufen durch dessen
/// native Undo-Infrastruktur.
struct GitConflictBar: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch workspace.activeConflictSupport {
            case .none:
                EmptyView()
            case .text(let change, let blocks):
                textControls(change: change, blocks: blocks)
            case .unsafe(let change, let reason):
                limitation(change: change, reason: reason)
            case .unsupported(let change, let reason):
                limitation(change: change, reason: reason)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSand.opacity(0.72))
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
        .accessibilityElement(children: .contain)
        .onAppear {
            workspace.refreshGitOperationState()
            workspace.invalidateAndRefreshActiveConflictInspection()
        }
    }

    @ViewBuilder
    private func textControls(change: GitChange, blocks: [ConflictMarkerBlock]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.gitModified)
                .accessibilityHidden(true)
            Text(blocks.isEmpty
                 ? L10n.string("Keine vollständigen Konfliktmarker mehr")
                 : L10n.format("Konflikt %ld von %ld",
                               min(workspace.activeConflictIndex + 1, blocks.count),
                               blocks.count))
                .fastraFont(.small)
                .fontWeight(.semibold)
            if let operation = workspace.gitOperationState {
                Text(operation.localizedName)
                    .fastraFont(size: 10, weight: .semibold)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surfaceRaised))
            }
            Spacer(minLength: 4)
            if !blocks.isEmpty {
                compactButton("chevron.up", label: "Voriger Konflikt") {
                    workspace.moveActiveConflict(by: -1)
                }
                .disabled(workspace.activeConflictIndex <= 0)
                compactButton("chevron.down", label: "Nächster Konflikt") {
                    workspace.moveActiveConflict(by: 1)
                }
                .disabled(workspace.activeConflictIndex >= blocks.count - 1)
            }
            Button("Als gelöst markieren") { workspace.markActiveConflictResolved() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!GitOperationControlAvailability.resolvedEnabled(
                    isBusy: workspace.gitOperationsAreBusy,
                    isDirty: workspace.activeTab?.isDirty
                ))
                .help(GitOperationControlText.resolvedHelp(
                    isBusy: workspace.gitOperationsAreBusy,
                    isDirty: workspace.activeTab?.isDirty
                ))
                .accessibilityHint(L10n.string("Commit oder Push werden nicht ausgeführt."))
        }

        if let block = workspace.activeConflictBlock {
            HStack(spacing: 6) {
                Button(upperTitle(block)) { workspace.acceptActiveConflict(.upper) }
                    .help(L10n.string("Ersetzt den gesamten Markerbereich durch den Text zwischen <<<<<<< und dem mittleren Marker. Mit Befehl-Z rückgängig."))
                Button(lowerTitle(block)) { workspace.acceptActiveConflict(.lower) }
                    .help(L10n.string("Ersetzt den gesamten Markerbereich durch den Text zwischen ======= und >>>>>>>. Mit Befehl-Z rückgängig."))
                Button("Beide Blöcke") { workspace.acceptActiveConflict(.both) }
                    .help(L10n.string("Übernimmt zuerst den oberen und direkt danach den unteren Block. Marker und diff3-Basis werden entfernt. Mit Befehl-Z rückgängig."))
                if block.baseRange != nil {
                    Toggle("Basis zeigen", isOn: $workspace.showsConflictBase)
                        .toggleStyle(.button)
                        .help(L10n.string("Zeigt den gemeinsamen diff3-Basisblock nur als Orientierung; er wird nicht automatisch übernommen."))
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(L10n.string("Konfliktauflösung im normalen Editor"))

            if workspace.showsConflictBase,
               let range = block.baseRange,
               let content = workspace.activeTab?.content as NSString? {
                Text(content.substring(with: range))
                    .fastraFont(size: 10, design: .monospaced)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceBase))
                    .accessibilityLabel(L10n.string("Gemeinsamer Basisblock"))
            }
        }

        operationControls
            .onAppear {
                if !blocks.isEmpty { workspace.jumpToActiveConflict() }
            }
            .onChange(of: blocks.count) {
                if blocks.isEmpty { workspace.activeConflictIndex = 0 }
                else { workspace.activeConflictIndex = min(workspace.activeConflictIndex,
                                                           blocks.count - 1) }
            }
    }

    private func limitation(change: GitChange, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(L10n.format("Konflikt in %@", change.path),
                  systemImage: "exclamationmark.triangle.fill")
                .fastraFont(.small)
                .fontWeight(.semibold)
                .foregroundColor(Theme.gitModified)
            Text(reason)
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .textSelection(.enabled)
            HStack {
                Button("Terminal im Projektordner öffnen") { workspace.openTerminal() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.string("Öffnet Terminal.app ohne einen Git-Befehl automatisch auszuführen."))
                Text("git status --short")
                    .fastraFont(size: 10, design: .monospaced)
                    .textSelection(.enabled)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            operationControls
        }
    }

    @ViewBuilder private var operationControls: some View {
        if let operation = workspace.gitOperationState {
            HStack(spacing: 6) {
                Text(L10n.format("Laufender Git-Vorgang: %@", operation.localizedName))
                    .fastraFont(size: 10)
                    .foregroundColor(Theme.textSecondary)
                Button("Fortsetzen") { workspace.gitContinueOperation() }
                    .disabled(!GitOperationControlAvailability.continueEnabled(
                        isBusy: workspace.gitOperationsAreBusy,
                        hasConflicts: !workspace.conflictedGitChanges.isEmpty
                    ))
                    .help(GitOperationControlText.continueHelp(
                        hasConflicts: !workspace.conflictedGitChanges.isEmpty,
                        isBusy: workspace.gitOperationsAreBusy
                    ))
                    .accessibilityHint(GitOperationControlText.continueHelp(
                        hasConflicts: !workspace.conflictedGitChanges.isEmpty,
                        isBusy: workspace.gitOperationsAreBusy
                    ))
                Button("Abbrechen…") { workspace.gitAbortOperation() }
                    .disabled(!GitOperationControlAvailability.abortEnabled(
                        isBusy: workspace.gitOperationsAreBusy
                    ))
                    .help(GitOperationControlText.abortHelp(
                        isBusy: workspace.gitOperationsAreBusy
                    ))
                    .accessibilityHint(GitOperationControlText.abortHelp(
                        isBusy: workspace.gitOperationsAreBusy
                    ))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func compactButton(_ systemImage: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(L10n.string(label))
        .accessibilityLabel(L10n.string(label))
    }

    private func upperTitle(_ block: ConflictMarkerBlock) -> String {
        block.upperLabel.map { L10n.format("Oberer Block · %@", $0) }
            ?? L10n.string("Oberer Block")
    }

    private func lowerTitle(_ block: ConflictMarkerBlock) -> String {
        block.lowerLabel.map { L10n.format("Unterer Block · %@", $0) }
            ?? L10n.string("Unterer Block")
    }
}
