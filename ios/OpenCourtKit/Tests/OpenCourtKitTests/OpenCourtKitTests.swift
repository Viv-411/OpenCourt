import Foundation
import Testing
@testable import OpenCourtKit

// Shapes exactly as PostgREST returns them for the backend schema.
let siteJSON = """
[{"id":"demo-site","name":"Demo Park","address":null,"latitude":41.8781,"longitude":-87.6298,
  "timezone":"America/Chicago","court_count":4,"health":"ok","queue_count":6,
  "queue_waiting":true,"wait_seconds":900,"next_free_seconds":120,"groups_ahead":2,
  "updated_at":"2026-09-16T20:01:02.123456+00:00","age_seconds":3,"is_stale":false},
 {"id":"new-site","name":"New","address":null,"latitude":null,"longitude":null,
  "timezone":"America/Chicago","court_count":2,"health":null,"queue_count":null,
  "queue_waiting":null,"wait_seconds":null,"next_free_seconds":null,"groups_ahead":null,
  "updated_at":null,"age_seconds":null,"is_stale":true}]
"""

let courtJSON = """
[{"site_id":"demo-site","number":1,"state":"due","light":"solid","occupancy":4,
  "clock_seconds":1250,"seconds_remaining":0,"on_court_seconds":1400,
  "updated_at":"2026-09-16T20:01:00+00:00"},
 {"site_id":"demo-site","number":2,"state":"something_new","light":"strobe","occupancy":3.5,
  "clock_seconds":null,"seconds_remaining":null,"on_court_seconds":null,
  "updated_at":"2026-09-16T20:01:00.5+00:00"}]
"""

@Suite struct Decoding {
    @Test func sitesDecode() throws {
        let sites = try OpenCourtJSON.decoder().decode([Site].self, from: Data(siteJSON.utf8))
        #expect(sites.count == 2)
        #expect(sites[0].courtCount == 4)
        #expect(sites[0].health == .ok)
        #expect(sites[0].peopleWaiting == 6)
        #expect(sites[1].updatedAt == nil)
        #expect(sites[1].health == nil)
    }

    @Test func courtsDecodeAndTolerateUnknownValues() throws {
        let courts = try OpenCourtJSON.decoder().decode([CourtStatus].self, from: Data(courtJSON.utf8))
        #expect(courts[0].state == .due)
        #expect(courts[0].light == .solid)
        #expect(courts[1].state == .unknown)
        #expect(courts[1].light == .off)
        #expect(courts[1].players == 4)
    }

    @Test(arguments: [
        "2026-09-16T20:01:02.123456+00:00",
        "2026-09-16T20:01:02+00:00",
        "2026-09-16 20:01:02.1+00",
        "2026-09-16T20:01:02Z",
    ])
    func timestamps(raw: String) throws {
        let d = try #require(OpenCourtJSON.parseTimestamp(raw))
        let base = OpenCourtJSON.parseTimestamp("2026-09-16T20:01:02Z")!
        #expect(abs(d.timeIntervalSince(base)) < 0.2)
    }

    @Test func realSensorPayloadStatesAreKnown() throws {
        // backend/tests/fixtures/payload_v1.json is produced by the sensor.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("backend/tests/fixtures/payload_v1.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for court in json["courts"] as! [[String: Any]] {
            let raw = court["state"] as! String
            #expect(CourtState(rawValue: raw) != nil, "app doesn't know state \(raw)")
        }
    }
}

@Suite struct Freshness_ {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func site(age: TimeInterval?, health: SensorHealth = .ok) -> Site {
        Site(id: "s", name: "S", courtCount: 2, health: health, queueCount: 5,
             queueWaiting: true, waitSeconds: 700, nextFreeSeconds: 60, groupsAhead: 2,
             updatedAt: age.map { now.addingTimeInterval(-$0) })
    }

