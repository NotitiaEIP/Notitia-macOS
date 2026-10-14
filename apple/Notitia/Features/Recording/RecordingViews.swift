import NotitiaKit
import SwiftData
import SwiftUI

// MARK: - Démarrage (consentement RGPD)

extension Workspace {
    /// Point d'entrée « Enregistrer » : crée la note si besoin, puis demande le consentement.
    func beginRecording() {
        guard !services.recorder.isActive else { return }
        if editor == nil || editor?.isReadOnly == true {
            let title = "Réunion du " + Date.now.formatted(date: .abbreviated, time: .shortened)
            createNote(title: title)
        }
        let askConsent = UserDefaults.standard.object(forKey: Preferences.Keys.askConsentBeforeRecording) as? Bool ?? true
        if askConsent {
            pendingConsent = PendingRecording()
        } else {
            startRecording(consentConfirmedAt: .now)
        }
    }

    func startRecording(consentConfirmedAt: Date) {
        guard let editor else { return }
        Task {
            do {
                let recording = try await services.recorder.start(note: editor.note, context: context, consentConfirmedAt: consentConfirmedAt)
                editor.insertBlocks([Block(kind: .transcript, recordingID: recording.uid)], after: editor.blocks.last?.id)
                editor.flush()
            } catch {
                alert = AlertMessage(title: String(localized: "Impossible de démarrer l'enregistrement"), message: error.localizedDescription)
            }
        }
    }
}

struct ConsentSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Preferences.Keys.askConsentBeforeRecording) private var askConsent = true
    @AppStorage(Preferences.Keys.annotateSounds) private var annotateSounds = true
    @AppStorage(Preferences.Keys.analyzeTone) private var analyzeTone = false
    @State private var confirmed = false
    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Avant d'enregistrer").font(.title3.bold())
                    Text("Protection des données personnelles").foregroundStyle(.secondary)
                }
            }

            Text("La voix des participants est une donnée personnelle. Vous devez les informer que la conversation est enregistrée et transcrite, et obtenir leur accord.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.s) {
                Label("L'audio reste sur ce Mac et il est chiffré.", systemImage: "lock")
                Label("La transcription est faite sur l'appareil, sans Internet.", systemImage: "wifi.slash")
                if annotateSounds {
                    Label("Les rires, applaudissements, silences et passages au volume élevé sont signalés dans la transcription.", systemImage: "waveform.badge.magnifyingglass")
                }
                if analyzeTone {
                    Label("Le ton des passages est analysé à partir du texte, jamais de la voix, et sans qualifier les personnes.", systemImage: "text.bubble")
                }
                Label("Vous pouvez supprimer l'audio à tout moment en gardant le texte.", systemImage: "trash")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Toggle("J'ai informé les participants et ils acceptent l'enregistrement.", isOn: $confirmed)
                .toggleStyle(.checkbox)
            Toggle("Ne plus afficher ce rappel", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .disabled(!confirmed)

            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Démarrer l'enregistrement") {
                    if dontAskAgain { askConsent = false }
                    dismiss()
                    workspace.startRecording(consentConfirmedAt: .now)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!confirmed)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }
}

// MARK: - Barre d'enregistrement

struct RecordingBar: View {
    @Environment(RecordingController.self) private var recorder
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle()
                .fill(recorder.state == .paused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse && recorder.state == .recording ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 0) {
                Text(recorder.state == .paused ? "En pause" : recorder.state == .finishing ? "Finalisation…" : "Enregistrement")
                    .font(.callout.weight(.semibold))
                Text(recorder.engineName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(TranscriptSegment.formatTimestamp(recorder.elapsed))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .frame(minWidth: 64)

            LevelMeter(level: recorder.level)
                .frame(width: 70, height: 18)

            Button {
                recorder.togglePause()
            } label: {
                Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.glass)
            .help(recorder.state == .paused ? "Reprendre (⇧⌘P)" : "Pause (⇧⌘P)")
            .disabled(recorder.state == .finishing || recorder.state == .starting)

            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Arrêter", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .help("Arrêter et enregistrer (⇧⌘R)")
            .disabled(recorder.state == .finishing)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enregistrement en cours")
    }
}

struct LevelMeter: View {
    let level: Float
    private let bars = 12

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Float(index) / Float(bars)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? Color.primary.opacity(0.75) : Color.primary.opacity(0.12))
                    .frame(width: 3, height: 4 + CGFloat(index % 4) * 3)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - Bloc de transcription

struct TranscriptBlockView: View {
    let block: Block
    let model: NoteEditorModel
    @Environment(RecordingController.self) private var recorder
    @Environment(AudioPlaybackController.self) private var player
    @Environment(AppServices.self) private var services
    @Query private var recordings: [Recording]
    @State private var confirmDeleteAudio = false
    @State private var showHiddenAnnotations = false
    @State private var hoveredSegment: UUID?

