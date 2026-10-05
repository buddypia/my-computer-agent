import Darwin
import Foundation
import MCACore
import MCAReasoning
import Testing

@Suite("Approved file writes")
struct ApprovedFileWriteTests {
    @Test("Replacing the parent directory invalidates creation approval")
    func changedParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("approved"), other = root.appendingPathComponent("other")
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let session = ActionAuthorization(goal: "Save report", requestApproval: { _ in
            await calls.record()
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: other)
            return .approved
        })
        let output = try await ActionAuthorization.$current.withValue(session) {
            try await WriteFileTool().invoke(arguments: arguments(parent.appendingPathComponent("report.txt")))
        }
        #expect(output.contains("changed"))
        #expect(await calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("report.txt").path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("report.txt").path))
    }
    @Test("An absent caller-selected path cannot bypass approval")
    func newPathRequiresApproval() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await WriteFileTool().invoke(arguments: arguments(url))
        #expect(output.contains("approval_required"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    private actor Calls {
        var count = 0
        func record() { count += 1 }
    }

    private func arguments(_ path: URL) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["file_path": path.path, "content": "new notes"])
    }

    @Test("An existing file is unchanged without a presenter")
    func noPresenter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await WriteFileTool().invoke(arguments: arguments(url))
        #expect(output.contains("approval_required"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    @Test("Approval authorizes the concrete overwrite")
    func approvedWrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = Calls()
        let session = ActionAuthorization(goal: "Update notes", requestApproval: { request in
            await calls.record()
            let resolved = try #require(realpath(url.path, nil))
            defer { free(resolved) }
            #expect(request.target == String(cString: resolved))
            #expect(request.details.contains("new notes"))
            return .approved
        })
        let output = try await ActionAuthorization.$current.withValue(session) {
            try await WriteFileTool().invoke(arguments: arguments(url))
        }
        #expect(await calls.count == 1)
        #expect(output.contains("Successfully"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new notes")
    }

    @Test("Changed file contents invalidate an approval")
    func staleContents() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ActionAuthorization(goal: "Update notes", requestApproval: { _ in
            try "changed by user".write(to: url, atomically: true, encoding: .utf8)
            return .approved
        })
        let output = try await ActionAuthorization.$current.withValue(session) {
            try await WriteFileTool().invoke(arguments: arguments(url))
        }
        #expect(output.contains("changed"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed by user")
    }

    @Test("Hard-linked files are refused so approval cannot change another path")
    func hardLink() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = url.appendingPathExtension("link")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.linkItem(at: url, to: other)
        let session = ActionAuthorization(goal: "Update notes", requestApproval: { _ in .approved })
        let output = try await ActionAuthorization.$current.withValue(session) {
            try await WriteFileTool().invoke(arguments: arguments(url))
        }
        #expect(output.contains("Error"))
        #expect(try String(contentsOf: other, encoding: .utf8) == "original")
    }

    @Test("A FIFO is refused without waiting for a writer")
    func fifo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(mkfifo(url.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await WriteFileTool().invoke(arguments: arguments(url))
        #expect(output.contains("Error"))
    }

    @Test("A new task output can be created without overwriting anything")
    func newOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = ActionAuthorization(goal: "Save notes", requestApproval: { _ in .approved })
        let output = try await ActionAuthorization.$current.withValue(session) {
            try await WriteFileTool().invoke(arguments: arguments(url))
        }
        #expect(output.contains("Successfully"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new notes")
    }
}
