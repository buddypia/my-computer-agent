import Foundation
import MCACore
import OSLog

/// Orders on-screen elements by how close they are in meaning to the goal.
///
/// Returns `nil` when it cannot rank, and the caller keeps its own order. A ranker
/// only reorders: it never decides what to do, so a wrong ranking costs a slower
/// or escalated step, not a wrong action.
public protocol UIElementRanking: Sendable {
    func rank(goal: String, candidates: [UIElementCandidate]) async -> [UIElementCandidate]?
}

/// Ranks elements with the local EmbeddingGemma 2 server (`eg2`).
///
/// Capture keeps elements in accessibility-tree order, so in a large window the
/// element the goal needs can sit past the cut. Embedding the goal and each element
/// and sorting by cosine similarity finds it by meaning, in any app and language,
/// in about 50 ms once the server is warm. Element vectors are cached by text: the
/// same window is read again on every step of a task.
///
/// Elements are described by role, label and value only. Coordinates say nothing
/// about meaning and pull every element towards every other.
public actor EmbeddingElementRanker: UIElementRanking {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let log = Logger(subsystem: "com.buddypia.mca", category: "ElementRanker")
    private let endpoint: URL
    private let model: String
    private let dimensions: Int
    private let transport: Transport
    private let launcher: EG2Launcher?
    private var cache: [String: [Float]] = [:]
    private let cacheLimit = 2_000

    /// - Parameter launcher: starts the server when it is not running. `nil` never starts anything.
    public init(
        endpoint: URL,
        model: String = "440m",
        dimensions: Int = 256,
        launcher: EG2Launcher? = nil,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.endpoint = endpoint
        self.model = model
        self.dimensions = dimensions
        self.launcher = launcher
        self.transport = transport
    }

    /// The ranker for the app: the local `eg2` server, started on demand.
    ///
    /// `nil` when the configured URL is not loopback. On-screen labels can carry
    /// anything the user is looking at, and they leave the machine only on the
    /// user's explicit say-so (`MCA_ALLOW_INSECURE_REMOTE_EMBEDDING` is for memory,
    /// not for this).
    public static func local(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EmbeddingElementRanker? {
        let base = environment["EG2_URL"] ?? environment["MCA_EMBEDDING_GEMMA_URL"] ?? EG2Launcher.defaultURL
        guard var components = URLComponents(string: base),
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        components.path = "/v1/embeddings"
        components.query = nil
        guard let url = components.url else { return nil }
        return EmbeddingElementRanker(endpoint: url, launcher: EG2Launcher(environment: environment))
    }

    public func rank(goal: String, candidates: [UIElementCandidate]) async -> [UIElementCandidate]? {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !candidates.isEmpty else { return nil }
        let texts = candidates.map(Self.describe)
        let missing = Array(Set(texts.filter { cache[$0] == nil }))
        do {
            async let goalVectors = embed([goal], inputType: "query")
            async let elementVectors = embed(missing, inputType: "document")
            let (query, documents) = try await (goalVectors, elementVectors)
            guard let goalVector = query.first else { return nil }
            store(zip(missing, documents))
            let scored = zip(candidates, texts).map { candidate, text in
                (candidate, cache[text].map { Self.cosine(goalVector, $0) } ?? -1)
            }
            // Stable for ties, so equal scores keep tree order.
            return scored.enumerated()
                .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .map(\.element.0)
        } catch {
            if Self.isConnectionFailure(error), let launcher {
                // Not awaited: this step keeps the capture order, the next one is ranked.
                Task.detached { await launcher.startIfNeeded() }
            }
            log.debug("Element ranking unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func describe(_ candidate: UIElementCandidate) -> String {
        var parts = [candidate.role.replacingOccurrences(of: "AX", with: "")]
        if !candidate.label.isEmpty { parts.append(candidate.label) }
        if let value = candidate.value, !value.isEmpty, value != candidate.label { parts.append(value) }
        return String(parts.joined(separator: " ").prefix(300))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let norm = (na * nb).squareRoot()
        return norm > 0 ? dot / norm : -1
    }

    private func store(_ pairs: Zip2Sequence<[String], [[Float]]>) {
        if cache.count > cacheLimit { cache.removeAll(keepingCapacity: true) }
        for (text, vector) in pairs { cache[text] = vector }
    }

    private struct EmbeddingsResponse: Decodable {
        struct Item: Decodable {
            let index: Int
            let embedding: [Float]
        }
        let data: [Item]
    }

    private func embed(_ inputs: [String], inputType: String) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A ranking that arrives after the step has moved on is worth nothing.
        request.timeoutInterval = 2
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": inputs, "dimensions": dimensions, "input_type": inputType,
        ])
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let items = try JSONDecoder().decode(EmbeddingsResponse.self, from: data).data
        guard items.count == inputs.count else { throw URLError(.cannotParseResponse) }
        return items.sorted { $0.index < $1.index }.map(\.embedding)
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut].contains(urlError.code)
    }
}

/// Starts the local `eg2` server on demand.
///
/// The server exits by itself when idle, so a request that finds it stopped is the
/// normal case, not a failure. `eg2 start` is idempotent and safe to run while
/// another client starts it. Attempts are spaced out so a machine without `eg2`
/// does not spawn a process on every step.
public actor EG2Launcher {
    public static let defaultURL = "http://127.0.0.1:38765"

    private let log = Logger(subsystem: "com.buddypia.mca", category: "ElementRanker")
    private let executable: URL?
    private var lastAttempt: ContinuousClock.Instant?
    private let retryInterval: Duration

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retryInterval: Duration = .seconds(60)
    ) {
        self.executable = Self.locate(environment: environment)
        self.retryInterval = retryInterval
    }

    /// Where `eg2` is. Checked by path because an app launched from Finder does not
    /// inherit the shell's `PATH`.
    static func locate(
        environment: [String: String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        var paths: [String] = []
        if let explicit = environment["EG2_BIN"], !explicit.isEmpty { paths.append(explicit) }
        let home = environment["HOME"] ?? NSHomeDirectory()
        paths += ["\(home)/.local/bin/eg2", "/opt/homebrew/bin/eg2", "/usr/local/bin/eg2"]
        return paths.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    public func startIfNeeded() async {
        guard let executable else { return }
        let now = ContinuousClock.now
        if let lastAttempt, lastAttempt.duration(to: now) < retryInterval { return }
        lastAttempt = now
        let process = Process()
        process.executableURL = executable
        process.arguments = ["start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            log.info("Started eg2 for element ranking")
        } catch {
            log.warning("Could not start eg2: \(error.localizedDescription, privacy: .public)")
        }
    }
}
