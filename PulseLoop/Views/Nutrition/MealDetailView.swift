import SwiftUI
import SwiftData

/// Full page for one logged meal (pushed via `AppRoute.mealDetail`): kcal + macro breakdown,
/// serving info, full nutrition facts, and provenance. Edit opens `MealLogSheet` prefilled;
/// delete confirms then pops.
struct MealDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mealId: UUID
    @Binding var path: NavigationPath

    @State private var dataChange = PulseDataChange.shared
    @State private var entry: MealEntry?
    @State private var editSheet = false
    @State private var deleteConfirm = false

    private func reload() {
        entry = NutritionRepository.entry(id: mealId, context: modelContext)
    }

    var body: some View {
        ScrollView {
            if let entry {
                VStack(spacing: 16) {
                    if let photo = CoachAttachmentRef.decode(fromJSON: entry.photoRefJSON).first
                        .flatMap({ CoachAttachmentStore.loadImage($0) }) {
                        Image(uiImage: photo)
                            .resizable().scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
                    }
                    titleBlock(entry)
                    kcalMacroCard(entry)
                    if entry.servingDescription != nil || entry.quantity != 1 {
                        servingCard(entry)
                    }
                    factsCard(entry)
                    if let notes = entry.notes, !notes.isEmpty {
                        DetailCard(title: "Notes", color: PulseColors.textMuted) {
                            Text(notes)
                                .font(PulseFont.body)
                                .foregroundStyle(PulseColors.textSecondary)
                                .padding(.top, 12)
                        }
                    }
                    sourceFooter(entry)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            } else {
                EmptyStateView(title: "Meal not found", body: "This entry was deleted.")
                    .padding(.top, 60)
            }
        }
        .background(PulseColors.background)
        .pageChrome(entry?.name ?? "Meal") {
            if entry != nil {
                Menu {
                    Button { editSheet = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { deleteConfirm = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(PulseFont.bodyEmphasis)
                        .foregroundStyle(PulseColors.textPrimary)
                        .frame(width: 36, height: 36)
                        .pulseGlass(Circle(), interactive: true)
                }
            }
        }
        .pulseScrollEdges()
        .task(id: dataChange.token) { reload() }
        .sheet(isPresented: $editSheet) {
            if let entry {
                MealLogSheet(day: entry.date, presetMealType: entry.mealType, editingId: entry.id)
            }
        }
        .confirmationDialog("Delete this meal?", isPresented: $deleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                NutritionRepository.delete(id: mealId, context: modelContext)
                dismiss()
            }
        }
    }

    // MARK: - Sections

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f
    }()

    private func titleBlock(_ entry: MealEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.mealType.label.uppercased())
                    .font(PulseFont.micro.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(PulseColors.calories)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PulseColors.calories.opacity(0.14), in: Capsule())
                ProvenanceBadge(source: entry.source, userEdited: entry.userEdited)
            }
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(PulseFont.caption.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kcalMacroCard(_ entry: MealEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(NutritionFormat.kcal(entry.calories))
                        .activityValueStyle(size: 40)
                    Text("kcal")
                        .font(PulseFont.subheadline)
                        .foregroundStyle(PulseColors.textMuted)
                }
                Text("ENERGY")
                    .font(PulseFont.micro.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(PulseColors.calories)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(MacroKind.allCases, id: \.self) { kind in
                macroStat(kind, grams: grams(kind, entry))
            }
        }
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func grams(_ kind: MacroKind, _ entry: MealEntry) -> Double {
        switch kind {
        case .protein: return entry.proteinG
        case .carbs: return entry.carbsG
        case .fat: return entry.fatG
        }
    }

    private func macroStat(_ kind: MacroKind, grams: Double) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(kind.color).frame(width: 6, height: 6)
                Text(kind.letter)
                    .font(PulseFont.micro.weight(.semibold))
                    .foregroundStyle(kind.color)
            }
            Text("\(NutritionFormat.grams(grams))g")
                .font(PulseFont.numberM)
                .monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
        }
        .frame(minWidth: 44)
    }

    private func servingCard(_ entry: MealEntry) -> some View {
        DetailCard(title: "Serving", color: PulseColors.calories) {
            VStack(alignment: .leading, spacing: 6) {
                if let serving = entry.servingDescription {
                    factRow("Serving size", serving)
                }
                factRow("Quantity", quantityText(entry.quantity))
            }
            .padding(.top, 12)
        }
    }

    private func quantityText(_ quantity: Double) -> String {
        quantity == quantity.rounded() ? "\(Int(quantity))" : String(format: "%.2g", quantity)
    }

    private func factsCard(_ entry: MealEntry) -> some View {
        DetailCard(title: "Nutrition Facts", color: PulseColors.calories) {
            VStack(spacing: 0) {
                factDividedRow("Calories", "\(NutritionFormat.kcal(entry.calories)) kcal", first: true)
                factDividedRow("Protein", "\(NutritionFormat.grams(entry.proteinG)) g")
                factDividedRow("Carbohydrates", "\(NutritionFormat.grams(entry.carbsG)) g")
                if let fiber = entry.fiberG {
                    factDividedRow("Fiber", "\(NutritionFormat.grams(fiber)) g", indented: true)
                }
                if let sugar = entry.sugarG {
                    factDividedRow("Sugar", "\(NutritionFormat.grams(sugar)) g", indented: true)
                }
                factDividedRow("Fat", "\(NutritionFormat.grams(entry.fatG)) g")
                if let sodium = entry.sodiumMg {
                    factDividedRow("Sodium", "\(NutritionFormat.grams(sodium)) mg")
                }
            }
            .padding(.top, 8)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(PulseFont.body).foregroundStyle(PulseColors.textSecondary)
            Spacer()
            Text(value)
                .font(PulseFont.body.monospacedDigit())
                .foregroundStyle(PulseColors.textPrimary)
        }
    }

    private func factDividedRow(_ label: String, _ value: String, first: Bool = false, indented: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first {
                Divider().overlay(PulseColors.borderSubtle)
            }
            HStack {
                Text(label)
                    .font(indented ? PulseFont.subheadline.weight(.regular) : PulseFont.body)
                    .foregroundStyle(indented ? PulseColors.textMuted : PulseColors.textSecondary)
                    .padding(.leading, indented ? 16 : 0)
                Spacer()
                Text(value)
                    .font(PulseFont.body.monospacedDigit())
                    .foregroundStyle(PulseColors.textPrimary)
            }
            .padding(.vertical, 10)
        }
    }

    private func sourceFooter(_ entry: MealEntry) -> some View {
        let text: String
        switch entry.source {
        case .offBarcode, .offSearch:
            text = "Nutrition data from Open Food Facts"
        case .llmEstimate:
            text = entry.userEdited ? "Estimated by AI Coach, adjusted by you" : "Estimated by AI Coach"
        case .manual:
            text = "Entered manually"
        }
        return Text(text)
            .font(PulseFont.caption.weight(.regular))
            .foregroundStyle(PulseColors.textMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
