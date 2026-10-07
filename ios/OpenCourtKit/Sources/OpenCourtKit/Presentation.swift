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

    /// "3 in play · 1 open", for the heading over the courts.
    public var courtSummary: String {
        let playing = courts.filter { [.idle, .active, .warning, .due].contains($0.state) }.count
        let open = courts.filter { $0.state == .empty }.count
        let changing = courts.filter { $0.state == .rotating }.count
        var parts: [String] = []
        if playing > 0 { parts.append("\(playing) in play") }
        if open > 0 { parts.append("\(open) open") }
        if changing > 0 { parts.append("\(changing) changing") }
        return parts.joined(separator: " · ")
    }
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

/// The wait, split so the number can be shown big: "10" over "min wait".
public struct WaitDisplay: Equatable, Sendable {
    public enum Tone: Sendable, Equatable { case open, waiting, unknown }
    public var value: String
    public var unit: String
    public var tone: Tone

    public init(value: String, unit: String, tone: Tone) {
        self.value = value
        self.unit = unit
        self.tone = tone
    }

    /// For VoiceOver, which would otherwise read "10" and "min wait" as two things.
    public var spoken: String {
        switch tone {
        case .open: "No wait"
        case .waiting: "Wait about \(value) minutes"
        case .unknown: "Wait unknown, \(unit)"
        }
    }
}

public extension Site {
    func waitDisplay(at now: Date) -> WaitDisplay {
        switch freshness(at: now) {
        case .neverReported: return WaitDisplay(value: "–", unit: "no data yet", tone: .unknown)
        case .stale: return WaitDisplay(value: "–", unit: "offline", tone: .unknown)
        case .limited: return WaitDisplay(value: "–", unit: "warming up", tone: .unknown)
        case .live:
            guard let seconds = waitSeconds else {
                return WaitDisplay(value: "–", unit: "unknown", tone: .unknown)
            }
            if seconds < 90 { return WaitDisplay(value: "Now", unit: "no wait", tone: .open) }
            return WaitDisplay(value: "\(WaitFormat.roundedMinutes(TimeInterval(seconds)))",
                               unit: "min wait", tone: .waiting)
        }
    }

    /// The line under a park's name in the list.
    func statusLine(at now: Date) -> String {
        switch freshness(at: now) {
        case .neverReported: return "No data yet"
        case .stale(let age): return "Offline · last update \(WaitFormat.age(age))"
        case .limited: return "Sensor warming up"
        case .live:
            if peopleWaiting == 1 { return "1 person in line" }
            if peopleWaiting > 1 { return "\(peopleWaiting) in line" }
            return nextFreeSeconds == 0 ? "Court open now" : "No line"
        }
    }

    /// Plain sentences under the big wait on a park's page: who's ahead, and when a court
    /// frees up. Empty unless the data is live.
    func waitDetails(at now: Date) -> [String] {
        guard freshness(at: now) == .live else { return [] }
        var lines: [String] = []
        if peopleWaiting > 0 {
            var line = peopleWaiting == 1 ? "1 person in line" : "\(peopleWaiting) people in line"
            if let ahead = groupsAhead, ahead > 0 {
                line += ahead == 1 ? " · 1 group ahead of you" : " · \(ahead) groups ahead of you"
            }
            lines.append(line)
        }
        if let free = nextFreeSeconds {
            if free < 60 {
                // With no wait, whoever is in line could walk on too: the court is just free.
                let noWait = (waitSeconds ?? 0) < 90
                lines.append(peopleWaiting > 0 && !noWait
                             ? "A court is open. The people in line go first."
                             : "A court is free right now.")
            } else {
                lines.append("Next court frees up in about \(WaitFormat.duration(TimeInterval(free)))")
            }
        }
        return lines
    }
}

public extension CourtStatus {
    /// The small print on a court's tile, in words a first-time user can read:
    /// "4 players · 7 min on court", "Nobody playing", "Groups changing over".
    func detailLine(at now: Date) -> String {
        switch state {
        case .empty: return "Nobody playing"
        case .rotating: return "Groups changing over"
        case .unknown: return "Checking the camera"
        case .idle, .active, .warning, .due:
            let who = players == 1 ? "1 player" : "\(players) players"
            guard let on = onCourtSeconds else { return who }
            let elapsed = TimeInterval(on) + max(0, now.timeIntervalSince(updatedAt))
            return "\(who) · \(WaitFormat.duration(elapsed)) on court"
        }
    }

    /// "From Court 1 · kept their time": a group that just moved over keeps its clock.
    var movedNote: String? {
        movedFrom.map { "From Court \($0) · kept their time" }
    }
}

public enum WaitFormat {
    /// Whole minutes rounded to 5, at least 5: wait estimates are rough by nature.
    public static func roundedMinutes(_ seconds: TimeInterval) -> Int {
        let minutes = Int((seconds / 60).rounded())
        return max(5, Int((Double(minutes) / 5).rounded()) * 5)
    }

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
