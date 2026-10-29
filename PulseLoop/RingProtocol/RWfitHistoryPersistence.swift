import Foundation

/// Durable storage boundary for ring history. A missing subscriber must never imply a save.
@MainActor
enum RWfitHistoryPersistence {
    private static let maximumJournalBytes = 4 * 1024 * 1024
    static var save: (([RingDecodedEvent]) throws -> Void)?

    enum PersistenceError: LocalizedError {
        case unavailable
        case rejectedRecord
        case invalidDevice

        var errorDescription: String? {
            switch self {
            case .unavailable: return "History storage is not ready. Please retry syncing."
            case .rejectedRecord: return "The ring returned a history record that could not be imported."
            case .invalidDevice: return "The ring identity is unavailable. Please reconnect."
            }
        }
    }

    private struct SleepPage: Codable {
        let id: UUID
        let payload: [UInt8]
    }

    /// Injectable only for isolated persistence tests. Production uses backup-eligible Application Support.
    static var journalDirectoryOverride: URL?

    private static func journalURL(deviceID: String) throws -> URL {
        guard let identifier = UUID(uuidString: deviceID) else { throw PersistenceError.invalidDevice }
        let directory: URL
        if let override = journalDirectoryOverride {
            directory = override
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
                .appendingPathComponent("RWfitSleepJournal", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(identifier.uuidString).appendingPathExtension("json")
    }

    private static func pages(deviceID: String) throws -> [SleepPage] {
        let url = try journalURL(deviceID: deviceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumJournalBytes else { throw PersistenceError.rejectedRecord }
        let stored = try JSONDecoder().decode([SleepPage].self, from: Data(contentsOf: url))
        guard stored.allSatisfy({ validSleepPage($0.payload) }) else { throw PersistenceError.rejectedRecord }
        return stored
    }

    /// Commit before consumption. Byte-identical replays after ambiguous deletion are deduplicated;
    /// record timestamps distinguish real adjacent pages.
    static func stageSleepPage(_ payload: [UInt8], deviceID: String, pageID: UUID) throws {
        guard validSleepPage(payload) else { throw PersistenceError.rejectedRecord }
        var stored = try pages(deviceID: deviceID)
        guard !stored.contains(where: { $0.id == pageID || $0.payload == payload }) else { return }
        stored.append(SleepPage(id: pageID, payload: payload))
        let data = try JSONEncoder().encode(stored)
        guard data.count <= maximumJournalBytes else { throw PersistenceError.rejectedRecord }
        try data.write(to: journalURL(deviceID: deviceID),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func validSleepPage(_ payload: [UInt8]) -> Bool {
        payload.count > 3 && payload.count <= 8 * 1024 && (payload.count - 3).isMultiple(of: 7)
    }

    /// Reset pending imports together with the user's health store, so erased sleep cannot reappear.
    static func clearAllSleepPages() throws {
        let sampleURL = try journalURL(deviceID: UUID().uuidString)
        let directory = sampleURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func sleepPayload(deviceID: String) throws -> [UInt8] {
        let stored = try pages(deviceID: deviceID)
        guard let first = stored.first else { return [] }
        return Array(first.payload.prefix(3)) + stored.flatMap { $0.payload.dropFirst(3) }
    }

    /// Call only after the aggregate's decoded sessions have been saved successfully.
    static func clearSleepPages(deviceID: String) throws {
        let url = try journalURL(deviceID: deviceID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
