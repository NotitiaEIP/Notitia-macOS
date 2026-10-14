import Foundation
import NotitiaKit
import Observation
import SwiftData

/// Demande de focus sur un bloc (le jeton distingue deux demandes identiques successives).
struct FocusRequest: Equatable {
    var blockID: UUID
    /// Décalage UTF-16 du curseur ; `nil` = fin du texte.
    var offset: Int?
    var token = UUID()
}

/// Menu « / » : choix du type de bloc.
struct SlashMenuState: Equatable {
    var blockID: UUID
    var query: String
    var selectedIndex = 0

    var items: [BlockKind] {
        let q = NoteSearch.fold(query)
        guard !q.isEmpty else { return BlockKind.insertable }
        return BlockKind.insertable.filter { kind in
            NoteSearch.fold(kind.displayName).contains(q) || kind.searchTerms.contains { $0.hasPrefix(q) }
        }
    }
}

/// État de l'éditeur d'une note.
///
/// Les blocs sont gardés en mémoire et manipulés avec `BlockOperations` (fonctions pures,
/// testées dans NotitiaKit). La note SwiftData est mise à jour avec un léger délai.
@Observable
final class NoteEditorModel {
    let note: Note
    let isReadOnly: Bool
    private(set) var blocks: [Block]
    private(set) var listNumbers: [UUID: Int] = [:]

    var focusRequest: FocusRequest?
    var titleFocusToken: UUID?
    private(set) var activeBlockID: UUID?
    private(set) var activeSelection: Range<Int> = 0..<0
    var slashMenu: SlashMenuState?

    /// Passage source mis en évidence dans la transcription (clic sur un nœud de carte mentale).
    var sourceHighlight: String?
    /// Bloc vers lequel faire défiler l'éditeur.
    var scrollTarget: UUID?

    /// Action IA en cours, affichée par la barre de génération et l'inspecteur.
    private(set) var generation: Generation?
    var isGenerating: Bool { generation != nil }
    var lastError: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var hasPendingChanges = false

    init(note: Note, services: AppServices, isReadOnly: Bool = false) {
        self.note = note
        self.services = services
        self.isReadOnly = isReadOnly
        self.blocks = note.document.blocks
        self.listNumbers = BlockOperations.listNumbers(blocks)
    }

    var activeBlock: Block? { blocks.first { $0.id == activeBlockID } }

    // MARK: Sauvegarde

    private func commit(_ newBlocks: [Block], focus caret: Caret? = nil) {
        blocks = newBlocks
        listNumbers = BlockOperations.listNumbers(newBlocks)
        if let caret { focusRequest = FocusRequest(blockID: caret.blockID, offset: caret.offset) }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isReadOnly else { return }
        hasPendingChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Écrit immédiatement les blocs dans la note.
    func flush() {
        saveTask?.cancel()
        guard hasPendingChanges, note.modelContext != nil else { return }
        hasPendingChanges = false
        note.document = NoteDocument(blocks: blocks)
        note.updatedAt = .now
        try? note.modelContext?.save()
    }

    func titleChanged() {
        note.updatedAt = .now
        scheduleSave()
    }

    func requestTitleFocus() { titleFocusToken = UUID() }

    // MARK: Focus

    func didFocus(_ id: UUID) {
        activeBlockID = id
        if slashMenu?.blockID != id { slashMenu = nil }
    }

    func selectionChanged(_ id: UUID, range: Range<Int>) {
        activeBlockID = id
        activeSelection = range
    }

    func focus(_ id: UUID, offset: Int? = nil) {
        focusRequest = FocusRequest(blockID: id, offset: offset)
    }

    func focusFirstBlock() {
        if let first = blocks.first(where: \.kind.hasText) {
            focus(first.id, offset: 0)
        } else {
            appendParagraph()
        }
    }

    @discardableResult
    func focusPrevious(from id: UUID) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        guard let previous = blocks[..<index].last(where: \.kind.hasText) else {
            requestTitleFocus()
            return true
        }
        focus(previous.id)
        return true
    }

