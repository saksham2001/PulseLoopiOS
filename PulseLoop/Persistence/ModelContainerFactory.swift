import SwiftData

enum ModelContainerFactory {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Device.self,
            ActivityDaily.self,
            Measurement.self,
            SleepSession.self,
            SleepStageBlock.self,
            RawPacketRow.self,
            DerivedUpdateRow.self,
            UserProfile.self,
            UserGoal.self,
            DeviceMeasurementConfig.self,
            ActivitySession.self,
            ActivitySample.self,
            ActivityBucketSample.self,
            ActivityGpsPoint.self,
            ActivityEvent.self,
            ActivitySensorPollEvent.self,
            CoachConversation.self,
            CoachMessage.self,
            CoachMemory.self,
            CoachToolCall.self,
            CoachNotificationRecord.self,
            CoachSummary.self,
            WearableLog.self
        ])
        
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
