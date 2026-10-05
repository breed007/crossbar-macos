import Foundation

/// Backend A: change service state by invoking
/// `sudo networksetup -setnetworkserviceenabled "<name>" on|off`, relying on a
/// passwordless sudoers rule (see README). No daemon, no XPC.
///
/// Safety properties:
///   - Arguments are passed as an explicit `argv` array — there is no shell, so
///     service names with spaces or odd characters can't be misinterpreted and
///     nothing can be injected.
///   - Calls are serialized on a private queue, so rapid clicks never produce
///     overlapping `networksetup` invocations.
///   - `sudo -n` (non-interactive) means a missing sudoers rule fails fast with
///     a detectable error instead of silently hanging on a password prompt.
///   - A `networksetup` that hangs is terminated after `timeout` seconds, so a
///     wedged process can't freeze a row (and the serial queue behind it) forever.
final class NetworksetupToggle: PrivilegedToggle {
    private static let networksetupPath = "/usr/sbin/networksetup"
    private static let sudoPath = "/usr/bin/sudo"
    private static let timeout: TimeInterval = 20

    /// Serial queue → at most one networksetup process at a time.
    private let queue = DispatchQueue(label: "com.breed.Crossbar.PrivilegedToggle")

    /// Backend A toggles by display name (all `networksetup` accepts); the
    /// stable `serviceID` is unused here.
    func setEnabled(_ enabled: Bool, serviceID: String, serviceName: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Self.run(enabled: enabled, serviceName: serviceName)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func run(enabled: Bool, serviceName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = [
            "-n",                              // non-interactive: never prompt
            networksetupPath,
            "-setnetworkserviceenabled",
            serviceName,                       // single argv element — no shell
            enabled ? "on" : "off",
        ]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PrivilegedToggleError.launchFailed(error.localizedDescription)
        }

        // Watchdog: terminating sudo (which relays the signal to networksetup)
        // closes stderr, which unblocks the read below.
        let fired = TimeoutFlag()
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            fired.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if fired.isSet { throw PrivilegedToggleError.timedOut }
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            // `sudo -n` prints these when it would have needed to prompt — i.e.
            // the NOPASSWD rule for this exact command isn't in place.
            if stderrText.localizedCaseInsensitiveContains("password is required")
                || stderrText.localizedCaseInsensitiveContains("a terminal is required") {
                throw PrivilegedToggleError.sudoRuleMissing
            }
            throw PrivilegedToggleError.commandFailed(
                status: process.terminationStatus, message: stderrText)
        }
    }
}

/// Set by the watchdog on another queue, read after the process exits.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
