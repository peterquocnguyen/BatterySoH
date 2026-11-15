import Foundation
import Testing

@testable import BatteryKit

@Suite("Fmt")
struct FormattingTests {
    @Test func dashIsEmDash() {
        #expect(Fmt.dash == "—")
    }

    @Test func nilRendersAsDash() {
        #expect(Fmt.watts(nil) == Fmt.dash)
        #expect(Fmt.watts(nil, signed: true) == Fmt.dash)
        #expect(Fmt.volts(mV: nil) == Fmt.dash)
        #expect(Fmt.amps(mA: nil) == Fmt.dash)
        #expect(Fmt.percent(nil) == Fmt.dash)
        #expect(Fmt.duration(minutes: nil) == Fmt.dash)
        #expect(Fmt.temperature(nil) == Fmt.dash)
        #expect(Fmt.temperature(nil, unit: .fahrenheit) == Fmt.dash)
        #expect(Fmt.mAh(nil) == Fmt.dash)
    }

    @Test(arguments: [
        (65.0, false, "65 W"),
        (47.2, false, "47.2 W"),
        (47.2, true, "+47.2 W"),
        (-12.356, false, "−12.4 W"),
        (-12.356, true, "−12.4 W"),
        (-10.0, true, "−10 W"),
        (5.0, false, "5.0 W"),
        (0.0, true, "0.0 W"),
        (18.0, false, "18 W"),
        (6.7, false, "6.7 W"),
        (100.0, true, "+100 W"),
    ])
    func watts(_ w: Double, _ signed: Bool, _ expected: String) {
        #expect(Fmt.watts(w, signed: signed) == expected)
    }

    @Test(arguments: [
        (20000, "20 V"), (12520, "12.52 V"), (12500, "12.5 V"), (12356, "12.36 V"),
        (5000, "5 V"), (0, "0 V"), (19988, "19.99 V"),
    ])
    func volts(_ mV: Int, _ expected: String) {
        #expect(Fmt.volts(mV: mV) == expected)
    }

    @Test(arguments: [
        (3250, "3.25 A"), (3000, "3 A"), (-1200, "1.2 A"), (0, "0 A"), (612, "0.61 A"), (10000, "10 A"),
    ])
    func amps(_ mA: Int, _ expected: String) {
        #expect(Fmt.amps(mA: mA) == expected)
    }

    @Test(arguments: [
        (5000, 3000, "5V/3A"), (9000, 3000, "9V/3A"), (20000, 3250, "20V/3.25A"),
        (14800, 2220, "14.8V/2.22A"), (15000, 5000, "15V/5A"),
    ])
    func profile(_ mV: Int, _ mA: Int, _ expected: String) {
        #expect(Fmt.profile(PDProfile(index: 0, voltageMV: mV, currentMA: mA)) == expected)
    }

    @Test func percent() {
        #expect(Fmt.percent(80) == "80%")
        #expect(Fmt.percent(79.0, decimals: 1) == "79.0%")
        #expect(Fmt.percent(89.5503, decimals: 1) == "89.6%")
    }

    @Test(arguments: [
        (0, "—"), (-5, "—"), (1, "1 min"), (58, "58 min"), (59, "59 min"),
        (60, "1h 0m"), (248, "4h 8m"), (1439, "23h 59m"),
    ])
    func duration(_ m: Int, _ expected: String) {
        #expect(Fmt.duration(minutes: m) == expected)
    }

    @Test func temperature() {
        #expect(Fmt.temperature(31.5) == "31.5 °C")
        #expect(Fmt.temperature(35) == "35.0 °C")
        #expect(Fmt.temperature(35, unit: .fahrenheit) == "95.0 °F")
        #expect(Fmt.temperature(0, unit: .fahrenheit) == "32.0 °F")
        #expect(Fmt.temperature(-3.25) == "-3.2 °C" || Fmt.temperature(-3.25) == "-3.3 °C")
    }

    @Test func mAh() {
        #expect(Fmt.mAh(5955) == "5,955 mAh")
        #expect(Fmt.mAh(999) == "999 mAh")
        #expect(Fmt.mAh(0) == "0 mAh")
        #expect(Fmt.mAh(12_345_678) == "12,345,678 mAh")
    }

    @Test func trimZeros() {
        #expect(Fmt.trimZeros("20.00") == "20")
        #expect(Fmt.trimZeros("0.00") == "0")
        #expect(Fmt.trimZeros("3.250") == "3.25")
        #expect(Fmt.trimZeros("100") == "100", "no decimal point: integer zeros kept")
    }
}
