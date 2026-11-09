import MCACore
@testable import MCASensing
import Testing

/// An element kept alive by a page that reuses it for other content must not be acted
/// on under the ref of what it showed before.
@Suite("AX ref identity")
struct AXRefIdentityTests {
    private let ref = BrowserElementRef(id: "0-12", role: "button", name: "Reply", frameOrdinal: 0)
    private let recorded = AXBrowserDriver.ElementIdentity(role: "button", name: "Reply")

    @Test("an element that now shows another name or role is a stale ref",
          arguments: [AXBrowserDriver.ElementIdentity(role: "button", name: "Delete"),
                      AXBrowserDriver.ElementIdentity(role: "link", name: "Reply"),
                      AXBrowserDriver.ElementIdentity(role: "button", name: nil)])
    func changedIdentityIsStale(_ live: AXBrowserDriver.ElementIdentity) {
        do {
            try AXBrowserDriver.requireSameIdentity(ref, recorded: recorded, live: live, knownRefs: 30)
            Issue.record("\(live) must not pass as \(recorded)")
        } catch BrowserError.staleRef(let id, let available) {
            #expect(id == "0-12" && available == 30)
        } catch {
            Issue.record("expected staleRef, got \(error)")
        }
    }

    @Test("the same identity passes, and an unreadable or unrecorded one is left to the later checks")
    func sameOrUnknownPasses() throws {
        try AXBrowserDriver.requireSameIdentity(ref, recorded: recorded, live: recorded, knownRefs: 30)
        try AXBrowserDriver.requireSameIdentity(ref, recorded: recorded, live: nil, knownRefs: 30)
        try AXBrowserDriver.requireSameIdentity(ref, recorded: nil, live: recorded, knownRefs: 30)
    }
}
