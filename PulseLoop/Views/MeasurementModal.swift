import SwiftUI
import SwiftData

/// Live measurement sheet ported from `frontend/src/components/measurement/MeasurementModal.tsx`.
/// Drives the existing `RingSyncCoordinator` measure flow when the ring is connected; otherwise
/// simulates a reading and saves a mock `Measurement` so the demo charts update.
struct MeasurementSheet: View {
    /// `.vitals` is one sweep that returns every metric the ring computes (jring's `0x24` packet);
    /// the rest are single-metric spot readings on devices that measure one thing at a time.
    enum Kind: Hashable { case hr, spo2, hrv, bloodPressure, vitals }
    enum Phase { case preparing, measuring, result, error }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator

    @State private var phase: Phase = .preparing
    @State private var value: Int?
    /// Diastolic, for blood pressure — the only single reading that is a pair.
    @State private var secondaryValue: Int?
    /// Populated for `.vitals`: every metric the sweep returned.
    @State private var vitals: RingSyncCoordinator.VitalsReading?
    @State private var animate = false

    private var color: Color {
        switch kind {
        case .hr, .vitals: return PulseColors.heartRate
        case .spo2: return PulseColors.spo2
        case .hrv: return PulseColors.hrv
        case .bloodPressure: return PulseColors.bloodPressure
        }
    }
    private var name: String {
        switch kind {
        case .hr: return "Heart Rate"
        case .spo2: return "Blood Oxygen"
        case .hrv: return "Heart Rate Variability"
        case .bloodPressure: return "Blood Pressure"
        case .vitals: return "Vitals"
        }
    }
    private var unit: String {
        switch kind {
        case .hr, .vitals: return "bpm"
        case .spo2: return "%"
        case .hrv: return "ms"
        case .bloodPressure: return "mmHg"
        }
    }
    private var instruction: String {
        switch kind {
        case .hr: return "Keep your hand still and rest your wrist on a flat surface."
        case .spo2: return "Breathe normally. Keep the sensor pressed firmly to your skin."
        case .hrv: return "Sit still and breathe normally — HRV needs a steady stretch of beats."
        case .bloodPressure: return "Sit upright, rest your hand at heart height, and stay still."
        case .vitals: return "Sit upright, rest your hand at heart height, and stay still. This takes about a minute."
        }
    }

    /// The big number in the ring. Blood pressure shows the systolic/diastolic pair.
    private var readingText: String? {
        guard let value else { return nil }
        if kind == .bloodPressure, let secondaryValue { return "\(value)/\(secondaryValue)" }
        return "\(value)"
    }

    /// One row per metric the sweep actually produced — the ring leaves the rest at zero.
    private var vitalTiles: [VitalTile] {
        guard let v = vitals else { return [] }
        var tiles: [VitalTile] = []
        if let hr = v.heartRate {
            tiles.append(.init(name: "Heart Rate", value: "\(hr)", unit: "bpm", icon: "heart.fill", tint: PulseColors.heartRate))
        }
        if let bp = v.bloodPressure {
            tiles.append(.init(name: "Blood Pressure", value: "\(bp.systolic)/\(bp.diastolic)", unit: "mmHg", icon: "heart.text.square", tint: PulseColors.bloodPressure))
        }
        if let spo2 = v.spo2 {
            tiles.append(.init(name: "Blood Oxygen", value: "\(spo2)", unit: "%", icon: "lungs.fill", tint: PulseColors.spo2))
        }
        if let fatigue = v.fatigue {
            tiles.append(.init(name: "Fatigue", value: "\(fatigue)", unit: "", icon: "battery.25", tint: PulseColors.warning))
        }
        if let stress = v.stress {
            tiles.append(.init(name: "Stress", value: "\(stress)", unit: "", icon: "bolt.fill", tint: PulseColors.stress))
        }
        if let hrv = v.hrv {
            tiles.append(.init(name: "HRV", value: "\(hrv)", unit: "ms", icon: "waveform.path.ecg", tint: PulseColors.hrv))
        }
        if let sugar = v.bloodSugarMgdl {
            tiles.append(.init(name: "Blood Sugar", value: "\(Int(sugar.rounded()))", unit: "mg/dL", icon: "drop.fill", tint: PulseColors.bloodSugar))
        }
        return tiles
    }

