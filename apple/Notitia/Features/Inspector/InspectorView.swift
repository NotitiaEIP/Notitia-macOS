import NotitiaKit
import SwiftData
import SwiftUI

struct InspectorView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let editor = workspace.editor {
            NoteInspector(model: editor)
                .id(editor.note.uid)
        } else {
            ContentUnavailableView("Aucune note", systemImage: "sidebar.trailing", description: Text("Sélectionnez une note pour voir ses informations."))
        }
    }
}

private struct NoteInspector: View {
    @Bindable var model: NoteEditorModel
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(AudioPlaybackController.self) private var player
    @Query(sort: [SortDescriptor(\Folder.name)]) private var folders: [Folder]
    @Query(sort: \NotitiaKit.Tag.name) private var allTags: [NotitiaKit.Tag]
    @State private var newTag = ""
    @State private var focusKeywords = ""
    @AppStorage(Preferences.Keys.aiService) private var aiServiceID = EngineCatalog.defaultAIServiceID
    @State private var recordingToDelete: Recording?

    private var note: Note { model.note }

    var body: some View {
        Form {
            noteSection
            tagSection
            if !model.isReadOnly { intelligenceSection }
            if !note.recordings.isEmpty { recordingsSection }
        }
        .formStyle(.grouped)
        .confirmationDialog("Supprimer cet enregistrement ?", isPresented: Binding(get: { recordingToDelete != nil }, set: { if !$0 { recordingToDelete = nil } }), presenting: recordingToDelete) { recording in
            Button("Supprimer l'audio et la transcription", role: .destructive) { deleteRecording(recording) }
        } message: { _ in
            Text("L'audio chiffré et le texte transcrit seront supprimés définitivement.")
        }
    }

    // MARK: Note

    private var noteSection: some View {
        Section("Note") {
            Picker("Dossier", selection: Binding(
                get: { note.folder?.uid },
                set: { uid in workspace.move(note, to: folders.first { $0.uid == uid }) }
            )) {
                Text("Aucun").tag(UUID?.none)
                Divider()
                ForEach(folders.sorted { $0.pathDescription.localizedStandardCompare($1.pathDescription) == .orderedAscending }) { folder in
                    Text(folder.pathDescription).tag(Optional(folder.uid))
                }
            }
            .disabled(model.isReadOnly)
            Toggle("Épinglée", isOn: Binding(get: { note.isPinned }, set: { note.isPinned = $0 }))
                .disabled(model.isReadOnly)
            InfoRow(label: "Créée", value: note.createdAt.formatted(date: .abbreviated, time: .shortened))
            InfoRow(label: "Modifiée", value: note.updatedAt.formatted(date: .abbreviated, time: .shortened))
            InfoRow(label: "Mots", value: "\(wordCount)")
            InfoRow(label: "Blocs", value: "\(model.blocks.count)")
        }
    }

    private var wordCount: Int {
        NoteDocument(blocks: model.blocks).plainText.split { $0.isWhitespace || $0.isNewline }.count
    }

    // MARK: Tags

