import Foundation
import os
@testable import mca
import Testing

@Suite("MainThreadWatchdog diagnostics and recovery")
struct MainThreadWatchdogTests {

    @Test("Responsive target queue does not trigger onHang")
    func responsiveTargetQueue() async throws {
        let testQueue = DispatchQueue(label: "com.buddypia.mca.test-watchdog-responsive")
        let hangCalled = OSAllocatedUnfairLock(initialState: false)

        let watchdog = MainThreadWatchdog(
            targetQueue: testQueue,
            timeoutSeconds: 1,
            pollIntervalSeconds: 1,
            onHang: { _ in
                hangCalled.withLock { $0 = true }
            }
        )

        watchdog.start()
        try await Task.sleep(for: .milliseconds(300))
        watchdog.stop()

        let wasHangCalled = hangCalled.withLock { $0 }
        #expect(!wasHangCalled)
    }

    @Test("Blocked target queue triggers onHang and onRecovered after unblock")
    func blockedQueueTriggersHangAndRecovery() async throws {
        let testQueue = DispatchQueue(label: "com.buddypia.mca.test-watchdog-hang")
        let blockSemaphore = DispatchSemaphore(value: 0)

        // Block the testQueue before starting
        testQueue.async {
            blockSemaphore.wait()
        }

        let hangTriggered = OSAllocatedUnfairLock(initialState: false)
        let recoveredTriggered = OSAllocatedUnfairLock(initialState: false)

        let watchdog = MainThreadWatchdog(
            targetQueue: testQueue,
            timeoutSeconds: 1,
            pollIntervalSeconds: 1,
            onHang: { _ in
                hangTriggered.withLock { $0 = true }
            },
            onRecovered: { _ in
                recoveredTriggered.withLock { $0 = true }
            }
        )

        watchdog.start()

        // Wait until watchdog detects the 1-second timeout
        var didHang = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let isHung = hangTriggered.withLock { $0 }
            if isHung {
                didHang = true
                break
            }
        }
        #expect(didHang)

        // Unblock the queue so recovery triggers
        blockSemaphore.signal()

        var didRecover = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let isRecovered = recoveredTriggered.withLock { $0 }
            if isRecovered {
                didRecover = true
                break
            }
        }
        #expect(didRecover)

        watchdog.stop()
    }
}
