import Foundation
import Testing

/// `.isolatedMeasurement` skips a test in the parallel run, and the gate's isolated
/// pass finds it by the `…Isolated()` name. A test with one and not the other runs
/// nowhere, or runs in the parallel pass it was meant to leave — both silently.
@Suite("Isolated measurement convention")
struct IsolatedMeasurementConventionTests {
    @Test("the trait and the Isolated() suffix always appear together")
    func traitAndSuffixAgree() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let declaration = try Regex(#"@Test\(([^\n]*)\)\s*(?:@\w+\s*)*func (\w+)\("#)
        var isolated = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: declaration) {
                let arguments = String(try #require(match.output[1].substring))
                let name = String(try #require(match.output[2].substring))
                let hasTrait = arguments.contains(".isolatedMeasurement")
                let hasSuffix = name.hasSuffix("Isolated")
                #expect(hasTrait == hasSuffix, "\(file.lastPathComponent): \(name)")
                if hasTrait { isolated += 1 }
            }
        }
        // The scan has to see the tests it guards, or a moved Tests/ passes it vacuously.
        #expect(isolated >= 10)
    }
}