    @discardableResult
    func focusNext(from id: UUID, atStart: Bool = false, createIfNeeded: Bool = false) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        if let next = blocks[(index + 1)...].first(where: \.kind.hasText) {
            focus(next.id, offset: atStart ? 0 : nil)
            return true
        }
        if createIfNeeded {
            appendParagraph()
            return true
        }
        return false
    }

    func appendParagraph() {
        let block = Block()
        commit(blocks + [block], focus: Caret(blockID: block.id, offset: 0))
    }

    /// Clic dans la zone vide sous le dernier bloc.
    func focusEnd() {
        if let last = blocks.last, last.kind.hasText, last.text.isEmpty, last.kind == .paragraph {
            focus(last.id)
        } else {
            appendParagraph()
        }
    }

    // MARK: Saisie

    func updateText(_ id: UUID, text: RichText, caret: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = blocks[index]
        block.text = text

        // Raccourcis Markdown (« # », « - », « [] »…).
        if let converted = MarkdownShortcut.apply(to: block) {
            var newBlocks = blocks
            newBlocks[index] = converted
            if !converted.kind.hasText {
                let next = Block()
                newBlocks.insert(next, at: index + 1)
                commit(newBlocks, focus: Caret(blockID: next.id, offset: 0))
            } else {
                let removed = text.length - converted.text.length
                commit(newBlocks, focus: Caret(blockID: id, offset: max(0, caret - removed)))
            }
            slashMenu = nil
            return
        }

        blocks[index] = block
        updateSlashMenu(for: block)
        scheduleSave()
    }

    private func updateSlashMenu(for block: Block) {
        let plain = block.text.plainText
        if block.kind.hasText, block.kind != .code, plain.hasPrefix("/"), plain.count <= 24,
           !plain.contains(where: { $0.isWhitespace }) {
            let query = String(plain.dropFirst())
            var menu = slashMenu?.blockID == block.id ? slashMenu! : SlashMenuState(blockID: block.id, query: query)
            menu.query = query
            menu.selectedIndex = min(menu.selectedIndex, max(0, menu.items.count - 1))
            slashMenu = menu
        } else if slashMenu?.blockID == block.id {
            slashMenu = nil
        }
    }

    // MARK: Menu « / »

    func moveSlashSelection(by delta: Int) {
        guard var menu = slashMenu, !menu.items.isEmpty else { return }
        menu.selectedIndex = (menu.selectedIndex + delta + menu.items.count) % menu.items.count
        slashMenu = menu
    }

    func commitSlashMenu() {
        guard let menu = slashMenu else { return }
        let items = menu.items
        slashMenu = nil
        guard items.indices.contains(menu.selectedIndex) else { return }
        choose(items[menu.selectedIndex], for: menu.blockID)
    }

    func closeSlashMenu() { slashMenu = nil }

    /// Applique un type choisi dans le menu « / » ou le bouton « + ».
    func choose(_ kind: BlockKind, for id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var newBlocks = blocks
        // Le texte « /requête » est retiré.
        if newBlocks[index].text.plainText.hasPrefix("/") { newBlocks[index].text = RichText() }
        newBlocks = BlockOperations.convert(newBlocks, blockID: id, to: kind)
        if kind.hasText {
            commit(newBlocks, focus: Caret(blockID: id, offset: newBlocks[index].text.length))
        } else {
            let next = Block()
            newBlocks.insert(next, at: index + 1)
            commit(newBlocks, focus: kind == .image ? nil : Caret(blockID: next.id, offset: 0))
        }
    }

    // MARK: Opérations structurelles

    func split(_ id: UUID, at offset: Int) {
        apply(BlockOperations.split(blocks, blockID: id, at: offset))
    }

    func backspaceAtStart(_ id: UUID) {
        apply(BlockOperations.backspaceAtStart(blocks, blockID: id))
    }

    func deleteForwardAtEnd(_ id: UUID) {
        apply(BlockOperations.deleteForwardAtEnd(blocks, blockID: id))
    }

    func indent(_ id: UUID) { commit(BlockOperations.indent(blocks, blockID: id)) }
    func outdent(_ id: UUID) { commit(BlockOperations.outdent(blocks, blockID: id)) }

    func convert(_ id: UUID, to kind: BlockKind) {
        commit(BlockOperations.convert(blocks, blockID: id, to: kind), focus: kind.hasText ? Caret(blockID: id, offset: activeSelection.upperBound) : nil)
    }

    func convertActiveBlock(to kind: BlockKind) {
        guard let id = activeBlockID else { return }
        convert(id, to: kind)
    }

    func toggleChecked(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var newBlocks = blocks
        newBlocks[index].isChecked.toggle()
        commit(newBlocks)
    }

    func toggleActiveTodo() {
        guard let block = activeBlock, block.kind == .todo else { return }
        toggleChecked(block.id)
    }

    func delete(_ id: UUID) {
        apply(BlockOperations.delete(blocks, blockID: id))
    }

    func duplicate(_ id: UUID) { commit(BlockOperations.duplicate(blocks, blockID: id)) }

    func move(_ id: UUID, before target: UUID?) {
        commit(BlockOperations.move(blocks, blockID: id, before: target))
    }

    func shift(_ id: UUID, by delta: Int) {
        commit(BlockOperations.shift(blocks, blockID: id, by: delta), focus: Caret(blockID: id, offset: activeSelection.lowerBound))
    }

    func shiftActiveBlock(by delta: Int) {
        guard let id = activeBlockID else { return }
        shift(id, by: delta)
    }

    func insertBlock(_ kind: BlockKind, after id: UUID) {
        let block = Block(kind: kind)
        commit(BlockOperations.insert(block, after: id, in: blocks), focus: kind.hasText ? Caret(blockID: block.id, offset: 0) : nil)
    }

    /// Insère des blocs générés (IA, transcription) après le bloc actif ou à la fin.
    func insertBlocks(_ newBlocks: [Block], after id: UUID? = nil) {
        commit(BlockOperations.insert(newBlocks, after: id ?? activeBlockID ?? blocks.last?.id, in: blocks))
        scrollTarget = newBlocks.first?.id
    }

    func updateBlock(_ id: UUID, _ transform: (inout Block) -> Void) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var newBlocks = blocks
        transform(&newBlocks[index])
        commit(newBlocks)
    }

    private func apply(_ result: EditResult) {
        commit(result.blocks, focus: result.caret)
    }

    // MARK: Images

    func setImage(_ url: URL, for id: UUID) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let name = try services.paths.importAttachment(from: url)
            updateBlock(id) { $0.attachment = name }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func attachmentURL(_ name: String) -> URL {
        services.paths.attachmentURL(name)
    }

    // MARK: Transcriptions

    /// Texte source des actions IA : les transcriptions si la note en a, sinon son contenu.
    /// Avec une transcription, la source porte aussi ses segments : chaque point d'un résumé reformulé
    /// reçoit l'horodatage de la phrase dont il vient.
    var aiSource: AISource {
        let recordings = note.recordings
            .sorted { $0.createdAt < $1.createdAt }
            .map { AISource.Recording(id: $0.uid, segments: $0.segments) }
            .filter { !$0.segments.fullText.isEmpty }
        let ownText = NoteDocument(blocks: blocks.filter { $0.kind != .mindMap }).plainText
        let text = recordings.isEmpty ? ownText : recordings.map(\.segments.fullText).joined(separator: "\n\n")
        return AISource(title: note.title, text: text, localeIdentifier: note.recordings.first?.localeIdentifier ?? "fr_FR",
                        recordings: recordings)
    }

    var transcriptBlockID: UUID? {
        blocks.last { $0.kind == .transcript }?.id
    }

    /// Copie la transcription dans la note sous forme de paragraphes éditables.
    func insertTranscriptAsText(recordingID: UUID, after id: UUID) {
        guard let recording = note.recordings.first(where: { $0.uid == recordingID }) else { return }
        let paragraphs = recording.segments.filter(\.isFinal).map { segment in
            var runs: [TextRun] = []
            if let speaker = segment.speaker { runs.append(TextRun(speaker + " : ", style: TextStyle(bold: true))) }
            runs.append(TextRun(segment.text))
            return Block(kind: .paragraph, text: RichText(runs: runs))
        }
        insertBlocks(paragraphs, after: id)
    }

    /// « Citer avec le contexte » : la phrase, celle d'avant et celle d'après, les annotations du moment,
    /// et des horodatages cliquables. Contre les citations sorties de leur contexte.
    func insertQuote(recordingID: UUID, segmentID: UUID, after id: UUID) {
        guard let recording = note.recordings.first(where: { $0.uid == recordingID }),
              let context = TranscriptTimeline.context(of: segmentID, segments: recording.segments, annotations: recording.annotations)
        else { return }
        insertBlocks(TranscriptTimeline.quoteBlocks(context, recordingID: recordingID, recordedAt: recording.createdAt), after: id)
    }

    /// Masque ou réaffiche une annotation. L'original est conservé (l'empreinte ne change pas).
    func setAnnotation(_ annotationID: UUID, hidden: Bool, in recordingID: UUID) {
        guard !isReadOnly, let recording = note.recordings.first(where: { $0.uid == recordingID }) else { return }
        var annotations = recording.annotations
        guard let index = annotations.firstIndex(where: { $0.id == annotationID }) else { return }
        annotations[index].isHidden = hidden
        recording.annotations = annotations
        try? recording.modelContext?.save()
    }

    /// Lien `notitia://recording/…` (horodatage d'une citation) : rejoue l'audio à cet instant.
    func open(_ link: TranscriptLink) {
        guard let recording = note.recordings.first(where: { $0.uid == link.recordingID }) else { return }
        scrollTarget = blocks.first { $0.recordingID == link.recordingID }?.id
        if recording.hasAudio { services.player.play(link.recordingID, from: link.time) }
    }

    /// Met en évidence la phrase source dans la transcription et y fait défiler l'éditeur.
    func revealSource(_ text: String?) {
        sourceHighlight = text
        if text != nil { scrollTarget = transcriptBlockID }
    }

    // MARK: Actions IA

    enum AIAction {
        case summary(focus: [String])
        case keywords
        case mindMap(focus: [String])

        /// Libellé affiché pendant la génération.
        var progressTitle: String {
            switch self {
            case .summary(let focus): focus.isEmpty ? String(localized: "Résumé en cours…") : String(localized: "Synthèse en cours…")
            case .keywords: String(localized: "Extraction des mots-clés…")
            case .mindMap: String(localized: "Carte mentale en cours…")
            }
        }
    }

    struct Generation: Equatable {
        /// Distingue une génération annulée d'une génération relancée juste après.
        var id = UUID()
        var title: String
        /// « Apple Intelligence » ou « Moteur local ».
        var engineName: String
        /// `nil` tant que le moteur n'a pas annoncé le nombre d'étapes (ou s'il n'en a qu'une).
        var progress: AIProgress?

        var detail: String {
            guard let progress, progress.total > 1 else { return engineName }
            return String(localized: "\(engineName) · étape \(min(progress.completed + 1, progress.total)) sur \(progress.total)")
        }
    }

    func run(_ action: AIAction) {
        guard !isGenerating else { return }
        let source = aiSource
        let serviceID = UserDefaults.standard.string(forKey: Preferences.Keys.aiService) ?? EngineCatalog.defaultAIServiceID
        let current = Generation(
            title: action.progressTitle,
            engineName: EngineCatalog.effectiveAIServiceName(id: serviceID, locale: Locale(identifier: source.localeIdentifier))
        )
        let id = current.id
        let service = EngineCatalog.aiService(id: serviceID) { [weak self] progress in
            Task { @MainActor in
                if self?.generation?.id == id { self?.generation?.progress = progress }
            }
        }
        // Les résultats s'ajoutent en fin de note, dans l'ordre où on les demande.
        let anchor = blocks.last?.id
        generation = current
        lastError = nil
        generationTask = Task {
            defer {
                if generation?.id == id {
                    generation = nil
                    generationTask = nil
                }
            }
            do {
                switch action {
                case .summary(let focus):
                    let blocks = try await service.summarize(source, focus: focus)
                    guard !Task.isCancelled else { return }
                    insertBlocks(blocks, after: anchor)
                case .keywords:
                    let keywords = try await service.keywords(source, limit: 10)
                    guard !Task.isCancelled else { return }
                    insertBlocks([Block(kind: .callout, text: RichText(runs: [
                        TextRun("Mots-clés : ", style: TextStyle(bold: true)),
                        TextRun(keywords.joined(separator: " · ")),
                    ]))], after: anchor)
                case .mindMap(let focus):
                    let map = try await service.mindMap(source, focus: focus)
                    guard !Task.isCancelled else { return }
                    insertBlocks([Block(kind: .mindMap, mindMap: map)], after: anchor)
                }
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription }
            }
        }
    }

    /// Annule la génération en cours : rien n'est ajouté à la note.
    func cancelGeneration() {
        generationTask?.cancel()
        generation = nil
    }
}
