import Foundation
import Testing

@testable import BatteryKit

/// `pmset -g custom` from a MacBook Pro M4 Pro on macOS 27.2 (Low Power on battery edited in).
private let customFixture = """
    Battery Power:
     Sleep On Power Button 1
     powermode            1
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         5
     womp                 0
     networkoversleep     0
     sleep                1
     lessbright           1
     tcpkeepalive         1
     disksleep            10
    AC Power:
     Sleep On Power Button 1
     powermode            2
     standby              1
     ttyskeepawake        1
     hibernatemode        3
     powernap             1
     hibernatefile        /var/vm/sleepimage
     displaysleep         10
     womp                 1
     networkoversleep     0
     sleep                1
     tcpkeepalive         1
     disksleep            0
    """

/// `pmset -g cap` on AC power (same Mac). It lists the current source only.
private let capACFixture = """
    Capabilities for AC Power:
     displaysleep
     disksleep
     sleep
     womp
     standby
     powernap
     ttyskeepawake
     hibernatemode
     hibernatefile
     tcpkeepalive
     lowpowermode
     highpowermode
    """

private let capBatteryNoHighPower = """
    Capabilities for Battery Power:
     displaysleep
     disksleep
     sleep
     standby
     lowpowermode
    """

@Suite("Energy Mode parsing")
struct EnergyModeParserTests {
    @Test func parsesPowermodePerSource() {
        let modes = EnergyModeParser.parseCustom(customFixture)
        #expect(modes[.battery] == .lowPower)
        #expect(modes[.ac] == .highPower)
    }

    @Test func automaticIsZero() {
        let text = "Battery Power:\n powermode            0\nAC Power:\n powermode 0\n"
        #expect(EnergyModeParser.parseCustom(text) == [.battery: .automatic, .ac: .automatic])
    }

    @Test func ignoresUnknownSectionsAndValues() {
        let text = "UPS Power:\n powermode 1\nAC Power:\n powermode 7\n sleep 1\n"
        #expect(EnergyModeParser.parseCustom(text).isEmpty)
    }

    @Test func legacyLowPowerModeKey() {
        let text = "Battery Power:\n lowpowermode         1\nAC Power:\n lowpowermode         0\n"
        #expect(EnergyModeParser.parseCustom(text) == [.battery: .lowPower, .ac: .automatic])
    }

    @Test func noPowermodeMeansEmpty() {
        let text = "AC Power:\n sleep                1\n displaysleep         10\n"
        #expect(EnergyModeParser.parseCustom(text).isEmpty)
    }

    @Test func capabilitiesWithHighPower() {
        let caps = EnergyModeParser.parseCapabilities(capACFixture)
        #expect(caps == [.ac: [.automatic, .lowPower, .highPower]])
        let status = EnergyModeStatus(modes: [:], capabilities: caps)
        #expect(status.supportedModes(for: .ac) == [.automatic, .lowPower, .highPower])
    }

    @Test func capabilitiesWithoutHighPower() {
        let status = EnergyModeStatus(
            modes: [:], capabilities: EnergyModeParser.parseCapabilities(capBatteryNoHighPower))
        #expect(status.supportedModes(for: .battery) == [.automatic, .lowPower])
    }

    @Test func unknownSourceFallsBackToAutomaticAndLowPower() {
        let status = EnergyModeStatus(modes: [:], capabilities: EnergyModeParser.parseCapabilities(capACFixture))
        #expect(status.supportedModes(for: .battery) == [.automatic, .lowPower])
    }

    @Test func capabilitiesForBothSections() {
        let caps = EnergyModeParser.parseCapabilities(capACFixture + "\n" + capBatteryNoHighPower)
        #expect(caps[.ac]?.contains(.highPower) == true)
        #expect(caps[.battery] == [.automatic, .lowPower])
    }
}

@Suite("Energy Mode command")
struct EnergyModeCommandTests {
    @Test func commandUsesFlagAndRawValue() {
        #expect(EnergyModeControl.command(setting: .highPower, for: .ac) == "/usr/bin/pmset -c powermode 2")
        #expect(EnergyModeControl.command(setting: .lowPower, for: .battery) == "/usr/bin/pmset -b powermode 1")
        #expect(EnergyModeControl.command(setting: .automatic, for: .battery) == "/usr/bin/pmset -b powermode 0")
    }

    @Test func appleScriptWrapsCommand() {
        #expect(
            EnergyModeControl.appleScriptSource(setting: .automatic, for: .ac)
                == "do shell script \"/usr/bin/pmset -c powermode 0\" with administrator privileges")
    }
}

@Suite("Charge limit status")
struct ChargeLimitStatusTests {
    @Test func heldPercentOnlyWhenEnabledAndHolding() {
        #expect(
            ChargeLimitStatus(isEnabled: true, limitPercent: 80, isHoldingCharge: true, overrideAllowed: true)
                .heldAtPercent == 80)
        #expect(
            ChargeLimitStatus(isEnabled: true, limitPercent: 80, isHoldingCharge: false, overrideAllowed: true)
                .heldAtPercent == nil)
        #expect(
            ChargeLimitStatus(isEnabled: false, limitPercent: 80, isHoldingCharge: true, overrideAllowed: true)
                .heldAtPercent == nil)
    }
}
