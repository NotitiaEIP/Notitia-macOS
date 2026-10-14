import Foundation

/// Description d'un moteur (transcription ou IA) affichée dans les réglages.
public struct EngineDescriptor: Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var detail: String
    /// Le moteur envoie des données sur le réseau. Les moteurs réseau sont toujours
    /// désactivés par défaut et exigent un consentement explicite (voir docs/PRIVACY.md).
    public var requiresNetwork: Bool
    /// Disponible dans cette version de l'application.
    public var isAvailable: Bool

    public init(id: String, displayName: String, detail: String, requiresNetwork: Bool, isAvailable: Bool) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.requiresNetwork = requiresNetwork
        self.isAvailable = isAvailable
    }
}

/// Bloc d'échantillons audio mono, copiés hors du thread audio.
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    /// Position du premier échantillon, en secondes depuis le début de l'enregistrement (pauses exclues).
    /// Toutes les analyses s'alignent sur cette horloge, même si un bloc est perdu en route.
    public var time: TimeInterval

    public init(samples: [Float], sampleRate: Double, time: TimeInterval = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.time = time
    }

    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    /// Niveau RMS normalisé entre 0 et 1 (pour l'indicateur de niveau).
    public var level: Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 55) / 55))
    }
}

/// Moteur de transcription : reçoit le flux audio et produit des segments.
///
/// Un même segment (même `id`) peut être émis plusieurs fois : provisoire (`isFinal == false`)
/// puis définitif. Le consommateur remplace le segment à chaque émission.
public protocol TranscriptionEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func transcribe(audio: AsyncStream<AudioChunk>, locale: Locale) -> AsyncThrowingStream<TranscriptSegment, any Error>
}

/// Détecteur d'annotations : reçoit le même flux audio que le moteur de transcription et produit des
/// annotations horodatées sur la même horloge (`AudioChunk.time`). Il décrit ce qu'on entend,
/// jamais l'état d'une personne (voir `TranscriptAnnotation`).
public protocol AnnotationDetector: Sendable {
    func detect(audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptAnnotation, any Error>
}

/// Texte source d'une action IA : contenu d'une note ou transcription.
public struct AISource: Sendable {
    /// Transcription d'un enregistrement, pour relier chaque point d'un résumé à l'instant où il a été dit.
    public struct Recording: Sendable {
        public var id: UUID
        public var segments: [TranscriptSegment]

        public init(id: UUID, segments: [TranscriptSegment]) {
            self.id = id
            self.segments = segments
        }
    }

    public var title: String
    public var text: String
    public var localeIdentifier: String
    /// Vide quand la source est le texte de la note.
    public var recordings: [Recording]

    public init(title: String, text: String, localeIdentifier: String = "fr_FR", recordings: [Recording] = []) {
        self.title = title
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.recordings = recordings
    }
}

public enum AIError: LocalizedError {
    case emptySource
    case engineUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptySource: "La note ne contient pas encore assez de texte."
        case .engineUnavailable(let name): "Le moteur « \(name) » n'est pas disponible."
        }
    }
}

/// Avancement d'une action IA longue (par exemple 2 morceaux traités sur 5).
public struct AIProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = max(0, min(completed, total))
        self.total = max(0, total)
    }

    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// Actions IA sur les notes. Toutes renvoient des blocs ou des structures éditables :
/// l'utilisateur garde la main sur le résultat.
public protocol NoteAIService: Sendable {
    var descriptor: EngineDescriptor { get }
    /// Résumé. Avec `focus`, synthèse organisée autour des mots-clés de l'utilisateur.
    func summarize(_ source: AISource, focus: [String]) async throws -> [Block]
    func keywords(_ source: AISource, limit: Int) async throws -> [String]
    func mindMap(_ source: AISource, focus: [String]) async throws -> MindMapDocument
}

/// Catalogue des moteurs connus. Seuls les moteurs hors ligne sont disponibles ;
/// les autres sont listés pour rendre la feuille de route visible dans les réglages.
public enum EngineCatalog {
    /// Moteur utilisé quand l'utilisateur n'a rien choisi : la vraie transcription d'Apple.
    public static let defaultTranscriptionEngineID = AppleSpeechTranscriptionEngine.descriptorValue.id

    public static let transcriptionEngines: [EngineDescriptor] = [
        AppleSpeechTranscriptionEngine.descriptorValue,
        DemoTranscriptionEngine.descriptorValue,
        EngineDescriptor(
            id: "cloud.deepgram",
            displayName: "Deepgram — cloud",
            detail: "Nécessite Internet et un consentement explicite. Non activé.",
            requiresNetwork: true,
            isAvailable: false
        ),
    ]

    /// Moteur de synthèse par défaut : Apple Intelligence, avec repli automatique sur le moteur extractif.
    public static let defaultAIServiceID = FoundationModelsAIService.descriptorValue.id

    public static let aiServices: [EngineDescriptor] = [
        FoundationModelsAIService.descriptorValue,
        LocalExtractiveAIService.descriptorValue,
        EngineDescriptor(
            id: "cloud.llm",
            displayName: "Modèle de langage — cloud",
            detail: "Nécessite Internet et un consentement explicite. Non activé.",
            requiresNetwork: true,
            isAvailable: false
        ),
    ]

    /// Moteur correspondant à `id` ; un identifiant inconnu ou vide donne le moteur par défaut.
    public static func transcriptionEngine(id: String, contextualStrings: [String] = []) -> any TranscriptionEngine {
        switch id {
        case DemoTranscriptionEngine.descriptorValue.id:
            DemoTranscriptionEngine()
        default:
            AppleSpeechTranscriptionEngine(contextualStrings: contextualStrings)
        }
    }

    /// Moteur correspondant à `id` ; un identifiant inconnu ou vide donne le moteur par défaut.
    /// `onProgress` n'est appelé que par les moteurs qui travaillent en plusieurs étapes.
    public static func aiService(id: String, onProgress: (@Sendable (AIProgress) -> Void)? = nil) -> any NoteAIService {
        switch id {
        case LocalExtractiveAIService.descriptorValue.id:
            LocalExtractiveAIService()
        default:
            FoundationModelsAIService(onProgress: onProgress)
        }
    }

    /// Nom du moteur qui travaillera **réellement** pour `id`, compte tenu du repli quand Apple Intelligence
    /// n'est pas disponible pour cette langue (affiché pendant une génération et dans l'inspecteur).
    public static func effectiveAIServiceName(id: String, locale: Locale) -> String {
        let usesAppleIntelligence = id != LocalExtractiveAIService.descriptorValue.id
            && FoundationModelsAIService.unavailabilityReason(for: locale) == nil
        return usesAppleIntelligence ? "Apple Intelligence" : "Moteur local"
    }
}
