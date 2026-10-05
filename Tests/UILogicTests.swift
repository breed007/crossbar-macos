import XCTest

final class ToggleConfirmationTests: XCTestCase {
    private let wifi = makeService("WIFI", name: "Wi-Fi", router: "192.168.60.1", kind: .wifi, ssid: "MI6", order: 2)
    private let ssh = RemoteSession(kind: .ssh, host: "10.0.0.5")

    private func plan(_ prediction: RoutePrediction, remote: [RemoteSession] = [], confirm: Bool = true) -> ToggleConfirmation? {
        ToggleConfirmation.plan(serviceName: "Thunderbolt Ethernet", prediction: prediction,
                                remoteSessions: remote, confirmHandoff: confirm)
    }

    func testDormantServicesNeverAsk() {
        XCTAssertNil(plan(.notActiveRoute))
        XCTAssertNil(plan(.notActiveRoute, remote: [ssh]))   // the session isn't on this service's route
    }

    func testHandoffAsksAndCanBeSilenced() {
        let asked = plan(.handoff(to: wifi))
        XCTAssertEqual(asked?.title, "Turn off Thunderbolt Ethernet?")
        XCTAssertEqual(asked?.message, "Traffic will move to Wi-Fi (MI6).")
        XCTAssertEqual(asked?.offersDontAskAgain, true)
        XCTAssertNil(plan(.handoff(to: wifi), confirm: false))
    }

    func testGoingOfflineAlwaysAsks() {
        XCTAssertEqual(plan(.offline, confirm: false)?.offersDontAskAgain, false)
    }

    func testRemoteSessionsAlwaysAskEvenWhenSilenced() {
        let asked = plan(.handoff(to: wifi), remote: [ssh], confirm: false)
        XCTAssertEqual(asked?.offersDontAskAgain, false)
        XCTAssertEqual(asked?.message,
                       "Traffic will move to Wi-Fi (MI6). This Mac has an SSH session from 10.0.0.5, which may disconnect.")
    }
}

final class SettlingTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testSettlesUntilConnected() {
        var tracker = SettlingTracker()
        tracker.begin("WIFI", at: start)
        tracker.prune([makeService("WIFI", kind: .wifi)], now: start.addingTimeInterval(5))
        XCTAssertTrue(tracker.isSettling("WIFI"))
        tracker.prune([makeService("WIFI", router: "10.0.0.1", kind: .wifi)], now: start.addingTimeInterval(6))
        XCTAssertFalse(tracker.isSettling("WIFI"))
    }

    func testGivesUpAfterTheWindow() {
        var tracker = SettlingTracker()
        tracker.begin("BR", at: start)
        tracker.prune([makeService("BR")], now: start.addingTimeInterval(SettlingTracker.window))
        XCTAssertFalse(tracker.isSettling("BR"))
    }

    func testStopsWhenTurnedOffOrGone() {
        var tracker = SettlingTracker()
        tracker.begin("A", at: start); tracker.begin("B", at: start)
        tracker.prune([makeService("A", enabled: false)], now: start.addingTimeInterval(1))
        XCTAssertFalse(tracker.isSettling("A"))
        XCTAssertFalse(tracker.isSettling("B"))
    }
}

final class MenuBarTextTests: XCTestCase {
    func testWiFiShowsTheSSID() {
        let wifi = makeService("WIFI", name: "Wi-Fi", router: "1.1.1.1", primary: true, kind: .wifi, ssid: "MI6")
        XCTAssertEqual(MenuBarText.networkName([wifi]), "MI6")
    }

    func testWiredShowsTheServiceName() {
        let eth = makeService("ETH", name: "Ethernet", router: "1.1.1.1", primary: true)
        XCTAssertEqual(MenuBarText.networkName([eth]), "Ethernet")
    }

    func testWiFiWithoutAnSSIDFallsBackToTheServiceName() {
        let wifi = makeService("WIFI", name: "Wi-Fi", router: "1.1.1.1", primary: true, kind: .wifi)
        XCTAssertEqual(MenuBarText.networkName([wifi]), "Wi-Fi")
    }

    func testNothingRoutingShowsNothing() {
        XCTAssertNil(MenuBarText.networkName([makeService("ETH")]))
    }

    func testLongNamesAreTruncated() {
        XCTAssertEqual(MenuBarText.truncate("Thunderbolt Ethernet Slot 0"), "Thunderbolt Eth…")
        XCTAssertEqual(MenuBarText.truncate("Thunderbolt Eth…").count, MenuBarText.maxLength)
        XCTAssertEqual(MenuBarText.truncate("Exactly16Chars!!"), "Exactly16Chars!!")
        XCTAssertEqual(MenuBarText.toggled(name: "Wi-Fi", enabled: false), "Wi-Fi off")
    }
}

final class PreferencesTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let suite = "CrossbarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults)
        XCTAssertFalse(prefs.showNetworkName)
        XCTAssertTrue(prefs.confirmRouteHandoff)
        prefs.confirmRouteHandoff = false
        prefs.showNetworkName = true
        XCTAssertFalse(Preferences(defaults).confirmRouteHandoff)
        XCTAssertTrue(Preferences(defaults).showNetworkName)
    }
}
