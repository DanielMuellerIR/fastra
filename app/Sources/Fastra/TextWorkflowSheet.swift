import SwiftUI

extension TextWorkflowStep.Kind {
    var title: String {
        if let operation = textOperation { return operation.title }
        switch self {
        case .replace: return L10n.string("Suchen und Ersetzen")
        case .sortAscending: return LineOperations.SortDirection.ascending.title
        case .sortDescending: return LineOperations.SortDirection.descending.title
        case .removeDuplicateLines: return L10n.string("Duplikate entfernen")
        default: return rawValue
        }
    }
}

struct TextWorkflowSheet: View {
    @ObservedObject var session: TextWorkflowSession
    @State private var selectedStep: UUID?
    @State private var pendingAction: (() -> Void)?
    @State private var showDiscard = false
    @State private var showDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                Text("Gespeicherte Textabläufe").fontWeight(.semibold)
                Spacer()
                Text("Alle Schritte wirken zuerst auf eine Vorschau.").foregroundStyle(Theme.textSecondary)
            }.padding(12)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gespeichert").fontWeight(.semibold)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.saved) { definition in
                                Button { protectDraft { session.choose(definition); selectedStep = nil } } label: {
                                    Text(definition.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                        .background(definition.id == session.definition.id ? Theme.accentReadable.opacity(0.15) : .clear)
                                }.buttonStyle(.plain)
                                    .help(definition.name)
                            }
                        }
                    }
                    HStack {
                        Button("Neu") { protectDraft { session.new(); selectedStep = nil } }
                        Button("Duplizieren") { protectDraft { session.new(copy: true); selectedStep = nil } }
                    }
                    Button("Neu laden") { protectDraft { session.reloadSaved(); selectedStep = nil } }
                    HStack {
                        Button("Importieren…") { protectDraft { session.importFile(); selectedStep = nil } }
                        Button("Exportieren…") { session.exportFile() }
                    }
                    Button("Gespeicherten Ablauf löschen…") { showDelete = true }
                        .disabled(!session.saved.contains { $0.id == session.definition.id })
                }.padding(12).frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                    .disabled(session.isBusy)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name des Ablaufs", text: session.nameBinding).textFieldStyle(.roundedBorder)
                            .id(session.definition.id)
                            .disabled(session.isBusy)
                            .background(SelfTestMarker(id: "textWorkflowName").frame(width: 0, height: 0))
                        Button("Speichern") { _ = session.save() }.disabled(!session.dirty || session.isBusy)
                            .background(SelfTestMarker(id: "textWorkflowSave").frame(width: 0, height: 0))
                    }
                    if session.dirty {
                        Text("Speichere die Ablaufdefinition vor dem Anwenden.").foregroundStyle(Theme.textSecondary).fastraFont(.small)
                    }
                    HStack {
                        Picker("Bereich", selection: $session.scope) {
                            ForEach(TextWorkflowScope.allCases) { scope in
                                Text(scope.title).tag(scope).disabled(scope == .project && session.workspace?.projectURL == nil)
                            }
                        }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(session.isBusy)
                            .background(SelfTestMarker(id: "textWorkflowBatchScope").frame(width: 0, height: 0))
                        Button("Vorschau berechnen") { session.calculate() }.disabled(session.isBusy)
                            .background(SelfTestMarker(id: "textWorkflowPreview").frame(width: 0, height: 0))
                    }
                    scopeControls.disabled(session.isBusy)
                    Text(session.sourceDescription)
                        .foregroundStyle(Theme.textSecondary).fastraFont(.small).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            List(selection: $selectedStep) {
                                ForEach(Array(session.definition.steps.enumerated()), id: \.element.id) { index, step in
                                    HStack {
                                        Toggle("Aktiv", isOn: session.binding(for: step).enabled).labelsHidden()
                                        Text("\(index+1). \(step.kind.title)").lineLimit(2)
                                    }.tag(step.id)
                                }
                            }.frame(minWidth: 210, idealWidth: 230, maxWidth: 300)
                            HStack(spacing: 6) {
                                Menu("Schritt hinzufügen") {
                                    ForEach(TextWorkflowStep.Kind.allCases, id: \.self) { kind in
                                        Button(kind.title) {
                                            let step = TextWorkflowStep(kind: kind)
                                            session.definition.steps.append(step); selectedStep = step.id
                                        }
                                    }
                                }.disabled(session.definition.steps.count >= 32)
                                    .background(SelfTestMarker(id: "textWorkflowAddStep").frame(width: 0, height: 0))
                                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(stepIndex == nil || stepIndex == 0).help("Schritt nach oben verschieben")
                                Button { move(1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(stepIndex == nil || stepIndex == session.definition.steps.count-1).help("Schritt nach unten verschieben")
                                Button {
                                    if let index = stepIndex { session.definition.steps.remove(at: index); selectedStep = nil }
                                } label: { Image(systemName: "minus") }.disabled(stepIndex == nil).help("Schritt entfernen")
                            }
                        }
                        Group {
                            if let index = stepIndex { TextWorkflowStepEditor(step: session.binding(for: session.definition.steps[index])).id(session.definition.steps[index].id) }
                            else { Text("Wähle einen Schritt, um seine Parameter zu bearbeiten.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.frame(minWidth: 260, maxWidth: .infinity)
                    }.frame(height: session.scope == .document ? 220 : 180).disabled(session.isBusy)
                    Divider()
                    HSplitView {
                    if let batch = session.batch {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.format("Eingaben: %ld · Änderungen: %ld", batch.entries.count, batch.changedCount)).fontWeight(.semibold)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(batch.entries) { entry in
                                        Button { session.selectInput(entry.id) } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(alignment: .top) {
                                                    Image(systemName: entry.issue != nil ? "exclamationmark.triangle" : entry.preview?.changed == true ? "pencil" : "equal")
                                                        .foregroundStyle(entry.issue != nil ? Color.red : Theme.textSecondary)
                                                    Text(entry.title).lineLimit(2)
                                                }
                                                Text(entry.issue ?? (entry.preview?.changed == true ? L10n.string("Änderung") : L10n.string("Keine wirksame Änderung")))
                                                    .fastraFont(.small).foregroundStyle(entry.issue != nil ? Color.red : Theme.textSecondary)
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                                .background(session.selectedInputID == entry.id ? Theme.accentReadable.opacity(0.15) : .clear)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).help(entry.detail)
                                            .background(SelfTestMarker(id: "textWorkflowInput-" + entry.id).frame(width: 0, height: 0))
                                    }
                                }
                            }
                        }.frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                    if let preview = session.visiblePreview {
                        if let entry = session.batch?.entries.first(where: { $0.id == session.selectedInputID }) {
                            Text(entry.detail).fastraFont(.small).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Picker("Vorschau", selection: Binding(get: { session.selectedPreview }, set: { session.showPreview($0) })) {
                                Text("Gesamtergebnis").tag(-1)
                                ForEach(preview.steps) { step in
                                    Text(String(format: L10n.string("Nach Schritt %ld: %@"), step.index+1,
                                                session.definition.steps[step.index].kind.title)).tag(step.index)
                                }
                            }.frame(maxWidth: 420)
                                .background(SelfTestMarker(id: "textWorkflowPreviewChoice").frame(width: 0, height: 0))
                            Spacer()
                            if session.selectedPreview == -1 && !preview.changed { Text("Keine wirksame Änderung").foregroundStyle(Theme.textSecondary) }
                        }
                        if session.representationDetails {
                            Text("Zusätze in ⟦…⟧ zeigen Unicode-Werte und Zeilenenden. Sie gehören nur zur Vorschau und werden nicht eingefügt.")
                                .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let request = session.diffRequest, let document = session.diffDocument {
                            FileDiffView(request: request, document: document, allowsExport: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    } else {
                        VStack(spacing: 10) {
                            if session.isBusy { ProgressView() }
                            Text(session.batch?.entries.first(where: { $0.id == session.selectedInputID })?.issue
                                 ?? session.progressText ?? (session.isBusy ? L10n.string("Vorschau wird berechnet…") : L10n.string("Berechne die Vorschau, um jeden Schritt und das Gesamtergebnis zu prüfen.")))
                                .foregroundStyle(Theme.textSecondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    }.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxHeight: .infinity)
                }.padding(12).frame(minWidth: 650, maxWidth: .infinity)
            }
            Divider()
            if let error = session.error {
                TextWorkflowErrorPanel(message: error)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            if let status = session.status {
                Text(status).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
            }
            if session.scope == .openDocuments && session.appliedDocuments != nil && !session.canRestoreDocuments && !session.isBusy {
                Text("Die gemeinsame Rücknahme ist auf dem aktuellen Dokumentstand nicht verfügbar. Warte auf laufende Dateioperationen oder nutze den einzelnen Dokumentverlauf.")
                    .fastraFont(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
            }
            if session.isBusy, let progress = session.progressText {
                Text(progress).fastraFont(.small).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            HStack(spacing: 10) {
                Text(session.scope == .document ? L10n.string("Grenzen: 32 Schritte, 4 MiB Text, 50 gespeicherte Abläufe. Anwenden ist ein Undo-Schritt.")
                     : L10n.string("Grenzen: 500 Eingaben, 64 MiB je Datenbudget, 4 MiB Text pro Eingabe. Fehler blockieren den gesamten Plan."))
                    .fastraFont(.small).foregroundStyle(Theme.textSecondary)
                Spacer()
                if session.scope == .openDocuments && session.appliedDocuments != nil {
                    Button(session.memoryRestored ? L10n.string("Gemeinsam wiederherstellen") : L10n.string("Speicheränderungen zurücknehmen")) { session.restoreDocuments() }
                        .disabled(!session.canRestoreDocuments)
                        .help("Die gemeinsame Rücknahme benötigt alle Dokumente auf der exakt angewendeten Basis.")
                        .background(SelfTestMarker(id: "textWorkflowMemoryUndo").frame(width: 0, height: 0))
                }
                if session.scope.isDisk && session.diskAppliedSession != nil {
                    Button("Plattenänderungen zurücknehmen") { session.restoreDisk() }.disabled(session.isBusy)
                        .background(SelfTestMarker(id: "textWorkflowDiskUndo").frame(width: 0, height: 0))
                }
                if session.isBusy {
                    Button("Abbrechen") { session.abortCalculation() }.disabled(!session.canCancelCalculation)
                }
                Button("Schließen") { protectDraft { session.close() } }.keyboardShortcut(.cancelAction).disabled(session.isBusy)
                    .background(SelfTestMarker(id: "textWorkflowClose").frame(width: 0, height: 0))
                Button(session.scope.isDisk ? L10n.string("Auf Platte anwenden") : L10n.string("Im Speicher anwenden")) { _ = session.apply() }
                    .keyboardShortcut(.defaultAction).disabled(!session.canApply)
                    .help("Die vollständig geprüften Gesamtergebnisse auf dieselben Eingaben anwenden.")
                    .background(SelfTestMarker(id: "textWorkflowApply").frame(width: 0, height: 0))
            }.padding(12)
        }.fastraFont(.ui).frame(minWidth: 900, idealWidth: 1100, minHeight: 760, idealHeight: 820)
            .background(Theme.surfaceRaised)
            .interactiveDismissDisabled()
            .onAppear { selectedStep = session.definition.steps.first?.id }
            .onDisappear { session.cancel() }
            .alert("Ungespeicherte Änderungen am Ablauf", isPresented: $showDiscard) {
                Button("Speichern") { if session.save() { pendingAction?(); pendingAction = nil } }
                Button("Verwerfen", role: .destructive) { pendingAction?(); pendingAction = nil }
                Button("Zurück", role: .cancel) { pendingAction = nil }
            } message: { Text("Die Ablaufdefinition wurde geändert. Der Dokumentinhalt bleibt bis zum Anwenden unverändert.") }
            .alert("Gespeicherten Ablauf löschen?", isPresented: $showDelete) {
                Button("Löschen", role: .destructive) { session.remove(); selectedStep = nil }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text(session.definition.name) }
    }

    @ViewBuilder private var scopeControls: some View {
        if session.scope == .document {
            Picker("Wirkbereich", selection: $session.selectionOnly) {
                Text("Ganzes Dokument").tag(false)
                Text("Auswahl (exakter Bereich)").tag(true).disabled(session.snapshot.selection.length == 0)
            }.pickerStyle(.segmented)
                .background(SelfTestMarker(id: "textWorkflowScope").frame(width: 0, height: 0))
        } else if session.scope.isDisk {
            HStack(alignment: .top, spacing: 12) {
                if session.scope == .folder {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Ordner").fontWeight(.semibold)
                            Button("Hinzufügen…") { session.chooseFolder() }
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(session.folderURLs, id: \.self) { url in
                                    HStack {
                                        Text(url.path).lineLimit(1).truncationMode(.middle).help(url.path)
                                        Spacer(minLength: 0)
                                        Button { session.folderURLs.removeAll { $0 == url } } label: { Image(systemName: "xmark") }.help("Ordner entfernen")
                                    }
                                }
                            }
                        }.frame(height: 48)
                    }.frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.workspace?.projectURL?.path ?? "").lineLimit(1).truncationMode(.middle)
                        Picker("Datei-Set", selection: $session.projectSetID) {
                            ForEach(session.workspace?.projectSearchConfiguration.fileSets ?? []) { set in
                                Text(set.name).tag(Optional(set.id))
                            }
                        }
                        TextField("Ausschlüsse", text: $session.exclusionsText).textFieldStyle(.roundedBorder)
                    }.frame(maxWidth: .infinity)
                }
                Picker("Dateitypen", selection: $session.fileFilter) {
                    ForEach(FileTypeFilter.allCases) { filter in Text(L10n.string(filter.rawValue)).tag(filter) }
                }.frame(width: 260)
            }
        }
    }

    private var stepIndex: Int? { session.definition.steps.firstIndex { $0.id == selectedStep } }
    private func move(_ delta: Int) {
        guard let index = stepIndex, session.definition.steps.indices.contains(index+delta) else { return }
        session.definition.steps.swapAt(index, index+delta)
    }
    private func protectDraft(_ action: @escaping () -> Void) {
        if session.dirty { pendingAction = action; showDiscard = true }
        else { action() }
    }
}

