// FourDMacroPreviewSheet.swift
//
// Diff-Vorschau eines 4D-Makrolaufs (Idee #28, 2026-08-19): Links der
// aktuelle Puffer, rechts das Makro-Ergebnis, gerendert über den gemeinsamen
// Datei-Vergleich (`FileDiffView`). „Anwenden" schreibt NIE direkt — es geht
// über `Workspace.applyFourDMacroPreview()`, das Tab und Inhaltsgeneration
// gegen den Stand der Vorschau prüft (Produktinvariante: Apply wirkt nur auf
// die sichtbare Trefferbasis).

import SwiftUI

struct FourDMacroPreviewSheet: View {
    @EnvironmentObject var workspace: Workspace
    let state: FourDMacroPreviewState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(Theme.accentReadable)
                Text(L10n.format("Makro „%@“ — Vorschau der Änderungen",
                                 state.macroName))
                    .fastraFont(.ui)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            FileDiffView(request: state.request, document: state.document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                Text("Angewendet wird als ein Undo-Schritt (⌘Z macht alles rückgängig).")
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button("Abbrechen") {
                    workspace.fourDMacroPreview = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Anwenden") {
                    workspace.applyFourDMacroPreview()
                }
                .keyboardShortcut(.defaultAction)
                .background {
                    SelfTestMarker(id: "fourDMacroPreviewApply")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 780, idealWidth: 940, minHeight: 460, idealHeight: 620)
        .background(Theme.surfaceRaised)
    }
}
