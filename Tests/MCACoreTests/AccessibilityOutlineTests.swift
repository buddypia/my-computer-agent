import Foundation
import Testing
@testable import MCACore

@Suite("AccessibilityOutline (hybrid tree)")
struct AccessibilityOutlineTests {
    private func node(
        _ id: String, parent: String? = nil, children: [String] = [], role: String, name: String? = nil,
        tag: String? = nil, scrollable: Bool = false
    ) -> OutlineNode {
        OutlineNode(nodeID: id, parentID: parent, childIDs: children, role: role, name: name,
                    encodedID: "0-\(id)", tagName: tag, isScrollable: scrollable)
    }

    @Test("structural nodes without a name collapse into their child")
    func pruning() {
        let nodes = [
            node("1", children: ["2"], role: "RootWebArea", name: "Page"),
            node("2", parent: "1", children: ["3"], role: "generic"),
            node("3", parent: "2", children: [], role: "button", name: "Save"),
        ]
        let rendered = AccessibilityOutline.render(AccessibilityOutline.buildTree(nodes))
        #expect(rendered == "[0-1] RootWebArea: Page\n  [0-3] button: Save")
    }

    @Test("StaticText repeating the parent's name is dropped")
    func redundantStaticText() {
        let nodes = [
            node("1", children: ["2"], role: "link", name: "Learn more"),
            node("2", parent: "1", role: "StaticText", name: "Learn more"),
        ]
        let rendered = AccessibilityOutline.render(AccessibilityOutline.buildTree(nodes))
        #expect(rendered == "[0-1] link: Learn more")
    }

    @Test("scrollable elements and <select> are relabelled")
    func decoration() {
        let nodes = [
            node("1", children: ["2", "3"], role: "RootWebArea", name: "P"),
            node("2", parent: "1", role: "generic", name: "feed", tag: "div", scrollable: true),
            node("3", parent: "1", role: "combobox", name: "Country", tag: "select"),
        ]
        let rendered = AccessibilityOutline.render(AccessibilityOutline.buildTree(nodes))
        #expect(rendered.contains("[0-2] scrollable, div: feed"))
        #expect(rendered.contains("[0-3] select: Country"))
    }

    @Test("renderedIDs lists exactly the ids that survive pruning")
    func renderedIDs() {
        let nodes = [
            node("1", children: ["2"], role: "RootWebArea", name: "P"),
            node("2", parent: "1", children: ["3"], role: "none"),
            node("3", parent: "2", role: "link", name: "Go"),
        ]
        let tree = AccessibilityOutline.buildTree(nodes)
        #expect(AccessibilityOutline.renderedIDs(tree) == ["0-1", "0-3"])
    }

    @Test("trim keeps matching lines with their ancestors and honours max depth")
    func trimFilterAndDepth() {
        let outline = """
            [0-1] RootWebArea: Shop
              [0-2] navigation
                [0-3] link: Home
                [0-4] link: Cart
              [0-5] main
                [0-6] heading: Products
                [0-7] button: Add to cart
            """
        let filtered = AccessibilityOutline.trim(outline, options: BrowserSnapshotOptions(filter: "cart"))
        #expect(filtered == "[0-1] RootWebArea: Shop\n  [0-2] navigation\n    [0-4] link: Cart\n  [0-5] main\n    [0-7] button: Add to cart")

        let regex = AccessibilityOutline.trim(outline, options: BrowserSnapshotOptions(filter: "/^\\s*\\[0-6\\]/"))
        #expect(regex.contains("[0-6] heading: Products"))
        #expect(!regex.contains("[0-7]"))

        let shallow = AccessibilityOutline.trim(outline, options: BrowserSnapshotOptions(maxDepth: 1))
        #expect(shallow == "[0-1] RootWebArea: Shop\n  [0-2] navigation\n  [0-5] main")
    }

    @Test("trim enforces the character budget and says how much was cut")
    func trimBudget() {
        let outline = (1...50).map { "[0-\($0)] link: item \($0)" }.joined(separator: "\n")
        let trimmed = AccessibilityOutline.trim(outline, options: BrowserSnapshotOptions(maxCharacters: 120))
        #expect(trimmed.count < 200)
        #expect(trimmed.contains("more lines omitted"))
    }

    @Test("diff returns only the lines a click revealed, re-based to column 0")
    func diff() {
        let before = "[0-1] RootWebArea\n  [0-2] combobox: Size"
        let after = "[0-1] RootWebArea\n  [0-2] combobox: Size\n    [0-3] option: Small\n    [0-4] option: Large"
        #expect(AccessibilityOutline.diff(previous: before, next: after) == "[0-3] option: Small\n[0-4] option: Large")
        #expect(AccessibilityOutline.diff(previous: after, next: after) == "")
    }

    @Test("iframe outlines are nested under the host line")
    func injectSubtrees() {
        let root = "[0-1] RootWebArea\n  [0-9] Iframe"
        let combined = AccessibilityOutline.injectSubtrees(root, subtrees: ["0-9": "[1-1] RootWebArea: Ad\n  [1-2] link: Buy"])
        #expect(combined == "[0-1] RootWebArea\n  [0-9] Iframe\n    [1-1] RootWebArea: Ad\n      [1-2] link: Buy")
    }

    @Test("cleanText strips private-use glyphs and folds spaces")
    func cleanText() {
        #expect(AccessibilityOutline.cleanText("\u{E000}Save\u{00A0} now") == "Save now")
    }
}

@Suite("Browser value types")
struct BrowserSnapshotTypeTests {
    @Test("element-less methods are the ones that act on the page or focus")
    func requiresElement() {
        #expect(!BrowserActionMethod.press.requiresElement)
        #expect(!BrowserActionMethod.nextChunk.requiresElement)
        #expect(BrowserActionMethod.click.requiresElement)
        #expect(BrowserActionMethod.fill.requiresElement)
    }

    @Test("stale ref error tells the model what to do next")
    func staleRefMessage() {
        let message = BrowserError.staleRef("0-42", available: 7).description
        #expect(message.contains("0-42"))
        #expect(message.contains("browser_snapshot"))
    }

    @Test("browser settings decode key by key with defaults")
    func settingsDecode() throws {
        let json = Data(#"{"browser": {"devtoolsPorts": [9333], "launchIfMissing": true}}"#.utf8)
        let configuration = try JSONDecoder().decode(AgentConfiguration.self, from: json)
        #expect(configuration.browser.devtoolsPorts == [9333])
        #expect(configuration.browser.launchIfMissing)
        #expect(configuration.browser.enabled)
        #expect(configuration.browser.accessibilityFallback)

        let legacy = try JSONDecoder().decode(AgentConfiguration.self, from: Data("{}".utf8))
        #expect(legacy.browser == BrowserAutomationSettings())
    }
}