    @Test func live() { #expect(site(age: 10).freshness(at: now) == .live) }
    @Test func stale() { #expect(site(age: 61).freshness(at: now) == .stale(age: 61)) }
    @Test func never() { #expect(site(age: nil).freshness(at: now) == .neverReported) }
    @Test func limited() {
        #expect(site(age: 5, health: .warmingUp).freshness(at: now) == .limited)
        #expect(site(age: 5, health: .degraded).freshness(at: now) == .limited)
    }

    @Test func headlines() {
        #expect(site(age: 10).headline(at: now) == "5 waiting · about 10 min")
        #expect(site(age: 600).headline(at: now) == "Sensor offline")
        var open = site(age: 1)
        open.queueCount = 0
        open.nextFreeSeconds = 0
        #expect(open.headline(at: now) == "Court open now")
    }
}

/// The big number on the Courts list and a park's page, and the plain sentences around it.
@Suite struct BigWait {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func site(wait: Int? = 700, queue: Double = 5, ahead: Int? = 2, nextFree: Int? = 240,
              age: TimeInterval? = 5, health: SensorHealth = .ok) -> Site {
        Site(id: "s", name: "S", courtCount: 4, health: health, queueCount: queue,
             queueWaiting: queue > 0, waitSeconds: wait, nextFreeSeconds: nextFree,
             groupsAhead: ahead, updatedAt: age.map { now.addingTimeInterval(-$0) })
    }

    @Test func waitIsRoundedMinutes() {
        #expect(site(wait: 700).waitDisplay(at: now)
                == WaitDisplay(value: "10", unit: "min wait", tone: .waiting))
        #expect(site(wait: 200).waitDisplay(at: now).value == "5")    // never "0" or "3"
        #expect(site(wait: 4200).waitDisplay(at: now).value == "70")  // minutes, not "1:10"
    }

    @Test func noWaitSaysNow() {
        #expect(site(wait: 30).waitDisplay(at: now)
                == WaitDisplay(value: "Now", unit: "no wait", tone: .open))
    }

    @Test func untrustedDataShowsNoNumber() {
        #expect(site(age: nil).waitDisplay(at: now).unit == "no data yet")
        #expect(site(age: 600).waitDisplay(at: now).unit == "offline")
        #expect(site(health: .warmingUp).waitDisplay(at: now).unit == "warming up")
        #expect(site(wait: nil).waitDisplay(at: now).tone == .unknown)
        #expect(site(age: 600).waitDisplay(at: now).value == "–")
    }

    @Test func spokenWait() {
        #expect(site().waitDisplay(at: now).spoken == "Wait about 10 minutes")
        #expect(site(age: 600).waitDisplay(at: now).spoken == "Wait unknown, offline")
    }

    @Test func statusLines() {
        #expect(site().statusLine(at: now) == "5 in line")
        #expect(site(queue: 1).statusLine(at: now) == "1 person in line")
        #expect(site(queue: 0, nextFree: 0).statusLine(at: now) == "Court open now")
        #expect(site(queue: 0, nextFree: 300).statusLine(at: now) == "No line")
        #expect(site(age: 7200).statusLine(at: now) == "Offline · last update 2 hr ago")
    }

    @Test func courtSummaryCountsByState() {
        let t = now
        func court(_ n: Int, _ state: CourtState) -> CourtStatus {
            CourtStatus(siteID: "s", number: n, state: state, occupancy: 4, updatedAt: t)
        }
        let snap = SiteSnapshot(site: site(), courts: [
            court(1, .active), court(2, .due), court(3, .empty), court(4, .rotating),
        ])
        #expect(snap.courtSummary == "2 in play · 1 open · 1 changing")
    }

    @Test func detailsSaySeparateThingsPlainly() {
        #expect(site().waitDetails(at: now) == [
            "5 people in line · 2 groups ahead of you",
            "Next court frees up in about 4 min",
        ])
        // The old "Open court: line's turn" becomes a sentence.
        #expect(site(nextFree: 0).waitDetails(at: now).last
                == "A court is open. The people in line go first.")
        #expect(site(queue: 0, ahead: 0, nextFree: 0).waitDetails(at: now)
                == ["A court is free right now."])
        #expect(site(age: 600).waitDetails(at: now).isEmpty)
    }
}

@Suite struct Formatting {
    @Test func waits() {
        #expect(WaitFormat.wait(nil) == "wait unknown")
        #expect(WaitFormat.wait(30) == "no wait")
        #expect(WaitFormat.wait(400) == "about 5 min")
        #expect(WaitFormat.wait(1000) == "about 15 min")
        #expect(WaitFormat.wait(4200) == "about 1 hr 10 min")
        #expect(WaitFormat.wait(3600) == "about 1 hr")
    }

