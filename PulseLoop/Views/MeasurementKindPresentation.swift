import SwiftUI

/// Everything the measurement sheet renders that depends only on *which* metric is being measured.
///
/// Kept apart from `MeasurementSheet` so the sheet is about the measurement's lifecycle — the stages,
/// the clock, the ring — and adding a sixth metric is a matter of answering these questions once,
/// rather than threading a new case through the middle of the state machine.
extension MeasurementSheet.Kind {
    var title: String {
        switch self {
        case .hr: return "Heart Rate"
        case .spo2: return "Blood Oxygen"
        case .hrv: return "Heart Rate Variability"
        case .bloodPressure: return "Blood Pressure"
        case .vitals: return "Vitals"
        }
    }

    var unit: String {
        switch self {
        case .hr, .vitals: return "bpm"
        case .spo2: return "%"
        case .hrv: return "ms"
        case .bloodPressure: return "mmHg"
        }
    }

    var tint: Color {
        switch self {
        case .hr, .vitals: return PulseColors.heartRate
        case .spo2: return PulseColors.spo2
        case .hrv: return PulseColors.hrv
        case .bloodPressure: return PulseColors.bloodPressure
        }
    }

    var symbolName: String {
        switch self {
        case .hr, .vitals: return "heart.fill"
        case .spo2: return "lungs.fill"
        case .hrv: return "waveform.path.ecg"
        case .bloodPressure: return "heart.text.square"
        }
    }

    /// Shown while the sheet holds before arming — what the user should do to make the reading work.
    var instruction: String {
        switch self {
        case .hr: return "Rest your wrist on a flat surface and keep still."
        case .spo2: return "Keep the ring pressed firmly to your skin and breathe normally."
        case .hrv: return "Sit still and breathe normally — HRV needs a steady stretch of beats."
        case .bloodPressure: return "Sit upright, rest your hand at heart height, and stay still."
        case .vitals: return "Sit upright, rest your hand at heart height, and stay still. This takes about a minute."
        }
    }

    /// Shown under the ring while the measurement runs.
    var workingCopy: String {
        switch self {
        case .hr: return "Finding your pulse…"
        case .spo2: return "Reading blood oxygen…"
        case .hrv: return "Reading heart rate variability…"
        case .bloodPressure: return "Measuring blood pressure…"
        case .vitals: return "Measuring your vitals…"
        }
    }

    /// What went wrong, phrased as the thing the user can actually do about it.
    var failureMessage: String {
        switch self {
        case .hr:
            // HR's failure mode is now "we read you, but the numbers never agreed" — see
            // `HRSampleWindow`. Stillness is the lever the user has, so the copy asks for stillness.
            return "Couldn't get a steady heart-rate reading. Keep the ring snug and your hand still, then try again."
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

    /// SpO₂ breathes rather than beats — its ambient pulse runs at a slower cadence.
    var slowBreathing: Bool { self == .spo2 }
}

/// The header eyebrow — the one place the sheet names the stage the user is in.
extension MeasurementSheet.Stage {
    func eyebrow(isCombinedSweep: Bool) -> String {
        switch self {
        case .preparing: return "GET READY"
        case .searching, .locking: return "MEASURING"
        case .result: return isCombinedSweep ? "RESULTS" : "COMPLETE"
        case .error: return "ISSUE"
        }
    }

    func eyebrowColor(tint: Color) -> Color {
        switch self {
        case .preparing: return PulseColors.textMuted
        case .searching, .locking: return tint
        case .result: return PulseColors.success
        case .error: return PulseColors.danger
        }
    }
}
