import SwiftUI

struct TextSnippetSheet: View {
    @ObservedObject var session: TextSnippetSession
    @State private var pendingAction: (() -> Void)?
    @State private var showDiscard = false
    @State private var showDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus")
                Text("Textbausteine").fontWeight(.semibold)
                Spacer()
                Text("Lokal gespeichert · keine Skripte").foregroundStyle(Theme.textSecondary).fastraFont(.small)
            }.padding(12)
            Divider()
            HSplitView {
                library
                editor
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error = session.error ?? session.validationMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
                        .background(SelfTestMarker(id: "snippetError").frame(width: 0, height: 0))
                }
                if !session.targetIsCurrent {
                    Text(TextSnippetError.staleTarget.localizedDescription).foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status = session.status { Text(status).foregroundStyle(Theme.textSecondary) }
                HStack(alignment: .center, spacing: 12) {
                    Text("Ersetzt die beim Öffnen festgehaltene Auswahl als einen Undo-Schritt. Die Datei wird erst beim Speichern geändert.")
                        .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Schließen") { protectDraft { session.close() } }
                        .keyboardShortcut(.cancelAction).disabled(session.isBusy)
                        .background(SelfTestMarker(id: "snippetClose").frame(width: 0, height: 0))
                    Button("Baustein einfügen") { session.insert() }
                        .keyboardShortcut(.defaultAction).disabled(!session.canInsert)
                        .background(SelfTestMarker(id: "snippetInsert").frame(width: 0, height: 0))
                }
            }.padding(12)
        }.fastraFont(.ui).background(Theme.surfaceRaised)
            .frame(minWidth: 760, idealWidth: 960, minHeight: 650, idealHeight: 740)
            .interactiveDismissDisabled()
            .onDisappear { session.cancel() }
            .alert("Ungespeicherte Änderungen am Textbaustein", isPresented: $showDiscard) {
                Button("Speichern") { if session.save() { pendingAction?(); pendingAction = nil } }
                Button("Verwerfen", role: .destructive) { pendingAction?(); pendingAction = nil }
                Button("Zurück", role: .cancel) { pendingAction = nil }
            } message: { Text("Die Vorlage wurde geändert. Der Dokumentinhalt bleibt bis zum Einfügen unverändert.") }
            .alert("Textbaustein löschen?", isPresented: $showDelete) {
                Button("Löschen", role: .destructive) { protectDraft { session.remove() } }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text(session.definition.name) }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Textbausteine durchsuchen", text: $session.filter).textFieldStyle(.roundedBorder)
                .background(SelfTestMarker(id: "snippetFilter").frame(width: 0, height: 0))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if session.saved.isEmpty {
                        Text("Noch keine Textbausteine. Erstelle eine Vorlage mit Neu.")
                            .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).padding(6)
                    } else if session.filtered.isEmpty {
                        Text("Keine passenden Textbausteine.").foregroundStyle(Theme.textSecondary).padding(6)
                    }
                    ForEach(session.filtered) { value in
                        Button { protectDraft { session.choose(value) } } label: {
                            Text(value.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                .background(value.id == session.definition.id ? Theme.accentReadable.opacity(0.15) : .clear)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(value.name)
                            .background(SelfTestMarker(id: "snippetSaved-" + value.id.uuidString).frame(width: 0, height: 0))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Neu") { protectDraft { session.new() } }
                    .background(SelfTestMarker(id: "snippetNew").frame(width: 0, height: 0))
                Button("Duplizieren") { protectDraft { session.new(copy: true) } }
                    .background(SelfTestMarker(id: "snippetDuplicate").frame(width: 0, height: 0))
            }
            Button("Neu laden") { protectDraft { session.reload() } }
                .background(SelfTestMarker(id: "snippetReload").frame(width: 0, height: 0))
            Button("Importieren…") { protectDraft { session.importFile() } }
                .background(SelfTestMarker(id: "snippetImport").frame(width: 0, height: 0))
            Button("Sammlung exportieren…") { session.exportFile() }.disabled(session.saved.isEmpty)
                .background(SelfTestMarker(id: "snippetExport").frame(width: 0, height: 0))
            Button("Löschen…") { showDelete = true }.disabled(!session.canRemove)
                .background(SelfTestMarker(id: "snippetDelete").frame(width: 0, height: 0))
            Text("Bis zu 50 Textbausteine. Import: höchstens 1 MiB; Namenskonflikte werden durch Nummern aufgelöst.")
                .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(minWidth: 180, idealWidth: 210, maxWidth: 260).disabled(session.isBusy)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name des Textbausteins", text: $session.definition.name).textFieldStyle(.roundedBorder)
                    .id(session.definition.id)
                    .background(SelfTestMarker(id: "snippetName").frame(width: 0, height: 0))
                Button("Speichern") { _ = session.save() }.disabled(!session.canSave)
                    .background(SelfTestMarker(id: "snippetSave").frame(width: 0, height: 0))
            }
            if session.dirty {
                Text("Speichere die Vorlage vor dem Einfügen.").fastraFont(.small).foregroundStyle(Theme.textSecondary)
            }
            Text("Vorlage").fontWeight(.semibold)
            SnippetTextInput(text: $session.definition.template, identifier: "snippetTemplateInput",
                             label: L10n.string("Vorlage"), byteLimit: TextSnippetTemplate.maximumTemplateBytes,
                             onLimit: session.showLimitError)
                .id(session.definition.id).frame(minHeight: 90, idealHeight: 130, maxHeight: 170)
            Text("Platzhalter: {{Name}}. Wiederholte Namen teilen ein Feld. Feldwerte werden wörtlich eingesetzt; Return fügt einen Zeilenumbruch ein.")
                .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if !session.placeholders.isEmpty {
                Text("Platzhalter ausfüllen").fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(session.placeholders.enumerated()), id: \.element) { index, name in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).lineLimit(2)
                                SnippetTextInput(text: Binding(get: { session.values[name] ?? "" },
                                                              set: { session.values[name] = $0 }),
                                                 identifier: "snippetValue-\(index)", label: name,
                                                 byteLimit: TextSnippetTemplate.maximumValueBytes,
                                                 tabMovesFocus: true, onLimit: session.showLimitError)
                                    .frame(height: 58)
                            }
                        }
                    }.padding(.trailing, 8)
                }.frame(minHeight: 80, idealHeight: 160, maxHeight: .infinity)
                Text("Tab: nächstes Feld · Umschalt-Tab: vorheriges Feld · Leere Werte sind erlaubt.")
                    .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Einfügevorschau").fontWeight(.semibold)
            SnippetTextInput(text: .constant(session.preview ?? ""), identifier: "snippetPreviewInput",
                             label: L10n.string("Einfügevorschau"), byteLimit: TextSnippetTemplate.maximumOutputBytes, editable: false)
                .frame(minHeight: 70, idealHeight: 100, maxHeight: 150)
            Text("Grenzen: 16 KiB pro Vorlage und Feldwert, 32 verschiedene Platzhalter, 256 KiB Ergebnis.")
                .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(minWidth: 530, maxWidth: .infinity, maxHeight: .infinity).disabled(session.isBusy)
    }

    private func protectDraft(_ action: @escaping () -> Void) {
        if session.dirty { pendingAction = action; showDiscard = true }
        else { action() }
    }
}

struct TextSnippetButton: View {
    @ObservedObject var workspace: Workspace
    var compact = false
    var body: some View {
        Button { workspace.openTextSnippets() } label: {
            if compact { Image(systemName: "text.badge.plus").frame(width: 26, height: 24) }
            else { Label("Textbausteine…", systemImage: "text.badge.plus").padding(.horizontal, 8).padding(.vertical, 5) }
        }.buttonStyle(.plain).disabled(!workspace.canUseTextSnippets)
            .help("Textbausteine mit ausfüllbaren Platzhaltern einfügen")
            .accessibilityLabel("Textbausteine…")
            .background(SelfTestMarker(id: "snippetOpen").frame(width: 0, height: 0))
    }
}
