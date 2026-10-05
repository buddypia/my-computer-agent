import Foundation

// The pure half of the browser snapshot: turning a flat list of accessibility
// nodes into the pruned, indented outline the model reads. The outline reads
// the same whether it came from Chrome's DevTools accessibility tree or from
// macOS Accessibility.
//
// Everything here is deterministic and free of I/O so it can be unit-tested
// with fixtures instead of a running browser.

/// One node of an accessibility tree before pruning.
///
/// Drivers fill this from their own source: the devtools driver maps
/// `Accessibility.getFullAXTree` nodes plus DOM tag/scrollable maps, the
/// accessibility driver maps `AXUIElement` attributes.
public struct OutlineNode: Sendable, Equatable {
    public var nodeID: String
    public var parentID: String?
    public var childIDs: [String]
    public var role: String
    public var name: String?
    public var description: String?
    public var value: String?
    public var selected: Bool?
    public var checked: Bool?
    /// The `[frame-node]` id printed in the outline. Nil for nodes that have no
    /// DOM identity (they are printed with their tree node id instead).
    public var encodedID: String?
    /// Lower-case HTML tag (`div`, `select`, `input, file`) when the DOM is
    /// known. Used to relabel `generic` nodes and to detect `<select>`.
    public var tagName: String?
    public var isScrollable: Bool

    public init(
        nodeID: String, parentID: String? = nil, childIDs: [String] = [],
        role: String, name: String? = nil, description: String? = nil, value: String? = nil,
        selected: Bool? = nil, checked: Bool? = nil, encodedID: String? = nil,
        tagName: String? = nil, isScrollable: Bool = false
    ) {
        self.nodeID = nodeID
        self.parentID = parentID
        self.childIDs = childIDs
        self.role = role
        self.name = name
        self.description = description
        self.value = value
        self.selected = selected
        self.checked = checked
        self.encodedID = encodedID
        self.tagName = tagName
        self.isScrollable = isScrollable
    }
}

/// A pruned tree ready to render.
public final class OutlineTreeNode: @unchecked Sendable {
    public let nodeID: String
    public var role: String
    public let name: String?
    public let encodedID: String?
    public let selected: Bool
    public let checked: Bool
    public var children: [OutlineTreeNode]

    init(_ node: OutlineNode, role: String, children: [OutlineTreeNode]) {
        self.nodeID = node.nodeID
        self.role = role
        self.name = node.name
        self.encodedID = node.encodedID
        self.selected = node.selected ?? false
        self.checked = node.checked ?? false
        self.children = children
    }

    /// The label shown in brackets: the encoded id when there is one.
    public var label: String { encodedID ?? nodeID }
}

public enum AccessibilityOutline {
    /// Container roles that carry no meaning of their own. A structural node
    /// with one child is replaced by that child; with none it is dropped.
    public static func isStructural(_ role: String) -> Bool {
        let lower = role.lowercased()
        return lower == "generic" || lower == "none" || lower == "inlinetextbox"
    }

    /// Re-labels roles before building the tree:
    /// scrollable containers and the `<html>` element become `scrollable, tag`,
    /// and file inputs (which Chrome exposes as `button`) become `input, file`.
    public static func decorateRole(of node: OutlineNode) -> String {
        var role = node.role
        let tag = node.tagName
        let isHTMLElement = tag == "html"
        if (node.isScrollable || isHTMLElement) && tag != "#document" {
            if let tag {
                let label = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
                role = "scrollable, \(label)"
            } else {
                role = role.isEmpty ? "scrollable" : "scrollable, \(role)"
            }
        }
        if tag == "input, file" {
            role = "input, file"
        }
        return role
    }

