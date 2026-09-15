import Foundation
import XCTest
@testable import olcrtc_ios

// Pure logic behind the hero throughput readout and the waveform's intensity:
// no NetworkExtension session, no getifaddrs, no timers. The monitor itself
// (`TunnelThroughputMonitor`) is exercised only by its source contract in
// Tests/test_signal_native_486.py.
final class TunnelThroughputTests: XCTestCase {

    // MARK: ThroughputEstimator

    func testFirstSampleYieldsNothingAndSecondYieldsARate() {
        var estimator = ThroughputEstimator()
        XCTAssertNil(estimator.ingest(ThroughputCounters(inBytes: 1_000, outBytes: 500, at: 10)))
        let rate = estimator.ingest(ThroughputCounters(inBytes: 3_000, outBytes: 1_500, at: 11))
        XCTAssertNotNil(rate)
        // One second, 2000 B in / 1000 B out, weighted by 1 - e^(-1/2).
        let weight = 1 - exp(-1 / ThroughputEstimator.timeConstant)
        XCTAssertEqual(rate?.inBytesPerSecond ?? -1, 2_000 * weight, accuracy: 0.001)
        XCTAssertEqual(rate?.outBytesPerSecond ?? -1, 1_000 * weight, accuracy: 0.001)
    }

    func testAverageConvergesToASteadyRateWithoutOvershoot() {
        var estimator = ThroughputEstimator()
        var last = 0.0
        for second in 0..<12 {
            let counters = ThroughputCounters(inBytes: UInt64(second) * 4_096,
                                              outBytes: UInt64(second) * 1_024,
                                              at: TimeInterval(second))
            if let rate = estimator.ingest(counters) {
                XCTAssertGreaterThanOrEqual(rate.inBytesPerSecond, last)
                XCTAssertLessThanOrEqual(rate.inBytesPerSecond, 4_096.000001)
                last = rate.inBytesPerSecond
            }
        }
        XCTAssertEqual(last, 4_096, accuracy: 20)
    }

    func testCounterGoingBackwardsResetsTheAverage() {
        var estimator = ThroughputEstimator()
        _ = estimator.ingest(ThroughputCounters(inBytes: 0, outBytes: 0, at: 0))
        _ = estimator.ingest(ThroughputCounters(inBytes: 100_000, outBytes: 100_000, at: 1))
        XCTAssertGreaterThan(estimator.inBytesPerSecond, 0)
        XCTAssertNil(estimator.ingest(ThroughputCounters(inBytes: 10, outBytes: 10, at: 2)))
        XCTAssertEqual(estimator.inBytesPerSecond, 0)
        XCTAssertEqual(estimator.outBytesPerSecond, 0)
    }

    func testZeroOrNegativeTimeStepIsIgnored() {
        var estimator = ThroughputEstimator()
        _ = estimator.ingest(ThroughputCounters(inBytes: 0, outBytes: 0, at: 5))
        XCTAssertNil(estimator.ingest(ThroughputCounters(inBytes: 10, outBytes: 10, at: 5)))
        XCTAssertNil(estimator.ingest(ThroughputCounters(inBytes: 20, outBytes: 20, at: 4)))
    }

    func testResetForgetsThePreviousSample() {
        var estimator = ThroughputEstimator()
        _ = estimator.ingest(ThroughputCounters(inBytes: 0, outBytes: 0, at: 0))
        _ = estimator.ingest(ThroughputCounters(inBytes: 100, outBytes: 100, at: 1))
        estimator.reset()
        XCTAssertEqual(estimator, ThroughputEstimator())
        // The first sample after a reset only primes the estimator again.
        XCTAssertNil(estimator.ingest(ThroughputCounters(inBytes: 50, outBytes: 50, at: 2)))
    }

    // MARK: WrappingCounter32

    func testWrappingCounterSurvivesA32BitWrap() {
        var counter = WrappingCounter32()
        XCTAssertEqual(counter.extend(UInt32.max - 10), 0)
        XCTAssertEqual(counter.extend(5), 16)
        XCTAssertEqual(counter.extend(1_005), 1_016)
    }

    // MARK: ThroughputReading

    func testReadingTotalsAndExactness() {
        let exact = ThroughputReading.exact(inBytesPerSecond: 1_000, outBytesPerSecond: 500)
        XCTAssertEqual(exact.totalBytesPerSecond, 1_500)
        XCTAssertTrue(exact.isExact)
        let estimate = ThroughputReading.estimate(totalBytesPerSecond: 42)
        XCTAssertEqual(estimate.totalBytesPerSecond, 42)
        XCTAssertFalse(estimate.isExact)
    }

    // MARK: ThroughputFormat

