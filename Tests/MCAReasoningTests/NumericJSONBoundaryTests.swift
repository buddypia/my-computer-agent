import Foundation
import Testing
@testable import MCAReasoning

@Suite("Shared numeric JSON boundaries")
struct NumericJSONBoundaryTests {
    @Test("Malformed integer arguments do not become truncated or trapping values")
    func invalidValues() throws {
        for value in ["1e100", "-1e100", "1.5", "true", "false", "null"] {
            let object = try #require(parseJSONObject("{\"value\":\(value)}"))
            #expect(object.int("value") == nil)
        }
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(["value": value as Any].int("value") == nil)
        }
    }
    @Test("Representable integer boundaries retain their exact values")
    func validValues() throws {
        for value in [Int.min, -1, 0, 1, 25, 100, Int.max] {
            let object = try #require(parseJSONObject("{\"value\":\(value)}"))
            #expect(object.int("value") == value)
        }
        #expect(["value": 25.0 as Any].int("value") == 25)
    }
}