    struct VitalTile: Identifiable {
        let name: String
        let value: String
        let unit: String
        let icon: String
        let tint: Color
        var id: String { name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase == .result ? "RESULTS" : "MEASURING")
                        .font(PulseFont.micro).tracking(1.8)
                        .foregroundStyle(PulseColors.textMuted)
                    Text(name).font(PulseFont.title3).foregroundStyle(PulseColors.textPrimary)
                }
                Spacer()
                Button(closeTitle) { dismiss() }
                    .font(PulseFont.footnote.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(PulseColors.card, in: Capsule())
                    .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
            .padding(24)

            // The combined results sit directly under the header — several cards need the height, and
            // centring them pushed the first row off the top on small phones.
            if phase == .result, kind == .vitals {
                vitalsResults
                Spacer(minLength: 0)
            } else {
                measuringContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PulseColors.background.ignoresSafeArea())
        .task { await run() }
        .onAppear { animate = true }
    }

    /// The pulsing ring (and the single-metric result), vertically centred.
    @ViewBuilder
    private var measuringContent: some View {
        VStack(spacing: 0) {
            Spacer()

            if phase == .error {
                errorState
            } else {
                ZStack {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(color.opacity(0.5), lineWidth: 2)
                            .frame(width: 200, height: 200)
                            .scaleEffect(animate ? 1.15 : 0.85)
                            .opacity(animate ? 0 : 0.6)
                            .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(i) * 0.5), value: animate)
                    }
                    Circle().fill(color.opacity(0.12)).frame(width: 220, height: 220)
                    VStack(spacing: 4) {
                        if let readingText, phase != .preparing {
                            // `numberHero`, not `nano` (9pt) — this is the sheet's centrepiece. The
                            // scale factor keeps a two-part reading like "120/80" on one line.
                            Text(readingText).font(PulseFont.numberHero).monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .foregroundStyle(PulseColors.textPrimary)
                            Text(unit.uppercased()).font(PulseFont.caption.weight(.regular)).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                        } else {
                            Text(phase == .preparing ? "READY" : "MEASURING")
                                .font(PulseFont.subheadline).tracking(1.8)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                    }
                    // Bound the reading to the inner circle so `minimumScaleFactor` has something to
                    // shrink against rather than overflowing the ring.
                    .frame(maxWidth: 190)
                }
                .frame(height: 240)

                Text(phaseCopy)
                    .font(PulseFont.subheadline.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 24)
            }

            Spacer()

