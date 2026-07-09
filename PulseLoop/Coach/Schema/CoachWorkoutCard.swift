import SwiftUI
import SwiftData

/// In-chat card for a workout the coach logged or edited this turn. Fetches the
/// `ActivitySession` by id and renders the existing `ActivityWorkoutRow`, so it
/// stays visually identical to the Activity tab. Renders nothing if the session
/// was since deleted (e.g. the user removed it), matching the design intent that
/// this is a locally-known fact, not an LLM-emitted card.
struct CoachWorkoutCard: View {
    let activityId: UUID
    var onOpen: ((UUID) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    private var session: ActivitySession? {
        let id = activityId
        var descriptor = FetchDescriptor<ActivitySession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    var body: some View {
        if let session {
            ActivityWorkoutRow(session: session, units: units) { onOpen?(session.id) }
        }
    }
}
