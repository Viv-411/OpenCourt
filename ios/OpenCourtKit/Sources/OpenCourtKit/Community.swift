import Foundation

// Community features: events (tournaments, open play, clinics...), player profiles and busy
// times. Mirrors supabase/migrations/20260919000000_community.sql.

public enum EventKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case tournament
    case openPlay = "open_play"
    case clinic
    case league
    case social

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tournament: "Tournament"
        case .openPlay: "Open play"
        case .clinic: "Clinic"
        case .league: "League"
        case .social: "Social"
        }
    }

    public var symbol: String {
        switch self {
        case .tournament: "trophy.fill"
        case .openPlay: "figure.pickleball"
        case .clinic: "graduationcap.fill"
        case .league: "list.number"
        case .social: "party.popper.fill"
        }
    }
}

public enum PlayFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case doubles, singles, mixed, any
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .doubles: "Doubles"
        case .singles: "Singles"
        case .mixed: "Mixed doubles"
        case .any: "Any format"
        }
    }
}

/// One row of the backend `event_listing` view.
public struct CourtEvent: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var organizerID: UUID
    public var kind: EventKind
    public var title: String
    public var description: String
    public var siteID: String?
    public var locationName: String?
    public var startsAt: Date
    public var endsAt: Date?
    public var format: PlayFormat
    public var skillMin: Double?
    public var skillMax: Double?
    public var capacity: Int?
    public var feeCents: Int
    public var courtsReserved: Bool
    public var contact: String?
    public var status: String
    public var siteName: String?
    public var organizerName: String?
    public var registeredCount: Int

    public init(
        id: UUID = UUID(), organizerID: UUID, kind: EventKind, title: String,
        description: String = "", siteID: String? = nil, locationName: String? = nil,
        startsAt: Date, endsAt: Date? = nil, format: PlayFormat = .doubles,
        skillMin: Double? = nil, skillMax: Double? = nil, capacity: Int? = nil,
        feeCents: Int = 0, courtsReserved: Bool = false, contact: String? = nil,
        status: String = "scheduled", siteName: String? = nil, organizerName: String? = nil,
        registeredCount: Int = 0
    ) {
        self.id = id
        self.organizerID = organizerID
        self.kind = kind
        self.title = title
        self.description = description
        self.siteID = siteID
        self.locationName = locationName
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.format = format
        self.skillMin = skillMin
        self.skillMax = skillMax
        self.capacity = capacity
        self.feeCents = feeCents
        self.courtsReserved = courtsReserved
        self.contact = contact
        self.status = status
        self.siteName = siteName
        self.organizerName = organizerName
        self.registeredCount = registeredCount
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, description, format, capacity, contact, status
        case organizerID = "organizer_id"
        case siteID = "site_id"
        case locationName = "location_name"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case skillMin = "skill_min"
        case skillMax = "skill_max"
        case feeCents = "fee_cents"
        case courtsReserved = "courts_reserved"
        case siteName = "site_name"
        case organizerName = "organizer_name"
        case registeredCount = "registered_count"
    }

    public var place: String { siteName ?? locationName ?? "Location to be announced" }
    public var isCancelled: Bool { status == "cancelled" }
    public var spotsLeft: Int? { capacity.map { max(0, $0 - registeredCount) } }
    public var isFull: Bool { spotsLeft == 0 }
    public func hasStarted(at now: Date) -> Bool { startsAt <= now }

    public var feeText: String {
        guard feeCents > 0 else { return "Free" }
        let dollars = Double(feeCents) / 100
        return feeCents % 100 == 0 ? "$\(feeCents / 100)" : String(format: "$%.2f", dollars)
    }

    /// "All levels", "3.0+", "Up to 3.5", "3.0–4.0".
    public var skillText: String {
        switch (skillMin, skillMax) {
        case (nil, nil): "All levels"
        case (let lo?, nil): String(format: "%.1f+", lo)
        case (nil, let hi?): String(format: "Up to %.1f", hi)
        case (let lo?, let hi?): String(format: "%.1f–%.1f", lo, hi)
        }
    }

    public var spotsText: String {
        guard let spotsLeft else { return "\(registeredCount) going" }
        if spotsLeft == 0 { return "Full" }
        return spotsLeft == 1 ? "1 spot left" : "\(spotsLeft) spots left"
    }
}

/// What the app sends to create an event (the server fills in id, organizer and counts).
public struct NewEvent: Encodable, Sendable, Equatable {
    public var kind: EventKind = .openPlay
    public var title: String = ""
    public var description: String = ""
    public var siteID: String?
    public var locationName: String?
    public var startsAt: Date
    public var endsAt: Date?
    public var format: PlayFormat = .doubles
    public var skillMin: Double?
    public var skillMax: Double?
    public var capacity: Int?
    public var feeCents: Int = 0
    public var courtsReserved: Bool = false
    public var contact: String?

    public init(startsAt: Date) { self.startsAt = startsAt }

