---
title: RWfit rings
description: Native support for the legacy and modern RWfit protocols, with vendor SDK references and hardware validation status.
---

# RWfit rings

PulseLoop implements the RWfit protocol in Swift; it does not bundle the vendor SDK.
RwFit rings use the `A00A` service, `B002` write characteristic and `B003` notification
characteristic. Rebranded model names alone are not reliable protocol identifiers.

## Compatibility status

**Hardware validation is pending for SR16 and SY01.** Reports from PulseLoop 2.6.0
included pairing without data and manual-reading timeouts. The supplied SR16 export
(firmware `001.0B`) contains connection and sync-stage logs, but no raw packets.
Its approximately six-second stage changes match the old timeout-based pager;
“done” in that export is not evidence of a successful history transfer.

The fixes have SDK-derived regression coverage. They do not establish universal
compatibility with every ring sold for the RwFit app.

## Protocol references

- [Vendor invitation, issue #135](https://github.com/saksham2001/PulseLoopiOS/issues/135)
- [Executable SDK, pinned revision](https://github.com/RWFitSDK/RW_weixi_miniprogram_sdk/blob/8613daec2c08a41fa6c0bf5476af4f125e1532e5/RW_SDK_DEMO/sdk/rw-ble-sdk.min.js)
- [iOS guide, pinned revision](https://github.com/RWFitSDK/RW_iOS_SDK/blob/69b35c2471d0e531556b77a51bdc116f2a218171/doc/blesdkios_en.md)
- [iOS command constants](https://github.com/RWFitSDK/RW_iOS_SDK/blob/69b35c2471d0e531556b77a51bdc116f2a218171/Frameworks/DHBleSDK.xcframework/ios-arm64/DHBleSDK.framework/Headers/DHBleCommandEnums.h)

Modern behavior follows the published SDK. Legacy `7E` support retains the older
vendor-app-derived layouts. OTA sibling services are framing hints; a validated
response establishes the protocol. With no modern hint, a bounded legacy identity
read precedes an attempt at modern initialization.

## Initialization and responses

Modern frames are `AB flag lengthBE crc16ARC payload`. The payload starts with
command, key, and operation bytes. `01` responses require an echoed-triple `11` ACK;
`11` replies can carry data and are not acknowledged. `21` pushes carry unsolicited
data and never complete a pending transaction. The parser supports split headers,
continuations and coalesced frames with an 8 KiB payload limit.

Initialization runs in order: `0302` session setup, `0202` timezone (signed quarter
hours and iOS platform `01`), `0201` clock, then `0263` function menu. Password-capable
rings require `0304` authentication using the SDK default `0000`. Authentication
failure is reported without resetting the password. History and manual actions
remain unavailable until initialization succeeds.

Capabilities come from the function menu, not from the presence of an OTA service.
Commands wait for GATT transmission confirmation and a matching response; modern
transactions allow five seconds per response attempt and two retries.

## History and manual measurements

Only supported streams are queried. Modern history is requested repeatedly until
an explicit empty page; timers do not turn an unanswered request into success.
Current-day steps (`051A`) and historical steps (`0502`) are reconciled through the
existing cumulative/bucket persistence paths.

**Sync consumes transferred history from the ring.** Non-sleep streams are deleted
only after the complete response has been validated and durably imported. Sleep
requires deletion after each page, so raw pages are first atomically saved to a
bounded, per-device journal in Application Support. Complete sleep sessions are
assembled and imported before removing that journal. It survives interruption and
is cleared with the user's app data. RwFit may no longer be able to import records
that PulseLoop has consumed.

Live values arrive on `02`-group commands: HR `0224`, SpO2 `024E`, HRV `0269`, BP
`0231`, temperature `0230`, stress `024F`, and glucose `026C`. `0609` is measurement
status, never a reading: raw status zero means completion; other vendor statuses
are retained as diagnostics because their meanings are undocumented. A measurement
pauses history at a page boundary; stop must complete before history resumes.

Successful empty sync, imported data, partial import, failure and cancellation are
separate outcomes. Only successful completion updates successful-sync freshness.
The greeting “Burning the midnight oil” follows phone time and is unrelated to BLE.

## Tester verification

On SR16 and SY01, verify initial connection and populated history, HR and SpO2
spot readings, reconnect, and sync interrupted mid-transfer. Record firmware and
whether the same ring works in RwFit. Enable **Privacy & Data → Diagnostics → raw
packet capture** before reproducing, then export diagnostics. Raw health packets
remain opt-in in release builds; protocol stages and failures are logged normally.
