import AppKit
import MCACore
import SwiftUI

/// One block of a markdown document, in the small subset a chat answer uses.
///
/// A block model rather than one attributed string because the two differ in
/// what they can express: `AttributedString(markdown:)` renders emphasis, links
/// and inline code, but it has no way to draw a fenced block as a box you can
/// copy from, a list as aligned rows, or a table as columns. Those are exactly
/// the shapes a model reaches for when it answers "what is wrong with this
/// screen" — a command to run, three things to check, a table of options — and
/// collapsing them into a paragraph of pipes and backticks is what "markdown
/// support" is meant to stop.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    /// `language` is whatever followed the opening fence, if anything.
    case code(language: String?, text: String)
    case quote(String)
    /// Rows are padded to the header's width at parse time, so the renderer can
    /// assume a rectangle.
    case table(header: [String], rows: [[String]])
    case divider
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Nesting level, 0 for a top-level item.
    public var depth: Int
    /// What is drawn in the gutter: a bullet, an ordinal, or a checkbox.
    public var marker: String
    public var text: String

    public init(depth: Int, marker: String, text: String) {
        self.depth = depth
        self.marker = marker
        self.text = text
    }
}

/// A line-based markdown reader.
///
/// Deliberately not a conforming CommonMark parser. It reads text a model
/// produced for a person to skim, so the only thing that matters is that the
/// common shapes survive and that nothing throws — an answer must never fail to
/// appear because it contained an odd character. Anything unrecognised falls
/// through to a paragraph and is shown as written.
public enum Markdown {
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fence(trimmed) {
                blocks.append(readCode(lines, from: &index, fence: fence))
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                blocks.append(readQuote(lines, from: &index))
                continue
            }

            if isTableStart(lines, at: index) {
                blocks.append(readTable(lines, from: &index))
                continue
            }

            if listItem(line) != nil {
                var items: [MarkdownListItem] = []
                while index < lines.count, let item = listItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            blocks.append(readParagraph(lines, from: &index))
        }

        return blocks
    }

    // MARK: - Blocks

    /// An unterminated fence runs to the end of the input rather than being
    /// rejected. Answers are rendered while they stream, so *every* code block
    /// is unterminated for as long as it is being typed out — treating that as
    /// malformed would make the block flicker into existence only at the end.
    private static func readCode(
        _ lines: [String], from index: inout Int, fence: String
    ) -> MarkdownBlock {
        let opening = lines[index].trimmingCharacters(in: .whitespaces)
        let language = String(opening.dropFirst(fence.count))
            .trimmingCharacters(in: .whitespaces)
        index += 1

        var body: [String] = []
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix(fence) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }

        return .code(
            language: language.isEmpty ? nil : language,
            text: body.joined(separator: "\n"))
    }

    private static func readQuote(_ lines: [String], from index: inout Int) -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix(">") else { break }
            body.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .quote(body.joined(separator: "\n"))
    }

    private static func readTable(_ lines: [String], from index: inout Int) -> MarkdownBlock {
        let header = cells(lines[index])
        index += 2  // the header and the `---|---` rule under it

        var rows: [[String]] = []
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            guard candidate.contains("|") else { break }
            var row = cells(candidate)
            // Padded and truncated here so the renderer never has to reason
            // about a ragged table: a model that drops a trailing empty cell
            // would otherwise shift a whole row left by one column.
            if row.count < header.count {
                row.append(contentsOf: Array(repeating: "", count: header.count - row.count))
            }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }

        return .table(header: header, rows: rows)
    }

    /// Consecutive non-blank lines, kept as separate lines rather than reflowed.
    ///
    /// CommonMark folds a single newline into a space. That rule exists for
    /// prose typeset into a column; here the newline is usually load-bearing —
    /// a list of file paths, a stack frame, the second half of a sentence the
    /// model chose to break — and joining them produces a wall of text.
    private static func readParagraph(_ lines: [String], from index: inout Int) -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if fence(trimmed) != nil || isDivider(trimmed) || heading(trimmed) != nil
                || trimmed.hasPrefix(">") || listItem(line) != nil
                || isTableStart(lines, at: index) {
                break
            }
            body.append(trimmed)
            index += 1
        }
        return .paragraph(body.joined(separator: "\n"))
    }

    // MARK: - Line shapes

    private static func fence(_ trimmed: String) -> String? {
        for token in ["```", "~~~"] where trimmed.hasPrefix(token) {
            return token
        }
        return nil
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for token: Character in ["-", "*", "_"] where trimmed.allSatisfy({ $0 == token }) {
            return true
        }
        return false
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let columns = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = min(columns / 2, 3)
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first else { return nil }

        if "-*+".contains(first) {
            let body = rest.dropFirst()
            guard body.first == " " else { return nil }
            return item(depth: depth, marker: "•", body: body)
        }

        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        let body = afterDigits.dropFirst()
        guard body.first == " " else { return nil }
        return item(depth: depth, marker: "\(digits).", body: body)
    }

    /// Task list boxes get their own marker. A model asked what to fix answers
    /// with `- [ ]` often enough that leaving the brackets in the text reads as
    /// a typo rather than as a checkbox.
    private static func item(
        depth: Int, marker: String, body: Substring
    ) -> MarkdownListItem {
        var text = String(body.drop(while: { $0 == " " }))
        var marker = marker
        if text.hasPrefix("[ ] ") {
            marker = "☐"
            text.removeFirst(4)
        } else if text.lowercased().hasPrefix("[x] ") {
            marker = "☑"
            text.removeFirst(4)
        }
        return MarkdownListItem(depth: depth, marker: marker, text: text)
    }

    /// A table is only a table with the `|---|---|` rule under its header. A
    /// single line with a pipe in it is far more often a shell command.
    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        let rule = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"), rule.contains("|") else { return false }

        let ruleCells = cells(rule)
        guard ruleCells.count > 1 else { return false }
        return ruleCells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Markdown, drawn.
