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

    func testDisplayOrderIsCategoryThenServiceOrderThenName() {
        let vpn = makeService("VPN", name: "Corp VPN", kind: .vpn, order: 0)
        let wifi = makeService("WIFI", name: "Wi-Fi", kind: .wifi, order: 1)
        let usb = makeService("USB", name: "USB Ethernet", order: 3)
        let dockB = makeService("B", name: "Dock B", order: 2)
        let dockA = makeService("A", name: "Dock A", order: 2)
        let sorted = [vpn, wifi, usb, dockB, dockA].sorted(by: NetworkServiceState.displaysBefore)
        XCTAssertEqual(sorted.map(\.id), ["A", "B", "USB", "WIFI", "VPN"])
    }

    func testKindsSortWiredFirstOtherLast() {
        let ranks = [NetworkServiceState.Kind.other, .aggregate, .vpn, .wifi, .wired].map(\.sortRank)
        XCTAssertEqual(ranks, ranks.sorted(by: >))
    }
}
