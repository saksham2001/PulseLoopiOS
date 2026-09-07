import Foundation
import HealthKit
import SwiftData
import os

/// Reads data **out of** Apple Health and into PulseLoop's store — the other direction from
/// `HealthSyncService`.
///
/// This is what makes CGM data work: a continuous glucose monitor writes `bloodGlucose` to Health,
/// PulseLoop reads it, and from then on it sits in the same store the coach already queries, beside
/// the ring's sleep and heart rate. Oura's whole metabolic-health story is this same read.
///
/// Two invariants matter more than anything else here, and both have tests:
///
/// 1. **Never re-import our own exports.** PulseLoop writes glucose to Health on the export side, so
///    an unfiltered read would pull it straight back, re-export it, and loop — inflating the record
///    a little more on every pass. Every query excludes this app's own `HKSource`.
/// 2. **Imported rows carry `MeasurementSource.appleHealth`.** That is what keeps them out of the
///    export path, so an import can never be re-published to Health as if the ring had measured it.
@MainActor
@Observable
final class HealthImportService {
    static let shared = HealthImportService()

    nonisolated deinit {}

    private let store = HKHealthStore()
    private let log = Logger(subsystem: "com.pulseloop", category: "health-import")
    private var prefsStore: AppleHealthPrefsStore { .shared }

    private(set) var isImporting = false
    private(set) var lastResult: String?

    private init() {}

    /// The kinds this reads, and the HealthKit type each comes from.
    ///
    /// Steps and workouts are deliberately absent. Both would double-count against data the ring
    /// already produces — Health's step count includes the iPhone's own pedometer, and a ring-recorded
    /// workout that PulseLoop exported would come back as a second session. Merging those needs a
    /// provenance-aware reconciliation this doesn't have, so it doesn't pretend to.
    static let importableKinds: [MeasurementKind: HKQuantityTypeIdentifier] = [
        .bloodSugar: .bloodGlucose,
    ]

