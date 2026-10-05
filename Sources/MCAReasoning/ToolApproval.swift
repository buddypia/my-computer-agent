import Foundation
import MCACore

// MARK: - Approval

/// What a tool is about to do, in the exact terms the user needs to judge it.
///
/// `detail` is the literal AppleScript, JavaScript, path or payload — never a
/// model-written summary of it. The model that proposes the action may have
/// been steered by text it read on screen, so the user has to see what will
/// really run, not what the model says it will run.
public struct ToolApprovalRequest: Sendable, Equatable {
    public let toolName: String
    /// One line: "Run AppleScript", "Write a file".
    public let title: String
    /// The exact thing that will execute. Shown verbatim, monospaced.
    public let detail: String
    /// Set when the action deserves extra attention (e.g. a path outside the
    /// home folder).
    public let warning: String?

    public init(toolName: String, title: String, detail: String, warning: String? = nil) {
        self.toolName = toolName
        self.title = title
        self.detail = detail
        self.warning = warning
    }
}

public enum ToolApprovalDecision: Sendable, Equatable {
    case approved
    case denied(reason: String)
}

/// Gate that dangerous tools must pass before they run.
///
/// Tools hold one of these instead of deciding for themselves, so the same
/// tool is interactive in the app, a y/N prompt in `mca ask`, and denied over
/// MCP — and tests inject their own. Every dangerous tool defaults to
/// ``DenyAllToolApprover``: a composition root that forgets to wire an approver
/// gets a tool that refuses, not one that runs unattended.
public protocol ToolApproving: Sendable {
    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision
}

/// Refuses everything. The default wherever no human is available to ask.
public struct DenyAllToolApprover: ToolApproving {
    public let reason: String

    public init(reason: String = "no interactive approver is available, so dangerous tools are disabled") {
        self.reason = reason
    }

    public func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        .denied(reason: reason)
    }
}

/// Approves everything. Only for an explicit, user-configured opt-in
/// (`mcpAllowDangerousTools`) and for tests that exercise the tool body.
public struct AutoApproveToolApprover: ToolApproving {
    public init() {}

    public func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        .approved
    }
}

/// Makes model-supplied text safe to show in an approval prompt.
///
/// A path or app name is shown on one labelled line ("Path: …"). If it may carry
/// a newline it can end that line and print another, such as a fake
/// "Path: ~/Desktop/notes.txt" above the real one; ANSI escapes can do the same
/// to a terminal prompt by overwriting what was already printed. Control and
/// line-separator characters are therefore written out as visible escapes
/// instead of being rendered.
/// Preserve the public Reasoning spelling while sharing the pure formatter with UI.
public typealias ApprovalText = MCACore.ApprovalText

extension ToolApproving {
    /// Returns nil when the action may proceed, otherwise the text to hand back
    /// to the model in place of a result.
    ///
    /// The wording tells the model not to route around the refusal: a model
    /// that is told only "no" tends to try the same thing through another tool.
    public func gate(_ request: ToolApprovalRequest) async -> String? {
        switch await decide(request) {
        case .approved:
            return nil
        case .denied(let reason):
            return """
                Error: approval_required: '\(request.toolName)' was NOT run — it was not approved (\(reason)). \
                Do not retry it or achieve the same effect with a different tool. \
                Tell the user what you wanted to do and why, and let them decide.
                """
        }
    }
}

// MARK: - File write policy

/// Decides whether a path may be written at all, and whether a human has to
/// look first.
///
/// Three outcomes rather than two. Some destinations are never something the
/// agent should write — shell startup files, `~/.ssh`, LaunchAgents, `.git`
/// folders, the app's own configuration — because a
/// write there is persistent code execution, and a confirmation dialog is a
/// weak defence against a path that looks innocuous in a one-line prompt. Those
/// are refused outright. Everything else needs the user's approval; paths
/// outside the home folder are flagged so the prompt says so.
public enum FileWritePolicy {
    public enum Verdict: Equatable, Sendable {
        case denied(reason: String)
        case needsApproval(outsideHome: Bool)
    }

    private static let shellStartupFiles: Set<String> = [
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
        ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile",
        ".cshrc", ".tcshrc", ".login", ".kshrc",
    ]

    /// Path suffixes (lowercased, relative to a `/Library` or `~/Library`)
    /// under which a dropped file runs at login or boot.
    private static let persistenceDirectories = [
        "/library/launchagents", "/library/launchdaemons", "/library/startupitems",
        "/library/loginitems",
    ]

    private static let systemRoots = [
        "/system", "/bin", "/sbin", "/usr", "/etc", "/private/etc", "/private/var/root",
    ]

