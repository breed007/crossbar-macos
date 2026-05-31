import Foundation
import CoreLocation
import CoreWLAN

/// Reads the current Wi-Fi SSID.
///
/// On macOS 14+ the SSID is withheld from any app that isn't authorized for
/// Location Services (CoreWLAN's `ssid()` returns nil; `networksetup` and
/// `system_profiler` redact it). So this provider requests When-In-Use location
/// authorization once, and calls `onAuthorizationChange` when the status flips —
/// letting the monitor re-read so the SSID appears as soon as access is granted,
/// without the user having to toggle anything.
///
/// We never start location updates; merely holding the authorization is what
/// unlocks the SSID, so there's no ongoing location use.
final class WiFiSSIDProvider: NSObject, CLLocationManagerDelegate {
    /// Invoked on the main thread whenever location authorization changes.
    var onAuthorizationChange: (() -> Void)?

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()

    override init() {
        super.init()
        locationManager.delegate = self
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()   // one-time system prompt
        }
    }

    private var isAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// The SSID for a given BSD interface (e.g. "en0"), or nil if that interface
    /// isn't Wi-Fi, isn't associated to a network, or location access is absent.
    func ssid(forBSD bsd: String) -> String? {
        guard isAuthorized else { return nil }
        guard let interface = wifiClient.interface(withName: bsd) else { return nil }
        return interface.ssid()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?()
    }
}