            if phase == .result {
                Text("Saved")
                    .font(PulseFont.subheadline)
                    .foregroundStyle(PulseColors.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(PulseColors.success.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.success.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
    }

    /// The combined sweep stays open until dismissed — there's more than one number to read.
    private var closeTitle: String {
        if phase == .measuring { return "Finish" }
        if phase == .result, kind == .vitals { return "Done" }
        return "Cancel"
    }

    /// Result view for the combined sweep: one card per metric the ring actually returned. Sits at the
    /// top of the sheet — the confirmation is a compact inline row so the cards get the vertical space.
    private var vitalsResults: some View {
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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(vitalTiles) { tile in
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
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 24)
    }

    private var errorMessage: String {
        guard ble.state == .connected else {
            return "Your ring isn't connected. Reconnect it and try again."
        }
        switch kind {
        case .hr:
            return "Couldn't get a heart-rate reading. Make sure the ring is snug and worn on your finger, then try again."
        case .spo2:
            return "Couldn't get a blood-oxygen reading. Wear the ring snugly and keep still, then try again."
        case .hrv:
            return "Couldn't get an HRV reading. Wear the ring snugly, keep still, and try again."
        case .bloodPressure:
            return "Couldn't get a blood-pressure reading. Wear the ring snugly, rest your hand at heart height, and try again."
        case .vitals:
            return "Couldn't get a reading. Wear the ring snugly, keep still, and try again."
        }
    }

    private var phaseCopy: String {
        switch phase {
        case .preparing: return instruction
        case .measuring:
            switch kind {
            case .spo2: return "Measuring SpO₂… keep your hand still."
            case .bloodPressure: return "Measuring blood pressure… stay still."
            case .vitals: return "Measuring your vitals… stay still."
            default: return "Measuring… stay still."
            }
        case .result: return "Reading saved."
        case .error: return ""
        }
    }

    private var errorState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark")
                .font(PulseFont.title.weight(.bold))
                .foregroundStyle(PulseColors.danger)
                .frame(width: 80, height: 80)
                .background(PulseColors.danger.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(PulseColors.danger.opacity(0.3), lineWidth: 1))
            Text(errorMessage)
                .font(PulseFont.subheadline.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
            Button("Close") { dismiss() }
                .font(PulseFont.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(PulseColors.accent, in: Capsule())
        }
    }

    @MainActor
    private func run() async {
        phase = .preparing
        try? await Task.sleep(for: .seconds(1.2))
        phase = .measuring

        if kind == .vitals {
            await runCombinedVitals()
            return
        }

        let result: Int?
        if ble.state == .connected {
            switch kind {
            case .hr: result = await coordinator.measureHR()
            case .spo2: result = await coordinator.measureSpO2()
            case .hrv: result = await coordinator.measureHRV()
            case .bloodPressure:
                let reading = await coordinator.measureBloodPressure()
                secondaryValue = reading?.diastolic
                result = reading?.systolic
            case .vitals: return   // handled by `runCombinedVitals` above
            }
        } else {
            // Demo mode: simulate the measurement window, then persist a mock reading.
            try? await Task.sleep(for: .seconds(kind == .hr ? 2.2 : 3.0))
            if kind == .bloodPressure {
                // BP is stored as two rows so each trends independently — mock both.
                MetricsService.insertMockMeasurement(kind: .bloodPressureSystolic, context: modelContext)
                MetricsService.insertMockMeasurement(kind: .bloodPressureDiastolic, context: modelContext)
                let rows = MetricsService.fetchMeasurements(modelContext)
                secondaryValue = rows.first { $0.kind == .bloodPressureDiastolic }.map { Int($0.value) }
                result = rows.first { $0.kind == .bloodPressureSystolic }.map { Int($0.value) }
            } else {
                let measurementKind: MeasurementKind = {
                    switch kind {
                    case .hr: return .heartRate
                    case .spo2: return .spo2
                    case .hrv: return .hrv
                    // Both handled before reaching here (BP just above, vitals in `runCombinedVitals`).
                    case .bloodPressure, .vitals: return .bloodPressureSystolic
                    }
                }()
                MetricsService.insertMockMeasurement(kind: measurementKind, context: modelContext)
                result = MetricsService.fetchMeasurements(modelContext)
                    .first(where: { $0.kind == measurementKind })
                    .map { Int($0.value) }
            }
        }
        guard let result else { phase = .error; return }
        // A BP reading without its diastolic half is not a usable reading.
        if kind == .bloodPressure, secondaryValue == nil { phase = .error; return }
        value = result
        phase = .result
        try? await Task.sleep(for: .seconds(1.3))
        dismiss()
    }

    /// One sweep, every metric. Unlike the single-metric flows this does **not** auto-dismiss — there
    /// are several numbers to read, so the sheet waits for "Done".
    @MainActor
    private func runCombinedVitals() async {
        if ble.state == .connected {
            vitals = await coordinator.measureVitals()
        } else {
            // Demo mode: mock the metrics the jring's combined packet actually carries.
            try? await Task.sleep(for: .seconds(3.0))
            for kind in [MeasurementKind.heartRate, .spo2, .bloodPressureSystolic, .bloodPressureDiastolic] {
                MetricsService.insertMockMeasurement(kind: kind, context: modelContext)
            }
            let rows = MetricsService.fetchMeasurements(modelContext)
            func latest(_ k: MeasurementKind) -> Int? { rows.first { $0.kind == k }.map { Int($0.value) } }
            var bloodPressure: RingSyncCoordinator.BloodPressureReading?
            if let systolic = latest(.bloodPressureSystolic), let diastolic = latest(.bloodPressureDiastolic) {
                bloodPressure = .init(systolic: systolic, diastolic: diastolic)
            }
            vitals = RingSyncCoordinator.VitalsReading(
                heartRate: latest(.heartRate),
                bloodPressure: bloodPressure,
                spo2: latest(.spo2)
            )
        }
        guard let vitals, !vitals.isEmpty else { phase = .error; return }
        phase = .result
    }
}
