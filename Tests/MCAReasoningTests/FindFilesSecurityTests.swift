import Foundation
import Testing

@testable import MCAReasoning

@Suite("find_files argument handling")
struct FindFilesSecurityTests {
    @Test("a leading dash is quoted so mdfind cannot read it as an option", arguments: [
        "-live", "-attr", "-onlyin /", "  -count",
    ])
    func quotesLeadingDash(_ query: String) {
        let quoted = FindFilesTool.mdfindQuery(query)
        #expect(!quoted.hasPrefix("-"))
        #expect(quoted.hasPrefix("\"") && quoted.hasSuffix("\""))
    }

    @Test("quotes inside a dash-led query are escaped")
    func escapesQuotes() {
        #expect(FindFilesTool.mdfindQuery("-a\"b") == "\"-a\\\"b\"")
    }

    @Test("an ordinary query passes through untouched")
    func ordinaryQueryUnchanged() {
        #expect(FindFilesTool.mdfindQuery("budget *.xlsx") == "budget *.xlsx")
    }

    @Test("the query is always the last argument, after -onlyin")
    func argumentOrder() {
        #expect(FindFilesTool.mdfindArguments(query: "-live", inDirectory: "/tmp") == ["-onlyin", "/tmp", "\"-live\""])
        #expect(FindFilesTool.mdfindArguments(query: "notes", inDirectory: nil) == ["notes"])
    }

    @Test("a child that outlives the timeout is killed")
    func timesOut() throws {
        let started = Date()
        let result = try FindFilesTool.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("output of a child that finishes in time is returned")
    func returnsOutput() throws {
        let result = try FindFilesTool.run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 5)
        #expect(!result.timedOut)
        #expect(result.output == "hello\n")
    }

    @Test("output larger than a pipe buffer does not stall the child")
    func largeOutput() throws {
        // 1 MB is far past the 64 KB pipe buffer: if the pipe were not drained
        // while the child runs, `head` would block on write and only the timeout
        // would end it. A bounded writer keeps the test independent of how fast
        // a loaded machine starts the child (an endless `yes` cut at 0.5 s
        // sometimes produced nothing at all).
        let result = try FindFilesTool.run(
            executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1000000", "/dev/zero"], timeout: 10)
        #expect(!result.timedOut)
        #expect(result.output.utf8.count == 1_000_000)
    }
}
