import Foundation
import Testing

/// A process-wide number asserted behind `IsolatedTiming.enabled` is only checked by the gate's isolated
/// stage, which finds its test by the `…Isolated` name. A test with the switch and not the name has
/// assertions that run nowhere; a test with the name and not the switch runs twice for nothing.
@Suite("Isolated timing convention")
struct IsolatedTimingConventionTests {
    private static let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles() throws -> [URL] {
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("the switch and the Isolated suffix always appear together")
    func switchAndSuffixAgree() throws {
        // A test's text runs from its `@Test` to the next one: the attribute, however many lines, any
        // modifiers before `func`, and the body where the switch is read.
        let function = try Regex(#"\bfunc\s+(\w+)\s*[<(]"#)
        var isolated = 0
        for file in try Self.swiftFiles() where file.lastPathComponent != "IsolatedTiming.swift" {
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

    @Test("every test target's copy of the switch is the same")
    func switchCopiesMatch() throws {
        let copies = try Self.swiftFiles().filter { $0.lastPathComponent == "IsolatedTiming.swift" }
        #expect(copies.count >= 3)
        let texts = Set(try copies.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(texts.count == 1, "\(copies.map(\.path))")
    }
}
