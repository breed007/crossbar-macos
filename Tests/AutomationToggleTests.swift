import XCTest

/// A network the fakes can change: setEnabled flips the service and records it. Like
/// a real network, a service it turns on has no router until DHCP answers, which
/// here is after `connectAfterPauses` pauses (nil: never).
private final class FakeNetwork: @unchecked Sendable {
    var services: [NetworkServiceState]
    var calls: [(Bool, String)] = []
    var error: Error?
    var failingIDs: Set<String> = []
    var announcements: [AutomationToggle.Announcement] = []
    var connectAfterPauses: Int? = 2
    var pauses = 0
    private var pendingRouters: [String: String] = [:]

    init(_ services: [NetworkServiceState]) { self.services = services }

    private func replace(_ id: String, enabled: Bool, router: String?) {
        services = services.map {
            guard $0.id == id else { return $0 }
            return makeService($0.id, name: $0.name, enabled: enabled, router: router,
                               primary: enabled && $0.isPrimary, kind: $0.kind, order: $0.orderIndex)
        }
    }

    var automation: AutomationToggle {
        var automation = AutomationToggle(
            services: { self.services },
            setEnabled: { enabled, id, _ in
                self.calls.append((enabled, id))
                if let error = self.error, self.failingIDs.isEmpty || self.failingIDs.contains(id) { throw error }
                let router = self.services.first { $0.id == id }?.router
                if enabled, let router { self.pendingRouters[id] = router }
                self.replace(id, enabled: enabled, router: nil)
            },
            announce: { self.announcements.append($0) })
        automation.pause = {
            self.pauses += 1
            guard let after = self.connectAfterPauses, self.pauses >= after else { return }
            for (id, router) in self.pendingRouters { self.replace(id, enabled: true, router: router) }
            self.pendingRouters = [:]
        }
        return automation
    }
}

final class AutomationToggleTests: XCTestCase {
    private func network() -> FakeNetwork {
        FakeNetwork([
            makeService("ETH", name: "Ethernet", router: "10.0.0.1", primary: true, order: 0),
            makeService("WIFI", name: "Wi-Fi", enabled: false, router: "192.168.1.1", kind: .wifi, order: 1),
        ])
    }

    func testAlreadyInStateDoesNothingAndSaysNothing() async throws {
        let net = network()
        let applied = try await net.automation.run([.init(serviceID: "ETH", enabled: true)], source: .shortcut)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(net.calls.isEmpty)
        XCTAssertTrue(net.announcements.isEmpty)
    }