    @Test func clocks() {
        #expect(WaitFormat.clock(0) == "0:00")
        #expect(WaitFormat.clock(1265) == "21:05")
        #expect(WaitFormat.clock(-5) == "0:00")
    }

    @Test func ages() {
        #expect(WaitFormat.age(2) == "just now")
        #expect(WaitFormat.age(42) == "42 s ago")
        #expect(WaitFormat.age(600) == "10 min ago")
    }

    @Test func stateWordingIsFactual() {
        for state in CourtState.allCases {
            for t in [state.title.lowercased(), state.shortTitle.lowercased()] {
                for word in ["cheat", "violat", "expired", "hog", "kick"] {
                    #expect(!t.contains(word), "\(state) wording '\(t)' is accusatory")
                }
            }
        }
        #expect(CourtState.due.title == "Time up")
        #expect(CourtState.due.shortTitle == "Time up")
    }
}

@Suite struct Clocks {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func extrapolatesFromLastUpdate() {
        let c = CourtStatus(siteID: "s", number: 1, state: .active, occupancy: 4,
                            clockSeconds: 600, secondsRemaining: 600, updatedAt: t0)
        #expect(c.clock(at: t0.addingTimeInterval(30)) == 630)
        #expect(c.remaining(at: t0.addingTimeInterval(30)) == 570)
        #expect(c.remaining(at: t0.addingTimeInterval(9999)) == 0)
    }

    @Test func noClockWhenNobodyWaiting() {
        let c = CourtStatus(siteID: "s", number: 1, state: .idle, occupancy: 4,
                            clockSeconds: nil, onCourtSeconds: 900, updatedAt: t0)
        #expect(c.clock(at: t0) == nil)
    }
}

@Suite struct Demo {
    @Test func demoSitesLoad() async throws {
        let repo = DemoRepository(start: Date(timeIntervalSince1970: 0),
                                  clock: { Date(timeIntervalSince1970: 1800) })
        let sites = try await repo.sites()
        #expect(sites.map(\.id) == DemoRepository.siteIDs)
        let snap = try await repo.snapshot(siteID: "mike-rylko")
        #expect(snap.courts.count == 8)
        #expect(snap.courts.map(\.number) == Array(1...8))
        #expect(snap.freshness(at: Date(timeIntervalSince1970: 1800)) == .live)
        let offline = try await repo.snapshot(siteID: "demo-offline")
        if case .stale = offline.freshness(at: Date(timeIntervalSince1970: 1800)) {} else {
            Issue.record("offline demo site should be stale")
        }
    }

    @Test func demoEventuallyShowsASecondGame() async throws {
        var sawDue = false
        for minute in stride(from: 0, to: 60, by: 1) {
            let repo = DemoRepository(start: Date(timeIntervalSince1970: 0),
                                      clock: { Date(timeIntervalSince1970: Double(minute * 60)) })
            let snap = try await repo.snapshot(siteID: "mike-rylko")
            sawDue = sawDue || !snap.courtsInSecondGame.isEmpty
        }
        #expect(sawDue)
    }

    @Test func unknownSite() async {
        await #expect(throws: RepositoryError.siteNotFound("nope")) {
            try await DemoRepository().snapshot(siteID: "nope")
        }
    }
}

@Suite @MainActor struct Store {
    @Test func loadsAndFollows() async throws {
        let store = SiteStore(repository: DemoRepository(tick: .milliseconds(20)),
                              isDemo: true, pollInterval: .seconds(60))
        await store.loadSites()
        #expect(store.sites.count == 3)
        #expect(store.errorMessage == nil)
        store.follow(siteID: "rick-drazner")
        for _ in 0..<100 where store.snapshot == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.snapshot?.site.id == "rick-drazner")
        #expect(store.snapshot?.openCourts.count == 1)
        store.stop()
    }

    @Test func reportsErrors() async {
        let store = SiteStore(repository: DemoRepository())
        await store.refresh(siteID: "missing")
        #expect(store.errorMessage == "Couldn't find site missing.")
    }
}
