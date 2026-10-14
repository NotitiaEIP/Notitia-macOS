@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import NotitiaKit

private let script = DemoTranscriptionEngine.defaultScript.joined(separator: " ")

@Suite("Découpage et vérification des sources")
struct SourceGroundingTests {
    @Test func morceauxSansPhraseCoupee() {
        let chunks = TextChunker.chunks(of: script, maxCharacters: 300)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 300 })
        // Chaque phrase du script se retrouve entière dans un morceau.
        for sentence in DemoTranscriptionEngine.defaultScript {
            #expect(chunks.contains { $0.contains(sentence) }, "phrase coupée : \(sentence)")
        }
    }

    @Test func phraseTropLongueCoupeeEntreDeuxMots() {
        let long = Array(repeating: "mot", count: 200).joined(separator: " ") + "."
        let chunks = TextChunker.chunks(of: long, maxCharacters: 100)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks.joined(separator: " ") == long)
    }

    @Test func budgetDeCaracteres() {
        #expect(TextChunker.characterBudget(contextSize: 4096, reservedTokens: 1800) == 5740)
        #expect(TextChunker.characterBudget(contextSize: 1000, reservedTokens: 1800) == 600, "jamais sous le minimum")
    }

    @Test func citationExacteOuApprochee() {
        let verifier = SourceVerifier(text: script)
        let original = "Oui, c'est décidé : on garde uniquement la couleur d'accent du système."
        #expect(verifier.locate(original) == original)
        #expect(verifier.locate("OUI C’EST DECIDE on garde uniquement la couleur d’accent du systeme") == original,
                "casse, accents, apostrophes et ponctuation ignorés")
        #expect(verifier.locate("on garde uniquement la couleur d'accent") == original, "extrait d'une phrase")
        #expect(verifier.locate("Oui, c'est décidé : on conserve uniquement la couleur d'accent du système.") == original,
                "un mot changé reste reconnu")
    }

    @Test func citationInventeeRejetee() {
        let verifier = SourceVerifier(text: script)
        #expect(verifier.locate("Le budget du projet est doublé pour l'année prochaine.") == nil)
        #expect(verifier.locate("Oui") == nil, "trop court pour être une preuve")
        #expect(verifier.locate("") == nil)
    }

    @Test func citationSurDeuxPhrases() {
        let verifier = SourceVerifier(text: script)
        let quote = "Est-ce que tout le monde est d'accord pour abandonner l'ancien thème néon ? Oui, c'est décidé"
        #expect(verifier.locate(quote) == "Est-ce que tout le monde est d'accord pour abandonner l'ancien thème néon ?")
    }

    @Test func horodatageDeLaPhraseDOrigine() throws {
        let id = UUID()
        let segments = [
            TranscriptSegment(text: "Bonjour à tous.", start: 0, end: 2),
            TranscriptSegment(text: "On garde la couleur d'accent du système.", start: 12.5, end: 15),
        ]
        let locator = SourceLocator(recordings: [AISource.Recording(id: id, segments: segments)])
        let link = try #require(locator.link(for: "On garde la couleur d’accent du système."))
        #expect(link == TranscriptLink(recordingID: id, time: 12.5))
        #expect(locator.link(for: "Une phrase jamais prononcée pendant la réunion.") == nil)
        #expect(SourceLocator(recordings: []).isEmpty)
    }
}

@Suite("Résumé reformulé")
struct SummaryAssemblyTests {
    let verifier = SourceVerifier(text: script)
    let decision = "Oui, c'est décidé : on garde uniquement la couleur d'accent du système."
    let action = "Pour l'éditeur, il faut finir les listes de tâches et le menu des blocs avant vendredi."

