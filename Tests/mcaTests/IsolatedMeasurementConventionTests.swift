import Foundation
import Testing

/// `.isolatedMeasurement` skips a test in the parallel run, and the gate's isolated
/// pass finds it by the `…Isolated(` name. A test with one and not the other runs
/// nowhere, or runs in the parallel pass it was meant to leave — both silently.
@Suite("Isolated measurement convention")
struct IsolatedMeasurementConventionTests {
    private static let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles() throws -> [URL] {
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("the trait and the Isolated suffix always appear together")
    func traitAndSuffixAgree() throws {
        // Everything from one `@Test` to the first `func` after it is that test's
        // attribute, however many lines it spans or whatever modifiers precede `func`.
        let function = try Regex(#"\bfunc\s+(\w+)\s*\("#)
        var isolated = 0
        for file in try Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for chunk in text.components(separatedBy: "@Test").dropFirst() {
                guard let match = chunk.firstMatch(of: function),
                      let name = match.output[1].substring
                else { continue }
                let hasTrait = chunk[..<match.range.lowerBound].contains(".isolatedMeasurement")
                let hasSuffix = name.hasSuffix("Isolated")
                #expect(hasTrait == hasSuffix, "\(file.lastPathComponent): \(name)")
                if hasTrait { isolated += 1 }
            }
        }
        // The scan has to see the tests it guards, or a moved Tests/ passes it vacuously.
        #expect(isolated >= 11)
    }

    @Test("every test target's copy of the trait is the same")
    func traitCopiesMatch() throws {
        let copies = try Self.swiftFiles().filter { $0.lastPathComponent == "IsolatedMeasurement.swift" }
        #expect(copies.count >= 3)
        let texts = Set(try copies.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(texts.count == 1, "\(copies.map(\.path))")
    }
}
