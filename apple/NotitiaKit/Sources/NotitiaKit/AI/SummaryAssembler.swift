import Foundation

/// Point d'un résumé reformulé : la reformulation et la **phrase d'origine vérifiée** dont il vient.
public struct GroundedItem: Equatable, Sendable {
    public var text: String
    public var source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

/// Résumé reformulé, avant mise en blocs. Tous les points ont une source vérifiée (`SourceVerifier`).
public struct SummaryDraft: Equatable, Sendable {
    public var overview: String = ""
    public var keyPoints: [GroundedItem] = []
    public var decisions: [GroundedItem] = []
    public var actions: [GroundedItem] = []
    public var questions: [GroundedItem] = []
    public var keywords: [String] = []
    /// Points proposés par le modèle mais écartés : citation introuvable dans la source.
    public var rejectedItems = 0
    /// Morceaux de la source que le modèle n'a pas pu traiter (garde-fous, erreur).
    public var skippedChunks = 0

    public init() {}

    public var isEmpty: Bool { keyPoints.isEmpty && decisions.isEmpty && actions.isEmpty && questions.isEmpty }
}

/// « Réécrire avec mes mots-clés » : une section par mot-clé.
public struct FocusedDraft: Equatable, Sendable {
    public var sections: [(keyword: String, items: [GroundedItem])]
    public var rejectedItems = 0
    public var skippedChunks = 0

    public init(keywords: [String]) {
        sections = keywords.map { ($0, []) }
    }

    public static func == (lhs: FocusedDraft, rhs: FocusedDraft) -> Bool {
        lhs.sections.map(\.keyword) == rhs.sections.map(\.keyword)
            && lhs.sections.map(\.items) == rhs.sections.map(\.items)
            && lhs.rejectedItems == rhs.rejectedItems && lhs.skippedChunks == rhs.skippedChunks
    }
}

/// Carte mentale reformulée, avant mise en forme.
public struct MindMapDraft: Equatable, Sendable {
    public struct Idea: Equatable, Sendable {
        public var label: String
        public var kind: MindMapNodeKind
        public var source: String
    }

    public struct Topic: Equatable, Sendable {
        public var label: String
        public var ideas: [Idea]
    }

    public var topics: [Topic] = []

    public init() {}

    /// Ajoute un thème, en le fusionnant avec un thème déjà présent de même nom.
    public mutating func add(_ topic: Topic) {
        let key = SourceVerifier.normalize(topic.label)
        if let index = topics.firstIndex(where: { SourceVerifier.normalize($0.label) == key }) {
            for idea in topic.ideas where !topics[index].ideas.contains(where: { $0.source == idea.source }) {
                topics[index].ideas.append(idea)
            }
        } else {
            topics.append(topic)
        }
    }
}

/// Met en blocs (ou en carte mentale) un brouillon vérifié. Logique pure, testée.
public enum SummaryAssembler {
    static let maxPerSection = 8
    static let maxKeyPoints = 6

    public static func blocks(_ draft: SummaryDraft, locator: SourceLocator) -> [Block] {
        var blocks: [Block] = [Block(kind: .heading2, text: "Résumé")]
        if !draft.overview.isEmpty {
            blocks.append(Block(kind: .paragraph, text: RichText(draft.overview)))
        }
        // Une même phrase d'origine n'apparaît qu'une fois : décisions, actions et questions d'abord.
        var used = Set<String>()
        func unique(_ items: [GroundedItem], limit: Int) -> [GroundedItem] {
            var result: [GroundedItem] = []
            for item in items where !used.contains(item.source) && result.count < limit {
                used.insert(item.source)
                result.append(item)
            }
            return result
        }
        let decisions = unique(draft.decisions, limit: maxPerSection)
        let actions = unique(draft.actions, limit: maxPerSection)
        let questions = unique(draft.questions, limit: maxPerSection)
        let keyPoints = unique(draft.keyPoints, limit: maxKeyPoints)

        blocks += section("Points clés", keyPoints, kind: .bulleted, locator: locator)
        blocks += section("Décisions", decisions, kind: .bulleted, locator: locator)
        blocks += section("Actions", actions, kind: .todo, locator: locator)
        blocks += section("Questions ouvertes", questions, kind: .bulleted, locator: locator)

        if !draft.keywords.isEmpty {
            blocks.append(Block(kind: .callout, text: RichText(runs: [
                TextRun("Mots-clés : ", style: TextStyle(bold: true)),
                TextRun(draft.keywords.joined(separator: " · ")),
            ])))
        }
        blocks.append(footnote(skippedChunks: draft.skippedChunks, linked: !locator.isEmpty))
        return blocks
    }