    init(block: Block, model: NoteEditorModel) {
        self.block = block
        self.model = model
        let uid = block.recordingID ?? UUID()
        _recordings = Query(filter: #Predicate<Recording> { $0.uid == uid })
    }

    private var recording: Recording? { recordings.first }
    private var isLive: Bool { recorder.recordingID != nil && recorder.recordingID == block.recordingID }
    private var segments: [TranscriptSegment] { isLive ? recorder.segments : (recording?.segments ?? []) }
    private var annotations: [TranscriptAnnotation] { isLive ? recorder.annotations : (recording?.annotations ?? []) }
    private var hasAudio: Bool { recording?.hasAudio == true && !isLive }
    private var isAnalyzingTone: Bool { block.recordingID.map { recorder.toneAnalysisInProgress.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            if isLive, let error = recorder.transcriptionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let items = TranscriptTimeline.merge(segments: segments, annotations: annotations, includeHidden: showHiddenAnnotations)
            if items.isEmpty {
                Text(isLive ? "Parlez, la transcription s'affiche ici…" : "Aucune transcription.")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(items) { item in
                        switch item {
                        case .segment(let segment):
                            segmentRow(segment)
                        case .annotation(let annotation) where annotation.kind == .tone:
                            toneRow(annotation)
                        case .annotation(let annotation):
                            annotationRow(annotation)
                        }
                    }
                }
            }
            if isAnalyzingTone {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Analyse du ton des passages…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Spacing.l)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(.separator.opacity(0.6)))
        .confirmationDialog("Supprimer l'audio de cet enregistrement ?", isPresented: $confirmDeleteAudio) {
            Button("Supprimer l'audio", role: .destructive) {
                if let recording {
                    if player.recordingID == recording.uid { player.stop() }
                    services.store.deleteAudio(of: recording)
                    try? recording.modelContext?.save()
                }
            }
        } message: {
            Text("La transcription est conservée. Cette action est définitive.")
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: isLive ? "waveform.badge.mic" : "waveform")
                .foregroundStyle(isLive ? .red : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: isLive && recorder.state == .recording)
            VStack(alignment: .leading, spacing: 0) {
                Text("Transcription").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let recording, hasAudio {
                Button {
                    player.toggle(recording.uid)
                } label: {
                    Image(systemName: player.recordingID == recording.uid && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Écouter l'enregistrement")
            }
            if !isLive {
                Menu {
                    Button("Résumer") { model.run(.summary(focus: [])) }
                        .disabled(model.isGenerating)
                    Button("Carte mentale") { model.run(.mindMap(focus: [])) }
                        .disabled(model.isGenerating)
                    Button("Analyser le ton des passages") {
                        if let recording { recorder.analyzeTone(of: recording) }
                    }
                    .disabled(recording?.segments.isEmpty != false || isAnalyzingTone)
                    Button("Copier dans la note comme texte") {
                        if let id = block.recordingID { model.insertTranscriptAsText(recordingID: id, after: block.id) }
                    }
                    if annotations.contains(where: \.isHidden) {
                        Divider()
                        Toggle("Afficher les annotations masquées", isOn: $showHiddenAnnotations)
                    }
                    Divider()
                    Button("Supprimer l'audio…", role: .destructive) { confirmDeleteAudio = true }
                        .disabled(recording?.hasAudio != true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isReadOnly)
            }
        }
    }

    private var subtitle: String {
        if isLive { return String(localized: "En cours · \(TranscriptSegment.formatTimestamp(recorder.elapsed))") }
        guard let recording else { return String(localized: "Enregistrement introuvable") }
        var parts = [
            recording.createdAt.formatted(date: .abbreviated, time: .shortened),
            TranscriptSegment.formatTimestamp(recording.duration),
        ]
        if !recording.hasAudio {
            parts.append(recording.audioDeletedAt != nil ? String(localized: "audio supprimé") : String(localized: "sans audio"))
        }
        return parts.joined(separator: " · ")
    }

    /// Horodatage cliquable : lance la lecture à cet instant.
    private func timestamp(_ time: TimeInterval) -> some View {
        Button {
            if let id = block.recordingID, hasAudio { player.play(id, from: time) }
        } label: {
            Text(TranscriptSegment.formatTimestamp(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(hasAudio ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!hasAudio)
        .help("Écouter à partir d'ici")
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let isCurrent = player.recordingID == block.recordingID && player.isPlaying
            && player.currentTime >= segment.start && player.currentTime < segment.end + 0.5
        let isHighlighted = model.sourceHighlight.map { segment.text.contains($0) || $0.contains(segment.text) } ?? false
        let canQuote = !isLive && !model.isReadOnly && segment.isFinal
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            timestamp(segment.start)

            Text("\(Text(segment.speaker.map { "\($0)  " } ?? "").bold())\(segment.text)")
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .italic(!segment.isFinal)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                quote(segment)
            } label: {
                Image(systemName: "quote.bubble")
            }
            .buttonStyle(.borderless)
            .help("Citer avec le contexte : insère cette phrase, la précédente et la suivante dans la note")
            .opacity(canQuote && hoveredSegment == segment.id ? 1 : 0)
            .disabled(!canQuote)
            .accessibilityLabel("Citer avec le contexte")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, Spacing.xs)
        .background {
            if isCurrent || isHighlighted {
                RoundedRectangle(cornerRadius: Radius.s)
                    .fill(isHighlighted ? Color.yellow.opacity(0.25) : Color.accentColor.opacity(0.12))
            }
        }
        .onHover { inside in
            if inside { hoveredSegment = segment.id } else if hoveredSegment == segment.id { hoveredSegment = nil }
        }
        .contextMenu {
            Button("Citer avec le contexte") { quote(segment) }
                .disabled(!canQuote)
        }
    }

    private func quote(_ segment: TranscriptSegment) {
        guard let id = block.recordingID else { return }
        model.insertQuote(recordingID: id, segmentID: segment.id, after: block.id)
    }

    /// Son ou mesure du volume : puce discrète, toujours marquée « automatique ».
    private func annotationRow(_ annotation: TranscriptAnnotation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            timestamp(annotation.start)
            Label(annotation.text, systemImage: annotation.kind.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.8), in: Capsule())
            Text("automatique")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xs)
        .opacity(annotation.isHidden ? 0.45 : 1)
        .help(annotation.helpText)
        .contextMenu { hideButton(annotation) }
        .accessibilityElement(children: .combine)
    }

    /// Ton d'un passage (déduit du texte) : bandeau qui introduit le passage concerné.
    private func toneRow(_ annotation: TranscriptAnnotation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: annotation.kind.symbolName)
            Text("Ton du passage : \(Text(annotation.text).italic())")
            Text("\(TranscriptSegment.formatTimestamp(annotation.start))–\(TranscriptSegment.formatTimestamp(annotation.end)) · automatique")
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .padding(.leading, Spacing.s)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(annotation.toneColor)
                .frame(width: 2)
        }
        .padding(.leading, Spacing.xs)
        .opacity(annotation.isHidden ? 0.45 : 1)
        .help(annotation.helpText)
        .contextMenu { hideButton(annotation) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func hideButton(_ annotation: TranscriptAnnotation) -> some View {
        Button(annotation.isHidden ? "Afficher l'annotation" : "Masquer l'annotation") {
            if let id = block.recordingID { model.setAnnotation(annotation.id, hidden: !annotation.isHidden, in: id) }
        }
        .disabled(isLive || model.isReadOnly)
    }
}

extension TranscriptAnnotation.Kind {
    var symbolName: String {
        switch self {
        case .laughter: "face.smiling"
        case .applause: "hands.clap"
        case .raisedVoice: "speaker.wave.3"
        case .longSilence: "hourglass"
        case .tone: "text.bubble"
        case .unknown: "waveform"
        }
    }
}

extension TranscriptAnnotation {
    var helpText: String {
        let percent = Int((confidence * 100).rounded())
        return String(localized: "Détecté automatiquement (\(source.displayName)), confiance \(percent) %. Décrit le moment, jamais l'état d'une personne. Clic droit pour masquer.")
    }

    /// La couleur a un sens : orange pour un passage tendu ou négatif, vert pour un passage positif.
    var toneColor: Color {
        guard let polarity else { return .secondary }
        if polarity <= -0.5 { return .orange }
        if polarity >= 0.5 { return .green }
        return .secondary
    }
}
