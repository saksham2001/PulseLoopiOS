import Foundation
import XCTest
@testable import PulseLoop

@MainActor
final class ManualActivityServiceTests: XCTestCase {
    func testCreatePersistsFinishedManualSession() throws {
        let context = try TestSupport.makeContext()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-90 * 60)

        let session = try ManualActivityService.create(
            type: "cycling",
            startedAt: start,
            durationMinutes: 60,
            distanceMeters: 18_000,
            notes: "Evening ride",
            now: now,
            context: context
        )

        XCTAssertEqual(session.type, "cycle")
        XCTAssertEqual(session.status, .finished)
        XCTAssertEqual(session.startedAt, start)
        XCTAssertEqual(session.endedAt, start.addingTimeInterval(3600))
        XCTAssertEqual(session.distanceMeters, 18_000)
        XCTAssertEqual(session.notes, "Evening ride")
        XCTAssertFalse(session.useGps)
        XCTAssertEqual(ActivityRepository.sessions(context: context).map(\.id), [session.id])
    }

    func testCreateRejectsInvalidDuration() throws {
        let context = try TestSupport.makeContext()

        XCTAssertThrowsError(try ManualActivityService.create(
            type: "run",
            startedAt: Date().addingTimeInterval(-3600),
            durationMinutes: 0,
            context: context
        )) { error in
            XCTAssertEqual(error as? ManualActivityCreationError, .invalidDuration)
        }
        XCTAssertTrue(ActivityRepository.sessions(context: context).isEmpty)
    }

    func testCreateRejectsWorkoutEndingInFuture() throws {
        let context = try TestSupport.makeContext()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertThrowsError(try ManualActivityService.create(
            type: "run",
            startedAt: now.addingTimeInterval(-10 * 60),
            durationMinutes: 30,
            now: now,
            context: context
        )) { error in
            XCTAssertEqual(error as? ManualActivityCreationError, .endsInFuture)
        }
        XCTAssertTrue(ActivityRepository.sessions(context: context).isEmpty)
    }
}
