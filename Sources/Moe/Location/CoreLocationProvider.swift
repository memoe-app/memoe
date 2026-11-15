import CoreLocation
import Foundation

/// The real `LocationProvider`: one `CLLocationManager`, made on first use so
/// nothing touches CoreLocation until a turn needs a place. When-in-use
/// authorisation only; a hundred metres of accuracy is asked for, which is
/// Wi-Fi positioning and comes back in a second or two.
///
/// Needs, in the bundle: `NSLocationWhenInUseUsageDescription` (build.sh) and,
/// under Hardened Runtime, `com.apple.security.personal-information.location`
/// (scripts/Moe.entitlements) — without the entitlement macOS refuses with no
/// prompt at all.
@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, @preconcurrency CLLocationManagerDelegate {
    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return m
    }()
    private var decisionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var fixWaiters: [UUID: CheckedContinuation<LocationFix?, Never>] = [:]

    func servicesEnabled() async -> Bool {
        // Off the main thread: CoreLocation warns that this one can block.
        await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        default: return .authorized
        }
    }

    func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    func waitForDecision(timeout: TimeInterval) async -> LocationAuthorization {
        guard authorization == .notDetermined else { return authorization }
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            decisionWaiters[id] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.decisionWaiters.removeValue(forKey: id)?.resume()
            }
        }
        return authorization
    }

    func fix(timeout: TimeInterval) async -> LocationFix? {
        let id = UUID()
        return await withCheckedContinuation { (c: CheckedContinuation<LocationFix?, Never>) in
            fixWaiters[id] = c
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.fixWaiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func place(latitude: Double, longitude: Double) async -> PlaceName? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: latitude, longitude: longitude))
        guard let mark = marks?.first else { return nil }
        return PlaceName(city: mark.locality ?? mark.subAdministrativeArea,
                         region: mark.administrativeArea,
                         country: mark.country,
                         countryCode: mark.isoCountryCode,
                         timeZone: mark.timeZone?.identifier)
    }

    // MARK: - CLLocationManagerDelegate (delivered on the main thread, where the manager was made)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard Self.map(manager.authorizationStatus) != .notDetermined else { return }
        let waiting = decisionWaiters
        decisionWaiters.removeAll()
        for c in waiting.values { c.resume() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        finish(LocationFix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                           accuracy: l.horizontalAccuracy, at: l.timestamp))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` means "still trying"; anything else is an answer.
        if (error as? CLError)?.code == .locationUnknown { return }
        finish(nil)
    }

    private func finish(_ fix: LocationFix?) {
        let waiting = fixWaiters
        fixWaiters.removeAll()
        for c in waiting.values { c.resume(returning: fix) }
    }
}

/// Settings › Permissions: the grant's state, read without asking.
enum LocationPermission {
    static func state() -> PermissionStatus.State {
        switch CoreLocationProvider.map(CLLocationManager().authorizationStatus) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        }
    }
}

extension PermissionGuide {
    /// Location's row. Here rather than in PermissionGuide.swift's `all`:
    /// it is asked on first need only, so it has no place in the welcome's
    /// list, and no failure code points at it.
    static let location = PermissionGuide(
        id: "location",
        name: "Location Services",
        what: "To know which town you're in for the weather, “near me” and directions. Moe asks the first time a question needs it, uses it for that answer, and never follows where you go in the background.",
        ifDeclined: "Moe keeps working. It asks you where you are, or goes by the rough place your internet connection gives — and says which it used.",
        steps: "System Settings → Privacy & Security → Location Services → switch Memoe on.",
        settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
        needsRelaunch: false,
        codes: [],
        probe: .none)
}