    private var tagSection: some View {
        Section("Tags") {
            if !note.tags.isEmpty {
                FlowLayout().callAsFunction {
                    ForEach(note.tags.sorted { $0.name < $1.name }) { tag in
                        TagChip(name: tag.name, color: tag.color, onRemove: model.isReadOnly ? nil : {
                            note.tags.removeAll { $0.uid == tag.uid }
                        })
                    }
                }
            }
            if !model.isReadOnly {
                HStack {
                    TextField("Ajouter un tag", text: $newTag)
                        .onSubmit(addTag)
                    let suggestions = allTags.filter { tag in !note.tags.contains { $0.uid == tag.uid } }
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions) { tag in
                                Button(tag.name) { note.tags.append(tag) }
                            }
                        } label: {
                            Image(systemName: "tag")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Tags existants")
                    }
                }
            }
        }
    }

    private func addTag() {
        let name = newTag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !name.isEmpty else { return }
        if let existing = allTags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if !note.tags.contains(where: { $0.uid == existing.uid }) { note.tags.append(existing) }
        } else {
            let palette: [NoteColor] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo]
            let tag = NotitiaKit.Tag(name: name, color: palette[allTags.count % palette.count])
            workspace.context.insert(tag)
            note.tags.append(tag)
        }
        newTag = ""
        try? workspace.context.save()
    }

    // MARK: Intelligence

    private var intelligenceSection: some View {
        Section {
            Group {
                Button {
                    model.run(.summary(focus: []))
                } label: {
                    Label("Résumer", systemImage: "text.badge.star")
                }
                Button {
                    model.run(.keywords)
                } label: {
                    Label("Extraire les mots-clés", systemImage: "key")
                }
                Button {
                    model.run(.mindMap(focus: []))
                } label: {
                    Label("Créer une carte mentale", systemImage: "point.3.connected.trianglepath.dotted")
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Réécrire avec mes mots-clés").font(.callout.weight(.medium))
                    TextField("ex. : planning, design, RGPD", text: $focusKeywords)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Synthèse") { model.run(.summary(focus: keywords)) }
                        Button("Carte mentale") { model.run(.mindMap(focus: keywords)) }
                    }
                    .disabled(keywords.isEmpty)
                }
                .padding(.vertical, Spacing.xs)
            }
            .disabled(model.isGenerating)

            if let generation = model.generation {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(generation.title).font(.callout.weight(.medium))
                        Spacer()
                        Button("Annuler") { model.cancelGeneration() }
                    }
                    if let progress = generation.progress, progress.total > 1 {
                        ProgressView(value: progress.fraction)
                    }
                    Text(generation.detail).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xs)
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Intelligence")
        } footer: {
            Label("\(EngineCatalog.effectiveAIServiceName(id: aiServiceID, locale: Locale(identifier: note.recordings.first?.localeIdentifier ?? "fr_FR"))) · rien ne quitte ce Mac", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    private var keywords: [String] {
        focusKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Enregistrements

    private var recordingsSection: some View {
        Section("Enregistrements") {
            ForEach(note.recordings.sorted { $0.createdAt < $1.createdAt }) { recording in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Image(systemName: "waveform")
                        Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(TranscriptSegment.formatTimestamp(recording.duration)).monospacedDigit()
                    }
                    .font(.callout)
                    Group {
                        Text("Moteur : \(recording.engineName) · \(Locale.current.localizedString(forIdentifier: recording.localeIdentifier) ?? recording.localeIdentifier)")
                        Text("Consentement confirmé le \(recording.consentConfirmedAt.formatted(date: .abbreviated, time: .shortened))")
                        integrityLabel(recording)
                        let annotationCount = recording.annotations.count
                        if annotationCount > 0 {
                            Label("\(annotationCount) annotation(s) automatique(s)", systemImage: "waveform.badge.magnifyingglass")
                        }
                        if recording.hasAudio {
                            Label("Audio chiffré (AES-256) sur ce Mac", systemImage: "lock.fill")
                        } else if let deleted = recording.audioDeletedAt {
                            Label("Audio supprimé le \(deleted.formatted(date: .abbreviated, time: .omitted))", systemImage: "speaker.slash")
                        } else {
                            Label("Pas d'audio", systemImage: "speaker.slash")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        if recording.hasAudio {
                            Button("Supprimer l'audio") {
                                if player.recordingID == recording.uid { player.stop() }
                                services.store.deleteAudio(of: recording)
                                try? workspace.context.save()
                            }
                        }
                        Button("Supprimer…", role: .destructive) { recordingToDelete = recording }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(model.isReadOnly)
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    /// État de l'empreinte de la transcription d'origine (voir `TranscriptIntegrity`).
    @ViewBuilder
    private func integrityLabel(_ recording: Recording) -> some View {
        switch recording.integrityStatus {
        case .intact:
            Label("Transcription d'origine, non modifiée", systemImage: "checkmark.seal")
                .help("L'empreinte calculée à la fin de l'enregistrement correspond toujours au texte et aux sons captés. Elle détecte une modification de la base sur ce Mac ; ce n'est pas une preuve opposable à un tiers.")
        case .modified:
            Label("Transcription modifiée depuis l'enregistrement", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("Le texte ou les sons captés ne correspondent plus à l'empreinte calculée à la fin de l'enregistrement.")
        case .notSealed:
            EmptyView()
        }
    }

    private func deleteRecording(_ recording: Recording) {
        if player.recordingID == recording.uid { player.stop() }
        let uid = recording.uid
        try? services.vault.delete(uid)
        for block in model.blocks where block.recordingID == uid {
            model.delete(block.id)
        }
        workspace.context.delete(recording)
        model.flush()
        try? workspace.context.save()
    }
}
