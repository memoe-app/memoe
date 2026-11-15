import Foundation

// Where this Mac is, for Moe, with permission.
//
// The owner asked "what's the weather" and got Huntington Station — "which is
// where your connection places you" (2026-11-12). There was no CoreLocation
// anywhere in Sources/; the model guessed from the IP address.
//
// The shape, and why:
//
// * **A tool, not a line in the brief.** `moe_location` (the moe-screen
//   plugin's location.py) asks the app when a question needs a place. Nothing
//   about where the person is rides along on a turn that did not ask, and the
//   per-turn prompt stays stable (anything volatile there respawns Hermes's
//   child, +5–7 s).
// * **Asked on first need.** macOS's own question appears the first time a
//   turn calls the tool — never at launch, never in the welcome.
// * **Rounded unless precision is asked for.** Two decimal places, about a
//   kilometre, is plenty for weather and "near me". `precise` is for
//   directions.
// * **Never a silent guess.** Every way of not knowing is a sentence that
//   says which it is and what Moe may do instead.
// * **Nothing kept.** The last fix lives in this object's memory so a second
//   question does not wait on the radio again; it is never written to disk,
//   to memory (claimstore), to a log, or sent anywhere by the app. The log
//   gets "location: fix, accuracy N m, age N s" and no numbers that place it.
//
// CoreLocation sits behind `LocationProvider` so every test injects its own
// fixes and refusals and no test can raise macOS's prompt.

enum LocationAuthorization: Equatable, Sendable {
    case notDetermined, denied, restricted, authorized
}

struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy, metres.
    var accuracy: Double
    var at: Date
}

struct PlaceName: Equatable, Sendable {
    var city: String?
    var region: String?
    var country: String?
    var countryCode: String?
    var timeZone: String?
}

@MainActor
protocol LocationProvider: AnyObject {
    /// Location Services, the Mac-wide switch.
    func servicesEnabled() async -> Bool
    var authorization: LocationAuthorization { get }
    /// Raises macOS's question. Called at most once per launch.
    func requestAuthorization()
    /// The authorisation once it is no longer undetermined, or after `timeout`.
    func waitForDecision(timeout: TimeInterval) async -> LocationAuthorization
    /// One fresh fix, or nil when none came in time.
    func fix(timeout: TimeInterval) async -> LocationFix?
    /// The town these coordinates are in. Given the ROUNDED pair: naming a
    /// town does not need the street.
    func place(latitude: Double, longitude: Double) async -> PlaceName?
}

/// What the tool gets back.
enum LocationAnswer: Equatable {
    case place(fix: LocationFix, name: PlaceName?, precise: Bool, age: TimeInterval, stale: Bool)
    case servicesOff
    case denied
    case restricted
    /// macOS is asking the person right now and they have not answered.
    case asked
    /// Allowed, and no fix could be had.
    case unavailable
    /// Not a turn the person started at this Mac.
    case refused

    static let fallback = "Do not guess: ask the person where they are, or use the rough place their "
        + "internet connection gives and say that is what you used."

    /// The plain sentence for every answer that is not a place. Written to
    /// Moe, who puts it to the person in its own words.
    var sentence: String? {
        switch self {
        case .place: return nil
        case .servicesOff:
            return "Location Services is switched off for this whole Mac (System Settings › Privacy & "
                + "Security › Location Services), so Memoe cannot tell where it is. " + Self.fallback
        case .denied:
            return "Location is switched off for Memoe on this Mac (System Settings › Privacy & Security › "
                + "Location Services › Memoe), so Memoe cannot tell where it is. " + Self.fallback
        case .restricted:
            return "Location is restricted on this Mac by a profile or parental controls, so Memoe cannot "
                + "tell where it is and the person cannot switch it on themselves. " + Self.fallback
        case .asked:
            return "macOS is asking the person, right now, whether Memoe may use this Mac's location, and "
                + "they have not answered yet. Tell them to click Allow on that question, then call "
                + "moe_location again. If they would rather not, ask them where they are."
        case .unavailable:
            return "Location is allowed, but this Mac could not work out where it is just now (Wi-Fi being "
                + "off is the usual reason). " + Self.fallback
        case .refused:
            return "This Mac's location is only read during the person's own turn at the Mac. "
                + "Ask them where they are, or use what they have already told you."
        }
    }

    var status: String {
        switch self {
        case .place: return "ok"
        case .servicesOff: return "services_off"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .asked: return "asked"
        case .unavailable: return "unavailable"
        case .refused: return "refused"
        }
    }

    /// About a kilometre: two decimal places of a degree (1.1 km of latitude).
    static func rounded(_ degrees: Double) -> Double { (degrees * 100).rounded() / 100 }
    /// About a metre. More than the fix itself knows, never less.
    static func exact(_ degrees: Double) -> Double { (degrees * 100_000).rounded() / 100_000 }

