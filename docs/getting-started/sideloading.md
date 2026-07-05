---
title: Sideloading the IPA
description: Install the pre-built PulseLoop IPA on your iPhone without Xcode. Sign it yourself via Sideloadly, AltStore/SideStore, Feather/ESign, TrollStore, or a paid Developer account.
---

# Sideloading PulseLoop on iOS

Every published [release](https://github.com/saksham2001/PulseLoopiOS/releases)
ships a pre-built, **unsigned** IPA:

```
PulseLoop-<tag>.ipa      e.g. PulseLoop-v1.0.0.ipa
```

Nothing is signed in CI, so there are no Apple certificates or secrets in the
repo. You sign the IPA yourself with your own Apple ID using one of the tools
below. This lets you run PulseLoop on a real iPhone without building it in Xcode.

!!! info "Prefer a hands-off install?"
    The **[TestFlight beta](ios.md#testflight-beta)** needs no signing, no
    computer, and no 7-day refresh. Sideloading is for people who want the raw
    IPA or aren't on the TestFlight list yet.

## :material-alert: Read this first: the App Group caveat

PulseLoop's only special entitlement is an **App Group**
(`group.xyz.sakshambhutani.pulseloop2`). It's the shared container that the
Home Screen widgets and the Live Activity / Dynamic Island read from.

**Free Apple IDs cannot provision App Groups.** Every free-signing tool below
(Sideloadly, AltStore, SideStore, Feather, ESign with a free cert) strips that
entitlement at sign time. The result:

| Feature | Free Apple ID sideload | Paid Developer account |
| --- | --- | --- |
| Core app: ring sync, vitals, sleep, coach, workouts, GPS | :material-check: Works | :material-check: Works |
| Home Screen widgets (Activity, Vitals) | :material-close: Broken | :material-check: Works |
| Live Activity / Dynamic Island | :material-close: Broken | :material-check: Works |

The app does **not** crash without the App Group. Those features degrade
gracefully and everything else runs normally.

!!! tip "Want the widgets? Use a paid ($99/yr) Apple Developer account"
    Only a paid account provisions the App Group. Sign with a paid cert (via
    Sideloadly, Feather, or ESign) and the widgets + Live Activity light up.
    A [Developer account](https://developer.apple.com/programs/) also raises the
    signing certificate to **1 year** instead of 7 days.

## :material-numeric-1-circle: Download the IPA

1. Open the **[Releases](https://github.com/saksham2001/PulseLoopiOS/releases)**
   page.
2. Under the latest release's **Assets**, download `PulseLoop-<tag>.ipa`.
3. Get it onto (or reachable from) the device or computer you'll sign with.

## :material-numeric-2-circle: Pick a signing method

| Method | Computer needed? | Signing lasts | App limit (free ID) | Best for |
| --- | --- | --- | --- | --- |
| **Sideloadly** | Yes (once per refresh) | 7 days (free) / 1 yr (paid) | 3 | Simplest one-shot install |
| **AltStore** | Yes (AltServer, same Wi-Fi) | 7 days, auto-refreshes | 3 | Set-and-forget auto refresh |
| **SideStore** | Only for setup | 7 days, on-device refresh | 3 | No computer after setup |
| **Feather / ESign** | No | Depends on cert | Cert-dependent | On-device, paid/enterprise certs |
| **TrollStore** | No | **Permanent** | Unlimited | Supported iOS versions only |
| **Paid Dev + Xcode** | Yes | 1 year | Higher | Widgets + longest signing |

!!! note "Free Apple ID limits (apply to Sideloadly, AltStore, SideStore)"
    - **7-day expiry**: the app stops opening after a week until you re-sign.
    - **Max 3 sideloaded apps** at once per Apple ID.
    - **No App Groups**, so no PulseLoop widgets / Live Activity (see above).
    - Use a **secondary/burner Apple ID**, not your main one, to sign.

---

## :material-laptop: Sideloadly (simplest)

Free desktop tool for macOS and Windows. Signs and installs in one pass.

1. Install **[Sideloadly](https://sideloadly.io/)** and its prerequisites
   (iTunes + iCloud on Windows; nothing extra on macOS).
2. Plug your iPhone in via USB and trust the computer.
3. Drag `PulseLoop-<tag>.ipa` into Sideloadly.
4. Enter your Apple ID (use a burner). Leave the bundle ID as-is unless you're
   installing alongside another copy.
5. Click **Start**. Enter your Apple ID password / app-specific password when
   prompted.
6. On the phone: **Settings → General → VPN & Device Management** → trust your
   Apple ID's developer profile.
7. Launch PulseLoop.

!!! warning "Re-sign every 7 days"
    With a free Apple ID the app expires after 7 days. Re-run the same Sideloadly
    steps before it lapses (do it *before* expiry to keep your data).

## :material-store: AltStore (auto-refresh over Wi-Fi)

AltStore installs a companion app on the phone and re-signs automatically while
**AltServer** runs on a computer on the same network.

1. Install **[AltServer](https://altstore.io/)** on macOS/Windows and run it.
2. Connect the phone once via USB; from AltServer choose **Install AltStore**.
3. On the phone, trust the developer profile (**Settings → General → VPN &
   Device Management**).
4. Open **AltStore → My Apps → +**, pick `PulseLoop-<tag>.ipa`, sign in with a
   burner Apple ID.
5. Keep AltServer running on the same Wi-Fi, and AltStore refreshes the 7-day
   signature in the background so the app doesn't lapse.

!!! tip "EU users: AltStore PAL"
    In the EU, **AltStore PAL** is an Apple-approved alternative marketplace and
    doesn't need AltServer or the 7-day refresh. You still sideload the IPA
    manually as a source/app.

## :material-cellphone-cog: SideStore (no computer after setup, recommended for free IDs)

An AltStore fork that refreshes **on-device**, so no computer is needed after the
one-time setup, and no DNS tricks are needed to avoid revokes. On-device refresh
runs through **LocalDevVPN** (the SideStore team's local VPN, installed from the
App Store). The **7-day** free-ID certificate is refreshed by tapping the counter
in SideStore; after a refresh you can stay offline until it lapses.

!!! info "Follow the official guide"
    Steps below match the SideStore docs. If anything drifts, the source of
    truth is
    **[docs.sidestore.io](https://docs.sidestore.io/docs/installation/prerequisites)**.

**Prerequisites:**

- iPhone/iPad on **iOS/iPadOS 15.0+** with a **passcode set** and a **Wi-Fi**
  connection (mobile data is not suitable).
- A burner Apple Account (not your primary Apple ID).
- A computer (Windows 8+, macOS High Sierra+, up-to-date Linux, or an
  un-enrolled Chromebook), needed **only** for the initial install.

**On the device, install LocalDevVPN:**

Install **[LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)**
from the **App Store** (or the **AltStore PAL** source), open it, and tap
**Connect**. Tap **Allow** and enter your passcode if prompted for "Allow VPN
Configurations". This VPN must be **on** whenever you install, update, or refresh
apps in SideStore.

**On the computer, install iloader (per OS):**

=== "macOS"

    Download and install **[iloader](https://docs.sidestore.io/docs/installation/prerequisites)**.

=== "Windows"

    1. Install **iTunes** from the Microsoft Store or directly from Apple.
    2. Download the **iloader** installer as an **MSI** (recommended) or **EXE**.
    3. Run the installer.

=== "Linux"

    1. Install **usbmuxd** (often preinstalled; else use your package manager,
       e.g. search "install usbmuxd _\<distro\>_").
    2. Install **iloader** for your distro: **DEB** (Debian/Ubuntu), **RPM**
       (Fedora/openSUSE), or **AppImage** (others). ARM builds exist for all
       three.

    !!! warning "Community packages"
        Third-party packages (e.g. the Arch AUR one) aren't vetted by SideStore.
        Do your own due diligence before installing.

=== "Chromebook"

    Requires an **un-enrolled** Chromebook with the Linux dev environment
    available (enrolled/old Chromebooks may have it disabled).

    1. Enable the **Linux development environment**
       ([Google's guide](https://support.google.com/chromebook/answer/9145439)).
    2. Update: `sudo apt-get update && sudo apt-get dist-upgrade`
    3. Install deps: `sudo apt-get install usbmuxd fuse curl`
    4. Download the **iloader AppImage** for your arch (`uname -m` gives
       `x86_64` for the amd64 build, `aarch64` for the aarch64 build) from the
       [iloader releases](https://github.com/nab138/iloader/releases/latest).
    5. `sudo systemctl restart usbmuxd`, then connect the device and **quickly**
       enable it under **Settings → About ChromeOS → Developers → Linux
       development environment → Manage USB devices** (ChromeOS claims the device
       otherwise). Verify with `lsusb`.
    6. `chmod +x ./iloader-linux-*.AppImage` and run it.

    Full detail (incl. troubleshooting) is in the
    [official prerequisites](https://docs.sidestore.io/docs/installation/prerequisites).

**One-time setup (needs the computer once):**

1. Connect the device via USB and **trust** the computer.
2. Open **iloader**, sign in with your Apple Account (case-sensitive), select
   your device, and choose **Install SideStore (Stable)**.
3. On the device, trust the profile: **Settings → General → VPN & Device
   Management** → your Apple ID.

    - **iOS 16+:** first enable **Developer Mode** (**Settings → Privacy &
      Security → Developer Mode**) and reboot.
    - **iOS 18+:** the trust prompt is **"Allow & Restart"** and asks for your
      passcode.

4. Ensure **LocalDevVPN** is **connected** (from the earlier step); it must be
   on to install, update, or refresh.
5. Open **SideStore**, sign in with the **same** Apple Account used in iloader.
   In **My Apps**, tap the **"7 DAYS"** counter to refresh SideStore itself and
   confirm any certificate prompt.
6. Disconnect the computer. You won't need it again unless you update SideStore
   or replace the pairing file.

**Install PulseLoop:**

7. Download `PulseLoop-<tag>.ipa` on the device.
8. With LocalDevVPN **connected**, SideStore → **My Apps → +** → pick the IPA.
   It signs and installs on-device.

**Stay refreshed (or the app lapses at day 7):** tap the day counter in **My
Apps** before it hits zero, or automate it with a Shortcuts automation that
*connects LocalDevVPN → waits a few seconds → refreshes SideStore apps →
disconnects LocalDevVPN*, scheduled a few nights a week.

!!! note "If it lapses, don't delete PulseLoop"
    An expired app stops opening but is **not** revoked, so your data is intact.
    Reconnect and refresh in SideStore (re-run iloader only if SideStore itself
    lapsed). No need to redo the whole setup. Pairing files can expire after an
    iOS update or reset; regenerate via iloader / the SideStore advanced guide
    if refresh starts failing.

### LiveContainer: beat the 3-app limit (free IDs)

A free Apple ID caps you at **3 sideloaded apps**. **[LiveContainer](https://github.com/LiveContainer/LiveContainer)**
is one app that virtualizes and runs *other* apps inside it, so dozens of apps
cost just **one** of your three slots, and the inner apps don't need individual
signing or refreshing (you only refresh LiveContainer in SideStore).

!!! warning "PulseLoop's widgets are not expected to work inside LiveContainer"
    LiveContainer runs apps in a shared virtualized sandbox and generally can't
    host app extensions, so PulseLoop's Home Screen widgets and the Live Activity
    / Dynamic Island are **not expected to work** inside it (we haven't tested
    this specific case). The core app (ring sync, vitals, sleep, coach, workouts,
    GPS) should run fine. If you want the widgets, install PulseLoop **directly**
    via SideStore (using a normal app slot) rather than inside LiveContainer, and
    remember you still need a **paid** cert for the App Group. LiveContainer is
    best when you're bundling many *other* modded apps and just want PulseLoop's
    core app along for the ride.

To use it: install `LiveContainer.ipa` through SideStore, complete its
**JIT-Less Mode** setup (LiveContainer Settings → *Import Certificate from
SideStore* → *Test JIT-Less Mode*), then add `PulseLoop-<tag>.ipa` from
LiveContainer's **+** button.

## :material-file-certificate: Feather / ESign (on-device, certificate-based)

On-device sideloaders that install an IPA using a **signing certificate + `.mobileprovision`**.
With a **paid Developer** or **enterprise** certificate this preserves the App
Group, so the widgets and Live Activity work.

1. Install **[Feather](https://github.com/khcrysalis/Feather)** or ESign.
2. Import your certificate (`.p12` + provisioning profile). A paid Developer
   cert keeps the App Group entitlement; a free one strips it.
3. Import `PulseLoop-<tag>.ipa`, sign, and install.
4. Trust the profile under **Settings → General → VPN & Device Management**.

!!! danger "Only import certificates you trust"
    Never load a certificate or provisioning profile from an untrusted source. A
    malicious cert can sign anything onto your device. Use your own paid
    Developer cert whenever possible.

## :material-shield-check: TrollStore (permanent, version-limited)

TrollStore signs apps **permanently**: no Apple ID, no 7-day expiry, no app
limit. The catch: it only installs on iOS versions with a compatible exploit
(broadly **iOS 14.0 to 16.6.1**, and specific 17.0 builds; **not** newer
releases).

1. Check compatibility and install TrollStore via the
   **[ios.cfw.guide install guide](https://ios.cfw.guide/installing-trollstore/)**
   or the official [TrollStore repo](https://github.com/opa334/TrollStore).
2. Open `PulseLoop-<tag>.ipa` in TrollStore and install.

!!! note "Entitlements on TrollStore"
    TrollStore can grant many entitlements the normal sandbox can't, but App
    Groups still need a matching provisioning profile. If the widgets don't
    appear, sign the IPA with a paid Developer profile first, then install.

## :material-xml: Paid Developer account + Xcode (widgets + 1-year signing)

The most reliable path, and the only free-of-refresh way to get the **widgets
and Live Activity**. Requires a paid [Apple Developer](https://developer.apple.com/programs/)
account ($99/yr).

If you have Xcode, prefer **[Build from source](ios.md#build-from-source-xcode)**:
set your Team on both the `PulseLoop` and `PulseLoopLiveActivity` targets and it
provisions the App Group for you.

To sign the pre-built IPA instead, use Sideloadly / Feather / ESign with your
**paid** Apple ID or Developer certificate. Paid signing gives you:

- **1-year** certificate instead of 7 days.
- The **App Group** entitlement, so the widgets + Live Activity work.
- No 3-app limit.

## :material-lifebuoy: Troubleshooting

??? question "\"Unable to Verify App\" / \"Untrusted Developer\""
    Go to **Settings → General → VPN & Device Management**, tap your developer
    profile, and choose **Trust**. Needs an internet connection the first time.

??? question "App opens then immediately closes"
    The signature likely expired (free 7-day limit), so re-sign with the same
    tool. If it's a fresh install, the certificate/profile may be invalid.

??? question "Widgets or Live Activity don't work"
    Expected on a **free** Apple ID, since the App Group is stripped. Re-sign
    with a **paid** Developer account/cert to enable them. See
    [the caveat](#read-this-first-the-app-group-caveat).

??? question "\"Maximum number of apps installed\""
    A free Apple ID allows only **3** sideloaded apps. Remove another sideloaded
    app or use a different Apple ID.

??? question "`56ff` ring receives no data"
    Set the ring up once in the **Jring** app, unpair it there, then connect it
    in PulseLoop. See the [iOS guide](ios.md).

## :material-scale-balance: A note on sideloading

Sideloading with your own Apple ID is a supported Apple developer workflow.
Third-party tools and certificates are provided by their respective projects, so
review and trust them yourself. Never sign in with your primary Apple ID on an
untrusted tool; use a secondary account.

## Next steps

- [Getting Started on iOS](ios.md) covers TestFlight and building from source.
- [Supported hardware](../hardware/index.md) helps you pick a compatible ring.
- [Privacy](../project/privacy.md) explains where your data lives (on-device).