    func draft() -> SummaryDraft {
        var draft = SummaryDraft()
        draft.add(RawChunkSummary(
            keyPoints: [
                RawPoint(text: "Interface sobre, conventions d'Apple.", quote: "on part sur une interface sobre qui suit les conventions d'Apple"),
                RawPoint(text: "Couleur d'accent du système retenue.", quote: decision), // doublon de la décision
            ],
            decisions: [RawPoint(text: "Abandon du thème néon au profit de la couleur d'accent.", quote: decision)],
            actions: [
                RawPoint(text: "Finir les listes de tâches et le menu des blocs, avant vendredi.", quote: action),
                RawPoint(text: "Publier l'application sur l'App Store demain.", quote: "On publie sur l'App Store demain matin."),
            ],
            keywords: ["Design", "design", "Transcription"]
        ), verifier: verifier)
        return draft
    }

    @Test func pointsInventesEcartes() {
        let draft = draft()
        #expect(draft.rejectedItems == 1, "l'action inventée est écartée")
        #expect(draft.actions.map(\.source) == [action])
        #expect(draft.decisions.first?.source == decision)
    }

    @Test func blocsAvecLesMemesSections() {
        let blocks = SummaryAssembler.blocks(draft(), locator: SourceLocator(recordings: []))
        let headings = blocks.filter { $0.kind == .heading3 }.map(\.text.plainText)
        #expect(blocks.first?.text.plainText == "Résumé")
        #expect(headings == ["Points clés", "Décisions", "Actions"])
        #expect(blocks.filter { $0.kind == .todo }.count == 1)
        // La même phrase d'origine n'apparaît qu'une fois : la décision prime sur le point clé.
        #expect(!blocks.contains { $0.text.plainText == "Couleur d'accent du système retenue." })
        #expect(blocks.last?.text.plainText.contains("Reformulé sur ce Mac") == true)
        #expect(blocks.allSatisfy { $0.text.runs.allSatisfy { $0.style.link == nil } }, "pas de lien sans transcription")
    }

    @Test func horodatagesCliquablesQuandLaSourceEstUneTranscription() throws {
        let id = UUID()
        let segments = DemoTranscriptionEngine.defaultScript.enumerated().map {
            TranscriptSegment(text: $0.element, start: Double($0.offset) * 5, end: Double($0.offset) * 5 + 4)
        }
        let blocks = SummaryAssembler.blocks(draft(), locator: SourceLocator(recordings: [AISource.Recording(id: id, segments: segments)]))
        let todo = try #require(blocks.first { $0.kind == .todo })
        let link = try #require(todo.text.runs.compactMap(\.style.link).first.flatMap(URL.init(string:)))
        #expect(TranscriptLink(url: link) == TranscriptLink(recordingID: id, time: 25))
        #expect(todo.text.plainText.hasSuffix("[00:25]"))
        #expect(blocks.last?.text.plainText.contains("réécouter cette phrase") == true)
    }

    @Test func syntheseParMotsCles() {
        var draft = FocusedDraft(keywords: ["Design", "Licorne"])
        draft.add([
            RawPoint(text: "Interface sobre.", quote: "on part sur une interface sobre qui suit les conventions d'Apple", keyword: "design"),
            RawPoint(text: "Hors sujet.", quote: decision, keyword: "Budget"),
        ], verifier: verifier)
        #expect(draft.rejectedItems == 1, "mot-clé non demandé")
        let blocks = SummaryAssembler.blocks(draft, locator: SourceLocator(recordings: []))
        #expect(blocks.filter { $0.kind == .heading3 }.map(\.text.plainText) == ["Design", "Licorne"])
        #expect(blocks.contains { $0.text.plainText == "Aucune mention dans la source." })
    }

    @Test func motsClesDedoublonnes() {
        #expect(FoundationModelsAIService.topKeywords(["design", "Transcription", "Design", "Désign", "RGPD"], limit: 2)
                == ["Design", "Transcription"])
        #expect(FoundationModelsAIService.topKeywords(["macOS", "RGPD"], limit: 2) == ["macOS", "RGPD"])
    }
}

