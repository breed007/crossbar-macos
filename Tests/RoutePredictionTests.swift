import XCTest

/// Builds a service; `order` is its position in the service order.
func makeService(_ id: String, name: String? = nil, enabled: Bool = true, router: String? = nil,
                 ip: String? = nil, primary: Bool = false, kind: NetworkServiceState.Kind = .wired,
                 ssid: String? = nil, order: Int = 0) -> NetworkServiceState {
    NetworkServiceState(id: id, name: name ?? id, bsdName: nil, isEnabled: enabled,
                        ipv4Address: ip ?? (router == nil ? nil : "10.0.0.\(order + 2)"),
                        router: router, hasActiveLink: router != nil, isPrimary: primary,
                        kind: kind, ssid: ssid, orderIndex: order)
}

final class RoutePredictionTests: XCTestCase {
    private let ethernet = makeService("ETH", name: "Thunderbolt Ethernet", router: "10.0.0.1", primary: true, order: 0)
    private let wifi = makeService("WIFI", name: "Wi-Fi", router: "10.20.40.1", kind: .wifi, ssid: "Harbor Lane", order: 2)

    func testDormantServiceNeedsNoWarning() {
        XCTAssertEqual(RoutePrediction.disabling("WIFI", in: [ethernet, wifi]), .notActiveRoute)
    }

    func testUnknownServiceNeedsNoWarning() {
        XCTAssertEqual(RoutePrediction.disabling("GONE", in: [ethernet, wifi]), .notActiveRoute)
    }

    func testActiveRouteHandsOffToTheNextConnectedService() {
        XCTAssertEqual(RoutePrediction.disabling("ETH", in: [ethernet, wifi]), .handoff(to: wifi))
        XCTAssertEqual(RoutePrediction.disabling("ETH", in: [ethernet, wifi]).sentence,
                       "Traffic will move to Wi-Fi (Harbor Lane).")
    }

    func testSuccessorFollowsServiceOrderNotListOrder() {
        let usb = makeService("USB", name: "USB Ethernet", router: "10.1.0.1", order: 1)
        // The list is sorted by category for display; prediction must use service order.
        XCTAssertEqual(RoutePrediction.disabling("ETH", in: [ethernet, wifi, usb]), .handoff(to: usb))
    }

    func testServicesWithoutARouterCantTakeOver() {
        let bridge = makeService("BR", name: "Thunderbolt Bridge", kind: .aggregate, order: 1)  // no router
        let off = makeService("OFF", enabled: false, router: "10.2.0.1", order: 1)            // disabled
        XCTAssertEqual(RoutePrediction.disabling("ETH", in: [ethernet, bridge, off]), .offline)
        XCTAssertEqual(RoutePrediction.disabling("ETH", in: [ethernet]).sentence,
                       "Nothing else is connected, so you’ll go offline.")
    }

    func testRemoteSessionsFromLoginRecordsAndProcesses() {
        let sessions = RemoteSessions.summarize(loginHosts: ["", "10.0.0.5", "10.0.0.5"],
                                                processNames: ["launchd", "screensharingd"])
        XCTAssertEqual(sessions, [RemoteSession(kind: .ssh, host: "10.0.0.5"),
                                  RemoteSession(kind: .screenSharing, host: nil)])
        XCTAssertEqual(RemoteSessions.warning(for: sessions),
                       "This Mac has an SSH session from 10.0.0.5 and a Screen Sharing session, which may disconnect.")
    }

    func testLocalSessionsAreNotRemote() {
        XCTAssertTrue(RemoteSessions.summarize(loginHosts: ["", ""], processNames: ["launchd"]).isEmpty)
        XCTAssertNil(RemoteSessions.warning(for: []))
    }
}
