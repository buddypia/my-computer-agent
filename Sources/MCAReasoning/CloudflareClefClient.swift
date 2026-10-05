import Foundation

/// System One on Cloudflare Workers AI (`@cf/cloudflare/clef`, `@cf/cloudflare/clef-flash`).
///
/// Clef speaks the same request shape as TypeSafe (state + typed `noul`/`choice`/`score`
/// questions) and adds `images`, so it slots in behind `TypeSafeEvaluating` unchanged.
/// Credentials come from the user's existing Cloudflare CLI session (`cf auth login`); nothing is stored here.
public struct CloudflareClefClient: TypeSafeEvaluating {
    public enum Model: String, Sendable, CaseIterable {
        case clef
        case clefFlash = "clef-flash"
    }

    public enum ClientError: LocalizedError, Sendable {
        case httpError(status: Int, message: String)
        case apiError(String)
        case invalidAccount

        public var errorDescription: String? {
            switch self {
            case .httpError(let status, let message): return "Workers AI returned HTTP \(status): \(message)"
            case .apiError(let message): return "Workers AI error: \(message)"
            case .invalidAccount: return "Cloudflare account id is not usable in a URL"
            }
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let model: Model
    private let credentials: CloudflareCredentials
    private let transport: Transport

    public init(
        model: Model = .clef,
        credentials: CloudflareCredentials = .shared,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.model = model
        self.credentials = credentials
        self.transport = transport
    }

    public var acceptsImages: Bool { true }

    public func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
        do {
            return try await send(request, forceRefresh: false)
        } catch ClientError.httpError(let status, _) where status == 401 {
            // The cached OAuth token expired between refreshes; ask cf once more.
            // A 403 (Workers AI not enabled, missing scope) would not be fixed by a new token.
            return try await send(request, forceRefresh: true)
        }
    }

    private func send(_ request: TypeSafeClient.EvaluationRequest, forceRefresh: Bool) async throws -> TypeSafeClient.EvaluationResponse {
        let auth = try await credentials.current(forceRefresh: forceRefresh)
        var body = request
        body.model = model.rawValue

        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(auth.accountId)/ai/run/@cf/cloudflare/\(model.rawValue)") else {
            throw ClientError.invalidAccount
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Measured: 1-3s for text, 6-14s with a 768px screenshot.
        urlRequest.timeoutInterval = (request.images?.isEmpty ?? true) ? 10 : 30
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport(urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw ClientError.httpError(status: status, message: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.success, let result = envelope.result else {
            throw ClientError.apiError(envelope.errors.map(\.message).joined(separator: "; "))
        }
        return result
    }

    private struct Envelope: Decodable {
        struct Message: Decodable { let message: String }
        let result: TypeSafeClient.EvaluationResponse?
        let success: Bool
        let errors: [Message]
    }
}

/// Cloudflare account id + bearer token, taken from the environment or from `cf` CLI.
///
/// `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` are the names `cf` itself reads.
/// Without them, the token comes from `cf auth whoami` and OAuth profile configuration,
/// which refreshes the OAuth token from `cf auth login` as needed. That token lives
/// about an hour or more, so it is cached and refreshed on a 401. Each CLI call starts Node
/// (1-3s measured), so `prefetch()` warms the cache before the first decision.
public actor CloudflareCredentials {
    public struct Auth: Sendable, Equatable {
        public let accountId: String
        public let token: String
    }

    public enum CredentialError: LocalizedError, Sendable {
        case cfUnavailable(String)
        case accountAmbiguous(Int)

        public static func wranglerUnavailable(_ detail: String) -> CredentialError {
            .cfUnavailable(detail)
        }

        public var errorDescription: String? {
            switch self {
            case .cfUnavailable(let detail): return "cf credentials unavailable: \(detail)"
            case .accountAmbiguous(let n): return "cf is logged in to \(n) accounts; set CLOUDFLARE_ACCOUNT_ID"
            }
        }
    }

    /// Runs a cf subcommand and returns its stdout.
    public typealias Runner = @Sendable ([String]) async throws -> String

    public static let shared = CloudflareCredentials()

    private let environment: [String: String]
    private let runner: Runner
    private let tokenLifetime: TimeInterval
    private var cached: (auth: Auth, until: Date)?
    /// The prefetch and the first decision would otherwise each start cf.
    private var inflight: Task<Auth, Error>?
    /// After a failed lookup, calls fail fast until this date instead of starting cf
    /// on every decision; the engine falls back to offline meanwhile.
    private var failedUntil: Date?
    private let failureBackoff: TimeInterval
    private var accountId: String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: @escaping Runner = CloudflareCredentials.runCf,
        tokenLifetime: TimeInterval = 45 * 60,
        failureBackoff: TimeInterval = 5 * 60
    ) {
        self.environment = environment
        self.runner = runner
        self.tokenLifetime = tokenLifetime
        self.failureBackoff = failureBackoff
    }

    /// Resolves credentials in the background so the first decision does not wait for cf.
    public nonisolated func prefetch() {
        Task { _ = try? await current() }
    }

    public func current(forceRefresh: Bool = false) async throws -> Auth {
        if let token = (environment["CLOUDFLARE_API_TOKEN"] ?? environment["CF_API_TOKEN"]), !token.isEmpty,
           let account = environment["CLOUDFLARE_ACCOUNT_ID"], !account.isEmpty {
            return Auth(accountId: account, token: token)
        }
        if !forceRefresh, let cached, cached.until > Date() {
            return cached.auth
        }
        if let failedUntil, failedUntil > Date() {
            throw CredentialError.cfUnavailable("previous lookup failed; retrying after backoff")
        }
        // A forced refresh must not reuse an in-flight lookup that may return the stale token.
        if !forceRefresh, let inflight { return try await inflight.value }
        let task = Task { try await fetch(forceRefresh: forceRefresh) }
        inflight = task
        defer { if inflight == task { inflight = nil } }
        do {
            let auth = try await task.value
            cached = (auth, Date().addingTimeInterval(tokenLifetime))
            failedUntil = nil
            return auth
        } catch {
            // Drop the token too: after a failed refresh it is the one the server just rejected.
            cached = nil
            failedUntil = Date().addingTimeInterval(failureBackoff)
            throw error
        }
    }

    private func fetch(forceRefresh: Bool = false) async throws -> Auth {
        // Run cf auth whoami to check/refresh credentials and retrieve account info.
        let whoami = try await runner(["auth", "whoami"])
        let accountId = try await resolveAccountId(from: whoami)
        let token = try resolveToken(from: whoami)
        return Auth(accountId: accountId, token: token)
    }

    private func resolveAccountId(from whoamiOutput: String? = nil) async throws -> String {
        if let account = environment["CLOUDFLARE_ACCOUNT_ID"], !account.isEmpty { return account }
        if let accountId { return accountId }
        let raw: String
        if let whoamiOutput {
            raw = whoamiOutput
        } else {
            raw = try await runner(["auth", "whoami"])
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(Self.jsonObject(in: raw).utf8)) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]] else {
            throw CredentialError.cfUnavailable("unexpected whoami output")
        }
        guard accounts.count == 1, let id = accounts[0]["id"] as? String else {
            throw CredentialError.accountAmbiguous(accounts.count)
        }
        accountId = id
        return id
    }

