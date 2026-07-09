import Foundation
import XCTest
@testable import PulseLoop

final class WorkoutActivityAttributesTests: XCTestCase {
    func testContentStateDecodesLegacyPayloadWithoutUnitsPreference() throws {
        let state = WorkoutActivityAttributes.ContentState(
            status: "recording",
            elapsedSeconds: 42,
            startDate: Date(timeIntervalSince1970: 100),
            pausedAt: nil,
            usesGps: true,
            distanceMeters: 250,
            paceSecondsPerKm: 300,
            lastHeartRate: 120,
            lastSpO2: 98,
            activityType: "run",
            lastUpdated: Date(timeIntervalSince1970: 120),
            useImperial: true
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        XCTAssertEqual(payload["useImperial"] as? Bool, true)
        payload.removeValue(forKey: "useImperial")

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(
            WorkoutActivityAttributes.ContentState.self,
            from: legacyData
        )

        XCTAssertFalse(decoded.useImperial)
    }

    func testContentStateDecodesLegacyPayloadWithoutAvgHeartRate() throws {
        let state = WorkoutActivityAttributes.ContentState(
            status: "recording",
            elapsedSeconds: 42,
            startDate: Date(timeIntervalSince1970: 100),
            pausedAt: nil,
            usesGps: true,
            distanceMeters: 250,
            paceSecondsPerKm: 300,
            lastHeartRate: 120,
            lastSpO2: 98,
            activityType: "run",
            lastUpdated: Date(timeIntervalSince1970: 120),
            useImperial: false,
            avgHeartRate: 132
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        XCTAssertEqual(payload["avgHeartRate"] as? Int, 132)
        payload.removeValue(forKey: "avgHeartRate")

        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(
            WorkoutActivityAttributes.ContentState.self,
            from: legacyData
        )

        XCTAssertNil(decoded.avgHeartRate)
    }

    func testFinishedContentStateRoundTrips() throws {
        let state = WorkoutActivityAttributes.ContentState(
            status: "finished",
            elapsedSeconds: 1830,
            startDate: Date(timeIntervalSince1970: 100),
            pausedAt: nil,
            usesGps: true,
            distanceMeters: 5120,
            paceSecondsPerKm: 357,
            lastHeartRate: 141,
            lastSpO2: 97,
            activityType: "run",
            lastUpdated: Date(timeIntervalSince1970: 1930),
            useImperial: false,
            avgHeartRate: 138
        )
        let decoded = try JSONDecoder().decode(
            WorkoutActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded.status, "finished")
        XCTAssertEqual(decoded.elapsedSeconds, 1830)
        XCTAssertEqual(decoded.avgHeartRate, 138)
    }
}
