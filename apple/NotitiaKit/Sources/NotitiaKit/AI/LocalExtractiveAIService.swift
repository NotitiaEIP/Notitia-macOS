import Foundation

/// Service IA local et déterministe : résumé **extractif** (sélection des phrases
/// les plus représentatives), mots-clés par fréquence, carte mentale par regroupement
/// thématique. Tout s'exécute sur l'appareil, sans réseau.
///
/// Il sert de repli quand Apple Intelligence n'est pas disponible (`FoundationModelsAIService`),
/// et reste sélectionnable dans les réglages.
public struct LocalExtractiveAIService: NoteAIService {
    public static let descriptorValue = EngineDescriptor(
        id: "local.extractive",
        displayName: "Local — extractif",
        detail: "Sélectionne et organise les phrases de vos notes. Hors ligne, déterministe.",
        requiresNetwork: false,
        isAvailable: true
    )

    public var descriptor: EngineDescriptor { Self.descriptorValue }

    public init() {}

    // MARK: Mots-clés

    public func keywords(_ source: AISource, limit: Int = 8) async throws -> [String] {
        let analysis = try analyze(source)
        return analysis.keywords(limit: limit)
    }

    // MARK: Résumé

    public func summarize(_ source: AISource, focus: [String]) async throws -> [Block] {
        let analysis = try analyze(source)
        let focus = focus.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return focus.isEmpty ? generalSummary(analysis) : focusedSummary(analysis, focus: focus)
    }

    private func generalSummary(_ analysis: TextAnalysis) -> [Block] {
        var blocks: [Block] = [Block(kind: .heading2, text: "Résumé")]
        let ranked = analysis.ranked()
        var used = Set<Int>()

        // Vue d'ensemble : les deux phrases les plus représentatives, dans l'ordre du texte.
        let overview = ranked.prefix(2).sorted { $0.index < $1.index }
        overview.forEach { used.insert($0.index) }
        blocks.append(Block(kind: .paragraph, text: RichText(overview.map(\.text).joined(separator: " "))))

        let decisions = analysis.sentences.filter { analysis.isDecision($0) && !used.contains($0.index) }
        decisions.forEach { used.insert($0.index) }
        let actions = analysis.sentences.filter { analysis.isAction($0) && !used.contains($0.index) }
        actions.forEach { used.insert($0.index) }
        let questions = analysis.sentences.filter { analysis.isQuestion($0) && !used.contains($0.index) }
        questions.forEach { used.insert($0.index) }

        let keyPoints = ranked.filter { !used.contains($0.index) }.prefix(5).sorted { $0.index < $1.index }
        if !keyPoints.isEmpty {
            blocks.append(Block(kind: .heading3, text: "Points clés"))
            blocks += keyPoints.map { Block(kind: .bulleted, text: RichText($0.text)) }
        }
        if !decisions.isEmpty {
            blocks.append(Block(kind: .heading3, text: "Décisions"))
            blocks += decisions.map { Block(kind: .bulleted, text: RichText($0.text)) }
        }
        if !actions.isEmpty {
            blocks.append(Block(kind: .heading3, text: "Actions"))
            blocks += actions.map { Block(kind: .todo, text: RichText($0.text)) }
        }
        if !questions.isEmpty {
            blocks.append(Block(kind: .heading3, text: "Questions ouvertes"))
            blocks += questions.map { Block(kind: .bulleted, text: RichText($0.text)) }
        }

        let keywords = analysis.keywords(limit: 6)
        if !keywords.isEmpty {
            blocks.append(Block(kind: .callout, text: RichText(runs: [
                TextRun("Mots-clés : ", style: TextStyle(bold: true)),
                TextRun(keywords.joined(separator: " · ")),
            ])))
        }
        return blocks
    }

