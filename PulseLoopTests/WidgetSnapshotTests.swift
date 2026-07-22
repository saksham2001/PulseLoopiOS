import XCTest
import SwiftUI
@testable import PulseLoop

/// The widget-snapshot contract: encode/decode round-trips, color-token bridging, and the baked-in
/// chart color step function the widget uses instead of the threshold engine.
@MainActor
final class WidgetSnapshotTests: XCTestCase {

    private func roundTrip(_ snapshot: WidgetSnapshot) throws -> WidgetSnapshot {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot))
    }

    func testSnapshotRoundTripPreservesPayloads() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metric = WidgetMetricPayload(
            kind: MetricKind.heartRate.rawValue, title: "Heart rate",
            valueText: "54–91", unitText: "bpm range", statusText: "Typical",
            statusColorHex: "#FF4D6D", isEmpty: false,
            samples: [WidgetSamplePayload(t: now, v: 72)],
            yLower: 40, yUpper: 140,
            referenceBands: [WidgetBandPayload(lower: 60, upper: 100, colorToken: "accent:heartRate", opacity: 0.08)],
            dashedRules: [92], thresholds: [50, 60, 100, 120],
            intervalColorHexes: ["#4DA3FF", "#4DA3FF", "#FF4D6D", "#FFB86B", "#FF1744"],
            zones: [WidgetZonePayload(id: "normal", label: "Normal", lower: 60, upper: 100,
                                      severityRaw: ZoneSeverity.normal.rawValue, colorToken: "mint")],
            systolic: 121, diastolic: 79, systolicZones: [], diastolicZones: []
        )
        let snapshot = WidgetSnapshot(
            generatedAt: now, dayStart: Calendar.current.startOfDay(for: now),
            activity: WidgetActivityPayload(
                steps: 6841, stepsGoal: 8000, distanceDisplay: 4.92, distanceGoalDisplay: 6,
                distanceUnitLabel: "KM", calories: 388, caloriesGoal: 520,
                stepsText: "6,841", distanceText: "4.92", caloriesText: "388"
            ),
            sleep: WidgetSleepPayload(durationText: "7h 23m", score: 82,
                                      segments: [.init(minutes: 78, colorHex: "#3F2DD8", label: "DEEP")]),
            metrics: [MetricKind.heartRate.rawValue: metric]
        )

        let decoded = try roundTrip(snapshot)

        XCTAssertEqual(decoded.activity?.stepsText, "6,841")
        XCTAssertEqual(decoded.sleep?.score, 82)
        let hr = try XCTUnwrap(decoded.metrics[MetricKind.heartRate.rawValue])
        XCTAssertEqual(hr.valueText, "54–91")
        XCTAssertEqual(hr.thresholds, [50, 60, 100, 120])
        XCTAssertEqual(hr.samples.first?.v, 72)
        XCTAssertEqual(hr.zones.first?.colorToken, "mint")
        XCTAssertEqual(hr.systolic, 121)
        // Dates survive the seconds-since-1970 strategy to the second.
        XCTAssertEqual(decoded.generatedAt.timeIntervalSince1970,
                       snapshot.generatedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testColorTokenStringBridgeRoundTripsAllTokens() {
        var tokens: [VitalColorToken] = [.blue, .mint, .cyan, .amber, .softAmber, .orange, .red, .brightRed, .deepRed, .neutral]
        tokens += MetricKind.allCases.map { .metricAccent($0) }
        for token in tokens {
            XCTAssertEqual(VitalColorToken(tokenString: token.tokenString), token)
        }
        // Unknown strings degrade to neutral instead of crashing on old/corrupt snapshots.
        XCTAssertEqual(VitalColorToken(tokenString: "definitely-not-a-token"), .neutral)
        XCTAssertEqual(VitalColorToken(tokenString: "accent:not-a-metric"), .neutral)
    }

    func testZonePayloadReconstructsMetricZone() {
        let zone = MetricZone(id: "watch", label: "Elevated", lower: 100, upper: 120,
                              severity: .watch, colorToken: .amber, explanation: "detail-only")
        let rebuilt = WidgetZonePayload(zone).metricZone
        XCTAssertEqual(rebuilt.id, zone.id)
        XCTAssertEqual(rebuilt.label, zone.label)
        XCTAssertEqual(rebuilt.lower, zone.lower)
        XCTAssertEqual(rebuilt.upper, zone.upper)
        XCTAssertEqual(rebuilt.severity, zone.severity)
        XCTAssertEqual(rebuilt.colorToken, zone.colorToken)
        XCTAssertTrue(rebuilt.contains(110))
        XCTAssertFalse(rebuilt.contains(120), "upper bound stays half-open")
    }

    func testLineColorStepFunctionMatchesEngineIntervals() {
        // The engine's mapping for a profile-less HR series, baked the way the publisher bakes it.
        let profile = UserPhysiologyProfile.unknown
        let thresholds = VitalsThresholdEngine.zoneThresholds(for: .heartRate, profile: profile, baseline: nil)
        XCTAssertFalse(thresholds.isEmpty)

        var hexes: [String] = []
        for index in 0...thresholds.count {
            let representative: Double
            if index == 0 { representative = thresholds[0] - 1 }
            else if index == thresholds.count { representative = thresholds[index - 1] + 1 }
            else { representative = (thresholds[index - 1] + thresholds[index]) / 2 }
            // Interval index encoded as a fake hex so we can assert pure index math below.
            _ = representative
            hexes.append(String(format: "#%06X", index))
        }
        let payload = WidgetMetricPayload(
            kind: MetricKind.heartRate.rawValue, title: "Heart rate", valueText: "72",
            unitText: nil, statusText: "Typical", statusColorHex: "#FFFFFF", isEmpty: false,
            samples: [], yLower: 40, yUpper: 140, referenceBands: [], dashedRules: [],
            thresholds: thresholds, intervalColorHexes: hexes,
            zones: [], systolic: nil, diastolic: nil, systolicZones: [], diastolicZones: []
        )

        // Below the first boundary → interval 0; above the last → last interval; boundary values
        // belong to the interval above them (half-open zones).
        XCTAssertEqual(payload.lineColor(forValue: thresholds[0] - 5), Color(hex: hexes[0]))
        XCTAssertEqual(payload.lineColor(forValue: thresholds[0]), Color(hex: hexes[1]))
        XCTAssertEqual(payload.lineColor(forValue: thresholds.last! + 5), Color(hex: hexes.last!))
    }
}
