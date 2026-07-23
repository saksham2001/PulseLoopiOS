import Foundation
import HealthKit
import SwiftData
import os

/// Dietary export pass: logged meals → `HKQuantitySample`s (energy + macros). One sample per
/// non-nil nutrient per entry, all keyed on `pl-meal-<id>-<nutrient>` sync identifiers with
/// `HKMetadataKeySyncVersion = Int(updatedAt)`, so an edited meal re-exports and *replaces*
/// its samples. Watermarked on `MealEntry.updatedAt` in `AppleHealthSyncState.nutritionExportedThrough`.
///
/// Gated on BOTH master toggles: Apple Health sync (`AppleHealthPrefs`) and the nutrition
/// feature (`NutritionPrefs`) — plus the per-type `syncNutrition` toggle.
extension HealthSyncService {

    func exportNutrition(context: ModelContext, state: inout AppleHealthSyncState,
                         counts: inout SyncCounts, now: Date) async throws {
        guard AppleHealthPrefsStore.shared.prefs.syncNutrition,
              NutritionPrefsStore.shared.prefs.masterEnabled else { return }

        let watermark = state.nutritionExportedThrough ?? .distantPast
        let descriptor = FetchDescriptor<MealEntry>(
            predicate: #Predicate { $0.updatedAt > watermark },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return }

        // Chunked saves (batch of 200 entries) with the watermark advanced per chunk, so an
        // interrupted backfill resumes and re-runs stay harmless (upsert).
        var index = 0
        while index < rows.count {
            let chunk = Array(rows[index..<min(index + 200, rows.count)])
            index += 200
            var samples: [HKQuantitySample] = []
            for entry in chunk {
                samples.append(contentsOf: mealSamples(entry: entry, now: now))
            }
            if !samples.isEmpty {
                try await save(samples)
                counts.meals += chunk.count
            }
            if let maxUpdated = chunk.map({ $0.updatedAt }).max() {
                state.nutritionExportedThrough = maxUpdated
                AppleHealthPrefsStore.shared.syncState = state
            }
        }
    }

    /// One exportable nutrient of a meal entry.
    private struct MealNutrient {
        let nutrient: String
        let id: HKQuantityTypeIdentifier
        let unit: HKUnit
        let value: Double
    }

    /// Energy plus every present nutrient for one entry.
    private func mealNutrients(_ entry: MealEntry) -> [MealNutrient] {
        var out: [MealNutrient] = [
            MealNutrient(nutrient: "energy", id: .dietaryEnergyConsumed, unit: .kilocalorie(), value: entry.calories),
            MealNutrient(nutrient: "protein", id: .dietaryProtein, unit: .gram(), value: entry.proteinG),
            MealNutrient(nutrient: "carbs", id: .dietaryCarbohydrates, unit: .gram(), value: entry.carbsG),
            MealNutrient(nutrient: "fat", id: .dietaryFatTotal, unit: .gram(), value: entry.fatG),
        ]
        if let fiber = entry.fiberG {
            out.append(MealNutrient(nutrient: "fiber", id: .dietaryFiber, unit: .gram(), value: fiber))
        }
        if let sugar = entry.sugarG {
            out.append(MealNutrient(nutrient: "sugar", id: .dietarySugar, unit: .gram(), value: sugar))
        }
        if let sodium = entry.sodiumMg {
            out.append(MealNutrient(nutrient: "sodium", id: .dietarySodium, unit: .gramUnit(with: .milli), value: sodium))
        }
        return out
    }

    private func mealSamples(entry: MealEntry, now: Date) -> [HKQuantitySample] {
        let timestamp = min(entry.timestamp, now)   // never write a future-dated sample
        let version = Int(entry.updatedAt.timeIntervalSince1970)
        var samples: [HKQuantitySample] = []
        for item in mealNutrients(entry) {
            guard item.value > 0 || (item.nutrient == "energy" && item.value >= 0),
                  item.value.isFinite,
                  let type = HKQuantityType.quantityType(forIdentifier: item.id),
                  canShare(type) else { continue }
            samples.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: item.unit, doubleValue: item.value),
                start: timestamp, end: timestamp,
                metadata: HealthKitTypeMappings.metadata(
                    syncID: HealthKitTypeMappings.mealNutrientSyncID(entryID: entry.id, nutrient: item.nutrient),
                    version: version
                )
            ))
        }
        return samples
    }

    /// Fire-and-forget removal of one meal's exported samples (called when the entry is deleted
    /// locally). Best-effort: if export was off at delete time, orphaned samples may remain —
    /// a documented limitation.
    func deleteExportedMeal(entryId: UUID) {
        guard isAvailable, !isRunningUnitTests, authState == .authorized else { return }
        let syncIDs = ["energy", "protein", "carbs", "fat", "fiber", "sugar", "sodium"].map {
            HealthKitTypeMappings.mealNutrientSyncID(entryID: entryId, nutrient: $0)
        }
        let identifiers: [HKQuantityTypeIdentifier] = [
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
            .dietaryFatTotal, .dietaryFiber, .dietarySugar, .dietarySodium
        ]
        Task {
            for identifier in identifiers {
                guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
                let metaPredicate = HKQuery.predicateForObjects(
                    withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: syncIDs)
                let sourcePredicate = HKQuery.predicateForObjects(from: HKSource.default())
                let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, metaPredicate])
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                        if let error {
                            self.log.error("Meal sample delete failed for \(type.identifier): \(error.localizedDescription)")
                        }
                        cont.resume()
                    }
                }
            }
        }
    }
}
