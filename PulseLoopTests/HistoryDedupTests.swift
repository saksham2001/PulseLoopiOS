import XCTest
import SwiftData
@testable import PulseLoop

/// History measurements are replayed verbatim every time a day is re-requested from the ring, so the
/// persistence layer upserts them on `(kind, timestamp)`. Live samples must keep append semantics.
@MainActor
final class HistoryDedupTests: XCTestCase {
    private func historyEvent(bpm: Double, at timestamp: Date) -> PulseEvent {
        .historyMeasurement(kind: .heartRate, value: bpm, timestamp: timestamp)
    }

    private func heartRateRows(_ context: ModelContext) throws -> [PulseLoop.Measurement] {
        let kindRaw = MeasurementKind.heartRate.rawValue
        return try context.fetch(
            FetchDescriptor<PulseLoop.Measurement>(
                predicate: #Predicate<PulseLoop.Measurement> { $0.kindRaw == kindRaw }
            )
        )
    }

    /// Re-delivering the same history sample within one sync inserts exactly one row.
    func testRepeatedHistorySampleInsertsOnce() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)

        subscriber.persist(historyEvent(bpm: 62, at: ts))
        subscriber.persist(historyEvent(bpm: 62, at: ts))
        subscriber.flush()

        XCTAssertEqual(try heartRateRows(context).count, 1)
    }

    /// A re-sync *across* syncs (the in-memory guard has been cleared) still finds the stored row and
    /// updates it in place rather than inserting a duplicate.
    func testResyncAfterCompletionUpdatesInPlace() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)

        subscriber.persist(historyEvent(bpm: 62, at: ts))
        subscriber.persist(.syncProgress(stage: "done"))   // clears the in-memory guard
        subscriber.flush()

        // Second sync replays the same slot with a refined average.
        subscriber.persist(historyEvent(bpm: 65, at: ts))
        subscriber.flush()

        let rows = try heartRateRows(context)
        XCTAssertEqual(rows.count, 1, "re-sync must not duplicate a history row")
        XCTAssertEqual(rows.first?.value, 65, "the refined value should overwrite the stored one")
    }

    /// Distinct timestamps are distinct samples.
    func testDifferentTimestampsInsertSeparately() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)

        subscriber.persist(historyEvent(bpm: 62, at: ts))
        subscriber.persist(historyEvent(bpm: 63, at: ts.addingTimeInterval(60)))
        subscriber.flush()

        XCTAssertEqual(try heartRateRows(context).count, 2)
    }

    /// One expected SwiftData row for a history kind.
    private struct StoredSample {
        let kind: MeasurementKind
        let value: Double
        let unit: String
    }

    /// The YCBT history types A3 added feed `.historyMeasurement`, which persists generically over
    /// `MeasurementKind` — this proves each new kind actually reaches SwiftData (with its unit) rather
    /// than falling off an unrouted branch somewhere between the bridge and the store.
    func testNewHistoryKindsReachSwiftDataWithTheirUnit() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            StoredSample(kind: .respiratoryRate, value: 14, unit: "brpm"),
            StoredSample(kind: .vo2max, value: 42, unit: "mL/kg/min"),
            StoredSample(kind: .temperature, value: 36.6, unit: "°C"),
            StoredSample(kind: .stress, value: 34.25, unit: ""),
            StoredSample(kind: .fatigue, value: 18, unit: ""),
            StoredSample(kind: .bloodSugar, value: 99.088, unit: "mg/dL"),
            StoredSample(kind: .bloodPressureSystolic, value: 118, unit: "mmHg"),
            StoredSample(kind: .bloodPressureDiastolic, value: 79, unit: "mmHg"),
            StoredSample(kind: .spo2, value: 97, unit: "%"),
        ]
        for sample in samples {
            subscriber.persist(.historyMeasurement(kind: sample.kind, value: sample.value, timestamp: ts))
        }
        subscriber.flush()

        for sample in samples {
            let kindRaw = sample.kind.rawValue
            let rows = try context.fetch(FetchDescriptor<PulseLoop.Measurement>(
                predicate: #Predicate<PulseLoop.Measurement> { $0.kindRaw == kindRaw }
            ))
            XCTAssertEqual(rows.count, 1, "\(sample.kind) never reached SwiftData")
            XCTAssertEqual(rows.first?.value ?? .nan, sample.value, accuracy: 0.001)
            XCTAssertEqual(rows.first?.unit, sample.unit)
            XCTAssertEqual(rows.first?.sourceRaw, MeasurementSource.history.rawValue)
        }
    }

    /// Live samples are events, not log slots: two readings at the same instant both persist.
    func testLiveSamplesAreNotDeduplicated() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)

        subscriber.persist(.heartRateSample(bpm: 70, timestamp: ts))
        subscriber.persist(.heartRateSample(bpm: 70, timestamp: ts))
        subscriber.flush()

        XCTAssertEqual(try heartRateRows(context).count, 2)
    }
}
