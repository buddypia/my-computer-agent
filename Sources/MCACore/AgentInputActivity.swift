import CoreGraphics
import Synchronization

/// One piece of input the agent is about to send to the desktop, in global
/// Quartz coordinates (origin at the top-left of the primary display).
///
/// Reported so the presentation layer can show *where* the agent is acting —
/// its own cursor, a ripple on a click — the way a person watching over a
/// shoulder would see a second pointer. It carries no text: what is typed is
/// not drawn, only that typing happened.
public enum AgentInputActivity: Sendable, Equatable {
    case move(CGPoint)
    case click(CGPoint, count: Int, secondary: Bool)
    case drag(from: CGPoint, to: CGPoint)
    case scroll(CGPoint)
    case keyboard
    /// The agent let go of every held button and key (an emergency release).
    case released
}

/// The seam between the event synthesizer (Sensing) and whatever draws the
/// agent's activity (Presentation). Sensing reports; the composition root
/// installs a sink. With no sink installed — `mca mcp`, `mca act`, tests —
/// reporting costs one lock and does nothing.
public enum AgentInputFeedback {
    /// Stamped into `CGEventField.eventSourceUserData` of every event the
    /// agent posts. Lets the UI tell the agent's input apart from the user's:
    /// a stop control must not be pressed by the very agent it stops, even
    /// though the agent cannot see it (it is excluded from screenshots).
    public static let eventSourceTag: Int64 = 0x4D_43_41 // "MCA"

    public typealias Sink = @Sendable (AgentInputActivity) -> Void

    private static let sink = Mutex<Sink?>(nil)

    /// Installs (or with `nil`, removes) the single receiver of activity.
    public static func install(_ newSink: Sink?) {
        sink.withLock { $0 = newSink }
    }

    /// Called from whichever thread is synthesizing input. The sink must not
    /// block: it is on the path of every click.
    public static func report(_ activity: AgentInputActivity) {
        let current = sink.withLock { $0 }
        current?(activity)
    }

    /// Whether an event's user-data field carries the agent's tag.
    public static func isAgentGenerated(userData: Int64) -> Bool {
        userData == eventSourceTag
    }
}
