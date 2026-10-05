import XCTest

final class NetworkServiceStateTests: XCTestCase {
    private func service(enabled: Bool = true, ip: String? = nil, link: Bool = false,
                         primary: Bool = false) -> NetworkServiceState {
        NetworkServiceState(id: "ID", name: "Wi-Fi", bsdName: "en0", isEnabled: enabled,
                            ipv4Address: ip, router: nil, hasActiveLink: link,
                            isPrimary: primary, kind: .wifi, ssid: nil)
    }

    func testDisabledIsInactiveWhateverElseIsTrue() {
        XCTAssertEqual(service(enabled: false, ip: "10.0.0.2", link: true).connectivity, .inactive)
        XCTAssertEqual(service(enabled: false).routeState, "Disabled")
    }

    func testAddressOrLinkMeansConnected() {
        XCTAssertEqual(service(ip: "10.0.0.2").connectivity, .connected)
        XCTAssertEqual(service(link: true).connectivity, .connected)
        XCTAssertEqual(service().connectivity, .notConnected)
    }

    func testRouteState() {
        XCTAssertEqual(service(primary: true).routeState, "Enabled & routing")
        XCTAssertEqual(service().routeState, "Enabled & dormant")
    }

    func testKindsSortWiredFirstOtherLast() {
        let ranks = [NetworkServiceState.Kind.other, .aggregate, .vpn, .wifi, .wired].map(\.sortRank)
        XCTAssertEqual(ranks, ranks.sorted(by: >))
    }
}
