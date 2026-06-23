//
//  PulseLoopApp.swift
//  PulseLoop
//
//  Created by Saksham Bhutani on 5/31/26.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct PulseLoopApp: App {
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer
    @State private var bleClient: RingBLEClient
    @State private var coordinator: RingSyncCoordinator
    @State private var gpsRecorder: GpsRouteRecorder
    @State private var liveWorkout: LiveWorkoutManager
    /// Retained for app lifetime so it keeps draining the event bus into SwiftData.
    private let persistence: EventPersistenceSubscriber
    /// Retained so it keeps regenerating Today/Sleep coach summaries on new data.
    private let summaryCoordinator: CoachSummaryCoordinator
    /// Retained so it keeps recording the structured wearable diagnostics timeline.
    private let diagnostics: DiagnosticsSubscriber
    /// Retained so the UNUserNotificationCenter delegate stays alive.
    private let notificationDelegate = CoachNotificationDelegate()

    /// True when the app host is launched by the XCTest runner. Unit tests build their own
    /// in-memory stores and never touch the live BLE/notification stack, so the app host must
    /// not spin those up: on the headless CI simulator CoreBluetooth's XPC service and the
    /// on-disk SwiftData store are unavailable, and starting them hangs/crashes the test host.
    private static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    init() {
        let runningTests = Self.isRunningUnitTests

        let container: ModelContainer
        do {
            // Under tests, use an isolated in-memory store instead of the on-disk `default.store`
            // (which fails to create in the sandboxed CI simulator).
            container = try ModelContainerFactory.make(inMemory: runningTests)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        self.container = container

        // One-time cleanup of activity totals inflated by the old accumulator bug.
        ActivityService.migrateInflatedActivityIfNeeded(context: container.mainContext)

        // Don't bring up CoreBluetooth under tests (see `isRunningUnitTests`).
        let client = RingBLEClient(startManager: !runningTests)
        let coordinator = RingSyncCoordinator(client: client, context: container.mainContext)
        client.onConnected = { [weak coordinator] in coordinator?.runStartupSequence() }
        let gps = GpsRouteRecorder()
        _bleClient = State(initialValue: client)
        _coordinator = State(initialValue: coordinator)
        _gpsRecorder = State(initialValue: gps)
        _liveWorkout = State(initialValue: LiveWorkoutManager(coordinator: coordinator, gps: gps, context: container.mainContext))

        let subscriber = EventPersistenceSubscriber(context: container.mainContext)
        self.persistence = subscriber
        self.summaryCoordinator = CoachSummaryCoordinator(context: container.mainContext)
        let diagnostics = DiagnosticsSubscriber(context: container.mainContext)
        self.diagnostics = diagnostics

        // Skip the live subsystems entirely under XCTest — the test target exercises these
        // components directly with their own fixtures; the app host just needs to launch cleanly.
        guard !runningTests else { return }

        // Start persistence + coordinator draining the bus; auto-reconnect happens when
        // CoreBluetooth reports poweredOn (see RingBLEClient.centralManagerDidUpdateState).
        subscriber.start()
        coordinator.start()
        summaryCoordinator.start()
        diagnostics.start()

        // Daily check-in notifications: route taps + register the background wake.
        UNUserNotificationCenter.current().delegate = notificationDelegate
        let ctx = container.mainContext
        CoachNotificationScheduler.shared.register {
            CoachNotificationService(modelContext: ctx, coordinator: coordinator)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootAppView()
                .environment(bleClient)
                .environment(coordinator)
                .environment(gpsRecorder)
                .environment(liveWorkout)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Both calls are no-ops when the AI Coach master switch is off — the
            // scheduler gates on `coachMasterEnabled`, and `runDueSlot` short
            // -circuits via the feature-flags gate.
            CoachNotificationScheduler.shared.scheduleNext()
            guard CoachSettingsStore.shared.settings.coachMasterEnabled else { return }
            // Foreground catch-up: deliver a due check-in we missed while away.
            let ctx = container.mainContext
            let coordinator = coordinator
            Task {
                await CoachNotificationService(modelContext: ctx, coordinator: coordinator).runDueSlot()
            }
        }
    }
}
