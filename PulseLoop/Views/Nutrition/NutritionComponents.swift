import SwiftUI
import UIKit

// Shared building blocks for the nutrition feature: the calorie budget gauge, macro progress
// bars, meal rows, and the provenance badge. All follow the Liquid Glass design system and are
// reused across the Nutrition page, Activity card, Today tile, and coach chat meal card.

/// One macro's identity: display name, single-letter tag, and token color.
enum MacroKind: CaseIterable {
    case protein, carbs, fat

    var name: String {
        switch self {
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        }
    }

    var letter: String {
        switch self {
        case .protein: return "P"
        case .carbs: return "C"
        case .fat: return "F"
        }
    }

    var color: Color {
        switch self {
        case .protein: return PulseColors.macroProtein
        case .carbs: return PulseColors.macroCarbs
        case .fat: return PulseColors.macroFat
        }
    }
}

enum NutritionFormat {
    static func kcal(_ value: Double) -> String { Int(value.rounded()).formatted() }
    static func grams(_ value: Double) -> String { "\(Int(value.rounded()))" }

    /// Fill color for consumed-vs-goal progress: metric color while under goal, warning slightly
    /// over, danger well over — mirrors the vitals zone idiom (never a hard red at 101%).
    static func progressColor(consumed: Double, goal: Double, base: Color) -> Color {
        guard goal > 0, consumed > goal else { return base }
        return consumed <= goal * 1.15 ? PulseColors.warning : PulseColors.danger
    }
}

// MARK: - Macro mini bar

/// A thin capsule progress bar for one macro (value vs goal). Goal-less bars render as a muted
/// track only — no invented targets.
struct MacroMiniBar: View {
    let value: Double
    let goal: Double?
    var color: Color
    var height: CGFloat = 4

    private var fraction: Double {
        guard let goal, goal > 0 else { return 0 }
        return min(1, max(0, value / goal))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(PulseColors.elevated)
                if fraction > 0 {
                    Capsule()
                        .fill(goal.map { NutritionFormat.progressColor(consumed: value, goal: $0, base: color) } ?? color)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
    }
}

/// The three macro mini-bars in one row with `P 80/112g`-style micro labels. Used on the
/// Activity summary card and (vertically) the Today tile.
struct MacroMiniBars: View {
    let totals: NutritionDayTotals
    let goals: GoalsSummary

    var body: some View {
        HStack(spacing: 12) {
            column(.protein, value: totals.proteinG, goal: goals.intakeProteinG)
            column(.carbs, value: totals.carbsG, goal: goals.intakeCarbsG)
            column(.fat, value: totals.fatG, goal: goals.intakeFatG)
        }
    }

    private func column(_ kind: MacroKind, value: Double, goal: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(kind.letter)
                    .font(PulseFont.micro.weight(.semibold))
                    .foregroundStyle(kind.color)
                Text(goal.map { "\(NutritionFormat.grams(value))/\($0)g" } ?? "\(NutritionFormat.grams(value))g")
                    .font(PulseFont.micro.weight(.medium).monospacedDigit())
                    .foregroundStyle(PulseColors.textMuted)
                    .lineLimit(1)
            }
            MacroMiniBar(value: value, goal: goal.map(Double.init), color: kind.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Macro progress row (Nutrition page)

/// Full-width macro row: colored dot + name, `80 / 112 g`, and a 6pt progress bar.
struct MacroProgressRow: View {
    let kind: MacroKind
    let consumed: Double
    let goal: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(kind.color).frame(width: 8, height: 8)
                        .shadow(color: kind.color.opacity(0.7), radius: 5)
                    Text(kind.name)
                        .font(PulseFont.subheadline)
                        .foregroundStyle(PulseColors.textPrimary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(NutritionFormat.grams(consumed))
                        .font(PulseFont.numberM)
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                    Text(goal.map { "/ \($0) g" } ?? "g")
                        .font(PulseFont.caption.weight(.regular).monospacedDigit())
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            MacroMiniBar(value: consumed, goal: goal.map(Double.init), color: kind.color, height: 6)
        }
    }
}

// MARK: - Calorie budget gauge (Nutrition page hero)

/// The page hero: a large eaten-vs-goal ring with remaining kcal in the center, flanked by
/// EATEN and BURNED stat columns. With no goal set, the ring stays a muted track and the
/// center shows total eaten — the app never invents a calorie target.
struct CalorieBudgetGauge: View {
    let totals: NutritionDayTotals
    let goal: Int?
    /// Active-energy burned today (from the existing activity summary); informational.
    let burned: Double?

