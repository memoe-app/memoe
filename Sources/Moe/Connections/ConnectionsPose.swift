import Foundation

/// Invented connections for `--settings-snapshot` and the layout tests:
/// nobody's real accounts, every shape the detail side has to hold.
///
/// Built through the real parser and the real fold (`ConnectionsCatalog.parse`
/// and `.merge`), from the JSON the scripts would print — so a posed Gmail has
/// the label, the blurb, the accounts and the folded "Use an app password
/// instead" row a real one has, and a change to any of those shows up in the
/// pictures without anyone editing this file.
enum ConnectionsPose {
    /// One brokered service's sign-ins.
    struct Service {
        let name: String
        let label: String
        var state = "ok"
        var auth = "oauth"
        var broken = false
        /// (id, who, status)
        var accounts: [(String, String, String)] = []
    }

    static let gmailThree = "gmail-three"

    /// The poses, by name. Each is a whole list, so the left side is drawn
    /// with rows in it too — it shares the window's height with the detail.
    static let all: [(name: String, select: String, services: [Service])] = [
        // The owner's report: three addresses and the app-password row.
        (gmailThree, "composio/gmail", [gmail([("ca_pose_1", "ada@example.com", "ACTIVE"),
                                               ("ca_pose_2", "ada.lovelace@work.example.com", "ACTIVE"),
                                               ("ca_pose_3", "family@example.com", "ACTIVE")])]),
        ("gmail-one", "composio/gmail", [gmail([("ca_pose_1", "ada@example.com", "ACTIVE")])]),
        // Unnamed: Composio records no identity, so the row says which one
        // by its place in the list.
        ("gmail-unnamed", "composio/gmail", [gmail([("ca_pose_1", "", "ACTIVE"), ("ca_pose_2", "", "ACTIVE")])]),
        ("gmail-none", "composio/gmail", [gmail([], state: "missing")]),
        // Nothing live: the dead sign-ins are the explanation, so they show.
        ("gmail-expired", "composio/gmail", [gmail([("ca_pose_1", "ada@example.com", "EXPIRED"),
                                                    ("ca_pose_2", "", "INITIATED")], state: "needs-setup")]),
        // Many, and long: the page has to scroll and an address has to wrap.
        ("gmail-many", "composio/gmail", [gmail((1...9).map {
            ("ca_pose_\($0)", "a.very.long.mailbox.name.number.\($0)@a-long-department.subsidiary.example.com", "ACTIVE")
        })]),
        ("gmail-broken", "composio/gmail", [gmail([], broken: true)]),
    ]

    private static func gmail(_ accounts: [(String, String, String)], state: String = "ok",
                              broken: Bool = false) -> Service {
        Service(name: "gmail", label: "Gmail", state: state, broken: broken, accounts: accounts)
    }

    /// Enough other rows that the list is longer than a short window.
    private static let others: [Service] = [
        Service(name: "googlecalendar", label: "Google Calendar", accounts: [("ca_pose_c", "ada@example.com", "ACTIVE")]),
        Service(name: "googledrive", label: "Google Drive", state: "missing"),
        Service(name: "notion", label: "Notion", state: "missing"),
        Service(name: "slack", label: "Slack", state: "missing"),
        Service(name: "github", label: "GitHub", state: "missing"),
        Service(name: "linear", label: "Linear", state: "missing"),
        Service(name: "hubspot", label: "HubSpot", state: "missing"),
        Service(name: "figma", label: "Figma", state: "missing"),
        Service(name: "asana", label: "Asana", state: "missing"),
        Service(name: "dropbox", label: "Dropbox", state: "missing"),
        Service(name: "trello", label: "Trello", state: "missing"),
        Service(name: "airtable", label: "Airtable", state: "missing"),
    ]

    static func rows(_ name: String) -> [Connection] {
        guard let pose = all.first(where: { $0.name == name }) else { return [] }
        return rows(pose.services + others)
    }

    static func rows(_ services: [Service]) -> [Connection] {
        let catalog: [String: Any] = ["composio": services.map { s -> [String: Any] in
            ["kind": "composio", "name": s.name, "label": s.label,
             "blurb": "Moe can read and work with your \(s.label), and change things when you ask. One sign-in, nothing to paste.",
             "auth": s.auth, "broken": s.broken, "featured": true,
             "docs": "https://example.com/\(s.name)"]
        }]
        let connections: [String: Any] = ["connections": services.map { s -> [String: Any] in
            ["kind": "composio", "name": s.name, "label": s.label, "auth": s.auth, "state": s.state,
             "detail": s.accounts.contains { $0.2 == "ACTIVE" } ? "connected" : "",
             "accounts": s.accounts.map { ["id": $0.0, "who": $0.1, "status": $0.2] }]
        }]
        let parsed = ConnectionsCatalog.parse(
            catalogJSON: (try? JSONSerialization.data(withJSONObject: catalog)) ?? Data(),
            connectionsJSON: (try? JSONSerialization.data(withJSONObject: connections)) ?? Data())
        // The Mac's own Gmail, not connected — which the fold turns into the
        // "Use an app password instead" row under the brokered one.
        let mac = MacSources.specs.filter { $0.key == "gmail" }
            .map { MacSources.connection(for: $0, statusLine: "not-connected: no mailbox yet") }
        return ConnectionsCatalog.merge(mac: mac, engine: parsed.connections)
    }
}
