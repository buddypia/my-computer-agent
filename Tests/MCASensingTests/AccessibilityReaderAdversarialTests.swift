import AppKit
import ApplicationServices
import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("AccessibilityReader Adversarial & Stress Suite")
struct AccessibilityReaderAdversarialTests {

    @Test("traversalBudget handles negative, zero, and extreme values safely")
    func testTraversalBudgetBoundaries() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Negative budget (should default to at least 1ms internally without negative deadline)
        let negativeReader = AccessibilityReader(traversalBudget: -10.0)
        let snap1 = await negativeReader.readWindowAsync(pid: ownPID)
        #expect(snap1 != nil)
        #expect(snap1?.elementCount == 0)

        // Zero budget
        let zeroReader = AccessibilityReader(traversalBudget: 0.0)
        let snap2 = await zeroReader.readWindowAsync(pid: ownPID)
        #expect(snap2 != nil)
        #expect(snap2?.elementCount == 0)

        // Micro budget (1ms)
        let microReader = AccessibilityReader(traversalBudget: 0.001)
        let snap3 = await microReader.readWindowAsync(pid: ownPID)
        #expect(snap3 != nil)
        #expect(snap3?.elementCount == 0)

        // Huge budget
        let hugeReader = AccessibilityReader(traversalBudget: 1000.0)
        let snap4 = await hugeReader.readWindowAsync(pid: ownPID)
        #expect(snap4 != nil)
        #expect(snap4?.elementCount == 0)
    }

    @Test("readWindowAsync with own process PID is concurrency-safe and never triggers main thread assertion")
    func testOwnProcessPIDConcurrency() async {
        let reader = AccessibilityReader()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        await withTaskGroup(of: AccessibilityReader.Snapshot?.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await reader.readWindowAsync(pid: ownPID)
                }
            }
            var count = 0
            for await snap in group {
                #expect(snap != nil)
                #expect(snap?.elementCount == 0)
                #expect(snap?.text.isEmpty == true)
                count += 1
            }
            #expect(count == 50)
        }
    }

    @Test("invalid and dead PIDs return nil or safe empty snapshot immediately without hanging")
    func testInvalidPIDsFailFastIsolated() async {
        let reader = AccessibilityReader(traversalBudget: 0.2)

        let invalidPIDs: [pid_t] = [-1, -999, 999_999, 0]
        for pid in invalidPIDs {
            let start = DispatchTime.now()
            let snapshot = await reader.readWindowAsync(pid: pid)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

            // If NSRunningApplication doesn't exist for the PID, readWindow returns nil
            #expect(snapshot == nil || snapshot?.elementCount == 0)
            if IsolatedTiming.enabled {
                #expect(elapsedMs < 300, "Reading invalid PID \(pid) took too long: \(elapsedMs)ms")
            }
        }
    }

    @Test("traversalBudget halts tree walking promptly on active running apps")
    func testTraversalBudgetHaltsPromptlyIsolated() async {
        // Query running applications
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.activationPolicy == .regular
        }

        guard let targetApp = runningApps.first else {
            // No regular running apps found; pass
            return
        }

        // Test with tight budget of 50ms (0.05s)
        let tightReader = AccessibilityReader(traversalBudget: 0.05)
        let start = DispatchTime.now()
        _ = await tightReader.readWindowAsync(pid: targetApp.processIdentifier)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

        // With 50ms budget + 500ms messaging timeout, total wall-clock time should be strictly bounded
        if IsolatedTiming.enabled {
            #expect(elapsedMs < 1200, "Tight budget execution exceeded bound: \(elapsedMs)ms")
        }
    }

    @Test("readFocusedWindowAsync retrieves snapshot asynchronously without deadlocking MainActor")
    func testReadFocusedWindowAsyncNonBlocking() async {
        let reader = AccessibilityReader(traversalBudget: 0.5)

        let snap = await reader.readFocusedWindowAsync()
        // Frontmost window might be nil or valid snapshot depending on system state, but must return cleanly
        if let snap {
            #expect(snap.elementCount >= 0)
        }
    }

    @Test("high contention parallel readWindowAsync calls do not deadlock or crash")
    func testHighContentionParallelReads() async {
        let reader = AccessibilityReader(traversalBudget: 0.2)
        let pids: [pid_t] = NSWorkspace.shared.runningApplications.prefix(5).map(\.processIdentifier)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                let pid = pids[i % pids.count]
                group.addTask {
                    _ = await reader.readWindowAsync(pid: pid)
                }
            }
            await group.waitForAll()
        }
    }
}