    func testFormatPicksKilobytesBelowOneMegabyteAndOneDecimalBelowAHundred() {
        let en = Locale(identifier: "en_US")
        XCTAssertTrue(ThroughputFormat.rate(0, locale: en).hasPrefix("0 "))
        XCTAssertTrue(ThroughputFormat.rate(1_536, locale: en).hasPrefix("2 "))
        XCTAssertTrue(ThroughputFormat.rate(1_023 * 1_024, locale: en).hasPrefix("1023 "))
        XCTAssertTrue(ThroughputFormat.rate(1.25 * 1_024 * 1_024, locale: en).hasPrefix("1.2 "))
        XCTAssertTrue(ThroughputFormat.rate(1.25 * 1_024 * 1_024, locale: Locale(identifier: "ru_RU")).hasPrefix("1,2 "))
        XCTAssertTrue(ThroughputFormat.rate(1_023 * 1_024, locale: Locale(identifier: "ru_RU")).hasPrefix("1023 "))
        XCTAssertTrue(ThroughputFormat.rate(120 * 1_024 * 1_024, locale: en).hasPrefix("120 "))
        XCTAssertTrue(ThroughputFormat.rate(-5, locale: en).hasPrefix("0 "))
        XCTAssertTrue(ThroughputFormat.rate(.nan, locale: en).hasPrefix("0 "))
    }

    // MARK: SignalMotionPolicy — throughput to motion

    func testIntensityIsZeroAtIdleAndSaturatesAtTheTop() {
        XCTAssertEqual(SignalMotionPolicy.intensity(bytesPerSecond: 0), 0)
        XCTAssertEqual(SignalMotionPolicy.intensity(bytesPerSecond: SignalMotionPolicy.idleBytesPerSecond), 0)
        XCTAssertEqual(SignalMotionPolicy.intensity(bytesPerSecond: .nan), 0)
        XCTAssertEqual(SignalMotionPolicy.intensity(bytesPerSecond: SignalMotionPolicy.fullIntensityBytesPerSecond),
                       1, accuracy: 0.000001)
        XCTAssertEqual(SignalMotionPolicy.intensity(bytesPerSecond: .greatestFiniteMagnitude), 1)
    }

    func testIntensityIsMonotonicInThroughput() {
        var last = -1.0
        for exponent in stride(from: 2.0, through: 8.0, by: 0.25) {
            let value = SignalMotionPolicy.intensity(bytesPerSecond: pow(10, exponent))
            XCTAssertGreaterThanOrEqual(value, last)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
            last = value
        }
    }

    func testAmplitudeAndSpeedInterpolateBetweenCalmAndPeak() {
        XCTAssertEqual(SignalMotionPolicy.amplitude(intensity: 0, isConnected: true), SignalMotionPolicy.calmAmplitude)
        XCTAssertEqual(SignalMotionPolicy.amplitude(intensity: 1, isConnected: true), SignalMotionPolicy.peakAmplitude)
        XCTAssertEqual(SignalMotionPolicy.amplitude(intensity: 7, isConnected: true), SignalMotionPolicy.peakAmplitude)
        XCTAssertEqual(SignalMotionPolicy.amplitude(intensity: 1, isConnected: false), SignalMotionPolicy.staticAmplitude)
        XCTAssertEqual(SignalMotionPolicy.speed(intensity: 0), SignalMotionPolicy.calmSpeed)
        XCTAssertEqual(SignalMotionPolicy.speed(intensity: 1), SignalMotionPolicy.peakSpeed)
        XCTAssertLessThan(SignalMotionPolicy.staticAmplitude, SignalMotionPolicy.calmAmplitude)
        XCTAssertLessThan(SignalMotionPolicy.calmAmplitude, SignalMotionPolicy.peakAmplitude)
    }

    func testEasingMovesTowardTheTargetWithoutOvershoot() {
        var current = 0.0
        for _ in 0..<60 {
            let next = SignalMotionPolicy.eased(current: current, target: 1, dt: 1 / 30)
            XCTAssertGreaterThanOrEqual(next, current)
            XCTAssertLessThanOrEqual(next, 1)
            current = next
        }
        XCTAssertEqual(current, 1, accuracy: 0.01)
        XCTAssertEqual(SignalMotionPolicy.eased(current: 0.4, target: 1, dt: 0), 0.4)
        XCTAssertEqual(SignalMotionPolicy.eased(current: 0.4, target: 1, dt: 10), 1)
    }

    func testPhaseClockAdvancesOnlyBetweenTwoDatesAndForgetsOnReset() {
        let clock = SignalPhaseClock()
        let start = Date(timeIntervalSince1970: 1_000)
        clock.advance(to: start, target: 1)
        XCTAssertEqual(clock.phase, 0)
        clock.advance(to: start.addingTimeInterval(0.1), target: 1)
        XCTAssertGreaterThan(clock.phase, 0)
        XCTAssertGreaterThan(clock.intensity, 0)
        let phase = clock.phase
        clock.reset()
        clock.advance(to: start.addingTimeInterval(60), target: 1)
        XCTAssertEqual(clock.phase, phase, "a reset clock must not jump on its first tick")
    }
}