    /// `supportDirectory` is the app's own data directory (config.json, the
    /// context database). A write there could flip `mcpAllowDangerousTools` or
    /// shrink the privacy exclusions, i.e. switch off the other defences.
    public static func evaluate(
        path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDirectory: URL = AgentConfiguration.defaultSupportDirectory
    ) -> Verdict {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let target = canonicalPath(URL(fileURLWithPath: expanded)) else {
            return .denied(reason: "the path is a chain of symlinks too long (or looping) to tell where the write would land")
        }
        let homePath = canonicalPath(home) ?? home.standardizedFileURL.path

        let lowerTarget = target.lowercased()
        let lowerHome = homePath.lowercased()
        let name = (target as NSString).lastPathComponent.lowercased()
        let lowerSupport = (canonicalPath(supportDirectory) ?? supportDirectory.standardizedFileURL.path).lowercased()

        if lowerTarget == lowerSupport || lowerTarget.hasPrefix(lowerSupport + "/") {
            return .denied(reason: "this is the app's own configuration and data directory; changing it could turn off its safety settings")
        }
        if lowerTarget.split(separator: "/").contains(".git") {
            return .denied(reason: "files inside a .git folder (hooks, config) run code on the next git command")
        }

        if shellStartupFiles.contains(name) {
            return .denied(reason: "'\(name)' is a shell startup file; writing it makes code run in every terminal")
        }
        if persistenceDirectories.contains(where: { lowerTarget.contains($0 + "/") || lowerTarget.hasSuffix($0) }) {
            return .denied(reason: "files in LaunchAgents / LaunchDaemons / login items run automatically at login or boot")
        }
        if systemRoots.contains(where: { lowerTarget == $0 || lowerTarget.hasPrefix($0 + "/") }) {
            return .denied(reason: "system directories are not writable by the agent")
        }

        let insideHome = lowerTarget == lowerHome || lowerTarget.hasPrefix(lowerHome + "/")
        if insideHome {
            let relative = String(lowerTarget.dropFirst(lowerHome.count)).drop(while: { $0 == "/" })
            if let first = relative.split(separator: "/").first, first.hasPrefix(".") {
                return .denied(reason: "hidden files and folders in the home directory (shell, ssh and tool configuration) are off limits")
            }
            return .needsApproval(outsideHome: false)
        }
        return .needsApproval(outsideHome: true)
    }

    /// How many dangling symlinks are followed before giving up on a chain.
    private static let maxSymlinkHops = 8

    /// Where a write to `url` would land, resolved the way the kernel resolves
    /// it — or `nil` when that cannot be told, in which case the caller refuses.
    ///
    /// The longest prefix that exists on disk is handed to `realpath(3)`, so
    /// symlinks and `..` are resolved physically and in the kernel's order. No
    /// lexical clean-up is done first: `~/Desktop/link/../x` with
    /// `link -> ~/.ssh/sub` is `~/.ssh/x`, not `~/Desktop/x`.
    ///
    /// A *dangling* symlink (`~/Desktop/key -> ~/.ssh/newkey`, target absent)
    /// is followed too, up to `maxSymlinkHops`: writing through it creates the
    /// file at its target, so the target is what must be judged. A relative
    /// target is joined onto the link's real parent. A chain still unresolved
    /// when the budget runs out (or a loop) returns `nil`, as does `..` after a
    /// component that does not exist (the kernel would not get there either).
    static func canonicalPath(_ url: URL, hops: Int = 0) -> String? {
        let components = url.absoluteURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Longest prefix that `lstat` can see (a dangling link counts).
        var split = components.count
        while split > 0, !entryExists("/" + components[..<split].joined(separator: "/")) {
            split -= 1
        }
        let prefix = "/" + components[..<split].joined(separator: "/")
        let remainder = components[split...].filter { $0 != "." }
        if remainder.contains("..") { return nil }

        let fileManager = FileManager.default
        if split > 0, !fileManager.fileExists(atPath: prefix),
           let destination = try? fileManager.destinationOfSymbolicLink(atPath: prefix) {
            guard hops < maxSymlinkHops else { return nil }
            let parent = "/" + components[..<(split - 1)].joined(separator: "/")
            guard let realParent = realPath(parent) else { return nil }
            let target = destination.hasPrefix("/") ? destination : realParent + "/" + destination
            let rest = remainder.isEmpty ? "" : "/" + remainder.joined(separator: "/")
            return canonicalPath(URL(fileURLWithPath: target + rest), hops: hops + 1)
        }
        guard let resolved = realPath(prefix) else { return nil }
        if remainder.isEmpty { return resolved }
        return (resolved == "/" ? "" : resolved) + "/" + remainder.joined(separator: "/")
    }

    private static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
