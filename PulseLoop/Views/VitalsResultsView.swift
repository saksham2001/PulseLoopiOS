import SwiftUI

/// Results for the combined vitals sweep — the one measurement that returns everything the ring
/// computes at once (jring's `0x24` packet), rather than a single number.
///
/// Lives beside `MeasurementSheet` rather than inside it: the sheet's other four kinds all resolve to
/// one reading in the middle of the ring, and this is the only one that has to lay out a whole grid.
struct VitalsResultsView: View {
    let vitals: RingSyncCoordinator.VitalsReading

    struct VitalTile: Identifiable {
        let name: String
        let value: String
        let unit: String
        let icon: String
        let tint: Color
        var id: String { name }
    }

    /// One tile per metric the sweep actually produced — the ring leaves the rest at zero.
    static func tiles(for v: RingSyncCoordinator.VitalsReading) -> [VitalTile] {
        var tiles: [VitalTile] = []
        if let hr = v.heartRate {
            tiles.append(.init(name: "Heart Rate", value: "\(hr)", unit: "bpm",
                               icon: "heart.fill", tint: PulseColors.heartRate))
        }
        if let bp = v.bloodPressure {
            tiles.append(.init(name: "Blood Pressure", value: "\(bp.systolic)/\(bp.diastolic)", unit: "mmHg",
                               icon: "heart.text.square", tint: PulseColors.bloodPressure))
        }
        if let spo2 = v.spo2 {
            tiles.append(.init(name: "Blood Oxygen", value: "\(spo2)", unit: "%",
                               icon: "lungs.fill", tint: PulseColors.spo2))
        }
        if let fatigue = v.fatigue {
            tiles.append(.init(name: "Fatigue", value: "\(fatigue)", unit: "",
                               icon: "battery.25", tint: PulseColors.warning))
        }
        if let stress = v.stress {
            tiles.append(.init(name: "Stress", value: "\(stress)", unit: "",
                               icon: "bolt.fill", tint: PulseColors.stress))
        }
        if let hrv = v.hrv {
            tiles.append(.init(name: "HRV", value: "\(hrv)", unit: "ms",
                               icon: "waveform.path.ecg", tint: PulseColors.hrv))
        }
        if let sugar = v.bloodSugarMgdl {
            tiles.append(.init(name: "Blood Sugar", value: "\(Int(sugar.rounded()))", unit: "mg/dL",
                               icon: "drop.fill", tint: PulseColors.bloodSugar))
        }
        return tiles
    }

    /// Sits at the top of the sheet — the confirmation is a compact inline row so the cards get the
    /// vertical space. Centring them pushed the first row off the top on small phones.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(PulseFont.footnote.weight(.bold))
                    .foregroundStyle(PulseColors.success)
                    .frame(width: 30, height: 30)
                    .background(PulseColors.success.opacity(0.10), in: Circle())
                    .overlay(Circle().stroke(PulseColors.success.opacity(0.3), lineWidth: 1))
                Text("Reading complete")
                    .font(PulseFont.bodyEmphasis)
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer(minLength: 0)
            }

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(Self.tiles(for: vitals)) { tile in
                        card(tile)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 24)
    }

    private func card(_ tile: VitalTile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: tile.icon).font(PulseFont.footnote).foregroundStyle(tile.tint)
                Text(tile.name)
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tile.value)
                    .font(PulseFont.numberXL).monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if !tile.unit.isEmpty {
                    Text(tile.unit).font(PulseFont.caption).foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(PulseColors.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}
