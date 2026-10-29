import Foundation

/// One logical outbound command, before wire framing. The command gate frames it with whichever
/// codec the connection's framing selected — the encoder below emits the right variant for the
/// active framing, so a caller never handles both.
enum RWfitOutbound: Equatable {
    case legacy(cmd: UInt8, payload: [UInt8])
    case jieli(payload: [UInt8])   // payload includes the {CMD, Key, KeyFlag} triple
}

/// Logical command builders for both RWfit framings behind one API. Each method mirrors the vendor
/// builder cited on it (`p.java` = `…/mlkit_vision_common/p.java`, the R8-relocated `CmdHelper`).
///
/// Stateless — the framing is passed per call (the driver owns it, and it can change between
/// connects if a user swaps rings).
struct RWfitEncoder {
    /// PulseLoop's bind identity. The vendor binds with its account's numeric user id; the ring just
    /// stores and echoes it. UTF-16LE on the wire (`y5/b.java m()`).
    static let bindUserID = "PL"

    // SDK startup commands; session key flag is 0x20, password authentication is 0x10.
    func sessionInitialize() -> RWfitOutbound {
        .jieli(payload: [0x03, 0x02, 0x20, 0, 0, 0, 1])
    }

    func timezone(offsetSeconds: Int) -> RWfitOutbound {
        let quarters = Int8(clamping: Int((Double(offsetSeconds) / 900).rounded()))
        return .jieli(payload: [0x02, 0x02, 0x00, UInt8(bitPattern: quarters), 0x01])
    }

    func functionMenu() -> RWfitOutbound { .jieli(payload: [0x02, 0x63, 0x10]) }

    func authenticate() -> RWfitOutbound {
        .jieli(payload: [0x03, 0x04, 0x10] + Array("0000".utf8))
    }

    func historyDelete(type: UInt8) -> RWfitOutbound { .jieli(payload: [0x05, type, 0x30]) }

    // MARK: - Clock

    /// Set the ring's RTC from **local** calendar components — both firmwares stamp history off this
    /// clock, so it leads the startup sequence. Legacy: `[yearBE(2), mo, d, h, m, s]` (`p.java u()`);
    /// JieLi: `{02 01 00, year-2000, mo, d, h, m, s}` (`p.java v()`).
    func setTime(framing: RWfitFraming, components: DateComponents) -> RWfitOutbound {
        let year = components.year ?? 2000
        let fields = [
            UInt8(components.month ?? 1), UInt8(components.day ?? 1),
            UInt8(components.hour ?? 0), UInt8(components.minute ?? 0), UInt8(components.second ?? 0),
        ]
        switch framing {
        case .legacy:
            let yearBytes = RWfitBytes.packU16BE(year)
            return .legacy(cmd: RWfitLegacyCommand.setTime, payload: yearBytes + fields)
        case .jieli:
            return .jieli(payload: RWfitJLTriple.setTime.bytes + [UInt8(clamping: year - 2000)] + fields)
        }
    }

    // MARK: - Reads

    func deviceInfo(framing: RWfitFraming) -> RWfitOutbound {
        request(framing, legacy: RWfitLegacyCommand.deviceInfo, jl: .deviceInfo)
    }

    func battery(framing: RWfitFraming) -> RWfitOutbound {
        request(framing, legacy: RWfitLegacyCommand.battery, jl: .battery)
    }

    /// Capability discovery: legacy SupportMenuBean or the modern SDK 0263 function menu.
    func features(framing: RWfitFraming) -> RWfitOutbound {
        request(framing, legacy: RWfitLegacyCommand.features, jl: RWfitJLTriple(cmd: 0x02, key: 0x63, keyFlag: 0x10))
    }

    func bindStatus(framing: RWfitFraming) -> RWfitOutbound {
        request(framing, legacy: RWfitLegacyCommand.bindStatus, jl: .bindStatus)
    }

    // MARK: - Bind / unbind

    /// Claim the ring. Legacy: `[bindType, userId UTF-16LE…]` (`p.java s()`); JieLi: `03 01 20` +
    /// the userId's UTF-16LE bytes right-aligned into 4 (`p.java t()`).
    func bind(framing: RWfitFraming) -> RWfitOutbound {
        let userID = Array(Self.bindUserID.data(using: .utf16LittleEndian) ?? Data())
        switch framing {
        case .legacy:
            return .legacy(cmd: RWfitLegacyCommand.bind, payload: [0x01] + userID)
        case .jieli:
            var id: [UInt8] = [0, 0, 0, 0]
            let tail = userID.suffix(4)
            id.replaceSubrange((4 - tail.count)..<4, with: tail)
            return .jieli(payload: RWfitJLTriple.bind.bytes + id)
        }
    }

    /// Release the ring on Forget. Legacy: `0x44`, empty (`h0.java:319`); JieLi: `03 01 30 00`
    /// (`p.java X()`).
    func unbind(framing: RWfitFraming) -> RWfitOutbound {
        switch framing {
        case .legacy: return .legacy(cmd: RWfitLegacyCommand.unbind, payload: [])
        case .jieli: return .jieli(payload: RWfitJLTriple.unbind.bytes + [0x00])
        }
    }

