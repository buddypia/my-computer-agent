import Foundation
import NaturalLanguage

/// Turns text into a vector for semantic retrieval.
///
/// A protocol rather than a concrete type because the right embedding model
/// changes faster than anything else in this system. The built-in
/// `NLEmbedding` needs no download and works offline from first launch;
/// swapping in EmbeddingGemma-300M via MLX later is a matter of adding a
/// conformance, and nothing above this line changes.
public protocol TextEmbedding: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async -> [Float]?
}

/// Apple's on-device sentence embedding.
///
/// **Not wired up by default, on measured evidence.** For the paraphrase
/// queries this app cares about it does not merely underperform, it inverts:
///
/// ```
/// query "when are we shipping"
///   vs "We agreed to release the new build on Friday afternoon." → 0.030
///   vs "The cafeteria menu changed this week."                   → 0.060
/// ```
///
/// RRF tolerates a weak second ranker but not an anti-correlated one, so
/// enabling this would make retrieval worse than lexical search alone. The
/// semantic path is served instead by on-device query expansion in the
/// reasoning layer, which uses a model that actually understands the question.
///
/// Kept because the conformance is the seam: pointing this protocol at
/// EmbeddingGemma-300M through MLX is a drop-in change, and nothing above it
/// moves.
///
/// `@unchecked Sendable`: `NLEmbedding` is an immutable, thread-safe model
/// handle that the framework has simply not annotated.
public final class NLTextEmbedding: TextEmbedding, @unchecked Sendable {
    private let embedding: NLEmbedding?

    public var dimension: Int { embedding?.dimension ?? 0 }
    public var isAvailable: Bool { embedding != nil }

    public init(language: NLLanguage = .english) {
        self.embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    public func embed(_ text: String) async -> [Float]? {
        guard let embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Sentence embeddings degrade on very long inputs; a screen dump can be
        // thousands of characters, so take the leading window.
        let clipped = String(trimmed.prefix(1000))
        guard let vector = embedding.vector(for: clipped) else { return nil }

        let floats = vector.map(Float.init)
        return VectorMath.normalized(floats)
    }
}

public enum VectorMath {
    /// L2-normalises so cosine similarity reduces to a dot product at query
    /// time. Vectors are stored normalised for the same reason.
    public static func normalized(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for value in vector { sumSquares += value * value }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = (normA.squareRoot() * normB.squareRoot())
        guard denominator > 0 else { return 0 }
        return Double(dot / denominator)
    }
}
