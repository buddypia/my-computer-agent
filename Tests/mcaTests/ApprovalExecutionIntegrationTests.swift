import Foundation
import MCACore
import MCAPresentation
import MCAReasoning
import Testing

private actor DispatchCounter {
    var count = 0
    func record() { count += 1 }
}

private struct RecordedApprovalTool: AgentTool {
    let counter: DispatchCounter
    var definition: ToolDefinition {
        ToolDefinition(name: "record_dispatch", description: "Record dispatch", parameters: Data("{}".utf8))
    }
    func invoke(arguments: Data) async throws -> String {
        await counter.record()
        return "dispatched"
    }
}

@Suite("Approval execution integration")
@MainActor
struct ApprovalExecutionIntegrationTests {
    private enum FixtureError: Error { case missingCard }

    private func waitForCard(_ state: HUDState) async throws -> ActionApprovalRequest {
        for _ in 0..<1_000 {
            if let card = state.messages.last?.approval { return card }
            await Task.yield()
        }
        throw FixtureError.missingCard
    }

    @Test("Only the displayed operation is written and each later write needs its own card")
    func exactWriteAndSecondApproval() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try "original".write(to: path, atomically: true, encoding: .utf8)
        let state = HUDState()
        let session = ActionAuthorization(goal: "Save meeting notes", requestApproval: { proposal in
            await state.requestApproval(proposal)
        })
        let registry = ToolRegistry(tools: [WriteFileTool()])
        let call = ToolCall(id: "first", name: "write_file", arguments: try JSONSerialization.data(
            withJSONObject: ["file_path": path.path, "content": "approved notes"]))
        let first = Task { await ActionAuthorization.withSession(session) { await registry.invoke(call) } }
        defer { first.cancel() }
        let card = try await waitForCard(state)
        #expect(card.goal == "Save meeting notes")
        #expect(card.details == "approved notes")
        #expect(try String(contentsOf: path, encoding: .utf8) == "original")
        state.resolveApproval(UUID(), status: .approved)
        #expect(state.isAwaitingApproval)
        state.resolveApproval(card.id, status: .approved)
        #expect(await first.value.content.contains("Successfully"))
        #expect(try String(contentsOf: path, encoding: .utf8) == "approved notes")

        let secondCall = ToolCall(id: "second", name: "write_file", arguments: try JSONSerialization.data(
            withJSONObject: ["file_path": path.path, "content": "unapproved notes"]))
        let second = Task { await ActionAuthorization.withSession(session) { await registry.invoke(secondCall) } }
        defer { second.cancel() }
        let next = try await waitForPendingCard(state)
        #expect(next.id != card.id)
        state.resolveApproval(card.id, status: .approved)
        #expect(state.isAwaitingApproval)
        state.resolveApproval(next.id, status: .rejected)
        #expect(await second.value.content.contains("rejected"))
        #expect(try String(contentsOf: path, encoding: .utf8) == "approved notes")
    }

    private func waitForPendingCard(_ state: HUDState) async throws -> ActionApprovalRequest {
        for _ in 0..<1_000 {
            if let message = state.messages.last, message.approvalStatus == .pending,
               let card = message.approval { return card }
            await Task.yield()
        }
        throw FixtureError.missingCard
    }

    @Test("Cancelling during the chat approval wait leaves the file unchanged")
    func cancellationWhileWaiting() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try "original".write(to: path, atomically: true, encoding: .utf8)
        let state = HUDState()
        let session = ActionAuthorization(goal: "Save notes", requestApproval: { proposal in
            await state.requestApproval(proposal)
        })
        let registry = ToolRegistry(tools: [WriteFileTool()])
        let call = ToolCall(id: "cancel", name: "write_file", arguments: try JSONSerialization.data(
            withJSONObject: ["file_path": path.path, "content": "must not be written"]))
        let task = Task { await ActionAuthorization.withSession(session) { await registry.invoke(call) } }
        defer { task.cancel() }
        let card = try await waitForCard(state)
        task.cancel()
        _ = await task.value
        state.resolveApproval(card.id, status: .approved)
        #expect(state.messages.last?.approvalStatus == .cancelled)
        #expect(!state.isAwaitingApproval)
        #expect(await session.terminalFailure != nil)
        #expect(try String(contentsOf: path, encoding: .utf8) == "original")
    }

    @Test("A cancelled task cannot enter another registered tool")
    func cancelledRegistryDispatch() async {
        let counter = DispatchCounter()
        let registry = ToolRegistry(tools: [RecordedApprovalTool(counter: counter)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await registry.invoke(ToolCall(id: "cancelled", name: "record_dispatch", arguments: Data("{}".utf8)))
        }
        let output = await task.value
        #expect(output.content.hasPrefix("Error:"))
        #expect(await counter.count == 0)
    }

    @Test("A rejected session cannot dispatch a later tool even through the registry directly")
    func deniedRegistryDispatch() async {
        let counter = DispatchCounter()
        let registry = ToolRegistry(tools: [RecordedApprovalTool(counter: counter)])
        let session = ActionAuthorization(goal: "Save notes", requestApproval: { _ in .rejected })
        let output = await ActionAuthorization.withSession(session) {
            do {
                try await ActionAuthorization.requireApproval(operation: "Write", target: "notes", details: "new notes")
            } catch {}
            return await registry.invoke(ToolCall(id: "after-denial", name: "record_dispatch", arguments: Data("{}".utf8)))
        }
        #expect(output.content.hasPrefix("Error:"))
        #expect(await counter.count == 0)
    }
}
