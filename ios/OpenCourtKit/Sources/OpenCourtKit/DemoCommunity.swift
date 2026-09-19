import Foundation

/// In-memory sign-in for demo mode and previews: any email with a 6+ character password works.
public actor DemoAuthService: AuthService {
    private var account: Account?
    private var continuations: [UUID: AsyncStream<Account?>.Continuation] = [:]

    public init(signedIn: Bool = false) {
        account = signedIn ? Account(id: DemoCommunityRepository.demoUserID, email: "you@example.com") : nil
    }

    public func currentAccount() async -> Account? { account }

    public nonisolated func accountChanges() -> AsyncStream<Account?> {
        AsyncStream { continuation in
            let key = UUID()
            Task { await self.add(key, continuation) }
            continuation.onTermination = { _ in Task { await self.remove(key) } }
        }
    }

    private func add(_ key: UUID, _ c: AsyncStream<Account?>.Continuation) {
        continuations[key] = c
        c.yield(account)
    }

    private func remove(_ key: UUID) { continuations[key] = nil }

    private func publish() {
        for c in continuations.values { c.yield(account) }
    }

    public func signIn(email: String, password: String) async throws -> Account {
        guard email.contains("@") else { throw CommunityError.server("enter a valid email address") }
        guard password.count >= 6 else { throw CommunityError.server("wrong email or password") }
        let a = Account(id: DemoCommunityRepository.demoUserID, email: email)
        account = a
        publish()
        return a
    }

    public func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult {
        guard password.count >= 6 else {
            throw CommunityError.server("use at least 6 characters for the password")
        }
        return .signedIn(try await signIn(email: email, password: password))
    }

    public func signOut() async throws {
        account = nil
        publish()
    }

    public func sendPasswordReset(email: String) async throws {}

    public func signInWithGoogle() async throws -> Account {
        try await signIn(email: "you@gmail.com", password: "google")
    }

    public func handleRedirect(_ url: URL) async throws -> AuthRedirect {
        let a = Account(id: DemoCommunityRepository.demoUserID, email: "you@example.com")
        account = a
        publish()
        return url.path.contains("reset") ? .choosePassword(a) : .signedIn(a)
    }

    public func updatePassword(_ password: String) async throws {
        guard password.count >= 6 else {
            throw CommunityError.server("use at least 6 characters for the password")
        }
    }
}

