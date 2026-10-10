import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

/// Reine Darstellung pro geöffnetem Dokument; keine Änderung des Textes oder
/// seiner gespeicherten Formatierung. Unteroptionen überleben den Hauptschalter.
struct EditorDisplayOptions: Equatable, Hashable {
    var showInvisibles = false
    var showSpaces = true
    var showTabs = true
    var showLineEndings = true
    var showGutter = true

    var invisibleCharacters: InvisibleCharactersConfiguration {
        .init(showSpaces: showInvisibles && showSpaces,
              showTabs: showInvisibles && showTabs,
              showLineEndings: showInvisibles && showLineEndings)
    }
}

extension Workspace {
    var canConfigureTextDisplay: Bool {
        guard let tab = activeTab else { return false }
        return !isWelcomeScreen && !tab.isLoading && tab.displayMode == .text
            && activeViewMode == .text && !activeMarkdownIsVisual && !activeTabShowsDiff
    }

    var editorDisplayOptions: EditorDisplayOptions {
        activeTab?.editorDisplayOptions ?? .init()
    }

    func setEditorDisplayOption(_ key: WritableKeyPath<EditorDisplayOptions, Bool>, _ value: Bool) {
        guard canConfigureTextDisplay,
              let index = tabs.firstIndex(where: { $0.id == activeTab?.id }) else { return }
        tabs[index].editorDisplayOptions[keyPath: key] = value
    }
}

struct EditorOptionsButton: View {
    @EnvironmentObject private var workspace: Workspace
    @State private var showingOptions = false

    var body: some View {
        Button { showingOptions.toggle() } label: {
            Image(systemName: "gearshape")
                .fastraFont(size: 14)
                .foregroundStyle(showingOptions ? Theme.accentReadable : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Editoroptionen")
        .accessibilityLabel("Editoroptionen")
        .accessibilityIdentifier("editorOptionsButton")
        .background(SelfTestMarker(id: "editorOptionsButton"))
        .disabled(workspace.activeTab == nil || workspace.isWelcomeScreen)
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            EditorOptionsPopover().environmentObject(workspace)
        }
    }
}

struct EditorOptionsPopover: View {
    @EnvironmentObject private var workspace: Workspace
    @AppStorage("editor.showMinimap", store: SelfTest.workspaceDefaults()) private var showMinimap = false

    private func displayBinding(_ key: WritableKeyPath<EditorDisplayOptions, Bool>) -> Binding<Bool> {
        Binding(get: { workspace.editorDisplayOptions[keyPath: key] },
                set: { workspace.setEditorDisplayOption(key, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Editoroptionen").fastraFont(size: 16, weight: .semibold)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Umbruch und Einrückung").fontWeight(.semibold)
                    Text(verbatim: L10n.format("Gilt für: %@", workspace.softWrapScopeName))
                        .foregroundStyle(.secondary)
                    Toggle("Soft Wrap", isOn: Binding(
                        get: { workspace.softWrapEnabled }, set: { workspace.setSoftWrapEnabled($0) }))
                    Picker("Umbruchziel", selection: Binding(
                        get: { workspace.softWrapTarget }, set: { workspace.selectSoftWrapTarget($0) })) {
                        Text("Fensterbreite").tag(SoftWrapTarget.window)
                        Text("Page Guide").tag(SoftWrapTarget.pageGuide)
                        Text("Feste Breite").tag(SoftWrapTarget.fixedColumn)
                    }
                    .disabled(!workspace.softWrapEnabled)
                    Stepper(L10n.format("Feste Breite: Spalte %ld", workspace.softWrapFixedColumn),
                            value: Binding(get: { workspace.softWrapFixedColumn },
                                           set: { workspace.setSoftWrapFixedColumn($0) }),
                            in: SoftWrapProfileStore.validColumnRange)
                        .disabled(!workspace.softWrapEnabled || workspace.softWrapTarget != .fixedColumn)
                    Picker("Folgezeilen einrücken", selection: Binding(
                        get: { workspace.softWrapIndentation }, set: { workspace.setSoftWrapIndentation($0) })) {
                        Text("Bündig links").tag(SoftWrapIndentation.flushLeft)
                        Text("Wie erste Zeile").tag(SoftWrapIndentation.firstLine)
                        Text("Eine Stufe tiefer").tag(SoftWrapIndentation.reverse)
                    }.disabled(!workspace.softWrapEnabled)
                    Divider()
                    Toggle("Tabulator zum Einrücken", isOn: Binding(
                        get: { workspace.activeIndentationProfile.usesTabs },
                        set: { workspace.setIndentUsesTabs($0) }))
                    Stepper(L10n.format("Einrückungsbreite: %ld", workspace.activeIndentationProfile.indentWidth),
                            value: Binding(get: { workspace.activeIndentationProfile.indentWidth },
                                           set: { workspace.setIndentWidth($0) }),
                            in: SoftWrapProfileStore.validIndentRange)
                        .disabled(workspace.activeIndentationProfile.usesTabs)
                    Stepper(L10n.format("Tabbreite: %ld", workspace.activeIndentationProfile.tabWidth),
                            value: Binding(get: { workspace.activeIndentationProfile.tabWidth },
                                           set: { workspace.setEditorTabWidth($0) }),
                            in: SoftWrapProfileStore.validIndentRange)
                }.frame(width: 260)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Darstellung dieses Dokuments").fontWeight(.semibold)
                    Toggle("Zeilennummern und Rand anzeigen", isOn: displayBinding(\.showGutter))
                    Toggle("Unsichtbare Zeichen anzeigen", isOn: displayBinding(\.showInvisibles))
                        .accessibilityIdentifier("showInvisiblesToggle")
                        .background(SelfTestMarker(id: "showInvisiblesToggle"))
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Leerzeichen", isOn: displayBinding(\.showSpaces))
                        Toggle("Tabulatoren", isOn: displayBinding(\.showTabs))
                        Toggle("Zeilenenden", isOn: displayBinding(\.showLineEndings))
                    }
                    .padding(.leading, 18)
                    .disabled(!workspace.editorDisplayOptions.showInvisibles)
                    Divider()
                    Text("Darstellung in allen Fenstern").fontWeight(.semibold)
                    Toggle("Minimap anzeigen", isOn: $showMinimap)
                    Toggle("Seitenlinie anzeigen", isOn: Binding(
                        get: { workspace.showPageGuide }, set: { workspace.setShowPageGuide($0) }))
                    Stepper(L10n.format("Seitenlinie: Spalte %ld", workspace.pageGuideColumn),
                            value: Binding(get: { workspace.pageGuideColumn },
                                           set: { workspace.setPageGuideColumn($0) }),
                            in: SoftWrapProfileStore.validColumnRange)
                }.frame(width: 260)
            }
            .disabled(!workspace.canConfigureTextDisplay)
            if !workspace.canConfigureTextDisplay {
                Text("Diese Optionen gelten im Texteditor. Für Markdown zuerst zum Quelltext wechseln.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(20)
        .frame(width: 584)
        .background(SelfTestMarker(id: "editorOptionsPopover"))
    }
}
