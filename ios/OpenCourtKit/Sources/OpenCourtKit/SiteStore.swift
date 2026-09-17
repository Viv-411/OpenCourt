import Foundation
import Observation

/// App state for the site list and the selected site. Main-actor isolated; views observe it.
@MainActor
@Observable
public final class SiteStore {
    public private(set) var sites: [Site] = []
    public private(set) var snapshot: SiteSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// Ticks every second so relative times and extrapolated clocks stay current.
    public private(set) var now: Date

    public let isDemo: Bool
    private let repository: any StatusRepository
    private let clock: @Sendable () -> Date
    private var liveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var pollInterval: Duration

    public init(repository: any StatusRepository, isDemo: Bool = false,
                pollInterval: Duration = .seconds(20),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.isDemo = isDemo
        self.pollInterval = pollInterval
        self.clock = clock
        self.now = clock()
    }

    public func loadSites() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sites = try await repository.sites()
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
        now = clock()
    }

    public func refresh(siteID: String) async {
        do {
            let snap = try await repository.snapshot(siteID: siteID)
            snapshot = snap
            if let i = sites.firstIndex(where: { $0.id == siteID }) { sites[i] = snap.site }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = Self.describe(error)
        }
        now = clock()
    }

    /// Start following one site: fetch now, refetch on every change notification, and poll as
    /// a safety net (Realtime can silently drop on mobile networks).
    public func follow(siteID: String) {
        stop()
        if snapshot?.site.id != siteID { snapshot = nil }
        let changes = repository.changes(siteID: siteID)
        let poll = pollInterval
        liveTask = Task { [weak self] in
            await self?.refresh(siteID: siteID)
            for await _ in changes {
                await self?.refresh(siteID: siteID)
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                await self?.refresh(siteID: siteID)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.now = self.clock()
            }
        }
    }

    public func stop() {
        for task in [liveTask, pollTask, tickTask] { task?.cancel() }
        liveTask = nil
        pollTask = nil
        tickTask = nil
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Can't reach the server. Check your connection."
        }
        return "Something went wrong loading court status."
    }
}
