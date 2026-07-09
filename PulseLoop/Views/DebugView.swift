import SwiftUI
import SwiftData

struct DebugView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var filter = "all"
    @State private var refreshToken = UUID()

    var body: some View {
        let packets = DebugRepository.queryPackets(filter: packetFilter, context: modelContext)
        VStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                Text("All").tag("all")
                Text("In").tag(PacketDirection.incoming.rawValue)
                Text("Out").tag(PacketDirection.outgoing.rawValue)
                Text("Unknown").tag("unknown")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            List(packets) { packet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(packet.timestamp, style: .time)
                        Text(packet.directionRaw)
                        Text(String(format: "0x%02x", packet.commandId))
                        Spacer()
                        Text(packet.confidence.debugLabel)
                            .foregroundStyle(packet.confidence == .unknown ? PulseColors.warning : PulseColors.success)
                    }
                    .font(.caption.monospaced())
                    Text(packet.hexPayload)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(2)
                    Text(packet.decodedKind ?? "unknown")
                        .font(.caption)
                        .foregroundStyle(PulseColors.textSecondary)
                }
                .listRowBackground(PulseColors.card)
            }
            .scrollContentBackground(.hidden)

            HStack {
                SecondaryButton(title: "Log mock packet", systemImage: "plus") {
                    let data = RingEncoder().makeStatusCommand()
                    let decoded = RingDecoder().decode(data)
                    DebugRepository.insertRawPacket(
                        direction: .outgoing,
                        commandId: Int(data.first ?? 0),
                        hexPayload: data.hexString,
                        decodedKind: decoded.kind,
                        decodedJSON: decoded.debugJSON,
                        confidence: decoded.confidence,
                        context: modelContext
                    )
                    try? modelContext.save()
                    refreshToken = UUID()
                }
            }
            .padding(.horizontal)
        }
        .id(refreshToken)
        .background(PulseColors.background)
        .pageChrome("Debug")
    }

    private var packetFilter: DebugPacketFilter {
        switch filter {
        case PacketDirection.incoming.rawValue:
            return DebugPacketFilter(direction: .incoming)
        case PacketDirection.outgoing.rawValue:
            return DebugPacketFilter(direction: .outgoing)
        case "unknown":
            return DebugPacketFilter(confidence: .unknown)
        default:
            return DebugPacketFilter()
        }
    }
}

struct ComponentGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroInsightCardView(
                    title: "Steady build",
                    summary: "You're at 9,342 steps, 7h 35m of sleep, and your latest reading is 72 bpm.",
                    chips: [ToneChip(label: "Steps +12%", tone: .up), ToneChip(label: "HR collected", tone: .neutral), ToneChip(label: "Sleep synced", tone: .neutral)]
                )
                MetricCardButton(metric: "hr", label: "Heart rate", value: "72", unit: "bpm", color: PulseColors.heartRate, sparkline: [62, 68, 72, 70, 76])
                StatusCopy(title: "Empty state", body: "Reusable loading, empty, and error states use the same card hierarchy.")
            }
            .padding()
        }
        .background(PulseColors.background)
        .navigationTitle("Components")
    }
}