    enum CodingKeys: String, CodingKey {
        case kind, title, description, format, capacity, contact
        case siteID = "site_id"
        case locationName = "location_name"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case skillMin = "skill_min"
        case skillMax = "skill_max"
        case feeCents = "fee_cents"
        case courtsReserved = "courts_reserved"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let iso = ISO8601DateFormatter()
        try c.encode(kind, forKey: .kind)
        try c.encode(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(siteID, forKey: .siteID)
        try c.encode(locationName, forKey: .locationName)
        try c.encode(iso.string(from: startsAt), forKey: .startsAt)
        try c.encode(endsAt.map(iso.string(from:)), forKey: .endsAt)
        try c.encode(format, forKey: .format)
        try c.encode(skillMin, forKey: .skillMin)
        try c.encode(skillMax, forKey: .skillMax)
        try c.encode(capacity, forKey: .capacity)
        try c.encode(feeCents, forKey: .feeCents)
        try c.encode(courtsReserved, forKey: .courtsReserved)
        try c.encode(contact, forKey: .contact)
    }

    /// Problems to fix before posting, in the order they appear on the form.
    public func problems(now: Date) -> [String] {
        var out: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 3 { out.append("Give it a title (at least 3 characters).") }
        if t.count > 80 { out.append("Keep the title under 80 characters.") }
        if siteID == nil && (locationName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("Choose a park or type a location.")
        }
        if startsAt < now { out.append("Pick a start time in the future.") }
        if let endsAt, endsAt <= startsAt { out.append("The end time must be after the start.") }
        if let lo = skillMin, let hi = skillMax, hi < lo {
            out.append("The top skill level must be at least the bottom one.")
        }
        if let capacity, !(2...512).contains(capacity) { out.append("Spots must be 2–512.") }
        return out
    }
}

public struct PlayerProfile: Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var skillLevel: Double?
    public var homeSite: String?

    public init(id: UUID, displayName: String, skillLevel: Double? = nil, homeSite: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.skillLevel = skillLevel
        self.homeSite = homeSite
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case skillLevel = "skill_level"
        case homeSite = "home_site"
    }

    public var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

public struct Account: Sendable, Equatable {
    public var id: UUID
    public var email: String?
    public init(id: UUID, email: String?) {
        self.id = id
        self.email = email
    }
}

/// What an email link (confirmation or password reset) turned into once it reached the app.
public enum AuthRedirect: Sendable, Equatable {
    case signedIn(Account)
    /// Signed in from a password-reset link: ask for a new password next.
    case choosePassword(Account)
}

public enum SignUpResult: Sendable, Equatable {
    case signedIn(Account)
    /// The server wants the email address confirmed before the first sign-in.
    case confirmEmail
}

/// One row of the backend `site_busy_hours` view.
public struct BusyHour: Codable, Sendable, Hashable {
    public var siteID: String
    public var weekday: Int  // 1 = Monday … 7 = Sunday
    public var hour: Int
    public var avgWaiting: Double
    public var courtsInUse: Double?
    public var samples: Int

    public init(siteID: String, weekday: Int, hour: Int, avgWaiting: Double,
                courtsInUse: Double? = nil, samples: Int) {
        self.siteID = siteID
        self.weekday = weekday
        self.hour = hour
        self.avgWaiting = avgWaiting
        self.courtsInUse = courtsInUse
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case weekday, hour, samples
        case siteID = "site_id"
        case avgWaiting = "avg_waiting"
        case courtsInUse = "courts_in_use"
    }
}

public enum BusyTimes {
    /// ISO weekday (1 = Monday) for a date in a time zone.
    public static func isoWeekday(_ date: Date, in tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let w = cal.component(.weekday, from: date)  // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    /// Hours of one weekday with enough data to show, 6 am–10 pm.
    public static func day(_ rows: [BusyHour], weekday: Int, minSamples: Int = 3) -> [BusyHour] {
        rows.filter { $0.weekday == weekday && $0.samples >= minSamples && (6...22).contains($0.hour) }
            .sorted { $0.hour < $1.hour }
    }
}

public protocol AuthService: Sendable {
    func currentAccount() async -> Account?
    /// Emits the current account immediately, then on every sign-in or sign-out.
    func accountChanges() -> AsyncStream<Account?>
    func signIn(email: String, password: String) async throws -> Account
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult
    func signOut() async throws
    func sendPasswordReset(email: String) async throws
    /// Sign in with a Google account (throws `CancellationError` if the person backs out).
    func signInWithGoogle() async throws -> Account
    /// Finish signing in from a link in a confirmation or reset email
    /// (`opencourt://auth/confirm?code=…` or `opencourt://auth/reset?code=…`).
    func handleRedirect(_ url: URL) async throws -> AuthRedirect
    func updatePassword(_ password: String) async throws
}

public protocol CommunityRepository: Sendable {
    func upcomingEvents(from: Date) async throws -> [CourtEvent]
    func createEvent(_ event: NewEvent) async throws
    func cancelEvent(id: UUID) async throws
    func register(eventID: UUID) async throws
    func unregister(eventID: UUID) async throws
    func myRegistrations() async throws -> Set<UUID>
    func profile(id: UUID) async throws -> PlayerProfile?
    func saveProfile(_ profile: PlayerProfile) async throws
    func busyHours(siteID: String) async throws -> [BusyHour]
}

public enum CommunityError: LocalizedError, Equatable {
    case signInRequired
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to do that."
        case .server(let message): message.prefix(1).uppercased() + message.dropFirst()
        }
    }
}
