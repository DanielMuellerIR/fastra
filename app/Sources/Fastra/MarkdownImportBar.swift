// MarkdownImportBar.swift
//
// Dezente, NICHT-modale Leiste über dem Editor: bietet für ein erkanntes
// Fremdformat die Umwandlung nach Markdown an und zeigt danach Warnungen oder
// den echten Fehler.
//
// Bewusst kein Dialog beim Öffnen: Wer mehrere Dokumente hintereinander öffnet,
// soll nicht jedes Mal wegklicken müssen. Der Klick auf „Umwandeln" IST die
// verlangte sichtbare Zustimmung — vorher schreibt Fastra nichts.

import SwiftUI

struct MarkdownImportBar: View {
    /// Quelle, für die das Angebot gilt (nur im Angebots-Zustand gesetzt).
    let offer: MarkdownImportOffer?
    /// Zustand, den DIESES Fenster zeichnen darf. Der Dienst ist ein
    /// Singleton; läuft dort die Umwandlung eines ANDEREN Fensters, übergibt
    /// `EditorView` hier `.idle`, damit die Leiste nur das eigene Angebot
    /// zeigt statt fremdem Fortschritt, Erfolg oder Fehler
    /// (Code-Review 2026-08-10).
    let effectiveState: MarkdownImportState
    /// Blendet das Angebot für diesen Tab aus, ohne etwas umzuwandeln.
    let onDismissOffer: () -> Void

    @ObservedObject private var service = MarkdownImportService.shared
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .background(SelfTestMarker(id: "markdownImportBar").frame(width: 0, height: 0))
    }

    private var background: some View {
        Group {
            if case .failed = effectiveState {
                Theme.surfaceSand.opacity(0.9)
            } else {
                Theme.surfaceSand.opacity(0.6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveState {
        case .running(let url):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: L10n.format("„%@“ wird umgewandelt …", url.lastPathComponent))
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                Spacer(minLength: 0)
            }
        case .finished(let markdownFile, let warnings):
            finishedBar(markdownFile: markdownFile, warnings: warnings)
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .fastraFont(size: 11)
                    .foregroundColor(Theme.gitModified)
                Text(verbatim: message)
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                closeButton { service.clearState() }
            }
        case .idle:
            if let offer { offerBar(offer) }
        }
    }

    @ViewBuilder
    private func offerBar(_ offer: MarkdownImportOffer) -> some View {
        if offer.format.isAvailable {
            availableOfferBar(offer)
        } else {
            unavailableOfferBar(offer)
        }
    }

    private func availableOfferBar(_ offer: MarkdownImportOffer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.doc.on.clipboard")
                .fastraFont(size: 11)
                .foregroundColor(Theme.accentReadable)
            Text(verbatim: L10n.format(
                "%@ erkannt — Fastra kann das Dokument in Markdown umwandeln.",
                offer.format.identifier.uppercased()
            ))
            .fastraFont(.small)
            .foregroundColor(Theme.textSecondary)
            .lineLimit(2)
            Spacer(minLength: 0)
            Button("In Markdown umwandeln") {
                workspace.convertToMarkdown(offer.sourceURL)
            }
            .buttonStyle(.plain)
            .fastraFont(size: 11, weight: .semibold)
            .foregroundColor(Theme.accentReadable)
            // Klick-Anker für den Fenster-Selbsttest `markdownimport`.
            .background(SelfTestMarker(id: "markdownImportConvertButton")
                .frame(width: 0, height: 0))
            closeButton(onDismissOffer)
        }
    }

    /// Format erkannt, aber die Umwandlung würde scheitern, weil ein
    /// Zusatzprogramm (meist pandoc) fehlt. Statt die Leiste ganz zu
    /// verstecken, steht hier, was fehlt und wie man es installiert
    /// (Daniel-Befund 2026-07-29).
    private func unavailableOfferBar(_ offer: MarkdownImportOffer) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .fastraFont(size: 11)
                .foregroundColor(Theme.gitModified)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.format(
                    "%@ erkannt — die Umwandlung in Markdown ist zurzeit nicht möglich.",
                    offer.format.identifier.uppercased()
                ))
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
                if let explanation =
                    Workspace.markdownImportUnavailableExplanation(for: offer.format) {
                    Text(verbatim: explanation)
                        .fastraFont(size: 10)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            closeButton(onDismissOffer)
        }
    }

    private func finishedBar(markdownFile: URL, warnings: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warnings.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .fastraFont(size: 11)
                .foregroundColor(warnings.isEmpty ? Theme.accentReadable : Theme.gitModified)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.format("„%@“ angelegt.", markdownFile.lastPathComponent))
                    .fastraFont(.small)
                    .foregroundColor(Theme.textSecondary)
                // Formatverluste stehen sichtbar hier, nicht in einem Dialog,
                // den man wegklickt, ohne ihn zu lesen.
                ForEach(warnings, id: \.self) { warning in
                    Text(verbatim: warning)
                        .fastraFont(size: 10)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button("Im Finder zeigen…") {
                NSWorkspace.shared.activateFileViewerSelecting([markdownFile])
            }
            .buttonStyle(.plain)
            .fastraFont(size: 11, weight: .semibold)
            .foregroundColor(Theme.accentReadable)
            closeButton { service.clearState() }
        }
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .fastraFont(size: 9, weight: .semibold)
                .foregroundColor(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Ausblenden")
        .accessibilityLabel("Ausblenden")
    }
}

/// Ein konkretes Umwandlungsangebot für genau eine Quelle.
struct MarkdownImportOffer: Equatable {
    let sourceURL: URL
    let format: MarkdownImportFormat
}