    // MARK: - Profile / units / goal

    /// Push the user profile. Legacy `0x2E`: `[gender(1=male), age, heightBE u16, weight×10 BE u16,
    /// goalBE u16, nickname UTF-16LE…]` (`p.java x()`). JieLi `02 06 00`: `[unit, gender, age,
    /// height float LE(4), weight float LE(4)]` (`p.java Q()` — the two IEEE-754 floats are the one
    /// little-endian field in the whole protocol).
    func userProfile(
        framing: RWfitFraming,
        profile: UserProfileValues,
        goalSteps: Int
    ) -> RWfitOutbound {
        // RWfit gender byte: 1 = male, 0 = everyone else (the vendor has no third value).
        let gender: UInt8 = profile.gender == 0x01 ? 1 : 0
        switch framing {
        case .legacy:
            var payload: [UInt8] = [gender, profile.age]
            payload += RWfitBytes.packU16BE(Int(profile.heightCm))
            payload += RWfitBytes.packU16BE(Int(profile.weightKg) * 10)
            payload += RWfitBytes.packU16BE(goalSteps)
            payload += Array("PulseLoop".data(using: .utf16LittleEndian) ?? Data())
            return .legacy(cmd: RWfitLegacyCommand.profile, payload: payload)
        case .jieli:
            var payload = RWfitJLTriple.profile.bytes
            payload.append(profile.metric ? 0 : 1)
            payload.append(gender)
            payload.append(profile.age)
            payload += floatLE(Float(profile.heightCm))
            payload += floatLE(Float(profile.weightKg))
            return .jieli(payload: payload)
        }
    }

    /// Language / units. Legacy `0x24`: `[lang, measureUnit, tempUnit, timeFont]` (`p.java P()`);
    /// JieLi `02 11 00 <unit>` (`p.java w()`). 0 = metric/Celsius, English.
    func units(framing: RWfitFraming, metric: Bool) -> RWfitOutbound {
        let unit: UInt8 = metric ? 0 : 1
        switch framing {
        case .legacy:
            return .legacy(cmd: RWfitLegacyCommand.units, payload: [0x00, unit, unit, 0x00])
        case .jieli:
            return .jieli(payload: RWfitJLTriple.units.bytes + [unit])
        }
    }

    /// Daily step goal. Legacy has no standalone goal command — it rides the profile (`p.java x()`),
    /// so the legacy variant re-sends the profile. JieLi: `02 07 00` + u32 BE (`p.java`, line 194).
    func goal(
        framing: RWfitFraming,
        steps: Int,
        profile: UserProfileValues
    ) -> RWfitOutbound {
        switch framing {
        case .legacy:
            return userProfile(framing: .legacy, profile: profile, goalSteps: steps)
        case .jieli:
            return .jieli(payload: RWfitJLTriple.goal.bytes + RWfitBytes.packU32BE(steps))
        }
    }

    // MARK: - History

    /// Request one history stream. Both framings: empty-bodied requests (`blesdk/service/l.java`,
    /// `y.java`) — the ring replies with everything it holds for the type.
    /// Returns nil when the active framing has no such stream.
    func historyRequest(framing: RWfitFraming, type: RWfitHistoryType) -> RWfitOutbound? {
        switch framing {
        case .legacy:
            guard let cmd = type.legacyCommand else { return nil }
            return .legacy(cmd: cmd, payload: [])
        case .jieli:
            guard let jlType = type.jlType else { return nil }
            return .jieli(payload: RWfitJLTriple.historySync(type: jlType).bytes)
        }
    }

    /// The legacy "what do you have" manifest (`0xA0`, `u1.java:444`). Legacy-only.
    func syncManifest() -> RWfitOutbound {
        .legacy(cmd: RWfitLegacyCommand.syncManifest, payload: [])
    }

    // MARK: - Realtime measurement (JieLi-only)

    /// Start/stop an on-demand measurement: `06 09 00 <type> 05 <enable>` (`u0.java n()` et al.).
    /// The vendor app never sends a legacy equivalent — no legacy builder for internal id `0x1F`
    /// exists — so on legacy links the caller must not offer these (capability-gated).
    func realtimeMeasure(type: UInt8, on: Bool) -> RWfitOutbound {
        .jieli(payload: RWfitJLTriple.realtimeMeasure.bytes + [type, 0x05, on ? 0x01 : 0x00])
    }

    // MARK: - Helpers

    private func request(_ framing: RWfitFraming, legacy: UInt8, jl: RWfitJLTriple) -> RWfitOutbound {
        switch framing {
        case .legacy: return .legacy(cmd: legacy, payload: [])
        case .jieli: return .jieli(payload: jl.bytes)
        }
    }

    /// IEEE-754 float, little-endian byte order (`p.java Q()` reverses the big-endian array).
    private func floatLE(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
}
