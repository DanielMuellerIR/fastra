import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TextSnippetSession: ObservableObject, Identifiable {
    let id = UUID()
    weak var workspace: Workspace?
    private let target: TextSnippetInsertionTarget
    private let store: TextSnippetStore
    @Published private(set) var saved: [TextSnippetDefinition] = []
    @Published var definition: TextSnippetDefinition {
        didSet { if !oldValue.template.utf8.elementsEqual(definition.template.utf8) { updateValues() }; error = nil; status = nil }
    }
    @Published var values: [String: String] = [:]
    @Published var filter = ""
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    private var baseline: TextSnippetDefinition?
    private var closed = false
    private var observation: AnyCancellable?

    init(workspace: Workspace, target: TextSnippetInsertionTarget, store: TextSnippetStore? = nil) {
        self.workspace = workspace; self.target = target; self.store = store ?? TextSnippetStore()
        definition = TextSnippetDefinition(name: L10n.string("Neuer Textbaustein"), template: "{{Text}}")
        _ = objectWillChange
        do {
            saved = try self.store.load()
            if let first = saved.first { definition = first; baseline = first }
        } catch { self.error = error.localizedDescription }
        updateValues()
        observation = workspace.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    var dirty: Bool { baseline != definition }
    var placeholders: [String] { (try? TextSnippetTemplate(definition.template).names) ?? [] }
    var preview: String? { try? TextSnippetTemplate(definition.template).render(values: values) }
    var validationMessage: String? {
        do { try definition.validate(); _ = try TextSnippetTemplate(definition.template).render(values: values); return nil }
        catch { return error.localizedDescription }
    }
    var canSave: Bool { !closed && !isBusy && dirty && (try? definition.validate()) != nil }
    var canInsert: Bool { !closed && !isBusy && !dirty && validationMessage == nil && target.isCurrent }
    var targetIsCurrent: Bool { target.isCurrent }
    var canRemove: Bool { baseline != nil && saved.contains { $0.id == definition.id } }
    var filtered: [TextSnippetDefinition] {
        saved.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func updateValues() {
        let names = placeholders
        values = Dictionary(uniqueKeysWithValues: names.map { ($0, values[$0] ?? "") })
    }

    func choose(_ value: TextSnippetDefinition) {
        guard !isBusy else { return }
        values = [:]; definition = value; baseline = value; updateValues()
    }

    func new(copy: Bool = false) {
        guard !isBusy else { return }
        let name = copy ? definition.name + " " + L10n.string("Kopie") : L10n.string("Neuer Textbaustein")
        let text = copy ? definition.template : "{{Text}}"
        values = [:]
        definition = TextSnippetDefinition(name: TextSnippetStore.availableName(name, excluding: saved.map(\.name)), template: text)
        baseline = nil; updateValues()
    }

    @discardableResult func save() -> Bool {
        guard !closed, !isBusy else { return false }
        do {
            let value = try store.save(definition, expectedRevision: baseline?.revision)
            saved = try store.load(); definition = value; baseline = value
            status = L10n.string("Textbaustein gespeichert."); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func reload() {
        guard !isBusy else { return }
        do {
            saved = try store.load()
            if let current = saved.first(where: { $0.id == definition.id }) ?? saved.first { choose(current) }
            else { new() }
        } catch { self.error = error.localizedDescription }
    }

    func remove() {
        guard !closed, !isBusy, let baseline else { return }
        do {
            try store.remove(id: baseline.id, expectedRevision: baseline.revision)
            saved = try store.load()
            if let first = saved.first { choose(first) } else { new() }
            status = L10n.string("Textbaustein gelöscht.")
        } catch { self.error = error.localizedDescription }
    }

    func insert() {
        guard canInsert, let replacement = preview else { error = TextSnippetError.staleTarget.localizedDescription; return }
        isBusy = true; error = nil
        target.insert(replacement) { [weak self] result in
            guard let self, !self.closed else { return }
            self.isBusy = false
            switch result {
            case .success: self.close()
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func showLimitError() { error = TextSnippetError.sizeLimit.localizedDescription }

    func importFile() {
        guard !closed, !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        SelfTest.configureTextSnippetPanel(panel, importing: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true; error = nil
        Task {
            let result = await Task.detached { Result { try FileSnapshot.read(from: url, byteLimit: UInt64(TextSnippetArchive.maximumBytes)).data } }.value
            guard !closed else { return }
            isBusy = false
            do {
                let data = try result.get()
                let prepared = try store.prepareImport(data)
                let incoming = prepared.incoming
                let alert = NSAlert()
                alert.messageText = L10n.string("Textbausteine importieren?")
                alert.informativeText = L10n.string("Die vorhandene Sammlung bleibt erhalten. Folgende Namen werden übernommen; Namenskonflikte sind bereits nummeriert:")
                let names = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
                names.string = incoming.map(\.name).joined(separator: "\n")
                names.isEditable = false; names.isRichText = false
                names.font = .systemFont(ofSize: 12); names.textContainerInset = NSSize(width: 6, height: 6)
                names.isVerticallyResizable = true; names.isHorizontallyResizable = false
                names.autoresizingMask = [.width]; names.textContainer?.widthTracksTextView = true
                let list = NSScrollView(frame: names.frame); list.hasVerticalScroller = true
                list.borderType = .bezelBorder; list.documentView = names; alert.accessoryView = list
                alert.addButton(withTitle: L10n.string("Importieren"))
                alert.addButton(withTitle: L10n.string("Abbrechen"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let imported = try store.importPrepared(prepared); saved = try store.load()
                if let first = imported.first { choose(first) }
                status = L10n.format("%ld Textbausteine importiert. Doppelte Namen erhielten eine Nummer.", imported.count)
            } catch { self.error = error.localizedDescription }
        }
    }

    func exportFile() {
        guard !closed, !isBusy else { return }
        do {
            let data = try TextSnippetArchive.encode(store.load())
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = L10n.string("Textbausteine.json")
            SelfTest.configureTextSnippetPanel(panel, importing: false)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            isBusy = true; error = nil
            Task {
                let result = await Task.detached { Result { try data.write(to: url, options: .atomic) } }.value
                guard !closed else { return }
                isBusy = false
                switch result {
                case .success: status = L10n.string("Textbausteinsammlung exportiert.")
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func close() {
        guard !isBusy else { return }
        cancel(); workspace?.textSnippetSession = nil
    }
    func cancel() { closed = true; target.release() }
}

extension Workspace {
    var canUseTextSnippets: Bool {
        activeTab.map { $0.isEditableTextDocument && textEditingIsAllowed(for: $0) } == true
            && activeViewMode == .text
    }

    @MainActor func openTextSnippets() {
        guard textSnippetSession == nil else { return }
        TextSnippetInsertionTarget.capture(in: self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let target):
                guard self.textSnippetSession == nil, target.isCurrent else { target.release(); return }
                self.textSnippetSession = TextSnippetSession(workspace: self, target: target)
            case .failure(let error): self.saveSafetyWarningHandler(L10n.string("Textbausteine"), error.localizedDescription)
            }
        }
    }
}
