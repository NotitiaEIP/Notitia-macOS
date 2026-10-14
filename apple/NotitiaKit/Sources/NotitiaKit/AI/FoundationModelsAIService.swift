import Foundation
import FoundationModels

/// Résumés, mots-clés et cartes mentales **reformulés** par le modèle d'Apple Intelligence, sur l'appareil.
///
/// Fidélité : le modèle doit citer, pour chaque point, la phrase de la source dont il vient ; `SourceVerifier`
/// écarte tout point dont la citation est introuvable. Le résumé ne peut donc pas inventer une décision, et chaque
/// point renvoie à l'instant où il a été dit (`SourceLocator`).
///
/// Les longues sources sont découpées (`TextChunker`) pour tenir dans la fenêtre de contexte. Si le modèle est
/// indisponible (Mac non compatible, Apple Intelligence désactivée, langue non prise en charge) ou n'aboutit sur
/// aucun morceau, le service se rabat sur `LocalExtractiveAIService`.
///
/// Seul `SystemLanguageModel` (sur l'appareil) est utilisé, jamais le Private Cloud Compute.
public struct FoundationModelsAIService: NoteAIService {
    public static let descriptorValue = EngineDescriptor(
        id: "apple.foundationmodels",
        displayName: "Apple Intelligence — sur l'appareil",
        detail: "Reformule résumés et cartes mentales sur ce Mac, sans Internet ; chaque point renvoie à sa phrase d'origine. Moteur local en repli.",
        requiresNetwork: false,
        isAvailable: true
    )

    public var descriptor: EngineDescriptor { Self.descriptorValue }

    let fallback = LocalExtractiveAIService()
    /// Pour les tests : force l'indisponibilité du modèle.
    var forceUnavailable = false
    /// Appelé après chaque étape (un morceau de la source, puis la vue d'ensemble d'un résumé).
    public var onProgress: (@Sendable (AIProgress) -> Void)?

    public init(onProgress: (@Sendable (AIProgress) -> Void)? = nil) {
        self.onProgress = onProgress
    }

    init(forceUnavailable: Bool) {
        self.forceUnavailable = forceUnavailable
    }

    // MARK: Disponibilité