    /// Read types the import needs, on top of the profile characteristics the export side requests.
    var importReadTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        for identifier in Self.importableKinds.values {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) { set.insert(type) }
        }
        if let mass = HKQuantityType.quantityType(forIdentifier: .bodyMass) { set.insert(mass) }
        return set
    }

    /// Requests read-only access for the import types. Kept separate from the export authorization so
    /// enabling import never re-prompts for write access to the ring's data.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSyncError.unavailable }
        try await store.requestAuthorization(toShare: [], read: importReadTypes)
    }

    /// Pulls everything newer than each kind's import watermark.
    ///
    /// Returns `false` when it short-circuited (disabled, unavailable, already running) so a caller
    /// can re-arm rather than assume the data landed.
    @discardableResult
    func importIncremental(context: ModelContext, now: Date = Date()) async -> Bool {
        guard shouldImport(), !isImporting else { return false }
        isImporting = true
        defer { isImporting = false }

        var state = prefsStore.syncState
        var imported = 0

        if prefsStore.prefs.importGlucose {
            imported += await importQuantity(
                kind: .bloodSugar, unit: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
                context: context, state: &state, now: now
            )
        }
        if prefsStore.prefs.importBodyMass {
            await importBodyMass(context: context, state: &state, now: now)
        }

        prefsStore.syncState = state
        let summary = imported > 0
            ? "Imported \(imported) reading\(imported == 1 ? "" : "s") from Apple Health."
            : "Nothing new to import."
        lastResult = summary
        log.info("Health import finished: \(summary, privacy: .public)")
        return true
    }

    private func shouldImport() -> Bool {
        prefsStore.prefs.importEnabled
            && HKHealthStore.isHealthDataAvailable()
            && !HealthSyncService.shared.isRunningUnitTests
    }

    // MARK: - Quantity import

    private func importQuantity(
        kind: MeasurementKind, unit: HKUnit, context: ModelContext,
        state: inout AppleHealthSyncState, now: Date
    ) async -> Int {
        guard let identifier = Self.importableKinds[kind],
              let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return 0 }

        let watermark = state.importWatermarks[kind.rawValue] ?? now.addingTimeInterval(-30 * 86_400)
        let samples = await fetch(type: type, from: watermark, to: now)
        guard !samples.isEmpty else { return 0 }

        var written = 0
        for sample in samples {
            let value = sample.quantity.doubleValue(for: unit)
            // Reuse the ring path's own gate, so an implausible third-party reading is refused on
            // exactly the same terms as an implausible ring one.
            guard RingEventBridge.events(
                for: .historyMeasurement(kind: kind, value: value, timestamp: sample.startDate), now: now
            ).isEmpty == false else { continue }

            if upsert(kind: kind, value: value, timestamp: sample.startDate, context: context) { written += 1 }
        }
        try? context.save()

        if let newest = samples.map(\.startDate).max() {
            state.importWatermarks[kind.rawValue] = newest
        }
        return written
    }

    /// Inserts or updates the row for this (kind, instant, imported) triple.
    ///
    /// Keyed on the sample instant rather than HealthKit's UUID because that is how every other
    /// history path in the app deduplicates, and it means a CGM that revises a reading in place
    /// updates the existing row instead of stacking a second one beside it.
    ///
    /// Internal rather than private so the dedup rule is testable without a live `HKHealthStore`.
    @discardableResult
    func upsert(kind: MeasurementKind, value: Double, timestamp: Date, context: ModelContext) -> Bool {
        let raw = kind.rawValue
        let importedRaw = MeasurementSource.appleHealth.rawValue
        var descriptor = FetchDescriptor<Measurement>(
            predicate: #Predicate { $0.kindRaw == raw && $0.timestamp == timestamp && $0.sourceRaw == importedRaw }
        )
        descriptor.fetchLimit = 1

        if let existing = (try? context.fetch(descriptor))?.first {
            guard existing.value != value else { return false }
            existing.value = value
            return true
        }
        context.insert(Measurement(kind: kind, value: value, unit: kind.unit,
                                   timestamp: timestamp, source: .appleHealth))
        return true
    }

    // MARK: - Body mass

    /// Body mass updates the profile rather than becoming a measurement row: it is a profile
    /// characteristic everywhere else in the app (the calorie model and BMI read
    /// `UserProfile.weightKg`), and a second home for it would let the two disagree.
    private func importBodyMass(context: ModelContext, state: inout AppleHealthSyncState, now: Date) async {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return }
        let watermark = state.importWatermarks[bodyMassWatermarkKey] ?? now.addingTimeInterval(-365 * 86_400)
        let samples = await fetch(type: type, from: watermark, to: now)
        guard let newest = samples.max(by: { $0.startDate < $1.startDate }) else { return }

        let kilograms = newest.quantity.doubleValue(for: .gramUnit(with: .kilo))
        guard (20...400).contains(kilograms) else { return }

        if let profile = ProfileRepository.profile(context: context), profile.weightKg != kilograms {
            profile.weightKg = kilograms
            profile.updatedAt = Date()
            try? context.save()
        }
        state.importWatermarks[bodyMassWatermarkKey] = newest.startDate
    }

    /// Body mass has no `MeasurementKind`, so its watermark needs a key that can't collide with one.
    private var bodyMassWatermarkKey: String { "profile.bodyMass" }

    // MARK: - Fetch

    /// Samples of a type in a window, **excluding anything this app itself wrote**.
    ///
    /// That exclusion is the loop guard: PulseLoop exports glucose, so an unfiltered read would pull
    /// its own writes straight back in.
    private func fetch(type: HKQuantityType, from start: Date, to end: Date) async -> [HKQuantitySample] {
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let notOurs = NSCompoundPredicate(
            notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default())
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [window, notOurs])

        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { self.log.error("Import fetch failed: \(error.localizedDescription)") }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }
}
