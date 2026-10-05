import Foundation
import MCACore
import MCAReasoning
import Testing

@Suite("Browser authorization boundary")
struct BrowserAuthorizationTests {
    @Test("Ungrounded keyboard focus is refused even after operation approval")
    func unknownKeyboardFocus() async throws {
        let driver = driver(), browser = BrowserSession(drivers: [driver], inference: nil)
        _ = try await browser.snapshot()
        let session = ActionAuthorization(goal: "Submit", requestApproval: { _ in .approved })
        await #expect(throws: BrowserError.self) {
            try await ActionAuthorization.$current.withValue(session) {
                try await browser.perform(BrowserAction(method: .press, arguments: ["Enter"]))
            }
        }
        #expect(await driver.performed.isEmpty)
    }
    private let element = BrowserElementRef(id: "0-1", role: "button", name: "Submit")
    private func driver(changed: Bool = false) -> FakeBrowserDriver {
        FakeBrowserDriver(outlines: changed ? ["Submit", "Delete"] : ["Submit"],
                          refs: changed ? [["0-1": element], ["0-1": element]] : [["0-1": element]])
    }
    @Test("A direct mutating browser call cannot bypass approval")
    func directCall() async throws {
        let driver = driver(), browser = BrowserSession(drivers: [driver], inference: nil)
        _ = try await browser.snapshot()
        await #expect(throws: ActionAuthorizationError.approvalRequired) {
            try await browser.perform(BrowserAction(method: .click, elementID: "0-1"))
        }
        #expect(await driver.performed.isEmpty)
    }
    @Test("Rejection stops before dispatch and freezes the task")
    func rejection() async throws {
        let driver = driver(), browser = BrowserSession(drivers: [driver], inference: nil)
        _ = try await browser.snapshot()
        let session = ActionAuthorization(goal: "Send form", requestApproval: { request in
            #expect(request.target.contains("example.test"))
            #expect(request.operation.contains("click"))
            return .rejected
        })
        await #expect(throws: ActionAuthorizationError.denied) {
            try await ActionAuthorization.$current.withValue(session) {
                try await browser.perform(BrowserAction(method: .click, elementID: "0-1"))
            }
        }
        #expect(await driver.performed.isEmpty)
        #expect(await session.terminalFailure != nil)
    }
    @Test("Changed screen content invalidates an approved browser operation")
    func drift() async throws {
        let driver = driver(changed: true), browser = BrowserSession(drivers: [driver], inference: nil)
        _ = try await browser.snapshot()
        let session = ActionAuthorization(goal: "Send form", requestApproval: { _ in .approved })
        await #expect(throws: ActionAuthorizationError.staleTarget) {
            try await ActionAuthorization.$current.withValue(session) {
                try await browser.perform(BrowserAction(method: .click, elementID: "0-1"))
            }
        }
        #expect(await driver.performed.isEmpty)
    }
    @Test("Page scrolling uses the observed page without requesting mutation approval")
    func safeScroll() async throws {
        let driver = driver(), browser = BrowserSession(drivers: [driver], inference: nil)
        _ = try await browser.snapshot()
        _ = try await browser.perform(BrowserAction(method: .nextChunk))
        #expect(await driver.performed.count == 1)
    }
}