    /// `nil` si le modèle est utilisable pour cette langue, sinon la raison, à afficher dans les réglages.
    public static func unavailabilityReason(for locale: Locale) -> String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? nil : "Apple Intelligence ne prend pas en charge cette langue."
        case .unavailable(.deviceNotEligible):
            return "Ce Mac n'est pas compatible avec Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Activez Apple Intelligence dans Réglages Système pour utiliser ce moteur."
        case .unavailable(.modelNotReady):
            return "Le modèle d'Apple Intelligence est en cours de préparation. Réessayez dans quelques minutes."
        case .unavailable:
            return "Apple Intelligence n'est pas disponible."
        }
    }

    private func isUsable(for source: AISource) -> Bool {
        !forceUnavailable && Self.unavailabilityReason(for: Locale(identifier: source.localeIdentifier)) == nil
    }

    // MARK: NoteAIService

    public func summarize(_ source: AISource, focus: [String]) async throws -> [Block] {
        try Self.checkLength(source)
        let focus = focus.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard isUsable(for: source) else { return try await fallback.summarize(source, focus: focus) }
        let verifier = SourceVerifier(text: source.text)
        let locator = SourceLocator(recordings: source.recordings)

        let chunks = chunks(of: source)
        if focus.isEmpty {
            var draft = SummaryDraft()
            // La vue d'ensemble est une étape de plus.
            let total = chunks.count + 1
            report(0, of: total)
            for (index, chunk) in chunks.enumerated() {
                if let reading = await respond(ChunkSummary.self, chunk: chunk, prompt: Self.summaryPrompt) {
                    draft.add(reading.raw, verifier: verifier)
                } else {
                    draft.skippedChunks += 1
                }
                report(index + 1, of: total)
            }
            guard !draft.isEmpty else { return try await fallback.summarize(source, focus: focus) }
            draft.overview = await overview(of: draft)
            report(total, of: total)
            draft.keywords = Self.topKeywords(draft.keywords, limit: 6)
            return SummaryAssembler.blocks(draft, locator: locator)
        } else {
            var draft = FocusedDraft(keywords: focus)
            let prompt = Self.focusPrompt(focus)
            report(0, of: chunks.count)
            for (index, chunk) in chunks.enumerated() {
                if let reading = await respond(FocusedChunk.self, chunk: chunk, prompt: prompt) {
                    draft.add(reading.points.map { RawPoint(text: $0.text, quote: $0.quote, keyword: $0.keyword) }, verifier: verifier)
                } else {
                    draft.skippedChunks += 1
                }
                report(index + 1, of: chunks.count)
            }
            return SummaryAssembler.blocks(draft, locator: locator)
        }
    }

    public func keywords(_ source: AISource, limit: Int) async throws -> [String] {
        try Self.checkLength(source)
        guard isUsable(for: source) else { return try await fallback.keywords(source, limit: limit) }
        var all: [String] = []
        let chunks = chunks(of: source)
        report(0, of: chunks.count)
        for (index, chunk) in chunks.enumerated() {
            if let reading = await respond(ChunkKeywords.self, chunk: chunk, prompt: "Donne les concepts importants de cet extrait.") {
                all += reading.keywords
            }
            report(index + 1, of: chunks.count)
        }
        let result = Self.topKeywords(all, limit: limit)
        return result.isEmpty ? try await fallback.keywords(source, limit: limit) : result
    }

    public func mindMap(_ source: AISource, focus: [String]) async throws -> MindMapDocument {
        try Self.checkLength(source)
        let focus = focus.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard isUsable(for: source) else { return try await fallback.mindMap(source, focus: focus) }
        let verifier = SourceVerifier(text: source.text)
        var draft = MindMapDraft()
        let prompt = focus.isEmpty
            ? "Organise cet extrait en thèmes, chacun avec ses idées, décisions, actions et questions."
            : "Organise cet extrait autour de ces thèmes, et seulement ceux-ci : \(focus.joined(separator: ", "))."
        let chunks = chunks(of: source)
        report(0, of: chunks.count)
        for (index, chunk) in chunks.enumerated() {
            if let reading = await respond(ChunkMindMap.self, chunk: chunk, prompt: prompt) {
                for topic in reading.raw {
                    draft.add(topic, verifier: verifier)
                }
            }
            report(index + 1, of: chunks.count)
        }
        guard !draft.topics.isEmpty else { return try await fallback.mindMap(source, focus: focus) }
        let analysis = TextAnalysis(text: source.text, title: source.title)
        let title = source.title.trimmingCharacters(in: .whitespaces).isEmpty ? (draft.topics.first?.label ?? "Sujet") : source.title
        return SummaryAssembler.mindMap(
            draft,
            title: title,
            overview: analysis.ranked().first?.text,
            extraBranches: LocalExtractiveAIService.entityBranches(source.text, analysis: analysis)
        )
    }

    // MARK: Modèle

    static let instructions = """
    Tu aides à prendre des notes de réunions et de cours. On te donne un extrait.
    Règles strictes :
    - Tu reformules de façon courte, claire et fidèle. Tu n'ajoutes rien qui ne soit pas dans l'extrait.
    - Pour chaque élément, tu recopies mot pour mot, dans « quote », la phrase de l'extrait dont il vient.
    - Une décision est ce qui a été décidé ou validé. Une action est une tâche à faire, avec son échéance si elle est
      citée. Une question est une question restée ouverte.
    - Tu ne juges pas les personnes et tu ne devines ni leurs émotions ni leurs intentions.
    - Si une catégorie est vide dans l'extrait, laisse la liste vide.
    - Tu réponds dans la langue de l'extrait.
    """

    static let summaryPrompt = "Résume cet extrait : idées importantes, décisions, actions, questions ouvertes et mots-clés."

    static func focusPrompt(_ focus: [String]) -> String {
        "Pour chacun de ces mots-clés, relève ce que dit l'extrait (rien si l'extrait n'en parle pas) : \(focus.joined(separator: ", "))."
    }

    /// Instructions + schéma de sortie + réponse : ce qui reste est pour l'extrait.
    static let reservedTokens = 1_800

    private func chunks(of source: AISource) -> [String] {
        let budget = TextChunker.characterBudget(contextSize: SystemLanguageModel.default.contextSize, reservedTokens: Self.reservedTokens)
        return TextChunker.chunks(of: source.text, maxCharacters: budget)
    }

    /// Une session par morceau : le contexte reste petit et les morceaux ne s'influencent pas.
    /// Si le morceau dépasse malgré tout la fenêtre, il est coupé en deux et le résultat de la première moitié
    /// est gardé (la seconde sera couverte par le morceau suivant dans la plupart des cas).
    private func respond<Output: Generable>(_ type: Output.Type, chunk: String, prompt: String, retry: Bool = true) async -> Output? {
        guard !Task.isCancelled else { return nil }
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            return try await session.respond(
                to: "\(prompt)\n\nExtrait :\n\(chunk)",
                generating: type,
                options: GenerationOptions(temperature: 0)
            ).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where retry {
            let half = TextChunker.chunks(of: chunk, maxCharacters: max(300, chunk.count / 2))
            return await respond(type, chunk: half.first ?? chunk, prompt: prompt, retry: false)
        } catch {
            return nil
        }
    }

    private func report(_ completed: Int, of total: Int) {
        onProgress?(AIProgress(completed: completed, total: total))
    }

    private func overview(of draft: SummaryDraft) async -> String {
        let notes = (draft.decisions + draft.actions + draft.keyPoints).prefix(12).map { "- " + $0.text }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: Self.instructions)
        let reading = try? await session.respond(
            to: "Voici les notes d'une réunion ou d'un cours. Écris une vue d'ensemble de 2 ou 3 phrases, fidèle à ces notes.\n\n\(notes)",
            generating: Overview.self,
            options: GenerationOptions(temperature: 0)
        ).content
        return reading?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func checkLength(_ source: AISource) throws {
        guard source.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else { throw AIError.emptySource }
    }

    /// Mots-clés les plus fréquents d'un morceau à l'autre, sans doublon (casse et accents ignorés).
    static func topKeywords(_ keywords: [String], limit: Int) -> [String] {
        var counts: [String: (display: String, count: Int, first: Int)] = [:]
        for (index, keyword) in keywords.enumerated() {
            let display = keyword.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let key = SourceVerifier.normalize(display)
            guard !key.isEmpty, display.count <= 40 else { continue }
            if let existing = counts[key] {
                counts[key] = (existing.display, existing.count + 1, existing.first)
            } else {
                // « macOS » ou « RGPD » gardent leur casse ; « design » devient « Design ».
                counts[key] = (display == display.lowercased() ? TextAnalysis.capitalizedFirst(display) : display, 1, index)
            }
        }
        return counts.values
            .sorted { ($0.count, -$0.first) > ($1.count, -$1.first) }
            .prefix(limit)
            .map(\.display)
    }
}

