import NotitiaKit
import SwiftUI

/// Barre flottante affichée pendant un résumé, une extraction de mots-clés ou une carte mentale :
/// une génération avec Apple Intelligence prend plusieurs secondes, il faut voir qu'elle avance.
struct GenerationBar: View {
    let model: NoteEditorModel
    let generation: NoteEditorModel.Generation

    var body: some View {
        HStack(spacing: Spacing.m) {
            Group {
                if let progress = generation.progress, progress.total > 1 {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.circular)
                        .animation(.smooth, value: progress.fraction)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 0) {
                Text(generation.title)
                    .font(.callout.weight(.semibold))
                Text(generation.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 180, alignment: .leading)

            Button("Annuler") { model.cancelGeneration() }
                .buttonStyle(.glass)
                .help("Arrêter : rien ne sera ajouté à la note")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(generation.title) \(generation.detail)"))
    }
}
