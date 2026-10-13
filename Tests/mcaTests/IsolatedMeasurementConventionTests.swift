import Foundation
import Testing

/// A process-wide number asserted behind `IsolatedTiming.enabled` is only checked by the gate's isolated
/// stage, which finds its test by the `…Isolated` name and switches the numbers on by environment. A test
/// with the switch and not the name has assertions that run nowhere; a stage that sets a different
/// variable than the switch reads has the same result for every test at once (main after #20 and #21).
///
/// The suite and function names predate the switch (they once checked a trait); they are kept because
/// trust's executed_tests reads a rename as a test that stopped running.
@Suite("Isolated timing convention")
struct IsolatedMeasurementConventionTests {
    private static let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles() throws -> [URL] {
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("the switch and the Isolated suffix always appear together")
    func traitAndSuffixAgree() throws {
        // A test's text runs from its `@Test` to the next one: the attribute, however many lines, any
        // modifiers before `func`, and the body where the switch is read. Same name pattern as the gate.
        let function = try Regex(#"\bfunc\s+(\w+)\s*\("#)
        var isolated = 0
        for file in try Self.swiftFiles()
        where !["IsolatedTiming.swift", "IsolatedMeasurementConventionTests.swift"].contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for chunk in text.components(separatedBy: "@Test").dropFirst() {
                guard let match = chunk.firstMatch(of: function),
                      let name = match.output[1].substring
                else { continue }
                let readsSwitch = chunk.contains("IsolatedTiming.enabled")
                let hasSuffix = name.hasSuffix("Isolated")
                #expect(readsSwitch == hasSuffix, "\(file.lastPathComponent): \(name)")
                if readsSwitch { isolated += 1 }
            }
        }
        // The scan has to see the tests it guards, or a moved Tests/ passes it vacuously.
        #expect(isolated >= 11)
    }

    @Test("every copy of the switch reads the variable the gate's isolated stage sets")
    func traitCopiesMatch() throws {
        let copies = try Self.swiftFiles().filter { $0.lastPathComponent == "IsolatedTiming.swift" }
        #expect(copies.count >= 3)
        let texts = Set(try copies.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(texts.count == 1, "\(copies.map(\.path))")
        #expect(texts.allSatisfy { $0.contains(#"environment["MCA_ISOLATED_TIMING"] == "1""#) })

        let gate = Self.tests.deletingLastPathComponent().appendingPathComponent("Scripts/gate.sh")
        let script = try String(contentsOf: gate, encoding: .utf8)
        #expect(script.contains("MCA_ISOLATED_TIMING=1 swift test"), "the isolated stage must switch the numbers on")
    }
}
