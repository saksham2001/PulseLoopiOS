import XCTest
@testable import PulseLoop

@MainActor
final class NutritionPrefsStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "NutritionPrefsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsArePrivacyFirst() {
        let store = NutritionPrefsStore(defaults: makeDefaults())
        XCTAssertFalse(store.prefs.masterEnabled, "nutrition must be off by default")
        // Sub-toggles default on so one tap enables the full feature.
        XCTAssertTrue(store.prefs.shareWithCoach)
        XCTAssertTrue(store.prefs.includeInNotifications)
        XCTAssertTrue(store.prefs.photoAnalysisEnabled)
        XCTAssertTrue(store.prefs.showOnToday)
    }

    func testPersistRoundTrip() {
        let defaults = makeDefaults()
        let store = NutritionPrefsStore(defaults: defaults)
        store.prefs.masterEnabled = true
        store.prefs.shareWithCoach = false

        let reloaded = NutritionPrefsStore(defaults: defaults)
        XCTAssertTrue(reloaded.prefs.masterEnabled)
        XCTAssertFalse(reloaded.prefs.shareWithCoach)
        XCTAssertTrue(reloaded.prefs.showOnToday)
    }

    func testTolerantDecodeOfPartialBlob() throws {
        let defaults = makeDefaults()
        // A blob from an "older build" that only knows masterEnabled.
        defaults.set(Data(#"{"masterEnabled":true}"#.utf8), forKey: "pulseloop.nutrition.prefs.v1")
        let store = NutritionPrefsStore(defaults: defaults)
        XCTAssertTrue(store.prefs.masterEnabled)
        XCTAssertTrue(store.prefs.shareWithCoach, "missing keys fall back to defaults, blob not discarded")
    }

    func testAppleHealthPrefsGainedNutritionToggle() throws {
        // The dietary-export toggle rides AppleHealthPrefs; older blobs must decode with it defaulted on.
        let data = Data(#"{"masterEnabled":true,"syncHeartRate":false}"#.utf8)
        let prefs = try JSONDecoder().decode(AppleHealthPrefs.self, from: data)
        XCTAssertTrue(prefs.syncNutrition)
        XCTAssertFalse(prefs.syncHeartRate)
    }
}