    /// « Réécrire avec mes mots-clés » : une section par mot-clé de l'utilisateur.
    private func focusedSummary(_ analysis: TextAnalysis, focus: [String]) -> [Block] {
        var blocks: [Block] = [Block(kind: .heading2, text: RichText("Synthèse — " + focus.joined(separator: ", ")))]
        for keyword in focus {
            blocks.append(Block(kind: .heading3, text: RichText(TextAnalysis.capitalizedFirst(keyword))))
            let mentions = analysis.sentences(mentioning: keyword)
                .sorted { analysis.score($0) > analysis.score($1) }
                .prefix(4)
                .sorted { $0.index < $1.index }
            if mentions.isEmpty {
                blocks.append(Block(kind: .paragraph, text: RichText("Aucune mention dans la source.", style: TextStyle(italic: true, color: .gray))))
            } else {
                blocks += mentions.map { sentence in
                    Block(kind: analysis.isAction(sentence) ? .todo : .bulleted, text: RichText(sentence.text))
                }
            }
        }
        return blocks
    }

    // MARK: Carte mentale

    public func mindMap(_ source: AISource, focus: [String]) async throws -> MindMapDocument {
        let analysis = try analyze(source)
        let focus = focus.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let topics = focus.isEmpty ? analysis.keywords(limit: 5) : focus

        let rootLabel = source.title.trimmingCharacters(in: .whitespaces).isEmpty
            ? (topics.first ?? "Sujet")
            : source.title
        var root = MindMapNode(
            label: rootLabel,
            detail: analysis.ranked().first?.text,
            kind: .root
        )

        var used = Set<Int>()
        for topic in topics {
            var topicNode = MindMapNode(label: TextAnalysis.capitalizedFirst(topic), kind: .topic)
            let mentions = analysis.sentences(mentioning: topic)
                .filter { !used.contains($0.index) }
                .sorted { analysis.score($0) > analysis.score($1) }
                .prefix(4)
                .sorted { $0.index < $1.index }
            for sentence in mentions {
                used.insert(sentence.index)
                topicNode.children.append(MindMapNode(
                    label: TextAnalysis.condensed(sentence.text),
                    detail: sentence.text,
                    kind: kind(of: sentence, in: analysis),
                    sourceText: sentence.text
                ))
            }
            if topicNode.sourceText == nil { topicNode.sourceText = mentions.first?.text }
            root.children.append(topicNode)
        }

        root.children += Self.entityBranches(source.text, analysis: analysis)

        return MindMapDocument(title: rootLabel, root: root)
    }

    /// Branches transverses : personnes et dates citées (NaturalLanguage, NSDataDetector).
    /// Partagées avec `FoundationModelsAIService`.
    static func entityBranches(_ text: String, analysis: TextAnalysis) -> [MindMapNode] {
        var branches: [MindMapNode] = []
        let entities = analysis.namedEntities(in: text)
        if !entities.people.isEmpty {
            branches.append(MindMapNode(
                label: "Personnes",
                kind: .topic,
                children: entities.people.prefix(6).map { name in
                    MindMapNode(label: name, kind: .person, sourceText: analysis.sentences(mentioning: name).first?.text)
                }
            ))
        }
        let dates = analysis.dateMentions(in: text)
        if !dates.isEmpty {
            branches.append(MindMapNode(
                label: "Échéances",
                kind: .topic,
                children: dates.prefix(5).map { mention in
                    MindMapNode(label: TextAnalysis.capitalizedFirst(mention), kind: .date, sourceText: analysis.sentences(mentioning: mention).first?.text)
                }
            ))
        }
        return branches
    }

    private func kind(of sentence: TextAnalysis.Sentence, in analysis: TextAnalysis) -> MindMapNodeKind {
        if analysis.isQuestion(sentence) { return .question }
        if analysis.isDecision(sentence) { return .decision }
        if analysis.isAction(sentence) { return .action }
        return .idea
    }

    // MARK: Interne

    private func analyze(_ source: AISource) throws -> TextAnalysis {
        let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { throw AIError.emptySource }
        let analysis = TextAnalysis(text: text, title: source.title)
        guard !analysis.sentences.isEmpty else { throw AIError.emptySource }
        return analysis
    }
}
