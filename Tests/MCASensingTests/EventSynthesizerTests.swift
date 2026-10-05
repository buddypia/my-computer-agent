import CoreGraphics
import Foundation
import Testing
@testable import MCASensing

@Suite("EventSynthesizer tests")
struct EventSynthesizerTests {
    let synthesizer = EventSynthesizer()

    @Test("Background scroll validation binds the addressed PID without requiring foreground focus")
    func backgroundScrollScope() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try EventSynthesizer.$expectedTargetPID.withValue(pid) {
            try synthesizer.validateProcessScrollTarget(pid: pid, at: CGPoint(x: 100, y: 100))
            #expect(throws: EventSynthesizer.SynthesizerError.self) {
                try synthesizer.validateProcessScrollTarget(pid: pid + 100_000, at: CGPoint(x: 100, y: 100))
            }
        }
    }

    @Test("Scoped coordinates cannot escape an unavailable selected window")
    func selectedWindowBounds() throws {
        try EventSynthesizer.$expectedTargetWindowID.withValue(UInt32.max) {
            #expect(throws: EventSynthesizer.SynthesizerError.self) {
                try synthesizer.validateCoordinate(CGPoint(x: 100, y: 100))
            }
        }
    }

    @Test("KeyCodeMap parses standard special keys correctly")
    func testSpecialKeyMapping() {
        #expect(KeyCodeMap.lookup("return") != nil)
        #expect(KeyCodeMap.lookup("enter") != nil)
        #expect(KeyCodeMap.lookup("tab") != nil)
        #expect(KeyCodeMap.lookup("space") != nil)
        #expect(KeyCodeMap.lookup("escape") != nil)
        #expect(KeyCodeMap.lookup("esc") != nil)
        #expect(KeyCodeMap.lookup("backspace") != nil)
        #expect(KeyCodeMap.lookup("left") != nil)
        #expect(KeyCodeMap.lookup("right") != nil)
        #expect(KeyCodeMap.lookup("up") != nil)
        #expect(KeyCodeMap.lookup("down") != nil)
    }

    @Test("KeyCodeMap parses characters and digits")
    func testCharacterKeyMapping() {
        #expect(KeyCodeMap.lookup("a") != nil)
        #expect(KeyCodeMap.lookup("z") != nil)
        #expect(KeyCodeMap.lookup("0") != nil)
        #expect(KeyCodeMap.lookup("9") != nil)
        #expect(KeyCodeMap.lookup("A") != nil) // case insensitive
    }

    @Test("parseKeyChord handles single keys and modifiers")
    func testKeyChordParsing() throws {
        let (codeReturn, flagsReturn) = try synthesizer.parseKeyChord("Return")
        #expect(flagsReturn.isEmpty)
        #expect(codeReturn == KeyCodeMap.lookup("return"))

        let (codeC, flagsCmdC) = try synthesizer.parseKeyChord("cmd+c")
        #expect(flagsCmdC.contains(.maskCommand))
        #expect(codeC == KeyCodeMap.lookup("c"))

        let (codeV, flagsMulti) = try synthesizer.parseKeyChord("cmd+shift+option+v")
        #expect(flagsMulti.contains(.maskCommand))
        #expect(flagsMulti.contains(.maskShift))
        #expect(flagsMulti.contains(.maskAlternate))
        #expect(codeV == KeyCodeMap.lookup("v"))
    }

    @Test("parseKeyChord throws for invalid keys")
    func testInvalidKeyChord() {
        #expect(throws: EventSynthesizer.SynthesizerError.self) {
            try synthesizer.parseKeyChord("invalid_super_fake_key_name")
        }

        #expect(throws: EventSynthesizer.SynthesizerError.self) {
            try synthesizer.parseKeyChord("")
        }
    }

    @Test("Text length limit is enforced")
    func testInputTooLong() {
        let excessiveText = String(repeating: "A", count: 5001)
        #expect(throws: EventSynthesizer.SynthesizerError.self) {
            try synthesizer.typeText(excessiveText)
        }
    }

    @Test("scrollProcess validates target coordinate or ensures permission")
    func testScrollProcessCoordinateValidation() {
        // With Accessibility trust the event is posted instead of rejected; only the
        // untrusted path is deterministic.
        guard !synthesizer.isTrusted else { return }
        #expect(throws: EventSynthesizer.SynthesizerError.self) {
            try synthesizer.scrollProcess(pid: 1234, at: CGPoint(x: -1e12, y: -1e12), deltaX: 0, deltaY: -5)
        }
    }

    @Test("Background scroll refuses invalid coordinates before any event", arguments: [
        CGPoint(x: CGFloat.nan, y: 100), CGPoint(x: 100, y: CGFloat.infinity), CGPoint(x: -1e12, y: -1e12)
    ])
    func backgroundScrollInvalidCoordinates(_ point: CGPoint) {
        #expect(throws: EventSynthesizer.SynthesizerError.self) {
            try synthesizer.validateProcessScrollTarget(pid: ProcessInfo.processInfo.processIdentifier, at: point)
        }
    }

    @Test("clampedCoordinate ensures safe point within display bounds")
    func testClampedCoordinate() {
        let point = CGPoint(x: 100, y: 100)
        let clamped = synthesizer.clampedCoordinate(point)
        #expect(clamped.x != 0 || clamped.y != 0)
    }
}
