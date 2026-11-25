import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MarkdownVisualSaveMessages {
    static var title: String {
        L10n.string("Dokument konnte nicht gespeichert werden")
    }

    static func detail(for check: MarkdownVisualCoordinator.SaveCheck) -> String {
        switch check {
        case .text:
            return L10n.string("Beim Speichern aus der formatierten Ansicht (WYSIWYG) würde sich der Text verändern.")
        case .format:
            return L10n.string("Beim Speichern aus der formatierten Ansicht (WYSIWYG) würden Formatierungen verloren gehen oder sich verändern.")
        case .breaks:
            return L10n.string("Beim Speichern aus der formatierten Ansicht (WYSIWYG) würden Zeilenumbrüche oder Leerzeilen verloren gehen oder sich verändern.")
        case .unavailable:
            return L10n.string("Fastra konnte vor dem Speichern nicht prüfen, ob die formatierte Ansicht (WYSIWYG) unverändert gespeichert würde.")
        case .ok:
            return ""
        }
    }

    static var saveFailureInfo: String {
        L10n.string("Deine Änderungen bleiben im offenen Editor erhalten. Du kannst das Diagnoseprotokoll sichern oder kopieren, um den Fehler zu melden, oder in die Quelltext-Ansicht wechseln.")
    }

    static func anomalyDetail(code: String) -> String {
        switch code {
        case "boundary-rescued":
            return L10n.string("Fastra hat bei der letzten Bearbeitung eine ungültige Blockgrenze abgefangen und sichtbaren Text geschützt.")
        case "unexpected-text-loss":
            return L10n.string("Bei einem Formatierungsbefehl in der formatierten Ansicht (WYSIWYG) hat sich die sichtbare Textlänge unerwartet verändert.")
        default:
            return L10n.string("Bei der letzten Bearbeitung in der formatierten Ansicht (WYSIWYG) ist ein unerwarteter Zustand aufgetreten.")
        }
    }
}

struct VisualDiagnosticAlert: Equatable {
    enum Kind: Equatable {
        case saveCheck(MarkdownVisualCoordinator.SaveCheck)
        case anomaly(code: String)
    }

    let signature: String
    let kind: Kind
    let title: String
    let detail: String
    let capturedAt: Date
    let revision: Int
    let frozenReportRedacted: String?
    let frozenReportFull: String?
}

final class MarkdownVisualDiagnosticsController: ObservableObject {
    @Published var activeWarning: VisualDiagnosticAlert?
    @Published var dismissedWarningSignature: String?
    @Published var lastCheckedRevision: Int?
    @Published var lastCheckPassed: Bool?
    @Published var lastCheckAt: Date?
    @Published var lastEventCount = 0
    @Published var isSheetPresented = false
    @Published var statusNotice: String?
    @Published var previewRedactedReport = ""

    init() { _ = objectWillChange }

    var showsBanner: Bool {
        guard let activeWarning else { return false }
        return activeWarning.signature != dismissedWarningSignature
    }

    @MainActor func dismissBanner() {
        dismissedWarningSignature = activeWarning?.signature
    }

    @MainActor func clear() {
        activeWarning = nil
        dismissedWarningSignature = nil
        lastCheckedRevision = nil
        lastCheckPassed = nil
        lastCheckAt = nil
        lastEventCount = 0
        statusNotice = nil
        previewRedactedReport = ""
    }

    @MainActor func recordLiveCheck(outcome: MarkdownVisualCoordinator.SaveCheck,
                         revision: Int,
                         eventCount: Int,
                         redactedReport: String?,
                         fullReport: String?) {
        lastCheckedRevision = revision
        lastCheckAt = Date()
        lastEventCount = eventCount
        if let redactedReport { previewRedactedReport = redactedReport }
        if outcome == .ok {
            lastCheckPassed = true
            if case .saveCheck = activeWarning?.kind {
                activeWarning = nil
                dismissedWarningSignature = nil
            } else if case .anomaly = activeWarning?.kind, (activeWarning?.revision ?? -1) < revision {
                activeWarning = nil
                dismissedWarningSignature = nil
            }
            return
        }
        lastCheckPassed = false
        let alert = VisualDiagnosticAlert(
            signature: "saveCheck:\(outcome.rawValue):\(revision)",
            kind: .saveCheck(outcome),
            title: L10n.string("Abweichung in der WYSIWYG-Ansicht erkannt"),
            detail: MarkdownVisualSaveMessages.detail(for: outcome),
            capturedAt: Date(),
            revision: revision,
            frozenReportRedacted: redactedReport,
            frozenReportFull: fullReport
        )
        if activeWarning?.signature != alert.signature {
            dismissedWarningSignature = nil
        }
        activeWarning = alert
    }

