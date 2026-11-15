import AppKit
import Foundation

/// The app's half of `moe_settings_change` and `moe_settings_show`
/// (moe-home/hermes-plugins/moe-screen/settings.py; docs/SETTINGS-ASSISTANT.md).
///
/// The plugin makes a named pipe only this user can open and posts a
/// distributed notification whose object is
/// `{"reply": <pipe>, "action": "change"|"show", "id": …, "value": …}`. The
/// app answers one line of JSON down the pipe, as `LocationBridge` does.
///
/// Anything on this Mac can post that notification, so the checks here are
/// the ones that count, whatever the plugin already refused:
/// - a turn the person started is in flight with a settings step running;
/// - the id is in `SettingsCatalogue`;
/// - a change is only ever for an entry whose `who` is `.moe`, with a value
///   the entry takes, applied through the entry's own `write`.
@MainActor
final class SettingsBridge {
    /// Kept equal to SIGNAL in moe-home/hermes-plugins/moe-screen/settings.py.
    static let signal = Notification.Name("com.moe.settings")

    /// Whether the person's own turn has a settings step running.
    var stepRunning: () -> Bool = { false }
    var log: (String) -> Void = { Log.write($0) }
    /// The step event and the plugin's signal travel separately and the
    /// signal can win. How long to give the step to show up.
    var stepGrace: TimeInterval = 2
    /// Opens Settings on a page with a row lit; replaced in tests.
    var open: (MainWindow.Section, String) -> Void = { _, _ in }
    private weak var conductor: Conductor?
    private var observer: NSObjectProtocol?

    init(conductor: Conductor? = nil) { self.conductor = conductor }

    static func isSettingsTool(_ name: String) -> Bool {
        ["moe_settings_change", "moe_settings_show"].contains { name == $0 || name.hasSuffix("__" + $0) }
    }

    func watch(_ conductor: Conductor) {
        self.conductor = conductor
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.signal, object: nil, queue: .main) { [weak self] note in
            guard let request = note.object as? String else { return }
            Task { @MainActor in await self?.handle(request: request) }
        }
    }

    struct Request: Equatable {
        enum Action: String { case change, show }
        var reply: String
        var action: Action
        var id: String
        var value: String?

        init?(_ raw: String) {
            guard raw.utf8.count <= 4096,
                  let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let reply = obj["reply"] as? String, reply.hasPrefix("/"),
                  let action = (obj["action"] as? String).flatMap(Action.init(rawValue:)),
                  let id = obj["id"] as? String, !id.isEmpty, id.count <= 80 else { return nil }
            self.reply = reply
            self.action = action
            self.id = id
            self.value = obj["value"] as? String
        }
    }

    static func refused(_ say: String) -> [String: Any] { ["status": "refused", "say": say] }

    /// The answer for a request, gate included. What `handle` writes.
    func answer(_ r: Request) async -> [String: Any] {
        var waited: TimeInterval = 0
        while !stepRunning(), waited < stepGrace {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard stepRunning() else {
            log("settings: refused \(r.action.rawValue) \(r.id.prefix(40)) — no settings step in a turn of the person's")
            return Self.refused("Not done: no turn of the person's at the Mac is asking for it.")
        }
        guard let entry = SettingsCatalogue.entry(r.id) else {
            return Self.refused("Memoe has no setting with that id.")
        }
        await SettingsCatalogue.Live.refresh()
        let page = SettingsView.label(SettingsWindow.Selection.landing(entry.page), awayTier: nil)
        switch r.action {
        case .show:
            open(entry.page, entry.title)
            log("settings: the brain opened \(entry.id) on \(page)")
            return ["status": "ok", "title": entry.title, "page": page,
                    "say": "Settings is open on \(page), with “\(entry.title)” highlighted."]
        case .change:
            guard entry.who == .moe else {
                log("settings: refused change \(entry.id) — the person's to flip")
                return Self.refused("“\(entry.title)” is the person's to change. Offer to open it instead.")
            }
            guard let conductor else { return Self.refused("Memoe is not ready.") }
            guard let value = r.value.flatMap({ SettingsCatalogue.normalise($0, for: entry) }) else {
                return Self.refused("“\(entry.title)” does not take that value.")
            }
            let was = entry.read(conductor)
            guard entry.write(conductor, value) else {
                log("settings: \(entry.id) did not take \(value)")
                return Self.refused("“\(entry.title)” could not be changed just now; it is still \(was).")
            }
            let now = entry.read(conductor)
            SettingsCatalogue.publish(conductor)
            log("settings: the brain changed \(entry.id) \(was) → \(now)")
            return ["status": "ok", "title": entry.title, "page": page, "was": was, "now": now,
                    "say": "“\(entry.title)” is now \(now) (it was \(was)). It is on Settings › \(page)."]
        }
    }

    func handle(request raw: String) async {
        guard let request = Request(raw) else {
            log("settings: refused — not a request")
            return
        }
        let reply = await answer(request)
        guard var data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !LocationBridge.write(data, toPipe: request.reply) {
            log("settings: nobody was reading the reply")
        }
    }
}
