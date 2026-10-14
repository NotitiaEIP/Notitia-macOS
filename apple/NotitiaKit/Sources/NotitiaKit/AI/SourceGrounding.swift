import Foundation
import NaturalLanguage

/// Découpe un texte en morceaux qui tiennent dans la fenêtre de contexte d'un modèle de langage,
/// sans jamais couper une phrase (sauf une phrase plus longue qu'un morceau entier).
public enum TextChunker {
    /// Caractères par token, estimation prudente pour le français (on ne peut compter les tokens
    /// qu'à partir de macOS 26.4).
    static let charactersPerToken = 2.5

    /// Taille d'un morceau en caractères pour une fenêtre de `contextSize` tokens, dont `reservedTokens`
    /// sont laissés aux consignes, au schéma de sortie et à la réponse.
    public static func characterBudget(contextSize: Int, reservedTokens: Int) -> Int {
        max(600, Int(Double(contextSize - reservedTokens) * charactersPerToken))
    }

    public static func chunks(of text: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(of: text) {
            for piece in split(sentence, maxCharacters: maxCharacters) {
                if !current.isEmpty, current.count + 1 + piece.count > maxCharacters {
                    chunks.append(current)
                    current = ""
                }
                current += current.isEmpty ? piece : " " + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func sentences(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    /// Une phrase plus longue qu'un morceau est coupée entre deux mots.
    private static func split(_ sentence: String, maxCharacters: Int) -> [String] {
        guard sentence.count > maxCharacters else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if !current.isEmpty, current.count + 1 + word.count > maxCharacters {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// Vérifie qu'une citation produite par un modèle de langage vient vraiment de la source,
/// et renvoie la **phrase d'origine exacte**. C'est ce qui empêche un résumé d'inventer une décision.
public struct SourceVerifier: Sendable {
    private struct Entry: Sendable {
        var original: String
        var normalized: String
        var words: Set<String>
    }

    private let entries: [Entry]

    /// Part minimale des mots de la citation qui doivent se trouver dans la phrase d'origine
    /// (le modèle recopie parfois une phrase avec un mot changé).
    public var minimumOverlap: Double = 0.8

    public init(text: String) {
        entries = TextChunker.sentences(of: text).map { sentence in
            let normalized = Self.normalize(sentence)
            return Entry(original: sentence, normalized: normalized, words: Self.words(normalized))
        }
    }

    /// Phrase d'origine dont `quote` est tirée, ou `nil` si la citation est introuvable (inventée).
    public func locate(_ quote: String) -> String? {
        let normalized = Self.normalize(quote)
        let quoteWords = Self.words(normalized)
        guard quoteWords.count >= 3 || normalized.count >= 15 else { return nil }

        // 1. Citation exacte, à la ponctuation et à la casse près.
        if let entry = entries.first(where: { $0.normalized.contains(normalized) }) { return entry.original }
        // 2. Citation qui couvre plusieurs phrases : on renvoie la première.
        if let entry = entries.first(where: { $0.normalized.count >= 15 && normalized.contains($0.normalized) }) {
            return entry.original
        }
        // 3. Recopie presque exacte : la phrase qui contient le plus de mots de la citation.
        let best = entries
            .map { entry in (entry, Double(quoteWords.intersection(entry.words).count) / Double(max(quoteWords.count, 1))) }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= minimumOverlap else { return nil }
        return best.0.original
    }

    /// Minuscules, sans accents, apostrophes unifiées, sans ponctuation, espaces simples.
    public static func normalize(_ text: String) -> String {
        NoteSearch.fold(text)
            .replacingOccurrences(of: "’", with: "'")
            .unicodeScalars
            .map { CharacterSet.punctuationCharacters.union(.symbols).contains($0) && $0 != "'" ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func words(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 2 })
    }
}

/// Retrouve l'instant d'un enregistrement où une phrase a été prononcée.
public struct SourceLocator: Sendable {
    private struct Entry: Sendable {
        var recordingID: UUID
        var start: TimeInterval
        var normalized: String
    }

    private let entries: [Entry]

    public init(recordings: [AISource.Recording]) {
        entries = recordings.flatMap { recording in
            recording.segments.filter(\.isFinal).map {
                Entry(recordingID: recording.id, start: $0.start, normalized: SourceVerifier.normalize($0.text))
            }
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func link(for sentence: String) -> TranscriptLink? {
        let normalized = SourceVerifier.normalize(sentence)
        guard !normalized.isEmpty else { return nil }
        let prefix = String(normalized.prefix(40))
        let match = entries.first { entry in
            !entry.normalized.isEmpty && (
                entry.normalized.contains(normalized)
                    || (entry.normalized.count >= 15 && normalized.contains(entry.normalized))
                    || entry.normalized.contains(prefix)
            )
        }
        return match.map { TranscriptLink(recordingID: $0.recordingID, time: $0.start) }
    }
}
