import Foundation
import UserNotifications

// MARK: - Pure crossing engine

/// Per-day latch state for the two battery thresholds, persisted as JSON in UserDefaults so a fired
/// alert isn't repeated on the next battery sample of the same day.
struct BatteryAlertState: Codable, Equatable {
    var dateKey: String = ""
    var firedLow = false        // below-20 fired today
    var firedCritical = false   // below-10 fired today
}

enum BatteryAlertKind: Equatable {
    case low(percent: Int)
    case critical(percent: Int)
}

/// Pure transition function: (new sample, state) -> (alert?, new state).
///
/// Level-triggered + latched: fires when a sample is observed below a threshold that hasn't fired yet
/// — battery samples are sparse (jring reports only on connect), so an edge trigger would miss
/// "connected already at 17%".
enum BatteryAlertEngine {
    static let lowThreshold = 20
    static let criticalThreshold = 10
    /// Re-arm bands (threshold + 5): a recharge above these clears the latch, so bouncing
    /// 19 -> 21 -> 19 can't re-fire but a real recharge re-arms.
    static let lowRearm = 25
    static let criticalRearm = 15

    static func evaluate(percent: Int, state: BatteryAlertState, dateKey: String) -> (alert: BatteryAlertKind?, state: BatteryAlertState) {
        guard (1...100).contains(percent) else { return (nil, state) }   // 0 = ring's unknown placeholder
        var s = state
        if s.dateKey != dateKey { s = BatteryAlertState(dateKey: dateKey) }
        if percent >= lowRearm { s.firedLow = false }
        if percent >= criticalRearm { s.firedCritical = false }
        if percent < criticalThreshold, !s.firedCritical {
            s.firedCritical = true
            s.firedLow = true                     // most severe only: 25 -> 8 fires just the critical alert
            return (.critical(percent: percent), s)
        }
        if percent < lowThreshold, !s.firedLow {
            s.firedLow = true
            return (.low(percent: percent), s)
        }
        return (nil, s)
    }

    /// A calendar-day key (yyyy-MM-dd) so the latch resets each day. Cached formatter — the monitor
    /// evaluates on the sparse battery stream, not per frame, but a shared formatter is still cheaper.
    static func dateKey(for date: Date = Date()) -> String {
        dateKeyFormatter.string(from: date)
    }

    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Monitor

/// Subscribes to `PulseEventBus` and fires a local notification when the ring's battery crosses the
/// low (<20%) / critical (<10%) thresholds. Pure engine + level-latched state persisted in
/// UserDefaults, so a single crossing fires once per day per threshold. Lives for the app lifetime,
/// like `CoachAnomalyMonitor`; started from `PulseLoopApp`.
@MainActor
final class BatteryAlertMonitor {
    /// UserDefaults key gating the feature. **Absent = enabled** (default ON).
    static let enabledKey = "pulseloop.batteryalerts.enabled"
    /// UserDefaults key for the persisted `BatteryAlertState` JSON.
    static let stateKey = "pulseloop.batteryalerts.state.v1"
    /// Stable notification identifier for both severities — a critical alert replaces a pending low one.
    static let notificationIdentifier = "ring.battery.alert"

    private let defaults: UserDefaults
    private var streamTask: Task<Void, Never>?

    /// `defaults` is injectable so the monitor can be exercised against an isolated suite in tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        streamTask?.cancel()
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            let stream = await PulseEventBus.shared.stream()
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: PulseEvent) {
        guard case let .batteryLevel(percent) = event else { return }
        handle(percent: percent, now: Date())
    }

    /// Run the crossing engine for a fresh sample and deliver an alert when one fires. Separated from
    /// the stream so it's directly testable.
    func handle(percent: Int, now: Date) {
        guard isEnabled else { return }
        let state = loadState()
        let (alert, newState) = BatteryAlertEngine.evaluate(
            percent: percent, state: state, dateKey: BatteryAlertEngine.dateKey(for: now)
        )
        if newState != state { saveState(newState) }
        guard let alert else { return }
        Task { await BatteryAlertMonitor.deliver(alert) }
    }

    // MARK: - Enabled + persisted state

    /// Absent key defaults to ON (the user's decision), so the alert works out of the box.
    private var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private func loadState() -> BatteryAlertState {
        guard let data = defaults.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(BatteryAlertState.self, from: data) else {
            return BatteryAlertState()
        }
        return state
    }

    private func saveState(_ state: BatteryAlertState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    // MARK: - Delivery

    /// Deliver a battery alert. No LLM / coach coupling — a plain local notification. Requests
    /// permission once if undetermined and proceeds only if granted; silently skips when denied.
    static func deliver(_ alert: BatteryAlertKind) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
        case .denied:
            return
        default:
            break
        }

        let content = UNMutableNotificationContent()
        switch alert {
        case let .low(percent):
            content.title = "Ring battery low"
            content.body = "Your ring is at \(percent)%. Charge it soon so tracking doesn't stop."
        case let .critical(percent):
            content.title = "Ring battery critically low"
            content.body = "Your ring is at \(percent)% and will shut down soon. Charge it now."
        }
        content.sound = .default
        // Shared identifier: a critical alert replaces a still-pending low one.
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil)
        try? await center.add(request)
    }
}
