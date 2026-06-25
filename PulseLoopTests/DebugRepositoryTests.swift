import XCTest
import SwiftData
@testable import PulseLoop

@MainActor
final class DebugRepositoryTests: XCTestCase {
    private func seed(_ context: ModelContext) {
        DebugRepository.insertRawPacket(
            timestamp: Date().addingTimeInterval(-3), direction: .outgoing, commandId: 0x0c,
            hexPayload: "0c00", decodedKind: "status", confidence: .known, context: context
        )
        DebugRepository.insertRawPacket(
            timestamp: Date().addingTimeInterval(-2), direction: .incoming, commandId: 0x03,
            hexPayload: "03aa", decodedKind: "activity", confidence: .known, context: context
        )
        DebugRepository.insertRawPacket(
            timestamp: Date().addingTimeInterval(-1), direction: .incoming, commandId: 0x52,
            hexPayload: "5200", decodedKind: "unknown", confidence: .unknown, context: context
        )
        try? context.save()
    }

    func testFilterByDirection() throws {
        let context = try TestSupport.makeContext()
        seed(context)
        let incoming = DebugRepository.queryPackets(filter: DebugPacketFilter(direction: .incoming), context: context)
        XCTAssertEqual(incoming.count, 2)
        XCTAssertTrue(incoming.allSatisfy { $0.direction == .incoming })
    }

    func testFilterByCommandId() throws {
        let context = try TestSupport.makeContext()
        seed(context)
        let status = DebugRepository.queryPackets(filter: DebugPacketFilter(commandId: 0x0c), context: context)
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status.first?.commandId, 0x0c)
    }

    func testFilterByUnknownConfidence() throws {
        let context = try TestSupport.makeContext()
        seed(context)
        let unknown = DebugRepository.queryPackets(filter: DebugPacketFilter(confidence: .unknown), context: context)
        XCTAssertEqual(unknown.count, 1)
        XCTAssertEqual(unknown.first?.commandId, 0x52)
    }

    func testNewestFirstOrdering() throws {
        let context = try TestSupport.makeContext()
        seed(context)
        let all = DebugRepository.queryPackets(context: context)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first?.commandId, 0x52, "most recent packet first")
    }
}
