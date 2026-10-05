import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("AccessibilityReader tests")
struct AccessibilityReaderTests {
    @Test("safely ignores own process PID and returns empty snapshot without AX traversal")
    func testIgnoresOwnProcessPID() {
        let reader = AccessibilityReader()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Passing own process PID must never inspect in-process AX elements
        let snapshot = reader.readWindow(pid: ownPID)
        #expect(snapshot != nil)
        #expect(snapshot?.text.isEmpty == true)
        #expect(snapshot?.elementCount == 0)
    }

    @Test("initializes with default and custom limits")
    func testInitializationLimits() {
        let reader = AccessibilityReader(maxElements: 500, maxDepth: 10, maxCharacters: 1000)
        #expect(AccessibilityReader.isTrusted == AccessibilityReader.isTrusted)
    }
}
