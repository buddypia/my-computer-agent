import CoreGraphics
import Foundation
import MCACore
import Testing

@Suite("Adversarial M1 Stress Tests: ComputerActionDecision & UIElementCandidate")
struct AdversarialM1Tests {

    // MARK: - 1. ActionType Exotic Casing & Weird Synonyms

    @Test("ActionType accepts exotic casing for standard and synonym raw values")
    func actionTypeExoticCasing() {
        let testCases: [(input: String, expected: ComputerActionDecision.ActionType)] = [
            // Standard types with random/extreme casing
            ("CLICK", .click),
            ("cLiCk", .click),
            ("Click", .click),
            ("SCROLL", .scroll),
            ("ScRoLl", .scroll),
            ("sCrOlL", .scroll),
            ("WAIT", .wait),
            ("Wait", .wait),
            ("wAiT", .wait),
            ("NONE", .none),
            ("None", .none),
            ("nOnE", .none),

            // Synonyms with various casing
            ("DOUBLE_CLICK", .doubleClick),
            ("DoubleClick", .doubleClick),
            ("doubleClick", .doubleClick),
            ("DOUBLECLICK", .doubleClick),
            ("dOuBlE_cLiCk", .doubleClick),

            ("RIGHT_CLICK", .rightClick),
            ("RightClick", .rightClick),
            ("rightClick", .rightClick),
            ("RIGHTCLICK", .rightClick),
            ("rIgHt_cLiCk", .rightClick),

            ("TYPE", .typeText),
            ("Type", .typeText),
            ("TYPETEXT", .typeText),
            ("typeText", .typeText),
            ("TypeText", .typeText),
            ("TYPE_TEXT", .typeText),
            ("type_text", .typeText),

            ("KEY", .keyPress),
            ("Key", .keyPress),
            ("KEYPRESS", .keyPress),
            ("keyPress", .keyPress),
            ("KeyPress", .keyPress),
            ("KEY_PRESS", .keyPress),
            ("key_press", .keyPress),
        ]

        for tc in testCases {
            let parsed = ComputerActionDecision.ActionType(rawValue: tc.input)
            #expect(parsed == tc.expected, "Failed to resolve exotic casing '\(tc.input)' to expected \(tc.expected)")
        }
    }

    @Test("ActionType rejects invalid, garbage, or unsupported synonyms")
    func actionTypeRejectsInvalidStrings() {
        let invalidInputs = [
            "",
            "   ",
            "123",
            "null",
            "undefined",
            "hover",
            "drag",
            "mouse_move",
            "left_click",
            "pressKey",
            "press_key",
            "key-press",
            "double-click",
            "right-click",
            "type-text",
            "scroll_down",
            "scroll_up",
            "click ",       // un-trimmed whitespace
            " scroll",      // un-trimmed whitespace
            "\tkey\n",      // un-trimmed tabs/newlines
            "SELECT * FROM actions",
            "🍎",
        ]

        for input in invalidInputs {
            let parsed = ComputerActionDecision.ActionType(rawValue: input)
            #expect(parsed == nil, "Input '\(input)' should not parse to an ActionType, but got \(String(describing: parsed))")
        }
    }

    // MARK: - 2. Dual-Key JSON Decoding Collisions (coordinates vs targetCenter)

    @Test("JSON collision: coordinates takes precedence over targetCenter when both present")
    func jsonCollisionPrecedenceModernOverLegacy() throws {
        let collisionJson = """
        {
            "action": "click",
            "coordinates": [100.5, 200.5],
            "targetCenter": [999.0, 888.0],
            "confidence": 0.99
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(collisionJson.utf8))

        #expect(decoded.action == .click)
        #expect(decoded.coordinates == CGPoint(x: 100.5, y: 200.5))
        #expect(decoded.targetCenter == CGPoint(x: 100.5, y: 200.5))
    }

    @Test("JSON collision: coordinates is null falls back to targetCenter")
    func jsonCollisionCoordinatesNullFallsBackToTargetCenter() throws {
        let json = """
        {
            "action": "click",
            "coordinates": null,
            "targetCenter": [350.0, 700.0]
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(json.utf8))

        #expect(decoded.coordinates == CGPoint(x: 350.0, y: 700.0))
        #expect(decoded.targetCenter == CGPoint(x: 350.0, y: 700.0))
    }

