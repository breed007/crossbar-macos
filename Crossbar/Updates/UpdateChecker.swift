import Cocoa

extension Notification.Name {
    /// The update check's answer, or the user's choice about it, changed. The popover
    /// and Settings refresh.
    static let crossbarUpdateStateChanged = Notification.Name("com.breed.Crossbar.updateStateChanged")
}

/// Checks GitHub for a newer crossbar, if the user turned that on (v0.7 U1–U3).
/// Notify only: it never downloads or installs anything. The request carries no
/// details about the Mac, and nothing is sent until the user says yes.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Outcome: Equatable {
        case upToDate(UpdateCheck.Version)
        case available(UpdateCheck.Release)
        case failed
    }

    let installed: UpdateCheck.Version
    private let preferences: Preferences
    private let fetch: (URL) async throws -> Data
    private let policyDisabled: () -> Bool
    private let now: () -> Date
    private var timer: Timer?
    /// The check in progress, so a second request (Check Now while the timer fires)
    /// waits for it instead of sending another GET.
    private var inFlight: Task<Outcome, Never>?

    init(preferences: Preferences = Preferences(),
         installed: UpdateCheck.Version? = nil,
         fetch: @escaping (URL) async throws -> Data = UpdateChecker.liveFetch,
         policyDisabled: @escaping () -> Bool = { UpdateCheck.disabledByPolicy(bundleID: "com.breed.Crossbar") },
         now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.installed = installed
            ?? UpdateCheck.Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            ?? UpdateCheck.Version("0")!
        self.fetch = fetch
        self.policyDisabled = policyDisabled
        self.now = now
    }

    /// An administrator turned update checks off (managed `DisableUpdateCheck`).
    var isDisabledByPolicy: Bool { policyDisabled() }

    /// Show the popover's one-time question.
    var shouldAsk: Bool {
        #if DEBUG
        if DemoData.active { return DemoData.updateRow == .ask }
        #endif
        return !isDisabledByPolicy && preferences.checkForUpdates == nil
    }

    /// Scheduled checks are on.
    var isAutomatic: Bool { !isDisabledByPolicy && preferences.checkForUpdates == true }

    /// A newer release the last check found, if any.
    var available: UpdateCheck.Release? {
        #if DEBUG
        if DemoData.active {
            return DemoData.updateRow == .available
                ? UpdateCheck.Release(version: UpdateCheck.Version("0.7.1")!, url: UpdateCheck.product.releasesPage)
                : nil
        }
        #endif
        guard !isDisabledByPolicy, let known = preferences.latestKnownRelease,
              let version = UpdateCheck.Version(known.version), let url = URL(string: known.url),
              UpdateCheck.isReleasePage(url) else { return nil }
        return UpdateCheck.update(UpdateCheck.Release(version: version, url: url), over: installed)
    }

    /// The user's answer, from the popover's question or Settings.
    func setAutomatic(_ on: Bool) {
        preferences.checkForUpdates = on
        if on { start() } else { stop() }
        NotificationCenter.default.post(name: .crossbarUpdateStateChanged, object: nil)
    }

    /// Check now if one is due, then look again every hour. Does nothing unless the
    /// user turned checks on.
    /// Returns the check it started, if any, so tests can wait for it.
    @discardableResult
    func start() -> Task<Outcome, Never>? {
        guard isAutomatic else { return nil }
        let check = checkIfDue()
        guard timer == nil else { return check }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        return check
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Returns the check it started, or nil when none is due or checks are off.
    @discardableResult
    func checkIfDue() -> Task<Outcome, Never>? {
        guard isAutomatic, UpdateCheck.isDue(lastCheck: preferences.lastUpdateCheck, now: now()) else { return nil }
        return Task { await checkNow() }
    }

    /// Ask GitHub now. Settings' Check Now calls this directly, whether or not
    /// scheduled checks are on; an administrator's policy still wins.
    @discardableResult
    func checkNow() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let check = Task { await fetchLatest() }
        inFlight = check
        defer { inFlight = nil }
        return await check.value
    }

    private func fetchLatest() async -> Outcome {
        guard !isDisabledByPolicy else { return .failed }
        preferences.lastUpdateCheck = now()
        guard let data = try? await fetch(UpdateCheck.product.latestReleaseAPI),
              let release = UpdateCheck.parseLatest(data) else { return .failed }
        preferences.latestKnownRelease = (release.version.description, release.url.absoluteString)
        NotificationCenter.default.post(name: .crossbarUpdateStateChanged, object: nil)
        return UpdateCheck.update(release, over: installed).map { .available($0) } ?? .upToDate(installed)
    }

    /// One GET with nothing about the Mac in it: an ephemeral session (no cookies,
    /// no cache) and fixed headers. URLSession would otherwise add the user's
    /// languages as Accept-Language and its own User-Agent naming the OS version.
    nonisolated static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Crossbar", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    nonisolated static func liveFetch(_ url: URL) async throws -> Data {
        let request = request(for: url)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// What clicking "crossbar 0.7.1 is available" does: the Homebrew command for a
    /// Homebrew install, the release page otherwise.
    static func present(_ release: UpdateCheck.Release) {
        let product = UpdateCheck.product
        guard UpdateCheck.installedWithHomebrew(product) else {
            NSWorkspace.shared.open(release.url)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update crossbar with Homebrew"
        alert.informativeText = "crossbar \(release.version) is available. You installed crossbar with Homebrew, so update it there:\n\n\(product.brewCommand)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(product.brewCommand, forType: .string)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.url)
        default:
            break
        }
    }
}
