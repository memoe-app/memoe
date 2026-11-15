import Contacts
import Foundation

// Contacts through the Contacts framework, for the shell connector and the
// tool.
//
//   Moe --contacts --status        "ok: reading Contacts" / "needs-setup: …", exit 3 without access
//   Moe --contacts find <name>     one line per match: name, then each email and phone, two spaces apart
//
// The same shape as EventKitBridge, for the same reason: `tools/apple.sh
// contacts-find` used `osascript … tell application "Contacts"`, which
// launches Contacts.app and answers under the Automation grant, while the
// Connections row for Contacts (`mac/contacts`) has to say whether Moe may
// read your contacts — which is the Contacts grant, Moe's own. Reading
// in-process makes the row's permission the tool's permission, and nothing
// appears in the Dock. The AppleScript stays in apple.sh and contacts.sh as
// the fallback for a checkout with no app installed.
//
// MOE_EVENTKIT_NO_PROMPT=1 means the same here as there: "not determined"
// reads as denied rather than raising the sheet from a timer or a test.
enum ContactsBridge {
    static let usage = "usage: Moe --contacts [--status] [find <name>]"

    static func run(_ args: ArraySlice<String>) async -> Never {
        var status = false
        var query: String?
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--status": status = true
            case "find":
                guard let q = it.next()?.trimmingCharacters(in: .whitespaces), !q.isEmpty else {
                    EventKitBridge.fail("find takes a name\n\(usage)")
                }
                query = q
            default: EventKitBridge.fail("unknown argument: \(a)\n\(usage)")
            }
        }
        guard status || query != nil else { EventKitBridge.fail(usage) }
        let store = CNContactStore()
        await ensureAccess(store)
        if status {
            print("ok: reading Contacts")
            exit(0)
        }
        print(find(query ?? "", in: store), terminator: "")
        exit(0)
    }

    static let needsSetup = "needs-setup: allow Memoe to read your Contacts (System Settings › Privacy & Security › Contacts)"

    /// Access, or a one-line reason and exit 3 — EventKitBridge's contract,
    /// which contacts.sh and the Connections row already read.
    static func ensureAccess(_ store: CNContactStore) async {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            if ProcessInfo.processInfo.environment["MOE_EVENTKIT_NO_PROMPT"] != nil {
                EventKitBridge.fail("needs-setup: Contacts access not yet granted to Moe (System Settings › Privacy & Security › Contacts)", code: EventKitBridge.deniedExit)
            }
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if granted { return }
            EventKitBridge.fail(needsSetup, code: EventKitBridge.deniedExit)
        case .denied, .restricted:
            EventKitBridge.fail(needsSetup, code: EventKitBridge.deniedExit)
        default:
            // macOS 15's limited grant: some access is access.
            return
        }
    }

    /// The lines `apple.sh contacts-find` has always printed: the name, then
    /// every email and phone, separated by two spaces.
    static func find(_ query: String, in store: CNContactStore) -> String {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)) ?? []
        return format(found.map { c in
            (CNContactFormatter.string(from: c, style: .fullName) ?? "",
             c.emailAddresses.map { String($0.value) },
             c.phoneNumbers.map { $0.value.stringValue })
        })
    }

    /// Kept apart from the store so a test can hand it people.
    static func format(_ people: [(name: String, emails: [String], phones: [String])]) -> String {
        people
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ([$0.name] + $0.emails + $0.phones).joined(separator: "  ") + "\n" }
            .joined()
    }
}