    /// Builds the pruned hierarchy from a flat node list.
    ///
    /// Rules, in order:
    /// 1. Keep a node if it has a name, has children, or is not structural.
    /// 2. Attach children to parents; roots are nodes without a parent.
    /// 3. Prune bottom-up: drop empty structural nodes, collapse a structural
    ///    node with one surviving child into that child.
    /// 4. Drop `StaticText` children whose combined text merely repeats the
    ///    parent's name (a link's own label, for example).
    /// 5. Relabel `generic`/`none` with the tag when known, and `combobox` on a
    ///    `<select>` as `select` so the model picks `selectOptionFromDropdown`.
    public static func buildTree(_ nodes: [OutlineNode]) -> [OutlineTreeNode] {
        var kept: [String: OutlineNode] = [:]
        var order: [String] = []
        for node in nodes {
            let hasName = !(node.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let keep = hasName || !node.childIDs.isEmpty || !isStructural(node.role)
            guard keep, kept[node.nodeID] == nil else { continue }
            kept[node.nodeID] = node
            order.append(node.nodeID)
        }

        var childrenOf: [String: [String]] = [:]
        for id in order {
            guard let node = kept[id], let parent = node.parentID, kept[parent] != nil else { continue }
            childrenOf[parent, default: []].append(id)
        }

        // Preserve the source order of children where the source declared it.
        for (parent, kids) in childrenOf {
            if let declared = kept[parent]?.childIDs, !declared.isEmpty {
                let rank = Dictionary(uniqueKeysWithValues: declared.enumerated().map { ($1, $0) })
                childrenOf[parent] = kids.sorted { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
            }
        }

        func prune(_ id: String) -> OutlineTreeNode? {
            guard let node = kept[id] else { return nil }
            if let numeric = Int(node.nodeID), numeric < 0 { return nil }

            let childNodes = (childrenOf[id] ?? []).compactMap(prune)
            let decorated = decorateRole(of: node)

            // Relabel before deciding on leaves so a bare `<select>` (a leaf
            // until it opens) still reads `select`, and a named `generic`
            // shows its tag.
            var role = decorated
            if (role == "generic" || role == "none"), let tag = node.tagName, !tag.isEmpty {
                role = tag
            }
            if role == "combobox", node.tagName == "select" {
                role = "select"
            }

            if childNodes.isEmpty {
                return isStructural(decorated) ? nil : OutlineTreeNode(node, role: role, children: [])
            }

            let withoutEcho = removeRedundantStaticText(parentName: node.name, children: childNodes)

            if isStructural(decorated) {
                if withoutEcho.count == 1 { return withoutEcho[0] }
                if withoutEcho.isEmpty { return nil }
            }
            return OutlineTreeNode(node, role: role, children: withoutEcho)
        }

        return order
            .filter { kept[$0]?.parentID == nil || kept[kept[$0]!.parentID!] == nil }
            .compactMap(prune)
    }

    /// Drops `StaticText` children whose concatenated text equals the parent's
    /// accessible name — the text would otherwise be printed twice.
    public static func removeRedundantStaticText(parentName: String?, children: [OutlineTreeNode]) -> [OutlineTreeNode] {
        guard let parentName, !parentName.isEmpty else { return children }
        let target = normaliseSpaces(parentName).trimmingCharacters(in: .whitespaces)
        var combined = ""
        for child in children where child.role == "StaticText" {
            combined += normaliseSpaces(child.name ?? "").trimmingCharacters(in: .whitespaces)
        }
        guard combined == target else { return children }
        return children.filter { $0.role != "StaticText" }
    }

    // MARK: - Rendering

    /// Renders the outline. Two spaces per level, `[id] role: name` per line,
    /// with `[selected]` / `[checked]` state flags appended.
    public static func render(_ roots: [OutlineTreeNode]) -> String {
        var lines: [String] = []
        for root in roots { renderLines(root, level: 0, into: &lines) }
        return lines.joined(separator: "\n")
    }

    private static func renderLines(_ node: OutlineTreeNode, level: Int, into lines: inout [String]) {
        var label = "[\(node.label)] \(node.role)"
        if let name = node.name, !name.isEmpty {
            let cleaned = cleanText(name)
            if !cleaned.isEmpty { label += ": \(cleaned)" }
        }
        if node.selected { label += " [selected]" }
        if node.checked { label += " [checked]" }
        lines.append(String(repeating: "  ", count: level) + label)
        for child in node.children { renderLines(child, level: level + 1, into: &lines) }
    }

    /// Every encoded id printed in the tree, so callers can restrict the ref
    /// map to nodes the model can actually see.
    public static func renderedIDs(_ roots: [OutlineTreeNode]) -> [String] {
        var ids: [String] = []
        func walk(_ node: OutlineTreeNode) {
            if let encoded = node.encodedID { ids.append(encoded) }
            node.children.forEach(walk)
        }
        roots.forEach(walk)
        return ids
    }

    /// Nests each child-frame outline under the line of the iframe that hosts
    /// it. `subtrees` is keyed by the host iframe's encoded id.
    public static func injectSubtrees(_ rootOutline: String, subtrees: [String: String]) -> String {
        guard !subtrees.isEmpty else { return rootOutline }
        var out: [String] = []
        var visited = Set<String>()

        func inject(_ outline: String) {
            for raw in outline.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                out.append(raw)
                let indent = raw.prefix { $0 == " " }
                let content = raw.dropFirst(indent.count)
                guard content.hasPrefix("["), let close = content.firstIndex(of: "]") else { continue }
                let id = String(content[content.index(after: content.startIndex)..<close])
                guard let child = subtrees[id], !visited.contains(id) else { continue }
                visited.insert(id)
                let nested = injectSubtrees(child, subtrees: subtrees)
                out.append(indentBlock(nested, indent: String(indent) + "  "))
            }
        }
        inject(rootOutline)
        return out.joined(separator: "\n")
    }

    public static func indentBlock(_ block: String, indent: String) -> String {
        guard !block.isEmpty else { return "" }
        return block.split(separator: "\n", omittingEmptySubsequences: false)
            .map { indent + $0 }
            .joined(separator: "\n")
    }

    // MARK: - Trimming for the model

    /// Applies the CLI-style view options: depth cap, then a substring or
    /// `/regex/` filter that keeps matching lines together with their
    /// ancestors, then the character budget.
    public static func trim(_ outline: String, options: BrowserSnapshotOptions) -> String {
        var lines = outline.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let maxDepth = options.maxDepth {
            lines = lines.filter { depth(of: $0) <= maxDepth }
        }
        if let filter = options.filter, !filter.isEmpty {
            lines = keepLinesWithAncestors(lines) { matches($0, pattern: filter) }
        }

        var budget = options.maxCharacters
        var kept: [String] = []
        var dropped = 0
        for line in lines {
            if budget - line.count - 1 < 0 {
                dropped += 1
                continue
            }
            budget -= line.count + 1
            kept.append(line)
        }
        if dropped > 0 {
            kept.append("… \(dropped) more lines omitted (use filter or max_depth to narrow)")
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lines added between two outlines, ignoring indentation, re-based so the
    /// shallowest added line sits at column 0. Empty when nothing changed.
    /// Used for the second step of a two-step action so the model only sees
    /// what a click revealed (a dropdown's options, a dialog).
    public static func diff(previous: String, next: String) -> String {
        let seen = Set(previous.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let added = next.split(separator: "\n").map(String.init).filter { line in
            let core = line.trimmingCharacters(in: .whitespaces)
            return !core.isEmpty && !seen.contains(core)
        }
        guard !added.isEmpty else { return "" }
        let minIndent = added.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return added.map { String($0.dropFirst(minIndent)) }.joined(separator: "\n")
    }

    // MARK: - Text helpers

    /// Removes private-use glyphs (icon fonts) and folds non-breaking spaces.
    public static func cleanText(_ input: String) -> String {
        var out = ""
        var inWhitespace = false
        for scalar in input.unicodeScalars {
            let value = scalar.value
            if (0xE000...0xF8FF).contains(value) { continue }
            let isSpace = value == 0x00A0 || value == 0x202F || value == 0x2007 || value == 0xFEFF
                || scalar.properties.isWhitespace
            if isSpace {
                if !inWhitespace {
                    out.append(" ")
                    inWhitespace = true
                }
                continue
            }
            out.unicodeScalars.append(scalar)
            inWhitespace = false
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses whitespace runs to a single space without trimming.
    public static func normaliseSpaces(_ text: String) -> String {
        var out = ""
        var inWhitespace = false
        for character in text {
            if character.isWhitespace {
                if !inWhitespace {
                    out.append(" ")
                    inWhitespace = true
                }
            } else {
                out.append(character)
                inWhitespace = false
            }
        }
        return out
    }

    /// Tree depth of a rendered line (two spaces per level).
    public static func depth(of line: String) -> Int {
        line.prefix { $0 == " " }.count / 2
    }

    static func keepLinesWithAncestors(_ lines: [String], where shouldKeep: (String) -> Bool) -> [String] {
        var keep = Set<Int>()
        for index in lines.indices where shouldKeep(lines[index]) {
            keep.insert(index)
            var depth = depth(of: lines[index])
            var ancestor = index - 1
            while ancestor >= 0 {
                let ancestorDepth = self.depth(of: lines[ancestor])
                if ancestorDepth < depth {
                    keep.insert(ancestor)
                    depth = ancestorDepth
                    if ancestorDepth == 0 { break }
                }
                ancestor -= 1
            }
        }
        return lines.indices.filter { keep.contains($0) }.map { lines[$0] }
    }

    static func matches(_ line: String, pattern: String) -> Bool {
        if pattern.count > 2, pattern.hasPrefix("/"), let last = pattern.lastIndex(of: "/"), last != pattern.startIndex {
            let body = String(pattern[pattern.index(after: pattern.startIndex)..<last])
            let flags = String(pattern[pattern.index(after: last)...])
            var options: NSRegularExpression.Options = []
            if flags.contains("i") { options.insert(.caseInsensitive) }
            if let regex = try? NSRegularExpression(pattern: body, options: options) {
                let range = NSRange(line.startIndex..., in: line)
                return regex.firstMatch(in: line, range: range) != nil
            }
        }
        return line.localizedCaseInsensitiveContains(pattern)
    }
}
