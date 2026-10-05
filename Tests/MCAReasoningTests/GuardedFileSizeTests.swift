import Foundation
import Testing
@testable import MCAReasoning

@Suite("Bounded existing file snapshots")
struct GuardedFileSizeTests {
    private func file(size: UInt64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("notes.txt")
        try Data("original".utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        return file
    }
    private struct GrowingApprover: ToolApproving {
        let target: URL
        let size: UInt64
        func decide(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
            do {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.truncate(atOffset: size)
                return .approved
            } catch { return .denied(reason: error.localizedDescription) }
        }
    }
    @Test("A destination growing beyond the bound during approval remains unmodified")
    func growsDuringApproval() async throws {
        let target = try file(size: 8), size = UInt64(GuardedFileWriter.maxSnapshotBytes + 1)
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let result = try await WriteFileTool(approver: GrowingApprover(target: target, size: size)).invoke(arguments:
            JSONSerialization.data(withJSONObject: ["file_path": target.path, "content": "replacement"]))
        #expect(result.contains("too large"))
        #expect(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size))
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 8) == Data("original".utf8))
    }

    @Test("An oversized destination is refused before approval and is never modified")
    func oversizedBeforeApproval() async throws {
        let size: UInt64 = 8 * 1024 * 1024 + 1
        let target = try file(size: size), approver = RecordingApprover.denying()
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let result = try await WriteFileTool(approver: approver).invoke(arguments:
            JSONSerialization.data(withJSONObject: ["file_path": target.path, "content": "replacement"]))
        #expect(result.contains("too large"))
        #expect(approver.requests.isEmpty)
        #expect(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size))
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 8) == Data("original".utf8))
    }
}
