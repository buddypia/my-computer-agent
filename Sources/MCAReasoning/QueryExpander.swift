import Foundation
import MCACore
import MCAMemory
import OSLog

/// Bridges the gap between how a user asks and how the text was actually
/// written.
///
/// This exists because the obvious approach did not survive measurement. The
/// plan was FTS5 fused with vector similarity from Apple's built-in
/// `NLEmbedding`; benchmarking it on real phrasings showed it ranking an
/// unrelated sentence *above* the correct one, which is worse than having no
/// second ranker at all.
///
/// Expanding the query with the on-device model instead reaches the same goal
/// through the tools already present: it costs nothing, stays local, and the
/// 3B model is comfortably good enough for "give me other words for this",
/// which is the kind of task Apple actually recommends it for.
public struct QueryExpander: Sendable {
    private let log = Logger(subsystem: "com.buddypia.mca", category: "QueryExpander")
    private let router: ModelRouter
    /// Skip expansion for queries that are already specific — an exact
    /// identifier or error code needs no synonyms and expansion only adds noise.
    private let minimumWordsToExpand: Int

    public init(router: ModelRouter, minimumWordsToExpand: Int = 3) {
        self.router = router
        self.minimumWordsToExpand = minimumWordsToExpand
    }

    /// Returns the original query plus alternate phrasings, most likely first.
    public func expand(_ query: String) async -> [String] {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= minimumWordsToExpand else { return [query] }

        let schema = Data("""
            {
              "type": "object",
              "properties": {
                "phrasings": {
                  "type": "array",
                  "items": {"type": "string"}
                }
              },
              "required": ["phrasings"]
            }
            """.utf8)

        do {
            let response = try await router.run(
                task: .triage,  // the on-device tier; expansion must stay free
                transcript: [
                    .instructions("""
                        Rewrite the user's search query as up to three alternate \
                        phrasings that might literally appear in a transcript or \
                        on screen. Use the words people would actually type or \
                        say, not synonyms of the question itself.

                        Example: "when are we shipping" → ["release date", \
                        "ship on", "deadline", "launch"]

                        Return only the JSON object.
                        """),
                    .prompt(Prompt(text: query)),
                ],
                temperature: 0,
                responseSchema: schema)

            guard let json = parseJSONObject(extractJSON(response.text)),
                  let phrasings = json["phrasings"] as? [String]
            else { return [query] }

            let alternates = phrasings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != query.lowercased() }
                .prefix(3)

            return [query] + alternates
        } catch {
            // Expansion is an optimisation; losing it degrades recall but never
            // correctness, so the original query is always returned.
            log.debug("Query expansion unavailable: \(error.localizedDescription, privacy: .public)")
            return [query]
        }
    }

    private func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else { return text }
        return String(text[start...end])
    }
}

/// Runs each phrasing as its own lexical search and fuses the rankings.
///
/// Fusing on rank rather than score means a phrasing that matches nothing
/// contributes nothing, instead of dragging the combined score down.
public struct ExpandedSearch: Sendable {
    private let store: any ContextStoring
    private let expander: QueryExpander
    private let rrfK = 60.0

    public init(store: any ContextStoring, expander: QueryExpander) {
        self.store = store
        self.expander = expander
    }

    public func search(_ query: ContextQuery) async throws -> [ScoredObservation] {
        guard let text = query.text, !text.isEmpty else {
            return try await store.search(query)
        }

        let phrasings = await expander.expand(text)
        guard phrasings.count > 1 else {
            return try await store.search(query)
        }

        var fused: [UUID: (observation: DesktopObservation, score: Double)] = [:]
        for (phrasingIndex, phrasing) in phrasings.enumerated() {
            var subQuery = query
            subQuery.text = phrasing
            subQuery.limit = max(query.limit * 2, 30)

            guard let results = try? await store.search(subQuery) else { continue }

            // The user's own wording is weighted above the model's guesses.
            let weight = phrasingIndex == 0 ? 1.5 : 1.0
            for (rank, result) in results.enumerated() {
                let id = identifier(of: result.observation)
                let contribution = weight / (rrfK + Double(rank + 1))
                if var existing = fused[id] {
                    existing.score += contribution
                    fused[id] = existing
                } else {
                    fused[id] = (result.observation, contribution)
                }
            }
        }

        return fused.values
            .sorted { $0.score > $1.score }
            .prefix(query.limit)
            .map { ScoredObservation(observation: $0.observation, score: $0.score) }
    }

    private func identifier(of observation: DesktopObservation) -> UUID {
        switch observation {
        case .screen(let screen): return screen.id
        case .audio(let audio): return audio.id
        }
    }
}
