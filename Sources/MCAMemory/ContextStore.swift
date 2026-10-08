import Foundation
import MCACore
import OSLog

/// Query describing a slice of the user's recent past.
public struct ContextQuery: Sendable {
    public var text: String?
    public var since: Date?
    public var until: Date?
    public var appName: String?
    public var channels: [AudioChannel]?
    public var limit: Int

    public init(
        text: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        appName: String? = nil,
        channels: [AudioChannel]? = nil,
        limit: Int = 40
    ) {
        self.text = text
        self.since = since
        self.until = until
        self.appName = appName
        self.channels = channels
        self.limit = limit
    }
}

public struct ScoredObservation: Sendable {
    public var observation: DesktopObservation
    public var score: Double

    public init(observation: DesktopObservation, score: Double) {
        self.observation = observation
        self.score = score
    }
}

public protocol ContextStoring: Actor {
    func append(_ observation: DesktopObservation) async throws
    func search(_ query: ContextQuery) async throws -> [ScoredObservation]
    func recent(seconds: TimeInterval, limit: Int) async throws -> [DesktopObservation]
    func purge(olderThan days: Int) async throws -> Int
    func count() async throws -> Int
}

/// SQLite-backed context store with hybrid retrieval.
///
/// Search fuses two rankings with Reciprocal Rank Fusion:
///
/// - **FTS5** catches exact tokens — identifiers, error codes, proper nouns —
///   which an embedding will happily blur into a neighbourhood.
/// - **Vector similarity** catches paraphrase, which lexical search misses
///   entirely ("the deployment discussion" vs "we ship on Friday").
///
/// Either one alone has a failure mode the user will hit within a day.
/// Similarity is brute-force: at the tens-of-thousands-of-rows scale this
/// corpus reaches, a full scan is milliseconds and an ANN index would only add
/// a build step and recall loss.
public actor SQLiteContextStore: ContextStoring {
    public enum StoreError: Error, CustomStringConvertible {
        case fts5Unavailable

        public var description: String {
            switch self {
            case .fts5Unavailable:
                return "This SQLite build lacks FTS5; full-text search is unavailable"
            }
        }
    }

    private let log = Logger(subsystem: "com.buddypia.mca", category: "Memory")
    private let db: SQLiteDatabase
    private var embedder: (any TextEmbedding)?

    /// RRF damping constant. 60 is the value from the original paper and is
    /// insensitive enough that tuning it is rarely worth it.
    private let rrfK = 60.0

    public init(url: URL, embedder: (any TextEmbedding)? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.db = try SQLiteDatabase(path: url.path)
        self.embedder = embedder
        try Self.migrate(db)
    }

    public func setEmbedder(_ embedder: (any TextEmbedding)?) {
        self.embedder = embedder
    }

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS observations (
                id           INTEGER PRIMARY KEY,
                uuid         TEXT NOT NULL UNIQUE,
                kind         TEXT NOT NULL,
                ts           REAL NOT NULL,
                app_name     TEXT NOT NULL DEFAULT '',
                bundle_id    TEXT,
                window_title TEXT NOT NULL DEFAULT '',
                channel      TEXT,
                speaker_id   TEXT,
                source       TEXT,
                trigger      TEXT,
                text         TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_observations_ts ON observations(ts);
            CREATE INDEX IF NOT EXISTS idx_observations_app ON observations(app_name);
            """)

        guard (try? db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS observations_fts USING fts5(
                text, app_name, window_title,
                content='observations', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            """)) != nil else {
            throw StoreError.fts5Unavailable
        }

        // Keep the FTS index in lockstep with the base table. Doing this in
        // triggers rather than app code means a write can never half-apply.
        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS observations_ai AFTER INSERT ON observations BEGIN
                INSERT INTO observations_fts(rowid, text, app_name, window_title)
                VALUES (new.id, new.text, new.app_name, new.window_title);
            END;
            CREATE TRIGGER IF NOT EXISTS observations_ad AFTER DELETE ON observations BEGIN
                INSERT INTO observations_fts(observations_fts, rowid, text, app_name, window_title)
                VALUES ('delete', old.id, old.text, old.app_name, old.window_title);
            END;
            CREATE TRIGGER IF NOT EXISTS observations_au AFTER UPDATE ON observations BEGIN
                INSERT INTO observations_fts(observations_fts, rowid, text, app_name, window_title)
                VALUES ('delete', old.id, old.text, old.app_name, old.window_title);
                INSERT INTO observations_fts(rowid, text, app_name, window_title)
                VALUES (new.id, new.text, new.app_name, new.window_title);
            END;
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS embeddings (
                observation_id INTEGER PRIMARY KEY
                    REFERENCES observations(id) ON DELETE CASCADE,
                dim    INTEGER NOT NULL,
                model  TEXT NOT NULL DEFAULT '',
                vector BLOB NOT NULL
            );
            """)

        let columns = (try? db.query("PRAGMA table_info(embeddings)") { $0.string(1) }) ?? []
        if !columns.isEmpty && !columns.contains("model") {
            try? db.execute("ALTER TABLE embeddings ADD COLUMN model TEXT NOT NULL DEFAULT ''")
        }
        try db.execute("CREATE INDEX IF NOT EXISTS idx_embeddings_model_dim ON embeddings(model, dim)")
    }

    // MARK: - Ingest

    public func append(_ observation: DesktopObservation) async throws {
        let record = Record(observation)
        guard !record.text.isEmpty else { return }

        try db.run(
            """
            INSERT OR IGNORE INTO observations
                (uuid, kind, ts, app_name, bundle_id, window_title,
                 channel, speaker_id, source, trigger, text)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(record.uuid),
                .text(record.kind),
                .double(record.timestamp.timeIntervalSince1970),
                .text(record.appName),
                record.bundleID.map { .text($0) } ?? .null,
                .text(record.windowTitle),
                record.channel.map { .text($0) } ?? .null,
                record.speakerID.map { .text($0) } ?? .null,
                record.source.map { .text($0) } ?? .null,
                record.trigger.map { .text($0) } ?? .null,
                .text(record.text),
            ])

        guard let embedder else { return }
        let rows = try db.query(
            "SELECT id FROM observations WHERE uuid = ?", [.text(record.uuid)]
        ) { $0.int(0) }
        guard let rowID = rows.first else { return }

        // Embedding is best-effort: a failure here degrades search to lexical
        // only, which is still useful, so it must not fail the write.
        if let vector = await embedder.embed(record.text) {
            let modelName = embedder.modelIdentifier ?? ""
            try? db.run(
                "INSERT OR REPLACE INTO embeddings (observation_id, dim, model, vector) VALUES (?,?,?,?)",
                [.int(rowID), .int(Int64(vector.count)), .text(modelName), .blob(Self.pack(vector))])
        }
    }

    // MARK: - Retrieval

    public func recent(seconds: TimeInterval, limit: Int = 60) async throws -> [DesktopObservation] {
        let cutoff = Date().addingTimeInterval(-seconds).timeIntervalSince1970
        return try db.query(
            """
            SELECT uuid, kind, ts, app_name, bundle_id, window_title,
                   channel, speaker_id, source, trigger, text
            FROM observations WHERE ts >= ? ORDER BY ts DESC LIMIT ?
            """,
            [.double(cutoff), .int(Int64(limit))],
            row: Self.decode
        ).compactMap { $0 }
    }

    public func search(_ query: ContextQuery) async throws -> [ScoredObservation] {
        var filters: [String] = []
        var arguments: [SQLiteDatabase.Value] = []

        if let since = query.since {
            filters.append("o.ts >= ?")
            arguments.append(.double(since.timeIntervalSince1970))
        }
        if let until = query.until {
            filters.append("o.ts <= ?")
            arguments.append(.double(until.timeIntervalSince1970))
        }
        if let appName = query.appName {
            filters.append("o.app_name LIKE ?")
            arguments.append(.text("%\(appName)%"))
        }
        if let channels = query.channels, !channels.isEmpty {
            let placeholders = channels.map { _ in "?" }.joined(separator: ",")
            filters.append("o.channel IN (\(placeholders))")
            arguments.append(contentsOf: channels.map { .text($0.rawValue) })
        }
        let whereClause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")

        // No search text: this is a pure time/app filter, not a ranking problem.
        guard let text = query.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            let rows = try db.query(
                """
                SELECT o.uuid, o.kind, o.ts, o.app_name, o.bundle_id, o.window_title,
                       o.channel, o.speaker_id, o.source, o.trigger, o.text
                FROM observations o \(whereClause)
                ORDER BY o.ts DESC LIMIT ?
                """,
                arguments + [.int(Int64(query.limit))],
                row: Self.decode)
            return rows.compactMap { $0 }.map { ScoredObservation(observation: $0, score: 1) }
        }

        // Over-fetch each ranker so the fusion has something to work with.
        let candidateLimit = max(query.limit * 4, 40)

        let lexical = try lexicalRanking(
            text: text, whereClause: whereClause,
            arguments: arguments, limit: candidateLimit)
        let semantic = await semanticRanking(
            text: text, whereClause: whereClause,
            arguments: arguments, limit: candidateLimit)

        // Reciprocal Rank Fusion. Using ranks rather than raw scores is what
        // makes this work: BM25 and cosine similarity are not on comparable
        // scales and normalising them is fragile.
        var fused: [Int64: Double] = [:]
        for (rank, id) in lexical.enumerated() {
            fused[id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
        }
        for (rank, id) in semantic.enumerated() {
            fused[id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
        }

        let top = fused.sorted { $0.value > $1.value }.prefix(query.limit)
        guard !top.isEmpty else { return [] }

        let placeholders = top.map { _ in "?" }.joined(separator: ",")
        let rows = try db.query(
            """
            SELECT uuid, kind, ts, app_name, bundle_id, window_title,
                   channel, speaker_id, source, trigger, text, id
            FROM observations WHERE id IN (\(placeholders))
            """,
            top.map { .int($0.key) }
        ) { row -> (Int64, DesktopObservation?) in
            (row.int(11), Self.decode(row))
        }

        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { id, observation in
            observation.map { (id, $0) }
        })
        return top.compactMap { id, score in
            byID[id].map { ScoredObservation(observation: $0, score: score) }
        }
    }

    private func lexicalRanking(
        text: String, whereClause: String,
        arguments: [SQLiteDatabase.Value], limit: Int
    ) throws -> [Int64] {
        let joined = whereClause.isEmpty
            ? "WHERE observations_fts MATCH ?"
            : whereClause + " AND observations_fts MATCH ?"

        return try db.query(
            """
            SELECT o.id FROM observations_fts
            JOIN observations o ON o.id = observations_fts.rowid
            \(joined)
            ORDER BY bm25(observations_fts) LIMIT ?
            """,
            arguments + [.text(Self.escapeFTS(text)), .int(Int64(limit))]
        ) { $0.int(0) }
    }

    private func semanticRanking(
        text: String, whereClause: String,
        arguments: [SQLiteDatabase.Value], limit: Int
    ) async -> [Int64] {
        guard let embedder, let queryVector = await embedder.embed(text) else { return [] }

        let dim = queryVector.count
        var filters = ["e.dim = ?"]
        var filterArgs: [SQLiteDatabase.Value] = [.int(Int64(dim))]

        if let modelName = embedder.modelIdentifier, !modelName.isEmpty {
            filters.append("(e.model = ? OR e.model = '')")
            filterArgs.append(.text(modelName))
        }

        if !whereClause.isEmpty {
            let stripped = whereClause.hasPrefix("WHERE ")
                ? String(whereClause.dropFirst(6))
                : whereClause
            filters.append(stripped)
            filterArgs.append(contentsOf: arguments)
        }

        let whereExpr = "WHERE " + filters.joined(separator: " AND ")
        let sql = """
            SELECT e.observation_id, e.vector FROM embeddings e
            JOIN observations o ON o.id = e.observation_id
            \(whereExpr)
            """
        let candidates: [(Int64, [Float])]
        do {
            candidates = try db.query(sql, filterArgs) { row in
                (row.int(0), Self.unpack(row.blob(1)))
            }
        } catch {
            log.error("Semantic ranking failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        return candidates
            .map { ($0.0, VectorMath.cosineSimilarity($0.1, queryVector)) }
            .filter { $0.1 > 0.2 }  // drop near-orthogonal noise
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Maintenance

    public func purge(olderThan days: Int) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let before = try count()
        try db.run("DELETE FROM observations WHERE ts < ?", [.double(cutoff)])
        try db.execute("INSERT INTO observations_fts(observations_fts) VALUES('optimize')")
        return before - (try count())
    }

    public func count() throws -> Int {
        let rows = try db.query("SELECT COUNT(*) FROM observations") { Int($0.int(0)) }
        return rows.first ?? 0
    }

    // MARK: - Encoding helpers

    private static func pack(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func unpack(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    /// FTS5 treats a bare query as a mini-language; a stray quote or `NEAR`
    /// from user text would be a syntax error. Quoting each token turns the
    /// whole thing into a literal AND-of-terms.
    private static func escapeFTS(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .filter { $0 != "\"\"" }
            .joined(separator: " ")
    }

    private static func decode(_ row: SQLiteDatabase.Row) -> DesktopObservation? {
        let uuid = UUID(uuidString: row.string(0)) ?? UUID()
        let kind = row.string(1)
        let timestamp = Date(timeIntervalSince1970: row.double(2))

        switch kind {
        case "screen":
            return .screen(ScreenObservation(
                id: uuid,
                timestamp: timestamp,
                bundleID: row.optionalString(4),
                appName: row.string(3),
                windowTitle: row.string(5),
                text: row.string(10),
                source: ScreenTextSource(rawValue: row.optionalString(8) ?? "") ?? .accessibility,
                trigger: CaptureTrigger(rawValue: row.optionalString(9) ?? "") ?? .unknown))
        case "audio":
            return .audio(AudioObservation(
                id: uuid,
                timestamp: timestamp,
                channel: AudioChannel(rawValue: row.optionalString(6) ?? "") ?? .microphone,
                speakerID: row.optionalString(7),
                text: row.string(10),
                isFinal: true))
        default:
            return nil
        }
    }

    private struct Record {
        var uuid: String
        var kind: String
        var timestamp: Date
        var appName: String
        var bundleID: String?
        var windowTitle: String
        var channel: String?
        var speakerID: String?
        var source: String?
        var trigger: String?
        var text: String

        init(_ observation: DesktopObservation) {
            switch observation {
            case .screen(let s):
                uuid = s.id.uuidString
                kind = "screen"
                timestamp = s.timestamp
                appName = s.appName
                bundleID = s.bundleID
                windowTitle = s.windowTitle
                channel = nil
                speakerID = nil
                source = s.source.rawValue
                trigger = s.trigger.rawValue
                text = s.text
            case .audio(let a):
                uuid = a.id.uuidString
                kind = "audio"
                timestamp = a.timestamp
                appName = ""
                bundleID = nil
                windowTitle = ""
                channel = a.channel.rawValue
                speakerID = a.speakerID
                source = nil
                trigger = nil
                text = a.text
            }
        }
    }
}