    @MainActor func recordAnomaly(code: String,
                       revision: Int,
                       eventCount: Int,
                       redactedReport: String?,
                       fullReport: String?) {
        lastEventCount = max(lastEventCount, eventCount)
        if let redactedReport { previewRedactedReport = redactedReport }
        let alert = VisualDiagnosticAlert(
            signature: "anomaly:\(code):\(revision)",
            kind: .anomaly(code: code),
            title: L10n.string("Unerwartete WYSIWYG-Bearbeitung erkannt"),
            detail: MarkdownVisualSaveMessages.anomalyDetail(code: code),
            capturedAt: Date(),
            revision: revision,
            frozenReportRedacted: redactedReport,
            frozenReportFull: fullReport
        )
        if activeWarning?.signature != alert.signature {
            dismissedWarningSignature = nil
        }
        activeWarning = alert
    }

    @MainActor func present(in workspace: Workspace) {
        statusNotice = nil
        isSheetPresented = true
        refreshPreview(from: workspace)
    }

    @MainActor func refreshPreview(from workspace: Workspace) {
        guard let editor = workspace.visualMarkdownEditor, editor.ready else {
            if previewRedactedReport.isEmpty, let frozen = activeWarning?.frozenReportRedacted {
                previewRedactedReport = frozen
            }
            return
        }
        editor.collectDiagnosticReport(includeContent: false) { [weak self] report, eventCount in
            guard let self else { return }
            if let eventCount { self.lastEventCount = eventCount }
            if let report { self.previewRedactedReport = report }
        }
    }

    @MainActor func copyReport(includeContent: Bool, from workspace: Workspace, completion: ((Bool) -> Void)? = nil) {
        resolveReport(includeContent: includeContent, from: workspace) { [weak self] text in
            guard let text else {
                self?.statusNotice = L10n.string("Das Diagnoseprotokoll ist derzeit nicht verfügbar.")
                completion?(false)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.statusNotice = includeContent
                ? L10n.string("Vollständiges Diagnoseprotokoll in die Zwischenablage kopiert.")
                : L10n.string("Anonymisierte Diagnose in die Zwischenablage kopiert.")
            completion?(true)
        }
    }

    @MainActor func saveFullReport(from workspace: Workspace, completion: ((URL?) -> Void)? = nil) {
        resolveReport(includeContent: true, from: workspace) { [weak self] text in
            guard let self, let text else {
                self?.statusNotice = L10n.string("Das Diagnoseprotokoll ist derzeit nicht verfügbar.")
                completion?(nil)
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = Self.defaultFileName()
            guard panel.runModal() == .OK, let url = panel.url else {
                completion?(nil)
                return
            }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self.statusNotice = L10n.format("Diagnoseprotokoll gespeichert: %@", url.lastPathComponent)
                completion?(url)
            } catch {
                self.statusNotice = error.localizedDescription
                completion?(nil)
            }
        }
    }

    @MainActor func resolveReport(includeContent: Bool, from workspace: Workspace, completion: @escaping (String?) -> Void) {
        if let editor = workspace.visualMarkdownEditor, editor.ready {
            editor.collectDiagnosticReport(includeContent: includeContent) { [weak self] report, eventCount in
                if let eventCount { self?.lastEventCount = eventCount }
                if let report {
                    if !includeContent { self?.previewRedactedReport = report }
                    completion(report)
                } else {
                    let fallback = includeContent ? self?.activeWarning?.frozenReportFull : self?.activeWarning?.frozenReportRedacted
                    completion(fallback)
                }
            }
            return
        }
        let fallback = includeContent ? activeWarning?.frozenReportFull : activeWarning?.frozenReportRedacted
        completion(fallback)
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Fastra-WYSIWYG-Diagnose-\(formatter.string(from: Date())).json"
    }
}

struct MarkdownVisualDiagnosticPresentation: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var controller: MarkdownVisualDiagnosticsController

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $controller.isSheetPresented) {
                MarkdownVisualDiagnosticSheet(workspace: workspace, controller: controller)
            }
    }
}

