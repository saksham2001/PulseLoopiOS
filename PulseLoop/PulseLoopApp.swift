//
//  PulseLoopApp.swift
//  PulseLoop
//
//  Created by Saksham Bhutani on 5/31/26.
//

import SwiftUI
import SwiftData

@main
struct PulseLoopApp: App {
    let container: ModelContainer
    @State private var bleClient: RingBLEClient
    @State private var coordinator: RingSyncCoordinator
    @State private var gpsRecorder: GpsRouteRecorder
    @State private var liveWorkout: LiveWorkoutManager
    /// Retained for app lifetime so it keeps draining the event bus into SwiftData.
    private let persistence: EventPersistenceSubscriber

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

        // Start persistence + coordinator draining the bus; auto-reconnect happens when
        // CoreBluetooth reports poweredOn (see RingBLEClient.centralManagerDidUpdateState).
        subscriber.start()
        coordinator.start()
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
    }
}
