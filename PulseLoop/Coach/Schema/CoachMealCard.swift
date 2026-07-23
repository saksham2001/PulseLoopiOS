import SwiftUI
import SwiftData

/// In-chat card for a meal the coach logged or edited this turn. Fetches the
/// `MealEntry` by id and renders the existing `MealEntryRow`, so it stays visually
/// identical to the Nutrition page. Renders nothing if the entry was since deleted —
/// same locally-known-fact design as `CoachWorkoutCard`.
struct CoachMealCard: View {
    let mealId: UUID
    var onOpen: ((UUID) -> Void)?

    @Environment(\.modelContext) private var modelContext

    private var entry: MealEntry? {
        let id = mealId
        var descriptor = FetchDescriptor<MealEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    var body: some View {
        if let entry {
            MealEntryRow(entry: entry) { onOpen?(entry.id) }
        }
    }
}