struct MarkdownVisualDiagnosticSheet: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var controller: MarkdownVisualDiagnosticsController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WYSIWYG-Diagnoseprotokoll").fastraFont(.headline)
                Spacer()
                Button("Aktualisieren") { controller.refreshPreview(from: workspace) }
            }
            statusHeader
            Text("Das anonymisierte Protokoll enthält nur Aktionsarten, Strukturdaten und Abweichungsstellen ohne Dokumenttext. Das vollständige Protokoll enthält zusätzlich den aktuellen HTML- und Markdown-Stand zur Fehleranalyse.")
                .fastraFont(.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(verbatim: controller.previewRedactedReport.isEmpty
                     ? L10n.string("Keine Diagnose-Einträge vorhanden.")
                     : controller.previewRedactedReport)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 220)
            .background(Theme.surfaceBase)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))

            if let notice = controller.statusNotice {
                Text(verbatim: notice)
                    .fastraFont(.small)
                    .foregroundStyle(Theme.accentReadable)
            }

            HStack(spacing: 8) {
                Button("Diagnose ohne Dokumentinhalt kopieren") {
                    controller.copyReport(includeContent: false, from: workspace)
                }
                Button("Vollständiges Protokoll kopieren") {
                    controller.copyReport(includeContent: true, from: workspace)
                }
                Button("Vollständiges Protokoll sichern…") {
                    controller.saveFullReport(from: workspace)
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Schließen") { controller.isSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(SelfTestMarker(id: "markdownVisualDiagnosticSheet").frame(width: 0, height: 0))
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            if let warning = controller.activeWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: warning.title).fastraFont(.ui).fontWeight(.semibold)
                    Text(verbatim: warning.detail).fastraFont(.small).foregroundStyle(Theme.textSecondary)
                }
            } else {
                Image(systemName: controller.lastCheckPassed == true ? "checkmark.circle.fill" : "stethoscope")
                    .foregroundStyle(controller.lastCheckPassed == true ? Color.green : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.lastCheckPassed == true
                         ? L10n.string("Live-Prüfung: Keine Abweichungen erkannt")
                         : L10n.string("Live-Prüfung aktiv (1 Sekunde nach Eingaben)"))
                        .fastraFont(.ui).fontWeight(.semibold)
                    Text(verbatim: L10n.format("Protokollierte Schritte: %lld", Int64(controller.lastEventCount)))
                        .fastraFont(.small)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.surfaceSand.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct MarkdownVisualDiagnosticToolbarButton: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var diagnostics: MarkdownVisualDiagnosticsController

    var body: some View {
        let hasWarning = diagnostics.activeWarning != nil
        Button {
            diagnostics.present(in: workspace)
        } label: {
            Image(systemName: hasWarning ? "exclamationmark.triangle.fill" : "stethoscope")
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasWarning ? Color.orange : Theme.textSecondary)
        .help(hasWarning
              ? "WYSIWYG-Abweichung erkannt — Diagnoseprotokoll öffnen"
              : "WYSIWYG-Diagnoseprotokoll…")
        .accessibilityLabel("WYSIWYG-Diagnoseprotokoll öffnen")
        .background(SelfTestMarker(id: "markdownVisualDiagnosticButton").frame(width: 0, height: 0))
    }
}

struct MarkdownVisualDiagnosticBanner: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var diagnostics: MarkdownVisualDiagnosticsController

    var body: some View {
        if diagnostics.showsBanner, let warning = diagnostics.activeWarning {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .fastraFont(size: 11)
                        .foregroundStyle(.orange)
                    Text(verbatim: warning.detail)
                        .fastraFont(.small)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Protokoll sichern…") {
                        diagnostics.saveFullReport(from: workspace)
                    }
                    .buttonStyle(.plain)
                    .fastraFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.accentReadable)
                    Button("Diagnose…") {
                        diagnostics.present(in: workspace)
                    }
                    .buttonStyle(.plain)
                    .fastraFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                    Button("Quelltext öffnen") {
                        workspace.toggleMarkdownEditingMode()
                    }
                    .buttonStyle(.plain)
                    .fastraFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.textSecondary)
                    Button {
                        diagnostics.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .fastraFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Hinweis ausblenden")
                    .accessibilityLabel("Hinweis ausblenden")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceSand.opacity(0.75))
                .background(SelfTestMarker(id: "markdownVisualDiagnosticBanner").frame(width: 0, height: 0))
                Divider().opacity(0.3)
            }
        }
    }
}
