import Foundation
import MCACore
import MCAReasoning
import MCASensing
import Testing

@Suite("Screen privacy across authorization and tools")
struct ScreenPrivacyAuthorizationTests {
    @Test("AX workspace navigation cannot leave the pinned window", arguments: ["browser_navigate", "browser_tabs"])
    func pinnedWorkspaceOpen(_ name: String) async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]], kind: .accessibility)
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let pin = PinnedWindow(id: 123, appName: "Fixture", windowTitle: "Public", bundleID: "fixture.browser", processID: getpid())
        let session = ActionAuthorization(goal: "Open URL", requestApproval: { _ in .approved }, targetWindow: pin, requiresWindowScope: true)
        let registry = ToolRegistry(tools: [BrowserNavigateTool(session: browser), BrowserTabsTool(session: browser)])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: name, name: name,
                arguments: Data((name == "browser_navigate" ? #"{"url":"https://example.test/new"}"# : #"{"action":"new","url":"https://example.test/new"}"#).utf8)))
        }
        #expect(result.content.contains("selected window"))
        #expect(await driver.navigatedURLs.isEmpty)
        #expect(await driver.openedTabURLs.isEmpty)
    }

    @Test("Pinned browser switching is refused before dispatch even when approved")
    func pinnedSwitch() async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let pin = PinnedWindow(id: 123, appName: "Fixture", windowTitle: "Public",
                               bundleID: "fixture.browser", processID: getpid())
        let session = ActionAuthorization(goal: "Switch", requestApproval: { _ in .approved },
                                          targetWindow: pin, requiresWindowScope: true)
        let registry = ToolRegistry(tools: [BrowserTabsTool(session: browser)])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "switch", name: "browser_tabs",
                arguments: Data(#"{"action":"switch","id":"t2"}"#.utf8)))
        }
        #expect(result.content.contains("selected window"))
        #expect(await driver.switchedTabIDs.isEmpty)
    }

    @Test("Rejected and cancelled switching have no side effect", arguments: [ActionApprovalStatus.rejected, .cancelled])
    func deniedSwitch(_ status: ActionApprovalStatus) async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]])
        await driver.setTabs([BrowserTab(id: "t1", url: "https://example.test/", title: "Fake", isActive: true),
                              BrowserTab(id: "t2", url: "https://example.test/other", title: "Other", isActive: false)])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let session = ActionAuthorization(goal: "Switch", requestApproval: { _ in status })
        let registry = ToolRegistry(tools: [BrowserTabsTool(session: browser)])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "switch", name: "browser_tabs",
                arguments: Data(#"{"action":"switch","id":"t2"}"#.utf8)))
        }
        #expect(result.content.contains("no action was executed"))
        #expect(await driver.switchedTabIDs.isEmpty)
    }

    @Test("Tab listing does not export excluded window metadata")
    func excludedTabList() async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]])
        await driver.setTabs([
            BrowserTab(id: "t1", url: "https://example.test/public", title: "Public", isActive: true),
            BrowserTab(id: "t2", url: "https://example.test/private-detail", title: "Confidential account", isActive: false)
        ])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let session = ActionAuthorization(goal: "List public tabs", requestApproval: { _ in .rejected },
            privacyConfiguration: AgentConfiguration(excludedWindowPatterns: ["confidential"]))
        let registry = ToolRegistry(tools: [BrowserTabsTool(session: browser)])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "list", name: "browser_tabs", arguments: Data("{}".utf8)))
        }
        #expect(result.content.contains("Public"))
        #expect(!result.content.contains("Confidential"))
        #expect(!result.content.contains("private-detail"))
    }

    @Test("Cancellation after approval stops switch dispatch")
    func cancelledAfterApproval() async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let session = ActionAuthorization(goal: "Switch", requestApproval: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .approved
        })
        let registry = ToolRegistry(tools: [BrowserTabsTool(session: browser)])
        await driver.setTabs([BrowserTab(id: "t1", url: "https://example.test/", title: "Fake", isActive: true)])
        _ = await Task {
            await ActionAuthorization.withSession(session) {
                await registry.invoke(ToolCall(id: "switch", name: "browser_tabs",
                    arguments: Data(#"{"action":"switch","id":"t1"}"#.utf8)))
            }
        }.value
        #expect(await driver.switchedTabIDs.isEmpty)
    }

    @Test("Approved switching revalidates destination metadata before dispatch", arguments: [false, true])
    func destinationDrift(_ drift: Bool) async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let tabs = [BrowserTab(id: "t1", url: "https://example.test/", title: "Fake", isActive: true),
                    BrowserTab(id: "t2", url: "https://example.test/other", title: "Other", isActive: false)]
        await driver.setTabs(tabs)
        let session = ActionAuthorization(goal: "Switch", requestApproval: { request in
            #expect(request.details.contains("https://example.test/other"))
            if drift {
                await driver.setTabs([tabs[0], BrowserTab(id: "t2", url: "https://example.test/changed", title: "Changed", isActive: false)])
            }
            return .approved
        })
        let registry = ToolRegistry(tools: [BrowserTabsTool(session: browser)])
        _ = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "switch", name: "browser_tabs",
                arguments: Data(#"{"action":"switch","id":"t2"}"#.utf8)))
        }
        #expect(await driver.switchedTabIDs == (drift ? [] : ["t2"]))
    }

    @Test("Pinned tab listing includes only the selected active window")
    func pinnedTabList() async throws {
        let driver = FakeBrowserDriver(outlines: ["public"], refs: [[:]])
        await driver.setTabs([BrowserTab(id: "t1", url: "https://example.test/", title: "Fake", isActive: true),
                              BrowserTab(id: "t2", url: "https://example.test/unrelated", title: "Unrelated public window", isActive: false)])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let pin = PinnedWindow(id: 123, appName: "Fixture", windowTitle: "Public", bundleID: "fixture.browser", processID: getpid())
        let session = ActionAuthorization(goal: "List", requestApproval: { _ in .rejected }, targetWindow: pin, requiresWindowScope: true)
        let registry = ToolRegistry(tools: [BrowserTabsTool(session: browser)])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: "list", name: "browser_tabs", arguments: Data("{}".utf8)))
        }
        #expect(result.content.contains("Fake"))
        #expect(!result.content.contains("Unrelated"))
        #expect(!result.content.contains("unrelated"))
    }

    @Test("Navigation during a read cannot export excluded page content", arguments: ["browser_read", "browser_snapshot"])
    func navigationDuringRead(_ name: String) async throws {
        let driver = FakeBrowserDriver(outlines: ["fake text"], refs: [[:]])
        await driver.changeTitleDuringRead(to: "Confidential")
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let session = ActionAuthorization(goal: "Read public page", requestApproval: { _ in .rejected },
            privacyConfiguration: AgentConfiguration(excludedWindowPatterns: ["confidential"]))
        let registry = ToolRegistry(tools: [BrowserSnapshotTool(session: browser), BrowserReadTool(session: browser)])
        let result = await ActionAuthorization.withSession(session) {
            await registry.invoke(ToolCall(id: name, name: name, arguments: Data("{\"what\":\"text\"}".utf8)))
        }
        #expect(result.content.contains("excluded"))
        #expect(!result.content.contains("fake text"))
        #expect(await browser.lastSnapshot == nil)
    }
    @Test("The default inspector factory refuses a custom-excluded target before inspecting another window")
    func inspectorPolicy() async throws {
        let pinned = PinnedWindow(id: UInt32.max, appName: "Fixture", windowTitle: "Confidential document",
            bundleID: "fixture.browser", processID: nil)
        let session = ActionAuthorization(goal: "Explain this page", requestApproval: { _ in .rejected },
            targetWindow: pinned, requiresWindowScope: true,
            privacyConfiguration: AgentConfiguration(excludedWindowPatterns: ["confidential"]))
        await ActionAuthorization.withSession(session) {
            do {
                _ = try await InspectUIElementsTool.makeDefaultInspector().captureSnapshot()
                Issue.record("The excluded target was inspected")
            } catch {
                #expect(error.localizedDescription.contains("excluded"))
            }
        }
    }

    @Test("A browser session cannot export an excluded live page")
    func browserPolicy() async throws {
        let driver = FakeBrowserDriver(outlines: ["confidential body must never reach the model"], refs: [[:]])
        let browser = BrowserSession(drivers: [driver], inference: nil)
        let session = ActionAuthorization(goal: "Explain the public page", requestApproval: { _ in .rejected },
            privacyConfiguration: AgentConfiguration(excludedWindowPatterns: ["fake"]))
        await ActionAuthorization.withSession(session) {
            await #expect(throws: (any Error).self) {
                _ = try await browser.snapshot()
            }
        }
        #expect(await browser.lastSnapshot == nil)
        #expect(await driver.snapshotIndex == 0)
        let registry = ToolRegistry(tools: [BrowserSnapshotTool(session: browser), BrowserReadTool(session: browser)])
        for (name, arguments) in [("browser_snapshot", "{}"), ("browser_read", "{\"what\":\"text\"}")] {
            let result = await ActionAuthorization.withSession(session) {
                await registry.invoke(ToolCall(id: name, name: name, arguments: Data(arguments.utf8)))
            }
            #expect(result.content.contains("excluded"))
            #expect(!result.content.contains("confidential body"))
            #expect(!result.content.contains("fake text"))
        }
    }
}
