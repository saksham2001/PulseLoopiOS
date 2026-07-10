import SwiftUI
import SwiftData

/// Live measurement sheet ported from `frontend/src/components/measurement/MeasurementModal.tsx`.
/// Drives the existing `RingSyncCoordinator` measure flow when the ring is connected; otherwise
/// simulates a reading and saves a mock `Measurement` so the demo charts update.
struct MeasurementSheet: View {
    enum Kind: Hashable { case hr, spo2, hrv, bloodPressure }
    enum Phase { case preparing, measuring, result, error }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator

    @State private var phase: Phase = .preparing
    @State private var value: Int?
    /// Diastolic, for blood pressure — the only reading that is a pair.
    @State private var secondaryValue: Int?
    @State private var animate = false

    private var color: Color {
        switch kind {
        case .hr: return PulseColors.heartRate
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
        }
    }
    private var unit: String {
        switch kind {
        case .hr: return "bpm"
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
        }
    }

    /// The big number in the ring. Blood pressure shows the systolic/diastolic pair.
    private var readingText: String? {
        guard let value else { return nil }
        if kind == .bloodPressure, let secondaryValue { return "\(value)/\(secondaryValue)" }
        return "\(value)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEASURING")
                        .font(PulseFont.micro).tracking(1.8)
                        .foregroundStyle(PulseColors.textMuted)
                    Text(name).font(PulseFont.title3).foregroundStyle(PulseColors.textPrimary)
                }
                Spacer()
                Button(phase == .measuring ? "Finish" : "Cancel") { dismiss() }
                    .font(PulseFont.footnote.weight(.regular))
                    .foregroundStyle(PulseColors.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(PulseColors.card, in: Capsule())
                    .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
            .padding(24)

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
                            Text(readingText).font(PulseFont.nano).monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                            Text(unit.uppercased()).font(PulseFont.caption.weight(.regular)).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                        } else {
                            Text(phase == .preparing ? "READY" : "MEASURING")
                                .font(PulseFont.subheadline).tracking(1.8)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PulseColors.background.ignoresSafeArea())
        .task { await run() }
        .onAppear { animate = true }
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
        }
    }

    private var phaseCopy: String {
        switch phase {
        case .preparing: return instruction
        case .measuring:
            switch kind {
            case .spo2: return "Measuring SpO₂… keep your hand still."
            case .bloodPressure: return "Measuring blood pressure… stay still."
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
                    case .bloodPressure: return .bloodPressureSystolic   // handled above
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
}
