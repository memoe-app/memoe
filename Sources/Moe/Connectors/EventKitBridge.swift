import EventKit
import Foundation
import MoeConnectors

// Calendar and Reminders through EventKit, for the shell connectors.
//
// `Moe --calendar` / `Moe --reminders` / `--add-reminder` / `--add-event`
// replace the `osascript … tell application "Calendar"/"Reminders"` blocks in
// moe-home/connectors/{calendar,reminders}.sh and tools/apple.sh. Those
// blocks *launch* the app — visibly, every ten minutes from com.moe.sync —
// while EventKit reads the same store in-process with nothing on screen.
//
// Permission: macOS attributes the EventKit grant to the bundle that asks,
// so when the connectors call /Applications/Memoe.app/Contents/MacOS/Moe the
// one-time "Moe would like full access to your Calendar/Reminders" sheet is
// Moe's (Info.plist carries NS{Calendars,Reminders}FullAccessUsageDescription;
// see build.sh). It appears the first time the binary is run with the
// store not yet determined — on the next sync after upgrading, or on the
// first `Moe --reminders` from a terminal. A denied or restricted store
// prints one line and exits 3, the connectors' existing error style.
//
// Text shapes are MoeConnectors.ConnectorText: identical to what the
// AppleScript produced, so context/*.md and the prompts see no change.
//
//   Moe --reminders [--crawl DAYS] [--today] [--titles] [--list NAME] [--json] [--status]
//   Moe --calendar [DAYS] [--crawl DAYS] [--from-now] [--dash] [--json] [--status]
//   Moe --add-reminder <title> [due] [list]
//   Moe --add-event <title> <start> [end] [calendar]
//   Moe --eventkit-request              ask for both grants now, deliberately
//
// Set MOE_EVENTKIT_NO_PROMPT=1 to treat "not determined" as denied instead of
// asking. sync.sh sets it, so a launchd tick never raises the sheet at a
// random moment (and the 45 s alarm never kills a half-answered one); the
// tests set it so a headless run is silent. The sheet is raised on purpose
// by `Moe --eventkit-request`, which doctor.sh runs, and by any read from an
// interactive shell.
//
// What changes against the AppleScript, on purpose:
//   - Recurring events. `events of c whose start date …` in Calendar.app
//     matched only the *master* event, so a weekly meeting created last year
//     never made it into calendar.md. EventKit expands occurrences, so every
//     instance in the window appears — the brief finally sees standups.
//   - Order. Events are sorted by start (the AppleScript went calendar by
//     calendar); reminder lists are sorted by title.
//   - Empty output is empty. osascript printed a lone "\n" for an empty
//     result (and one extra "\n" after a non-empty one), so an empty
//     calendar used to be a 1-byte context file that sync.sh treated as
//     data; now it is 0 bytes and takes sync.sh's "connected, quiet" path.

enum EventKitBridge {
    static let deniedExit: Int32 = 3

