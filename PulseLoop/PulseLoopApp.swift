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

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainerFactory.make()
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        self.container = container

        let client = RingBLEClient()
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
