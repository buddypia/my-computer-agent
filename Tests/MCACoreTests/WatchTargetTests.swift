import Foundation
import Testing

@testable import MCACore

/// Pinning is the point at which the watch stops following the user and starts
/// looking at one window on its own — including windows the user cannot see. The
/// refusals are therefore a privacy boundary, not a convenience check.
@Suite("Watch target")
struct WatchTargetTests {
    private let window = PinnedWindow(
        id: 41773, appName: "Terminal", windowTitle: "swift build", bundleID: "com.apple.Terminal")

    private let display = PinnedDisplay(
        id: 1, name: "Built-in Retina Display", width: 3024, height: 1964)

    @Test("a pinned target reports the window it holds")
    func pinnedCarriesItsWindow() {
        let target = WatchTarget.pinned(window)

        #expect(target.isPinned)
        #expect(target.pinnedWindow == window)
        #expect(target.pinnedDisplay == nil)
        #expect(WatchTarget.focused.pinnedWindow == nil)
        #expect(!WatchTarget.focused.isPinned)
    }

    /// A display is pinned in the same sense a window is — held still — so it
    /// has to read as pinned everywhere the interface asks. Getting this wrong
    /// would draw an unpinned pin over a watch that is very much pinned.
    @Test("a pinned display is pinned, and is not a window")
    func displayIsPinnedButNotAWindow() {
        let target = WatchTarget.display(display)

        #expect(target.isPinned)
        #expect(target.pinnedDisplay == display)
        #expect(target.pinnedWindow == nil)
    }

    @Test("only a pinned target names a subject")
    func subjectNameFollowsTheCase() {
        #expect(WatchTarget.focused.subjectName == nil)
        #expect(WatchTarget.pinned(window).subjectName == "Terminal — swift build")
        #expect(WatchTarget.display(display).subjectName == "Built-in Retina Display")
    }

    /// Two monitors of the same model report the same name, so the number is
    /// what keeps them apart when macOS gives up on naming them.
    @Test("an unnamed display is still identifiable")
    func displayNameFallsBackToItsNumber() {
        let unnamed = PinnedDisplay(id: 7, name: "", width: 1920, height: 1080)

        #expect(unnamed.displayName == "Display 7")
        #expect(unnamed.resolution == "1920×1080")
    }

    /// The picker holds one thumbnail per row and re-photographs them every few
    /// seconds. Keying those by the whole value would miss the cache the moment
    /// a browser navigated — blanking a tile the user was looking at, which
    /// reads as the window having closed.
    @Test("a thumbnail key survives the window renaming itself")
    func keyIgnoresTheTitle() {
        let navigated = PinnedWindow(
            id: 41773, appName: "Terminal", windowTitle: "swift test",
            bundleID: "com.apple.Terminal")

        #expect(WatchTarget.pinned(window).key == WatchTarget.pinned(navigated).key)
    }

    /// Two targets sharing a key would share a picture, which is the one failure
    /// a picker cannot survive: it would show the user a photograph of a window
    /// other than the one they are about to choose.
    @Test("different subjects get different keys")
    func keysAreDistinct() {
        let other = PinnedWindow(id: 9, appName: "Safari", windowTitle: "")
        let keys = Set([
            WatchTarget.focused.key,
            WatchTarget.pinned(window).key,
            WatchTarget.pinned(other).key,
            WatchTarget.display(display).key,
        ])

        #expect(keys.count == 4)
    }

    @Test("an empty list knows it is empty")
    func emptyList() {
        #expect(WatchTargetList.empty.isEmpty)
        #expect(!WatchTargetList(windows: [window]).isEmpty)
        #expect(!WatchTargetList(displays: [display]).isEmpty)
    }

    @Test("an untitled window is still named after its application")
    func displayNameFallsBackToTheApp() {
        let untitled = PinnedWindow(id: 1, appName: "Preview", windowTitle: "")

        #expect(untitled.displayName == "Preview")
        #expect(window.displayName == "Terminal — swift build")
    }

    @Test("an ordinary window can be pinned")
    func acceptsAnOrdinaryWindow() {
        #expect(PinRefusal.refusal(
            for: window, isOwnWindow: false, isExcluded: false) == nil)
    }

    /// Watching ourselves would photograph the agent's own advice and feed it
    /// back as if it were the user's work.
    @Test("this app's own window is refused")
    func refusesOwnWindow() {
        #expect(PinRefusal.refusal(
            for: window, isOwnWindow: true, isExcluded: false) == .ownWindow)
    }

    /// The exclusion list is where the user wrote down what must never be sent,
    /// and a shortcut pressed over the wrong window is exactly the accident it
    /// exists to catch. An explicit pin does not override it.
    @Test("an excluded app is refused, and says which one")
    func refusesExcludedApp() {
        #expect(PinRefusal.refusal(
            for: window, isOwnWindow: false, isExcluded: true) == .excluded(appName: "Terminal"))
    }

    @Test("nothing in front is refused rather than treated as a window")
    func refusesMissingWindow() {
        #expect(PinRefusal.refusal(
            for: nil, isOwnWindow: false, isExcluded: false) == .noWindow)
    }

    /// Both problems at once still produces one message, and it is the one that
    /// tells the user what to do differently — moving a different window to the
    /// front is actionable, while "this app is excluded" would send them to
    /// Settings to change something that was not the problem.
    @Test("our own window wins over the exclusion list")
    func ownWindowIsReportedFirst() {
        #expect(PinRefusal.refusal(
            for: window, isOwnWindow: true, isExcluded: true) == .ownWindow)
    }

    @Test("pinned window carries optional process ID")
    func pinnedWindowCarriesProcessID() {
        let withPID = PinnedWindow(
            id: 1234, appName: "Google Chrome", windowTitle: "Meet - test", bundleID: "com.google.Chrome", processID: 5678)
        #expect(withPID.processID == 5678)
        #expect(window.processID == nil)
    }
}
