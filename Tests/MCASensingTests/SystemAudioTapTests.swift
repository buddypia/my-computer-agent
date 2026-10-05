import Foundation
import Testing

@testable import MCACore
@testable import MCASensing

@Suite("System audio tap")
struct SystemAudioTapTests {
    @Test("default tap uses global scope")
    func defaultTapUsesGlobalScope() {
        let tap = SystemAudioTap()
        #expect(tap.scope == .global(excludedPIDs: []))
    }

    @Test("custom excluded PIDs are respected in global scope")
    func excludedPIDsRespected() {
        let tap = SystemAudioTap(excludedPIDs: [100, 200])
        #expect(tap.scope == .global(excludedPIDs: [100, 200]))
    }

    @Test("targeted process scope captures specific PIDs")
    func targetedProcessScope() {
        let tap = SystemAudioTap(targetPIDs: [1234, 5678])
        #expect(tap.scope == .processes([1234, 5678]))
    }

    @Test("target scope equality")
    func targetScopeEquality() {
        let scope1 = SystemAudioTap.TargetScope.processes([42])
        let scope2 = SystemAudioTap.TargetScope.processes([42])
        let scope3 = SystemAudioTap.TargetScope.global(excludedPIDs: [42])

        #expect(scope1 == scope2)
        #expect(scope1 != scope3)
    }
}
