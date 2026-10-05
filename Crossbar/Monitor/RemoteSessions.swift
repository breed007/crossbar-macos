import Darwin
import Foundation

/// Remote sessions that turning off the active route could cut (F3): SSH logins and
/// Screen Sharing. Read without privileges and without a subprocess.
struct RemoteSession: Equatable {
    enum Kind: Equatable { case ssh, screenSharing }
    let kind: Kind
    /// Where an SSH login came from, when the login record says.
    let host: String?

    var description: String {
        switch kind {
        case .ssh: return host.map { "an SSH session from \($0)" } ?? "an SSH session"
        case .screenSharing: return "a Screen Sharing session"
        }
    }
}

enum RemoteSessions {
    /// The remote sessions active right now.
    static func current() -> [RemoteSession] {
        summarize(loginHosts: loginHosts(), processNames: processNames())
    }

    /// Pure: login records with a non-empty host are remote logins (local console
    /// and Terminal sessions have none); a running `screensharingd` means someone
    /// is connected over Screen Sharing.
    static func summarize(loginHosts: [String], processNames: Set<String>) -> [RemoteSession] {
        var sessions = Set(loginHosts.filter { !$0.isEmpty }).sorted().map { RemoteSession(kind: .ssh, host: $0) }
        if processNames.contains("screensharingd") {
            sessions.append(RemoteSession(kind: .screenSharing, host: nil))
        }
        return sessions
    }

    /// One phrase listing the sessions, or nil if there are none.
    static func warning(for sessions: [RemoteSession]) -> String? {
        guard !sessions.isEmpty else { return nil }
        let list = sessions.map(\.description).joined(separator: " and ")
        return "This Mac has \(list), which may disconnect."
    }

    /// Hosts of current user logins, from the utmpx login records.
    private static func loginHosts() -> [String] {
        var hosts: [String] = []
        setutxent(); defer { endutxent() }
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            var host = entry.pointee.ut_host
            hosts.append(withUnsafeBytes(of: &host) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            })
        }
        return hosts
    }

    /// Names of every running process. Uses the `KERN_PROC` sysctl, which, unlike
    /// `proc_name`, also returns root-owned processes such as `screensharingd`.
    private static func processNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16   // room for new processes
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        var names = Set<String>()
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            var comm = procs[index].kp_proc.p_comm
            names.insert(withUnsafeBytes(of: &comm) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            })
        }
        return names
    }
}
