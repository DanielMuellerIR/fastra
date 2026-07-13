//
// PatternEditorView.swift
//
// Kleine, native Bearbeitungsansicht für eigene Vorlagen und ein
// Beispiel-Transformationsblatt. AppKit-Panels halten Datei-Import und
// -Export bewusst aus der SwiftUI-Logik heraus.

import AppKit
import SwiftUI

struct PatternEditorView: View {
    @ObservedObject var library: PatternLibrary
    let onApply: (PatternTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var name = ""
    @State private var regex = ""
    @State private var replacement = ""
    @State private var category = PatternCategory.textStructure
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(library.templates) { template in
                    Text(template.name).tag(template.id as String?)
                }
            }
            .frame(minWidth: 180)
            .onChange(of: selectedID) { _, id in load(id: id) }

            Divider()
            Form {
                TextField("Name", text: $name)
                Picker("Kategorie", selection: $category) {
                    ForEach(PatternCategory.allCases, id: \.self) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                TextField("RegEx", text: $regex, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                TextField("Ersetzen (optional)", text: $replacement, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                if let message { Text(message).foregroundStyle(Theme.diffRemovedFG) }
                HStack {
                    Button("Neu") { clear() }
                    Button("Löschen", role: .destructive) {
                        if let selectedID { library.delete(id: selectedID) }
                        clear()
                    }
                    .disabled(selectedID == nil)
                    Spacer()
                    Button("Importieren…") { importTemplates() }
                    Button("Exportieren…") { exportTemplates() }
                    Button("Anwenden") { applyCurrent() }
                    Button("Speichern") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(minWidth: 430)
        }
        .frame(width: 720, height: 430)
    }

    private func load(id: String?) {
        guard let id, let template = library.templates.first(where: { $0.id == id }) else { return }
        name = template.name; regex = template.regex
        replacement = template.defaultReplacement ?? ""; category = template.category
    }

    private func clear() {
        selectedID = nil; name = ""; regex = ""; replacement = ""
        category = .textStructure; message = nil
    }

    private func makeTemplate() -> PatternTemplate {
        PatternTemplate(id: selectedID ?? "user-\(UUID().uuidString.lowercased())",
                        name: name, category: category, regex: regex,
                        exampleMatch: "", defaultReplacement: replacement.isEmpty ? nil : replacement)
    }

    private func save() {
        do { try library.save(makeTemplate()); message = nil }
        catch { message = error.localizedDescription }
    }

    private func applyCurrent() {
        let template = makeTemplate()
        do { _ = try template.compile(); onApply(template); dismiss() }
        catch { message = error.localizedDescription }
    }

    private func importTemplates() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { message = "\(try library.import(data: Data(contentsOf: url))) Vorlagen importiert." }
        catch { message = error.localizedDescription }
    }

    private func exportTemplates() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Fastra-Vorlagen.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.exportData().write(to: url, options: .atomic); message = "Vorlagen exportiert." }
        catch { message = error.localizedDescription }
    }
}

struct ExampleTransformationView: View {
    let onApply: (ExampleTransformation.Inference) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = "ring, The"
    @State private var destination = "The ring"

    private var inference: ExampleTransformation.Inference? {
        ExampleTransformation.infer(source: source, destination: destination)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transformation per Beispiel").font(.headline)
            Text("Fastra übernimmt den gemeinsamen Teil als Platzhalter und zeigt das daraus abgeleitete Suchen-und-Ersetzen-Muster.")
                .foregroundStyle(.secondary)
            TextField("Vorher", text: $source)
                .font(.system(.body, design: .monospaced))
            TextField("Nachher", text: $destination)
                .font(.system(.body, design: .monospaced))
            if let inference {
                VStack(alignment: .leading) {
                    Text("Suchen: \(inference.findPattern)").font(.system(.body, design: .monospaced))
                    Text("Ersetzen: \(inference.replacePattern)").font(.system(.body, design: .monospaced))
                }
                .padding(8).background(Theme.surfaceSand.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Für dieses Paar lässt sich kein sicheres Platzhalter-Muster ableiten.")
                    .foregroundStyle(Theme.diffRemovedFG)
            }
            HStack { Spacer(); Button("Abbrechen") { dismiss() }; Button("Übernehmen") { if let inference { onApply(inference); dismiss() } }.disabled(inference == nil).keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520)
    }
}
