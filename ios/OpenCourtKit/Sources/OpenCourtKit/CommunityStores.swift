import Foundation
import Observation

/// Who is signed in, and their profile. Browsing never requires an account; posting and
/// signing up for events do.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var account: Account?
    public private(set) var profile: PlayerProfile?
    public private(set) var isWorking = false
    public var errorMessage: String?
    /// Set after sign-up when the server wants the email confirmed first.
    public private(set) var awaitingConfirmation: String?

    public let auth: any AuthService
    private let community: any CommunityRepository
    private var watcher: Task<Void, Never>?

    public init(auth: any AuthService, community: any CommunityRepository) {
        self.auth = auth
        self.community = community
    }

    public var isSignedIn: Bool { account != nil }

    public func start() {
        guard watcher == nil else { return }
        let changes = auth.accountChanges()
        watcher = Task { [weak self] in
            for await account in changes {
                guard let self else { return }
                self.account = account
                await self.loadProfile()
            }
        }
    }

    private func loadProfile() async {
        guard let account else {
            profile = nil
            return
        }
        profile = (try? await community.profile(id: account.id))
            ?? PlayerProfile(id: account.id, displayName: account.email?.split(separator: "@").first
                .map(String.init) ?? "Player")
    }

    /// Returns true on success, so a sheet can close itself.
    public func signIn(email: String, password: String) async -> Bool {
        await run {
            let a = try await self.auth.signIn(email: email.trimmed, password: password)
            self.account = a
            await self.loadProfile()
        }
    }

    public func signUp(email: String, password: String, displayName: String) async -> Bool {
        await run {
            switch try await self.auth.signUp(email: email.trimmed, password: password,
                                              displayName: displayName.trimmed) {
            case .signedIn(let a):
                self.account = a
                await self.loadProfile()
            case .confirmEmail:
                self.awaitingConfirmation = email.trimmed
            }
        }
    }

    public func signOut() async {
        _ = await run {
            try await self.auth.signOut()
            self.account = nil
            self.profile = nil
        }
    }

    public func sendPasswordReset(email: String) async -> Bool {
        await run { try await self.auth.sendPasswordReset(email: email.trimmed) }
    }

    public func saveProfile(_ p: PlayerProfile) async -> Bool {
        await run {
            try await self.community.saveProfile(p)
            self.profile = p
        }
    }

    public func clearConfirmation() { awaitingConfirmation = nil }

    private func run(_ work: @escaping @MainActor () async throws -> Void) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
            return true
        } catch {
            errorMessage = SiteStore.describe(error)
            return false
        }
    }
}

/// Upcoming events and which ones the signed-in player is going to.
@MainActor
@Observable
public final class EventsStore {
    public private(set) var events: [CourtEvent] = []
    public private(set) var going: Set<UUID> = []
    public private(set) var isLoading = false
    public private(set) var busyEventID: UUID?
    public var errorMessage: String?
    public var kindFilter: EventKind?

    private let community: any CommunityRepository
    private let clock: @Sendable () -> Date

    public init(community: any CommunityRepository, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.community = community
        self.clock = clock
    }

    public var visible: [CourtEvent] {
        events.filter { kindFilter == nil || $0.kind == kindFilter }
    }

    public func events(at siteID: String) -> [CourtEvent] {
        events.filter { $0.siteID == siteID && !$0.isCancelled }
    }

    public func load(signedIn: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            events = try await community.upcomingEvents(from: clock())
            going = signedIn ? try await community.myRegistrations() : []
            errorMessage = nil
        } catch {
            errorMessage = SiteStore.describe(error)
        }
    }

    public func toggleGoing(_ event: CourtEvent) async {
        busyEventID = event.id
        defer { busyEventID = nil }
        do {
            if going.contains(event.id) {
                try await community.unregister(eventID: event.id)
            } else {
                try await community.register(eventID: event.id)
            }
            await load(signedIn: true)
        } catch {
            errorMessage = SiteStore.describe(error)
        }
    }

    public func create(_ event: NewEvent) async -> Bool {
        do {
            try await community.createEvent(event)
            await load(signedIn: true)
            return true
        } catch {
            errorMessage = SiteStore.describe(error)
            return false
        }
    }

    /// Typical crowd by weekday and hour; empty when there isn't enough history yet.
    public func busyHours(siteID: String) async -> [BusyHour] {
        (try? await community.busyHours(siteID: siteID)) ?? []
    }

    public func cancel(_ event: CourtEvent) async {
        do {
            try await community.cancelEvent(id: event.id)
            await load(signedIn: true)
        } catch {
            errorMessage = SiteStore.describe(error)
        }
    }
}

/// Parks the player has starred. Stored on the device; no account needed.
@MainActor
@Observable
public final class FavoritesStore {
    public private(set) var ids: [String]
    private let defaults: UserDefaults
    private static let key = "favoriteSiteIDs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.key) ?? []
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        defaults.set(ids, forKey: Self.key)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