///
/// Replaces `Text(LocalizedStringKey(body))`, which was markdown support in the
/// sense that bold and inline code rendered — and in no other sense. It treated
/// the model's answer as a format string, so a lone `%@` in a log line the agent
/// quoted came out as a stray placeholder, and every block shape above was lost.
public struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    private let size: CGFloat

    public init(_ source: String, size: CGFloat = 13) {
        self.blocks = Markdown.blocks(source)
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(.system(size: size + (level <= 2 ? 3 : 1), weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            Text(inline(text))
                .font(.system(size: size))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .list(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: size - 1, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(inline(item.text))
                            .font(.system(size: size))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 13)
                }
            }

        case let .code(language, text):
            MarkdownCodeBlock(language: language, text: text, size: size)

        case let .quote(text):
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 2)
                Text(inline(text))
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .table(header, rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell))
                            .font(.system(size: size - 1, weight: .semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(.system(size: size - 1))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.vertical, 2)

        case .divider:
            Divider()
        }
    }

    /// Emphasis, links and inline code inside one block.
    ///
    /// `failurePolicy: .returnPartiallyParsedIfPossible` and the `catch` are the
    /// same guarantee said twice: whatever the model wrote, something legible is
    /// drawn. An unclosed `[` must not cost the user their answer.
    private func inline(_ text: String) -> AttributedString {
        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible))
        } catch {
            return AttributedString(text)
        }

        // Collected before mutating: the runs are a view onto the string being
        // edited.
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].font = .system(size: size - 0.5, design: .monospaced)
            attributed[range].backgroundColor = Color.secondary.opacity(0.18)
        }
        return attributed
    }
}

/// A fenced block: the code, what it is, and a way to get it out of the window.
///
/// The copy button is the point. Most fenced blocks in this app's answers are
/// commands meant to be run, and retyping one from a floating panel — or
/// dragging to select it inside a scroll view — is where the advice stops being
/// worth reading.
private struct MarkdownCodeBlock: View {
    let language: String?
    let text: String
    let size: CGFloat

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: size - 3, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: size - 4, weight: .medium))
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Copy", "コピー", "복사"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: size - 1, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
                    .padding(.top, 2)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        // The tick is the only evidence the click did anything — the pasteboard
        // is invisible from here — and it goes away on its own so a block that
        // was copied ten minutes ago does not still claim to be fresh.
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
