import AppKit
import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("AccessibilityActuator tests")
struct AccessibilityActuatorTests {
    @Test("ActuatorError applicationBlocked provides clear description")
    func testApplicationBlockedErrorDescription() {
        let err = AccessibilityActuator.ActuatorError.applicationBlocked("1Password")
        #expect(err.errorDescription?.contains("1Password") == true)
        #expect(err.errorDescription?.contains("privacy blocklist") == true)
    }

    @Test("ActuatorError descriptions are well-formed")
    func testErrorDescriptions() {
        let permErr = AccessibilityActuator.ActuatorError.accessibilityPermissionDenied
        #expect(permErr.errorDescription?.contains("System Settings") == true)

        let notFoundErr = AccessibilityActuator.ActuatorError.applicationNotFound("DummyApp")
        #expect(notFoundErr.errorDescription?.contains("DummyApp") == true)

        let elemErr = AccessibilityActuator.ActuatorError.elementNotFound(query: "OK")
        #expect(elemErr.errorDescription?.contains("OK") == true)

        let actErr = AccessibilityActuator.ActuatorError.actionFailed("timeout")
        #expect(actErr.errorDescription?.contains("timeout") == true)
    }

    @Test("clickElement throws appropriate error when target app does not exist")
    func testTargetAppNotFound() {
        let actuator = AccessibilityActuator()
        #expect(throws: AccessibilityActuator.ActuatorError.self) {
            try actuator.clickElement(appName: "NonExistentApp99999", titleOrLabel: "Submit")
        }
    }
}