    /// What goes down the pipe to the tool.
    var json: [String: Any] {
        guard case .place(let fix, let name, let precise, let age, let stale) = self else {
            return ["status": status, "say": sentence ?? ""]
        }
        var out: [String: Any] = [
            "status": status,
            "source": "this Mac's own location (macOS Location Services), not the internet connection",
            "latitude": precise ? Self.exact(fix.latitude) : Self.rounded(fix.latitude),
            "longitude": precise ? Self.exact(fix.longitude) : Self.rounded(fix.longitude),
            "precision": precise ? "exact" : "rounded to about 1 km",
            "accuracy_m": Int(fix.accuracy.rounded()),
            "age_s": Int(age.rounded()),
        ]
        if let v = name?.city { out["city"] = v }
        if let v = name?.region { out["region"] = v }
        if let v = name?.country { out["country"] = v }
        if let v = name?.countryCode { out["country_code"] = v }
        if let v = name?.timeZone { out["time_zone"] = v }
        var notes: [String] = []
        if name?.city == nil {
            notes.append("The town's name could not be looked up; these are coordinates only.")
        }
        if stale {
            out["stale"] = true
            notes.append("This is the last fix, about \(Self.spoken(age)) old; a fresh one could not be had "
                + "just now. Say so if where they are may have changed.")
        }
        if !notes.isEmpty { out["note"] = notes.joined(separator: " ") }
        return out
    }

    static func spoken(_ age: TimeInterval) -> String {
        let minutes = Int((age / 60).rounded())
        if minutes < 1 { return "a few seconds" }
        if minutes < 90 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = Int((age / 3600).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

@MainActor
final class LocationService {
    /// A fix this recent answers without asking the radio again.
    static let freshFor: TimeInterval = 600
    /// Tighter when the street matters.
    static let freshForPrecise: TimeInterval = 60

    private let provider: LocationProvider
    var now: () -> Date = Date.init
    /// Where the log lines go. A seam: the tests read every line.
    var log: (String) -> Void = { Log.write($0) }
    /// How long one call waits on macOS's question. Shorter than the tool's
    /// own wait (location.py), so the tool always hears back.
    var decisionWait: TimeInterval = 25
    var fixWait: TimeInterval = 10

    /// The last fix and its town. Memory only.
    private var last: (fix: LocationFix, name: PlaceName?)?
    /// macOS's question has been raised this launch.
    private(set) var asked = false

    init(provider: LocationProvider) { self.provider = provider }

    func answer(precise: Bool = false) async -> LocationAnswer {
        guard await provider.servicesEnabled() else { return say(.servicesOff) }
        var auth = provider.authorization
        if auth == .notDetermined {
            // Once per launch: a second call while the question is still up
            // waits on the same question instead of raising another.
            if !asked {
                asked = true
                log("location: asked macOS for permission (first need)")
                provider.requestAuthorization()
            }
            auth = await provider.waitForDecision(timeout: decisionWait)
        }
        switch auth {
        case .notDetermined: return say(.asked)
        case .denied: return say(.denied)
        case .restricted: return say(.restricted)
        case .authorized: break
        }

        let window = precise ? Self.freshForPrecise : Self.freshFor
        if let last, now().timeIntervalSince(last.fix.at) <= window {
            return say(.place(fix: last.fix, name: last.name, precise: precise,
                              age: max(0, now().timeIntervalSince(last.fix.at)), stale: false))
        }
        guard let fix = await provider.fix(timeout: fixWait) else {
            // The old fix, marked with its age, beats nothing — and is said.
            if let last {
                return say(.place(fix: last.fix, name: last.name, precise: precise,
                                  age: max(0, now().timeIntervalSince(last.fix.at)), stale: true))
            }
            return say(.unavailable)
        }
        let lat = LocationAnswer.rounded(fix.latitude), lon = LocationAnswer.rounded(fix.longitude)
        var name: PlaceName?
        if let last, last.name?.city != nil,
           LocationAnswer.rounded(last.fix.latitude) == lat, LocationAnswer.rounded(last.fix.longitude) == lon {
            name = last.name   // the same square kilometre: the same town
        } else {
            name = await provider.place(latitude: lat, longitude: lon)
        }
        last = (fix, name)
        return say(.place(fix: fix, name: name, precise: precise,
                          age: max(0, now().timeIntervalSince(fix.at)), stale: false))
    }

    /// One log line per answer, and never a number that places anyone.
    private func say(_ answer: LocationAnswer) -> LocationAnswer {
        if case .place(let fix, let name, let precise, let age, let stale) = answer {
            log("location: \(stale ? "stale fix" : "fix"), accuracy \(Int(fix.accuracy.rounded())) m, "
                + "age \(Int(age.rounded())) s, \(precise ? "exact" : "rounded"), "
                + "town \(name?.city == nil ? "not named" : "named")")
        } else {
            log("location: no place given — \(answer.status)")
        }
        return answer
    }
}
