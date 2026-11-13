import SwiftUI

struct DocumentTransformationActivity: Identifiable {
    let id = UUID()
    let documentID: UUID
    let label: String
}

/// Kurze Vorgänge bleiben ruhig; längere Arbeit meldet sich im betroffenen Dokument.
struct DocumentTransformationIndicator: View {
    let activity: DocumentTransformationActivity
    @State private var visible = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: activity.label).fastraFont(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .background(SelfTestMarker(id: visible ? "documentTransformationVisible" : "documentTransformationPending")
            .frame(width: 0, height: 0))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!visible)
        .task(id: activity.id) {
            visible = false
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            visible = true
        }
    }
}
