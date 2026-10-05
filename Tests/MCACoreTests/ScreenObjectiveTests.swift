import MCACore
import Testing

@Suite("Screen objective identity")
struct ScreenObjectiveTests {
    @Test("An objective acts once per observation and cannot migrate to another window")
    func identityAndDeduplication() {
        let target = PinnedWindow(id: 10, appName: "Meeting", windowTitle: "Slides", processID: 44)
        var session = ScreenObjective(text: "Collect action items", target: target)
        let first = session.claim(fingerprint: "slide1", target: target)
        #expect(first)
        let repeatClaim = session.claim(fingerprint: "slide1", target: target)
        #expect(!repeatClaim)
        var other = target; other.id = 11
        let wrongWindow = session.claim(fingerprint: "slide2", target: other)
        #expect(!wrongWindow)
        let second = session.claim(fingerprint: "slide2", target: target)
        #expect(second)
        session.stop()
        let afterStop = session.claim(fingerprint: "slide3", target: target)
        #expect(!afterStop)
    }
}
