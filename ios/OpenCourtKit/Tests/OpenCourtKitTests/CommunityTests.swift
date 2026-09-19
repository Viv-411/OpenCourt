import Foundation
import Testing
@testable import OpenCourtKit

// The exact shape PostgREST returns for backend `event_listing` rows.
let eventJSON = """
[{"id":"6f1c2b0e-8a5d-4a3e-9d2f-1b2c3d4e5f60","organizer_id":"00000000-0000-0000-0000-0000000000a1",
  "kind":"tournament","title":"Fall Classic","description":"Pools then brackets.",
  "site_id":"mike-rylko","location_name":null,"starts_at":"2026-10-03T13:00:00+00:00",
  "ends_at":"2026-10-03T20:00:00+00:00","format":"doubles","skill_min":3.0,"skill_max":4.0,
  "capacity":32,"fee_cents":2500,"courts_reserved":true,"contact":"a@b.c","status":"scheduled",
  "created_at":"2026-09-19T12:00:00.123456+00:00","site_name":"Mike Rylko Community Park",
  "organizer_name":"BG Pickleball Club","registered_count":26}]
"""

@Suite struct EventModels {
    @Test func decodesEventListing() throws {
        let events = try OpenCourtJSON.decoder().decode([CourtEvent].self, from: Data(eventJSON.utf8))
        let e = try #require(events.first)
        #expect(e.kind == .tournament)
        #expect(e.place == "Mike Rylko Community Park")
        #expect(e.spotsText == "6 spots left")
        #expect(e.feeText == "$25")
        #expect(e.skillText == "3.0–4.0")
        #expect(e.courtsReserved)
    }

    @Test func labels() {
        var e = CourtEvent(organizerID: UUID(), kind: .openPlay, title: "x", startsAt: .now)
        #expect(e.feeText == "Free" && e.skillText == "All levels" && e.spotsText == "0 going")
        e.feeCents = 1250
        e.skillMin = 3.5
        e.capacity = 4
        e.registeredCount = 4
        #expect(e.feeText == "$12.50" && e.skillText == "3.5+" && e.spotsText == "Full" && e.isFull)
        e.skillMin = nil
        e.skillMax = 3
        #expect(e.skillText == "Up to 3.0")
    }

    @Test func newEventValidation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var e = NewEvent(startsAt: now.addingTimeInterval(-60))
        let problems = e.problems(now: now)
        #expect(problems.count == 3)  // title, place, time
        e.title = "Tuesday open play"
        e.siteID = "rick-drazner"
        e.startsAt = now.addingTimeInterval(3600)
        #expect(e.problems(now: now).isEmpty)
        e.endsAt = now
        e.skillMin = 4
        e.skillMax = 3
        #expect(e.problems(now: now).count == 2)
    }

    @Test func newEventEncodesSnakeCaseAndISODates() throws {
        var e = NewEvent(startsAt: Date(timeIntervalSince1970: 1_790_000_000))
        e.title = "  Social night "
        e.siteID = "mike-rylko"
        e.courtsReserved = true
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as! [String: Any]
        #expect(json["title"] as? String == "Social night")
        #expect(json["site_id"] as? String == "mike-rylko")
        #expect(json["courts_reserved"] as? Bool == true)
        #expect((json["starts_at"] as? String)?.hasPrefix("2026-") == true)
        #expect(json["organizer_id"] == nil)  // the server sets it from the session
    }

    @Test func profileInitials() {
        #expect(PlayerProfile(id: UUID(), displayName: "sam lee").initials == "SL")
        #expect(PlayerProfile(id: UUID(), displayName: "Jo").initials == "J")
    }

    @Test func busyTimesForToday() {
        let rows = [BusyHour(siteID: "s", weekday: 2, hour: 18, avgWaiting: 5, samples: 10),
                    BusyHour(siteID: "s", weekday: 2, hour: 7, avgWaiting: 1, samples: 10),
                    BusyHour(siteID: "s", weekday: 2, hour: 23, avgWaiting: 1, samples: 10),
                    BusyHour(siteID: "s", weekday: 2, hour: 12, avgWaiting: 9, samples: 1),
                    BusyHour(siteID: "s", weekday: 3, hour: 18, avgWaiting: 9, samples: 10)]
        #expect(BusyTimes.day(rows, weekday: 2).map(\.hour) == [7, 18])
        let tuesday = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 (a Monday UTC)
        let chicago = TimeZone(identifier: "America/Chicago")!
        #expect((1...7).contains(BusyTimes.isoWeekday(tuesday, in: chicago)))
    }
}

@Suite @MainActor struct CommunityFlows {
    @Test func signInThenSignUpForEvents() async throws {
        let community = DemoCommunityRepository()
        let session = SessionStore(auth: DemoAuthService(), community: community)
        let events = EventsStore(community: community)
        #expect(!session.isSignedIn)
        #expect(await session.signIn(email: "a@b.com", password: "123") == false)
        #expect(session.errorMessage == "Wrong email or password")
        #expect(await session.signIn(email: "a@b.com", password: "123456"))
        #expect(session.isSignedIn && session.profile != nil)

        await events.load(signedIn: true)
        let open = try #require(events.events.first { !$0.isFull })
        await events.toggleGoing(open)
        #expect(events.going.contains(open.id))
        #expect(events.events.first { $0.id == open.id }?.registeredCount == open.registeredCount + 1)
        await events.toggleGoing(open)
        #expect(!events.going.contains(open.id))
    }

    @Test func fullEventsRefuse() async throws {
        let community = DemoCommunityRepository()
        let events = EventsStore(community: community)
        await events.load(signedIn: true)
        let full = try #require(events.events.first { $0.isFull })
        await events.toggleGoing(full)
        #expect(events.errorMessage == "This event is full")
        #expect(!events.going.contains(full.id))
    }

    @Test func postAndCancelAnEvent() async throws {
        let community = DemoCommunityRepository()
        let events = EventsStore(community: community)
        var e = NewEvent(startsAt: Date().addingTimeInterval(86_400))
        e.title = "Saturday round robin"
        e.siteID = "rick-drazner"
        #expect(await events.create(e))
        let mine = try #require(events.events.first { $0.title == "Saturday round robin" })
        #expect(mine.place == "Rick Drazner Park")
        await events.cancel(mine)
        #expect(events.events.first { $0.id == mine.id }?.isCancelled == true)
        events.kindFilter = .tournament
        #expect(events.visible.allSatisfy { $0.kind == .tournament })
    }

    @Test func favoritesPersist() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let a = FavoritesStore(defaults: defaults)
        a.toggle("rick-drazner")
        #expect(FavoritesStore(defaults: defaults).contains("rick-drazner"))
        a.toggle("rick-drazner")
        #expect(!FavoritesStore(defaults: defaults).contains("rick-drazner"))
    }
}
