import CoreGraphics
import Synchronization
import Testing

@testable import MCACore

@Suite("Agent input feedback", .serialized)
struct AgentInputFeedbackTests {
    @Test("reports reach the installed sink, and nothing after it is removed")
    func sink() {
        let received = Mutex<[AgentInputActivity]>([])
        AgentInputFeedback.install { activity in received.withLock { $0.append(activity) } }
        AgentInputFeedback.report(.move(CGPoint(x: 1, y: 2)))
        AgentInputFeedback.report(.keyboard)
        AgentInputFeedback.install(nil)
        AgentInputFeedback.report(.released)
        #expect(received.withLock { $0 } == [.move(CGPoint(x: 1, y: 2)), .keyboard])
    }

    @Test("only the agent's tag counts as agent input")
    func tag() {
        #expect(AgentInputFeedback.isAgentGenerated(userData: AgentInputFeedback.eventSourceTag))
        #expect(!AgentInputFeedback.isAgentGenerated(userData: 0))
    }
}