    private func resolveToken(from output: String) throws -> String {
        // 1. Direct token in CLI/mock JSON output (e.g. tests or custom runner response)
        if let json = try? JSONSerialization.jsonObject(with: Data(Self.jsonObject(in: output).utf8)) as? [String: Any] {
            if let token = (json["token"] ?? json["oauth_token"]) as? String, !token.isEmpty {
                return token
            }
        }
        // 2. Read from profile config file on disk
        if let profileToken = readProfileOAuthToken() {
            return profileToken
        }
        throw CredentialError.cfUnavailable("no oauth_token found in cf profile or output")
    }

    private func readProfileOAuthToken() -> String? {
        let profile = environment["CLOUDFLARE_PROFILE"] ?? "default"
        let candidateDirs: [URL] = [
            environment["CLOUDFLARE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) },
            environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("cloudflare/config") },
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/cloudflare/config"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cloudflare/config")
        ].compactMap { $0 }

        for dir in candidateDirs {
            let file = dir.appendingPathComponent("\(profile).json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["oauth_token"] as? String, !token.isEmpty else {
                continue
            }
            return token
        }
        return nil
    }

    static func field(_ name: String, in raw: String) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: Data(jsonObject(in: raw).utf8)) as? [String: Any],
              let value = json[name] as? String, !value.isEmpty else {
            throw CredentialError.cfUnavailable("no \(name) in cf output")
        }
        return value
    }

    /// cf can print banners and warnings around its JSON.
    static func jsonObject(in raw: String) -> String {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return raw }
        return String(raw[start...end])
    }

    /// Runs cf through a login shell. A GUI app starts with a minimal PATH, and `-l`
    /// reads `.zprofile` but not `.zshrc`, so the usual install locations (mise shims,
    /// Homebrew, /usr/local) are prepended as well. Falls back to `npx` when cf is not
    /// installed globally, and gives up after `timeout` (npx may download, or hang offline).
    public static let runCf: Runner = { arguments in
        try await run(arguments, timeout: 30)
    }

    public static let runWrangler: Runner = runCf

    static func run(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let args = arguments.map { "'\($0)'" }.joined(separator: " ")
        let script = "if command -v cf >/dev/null 2>&1; then exec cf \(args); else exec npx --yes cf \(args); fi"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["\(home)/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let state = RunState()
        // One reader drains the pipe to EOF so a large output cannot stall the process.
        // `exec` above makes the timeout's signal reach cf/npx rather than only zsh.
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            state.append((try? stdout.fileHandleForReading.readToEnd()) ?? Data())
            reader.leave()
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                // A grandchild still holding the pipe must not block this handler.
                _ = reader.wait(timeout: .now() + 2)
                if finished.terminationStatus == 0 {
                    state.finish { continuation.resume(returning: String(decoding: state.output, as: UTF8.self)) }
                } else {
                    state.finish { continuation.resume(throwing: CredentialError.cfUnavailable("cf \(arguments.first ?? "") exited \(finished.terminationStatus)")) }
                }
            }
            do {
                try process.run()
            } catch {
                state.finish { continuation.resume(throwing: CredentialError.cfUnavailable(error.localizedDescription)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.finish {
                    process.terminate()
                    continuation.resume(throwing: CredentialError.cfUnavailable("cf \(arguments.first ?? "") timed out after \(Int(timeout))s"))
                }
            }
        }
    }

    /// Output collected from the pipe, and a once-only guard so the continuation resumes once.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var done = false

        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var output: Data { lock.withLock { data } }

        func finish(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
}
