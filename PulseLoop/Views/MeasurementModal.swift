import SwiftUI
import SwiftData

/// Live measurement sheet ported from `frontend/src/components/measurement/MeasurementModal.tsx`.
/// Drives the existing `RingSyncCoordinator` measure flow when the ring is connected; otherwise
/// simulates a reading and saves a mock `Measurement` so the demo charts update.
struct MeasurementSheet: View {
    enum Kind { case hr, spo2 }
    enum Phase { case preparing, measuring, result, error }

    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(RingBLEClient.self) private var ble
    @Environment(RingSyncCoordinator.self) private var coordinator

    @State private var phase: Phase = .preparing
    @State private var value: Int?
    @State private var animate = false

    private var color: Color { kind == .hr ? PulseColors.heartRate : PulseColors.spo2 }
    private var name: String { kind == .hr ? "Heart Rate" : "Blood Oxygen" }
    private var unit: String { kind == .hr ? "bpm" : "%" }
    private var instruction: String {
        kind == .hr
            ? "Keep your hand still and rest your wrist on a flat surface."
            : "Breathe normally. Keep the sensor pressed firmly to your skin."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEASURING")
                        .font(.system(size: 10, weight: .medium)).tracking(1.8)
                        .foregroundStyle(PulseColors.textMuted)
                    Text(name).font(.system(size: 18, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                }
                Spacer()
                Button(phase == .measuring ? "Finish" : "Cancel") { dismiss() }
                    .font(.system(size: 13))
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
                        if let value, phase != .preparing {
                            Text("\(value)").font(.system(size: 52, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                            Text(unit.uppercased()).font(.system(size: 12)).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                        } else {
                            Text(phase == .preparing ? "READY" : "MEASURING")
                                .font(.system(size: 14, weight: .medium)).tracking(1.8)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                    }
                }
                .frame(height: 240)

                Text(phaseCopy)
                    .font(.system(size: 14))
                    .foregroundStyle(PulseColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.top, 24)
            }

            Spacer()

            if phase == .result {
                Text("Saved")
                    .font(.system(size: 14, weight: .medium))
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

    private var phaseCopy: String {
        switch phase {
        case .preparing: return instruction
        case .measuring: return kind == .spo2 ? "Measuring SpO₂… keep your hand still." : "Measuring… stay still."
        case .result: return "Reading saved."
        case .error: return ""
        }
    }

    private var errorState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(PulseColors.danger)
                .frame(width: 80, height: 80)
                .background(PulseColors.danger.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(PulseColors.danger.opacity(0.3), lineWidth: 1))
            Text("Measurement didn't complete. Keep the ring connected and try again.")
                .font(.system(size: 14)).foregroundStyle(PulseColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
            Button("Close") { dismiss() }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
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
            result = kind == .hr ? await coordinator.measureHR() : await coordinator.measureSpO2()
        } else {
            // Demo mode: simulate the measurement window, then persist a mock reading.
            try? await Task.sleep(for: .seconds(kind == .hr ? 2.2 : 3.0))
            let measurementKind: MeasurementKind = kind == .hr ? .heartRate : .spo2
            MetricsService.insertMockMeasurement(kind: measurementKind, context: modelContext)
            result = MetricsService.fetchMeasurements(modelContext)
                .first(where: { $0.kind == measurementKind })
                .map { Int($0.value) }
        }
        guard let result else { phase = .error; return }
        value = result
        phase = .result
        try? await Task.sleep(for: .seconds(1.3))
        dismiss()
    }
}