    func testTurnOnsRunBeforeTurnOffs() async throws {
        let net = network()
        try await net.automation.run([.init(serviceID: "ETH", enabled: false),
                                      .init(serviceID: "WIFI", enabled: true)], source: .focus)
        XCTAssertEqual(net.calls.map(\.1), ["WIFI", "ETH"], "Wi-Fi comes up before Ethernet goes down")
        XCTAssertEqual(net.pauses, 2, "Ethernet waits until Wi-Fi has a router")
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Wi-Fi", enabled: true),
                                                     .init(name: "Ethernet", enabled: false)],
                                                    source: .focus, consequence: "Traffic will move to Wi-Fi.")])
    }

    func testSwapGivesUpWaitingWhenTheNewServiceNeverConnects() async throws {
        let net = network()
        net.connectAfterPauses = nil
        try await net.automation.run([.init(serviceID: "WIFI", enabled: true),
                                      .init(serviceID: "ETH", enabled: false)], source: .focus)
        XCTAssertEqual(net.pauses, Int(AutomationToggle.routeWait / AutomationToggle.routePollInterval))
        XCTAssertEqual(net.calls.map(\.1), ["WIFI", "ETH"], "the Focus still does what it was set up to do")
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Wi-Fi", enabled: true),
                                                     .init(name: "Ethernet", enabled: false)], source: .focus,
                                                    consequence: "Nothing else is connected, so you’ll go offline.")])
    }

    func testNoWaitWhenTheTurnOffIsntCarryingTraffic() async throws {
        let net = FakeNetwork([
            makeService("ETH", name: "Ethernet", router: "10.0.0.1", primary: true, order: 0),
            makeService("WIFI", name: "Wi-Fi", enabled: false, router: "192.168.1.1", kind: .wifi, order: 1),
            makeService("BR", name: "Thunderbolt Bridge", kind: .aggregate, order: 2),
        ])
        try await net.automation.run([.init(serviceID: "WIFI", enabled: true),
                                      .init(serviceID: "BR", enabled: false)], source: .focus)
        XCTAssertEqual(net.pauses, 0)
        XCTAssertEqual(net.calls.map(\.1), ["WIFI", "BR"])
    }

    func testTurningOffEveryLinkTogetherSaysOffline() async throws {
        let net = FakeNetwork([
            makeService("ETH", name: "Ethernet", router: "10.0.0.1", primary: true, order: 0),
            makeService("WIFI", name: "Wi-Fi", router: "192.168.1.1", kind: .wifi, order: 1),
        ])
        for order in [["ETH", "WIFI"], ["WIFI", "ETH"]] {
            net.services = [makeService("ETH", name: "Ethernet", router: "10.0.0.1", primary: true, order: 0),
                            makeService("WIFI", name: "Wi-Fi", router: "192.168.1.1", kind: .wifi, order: 1)]
            net.announcements = []
            try await net.automation.run(order.map { .init(serviceID: $0, enabled: false) }, source: .focus)
            guard case .changed(_, _, let consequence) = net.announcements.first else { return XCTFail() }
            XCTAssertEqual(consequence, "Nothing else is connected, so you’ll go offline.", "order \(order)")
        }
    }

    func testTheWaitEndsWhenAnyNewServiceCanTakeOver() async throws {
        let net = FakeNetwork([
            makeService("ETH", name: "Ethernet", router: "10.0.0.1", primary: true, order: 0),
            makeService("WIFI", name: "Wi-Fi", enabled: false, router: "192.168.1.1", kind: .wifi, order: 1),
            makeService("BR", name: "Thunderbolt Bridge", enabled: false, kind: .aggregate, order: 2),
        ])
        try await net.automation.run([.init(serviceID: "WIFI", enabled: true), .init(serviceID: "BR", enabled: true),
                                      .init(serviceID: "ETH", enabled: false)], source: .focus)
        XCTAssertEqual(net.pauses, 2, "the bridge never gets a router, but Wi-Fi does")
    }

    func testTheFirstConsequenceIsKept() async throws {
        let net = FakeNetwork([
            makeService("ETH", name: "Ethernet", router: "10.0.0.1", primary: true, order: 0),
            makeService("WIFI", name: "Wi-Fi", router: "192.168.1.1", kind: .wifi, order: 1),
            makeService("BR", name: "Thunderbolt Bridge", kind: .aggregate, order: 2),
        ])
        try await net.automation.run([.init(serviceID: "ETH", enabled: false),
                                      .init(serviceID: "BR", enabled: false)], source: .shortcut)
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Ethernet", enabled: false),
                                                     .init(name: "Thunderbolt Bridge", enabled: false)],
                                                    source: .shortcut, consequence: "Traffic will move to Wi-Fi.")])
    }

    func testTurningOffTheOnlyRouteAnnouncesOffline() async throws {
        let net = network()
        try await net.automation.run([.init(serviceID: "ETH", enabled: false)], source: .shortcut)
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Ethernet", enabled: false)], source: .shortcut,
                                                    consequence: "Nothing else is connected, so you’ll go offline.")])
    }

    func testShortcutFailuresThrowAndAnnounceNothing() async {
        let net = network()
        net.error = PrivilegedToggleError.sudoRuleMissing
        do {
            try await net.automation.run([.init(serviceID: "ETH", enabled: false)], source: .shortcut)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? PrivilegedToggleError, .sudoRuleMissing)
        }
        XCTAssertTrue(net.announcements.isEmpty)
    }

    func testShortcutForAMissingServiceThrows() async {
        do {
            try await network().automation.run([.init(serviceID: "GONE", enabled: false)], source: .shortcut)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AutomationToggle.Failure, .unknownService)
        }
    }

    func testAShortcutThatFailsPartwayStillAnnouncesWhatChanged() async {
        let net = network()
        net.error = PrivilegedToggleError.helperReportedError(HelperConstants.ErrorCode.commitFailed)
        net.failingIDs = ["ETH"]
        do {
            try await net.automation.run([.init(serviceID: "WIFI", enabled: true),
                                          .init(serviceID: "ETH", enabled: false)], source: .shortcut)
            XCTFail("expected a throw")
        } catch {}
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Wi-Fi", enabled: true)], source: .shortcut,
                                                    consequence: nil)])
    }

    func testAFocusThatLosesItsSetupPartwayAnnouncesWhatChanged() async throws {
        let net = network()
        net.error = PrivilegedToggleError.sudoRuleMissing
        net.failingIDs = ["ETH"]
        let applied = try await net.automation.run([.init(serviceID: "WIFI", enabled: true),
                                                    .init(serviceID: "ETH", enabled: false)], source: .focus)
        XCTAssertEqual(applied, [.init(name: "Wi-Fi", enabled: true)])
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Wi-Fi", enabled: true)], source: .focus,
                                                    consequence: nil),
                                           .setupNeeded])
    }

    func testFocusWithNothingSetUpAnnouncesSetupNeeded() async throws {
        let net = network()
        net.error = PrivilegedToggleError.sudoRuleMissing
        let applied = try await net.automation.run([.init(serviceID: "ETH", enabled: false)], source: .focus)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(net.announcements, [.setupNeeded])
    }

    func testFocusFailuresAreAnnouncedNotThrown() async throws {
        let net = network()
        net.error = PrivilegedToggleError.helperReportedError(HelperConstants.ErrorCode.commitFailed)
        try await net.automation.run([.init(serviceID: "ETH", enabled: false)], source: .focus)
        XCTAssertEqual(net.announcements, [.failed(names: ["Ethernet"])])
    }

    func testFocusSkipsAndReportsServicesThatNoLongerExist() async throws {
        let net = network()
        let applied = try await net.automation.run([.init(serviceID: "GONE", enabled: true, name: "Old VPN"),
                                                    .init(serviceID: "WIFI", enabled: true)], source: .focus)
        XCTAssertEqual(applied, [.init(name: "Wi-Fi", enabled: true)])
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Wi-Fi", enabled: true)], source: .focus,
                                                    consequence: nil),
                                           .failed(names: ["Old VPN"])])
    }
}

final class ToggleNotifierTests: XCTestCase {
    func testOneChange() {
        let (title, body) = ToggleNotifier.text(for: .changed([.init(name: "Wi-Fi", enabled: false)], source: .focus,
                                                              consequence: "Traffic will move to Ethernet."))
        XCTAssertEqual(title, "Turned off Wi-Fi")
        XCTAssertEqual(body, "Your Focus changed it. Traffic will move to Ethernet.")
    }

    func testSeveralChanges() {
        let (title, body) = ToggleNotifier.text(for: .changed([.init(name: "Wi-Fi", enabled: true),
                                                               .init(name: "Ethernet", enabled: false)],
                                                              source: .shortcut, consequence: nil))
        XCTAssertEqual(title, "Changed 2 network services")
        XCTAssertEqual(body, "A shortcut turned on Wi-Fi, turned off Ethernet.")
    }

    func testSetupNeededPointsAtTheSetupItem() {
        XCTAssertTrue(ToggleNotifier.text(for: .setupNeeded).1.contains("Set Up Passwordless Toggling…"))
    }
}
