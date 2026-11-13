import SwiftUI

/// The Sleep page's circadian tile: the semicircular dial with its one-line read. Tapping it
/// opens `CircadianDetailSheet`.
struct CircadianRhythmCard: View {
    let snapshot: CircadianSnapshot
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .top) {
                CircadianDial(snapshot: snapshot, shape: .semicircle)
                    // Cap the dial so it stays a compact tile on the widest phones.
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity)
                HStack {
                    Text("CIRCADIAN")
                        .font(PulseFont.caption2)
                        .tracking(1.8)
                        .foregroundStyle(PulseColors.textMuted)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .pulseGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.accessibilitySummary)
        .accessibilityHint("Opens circadian rhythm details")
        .accessibilityAddTraits(.isButton)
    }
}

extension CircadianSnapshot {
    /// The dial in words, for VoiceOver.
    var accessibilitySummary: String {
        var parts = ["Circadian rhythm", headline]
        if !subline.isEmpty { parts.append(subline) }
        for anchor in anchors {
            if let delta = anchor.deltaMinutes {
                parts.append("\(anchor.kind.label) \(CircadianFormat.spoken(delta))")
            }
        }
        for workout in workouts {
            parts.append("\(workout.isTypical ? "Typical workout" : workout.label) at \(CircadianFormat.clock(workout.startMinutes))")
        }
        return parts.joined(separator: ". ")
    }
}

/// The expanded view: the full 24-hour dial, how to read it, each event's time against its
/// usual, and prompts that carry the picture into a coach chat.
struct CircadianDetailSheet: View {
    let snapshot: CircadianSnapshot
    /// "Today · Fri, Nov 13" or "Past 7 days".
    let periodTitle: String
    let coachEnabled: Bool
    /// Called with the chosen question; the presenter closes this sheet and opens the coach.
    let onAskCoach: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(periodTitle)
                        .font(PulseFont.caption)
                        .foregroundStyle(PulseColors.textSecondary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                        .frame(maxWidth: .infinity, alignment: .center)

                    CircadianDial(snapshot: snapshot, shape: .full)
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity)
                        .pulseGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(snapshot.accessibilitySummary)

                    CircadianLegend()

                    if !rows.isEmpty { eventList }

                    Text(footnote)
                        .font(PulseFont.caption.weight(.regular))
                        .foregroundStyle(PulseColors.textMuted)
                        .padding(.horizontal, 4)

