import Foundation

/// A self-contained fake feed for previews, UI tests and "demo mode" when no backend is
/// configured. Deterministic for a given start date.
public actor DemoRepository: StatusRepository {
    private let start: Date
    private let clock: @Sendable () -> Date
    private let tick: Duration

    public init(start: Date = Date(), tick: Duration = .seconds(5),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.start = start
        self.clock = clock
        self.tick = tick
    }

    /// The demo mirrors the real pilot parks (so demo events line up with park pages), plus
    /// one made-up park whose sensor is offline.
    public static let siteIDs = ["mike-rylko", "rick-drazner", "demo-offline"]

    public func sites() async throws -> [Site] {
        let now = clock()
        return try await withThrowingTaskGroup(of: Site.self) { group in
            for id in Self.siteIDs {
                group.addTask { try await self.snapshot(siteID: id, now: now).site }
            }
            var out: [Site] = []
            for try await s in group { out.append(s) }
            return out.sorted { Self.siteIDs.firstIndex(of: $0.id)! < Self.siteIDs.firstIndex(of: $1.id)! }
        }
    }

    public func snapshot(siteID: String) async throws -> SiteSnapshot {
        try snapshot(siteID: siteID, now: clock())
    }

    public nonisolated func changes(siteID: String) -> AsyncStream<Void> {
        let tick = self.tick
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: tick)
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Fake world

    func snapshot(siteID: String, now: Date) throws -> SiteSnapshot {
        let t = now.timeIntervalSince(start)
        switch siteID {
        case "mike-rylko":
            return busySite(id: siteID, name: "Mike Rylko Community Park", courts: 8, t: t, now: now,
                            lat: 42.1683, lon: -87.9681)
        case "rick-drazner":
            return quietSite(id: siteID, name: "Rick Drazner Park", now: now)
        case "demo-offline":
            let site = Site(id: siteID, name: "Lakeview Courts", address: "Demo data",
                            latitude: 42.176, longitude: -87.95, courtCount: 2,
                            health: .ok, queueCount: 2, queueWaiting: true, waitSeconds: 600,
                            nextFreeSeconds: 120, groupsAhead: 1,
                            updatedAt: now.addingTimeInterval(-900))
            let courts = (1...2).map {
                CourtStatus(siteID: siteID, number: $0, state: .active, occupancy: 4,
                            clockSeconds: 300, secondsRemaining: 900, onCourtSeconds: 400,
                            updatedAt: now.addingTimeInterval(-900))
            }
            return SiteSnapshot(site: site, courts: courts)
        default:
            throw RepositoryError.siteNotFound(siteID)
        }
    }

    private func busySite(id: String, name: String, courts n: Int, t: TimeInterval, now: Date,
                          lat: Double, lon: Double) -> SiteSnapshot {
        let threshold = 1200.0
        let game = 900.0
        // Each court's group started at a staggered offset and cycles every ~17 min;
        // court n (farthest) overstays every other cycle so the light is visible in the demo.
        var courts: [CourtStatus] = []
        var remaining: [Double] = []
        for c in 1...n {
            let cycle = c == n ? 1500.0 : 1020.0
            let offset = Double(c) * 260
            let elapsed = (t + offset).truncatingRemainder(dividingBy: cycle)
            let rotating = elapsed < 25
            let state: CourtState
            if rotating { state = .rotating }
            else if elapsed >= threshold { state = .due }
            else if elapsed >= threshold - 120 { state = .warning }
            else { state = .active }
            courts.append(CourtStatus(
                siteID: id, number: c, state: state,
                light: state == .due ? .solid : state == .warning ? .pulse : .off,
                occupancy: rotating ? 2 : 4,
                clockSeconds: Int(elapsed), secondsRemaining: Int(max(0, threshold - elapsed)),
                onCourtSeconds: Int(elapsed), updatedAt: now))
            remaining.append(elapsed < game ? game - elapsed : 180)
        }
        let queue = 6 + 2 * sin(t / 300)
        let groupsAhead = Int((queue / 4).rounded(.up))
        let sorted = remaining.sorted()
        let wait = groupsAhead < sorted.count ? sorted[groupsAhead] : sorted.last! + game
        let site = Site(id: id, name: name, address: "1000 N Buffalo Grove Rd, Buffalo Grove, IL",
                        latitude: lat, longitude: lon,
                        courtCount: n, health: .ok, queueCount: queue, queueWaiting: true,
                        waitSeconds: Int(wait), nextFreeSeconds: Int(sorted[0]),
                        groupsAhead: groupsAhead, updatedAt: now)
        return SiteSnapshot(site: site, courts: courts)
    }

    private func quietSite(id: String, name: String, now: Date) -> SiteSnapshot {
        let site = Site(id: id, name: name, address: "401 Aptakisic Rd, Buffalo Grove, IL",
                        latitude: 42.159, longitude: -87.959, courtCount: 2, health: .ok,
                        queueCount: 0,
                        queueWaiting: false, waitSeconds: 0, nextFreeSeconds: 0,
                        groupsAhead: 0, updatedAt: now)
        let courts = [
            CourtStatus(siteID: id, number: 1, state: .empty, occupancy: 0, updatedAt: now),
            CourtStatus(siteID: id, number: 2, state: .idle, occupancy: 4, onCourtSeconds: 1500,
                        updatedAt: now),
        ]
        return SiteSnapshot(site: site, courts: courts)
    }
}