@Suite("Carte mentale reformulée")
struct MindMapAssemblyTests {
    @Test func themesFusionnesEtIdeesVerifiees() throws {
        let verifier = SourceVerifier(text: script)
        var draft = MindMapDraft()
        draft.add(MindMapDraft.RawTopic(label: "Design", ideas: [
            .init(label: "Interface sobre", kind: .idea, quote: "on part sur une interface sobre qui suit les conventions d'Apple"),
            .init(label: "Idée inventée", kind: .idea, quote: "Nous allons ajouter une mascotte licorne."),
        ]), verifier: verifier)
        draft.add(MindMapDraft.RawTopic(label: "design", ideas: [
            .init(label: "Couleur d'accent", kind: .decision, quote: "on garde uniquement la couleur d'accent du système"),
        ]), verifier: verifier)
        draft.add(MindMapDraft.RawTopic(label: "Vide", ideas: [
            .init(label: "Rien", kind: .idea, quote: "texte absent de la source, vraiment absent"),
        ]), verifier: verifier)

        #expect(draft.topics.count == 1, "même thème fusionné, thème sans idée vérifiée ignoré")
        #expect(draft.topics.first?.ideas.map(\.label) == ["Interface sobre", "Couleur d'accent"])

        let person = MindMapNode(label: "Personnes", kind: .topic)
        let map = SummaryAssembler.mindMap(draft, title: "Point d'avancement", overview: nil, extraBranches: [person])
        #expect(map.root.label == "Point d'avancement")
        #expect(map.root.children.map(\.label) == ["Design", "Personnes"])
        let leaves = try #require(map.root.children.first?.children)
        #expect(leaves.allSatisfy { script.contains($0.sourceText ?? "∅") }, "chaque nœud cite une phrase exacte de la source")
        #expect(leaves.last?.kind == .decision)
    }
}

@Suite("Moteur Apple Intelligence")
struct FoundationModelsServiceTests {
    @Test func catalogue() {
        #expect(EngineCatalog.aiService(id: "local.extractive").descriptor.id == "local.extractive")
        #expect(EngineCatalog.aiService(id: "apple.foundationmodels").descriptor.id == "apple.foundationmodels")
        #expect(EngineCatalog.aiService(id: "").descriptor.id == EngineCatalog.defaultAIServiceID)
    }

    @Test func avancement() {
        #expect(AIProgress(completed: 2, total: 5).fraction == 0.4)
        #expect(AIProgress(completed: 7, total: 5).completed == 5, "jamais au-delà du total")
        #expect(AIProgress(completed: 0, total: 0).fraction == 0)
        #expect(EngineCatalog.effectiveAIServiceName(id: "local.extractive", locale: Locale(identifier: "fr_FR")) == "Moteur local")
    }

    @Test func repliSurLeMoteurLocal() async throws {
        let service = FoundationModelsAIService(forceUnavailable: true)
        let source = AISource(title: "Point d'avancement", text: script)
        let blocks = try await service.summarize(source, focus: [])
        #expect(blocks.first?.text.plainText == "Résumé")
        #expect(!blocks.contains { $0.text.plainText.contains("Reformulé sur ce Mac") }, "résumé extractif")
        #expect(try await service.keywords(source, limit: 4).count == 4)
        #expect(try await service.mindMap(source, focus: []).root.label == "Point d'avancement")
    }

    @Test func sourceTropCourte() async {
        await #expect(throws: AIError.self) {
            _ = try await FoundationModelsAIService(forceUnavailable: true).summarize(AISource(title: "", text: "court"), focus: [])
        }
    }
}

@Suite("Lecture d'un fichier audio")
struct AudioFileReaderTests {
    @Test func blocsHorodatesCommeLeMicro() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "notitia-sinus-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 20_000))
            buffer.frameLength = 20_000
            for i in 0..<20_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.5 }
            try file.write(from: buffer)
            file.close()
        }
        let (chunks, duration) = try AudioFileReader.chunks(of: url, chunkSize: 4096)
        #expect(abs(duration - 1.25) < 0.001)
        #expect(chunks.count == 5)
        #expect(chunks.map(\.time) == [0, 0.256, 0.512, 0.768, 1.024])
        #expect(chunks.last?.samples.count == 20_000 - 4 * 4096)
    }
}
