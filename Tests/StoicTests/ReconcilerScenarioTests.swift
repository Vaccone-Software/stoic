@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// design/30's ideal scenario, as a test: a volunteering service whose
/// calendar attendees and map index follow the commitments and events, under
/// one supervisor, through a deploy that points the commitments query at the
/// wrong table.
@Suite("Reconciler: Kindora's derived systems")
struct ReconcilerScenarioTests {
    struct Listing: Hashable, Sendable {
        var title: String
        var attendees: Set<String>
    }

    /// The service's own database: events and who is committed to each.
    actor Database {
        var events: [String: (name: String, charity: String)] = [:]
        var commitments: [String: Set<String>] = [:]
        /// A deploy that points the commitments query at an empty table.
        var wrongTable = false

        func publish(_ id: String, name: String, charity: String) { events[id] = (name, charity) }
        func commit(_ email: String, to event: String) { commitments[event, default: []].insert(email) }
        func misconfigure(_ broken: Bool) { wrongTable = broken }

        func desiredListings(_ scope: ReconcileScope<String>) -> [String: Listing] {
            guard !wrongTable else { return [:] }
            var listings: [String: Listing] = [:]
            for (id, event) in events where scope.contains(id) {
                listings[id] = Listing(title: "\(event.name) - \(event.charity)", attendees: commitments[id] ?? [])
            }
            return listings
        }
    }

    enum Backends {
        static let database = Backend.remote("kindora.convex")
        static let calendar = Backend.remote("kindora.cronofy", capacity: 4)
    }

    /// The calendar's attendee lists follow the commitments; nothing else writes one.
    struct CalendarAttendees: Reconciliation {
        static let name = "kindora.calendar-attendees"
        static let readsTruth = Backends.database.readOnly("calendar.desired")
        static let readsDerived = Backends.calendar.readOnly("events.list")
        static let corrects = Backends.calendar.idempotent("events.put")

        let db: Database
        let calendar: SimulatedSide<String, Listing>

        func desired(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Listing] {
            await db.desiredListings(scope)
        }
        func actual(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Listing] {
            try await calendar.read(scope)
        }
        func correct(_ correction: Correction<String, Listing, Listing>, attempt: Attempt) async throws {
            switch correction {
            case .create(let id, let listing), .update(let id, let listing, was: _): try await calendar.write(id, listing)
            case .remove(let id, was: _): try await calendar.write(id, nil)
            }
        }
    }

    /// The health page: one row per reconciler.
    static func health<Key>(_ status: ReconcilerStatus<Key>, at now: Moment) -> String {
        if status.isOverdue(at: now) { return "no full pass since \(status.lastFullPass?.description ?? "start")" }
        switch status.phase {
        case .converged: return "in agreement"
        case .converging(let differences): return "\(differences) being corrected"
        case .stuck(let differences): return "\(status.stuck.count) stuck of \(differences)"
        case .held(let differences): return "removals wait for a person (\(differences) differences)"
        case .unreadable(let side): return "cannot read the \(side)"
        case .starting: return "first pass running"
        }
    }

    @Test func theCalendarFollowsTheCommitmentsAndSurvivesAnEmptyTruth() async throws {
        _ = try await simulate(seed: 3, faults: .none, schedule: .uniform) { context in
            let clock = context.clock
            let db = Database()
            for index in 0..<12 {
                await db.publish("event-\(index)", name: "Beach clean \(index)", charity: "Surfers Against Sewage")
                await db.commit("organiser-\(index)@kindora.example", to: "event-\(index)")
            }
            let calendar = SimulatedSide<String, Listing>(label: "cronofy")
            let attendees = Reconciler(CalendarAttendees(db: db, calendar: calendar))
            let derived = Supervisor(label: "kindora.derived") {
                Child("calendar-attendees") { _ in try await attendees.run() }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await derived.run() }
                await attendees.progress.wait(for: .passes, count: 2)   // the start, and its verification
                #expect(Self.health(attendees.status, at: Moment.now) == "in agreement")
                #expect(await calendar.entries.count == 12)

                // A commitment is written; the calendar follows within a second.
                let written = clock.now
                let passes = attendees.progress.passes
                await db.commit("ana@kindora.example", to: "event-3")
                attendees.changed("event-3")
                await attendees.progress.wait(for: .passes, count: passes + 1)
                #expect(await calendar.entries["event-3"]?.attendees.contains("ana@kindora.example") == true)
                #expect(written.duration(to: clock.now) == .seconds(1), "the trigger makes it prompt")

                // A missing trigger: the next full pass finds it.
                await db.commit("ben@kindora.example", to: "event-5")
                while await calendar.entries["event-5"]?.attendees.contains("ben@kindora.example") != true {
                    try await Ambient.sleep(for: .seconds(10))
                }
                #expect(written.duration(to: clock.now) <= .seconds(900), "within fifteen minutes")

                // The deploy: the commitments query reads the wrong table.
                await db.misconfigure(true)
                attendees.requestFullPass()
                while attendees.status.hold == nil { try await Ambient.sleep(for: .seconds(1)) }
                #expect(await calendar.entries.count == 12, "the calendar keeps every attendee list")
                #expect(Self.health(attendees.status, at: Moment.now) == "removals wait for a person (12 differences)")
                let hold = try #require(attendees.status.hold)
                #expect(hold.truthWasEmpty)

                // Someone is told; the deploy is fixed; the hold is released.
                await db.misconfigure(false)
                attendees.requestFullPass()
                while attendees.status.hold != nil { try await Ambient.sleep(for: .seconds(1)) }
                #expect(context.events.count("reconciler.hold_released") == 1)

                // A test calendar retired on purpose: the person confirms.
                for index in 0..<12 { await db.retire("event-\(index)") }
                attendees.requestFullPass()
                while attendees.status.hold == nil { try await Ambient.sleep(for: .seconds(1)) }
                let retired = try #require(attendees.status.hold)
                try attendees.confirm(retired, by: ana, because: "the test calendar was retired on purpose")
                while await !calendar.entries.isEmpty { try await Ambient.sleep(for: .seconds(1)) }
                while attendees.status.phase != .converged { try await Ambient.sleep(for: .seconds(1)) }
                #expect(Self.health(attendees.status, at: Moment.now) == "in agreement")
                group.cancelAll()
            }
        }
    }
}

extension ReconcilerScenarioTests.Database {
    func retire(_ id: String) {
        events[id] = nil
        commitments[id] = nil
    }
}