    @Test("JSON collision: targetCenter is null respects coordinates")
    func jsonCollisionTargetCenterNullRespectsCoordinates() throws {
        let json = """
        {
            "action": "scroll",
            "coordinates": [450.0, 550.0],
            "targetCenter": null
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(json.utf8))

        #expect(decoded.coordinates == CGPoint(x: 450.0, y: 550.0))
        #expect(decoded.targetCenter == CGPoint(x: 450.0, y: 550.0))
    }

    @Test("JSON collision: both coordinates and targetCenter null results in nil")
    func jsonCollisionBothNullResultsInNil() throws {
        let json = """
        {
            "action": "key",
            "coordinates": null,
            "targetCenter": null
        }
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ComputerActionDecision.self, from: Data(json.utf8))

        #expect(decoded.coordinates == nil)
        #expect(decoded.targetCenter == nil)
    }

    @Test("Initializer precedence: coordinates parameter takes precedence over targetCenter")
    func initPrecedenceCoordinatesOverTargetCenter() {
        let modernCoord = CGPoint(x: 111, y: 222)
        let legacyCoord = CGPoint(x: 333, y: 444)

        let decision = ComputerActionDecision(
            action: .click,
            targetCenter: legacyCoord,
            coordinates: modernCoord
        )

        #expect(decision.coordinates == modernCoord)
        #expect(decision.targetCenter == modernCoord)
    }

    @Test("Encoder emits both coordinates and targetCenter for interoperability")
    func encoderDualKeyEmissionAndReDecode() throws {
        let original = ComputerActionDecision(
            action: .doubleClick,
            coordinates: CGPoint(x: 640, y: 480),
            reasoning: "Test dual-key output"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(jsonObject != nil)
        #expect(jsonObject?["coordinates"] != nil)
        #expect(jsonObject?["targetCenter"] != nil)

        let decoder = JSONDecoder()
        let reDecoded = try decoder.decode(ComputerActionDecision.self, from: data)

        #expect(reDecoded == original)
        #expect(reDecoded.coordinates == CGPoint(x: 640, y: 480))
        #expect(reDecoded.targetCenter == CGPoint(x: 640, y: 480))
    }

    // MARK: - 3. Extreme, Negative & Floating Point Vectors

    @Test("Negative coordinates for multi-display setups (secondary monitor)")
    func negativeCoordinatesMultiDisplay() throws {
        // Multi-monitor: secondary monitor located to the left or top has negative screen coords
        let secondaryMonitorCoord = CGPoint(x: -1920, y: -1080)
        let decision = ComputerActionDecision(
            action: .click,
            coordinates: secondaryMonitorCoord
        )

        #expect(decision.coordinates?.x == -1920)
        #expect(decision.coordinates?.y == -1080)

        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(ComputerActionDecision.self, from: data)

        #expect(decoded.coordinates == secondaryMonitorCoord)
        #expect(decoded.targetCenter == secondaryMonitorCoord)
    }

    @Test("Extreme coordinate values and high precision floating point")
    func extremeAndHighPrecisionCoordinates() throws {
        let extremeCoord = CGPoint(x: 999_999.87654321, y: -888_888.12345678)
        let decision = ComputerActionDecision(
            action: .click,
            coordinates: extremeCoord
        )

        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(ComputerActionDecision.self, from: data)

        #expect(decoded.coordinates?.x == extremeCoord.x)
        #expect(decoded.coordinates?.y == extremeCoord.y)
    }

    @Test("Negative and zero scroll deltas (natural vs inverted scrolling)")
    func scrollDeltaPolarityAndMagnitudes() throws {
        let testVectors: [CGVector] = [
            CGVector(dx: 0, dy: -500),         // Standard scroll down
            CGVector(dx: 0, dy: 500),          // Standard scroll up
            CGVector(dx: -250, dy: 0),         // Horizontal scroll left
            CGVector(dx: 250, dy: 0),          // Horizontal scroll right
            CGVector(dx: -150.5, dy: -320.25), // Diagonal negative scroll
            CGVector(dx: 0, dy: 0),            // Zero scroll delta
            CGVector(dx: 1_000_000, dy: -1_000_000), // Extreme magnitude
        ]

        for vec in testVectors {
            let decision = ComputerActionDecision(
                action: .scroll,
                scrollDelta: vec
            )

            #expect(decision.scrollDelta == vec)

            let data = try JSONEncoder().encode(decision)
            let decoded = try JSONDecoder().decode(ComputerActionDecision.self, from: data)

            #expect(decoded.scrollDelta == vec)
        }
    }

    @Test("NaN and Infinite float behavior: JSONEncoder rejects non-conforming floats unless configured")
    func nanAndInfinityRejectionInStandardJSON() {
        let nanCoord = CGPoint(x: Double.nan, y: 100.0)
        let nanDecision = ComputerActionDecision(
            action: .click,
            coordinates: nanCoord
        )

        let encoder = JSONEncoder()
        // Standard JSONEncoder should throw EncodingError when encountering NaN without strategy
        #expect(throws: EncodingError.self) {
            _ = try encoder.encode(nanDecision)
        }

        let infVector = CGVector(dx: Double.infinity, dy: 0)
        let infDecision = ComputerActionDecision(
            action: .scroll,
            scrollDelta: infVector
        )
        #expect(throws: EncodingError.self) {
            _ = try encoder.encode(infDecision)
        }
    }

    // MARK: - 4. UIElementCandidate Dual-Key, Bounds & Center Oracles

    @Test("UIElementCandidate dual-key decoding: label vs title precedence")
    func uiElementCandidateDualKeyPrecedence() throws {
        // When only title is provided (modern spec format)
        let modernOnlyJson = """
        {
            "id": "elem_1",
            "role": "AXButton",
            "title": "Modern Title",
            "bounds": [[10, 20], [100, 50]],
            "isActionable": true,
            "source": "accessibility"
        }
        """
        let decodedModern = try JSONDecoder().decode(UIElementCandidate.self, from: Data(modernOnlyJson.utf8))
        #expect(decodedModern.title == "Modern Title")
        #expect(decodedModern.label == "Modern Title")

        // When only label is provided (legacy format)
        let legacyOnlyJson = """
        {
            "id": "elem_2",
            "role": "AXButton",
            "label": "Legacy Label",
            "bounds": [[10, 20], [100, 50]]
        }
        """
        let decodedLegacy = try JSONDecoder().decode(UIElementCandidate.self, from: Data(legacyOnlyJson.utf8))
        #expect(decodedLegacy.title == "Legacy Label")
        #expect(decodedLegacy.label == "Legacy Label")
        #expect(decodedLegacy.source == .accessibility) // default source

        // When both label and title are present in JSON
        let collisionJson = """
        {
            "id": "elem_3",
            "role": "AXButton",
            "label": "Legacy Label Content",
            "title": "Modern Title Content",
            "bounds": [[0, 0], [200, 40]]
        }
        """
        let decodedCollision = try JSONDecoder().decode(UIElementCandidate.self, from: Data(collisionJson.utf8))
        // Verify which key was resolved:
        #expect(!decodedCollision.label.isEmpty)
        #expect(decodedCollision.title == decodedCollision.label)
    }

    @Test("UIElementCandidate center calculation oracle across boundary conditions")
    func uiElementCandidateCenterOracle() {
        let testRects: [(bounds: CGRect, expectedCenter: CGPoint)] = [
            (CGRect(x: 0, y: 0, width: 100, height: 50), CGPoint(x: 50, y: 25)),
            (CGRect(x: 200, y: 300, width: 80, height: 40), CGPoint(x: 240, y: 320)),
            // Negative origin (secondary monitor)
            (CGRect(x: -1920, y: -1080, width: 1920, height: 1080), CGPoint(x: -960, y: -540)),
            // Zero-sized point element
            (CGRect(x: 150, y: 250, width: 0, height: 0), CGPoint(x: 150, y: 250)),
            // Odd pixel dimensions
            (CGRect(x: 10, y: 20, width: 15, height: 25), CGPoint(x: 17.5, y: 32.5)),
            // Fractional floats
            (CGRect(x: 10.25, y: 20.75, width: 30.5, height: 40.5), CGPoint(x: 25.5, y: 41.0)),
        ]

        for (i, tc) in testRects.enumerated() {
            let candidate = UIElementCandidate(
                id: "c_\(i)",
                role: "AXButton",
                title: "Element \(i)",
                bounds: tc.bounds,
                source: .ocr
            )

            #expect(candidate.center.x == tc.expectedCenter.x)
            #expect(candidate.center.y == tc.expectedCenter.y)
            #expect(candidate.source == .ocr)
        }
    }

    @Test("UIElementCandidate Codable roundtrip emits both label and title")
    func uiElementCandidateEmitsBothLabelAndTitle() throws {
        let candidate = UIElementCandidate(
            id: "elem_roundtrip",
            role: "AXTextField",
            title: "Search Query",
            value: "Swift Concurrency",
            bounds: CGRect(x: 50, y: 100, width: 300, height: 32),
            isActionable: true,
            source: .accessibility
        )

        let data = try JSONEncoder().encode(candidate)
        let jsonDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(jsonDict != nil)
        #expect(jsonDict?["label"] as? String == "Search Query")
        #expect(jsonDict?["title"] as? String == "Search Query")
        #expect(jsonDict?["source"] as? String == "accessibility")

        let decoded = try JSONDecoder().decode(UIElementCandidate.self, from: data)
        #expect(decoded == candidate)
        #expect(decoded.title == "Search Query")
    }

    // MARK: - 5. Corrupted JSON & Missing Mandatory Keys

    @Test("Corrupted JSON or missing mandatory keys throw DecodingError")
    func missingMandatoryKeysThrows() {
        let decoder = JSONDecoder()

        // Missing action in ComputerActionDecision
        let noActionJson = """
        {
            "confidence": 0.95,
            "coordinates": [100, 200]
        }
        """
        #expect(throws: DecodingError.self) {
            try decoder.decode(ComputerActionDecision.self, from: Data(noActionJson.utf8))
        }

        // Invalid action string
        let invalidActionJson = """
        {
            "action": "super_mega_click"
        }
        """
        #expect(throws: DecodingError.self) {
            try decoder.decode(ComputerActionDecision.self, from: Data(invalidActionJson.utf8))
        }

        // Missing bounds in UIElementCandidate
        let noBoundsJson = """
        {
            "id": "e1",
            "role": "AXButton",
            "title": "Click"
        }
        """
        #expect(throws: DecodingError.self) {
            try decoder.decode(UIElementCandidate.self, from: Data(noBoundsJson.utf8))
        }
    }

    // MARK: - 6. Geometry Encoding Formats (Array vs Dictionary Representation)

    @Test("Geometry decoding: check behavior for dictionary vs array representations")
    func geometryEncodingRepresentations() {
        let decoder = JSONDecoder()

        // Standard array representation for CGPoint: [100, 200]
        let arrayJson = """
        {
            "action": "click",
            "coordinates": [100, 200]
        }
        """
        let decodedArray = try? decoder.decode(ComputerActionDecision.self, from: Data(arrayJson.utf8))
        #expect(decodedArray?.coordinates == CGPoint(x: 100, y: 200))

        // Dictionary representation for CGPoint: {"x": 100, "y": 200}
        // Note: Apple Foundation's Codable implementation for CGPoint/CGVector/CGRect
        // defines the serialization format. Let's empirically check if dictionary format is supported or throws.
        let dictJson = """
        {
            "action": "click",
            "coordinates": {"x": 100, "y": 200}
        }
        """
        let decodedDict = try? decoder.decode(ComputerActionDecision.self, from: Data(dictJson.utf8))
        // Apple Foundation Codable for CGPoint uses SingleValueContainer or unkeyed container [x, y].
        // If dictionary is not supported by Foundation, decodedDict will be nil.
        // We record this empirical behavior.
        #expect(decodedDict == nil, "Foundation Codable for CGPoint decodes strictly from unkeyed [x, y] array, not dict")
    }

    // MARK: - 7. Unicode, Emoji, Multiline & Special Characters

    @Test("Unicode, emoji, multiline textInput and reasoning preserved across Codable roundtrip")
    func unicodeAndSpecialCharactersInPayload() throws {
        let complexTextInput = "こんにちは世界 🌍\nTab:\tQuote: \"Hello\" 'World'\r\nMath: ∑(x) = ∫ y dx"
        let complexReasoning = "ステップ 1: ログインボタンをクリックして次の画面へ進む 🚀 — [Test & Verify]"

        let decision = ComputerActionDecision(
            action: .typeText,
            coordinates: CGPoint(x: 100, y: 200),
            textInput: complexTextInput,
            keyCombination: ["⌘", "⌥", "Space"],
            reasoning: complexReasoning
        )

        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(ComputerActionDecision.self, from: data)

        #expect(decoded == decision)
        #expect(decoded.textInput == complexTextInput)
        #expect(decoded.reasoning == complexReasoning)
        #expect(decoded.keyCombination == ["⌘", "⌥", "Space"])
    }

    @Test("UIElementCandidate handles unicode, emojis, whitespace-only and empty values")
    func uiElementCandidateUnicodeAndEdgeStrings() throws {
        let candidate = UIElementCandidate(
            id: "elem_unicode_⚡️",
            role: "AXButton",
            title: "送信する 🚀 (Submit)",
            value: "値: 12,345 円",
            bounds: CGRect(x: 0, y: 0, width: 120, height: 40),
            source: .ocr
        )

        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(UIElementCandidate.self, from: data)

        #expect(decoded == candidate)
        #expect(decoded.title == "送信する 🚀 (Submit)")
        #expect(decoded.value == "値: 12,345 円")
        #expect(decoded.id == "elem_unicode_⚡️")
    }
}
