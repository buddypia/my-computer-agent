import Foundation
import MCACore
import OSLog

/// The three model calls made against a page outline: `observe` (find candidate
/// elements), `act` (choose one element and one method), `extract` (pull
/// structured data). Each returns parsed, validated output; the tools decide
/// what to do with it.
///
/// The model is reached through a closure rather than `ModelRouter` directly
/// so tests can substitute canned JSON.
public struct BrowserInference: Sendable {
    /// Runs one structured generation. `schema` is a JSON Schema the response
    /// must satisfy; providers that support guided generation enforce it,
    /// others get it in the prompt and are parsed leniently.
    public typealias Generate = @Sendable (_ system: String, _ user: String, _ schema: Data) async throws -> String

    private let log = Logger(subsystem: "com.buddypia.mca", category: "BrowserInference")
    private let generate: Generate
    /// Extra instructions from the user's configuration, appended as
    /// "Custom Instructions Provided by the User".
    public var userInstructions: String

    public init(userInstructions: String = "", generate: @escaping Generate) {
        self.userInstructions = userInstructions
        self.generate = generate
    }

    /// Wires the inference to the app's router at the `.answer` tier, which
    /// is the cheapest tier that reliably follows a schema.
    public init(router: ModelRouter, task: AgentTask = .answer, userInstructions: String = "") {
        self.init(userInstructions: userInstructions) { system, user, schema in
            let response = try await router.run(
                task: task,
                transcript: [.instructions(system), .prompt(Prompt(text: user))],
                temperature: 0,
                responseSchema: schema)
            return response.text
        }
    }

    // MARK: - Results

    public struct ObservedElement: Sendable, Equatable {
        public var elementID: String
        public var description: String
        public var method: BrowserActionMethod
        public var arguments: [String]

        public var action: BrowserAction {
            BrowserAction(method: method, elementID: elementID, description: description, arguments: arguments)
        }
    }

    public struct ActDecision: Sendable, Equatable {
        /// Nil when the model found nothing matching — never a guess.
        public var action: BrowserAction?
        /// The model believes a second step is needed (a custom dropdown that
        /// must be opened before an option can be chosen).
        public var twoStep: Bool
    }

    // MARK: - observe

    public static let defaultObserveInstruction =
        "Find elements that can be used for any future actions in the page. These may be navigation links, related pages, section/subsection links, buttons, or other interactive elements. Be comprehensive: if there are multiple elements that may be relevant for future actions, return all of them."

    public func observe(instruction: String?, outline: String) async throws -> [ObservedElement] {
        let system = Self.observeSystemPrompt(userInstructions: userInstructions)
        let user = "instruction: \(instruction ?? Self.defaultObserveInstruction)\nAccessibility Tree: \n\(outline)\n"
        let raw = try await generate(system, user, Self.observationSchema)
        guard let json = Self.parseObject(raw) else {
            throw BrowserError.protocolError("observe returned no JSON object")
        }
        let elements = (json["elements"] as? [[String: Any]]) ?? []
        return elements.compactMap(Self.element(from:))
    }

    // MARK: - act

    public func act(instruction: String, outline: String, secondStepAfter previous: BrowserAction? = nil, originalInstruction: String? = nil) async throws -> ActDecision {
        let system = Self.actSystemPrompt(userInstructions: userInstructions)
        let prompt: String
        if let previous {
            prompt = Self.stepTwoPrompt(original: originalInstruction ?? instruction, previous: previous)
        } else {
            prompt = Self.actPrompt(instruction)
        }
        let user = "instruction: \(prompt)\nAccessibility Tree: \n\(outline)\n"
        let raw = try await generate(system, user, Self.actSchema)
        guard let json = Self.parseObject(raw) else {
            throw BrowserError.protocolError("act returned no JSON object")
        }
        let twoStep = (json["twoStep"] as? Bool) ?? false
        guard let actionJSON = json["action"] as? [String: Any], let element = Self.element(from: actionJSON) else {
            return ActDecision(action: nil, twoStep: false)
        }
        return ActDecision(action: element.action, twoStep: twoStep)
    }