// MARK: - Sorties structurées

// Un seul type d'élément, utilisé une seule fois dans le schéma : avec un type partagé par plusieurs listes,
// le modèle recopiait la référence du schéma (« #/$defs/… ») au lieu de la citation.
// La citation est demandée **avant** la reformulation : le modèle part de la phrase réelle.

@Generable
enum SummaryCategory {
    case pointCle
    case decision
    case action
    case question
}

@Generable
struct SummaryItemReading {
    @Guide(description: "La phrase de l'extrait dont l'élément vient, recopiée mot pour mot.")
    var quote: String
    var category: SummaryCategory
    @Guide(description: "Reformulation courte et fidèle de cette phrase.")
    var text: String
}

@Generable
struct ChunkSummary {
    @Guide(description: "Idées importantes, décisions, actions et questions ouvertes de l'extrait.", .maximumCount(15))
    var items: [SummaryItemReading]
    @Guide(description: "Mots-clés de l'extrait, 1 à 3 mots chacun.", .maximumCount(5))
    var keywords: [String]
}

@Generable
struct FocusedPointReading {
    @Guide(description: "Le mot-clé concerné, tel qu'il est donné dans la demande.")
    var keyword: String
    @Guide(description: "La phrase de l'extrait dont le point vient, recopiée mot pour mot.")
    var quote: String
    @Guide(description: "Ce que l'extrait dit de ce mot-clé, reformulé en une phrase.")
    var text: String
}

@Generable
struct FocusedChunk {
    @Guide(description: "Points de l'extrait liés aux mots-clés demandés.", .maximumCount(10))
    var points: [FocusedPointReading]
}

@Generable
struct ChunkKeywords {
    @Guide(description: "Concepts importants de l'extrait, 1 à 3 mots chacun.", .maximumCount(8))
    var keywords: [String]
}

