import CoreGraphics
import Foundation
import MCACore
import Testing

@Suite("ComputerActionDecision Tests")
struct ComputerActionDecisionTests {
    
    @Test("ActionType raw values and synonym resolution")
    func actionTypeRawValuesAndSynonyms() {
        // Canonical raw values
        #expect(ComputerActionDecision.ActionType.scroll.rawValue == "scroll")
        #expect(ComputerActionDecision.ActionType.keyPress.rawValue == "key")
        #expect(ComputerActionDecision.ActionType.click.rawValue == "click")
        #expect(ComputerActionDecision.ActionType.doubleClick.rawValue == "double_click")
        #expect(ComputerActionDecision.ActionType.rightClick.rawValue == "right_click")
        #expect(ComputerActionDecision.ActionType.typeText.rawValue == "type")
        #expect(ComputerActionDecision.ActionType.wait.rawValue == "wait")
        #expect(ComputerActionDecision.ActionType.none.rawValue == "none")

        // Lenient synonym decoding
        #expect(ComputerActionDecision.ActionType(rawValue: "keyPress") == .keyPress)
        #expect(ComputerActionDecision.ActionType(rawValue: "keypress") == .keyPress)
        #expect(ComputerActionDecision.ActionType(rawValue: "key_press") == .keyPress)
        #expect(ComputerActionDecision.ActionType(rawValue: "KEY") == .keyPress)
        #expect(ComputerActionDecision.ActionType(rawValue: "doubleclick") == .doubleClick)
        #expect(ComputerActionDecision.ActionType(rawValue: "type_text") == .typeText)
        #expect(ComputerActionDecision.ActionType(rawValue: "invalid_action") == nil)
    }

    @Test("Scroll decision initialization and Codable roundtrip")
    func scrollDecisionCodableRoundtrip() throws {
        let scrollDecision = ComputerActionDecision(
            action: .scroll,
            confidence: 0.95,
            coordinates: CGPoint(x: 500, y: 300),
            scrollDelta: CGVector(dx: 0, dy: -120),
            reasoning: "Scroll down to locate submit button"
        )

        #expect(scrollDecision.action == .scroll)
        #expect(scrollDecision.scrollDelta == CGVector(dx: 0, dy: -120))
        #expect(scrollDecision.coordinates == CGPoint(x: 500, y: 300))
        #expect(scrollDecision.targetCenter == CGPoint(x: 500, y: 300))
        #expect(scrollDecision.reasoning == "Scroll down to locate submit button")

        let encoder = JSONEncoder()
        let data = try encoder.encode(scrollDecision)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: data)

        #expect(decoded == scrollDecision)
        #expect(decoded.scrollDelta?.dx == 0)
        #expect(decoded.scrollDelta?.dy == -120)
        #expect(decoded.coordinates == CGPoint(x: 500, y: 300))
    }

    @Test("KeyPress decision initialization and Codable roundtrip")
    func keyPressDecisionCodableRoundtrip() throws {
        let keyDecision = ComputerActionDecision(
            action: .keyPress,
            confidence: 0.98,
            keyCombination: ["command", "shift", "p"],
            reasoning: "Open Quick Open palette"
        )

        #expect(keyDecision.action == .keyPress)
        #expect(keyDecision.keyCombination == ["command", "shift", "p"])
        #expect(keyDecision.targetCenter == nil)
        #expect(keyDecision.scrollDelta == nil)

        let encoder = JSONEncoder()
        let data = try encoder.encode(keyDecision)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: data)

        #expect(decoded == keyDecision)
        #expect(decoded.keyCombination == ["command", "shift", "p"])
    }

    @Test("Backward compatibility decoding legacy JSON format")
    func legacyJSONDecoding() throws {
        let legacyJson = """
        {
            "targetElementId": "btn_submit",
            "action": "click",
            "confidence": 0.88,
            "isCompleted": false,
            "targetCenter": [120, 240]
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(legacyJson.utf8))

        #expect(decoded.targetElementId == "btn_submit")
        #expect(decoded.action == .click)
        #expect(decoded.confidence == 0.88)
        #expect(!decoded.isCompleted)
        #expect(decoded.targetCenter == CGPoint(x: 120, y: 240))
        #expect(decoded.coordinates == CGPoint(x: 120, y: 240))
        #expect(decoded.scrollDelta == nil)
        #expect(decoded.keyCombination == nil)
    }

    @Test("Modern JSON decoding using coordinates key")
    func modernJSONDecodingWithCoordinates() throws {
        let modernJson = """
        {
            "action": "scroll",
            "coordinates": [400, 600],
            "scrollDelta": [15, -45],
            "confidence": 0.92
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(modernJson.utf8))

        #expect(decoded.action == .scroll)
        #expect(decoded.coordinates == CGPoint(x: 400, y: 600))
        #expect(decoded.targetCenter == CGPoint(x: 400, y: 600))
        #expect(decoded.scrollDelta == CGVector(dx: 15, dy: -45))
        #expect(decoded.confidence == 0.92)
        #expect(!decoded.isCompleted)
    }

    @Test("Minimal JSON decoding fallback values")
    func minimalJSONDecoding() throws {
        let minJson = """
        {
            "action": "wait"
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(minJson.utf8))

        #expect(decoded.action == .wait)
        #expect(decoded.confidence == 1.0)
        #expect(!decoded.isCompleted)
        #expect(decoded.targetElementId == nil)
        #expect(decoded.coordinates == nil)
        #expect(decoded.scrollDelta == nil)
        #expect(decoded.keyCombination == nil)
    }

    @Test("Dual-key emission in JSON encoding")
    func dualKeyEmissionInEncoding() throws {
        let decision = ComputerActionDecision(
            action: .click,
            coordinates: CGPoint(x: 320, y: 480)
        )
        let data = try JSONEncoder().encode(decision)
        let jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(jsonDict != nil)
        #expect(jsonDict?["targetCenter"] != nil)
        #expect(jsonDict?["coordinates"] != nil)
    }

    @Test("Equality and inequality comparisons")
    func equalityComparisons() {
        let a = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: 50))
        let b = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: 50))
        let c = ComputerActionDecision(action: .scroll, scrollDelta: CGVector(dx: 0, dy: -50))
        let d = ComputerActionDecision(action: .keyPress, keyCombination: ["return"])

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}