    private var remaining: Double? { goal.map { Double($0) - totals.calories } }
    private var ringColor: Color {
        goal.map { NutritionFormat.progressColor(consumed: totals.calories, goal: Double($0), base: PulseColors.calories) }
            ?? PulseColors.calories
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                stat("EATEN", NutritionFormat.kcal(totals.calories), PulseColors.calories)
                Spacer(minLength: 8)
                ProgressRingView(
                    value: totals.calories,
                    max: Double(goal ?? 0),
                    size: 140,
                    stroke: 12,
                    color: ringColor
                ) {
                    VStack(spacing: 2) {
                        if let remaining {
                            Text(NutritionFormat.kcal(max(0, remaining)))
                                .font(PulseFont.numberXL)
                                .monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                            Text(remaining >= 0 ? "LEFT" : "OVER")
                                .font(PulseFont.micro.weight(.semibold))
                                .tracking(1.0)
                                .foregroundStyle(remaining >= 0 ? PulseColors.textMuted : ringColor)
                        } else {
                            Text(NutritionFormat.kcal(totals.calories))
                                .font(PulseFont.numberXL)
                                .monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                            Text("KCAL")
                                .font(PulseFont.micro.weight(.semibold))
                                .tracking(1.0)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                    }
                }
                Spacer(minLength: 8)
                stat("BURNED", burned.map { NutritionFormat.kcal($0) } ?? "—", PulseColors.textMuted)
            }
            Text(footerText)
                .font(PulseFont.caption.weight(.regular).monospacedDigit())
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private var footerText: String {
        var parts: [String] = []
        if let goal {
            parts.append("\(NutritionFormat.kcal(totals.calories)) of \(goal.formatted()) kcal")
        } else {
            parts.append("No calorie goal set")
        }
        if let burned, burned > 0 {
            parts.append("net \(NutritionFormat.kcal(totals.calories - burned))")
        }
        return parts.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .activityValueStyle(size: 24)
            Text(label)
                .font(PulseFont.micro.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Provenance badge

/// Small capsule stating where an entry's numbers came from — the honesty marker required by
/// the "we don't guess" principle. Database-verified (Open Food Facts), AI estimate, or manual.
struct ProvenanceBadge: View {
    let source: MealEntrySource
    var userEdited: Bool = false

    private var symbol: String {
        switch source {
        case .offBarcode, .offSearch: return "checkmark.seal"
        case .llmEstimate: return "sparkles"
        case .manual: return "pencil"
        }
    }

    private var label: String {
        if userEdited { return "Edited" }
        switch source {
        case .offBarcode, .offSearch: return "Verified"
        case .llmEstimate: return "AI estimate"
        case .manual: return "Manual"
        }
    }

    private var color: Color {
        switch source {
        case .offBarcode, .offSearch: return PulseColors.success
        case .llmEstimate: return PulseColors.accent
        case .manual: return PulseColors.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(PulseFont.micro)
            Text(label).font(PulseFont.micro.weight(.semibold)).tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Meal entry row

/// One logged meal in a list: leading food square, name + time, and the kcal/macro strip.
/// Shared by the Nutrition page and the coach chat meal card so both read identically —
/// the same relationship `ActivityWorkoutRow` has with its surfaces.
struct MealEntryRow: View {
    let entry: MealEntry
    var onTap: (() -> Void)?

    /// Meal photo, when the entry was logged from one (bytes live in the attachment store).
    private var photo: UIImage? {
        CoachAttachmentRef.decode(fromJSON: entry.photoRefJSON).first.flatMap { CoachAttachmentStore.loadImage($0) }
    }

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 12) {
                Group {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable().scaledToFill()
                    } else {
                        Image(systemName: "fork.knife")
                            .font(PulseFont.title3.weight(.regular))
                            .foregroundStyle(PulseColors.calories)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(PulseColors.calories.opacity(0.18))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.name)
                            .font(PulseFont.subheadline.weight(.semibold))
                            .foregroundStyle(PulseColors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(SleepFormat.clockTime(entry.timestamp))
                            .font(PulseFont.caption2.weight(.regular).monospacedDigit())
                            .foregroundStyle(PulseColors.textMuted)
                    }
                    HStack(spacing: 8) {
                        Text("\(NutritionFormat.kcal(entry.calories)) kcal")
                            .font(PulseFont.caption.weight(.regular).monospacedDigit())
                            .foregroundStyle(PulseColors.textMuted)
                        macroTag(.protein, entry.proteinG)
                        macroTag(.carbs, entry.carbsG)
                        macroTag(.fat, entry.fatG)
                        if entry.source == .llmEstimate && !entry.userEdited {
                            Image(systemName: "sparkles")
                                .font(PulseFont.micro)
                                .foregroundStyle(PulseColors.accent)
                        }
                    }
                }
            }
            .padding(16)
            .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private func macroTag(_ kind: MacroKind, _ grams: Double) -> some View {
        HStack(spacing: 2) {
            Text(kind.letter).font(PulseFont.caption.weight(.semibold)).foregroundStyle(kind.color)
            Text(NutritionFormat.grams(grams))
                .font(PulseFont.caption.weight(.regular).monospacedDigit())
                .foregroundStyle(PulseColors.textMuted)
        }
    }
}

// MARK: - First-run explainer

/// Shown on the Nutrition page until the first meal is ever logged: one glass card stating
/// what to do and the privacy stance. No modal onboarding.
struct NutritionEmptyStateCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "fork.knife.circle")
                .font(PulseFont.largeTitle.weight(.regular))
                .foregroundStyle(PulseColors.calories)
            Text("Log your first meal")
                .font(PulseFont.bodyEmphasis)
                .foregroundStyle(PulseColors.textPrimary)
            Text("Add meals manually, search the food database, or describe them to your coach. Everything stays on your device.")
                .font(PulseFont.caption.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }
}
