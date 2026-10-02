import SwiftUI
import SwiftData

/// The Vitals-tab cycle card: countdown headline, day + phase, a sparkline of this cycle's
/// nightly temperatures, and — around the predicted date — the one-tap "My period started"
/// button. Tapping the card opens the full detail screen.
struct CycleVitalsCard: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @State private var overview: CycleOverview?
    @State private var dataChange = PulseDataChange.shared
    @State private var settings = CycleSettingsStore.shared

    var body: some View {
        // Not one big Button: the "My period started" button lives inside the card, and
        // nested buttons fight over taps. The info area navigates; the action button acts.
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { path.append(AppRoute.cycleDetail) }

                if CycleCopy.shouldOfferPeriodStart(overview?.analysis) {
                    PeriodStartButton { logPeriodToday() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(PulseColors.cycle).frame(width: 8, height: 8)
            Text("CYCLE")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PulseColors.textMuted)
            Spacer()
            if let analysis = overview?.analysis {
                Text(CycleCopy.phaseLabel(analysis, hormonal: settings.settings.onHormonalContraception))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PulseColors.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(PulseColors.cardSoft, in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PulseColors.textMuted)
        }
    }

    @ViewBuilder private var content: some View {
        if let analysis = overview?.analysis {
            Text(CycleCopy.headline(analysis, hormonal: settings.settings.onHormonalContraception))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(PulseColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(CycleCopy.subtitle(analysis, hormonal: settings.settings.onHormonalContraception))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PulseColors.textMuted)

            let temps = (overview?.chartDays ?? []).filter { !$0.excluded }.compactMap(\.temperature)
            if temps.count > 1 {
                MiniSparkline(values: temps, color: PulseColors.cycle)
                    .frame(height: 30)
            }
        } else {
            Text("Set up cycle tracking")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(PulseColors.textPrimary)
            Text("Log your first period day — temperatures are already being collected while you sleep.")
                .font(.system(size: 12))
                .foregroundStyle(PulseColors.textMuted)
        }
    }

    private func reload() {
        overview = CycleService.overview(context: modelContext)
    }

    private func logPeriodToday() {
        let day = CycleRepository.dayOrNew(for: Date(), context: modelContext)
        day.isPeriod = true
        CycleRepository.save(day, context: modelContext)
        CycleNotificationCenter.shared.scheduleNext()
        reload()
    }
}

/// The one-tap happy path. Kept as its own small view so the card and the detail screen
/// render it identically.
struct PeriodStartButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("My period started", systemImage: "drop.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(PulseColors.textPrimary)
                .background(PulseColors.cycle.opacity(0.18))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(PulseColors.cycle.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