@Generable
enum IdeaKindReading {
    case idee
    case decision
    case action
    case question
}

@Generable
struct IdeaReading {
    @Guide(description: "La phrase de l'extrait dont l'idée vient, recopiée mot pour mot.")
    var quote: String
    var kind: IdeaKindReading
    @Guide(description: "Idée en 3 à 8 mots.")
    var label: String
}

@Generable
struct TopicReading {
    @Guide(description: "Nom du thème, 1 à 4 mots.")
    var label: String
    @Guide(.maximumCount(5))
    var ideas: [IdeaReading]
}

@Generable
struct ChunkMindMap {
    @Guide(description: "Thèmes de l'extrait.", .maximumCount(5))
    var topics: [TopicReading]
}

@Generable
struct Overview {
    @Guide(description: "Vue d'ensemble de 2 ou 3 phrases.")
    var text: String
}

// MARK: - Conversion vers des types simples (testables sans le modèle)

/// Point proposé par le modèle, avant vérification.
struct RawPoint: Equatable, Sendable {
    var text: String
    var quote: String
    var keyword: String = ""
}

struct RawChunkSummary: Equatable, Sendable {
    var keyPoints: [RawPoint] = []
    var decisions: [RawPoint] = []
    var actions: [RawPoint] = []
    var questions: [RawPoint] = []
    var keywords: [String] = []
}

extension ChunkSummary {
    var raw: RawChunkSummary {
        func points(_ category: SummaryCategory) -> [RawPoint] {
            items.filter { $0.category == category }.map { RawPoint(text: $0.text, quote: $0.quote) }
        }
        return RawChunkSummary(keyPoints: points(.pointCle), decisions: points(.decision), actions: points(.action),
                               questions: points(.question), keywords: keywords)
    }
}

extension ChunkMindMap {
    var raw: [MindMapDraft.RawTopic] {
        topics.map { topic in
            MindMapDraft.RawTopic(label: topic.label, ideas: topic.ideas.map { idea in
                let kind: MindMapNodeKind = switch idea.kind {
                case .idee: .idea
                case .decision: .decision
                case .action: .action
                case .question: .question
                }
                return MindMapDraft.RawIdea(label: idea.label, kind: kind, quote: idea.quote)
            })
        }
    }
}

extension SummaryDraft {
    /// Ajoute les points d'un morceau en ne gardant que ceux dont la citation est retrouvée dans la source.
    mutating func add(_ chunk: RawChunkSummary, verifier: SourceVerifier) {
        func verified(_ points: [RawPoint]) -> [GroundedItem] {
            points.compactMap { point in
                let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let source = verifier.locate(point.quote) else {
                    rejectedItems += 1
                    return nil
                }
                return GroundedItem(text: text, source: source)
            }
        }
        keyPoints += verified(chunk.keyPoints)
        decisions += verified(chunk.decisions)
        actions += verified(chunk.actions)
        questions += verified(chunk.questions)
        keywords += chunk.keywords
    }
}

extension FocusedDraft {
    mutating func add(_ points: [RawPoint], verifier: SourceVerifier) {
        for point in points {
            let key = SourceVerifier.normalize(point.keyword)
            let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = sections.firstIndex(where: { SourceVerifier.normalize($0.keyword) == key }),
                  !text.isEmpty, let source = verifier.locate(point.quote) else {
                rejectedItems += 1
                continue
            }
            sections[index].items.append(GroundedItem(text: text, source: source))
        }
    }
}

extension MindMapDraft {
    struct RawIdea: Equatable, Sendable {
        var label: String
        var kind: MindMapNodeKind
        var quote: String
    }

    struct RawTopic: Equatable, Sendable {
        var label: String
        var ideas: [RawIdea]
    }

    /// Ajoute un thème proposé par le modèle, en ne gardant que les idées dont la citation est retrouvée.
    mutating func add(_ topic: RawTopic, verifier: SourceVerifier) {
        let label = topic.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        let ideas = topic.ideas.compactMap { idea -> Idea? in
            guard let source = verifier.locate(idea.quote) else { return nil }
            let ideaLabel = idea.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return Idea(label: ideaLabel.isEmpty ? TextAnalysis.condensed(source) : ideaLabel, kind: idea.kind, source: source)
        }
        guard !ideas.isEmpty else { return }
        add(Topic(label: label, ideas: ideas))
    }
}