    static func fail(_ msg: String, code: Int32 = 2) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(code)
    }

    // MARK: Access

    enum Kind { case calendar, reminders }

    static func entity(_ k: Kind) -> EKEntityType { k == .calendar ? .event : .reminder }

    /// Full access, or a one-line reason and exit 3. Prompts only when the
    /// status is not yet determined (and MOE_EVENTKIT_NO_PROMPT is unset).
    static func ensureAccess(_ kind: Kind, store: EKEventStore) async {
        let name = kind == .calendar ? "Calendar" : "Reminders"
        let pane = kind == .calendar ? "Calendars" : "Reminders"
        switch EKEventStore.authorizationStatus(for: entity(kind)) {
        case .fullAccess:
            return
        case .notDetermined:
            if ProcessInfo.processInfo.environment["MOE_EVENTKIT_NO_PROMPT"] != nil {
                fail("needs-setup: \(name) access not yet granted to Moe (System Settings › Privacy & Security › \(pane))", code: deniedExit)
            }
            let granted: Bool
            do {
                granted = kind == .calendar
                    ? try await store.requestFullAccessToEvents()
                    : try await store.requestFullAccessToReminders()
            } catch {
                fail("needs-setup: \(name) access request failed: \(error.localizedDescription)", code: deniedExit)
            }
            if granted { return }
            fail("needs-setup: allow Memoe full access to \(name) (System Settings › Privacy & Security › \(pane))", code: deniedExit)
        case .denied, .restricted, .writeOnly:
            fail("needs-setup: allow Memoe full access to \(name) (System Settings › Privacy & Security › \(pane))", code: deniedExit)
        @unknown default:
            fail("needs-setup: \(name) access is in an unknown state", code: deniedExit)
        }
    }

    /// `Moe --eventkit-request`: raise the Calendar and Reminders sheets now,
    /// while someone is looking (doctor.sh), so the sync timer never has to.
    /// One line per store; exit 0 when both are granted, else 3.
    static func request() async -> Never {
        var allGranted = true
        for kind in [Kind.calendar, .reminders] {
            let name = kind == .calendar ? "Calendar" : "Reminders"
            let pane = kind == .calendar ? "Calendars" : "Reminders"
            let store = EKEventStore()
            var status = EKEventStore.authorizationStatus(for: entity(kind))
            if status == .notDetermined {
                let granted = (try? kind == .calendar
                    ? await store.requestFullAccessToEvents()
                    : await store.requestFullAccessToReminders()) ?? false
                status = granted ? .fullAccess : EKEventStore.authorizationStatus(for: entity(kind))
            }
            if status == .fullAccess {
                print("ok: \(name) full access granted to Moe")
            } else {
                allGranted = false
                print("needs-setup: allow Memoe full access to \(name) (System Settings › Privacy & Security › \(pane))")
            }
        }
        exit(allGranted ? 0 : deniedExit)
    }

    // MARK: Argument parsing

    struct Options {
        var days: Int?
        var crawlSince: Int?
        var json = false
        var status = false
        var today = false
        var titles = false
        var fromNow = false
        var dash = false
        var list: String?
        /// `--brief`: the brief's calendar, split by the clock (ticket #9).
        var brief = false
        /// `--now ISO8601`: the clock `--brief` labels against. Tests and
        /// `sync.sh` (MOE_NOW) pin it; otherwise it is the real time.
        var now: Date?
        /// `--from-json FILE`: render `--brief` from events in the `--json`
        /// shape instead of reading EventKit — fixtures, and a check that
        /// needs no Calendar permission.
        var fromJSON: String?
        /// `--items-since T`: events changed after unix time T, as the
        /// situations engine's items (CalendarItems). "" is the first look.
        var itemsSince: String?
    }

    static func parse(_ args: ArraySlice<String>, usage: String) -> Options {
        var o = Options()
        var it = args.makeIterator()
        func int(_ s: String?, _ flag: String) -> Int {
            guard let s, let n = Int(s), n >= 0 else { fail("\(flag) takes a whole number of days\n\(usage)") }
            return n
        }
        while let a = it.next() {
            switch a {
            case "--json": o.json = true
            case "--status": o.status = true
            case "--today": o.today = true
            case "--titles": o.titles = true
            case "--from-now": o.fromNow = true
            case "--dash": o.dash = true
            case "--brief": o.brief = true
            case "--from-json":
                guard let f = it.next(), !f.isEmpty else { fail("--from-json takes a file\n\(usage)") }
                o.fromJSON = f
            case "--now":
                guard let v = it.next(), let d = parseNow(v) else { fail("--now takes an ISO 8601 time, e.g. 2026-09-23T18:08:00-04:00\n\(usage)") }
                o.now = d
            case "--crawl": o.crawlSince = int(it.next(), "--crawl")
            case "--items-since": o.itemsSince = it.next() ?? ""
            case "--list":
                guard let l = it.next(), !l.isEmpty else { fail("--list takes a list name\n\(usage)") }
                o.list = l
            default:
                if let n = Int(a), n >= 0, o.days == nil { o.days = n }
                else { fail("unknown argument: \(a)\n\(usage)") }
            }
        }
        return o
    }

    static func parseNow(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func statusLine(_ kind: Kind) -> Never {
        let label = kind == .calendar ? "Calendar" : "Reminders"
        // Same access check; on success print the connectors' "ok:" line.
        print("ok: reading \(label) (EventKit)")
        exit(0)
    }

    // MARK: Reminders

    static let remindersUsage = "usage: Moe --reminders [--crawl DAYS] [--today] [--titles] [--list NAME] [--json] [--status] [--items-since UNIXTIME]"

    static func reminders(_ args: ArraySlice<String>) async -> Never {
        let o = parse(args, usage: remindersUsage)
        let store = EKEventStore()
        await ensureAccess(.reminders, store: store)
        if o.status { statusLine(.reminders) }

        let cal = Calendar.current
        let now = Date()
        var calendars = store.calendars(for: .reminder)
        if let l = o.list {
            calendars = calendars.filter { $0.title == l }
            if calendars.isEmpty { fail("no Reminders list named \(l)", code: 1) }
        }
        // Stable order: list title, then the store's order within a list.
        calendars.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let all = await fetch(store.predicateForReminders(in: calendars), store: store)
        let cutoff = o.crawlSince.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let startOfDay = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

        var items: [ReminderItem] = []
        for c in calendars {
            for r in all where r.calendar.calendarIdentifier == c.calendarIdentifier {
                let due = r.dueDateComponents.flatMap { cal.date(from: $0) }
                let done = r.completionDate
                if r.isCompleted {
                    // pull: open only. crawl: also what was finished in the window.
                    guard let cutoff, let done, done > cutoff else { continue }
                }
                if o.today {
                    guard let due, due >= startOfDay, due < endOfDay else { continue }
                }
                items.append(ReminderItem(list: c.title, title: r.title ?? "", due: due,
                                          completed: r.isCompleted ? done : nil))
            }
        }
        if o.json { print(ConnectorText.remindersJSON(items)); exit(0) }
        let shape: ConnectorText.Shape = o.titles ? .titles : o.today ? .apple : (o.crawlSince != nil ? .crawl : .pull)
        print(ConnectorText.reminders(items, shape: shape), terminator: "")
        exit(0)
    }

    static func fetch(_ predicate: NSPredicate, store: EKEventStore) async -> [EKReminder] {
        await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    // MARK: Calendar

    static let calendarUsage = "usage: Moe --calendar [DAYS] [--crawl DAYS] [--from-now] [--dash] [--brief [--now ISO8601] [--from-json FILE]] [--json] [--status]"

    static func calendar(_ args: ArraySlice<String>) async -> Never {
        let o = parse(args, usage: calendarUsage)
        if o.brief, let file = o.fromJSON {
            guard let data = FileManager.default.contents(atPath: file),
                  let items = ConnectorText.parseEventsJSON(data) else { fail("cannot read events from \(file)") }
            print(CalendarTimeline.render(items, now: o.now ?? Date(), zone: .current), terminator: "")
            exit(0)
        }
        let store = EKEventStore()
        await ensureAccess(.calendar, store: store)
        if o.status { statusLine(.calendar) }

        if let since = o.itemsSince { items(store: store, since: since, now: o.now ?? Date()) }

        let cal = Calendar.current
        let now = o.now ?? Date()
        let midnight = cal.startOfDay(for: now)
        let from: Date, to: Date
        if let since = o.crawlSince {
            // crawl: the past window plus the next 30 days.
            from = cal.date(byAdding: .day, value: -since, to: midnight)!
            to = cal.date(byAdding: .day, value: 30, to: midnight)!
        } else {
            let days = o.days ?? (o.fromNow ? 7 : 3)
            from = o.fromNow ? now : midnight
            to = cal.date(byAdding: .day, value: days, to: from)!
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate)
            // AppleScript keyed on start only. The brief keys on overlap: a
            // party that began at 11:30 PM is still on at 12:03 AM.
            .filter { o.brief ? ($0.endDate > from && $0.startDate < to)
                              : ($0.startDate >= from && $0.startDate < to) }
            .sorted { $0.startDate < $1.startDate }
        let items = events.map { e in
            EventItem(start: e.startDate, end: e.endDate, title: e.title ?? "",
                      calendar: e.calendar?.title ?? "",
                      location: e.location,
                      attendees: (e.attendees ?? []).map { $0.name ?? $0.url.absoluteString },
                      // The field the agent went to Gmail and then to the
                      // screen looking for on 2026-09-03. It was here.
                      joinURL: MeetingLink.find(url: e.url?.absoluteString,
                                                location: e.location,
                                                notes: e.notes),
                      allDay: e.isAllDay)
        }
        if o.brief {
            print(CalendarTimeline.render(items, now: now, zone: .current), terminator: "")
            exit(0)
        }
        if o.json { print(ConnectorText.eventsJSON(items)); exit(0) }
        let shape: ConnectorText.Shape = o.dash ? .apple : (o.crawlSince != nil ? .crawl : .pull)
        print(ConnectorText.events(items, shape: shape), terminator: "")
        exit(0)
    }

    /// `--items-since`: see CalendarItems. The window is yesterday through
    /// ninety days out — an invitation for next quarter is still news today.
    static func items(store: EKEventStore, since: String, now: Date) -> Never {
        guard let t = Double(since) else {
            print(#"{"cursor": "\#(Int(now.timeIntervalSince1970))"}"#)
            exit(0)
        }
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -1, to: now)!
        let to = cal.date(byAdding: .day, value: 90, to: now)!
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        func person(_ p: EKParticipant) -> CalendarItems.Person {
            let email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return .init(name: p.name ?? "", email: email, isMe: p.isCurrentUser,
                         status: p.participantStatus == .pending ? "pending" : "")
        }
        let mapped = events.map { e in
            CalendarItems.Event(id: e.eventIdentifier ?? e.calendarItemIdentifier,
                                thread: e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier,
                                title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                                location: e.location, notes: e.notes,
                                organizer: e.organizer.map(person),
                                attendees: (e.attendees ?? []).map(person),
                                changed: e.lastModifiedDate ?? e.creationDate)
        }
        let out = CalendarItems.lines(mapped, since: t)
        for line in out.items { print(line) }
        print(#"{"cursor": "\#(out.cursor)"}"#)
        exit(0)
    }

    // MARK: Writes (tools/apple.sh reminders-add; new cal add)

    static func addReminder(_ args: ArraySlice<String>) async -> Never {
        let usage = "usage: Moe --add-reminder <title> [due ISO|\"YYYY-MM-DD HH:MM\"] [list]"
        var a = Array(args)
        guard let title = a.first, !title.isEmpty else { fail(usage) }
        a.removeFirst()
        // apple.sh passes "${3:-}" "${4:-}": an empty argument means "not given".
        let dueText = a.first.flatMap { $0.isEmpty ? nil : $0 }
        let listName = a.count > 1 && !a[1].isEmpty ? a[1] : nil
        var due: Date?
        if let dueText {
            guard let d = ConnectorText.parseDate(dueText) else { fail("cannot read due date: \(dueText)\n\(usage)") }
            due = d
        }
        let store = EKEventStore()
        await ensureAccess(.reminders, store: store)
        let r = EKReminder(eventStore: store)
        r.title = title
        if let listName {
            guard let c = store.calendars(for: .reminder).first(where: { $0.title == listName }) else {
                fail("no Reminders list named \(listName)", code: 1)
            }
            r.calendar = c
        } else {
            guard let c = store.defaultCalendarForNewReminders() else { fail("no default Reminders list", code: 1) }
            r.calendar = c
        }
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do { try store.save(r, commit: true) } catch { fail("could not add reminder: \(error.localizedDescription)", code: 1) }
        print("added: \(title)")
        exit(0)
    }

    static func addEvent(_ args: ArraySlice<String>) async -> Never {
        let usage = "usage: Moe --add-event <title> <start ISO|\"YYYY-MM-DD HH:MM\"> [end] [calendar]"
        let a = Array(args)
        guard a.count >= 2, !a[0].isEmpty else { fail(usage) }
        guard let start = ConnectorText.parseDate(a[1]) else { fail("cannot read start: \(a[1])\n\(usage)") }
        var end = start.addingTimeInterval(3600)
        if a.count > 2, !a[2].isEmpty {
            guard let e = ConnectorText.parseDate(a[2]) else { fail("cannot read end: \(a[2])\n\(usage)") }
            end = e
        }
        guard end > start else { fail("end must be after start") }
        let store = EKEventStore()
        await ensureAccess(.calendar, store: store)
        let ev = EKEvent(eventStore: store)
        ev.title = a[0]; ev.startDate = start; ev.endDate = end
        if a.count > 3, !a[3].isEmpty {
            guard let c = store.calendars(for: .event).first(where: { $0.title == a[3] }) else {
                fail("no calendar named \(a[3])", code: 1)
            }
            ev.calendar = c
        } else {
            guard let c = store.defaultCalendarForNewEvents else { fail("no default calendar", code: 1) }
            ev.calendar = c
        }
        do { try store.save(ev, span: .thisEvent, commit: true) } catch { fail("could not add event: \(error.localizedDescription)", code: 1) }
        print("added: \(a[0])")
        exit(0)
    }
}