/// Sample events and profiles for demo mode, stored in memory.
public actor DemoCommunityRepository: CommunityRepository {
    public static let demoUserID = UUID(uuidString: "00000000-0000-0000-0000-00000000D3E0")!
    private static let organizerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private var events: [CourtEvent]
    private var mine: Set<UUID> = []
    private var profiles: [UUID: PlayerProfile]

    public init(now: Date = Date()) {
        let day: TimeInterval = 86_400
        func at(_ days: Double, _ hour: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/Chicago")!
            let start = cal.startOfDay(for: now.addingTimeInterval(days * day))
            return cal.date(byAdding: .hour, value: hour, to: start)!
        }
        let org = Self.organizerID
        events = [
            CourtEvent(organizerID: org, kind: .openPlay, title: "Tuesday Night Open Play",
                       description: "Drop in, put your paddle in the stack, and play. All levels welcome; "
                           + "games to 11, rotate after each game.",
                       siteID: "mike-rylko", startsAt: at(1, 18), endsAt: at(1, 21), format: .any,
                       siteName: "Mike Rylko Community Park", organizerName: "BG Pickleball Club",
                       registeredCount: 14),
            CourtEvent(organizerID: org, kind: .tournament, title: "Fall Classic Doubles",
                       description: "Round robin pools into single-elimination brackets. Bring a partner; "
                           + "courts reserved with a park district permit.",
                       siteID: "mike-rylko", startsAt: at(9, 8), endsAt: at(9, 15), format: .doubles,
                       skillMin: 3.0, skillMax: 4.0, capacity: 32, feeCents: 2500,
                       courtsReserved: true, contact: "fallclassic@example.com",
                       siteName: "Mike Rylko Community Park", organizerName: "BG Pickleball Club",
                       registeredCount: 26),
            CourtEvent(organizerID: org, kind: .clinic, title: "Beginner Clinic: Dinks & Resets",
                       description: "An hour on the soft game, then supervised play. Paddles available to borrow.",
                       siteID: "rick-drazner", startsAt: at(4, 10), endsAt: at(4, 11), format: .any,
                       skillMax: 3.0, capacity: 8, feeCents: 1000, courtsReserved: true,
                       siteName: "Rick Drazner Park", organizerName: "Coach Dana", registeredCount: 8),
            CourtEvent(organizerID: org, kind: .social, title: "Glow Pickleball Night",
                       description: "LED balls, music, snacks. Mixed doubles, partners rotate every game.",
                       siteID: "mike-rylko", startsAt: at(12, 19), endsAt: at(12, 22), format: .mixed,
                       capacity: 24, feeCents: 500, siteName: "Mike Rylko Community Park",
                       organizerName: "BG Pickleball Club", registeredCount: 9),
        ]
        profiles = [Self.demoUserID: PlayerProfile(id: Self.demoUserID, displayName: "You")]
    }

    public func upcomingEvents(from: Date) async throws -> [CourtEvent] {
        events.filter { ($0.endsAt ?? $0.startsAt) >= from }.sorted { $0.startsAt < $1.startsAt }
    }

    public func createEvent(_ e: NewEvent) async throws {
        let siteNames = ["rick-drazner": "Rick Drazner Park", "mike-rylko": "Mike Rylko Community Park"]
        events.append(CourtEvent(
            organizerID: Self.demoUserID, kind: e.kind, title: e.title, description: e.description,
            siteID: e.siteID, locationName: e.locationName, startsAt: e.startsAt, endsAt: e.endsAt,
            format: e.format, skillMin: e.skillMin, skillMax: e.skillMax, capacity: e.capacity,
            feeCents: e.feeCents, courtsReserved: e.courtsReserved, contact: e.contact,
            siteName: e.siteID.flatMap { siteNames[$0] },
            organizerName: profiles[Self.demoUserID]?.displayName ?? "You"))
    }

    public func cancelEvent(id: UUID) async throws {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].status = "cancelled"
    }

    public func register(eventID: UUID) async throws {
        guard let i = events.firstIndex(where: { $0.id == eventID }) else {
            throw CommunityError.server("event not found")
        }
        if mine.contains(eventID) { return }
        if events[i].isCancelled { throw CommunityError.server("this event was cancelled") }
        if events[i].isFull { throw CommunityError.server("this event is full") }
        mine.insert(eventID)
        events[i].registeredCount += 1
    }

    public func unregister(eventID: UUID) async throws {
        guard mine.remove(eventID) != nil,
              let i = events.firstIndex(where: { $0.id == eventID }) else { return }
        events[i].registeredCount -= 1
    }

    public func myRegistrations() async throws -> Set<UUID> { mine }

    public func profile(id: UUID) async throws -> PlayerProfile? { profiles[id] }

    public func saveProfile(_ profile: PlayerProfile) async throws { profiles[profile.id] = profile }

    public func busyHours(siteID: String) async throws -> [BusyHour] {
        // A plausible weekly shape: quiet mornings, busy after work and weekend mornings.
        var rows: [BusyHour] = []
        for weekday in 1...7 {
            for hour in 6...22 {
                let weekend = weekday >= 6
                let evening = exp(-pow(Double(hour) - 18.5, 2) / 4) * 7
                let morning = exp(-pow(Double(hour) - 9.5, 2) / 3) * (weekend ? 8 : 2.5)
                rows.append(BusyHour(siteID: siteID, weekday: weekday, hour: hour,
                                     avgWaiting: ((evening + morning) * 10).rounded() / 10,
                                     courtsInUse: min(1, (evening + morning) / 6 + 0.2), samples: 20))
            }
        }
        return rows
    }
}
