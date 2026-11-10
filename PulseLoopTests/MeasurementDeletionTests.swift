import XCTest
import SwiftData
@testable import PulseLoop

/// Deleting individual readings (issue #60): the row goes, a tombstone keeps it gone across re-syncs,
/// and a blood-pressure reading is removed as its systolic + diastolic pair.
@MainActor
final class MeasurementDeletionTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_760_000_000)

    private func rows(_ kind: MeasurementKind, _ context: ModelContext) throws -> [PulseLoop.Measurement] {
        let raw = kind.rawValue
        return try context.fetch(FetchDescriptor<PulseLoop.Measurement>(predicate: #Predicate { $0.kindRaw == raw }))
    }

    private func window() -> (Date, Date) { (ts.addingTimeInterval(-86_400), ts.addingTimeInterval(86_400)) }

    func testDeletedHistoryReadingIsNotRestoredByResync() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 140, timestamp: ts))
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 62, timestamp: ts.addingTimeInterval(300)))
        subscriber.persist(.syncProgress(stage: "done"))
        subscriber.flush()

        let (start, end) = window()
        let readings = VitalReadings.load(metric: .heartRate, start: start, end: end, context: context)
        XCTAssertEqual(readings.map(\.value), [62, 140], "newest first")
        let bad = try XCTUnwrap(readings.last)
        XCTAssertEqual(VitalReadings.delete(bad, context: context), 1)
        XCTAssertEqual(try rows(.heartRate, context).map(\.value), [62])
        XCTAssertTrue(MeasurementDeletionService.isDeleted(kind: .heartRate, timestamp: ts, context: context))

        // The ring replays the whole day on the next sync.
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 140, timestamp: ts))
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 62, timestamp: ts.addingTimeInterval(300)))
        subscriber.persist(.historyMeasurement(kind: .heartRate, value: 70, timestamp: ts.addingTimeInterval(600)))
        subscriber.flush()

        XCTAssertEqual(try rows(.heartRate, context).map(\.value).sorted(), [62, 70],
                       "the deleted slot stays deleted; new and existing slots still sync")
    }

    func testTombstoneIsPerKind() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 80, timestamp: ts, into: context)
        let row = try XCTUnwrap(try rows(.heartRate, context).first)
        MeasurementDeletionService.deleteReading(row, context: context)

        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.historyMeasurement(kind: .spo2, value: 97, timestamp: ts))
        subscriber.flush()
        XCTAssertEqual(try rows(.spo2, context).count, 1, "an SpO2 reading at the same instant is unaffected")
    }

    func testBloodPressureDeletesBothHalvesAndStaysDeleted() throws {
        let context = try TestSupport.makeContext()
        let subscriber = EventPersistenceSubscriber(context: context)
        subscriber.persist(.bloodPressureSample(systolic: 150, diastolic: 98, timestamp: ts))
        subscriber.persist(.bloodPressureSample(systolic: 118, diastolic: 76, timestamp: ts.addingTimeInterval(3600)))
        subscriber.flush()

        let (start, end) = window()
        let readings = VitalReadings.load(metric: .bloodPressure, start: start, end: end, context: context)
        XCTAssertEqual(readings.count, 2)
        let high = try XCTUnwrap(readings.first { $0.value == 150 })
        XCTAssertEqual(high.secondary, 98)
        XCTAssertTrue(high.isEstimated, "ring blood pressure is never shown unlabelled")

        XCTAssertEqual(VitalReadings.delete(high, context: context), 2, "a reading is its systolic + diastolic rows")
        XCTAssertEqual(try rows(.bloodPressureSystolic, context).map(\.value), [118])
        XCTAssertEqual(try rows(.bloodPressureDiastolic, context).map(\.value), [76])

        subscriber.persist(.bloodPressureSample(systolic: 150, diastolic: 98, timestamp: ts))
        subscriber.flush()
        XCTAssertEqual(try rows(.bloodPressureSystolic, context).count, 1)
        XCTAssertEqual(try rows(.bloodPressureDiastolic, context).count, 1)
    }

    func testReadingsApplyCalibrationAndWindow() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .bloodSugar, value: 100, timestamp: ts, into: context)
        TestSupport.insertMeasurement(kind: .bloodSugar, value: 90, timestamp: ts.addingTimeInterval(-3 * 86_400), into: context)
        var calibration = Calibration()
        calibration.glucoseOffsetMgdl = 5
        let (start, end) = window()
        let readings = VitalReadings.load(metric: .glucose, start: start, end: end, calibration: calibration, context: context)
        XCTAssertEqual(readings.map(\.value), [105], "calibrated, and only inside the window")
        XCTAssertTrue(readings[0].isEstimated)
    }

    /// Hourly SpO₂ a ring computes from heart rate (`EstimatedSpO2`): 30 hourly history rows with
    /// respiratory siblings and an HR row each, plus one live spot reading.
    private func seedDerivedSpO2Ring(_ context: ModelContext, now: Date) throws -> (hourly: [Date], spot: Date) {
        let heartRates = [48, 57, 67, 75, 82, 92, 105, 70]
        func spo2(_ hr: Int) -> Double { hr <= 48 ? 88 : hr <= 57 ? 94 : hr <= 92 ? 98 : 96 }
        var hourly: [Date] = []
        for i in 0..<30 {
            let t = now.addingTimeInterval(-Double(30 - i) * 3600 + 34)
            let hr = heartRates[i % heartRates.count]
            hourly.append(t)
            TestSupport.insertMeasurement(kind: .spo2, value: spo2(hr), timestamp: t, source: .history, into: context)
            TestSupport.insertMeasurement(kind: .respiratoryRate, value: Double(hr) / 5, timestamp: t, source: .history, into: context)
            TestSupport.insertMeasurement(kind: .heartRate, value: Double(hr), timestamp: t.addingTimeInterval(-5), source: .history, into: context)
        }
        let spot = now.addingTimeInterval(-600)
        TestSupport.insertMeasurement(kind: .spo2, value: 99, timestamp: spot, source: .live, into: context)
        return (hourly, spot)
    }

    func testEstimatedSpO2ReadingsAreHiddenOrTaggedLikeTheChart() throws {
        let context = try TestSupport.makeContext()
        let now = Date()
        let seeded = try seedDerivedSpO2Ring(context, now: now)
        let start = now.addingTimeInterval(-86_400), end = now.addingTimeInterval(1)

        let hidden = VitalReadings.load(metric: .spo2, start: start, end: end, hideEstimatedSpO2: true, context: context)
        XCTAssertEqual(hidden.map(\.timestamp), [seeded.spot], "estimates hidden: only the measured spot reading")
        XCTAssertFalse(hidden[0].isEstimated)

        let shown = VitalReadings.load(metric: .spo2, start: start, end: end, hideEstimatedSpO2: false, context: context)
        XCTAssertEqual(shown.count, seeded.hourly.filter { $0 >= start }.count + 1)
        XCTAssertEqual(shown.filter(\.isEstimated).count, shown.count - 1, "every hourly estimate is tagged")
        XCTAssertFalse(try XCTUnwrap(shown.first { $0.timestamp == seeded.spot }).isEstimated)
    }

    func testDeletingTwiceKeepsOneTombstone() throws {
        let context = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .hrv, value: 40, timestamp: ts, into: context)
        TestSupport.insertMeasurement(kind: .hrv, value: 41, timestamp: ts.addingTimeInterval(0.4), into: context)
        for row in try rows(.hrv, context) { MeasurementDeletionService.deleteReading(row, context: context) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MeasurementDeletion>()), 1)
        XCTAssertTrue(try rows(.hrv, context).isEmpty)
    }

    func testArchiveRoundTripsTombstonesAndAcceptsOlderArchives() async throws {
        let source = try TestSupport.makeContext()
        TestSupport.insertMeasurement(kind: .heartRate, value: 80, timestamp: ts, into: source)
        MeasurementDeletionService.deleteReading(try XCTUnwrap(try rows(.heartRate, source).first), context: source)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "MeasurementDeletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let data = try await DataArchiveService.exportArchive(context: source, defaults: defaults, attachmentsDirectory: dir)
        let target = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(data, context: target, defaults: defaults,
                                                   attachmentsDirectory: dir, refreshStores: false)
        XCTAssertTrue(MeasurementDeletionService.isDeleted(kind: .heartRate, timestamp: ts, context: target),
                      "a restore must carry the tombstones, or the next sync resurrects deleted readings")

        // An archive written before tombstones existed has no `measurementDeletions` key.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "measurementDeletions")
        let older = try JSONSerialization.data(withJSONObject: json)
        let fresh = try TestSupport.makeContext()
        try await DataArchiveService.importArchive(older, context: fresh, defaults: defaults,
                                                   attachmentsDirectory: dir, refreshStores: false)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<MeasurementDeletion>()), 0)
    }
}
