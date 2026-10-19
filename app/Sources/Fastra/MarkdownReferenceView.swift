import SwiftUI

struct MarkdownReferencePresentation: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var controller: MarkdownReferenceController

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $controller.isPresented) {
                MarkdownReferenceView(workspace: workspace, controller: controller)
            }
    }
}

struct MarkdownReferenceView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var controller: MarkdownReferenceController
    @State private var project = false
    @State private var problemsOnly = true
    @State private var selected: UUID?

    private var findings: [MarkdownReferenceCheck.Finding] {
        (controller.report?.findings ?? []).filter { !problemsOnly || $0.status != .valid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lokale Markdown-Verweise").fastraFont(.headline)
            Text("Prüft Datei- und Bildziele sowie Markdown- und HTML-Anker ausschließlich lokal. Netzadressen werden nicht geöffnet. Die Liste ist eine Momentaufnahme; Dateien werden nicht geändert.")
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("Bereich", selection: Binding(get: { project }, set: { value in
                    guard project != value else { return }
                    project = value; selected = nil; controller.invalidateScope()
                })) {
                    Text("Dokument").tag(false)
                    Text("Projekt").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                    .disabled(controller.running || workspace.projectURL == nil)
                    .background(SelfTestMarker(id: project ? "referenceScopeProject" : "referenceScopeDocument").frame(width: 0, height: 0))
                Spacer()
                if controller.running {
                    Button("Abbrechen") { controller.cancel() }
                        .background(SelfTestMarker(id: "referenceCancel").frame(width: 0, height: 0))
                } else {
                    Button(L10n.string(controller.report == nil ? "Prüfen" : "Erneut prüfen")) { controller.start(in: workspace, project: project) }
                        .keyboardShortcut(.defaultAction)
                        .background(SelfTestMarker(id: "referenceStart").frame(width: 0, height: 0))
                }
            }
            Text("Projekt-Ausschlüsse gelten. Versteckte Dateien, Pakete und Linkquellen bleiben ausgeschlossen. Grenzen: 200 Dateien, 10 MiB und 200.000 Umbruchzeichen je Quelle, 64 MiB insgesamt sowie jeweils 10.000 Verweise und Anker. Gequotete HTML-Verweise werden geprüft; weitere Grenzen stehen in der Hilfe.")
                .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if controller.running {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(verbatim: controller.progress.map { fileCount($0.files) + " · " + referenceCount($0.references) + " · " + $0.title } ?? L10n.string("Verweise werden geprüft…"))
                        .lineLimit(1).truncationMode(.middle)
                }.background(SelfTestMarker(id: "referenceRunning").frame(width: 0, height: 0))
            }
            if controller.cancelled { warning(L10n.string("Abgebrochen – Ergebnis unvollständig.")) }
            if let notice = controller.notice { warning(notice) }
            if let report = controller.report {
                HStack {
                    Label(L10n.string(report.isComplete ? "Prüfung vollständig" : "Prüfung unvollständig"), systemImage: report.isComplete ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(report.isComplete ? Theme.textSecondary : .orange)
                    Spacer()
                    Text(report.completedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(Theme.textSecondary)
                }.background(SelfTestMarker(id: "referenceFinished").frame(width: 0, height: 0))
                if let root = report.projectRoot {
                    Text(verbatim: L10n.format("Geprüftes Projekt: %@", root.path)).fastraFont(.small)
                        .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle).help(root.path)
                } else if let source = report.sources.first {
                    Text(verbatim: L10n.format("Geprüftes Dokument: %@", source.url?.path ?? source.title)).fastraFont(.small)
                        .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Text(verbatim: fileCount(report.sources.count) + " · " + localReferenceCount(report.findings.count) + " · " + skippedAddressCount(report.remoteCount))
                    .fastraFont(.small).foregroundStyle(Theme.textSecondary)
                if controller.hasChanged(in: workspace) { warning(L10n.string("Die Quelle wurde geändert oder geschlossen. Bitte erneut prüfen.")) }
                if !report.issues.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in warning(issue) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 80)
                }
            }
            Toggle("Nur Probleme anzeigen", isOn: $problemsOnly)
                .background(SelfTestMarker(id: "referenceProblemsOnly").allowsHitTesting(false))
                .background(SelfTestMarker(id: problemsOnly ? "referenceFilterOn" : "referenceFilterOff").frame(width: 0, height: 0))
            List(selection: $selected) {
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: sourceTitle(finding) + ":" + String(finding.reference.line)).fontWeight(.medium)
                                .lineLimit(1).truncationMode(.middle).help(sourceTitle(finding))
                            Spacer()
                            Text(verbatim: finding.status.title).foregroundStyle(finding.status == .valid ? Theme.textSecondary : .orange)
                        }
                        Text(verbatim: displayedDestination(finding.reference.destination))
                            .lineLimit(2).truncationMode(.middle)
                        Text(verbatim: finding.message).fastraFont(.small).foregroundStyle(Theme.textSecondary)
                    }.padding(.vertical, 4).tag(finding.id)
                        .background(SelfTestMarker(id: "referenceFinding-" + String(finding.reference.line)).frame(width: 0, height: 0))
                }
            }.frame(minHeight: 180).listStyle(.inset)
                .overlay { if !controller.running && findings.isEmpty { Text(verbatim: L10n.string(controller.cancelled ? "Keine abgeschlossenen Befunde." : controller.report == nil ? "Noch keine Prüfung ausgeführt." : "Keine Befunde in dieser Ansicht.")).foregroundStyle(Theme.textSecondary) } }
            HStack {
                Button("Schließen") { controller.close() }.keyboardShortcut(.cancelAction)
                    .background(SelfTestMarker(id: "referenceClose").frame(width: 0, height: 0))
                Spacer()
                Button("Zur Quelle") {
                    if let finding = findings.first(where: { $0.id == selected }) { controller.jump(to: finding, in: workspace) }
                }.disabled(controller.running || !findings.contains(where: { $0.id == selected }))
                    .background(SelfTestMarker(id: "referenceJump").frame(width: 0, height: 0))
                    .background(SelfTestMarker(id: findings.contains(where: { $0.id == selected }) ? "referenceJumpReady" : "referenceJumpBlocked").frame(width: 0, height: 0))
            }
        }.padding(20).frame(minWidth: 640, idealWidth: 900, minHeight: 600, idealHeight: 700)
            .fastraScalingRoot().onDisappear { controller.cancel() }
            .onChange(of: problemsOnly) { _, _ in selected = nil }
    }

    private func fileCount(_ count: Int) -> String {
        count == 1 ? L10n.string("1 Datei") : L10n.format("%d Dateien", count)
    }

    private func referenceCount(_ count: Int) -> String {
        count == 1 ? L10n.string("1 Verweis") : L10n.format("%d Verweise", count)
    }

    private func localReferenceCount(_ count: Int) -> String {
        count == 1 ? L10n.string("1 lokaler Verweis") : L10n.format("%d lokale Verweise", count)
    }

    private func skippedAddressCount(_ count: Int) -> String {
        count == 1 ? L10n.string("1 andere Adresse übersprungen") : L10n.format("%d andere Adressen übersprungen", count)
    }

    private func sourceTitle(_ finding: MarkdownReferenceCheck.Finding) -> String {
        guard let source = controller.report?.sources.first(where: { $0.id == finding.sourceID }) else { return "—" }
        return source.url?.path ?? source.title
    }

    private func warning(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func displayedDestination(_ value: String) -> String {
        if value.isEmpty { return "#" }
        let prefix = value.unicodeScalars.prefix(4096)
        return prefix.endIndex == value.unicodeScalars.endIndex ? value : String(prefix) + "…"
    }
}
