import Foundation

/// How much to trust what's on screen.
public enum Freshness: Equatable, Sendable {
    case live
    /// Sensor is reporting but can't see well (warming up, camera blocked, etc.).
    case limited
    /// No update for longer than `staleAfter`.
    case stale(age: TimeInterval)
    case neverReported

    public var isTrustworthy: Bool { self == .live }
}

public struct SiteSnapshot: Sendable, Equatable {
    public var site: Site
    public var courts: [CourtStatus]

    public init(site: Site, courts: [CourtStatus]) {
        self.site = site
        self.courts = courts.sorted { $0.number < $1.number }
    }

    public static let staleAfter: TimeInterval = 60

    public func freshness(at now: Date) -> Freshness {
        site.freshness(at: now)
    }

    public var openCourts: [CourtStatus] { courts.filter { $0.state.isAvailable } }
    public var courtsInSecondGame: [CourtStatus] { courts.filter { $0.state == .due } }
}

public extension Site {
    func freshness(at now: Date, staleAfter: TimeInterval = SiteSnapshot.staleAfter) -> Freshness {
        guard let updatedAt else { return .neverReported }
        let age = now.timeIntervalSince(updatedAt)
        if age > staleAfter { return .stale(age: age) }
        if health != .ok { return .limited }
        return .live
    }

    /// One line for the site list.
    func headline(at now: Date) -> String {
        switch freshness(at: now) {
        case .neverReported: return "No data yet"
        case .stale: return "Sensor offline"
        case .limited: return "Sensor warming up"
        case .live:
            if peopleWaiting == 0 {
                return nextFreeSeconds == 0 ? "Court open now" : "No line"
            }
            return "\(peopleWaiting) waiting · \(WaitFormat.wait(waitSeconds))"
        }
    }
}

public enum WaitFormat {
    /// Wait estimates are rough by nature; round and say "about".
    public static func wait(_ seconds: Int?) -> String {
        guard let seconds else { return "wait unknown" }
        if seconds < 90 { return "no wait" }
        return "about " + duration(TimeInterval(seconds), roundTo: 5)
    }

    public static func duration(_ seconds: TimeInterval, roundTo step: Int = 1) -> String {
        var minutes = Int((seconds / 60).rounded())
        if step > 1 { minutes = max(step, Int((Double(minutes) / Double(step)).rounded()) * step) }
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// `12:05` style clock for a court timer.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func age(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds)) s ago" }
        return duration(seconds) + " ago"
    }
}
