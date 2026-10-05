import Foundation
import Testing

@testable import MCAPresentation

/// The reader turns what a model wrote into what gets drawn, and every case here
/// is one the old `Text(LocalizedStringKey:)` path got wrong — a command block
/// that read as a line of backticks, a table that read as pipes, a list that
/// read as hyphens.
@Suite("Markdown")
struct MarkdownTests {
    @Test("a fenced block keeps its language and its line breaks")
    func fencedCode() {
        let blocks = Markdown.blocks("""
        Run this:

        ```bash
        swift build
        swift test
        ```
        """)

        #expect(blocks.count == 2)
        #expect(blocks.first == .paragraph("Run this:"))
        #expect(blocks.last == .code(language: "bash", text: "swift build\nswift test"))
    }

    /// Answers are drawn while they stream, so a block is unterminated for as
    /// long as it is being typed. Rejecting it would make the box appear only
    /// once the answer finished.
    @Test("an unterminated fence still renders as code")
    func unterminatedFence() {
        let blocks = Markdown.blocks("""
        ```swift
        let x = 1
        """)

        #expect(blocks == [.code(language: "swift", text: "let x = 1")])
    }

    @Test("bullets, ordinals and task boxes each get their own marker")
    func lists() {
        let blocks = Markdown.blocks("""
        - first
          - nested
        """)

        #expect(blocks == [.list([
            MarkdownListItem(depth: 0, marker: "•", text: "first"),
            MarkdownListItem(depth: 1, marker: "•", text: "nested"),
        ])])

        #expect(Markdown.blocks("2. second") == [.list([
            MarkdownListItem(depth: 0, marker: "2.", text: "second"),
        ])])

        #expect(Markdown.blocks("- [x] done") == [.list([
            MarkdownListItem(depth: 0, marker: "☑", text: "done"),
        ])])
    }

    @Test("a table is squared off so no row can shift a column")
    func tables() {
        let blocks = Markdown.blocks("""
        | Model | Cost |
        |-------|------|
        | Opus  | high |
        | Haiku |
        """)

        #expect(blocks == [.table(
            header: ["Model", "Cost"],
            rows: [["Opus", "high"], ["Haiku", ""]])])
    }

    /// The rule under the header is what makes it a table. Without that test a
    /// shell pipeline becomes a one-column table with the command as its
    /// heading.
    @Test("a piped command is not a table")
    func pipesAreNotAlwaysTables() {
        let blocks = Markdown.blocks("git status | grep modified")

        #expect(blocks == [.paragraph("git status | grep modified")])
    }

    @Test("headings, quotes and rules are recognised")
    func otherBlocks() {
        let blocks = Markdown.blocks("""
        ## What is wrong

        > the build is red

        ---
        """)

        #expect(blocks == [
            .heading(level: 2, text: "What is wrong"),
            .quote("the build is red"),
            .divider,
        ])
    }

    /// CommonMark folds a single newline into a space. Here the newline is
    /// usually the model listing things one per line, and folding them produces
    /// a wall of text.
    @Test("a paragraph keeps the line breaks the model wrote")
    func paragraphsKeepLineBreaks() {
        let blocks = Markdown.blocks("""
        Sources/main.swift
        Tests/mainTests.swift
        """)

        #expect(blocks == [.paragraph("Sources/main.swift\nTests/mainTests.swift")])
    }

    /// Nothing a model can write may cost the user their answer.
    @Test("unbalanced punctuation still yields the text")
    func malformedInputSurvives() {
        #expect(Markdown.blocks("see [the docs(https://example.com") == [
            .paragraph("see [the docs(https://example.com"),
        ])
        #expect(Markdown.blocks("").isEmpty)
        #expect(Markdown.blocks("\n\n  \n").isEmpty)
    }
}
