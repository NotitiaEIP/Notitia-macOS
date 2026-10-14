import NotitiaKit
import SwiftUI

struct NoteEditorView: View {
    @Bindable var model: NoteEditorModel
    @Environment(Workspace.self) private var workspace
    @Environment(RecordingController.self) private var recorder
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    blockList
                    // Zone cliquable sous le dernier bloc.
                    Color.clear
                        .frame(height: 220)
                        .contentShape(Rectangle())
                        .onTapGesture { if !model.isReadOnly { model.focusEnd() } }
                }
                .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xl)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.scrollTarget) {
                guard let target = model.scrollTarget else { return }
                withAnimation(.smooth) { proxy.scrollTo(target, anchor: .top) }
                model.scrollTarget = nil
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.s) {
                if let generation = model.generation {
                    GenerationBar(model: model, generation: generation)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if recorder.isActive, recorder.noteID == model.note.uid {
                    RecordingBar()
                }
            }
            .padding(.bottom, model.generation != nil || recorder.isActive ? Spacing.l : 0)
            .animation(.smooth, value: model.generation?.id)
        }
        .toolbar { EditorToolbar(model: model) }
        .onChange(of: model.titleFocusToken) { isTitleFocused = true }
        .onAppear {
            if model.note.title.isEmpty, model.blocks.count == 1, model.blocks[0].text.isEmpty {
                isTitleFocused = true
            }
        }
        .onDisappear { model.flush() }
        .navigationTitle(model.note.displayTitle)
        .navigationSubtitle(model.note.folder?.pathDescription ?? "")
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if model.isReadOnly {
                Label("Cette note est dans la corbeille. Restaurez-la pour la modifier.", systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Spacing.s)
            }
            TextField("Sans titre", text: Binding(
                get: { model.note.title },
                set: { model.note.title = $0; model.titleChanged() }
            ), axis: .vertical)
            .font(.system(size: 34, weight: .bold))
            .textFieldStyle(.plain)
            .focused($isTitleFocused)
            .disabled(model.isReadOnly)
            .onSubmit { model.focusFirstBlock() }

            HStack(spacing: Spacing.m) {
                Text("Modifiée \(model.note.updatedAt.formatted(.relative(presentation: .named)))")
                if !model.note.tags.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        ForEach(model.note.tags.sorted { $0.name < $1.name }) { tag in
                            TagChip(name: tag.name, color: tag.color)
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, Metrics.gutterWidth)
        .padding(.bottom, Spacing.l)
    }

    // MARK: Blocs

    private var blockList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.blocks) { block in
                BlockRowView(block: block, model: model, number: model.listNumbers[block.id])
                    .id(block.id)
                    .zIndex(model.slashMenu?.blockID == block.id ? 1 : 0)
            }
        }
    }
}

// MARK: - Barre d'outils

struct EditorToolbar: ToolbarContent {
    let model: NoteEditorModel
    @Environment(Workspace.self) private var workspace
    @Environment(RecordingController.self) private var recorder

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.isReadOnly {
                Menu {
                    ForEach(BlockKind.insertable.filter(\.hasText)) { kind in
                        Button {
                            model.convertActiveBlock(to: kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label("Type de bloc", systemImage: model.activeBlock?.kind.symbolName ?? "textformat")
                }
                .help("Type du bloc")
                .disabled(model.activeBlock == nil)

                ControlGroup {
                    Button { TextCommand.send(.bold) } label: { Label("Gras", systemImage: "bold") }.help("Gras (⌘B)")
                    Button { TextCommand.send(.italic) } label: { Label("Italique", systemImage: "italic") }.help("Italique (⌘I)")
                    Button { TextCommand.send(.underline) } label: { Label("Souligné", systemImage: "underline") }.help("Souligné (⌘U)")
                    Button { TextCommand.send(.strikethrough) } label: { Label("Barré", systemImage: "strikethrough") }.help("Barré (⇧⌘X)")
                }

                Menu {
                    Section("Couleur du texte") {
                        Button("Par défaut") { TextCommand.sendColor(nil) }
                        ForEach(NoteColor.allCases) { color in
                            Button { TextCommand.sendColor(color) } label: {
                                Label { Text(color.displayName) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                            }
                        }
                    }
                    Section("Surlignage") {
                        Button("Aucun") { TextCommand.sendHighlight(nil) }
                        ForEach([NoteColor.yellow, .green, .blue, .pink, .purple, .orange]) { color in
                            Button { TextCommand.sendHighlight(color) } label: {
                                Label { Text(color.displayName) } icon: { Image(systemName: "highlighter").foregroundStyle(color.color) }
                            }
                        }
                    }
                    Divider()
                    Button("Code") { TextCommand.send(.code) }
                    Button("Lien…") { TextCommand.sendLink() }
                } label: {
                    Label("Couleur et style", systemImage: "paintpalette")
                }
                .help("Couleur, surlignage, code et lien")
            }

            RecordButton()

            Button {
                workspace.isInspectorPresented.toggle()
            } label: {
                Label("Inspecteur", systemImage: "sidebar.trailing")
            }
            .help("Afficher l'inspecteur (⌥⌘I)")
        }
    }
}

struct RecordButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(RecordingController.self) private var recorder

    var body: some View {
        if recorder.isActive {
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Arrêter", systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .help("Arrêter l'enregistrement (⇧⌘R)")
        } else {
            Button {
                workspace.beginRecording()
            } label: {
                Label("Enregistrer", systemImage: "mic")
            }
            .help("Enregistrer et transcrire (⇧⌘R)")
            .disabled(recorder.state == .finishing)
        }
    }
}
