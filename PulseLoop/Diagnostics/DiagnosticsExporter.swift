import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Builds a shareable diagnostics bundle (JSON): app/OS/device info + the recent `WearableLog`
/// timeline. Raw BLE packets (`RawPacketRow`) are included only in DEBUG builds, so release exports
/// never leak protocol bytes.
@MainActor
enum DiagnosticsExporter {
    /// Serialize a diagnostics report to pretty-printed JSON.
    static func exportJSON(context: ModelContext, maxLogs: Int = 500) -> String {
        var root: [String: Any] = [:]
        root["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        root["app"] = appInfo()
        root["device"] = deviceInfo(context: context)
        root["logs"] = recentLogs(context: context, limit: maxLogs)
        #if DEBUG
        root["rawPackets"] = recentPackets(context: context, limit: 200)
        #endif

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Write the report to a temporary file and return its URL (for a share sheet).
    static func exportFile(context: ModelContext) -> URL? {
        let json = exportJSON(context: context)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulseloop-diagnostics-\(stamp).json")
        do {
            try json.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func appInfo() -> [String: Any] {
        let bundle = Bundle.main
        return [
            "version": bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?",
        ]
    }

    private static func deviceInfo(context: ModelContext) -> [String: Any] {
        var info: [String: Any] = [:]
        #if canImport(UIKit)
        info["model"] = UIDevice.current.model
        info["systemName"] = UIDevice.current.systemName
        info["systemVersion"] = UIDevice.current.systemVersion
        #endif
        if let device = (try? context.fetch(FetchDescriptor<Device>()))?.first {
            info["wearableType"] = device.deviceType.rawValue
            info["wearableName"] = device.name
            info["capabilities"] = device.capabilities.csv
            info["firmware"] = device.firmwareVersion ?? "?"
            info["lastSyncAt"] = device.lastSyncAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        }
        return info
    }

    private static func recentLogs(context: ModelContext, limit: Int) -> [[String: Any]] {
        var descriptor = FetchDescriptor<WearableLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let logs = (try? context.fetch(descriptor)) ?? []
        return logs.map { log in
            var row: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: log.timestamp),
                "category": log.categoryRaw,
                "level": log.levelRaw,
                "message": log.message,
            ]
            if let meta = log.metadataJSON { row["metadata"] = meta }
            if !log.deviceTypeRaw.isEmpty { row["deviceType"] = log.deviceTypeRaw }
            return row
        }
    }

    private static func recentPackets(context: ModelContext, limit: Int) -> [[String: Any]] {
        var descriptor = FetchDescriptor<RawPacketRow>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let packets = (try? context.fetch(descriptor)) ?? []
        return packets.map { p in
            [
                "at": ISO8601DateFormatter().string(from: p.timestamp),
                "direction": p.directionRaw,
                "hex": p.hexPayload,
                "decoded": p.decodedKind ?? "",
            ]
        }
    }
}
