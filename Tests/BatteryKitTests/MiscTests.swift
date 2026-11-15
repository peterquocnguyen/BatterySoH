import Foundation
import Testing
@testable import BatteryKit

@Suite("MacInfo")
struct MacInfoTests {
    @Test func splitsDetailInParentheses() {
        let (name, detail) = MacInfo.splitProductName("MacBook Pro (14-inch, Nov 2024)")
        #expect(name == "MacBook Pro")
        #expect(detail == "14-inch, Nov 2024")
    }

    @Test func splitsAirWithSpaces() {
        let (name, detail) = MacInfo.splitProductName("MacBook Air (13-inch, M3, 2024)")
        #expect(name == "MacBook Air")
        #expect(detail == "13-inch, M3, 2024")
    }

    @Test(arguments: ["MacBook Pro", "Mac16,8", "Weird (unclosed", ""])
    func noDetail(_ full: String) {
        let (name, detail) = MacInfo.splitProductName(full)
        #expect(name == full)
        #expect(detail == nil)
    }
}

@Suite("SMC four-char codes")
struct SMCTests {
    @Test func fourCCValue() {
        #expect(SMC.fourCC("TB0T") == 0x5442_3054)
        #expect(SMC.fourCC("flt ") == 0x666C_7420)
    }

    @Test(arguments: ["TB0T", "TB1T", "TB2T", "flt ", "sp78", "ui8 ", "ui16", "PSTR"])
    func roundTrip(_ key: String) throws {
        let code = try #require(SMC.fourCC(key))
        #expect(SMC.string(fromFourCC: code) == key)
    }

    @Test(arguments: ["", "TB0", "TB0TX"])
    func wrongLengthIsNil(_ key: String) {
        #expect(SMC.fourCC(key) == nil)
    }

    /// The kernel's SMCParamStruct is 80 bytes; a layout drift breaks every SMC read.
    @Test func paramStructMatchesKernelLayout() {
        #expect(SMC.paramStructSize == 80)
    }
}