private struct TextWorkflowStepEditor: View {
    @Binding var step: TextWorkflowStep
    var body: some View {
        Form {
            Picker("Aktion", selection: $step.kind) {
                ForEach(TextWorkflowStep.Kind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            switch step.kind {
            case .replace:
                TextField("Suchen", text: $step.find, axis: .vertical).lineLimit(1...3)
                TextField("Ersetzen", text: $step.replacement, axis: .vertical).lineLimit(1...3)
                HStack { Toggle("RegEx", isOn: $step.regex); Toggle("Groß-/Kleinschreibung", isOn: $step.caseSensitive) }
                HStack { Toggle("Ganzes Wort", isOn: $step.wholeWord); if !step.regex { Toggle("Sterne wörtlich", isOn: $step.literalWildcard) } }
            case .prefixLines, .suffixLines:
                TextField("Text", text: $step.argument, axis: .vertical).lineLimit(1...3)
            case .keepLinesMatching, .deleteLinesMatching:
                TextField("RegEx-Muster", text: $step.argument, axis: .vertical).lineLimit(1...3)
                Toggle("Groß-/Kleinschreibung", isOn: $step.caseSensitive)
                Text("Wie beim Einzelbefehl bleibt der Text erhalten, wenn der Filter alle Zeilen entfernen würde.").foregroundStyle(Theme.textSecondary)
            case .hardWrap:
                TextField("Spaltenbreite", value: $step.wrapColumn, format: .number)
            case .detab, .entab, .shiftRight, .shiftLeft:
                Stepper(value: $step.tabWidth, in: 1...16) { Text(String(format: L10n.string("Tabbreite: %ld"), step.tabWidth)) }
                if step.kind == .shiftRight || step.kind == .shiftLeft {
                    Toggle("Mit Tabs einrücken", isOn: $step.usesTabs)
                    Stepper(value: $step.indentWidth, in: 1...16) { Text(String(format: L10n.string("Einrückbreite: %ld"), step.indentWidth)) }
                }
            default: Text("Dieser Schritt benötigt keine weiteren Parameter.").foregroundStyle(Theme.textSecondary)
            }
        }.formStyle(.grouped)
    }
}

/// Lange Konfliktlisten bleiben vollständig scrollbar, ohne die
/// Dialogaktionen aus der sichtbaren Fläche zu schieben.
private struct TextWorkflowErrorPanel: View {
    let message: String
    @State private var contentHeight: CGFloat = 18

    var body: some View {
        ScrollView {
            Text(message).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TextWorkflowErrorHeightKey.self, value: geometry.size.height)
                })
                .background(SelfTestMarker(id: "textWorkflowErrorContent").frame(width: 0, height: 0))
        }
        .frame(height: min(96, max(18, contentHeight)))
        .onPreferenceChange(TextWorkflowErrorHeightKey.self) { height in
            if height.isFinite && height > 0 && abs(contentHeight - height) > 0.5 { contentHeight = height }
        }
    }
}

private struct TextWorkflowErrorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