    public static func blocks(_ draft: FocusedDraft, locator: SourceLocator) -> [Block] {
        var blocks: [Block] = [Block(kind: .heading2, text: RichText("Synthèse — " + draft.sections.map(\.keyword).joined(separator: ", ")))]
        for (keyword, items) in draft.sections {
            blocks.append(Block(kind: .heading3, text: RichText(TextAnalysis.capitalizedFirst(keyword))))
            var seen = Set<String>()
            let unique = items.filter { seen.insert($0.source).inserted }.prefix(maxPerSection)
            if unique.isEmpty {
                blocks.append(Block(kind: .paragraph, text: RichText("Aucune mention dans la source.", style: TextStyle(italic: true, color: .gray))))
            } else {
                blocks += unique.map { Block(kind: .bulleted, text: line($0, locator: locator)) }
            }
        }
        blocks.append(footnote(skippedChunks: draft.skippedChunks, linked: !locator.isEmpty))
        return blocks
    }

    public static func mindMap(_ draft: MindMapDraft, title: String, overview: String?, extraBranches: [MindMapNode]) -> MindMapDocument {
        var root = MindMapNode(label: title, detail: overview, kind: .root)
        for topic in draft.topics where !topic.ideas.isEmpty {
            root.children.append(MindMapNode(
                label: TextAnalysis.capitalizedFirst(topic.label),
                kind: .topic,
                sourceText: topic.ideas.first?.source,
                children: topic.ideas.prefix(5).map { idea in
                    MindMapNode(label: TextAnalysis.capitalizedFirst(idea.label), detail: idea.source, kind: idea.kind, sourceText: idea.source)
                }
            ))
        }
        root.children += extraBranches
        return MindMapDocument(title: title, root: root)
    }

    private static func section(_ title: String, _ items: [GroundedItem], kind: BlockKind, locator: SourceLocator) -> [Block] {
        guard !items.isEmpty else { return [] }
        return [Block(kind: .heading3, text: RichText(title))] + items.map { Block(kind: kind, text: line($0, locator: locator)) }
    }

    /// Reformulation, suivie de l'horodatage cliquable de la phrase d'origine si la source est une transcription.
    static func line(_ item: GroundedItem, locator: SourceLocator) -> RichText {
        var runs = [TextRun(item.text)]
        if let link = locator.link(for: item.source) {
            runs.append(TextRun(" "))
            runs.append(TextRun("[\(TranscriptSegment.formatTimestamp(link.time))]", style: TextStyle(link: link.url.absoluteString)))
        }
        return RichText(runs: runs)
    }

    static func footnote(skippedChunks: Int, linked: Bool) -> Block {
        var text = "Reformulé sur ce Mac par Apple Intelligence. Chaque point est tiré d'une phrase de la source"
        text += linked ? " : cliquez sur le repère [00:00] d'un point pour réécouter cette phrase." : "."
        if skippedChunks > 0 {
            text += " \(skippedChunks) passage(s) n'ont pas pu être traités."
        }
        return Block(kind: .paragraph, text: RichText(text, style: TextStyle(italic: true, color: .gray)))
    }
}