    // MARK: - extract

    /// Extracts data matching `schema` (a JSON Schema object) from the outline.
    /// Returns the raw JSON text of the object the model produced.
    public func extract(instruction: String, outline: String, schema: Data?) async throws -> String {
        let system = Self.extractSystemPrompt(userInstructions: userInstructions)
        let user = "Instruction: \(instruction)\nDOM: \(outline)"
        let effectiveSchema = schema ?? Self.freeformExtractSchema
        let raw = try await generate(system, user, effectiveSchema)
        guard let json = Self.parseObject(raw) else {
            throw BrowserError.protocolError("extract returned no JSON object")
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Prompts

    static func userInstructionsBlock(_ instructions: String) -> String {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return """


            # Custom Instructions Provided by the User

            Please keep the user's instructions in mind when performing actions. If the user's instructions are not relevant to the current task, ignore them.

            User Instructions:
            \(instructions)
            """
    }

    static func observeSystemPrompt(userInstructions: String) -> String {
        let actions = BrowserActionMethod.supportedNames.joined(separator: ", ")
        let base = """
            You are helping the user automate the browser by finding elements based on what the user wants to observe in the page.

            You will be given:
            1. a instruction of elements to observe
            2. a hierarchical accessibility tree showing the semantic structure of the page. The tree is a hybrid of the DOM and the accessibility tree.

            Return an array of elements that match the instruction if they exist, otherwise return an empty array.
            When returning elements, include the appropriate method from the supported actions list.

            Supported actions: \(actions). When choosing non-left click actions, provide right or middle as the argument.

            Each element in the accessibility tree has an ID in square brackets, like [0-18372]. The ID has two parts: frame ordinal and backend node ID. Always copy the complete ID exactly as shown inside the brackets into elementId, including the frame ordinal and hyphen. For example, if the tree shows [0-18372], return elementId "0-18372"; never return only "18372".

            Respond with only the JSON object described by the schema.
            """
        return base + userInstructionsBlock(userInstructions)
    }

    static func actSystemPrompt(userInstructions: String) -> String {
        let base = """
            You are helping the user automate the browser by finding elements based on what action the user wants to take on the page

            You will be given:
            1. a user defined instruction about what action to take
            2. a hierarchical accessibility tree showing the semantic structure of the page. The tree is a hybrid of the DOM and the accessibility tree.

            Return the element that matches the instruction if it exists. If no element on the page matches the instruction, set `action` to null. Do not fabricate or guess an element — empty strings or placeholder values for elementId/description/method are not acceptable.

            Each element in the accessibility tree has an ID in square brackets, like [0-18372]. Always copy the complete ID exactly as shown inside the brackets into elementId, including the frame ordinal and hyphen.

            Respond with only the JSON object described by the schema.
            """
        return base + userInstructionsBlock(userInstructions)
    }

    static func actPrompt(_ action: String) -> String {
        let actions = BrowserActionMethod.supportedNames.joined(separator: ", ")
        return """
            Find the most relevant element to perform an action on given the following action: \(action).
            IF AND ONLY IF the action EXPLICITLY includes the word 'dropdown' and implies choosing/selecting an option from a dropdown, ignore the 'General Instructions' section, and follow the 'Dropdown Specific Instructions' section carefully.

            General Instructions:
              Provide an action for this element such as \(actions). Remember that to users, buttons and links look the same in most cases.
              When choosing non-left click actions, provide right or middle as the argument
              If the action is completely unrelated to a potential action to be taken on the page, or no matching element exists, set `action` to null. Do not fabricate or guess an element.
              ONLY return one action. If multiple actions are relevant, return the most relevant one.
              If the user is asking to scroll to a position on the page, e.g., 'halfway' or 0.75, etc, you must return the argument formatted as the correct percentage, e.g., '50%' or '75%', etc.
              If the user is asking to scroll to the next chunk/previous chunk, choose the nextChunk/prevChunk method. No arguments are required here.
              If the action implies a key press, e.g., 'press enter', 'press a', 'press space', etc., always choose the press method with the appropriate key as argument — e.g. 'a', 'Enter', 'Space'. Do not choose a click action on an on-screen keyboard. Capitalize the first character like 'Enter', 'Tab', 'Escape' only for special keys.
              For typing into a field, prefer the fill method with the text as the single argument; it clears the field first.

            Dropdown Specific Instructions:
              For interacting with dropdowns, there are two specific cases that you need to handle.

              CASE 1: the element is a 'select' element.
                - choose the selectOptionFromDropdown method,
                - set the argument to the exact text of the option that should be selected,
                - set twoStep to false.
              CASE 2: the element is NOT a 'select' element:
                - do not attempt to directly choose the element from the dropdown. You will need to click to expand the dropdown first. You will achieve this by following these instructions:
                  - choose the node that most closely corresponds to the given instruction EVEN if it is a 'StaticText' element, or otherwise does not appear to be interactable.
                  - choose the 'click' method
                  - set twoStep to true.
            """
    }

    static func stepTwoPrompt(original: String, previous: BrowserAction) -> String {
        let actions = BrowserActionMethod.supportedNames.filter { $0 != BrowserActionMethod.selectOptionFromDropdown.rawValue }.joined(separator: ", ")
        let previousText = "method: \(previous.method.rawValue), description: \(previous.description), arguments: \(previous.arguments.joined(separator: ", "))"
        return """
            The original user action was: \(original).
            You have just taken the following action which completed step 1 of 2: \(previousText).

            Now, you must find the most relevant element to perform an action on in order to complete step 2 of 2.

            General Instructions:
            Provide an action for this element such as \(actions). Remember that to users, buttons and links look the same in most cases.
            If the action is completely unrelated to a potential action to be taken on the page, or no matching element exists, set `action` to null. Do not fabricate or guess an element.
            ONLY return one action. If multiple actions are relevant, return the most relevant one.
            If the user is asking to scroll to a position on the page, e.g., 'halfway' or 0.75, etc, you must return the argument formatted as the correct percentage, e.g., '50%' or '75%', etc.
            If the user is asking to scroll to the next chunk/previous chunk, choose the nextChunk/prevChunk method. No arguments are required here.
            If the action implies a key press, e.g., 'press enter', 'press a', 'press space', etc., always choose the press method with the appropriate key as argument — e.g. 'a', 'Enter', 'Space'. Do not choose a click action on an on-screen keyboard. Capitalize the first character like 'Enter', 'Tab', 'Escape' only for special keys.
            """
    }

    static func extractSystemPrompt(userInstructions: String) -> String {
        let base = """
            You are extracting content on behalf of a user. When the user asks for a 'list' or for 'all' of something, extract every matching item on the page, not a sample.

            You will be given:
            1. An instruction
            2. A list of DOM elements to extract from.

            Print the exact text from the DOM elements with all symbols, characters, and endlines as is. Print null or an empty string if no new information is found.

            If a user is attempting to extract links or URLs, use the URL shown for the link element when present; do not invent URLs.

            Respond with only the JSON object described by the schema.
            """
        return base + userInstructionsBlock(userInstructions)
    }

    // MARK: - Schemas

    /// Kept to the subset Gemini's `responseSchema` accepts: no `pattern`,
    /// `additionalProperties`, `$ref` or `const`.
    static let observationSchema = Data("""
        {
          "type": "object",
          "properties": {
            "elements": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "elementId": {"type": "string", "description": "The complete frame ordinal and backend node ID copied from the accessibility tree, without square brackets, e.g. 0-18372."},
                  "description": {"type": "string", "description": "A description of the accessible element and its purpose."},
                  "method": {"type": "string", "enum": \(methodEnumJSON), "description": "The supported browser interaction method for this element."},
                  "arguments": {"type": "array", "items": {"type": "string"}, "description": "The arguments to pass to the selected interaction method."}
                },
                "required": ["elementId", "description", "method", "arguments"]
              }
            }
          },
          "required": ["elements"]
        }
        """.utf8)

    static let actSchema = Data("""
        {
          "type": "object",
          "properties": {
            "action": {
              "type": "object",
              "nullable": true,
              "description": "The element to act on, or null when no matching element exists.",
              "properties": {
                "elementId": {"type": "string", "description": "The complete frame ordinal and backend node ID copied from the accessibility tree, without square brackets, e.g. 0-18372."},
                "description": {"type": "string", "description": "A description of the element and its purpose."},
                "method": {"type": "string", "enum": \(methodEnumJSON), "description": "The supported browser interaction method to execute."},
                "arguments": {"type": "array", "items": {"type": "string"}, "description": "The arguments to pass to the selected interaction method."}
              },
              "required": ["elementId", "description", "method", "arguments"]
            },
            "twoStep": {"type": "boolean", "description": "Whether the selected interaction requires a second action to finish the request."}
          },
          "required": ["action", "twoStep"]
        }
        """.utf8)

    static let freeformExtractSchema = Data("""
        {
          "type": "object",
          "properties": {
            "data": {"type": "string", "description": "The extracted content, as text or a JSON-formatted string when it is a list or a record."}
          },
          "required": ["data"]
        }
        """.utf8)

    static var methodEnumJSON: String {
        "[" + BrowserActionMethod.supportedNames.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    // MARK: - Parsing

    static func element(from json: [String: Any]) -> ObservedElement? {
        guard var elementID = json["elementId"] as? String ?? (json["elementId"] as? Int).map(String.init) else { return nil }
        elementID = elementID.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        // A bare backend id is the one mistake the prompt warns about; assume
        // the main frame rather than dropping the element.
        if !elementID.contains("-"), Int(elementID) != nil { elementID = "0-\(elementID)" }
        guard elementID.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil else { return nil }
        guard let methodName = json["method"] as? String,
              let method = BrowserActionMethod(rawValue: methodName) ?? BrowserActionMethod.lenient(methodName)
        else { return nil }
        let arguments = (json["arguments"] as? [Any])?.map { "\($0)" } ?? []
        return ObservedElement(
            elementID: elementID,
            description: (json["description"] as? String) ?? "",
            method: method,
            arguments: arguments)
    }

    /// Finds the outermost JSON object in a response that may be wrapped in
    /// prose or a code fence.
    static func parseObject(_ text: String) -> [String: Any]? {
        var candidate = text
        if let fence = candidate.range(of: "```") {
            candidate = String(candidate[fence.upperBound...])
            if candidate.hasPrefix("json") { candidate = String(candidate.dropFirst(4)) }
            if let end = candidate.range(of: "```") { candidate = String(candidate[..<end.lowerBound]) }
        }
        guard let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(candidate[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

extension BrowserActionMethod {
    /// Accepts the spellings models drift to (`double_click`, `scroll`).
    static func lenient(_ name: String) -> BrowserActionMethod? {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        switch key {
        case "click", "leftclick": return .click
        case "doubleclick", "dblclick": return .doubleClick
        case "fill", "setvalue", "input": return .fill
        case "type", "typetext": return .type
        case "press", "presskey", "key": return .press
        case "scroll", "scrollto": return .scrollTo
        case "nextchunk", "scrolldown": return .nextChunk
        case "prevchunk", "previouschunk", "scrollup": return .prevChunk
        case "select", "selectoption", "selectoptionfromdropdown": return .selectOptionFromDropdown
        case "hover", "mouseover": return .hover
        case "draganddrop", "drag": return .dragAndDrop
        default: return nil
        }
    }
}
