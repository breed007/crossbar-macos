import XCTest

/// A network the fakes can change: setEnabled flips the service and records it.
private final class FakeNetwork: @unchecked Sendable {
    var services: [NetworkServiceState]
    var calls: [(Bool, String)] = []
    var error: Error?
    var announcements: [AutomationToggle.Announcement] = []

    init(_ services: [NetworkServiceState]) { self.services = services }

    var automation: AutomationToggle {
        AutomationToggle(
            services: { self.services },
            setEnabled: { enabled, id, _ in
                self.calls.append((enabled, id))
                if let error = self.error { throw error }
                self.services = self.services.map {
                    guard $0.id == id else { return $0 }
                    return makeService($0.id, name: $0.name, enabled: enabled, router: enabled ? $0.router : nil,
                                       primary: enabled && $0.isPrimary, kind: $0.kind, order: $0.orderIndex)
                }
            },
            announce: { self.announcements.append($0) })
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
        XCTAssertEqual(net.announcements, [.changed([.init(name: "Wi-Fi", enabled: true),
                                                     .init(name: "Ethernet", enabled: false)],
                                                    source: .focus, consequence: "Traffic will move to Wi-Fi.")])
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

    func testFocusSkipsServicesThatNoLongerExist() async throws {
        let net = network()
        let applied = try await net.automation.run([.init(serviceID: "GONE", enabled: true),
                                                    .init(serviceID: "WIFI", enabled: true)], source: .focus)
        XCTAssertEqual(applied, [.init(name: "Wi-Fi", enabled: true)])
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