                    if coachEnabled { coachPrompts }
                }
                .padding(16)
            }
            .background(PulseColors.background)
            .navigationTitle("Circadian rhythm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Event list

    private enum Row: Identifiable {
        case anchor(CircadianAnchor)
        case workout(CircadianWorkout)

        var id: String {
            switch self {
            case .anchor(let a): return "anchor-\(a.id)"
            case .workout(let w): return "workout-\(w.id)"
            }
        }

        /// Minutes since the 4 AM day boundary, so the list reads in the order the day happens.
        var sortKey: Double {
            let minutes: Double
            switch self {
            case .anchor(let a): minutes = a.periodMinutes ?? a.displayMinutes
            case .workout(let w): minutes = w.startMinutes
            }
            return CircadianMath.normalize(minutes - CircadianDialGeometry.dayStartMinutes)
        }
    }

    private var rows: [Row] {
        (snapshot.anchors.map(Row.anchor) + snapshot.workouts.map(Row.workout)).sorted { $0.sortKey < $1.sortKey }
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                switch row {
                case .anchor(let anchor): anchorRow(anchor)
                case .workout(let workout): workoutRow(workout)
                }
                if index < rows.count - 1 {
                    Divider().overlay(PulseColors.borderSubtle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .pulseGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func anchorRow(_ anchor: CircadianAnchor) -> some View {
        let delta = anchor.deltaMinutes
        let offRhythm = abs(delta ?? 0) >= CircadianEngine.driftThreshold
        let detail: String
        if let delta {
            detail = CircadianFormat.words(delta)
        } else if anchor.periodMinutes == nil {
            detail = snapshot.scope == .day ? "Not recorded" : "No data"
        } else {
            detail = ""
        }
        return eventRow(
            symbol: anchor.kind.symbol,
            tint: anchor.kind.isMeal ? PulseColors.textPrimary.opacity(0.85) : PulseColors.sleep,
            title: anchor.kind.label,
            subtitle: anchor.usualMinutes.map { "Usually \(CircadianFormat.clock($0))" } ?? "No usual yet",
            value: anchor.periodMinutes.map(CircadianFormat.clock) ?? "—",
            detail: detail,
            detailColor: offRhythm ? PulseColors.rhythm : PulseColors.textSecondary,
            spoken: delta.map(CircadianFormat.spoken)
        )
    }

    private func workoutRow(_ workout: CircadianWorkout) -> some View {
        eventRow(
            symbol: workout.category.symbol,
            tint: PulseColors.success,
            title: workout.isTypical ? "Workout" : workout.label,
            subtitle: workout.isTypical ? "Typical time" : workout.category.label,
            value: CircadianFormat.clock(workout.startMinutes),
            detail: CircadianFormat.duration(workout.durationMinutes),
            detailColor: PulseColors.textSecondary,
            spoken: nil
        )
    }

    private func eventRow(
        symbol: String, tint: Color, title: String, subtitle: String,
        value: String, detail: String, detailColor: Color, spoken: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(PulseColors.cardSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PulseFont.callout.weight(.semibold)).foregroundStyle(PulseColors.textPrimary)
                Text(subtitle).font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(PulseFont.callout.weight(.semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
                // Always a line (a space when empty) so every row is the same height.
                Text(detail.isEmpty ? " " : detail).font(PulseFont.caption).monospacedDigit().foregroundStyle(detailColor)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value, spoken ?? detail, subtitle].filter { !$0.isEmpty && $0 != "—" }.joined(separator: ", "))
    }

    private var footnote: String {
        let window = snapshot.scope == .day ? "the 30 days before this day" : "the 30 days before this period"
        return "Usual is your average over \(window), or as many of them as you've tracked. "
            + "It needs at least 5 nights, and a missed night doesn't reset it. "
            + "Choose what appears here in Settings, under Circadian rhythm."
    }

    // MARK: Coach

    private var coachPrompts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASK YOUR COACH")
                .font(PulseFont.caption2)
                .tracking(1.8)
                .foregroundStyle(PulseColors.textMuted)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(snapshot.coachPrompts, id: \.self) { prompt in
                Button { onAskCoach(prompt) } label: {
                    CoachFollowUpChipLabel(text: prompt)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the coach with this question")
            }
        }
        .padding(.top, 4)
    }
}

/// How to read the dial: which way a bar points, and what the two colored bands are.
private struct CircadianLegend: View {
    private enum Glyph { case later, earlier, sleep, workout }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("READING THE DIAL")
                .font(PulseFont.caption2)
                .tracking(1.8)
                .foregroundStyle(PulseColors.textMuted)
                .accessibilityAddTraits(.isHeader)
            Text("Each icon sits at your usual time. A gold bar shows how far you were from it: the longer the bar, the bigger the gap.")
                .font(PulseFont.caption.weight(.regular))
                .foregroundStyle(PulseColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    item(.later, "Bar pointing out", "Later than usual")
                    item(.earlier, "Bar pointing in", "Earlier than usual")
                }
                GridRow {
                    item(.sleep, "Violet band", "Your usual sleep")
                    item(.workout, "Green band", "A workout")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func item(_ glyph: Glyph, _ title: String, _ meaning: String) -> some View {
        HStack(spacing: 8) {
            Canvas { context, size in
                draw(glyph, in: &context, size: size)
            }
            .frame(width: 30, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PulseFont.caption).foregroundStyle(PulseColors.textPrimary)
                Text(meaning).font(PulseFont.caption2.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A small slice of the dial: a piece of track, and either a node with its bar or a colored band.
    private func draw(_ glyph: Glyph, in context: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        var track = Path()
        track.move(to: CGPoint(x: 2, y: midY + 3))
        track.addQuadCurve(to: CGPoint(x: size.width - 2, y: midY + 3), control: CGPoint(x: size.width / 2, y: midY - 4))
        let trackStyle = StrokeStyle(lineWidth: 5, lineCap: .round)
        switch glyph {
        case .sleep:
            context.stroke(track, with: .color(PulseColors.accent.opacity(0.65)), style: trackStyle)
        case .workout:
            context.stroke(track, with: .color(PulseColors.elevated), style: trackStyle)
            context.stroke(track.trimmedPath(from: 0.3, to: 0.7), with: .color(PulseColors.success),
                           style: StrokeStyle(lineWidth: 5, lineCap: .butt))
        case .later, .earlier:
            context.stroke(track, with: .color(PulseColors.elevated), style: trackStyle)
            let node = CGPoint(x: size.width / 2, y: midY - 0.5)
            var bar = Path()
            if glyph == .later {
                bar.move(to: CGPoint(x: node.x, y: node.y - 6))
                bar.addLine(to: CGPoint(x: node.x, y: node.y - 11))
            } else {
                bar.move(to: CGPoint(x: node.x, y: node.y + 6))
                bar.addLine(to: CGPoint(x: node.x, y: node.y + 11))
            }
            context.stroke(bar, with: .color(PulseColors.rhythm), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let disc = Path(ellipseIn: CGRect(x: node.x - 4, y: node.y - 4, width: 8, height: 8))
            context.fill(disc, with: .color(PulseColors.cardSoft))
            context.stroke(disc, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
    }
}
