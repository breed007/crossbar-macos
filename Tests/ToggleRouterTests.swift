import XCTest

/// A helper that records calls and answers as told.
private final class FakeHelper: HelperBackend {
    var isEnabled: Bool
    var result: Result<Void, Error>
    private(set) var calls: [(Bool, String)] = []

    init(enabled: Bool, result: Result<Void, Error> = .success(())) {
        self.isEnabled = enabled
        self.result = result
    }

    func setEnabled(_ enabled: Bool, serviceID: String) async throws {
        calls.append((enabled, serviceID))
        try result.get()
    }
}

/// A Backend A stand-in.
private final class FakeFallback: PrivilegedToggle {
    var result: Result<Void, Error>
    private(set) var calls: [(Bool, String, String)] = []

    init(result: Result<Void, Error> = .success(())) { self.result = result }

    func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws {
        calls.append((enabled, serviceID, serviceName))
        try result.get()
    }
}

final class ToggleRouterTests: XCTestCase {
    private func run(_ router: ToggleRouter) async -> Error? {
        do { try await router.setEnabled(false, serviceID: "SVC", serviceName: "Wi-Fi"); return nil }
        catch { return error }
    }

    func testEnabledHelperHandlesTheToggleAlone() async {
        let helper = FakeHelper(enabled: true), fallback = FakeFallback()
        let error = await run(ToggleRouter(helper: helper, fallback: fallback))
        XCTAssertNil(error)
        XCTAssertEqual(helper.calls.map(\.1), ["SVC"])
        XCTAssertTrue(fallback.calls.isEmpty)
    }

    func testNoHelperUsesBackendAByName() async {
        let helper = FakeHelper(enabled: false), fallback = FakeFallback()
        let error = await run(ToggleRouter(helper: helper, fallback: fallback))
        XCTAssertNil(error)
        XCTAssertTrue(helper.calls.isEmpty)
        XCTAssertEqual(fallback.calls.map(\.2), ["Wi-Fi"])
    }

    func testUnreachableHelperFallsBackToBackendA() async {
        let helper = FakeHelper(enabled: true, result: .failure(PrivilegedToggleError.helperCommunicationFailed("gone")))
        let fallback = FakeFallback()
        let error = await run(ToggleRouter(helper: helper, fallback: fallback))
        XCTAssertNil(error)
        XCTAssertEqual(fallback.calls.count, 1)
    }

    func testHelperReportedFailureIsNotRetried() async {
        let code = HelperConstants.ErrorCode.commitFailed
        let helper = FakeHelper(enabled: true, result: .failure(PrivilegedToggleError.helperReportedError(code)))
        let fallback = FakeFallback()
        let error = await run(ToggleRouter(helper: helper, fallback: fallback))
        XCTAssertEqual(error as? PrivilegedToggleError, .helperReportedError(code))
        XCTAssertTrue(fallback.calls.isEmpty)
    }

    func testUnreachableHelperWithNoSudoRuleReportsTheHelperProblem() async {
        // The user set up the helper; "install the sudo rule" would be wrong advice.
        let helper = FakeHelper(enabled: true, result: .failure(PrivilegedToggleError.helperCommunicationFailed("gone")))
        let fallback = FakeFallback(result: .failure(PrivilegedToggleError.sudoRuleMissing))
        let error = await run(ToggleRouter(helper: helper, fallback: fallback))
        XCTAssertEqual(error as? PrivilegedToggleError, .helperCommunicationFailed("gone"))
    }

    func testNoHelperAndNoSudoRuleSaysSo() async {
        let fallback = FakeFallback(result: .failure(PrivilegedToggleError.sudoRuleMissing))
        let error = await run(ToggleRouter(helper: FakeHelper(enabled: false), fallback: fallback))
        XCTAssertEqual(error as? PrivilegedToggleError, .sudoRuleMissing)
    }

    func testOtherFallbackErrorsPassThrough() async {
        let fallback = FakeFallback(result: .failure(PrivilegedToggleError.timedOut))
        let error = await run(ToggleRouter(helper: FakeHelper(enabled: false), fallback: fallback))
        XCTAssertEqual(error as? PrivilegedToggleError, .timedOut)
    }
}
