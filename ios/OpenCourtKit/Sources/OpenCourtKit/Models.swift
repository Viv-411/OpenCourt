import Foundation

/// Court state as published by the sensor (sensor/src/opencourt/types.py `CourtState`).
public enum CourtState: String, Codable, Sendable, CaseIterable {
    case unknown, empty, rotating, idle, active, warning, due

    /// Unknown future values decode as `.unknown` rather than failing the whole response.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleContainer().decode(String.self)
        self = CourtState(rawValue: raw) ?? .unknown
    }

    /// Short, factual wording: the light reports the group's time; it never accuses.
    public var title: String {
        switch self {
        case .unknown: "Checking"
        case .empty: "Open"
        case .rotating: "Changing groups"
        case .idle: "In play"
        case .active: "In play · line waiting"
        case .warning: "Almost time"
        case .due: "Time up"
        }
    }

    public var isAvailable: Bool { self == .empty }
    public var hasClock: Bool { self == .active || self == .warning || self == .due }
}

public enum LightMode: String, Codable, Sendable {
    case off, pulse, solid

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleContainer().decode(String.self)
        self = LightMode(rawValue: raw) ?? .off
    }
}

public enum SensorHealth: String, Codable, Sendable {
    case warmingUp = "warming_up"
    case ok
    case degraded

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleContainer().decode(String.self)
        self = SensorHealth(rawValue: raw) ?? .degraded
    }
}

/// One row of the backend `site_overview` view.
public struct Site: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var address: String?
    public var latitude: Double?
    public var longitude: Double?
    public var timezone: String
    public var courtCount: Int
    public var health: SensorHealth?
    public var queueCount: Double?
    public var queueWaiting: Bool?
    public var waitSeconds: Int?
    public var nextFreeSeconds: Int?
    public var groupsAhead: Int?
    public var updatedAt: Date?

    public init(
        id: String, name: String, address: String? = nil, latitude: Double? = nil,
        longitude: Double? = nil, timezone: String = "America/Chicago", courtCount: Int,
        health: SensorHealth? = nil, queueCount: Double? = nil, queueWaiting: Bool? = nil,
        waitSeconds: Int? = nil, nextFreeSeconds: Int? = nil, groupsAhead: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.courtCount = courtCount
        self.health = health
        self.queueCount = queueCount
        self.queueWaiting = queueWaiting
        self.waitSeconds = waitSeconds
        self.nextFreeSeconds = nextFreeSeconds
        self.groupsAhead = groupsAhead
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude, timezone, health
        case courtCount = "court_count"
        case queueCount = "queue_count"
        case queueWaiting = "queue_waiting"
        case waitSeconds = "wait_seconds"
        case nextFreeSeconds = "next_free_seconds"
        case groupsAhead = "groups_ahead"
        case updatedAt = "updated_at"
    }

    /// People waiting, rounded for display.
    public var peopleWaiting: Int { Int((queueCount ?? 0).rounded()) }
}

/// One row of the backend `court_status` table.
public struct CourtStatus: Codable, Sendable, Identifiable, Hashable {
    public var siteID: String
    public var number: Int
    public var state: CourtState
    public var light: LightMode
    public var occupancy: Double
    public var clockSeconds: Int?
    public var secondsRemaining: Int?
    public var onCourtSeconds: Int?
    public var updatedAt: Date

    public var id: Int { number }

    public init(
        siteID: String, number: Int, state: CourtState, light: LightMode = .off,
        occupancy: Double, clockSeconds: Int? = nil, secondsRemaining: Int? = nil,
        onCourtSeconds: Int? = nil, updatedAt: Date
    ) {
        self.siteID = siteID
        self.number = number
        self.state = state
        self.light = light
        self.occupancy = occupancy
        self.clockSeconds = clockSeconds
        self.secondsRemaining = secondsRemaining
        self.onCourtSeconds = onCourtSeconds
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case number, state, light, occupancy
        case siteID = "site_id"
        case clockSeconds = "clock_seconds"
        case secondsRemaining = "seconds_remaining"
        case onCourtSeconds = "on_court_seconds"
        case updatedAt = "updated_at"
    }

    /// The backend skips no-op writes, so clocks are extrapolated from the last update.
    public func clock(at now: Date) -> TimeInterval? {
        guard state.hasClock, let clockSeconds else { return nil }
        return TimeInterval(clockSeconds) + max(0, now.timeIntervalSince(updatedAt))
    }

    public func remaining(at now: Date) -> TimeInterval? {
        guard state.hasClock, let secondsRemaining else { return nil }
        return max(0, TimeInterval(secondsRemaining) - max(0, now.timeIntervalSince(updatedAt)))
    }

    public var players: Int { Int(occupancy.rounded()) }
}

private extension Decoder {
    func singleContainer() throws -> SingleValueDecodingContainer { try singleValueContainer() }
}
