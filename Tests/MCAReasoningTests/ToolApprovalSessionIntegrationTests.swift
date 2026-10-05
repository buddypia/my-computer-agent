import Foundation
import MCACore
import MCASensing
@testable import MCAReasoning
import Testing

private enum ScreenshotRace: CaseIterable, Sendable { case absent, existing, parentReplacement, missingParentInsertion }

private struct CallbackToolApprover: ToolApproving {
    let body: @Sendable (ToolApprovalRequest) async -> ToolApprovalDecision
    func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision { await body(request) }
}

@Suite("Legacy and chat approval integration")
struct ToolApprovalSessionIntegrationTests {
    private actor Counter { var count = 0; func add() { count += 1 } }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func arguments(_ url: URL) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["file_path": url.path, "content": "approved content"])
    }

    @Test("Chat approval is used once without a second legacy prompt")
    func chatApproval() async throws {
        let root = try directory(), calls = Counter(), legacy = RecordingApprover.denying()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("notes.txt")
        let session = ActionAuthorization(goal: "Save notes", requestApproval: { request in
            #expect(request.details == "approved content")
            await calls.add(); return .approved
        })
        let output = try await ActionAuthorization.withSession(session) {
            try await WriteFileTool(approver: legacy, home: root).invoke(arguments: arguments(target))
        }
        #expect(output.contains("Successfully wrote"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "approved content")
        #expect(await calls.count == 1)
        #expect(legacy.requests.isEmpty)
    }

    @Test("A chat session cannot bypass persistence-path refusal")
    func blockedPath() async throws {
        let root = try directory(), calls = Counter()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(".zshrc")
        let session = ActionAuthorization(goal: "Save notes", requestApproval: { _ in await calls.add(); return .approved })
        let output = try await ActionAuthorization.withSession(session) {
            try await WriteFileTool(home: root).invoke(arguments: arguments(target))
        }
        #expect(output.contains("is not allowed"))
        #expect(await calls.count == 0)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("A directory inserted during legacy approval cannot redirect a pending creation")
    func legacyInsertedDirectory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Documents"), target = parent.appendingPathComponent("notes.txt")
        let legacy = CallbackToolApprover(body: { _ in
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try Data("external edit".utf8).write(to: target)
                return .approved
            } catch { Issue.record(error); return .denied(reason: "fixture write failed") }
        })
        let output = try await WriteFileTool(approver: legacy, home: root).invoke(arguments: arguments(target))
        #expect(!output.contains("Successfully"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "external edit")
    }

    @Test("A registry screenshot write rejects changes during legacy approval", arguments: ScreenshotRace.allCases)
    fileprivate func screenshotRace(_ race: ScreenshotRace) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Documents"), target = parent.appendingPathComponent("shot.png")
        let moved = root.appendingPathComponent("moved"), sensitive = root.appendingPathComponent(".ssh")
        if race != .missingParentInsertion { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        if race == .existing || race == .parentReplacement { try Data("original".utf8).write(to: target) }
        let legacy = CallbackToolApprover(body: { _ in
            do {
                if race == .parentReplacement {
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.createDirectory(at: sensitive, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: sensitive)
                } else {
                    if race == .missingParentInsertion { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
                    try Data("external edit".utf8).write(to: target)
                }
                return .approved
            } catch { Issue.record(error); return .denied(reason: "fixture mutation failed") }
        })
        let session = BrowserSession(drivers: [FakeBrowserDriver(outlines: [""], refs: [[:]])], inference: nil)
        let registry = ToolRegistry(tools: [BrowserReadTool(session: session, approver: legacy, home: root)])
        let call = ToolCall(id: UUID().uuidString, name: "browser_read", arguments:
            try JSONSerialization.data(withJSONObject: ["what": "screenshot", "path": target.path]))
        let output = await registry.invoke(call)
        #expect(!output.content.contains("Saved screenshot"))
        if race == .parentReplacement {
            #expect(!FileManager.default.fileExists(atPath: sensitive.appendingPathComponent("shot.png").path))
            #expect(try String(contentsOf: moved.appendingPathComponent("shot.png"), encoding: .utf8) == "original")
        } else { #expect(try Data(contentsOf: target) == Data("external edit".utf8)) }
    }

    @Test("A legacy approval rejects a file created or changed while approval is pending", arguments: [false, true])
    func legacyChangedFile(_ initiallyExists: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("notes.txt")
        if initiallyExists { try Data("original".utf8).write(to: target) }
        let legacy = CallbackToolApprover(body: { _ in
            do { try Data("external edit".utf8).write(to: target); return .approved }
            catch { Issue.record(error); return .denied(reason: "fixture write failed") }
        })
        let output = try await WriteFileTool(approver: legacy, home: root).invoke(arguments: arguments(target))
        #expect(!output.contains("Successfully"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "external edit")
    }
}
