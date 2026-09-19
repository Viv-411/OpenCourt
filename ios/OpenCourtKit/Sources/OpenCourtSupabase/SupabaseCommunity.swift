import Foundation
import OpenCourtKit
import Supabase

/// Everything the app needs from one Supabase project, sharing one client (and so one
/// signed-in session) between court status, sign-in and events.
public final class SupabaseBackend: Sendable {
    public let client: SupabaseClient
    public let status: SupabaseStatusRepository
    public let auth: SupabaseAuthService
    public let community: SupabaseCommunityRepository

    public init(url: URL, anonKey: String) {
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
        status = SupabaseStatusRepository(client: client)
        auth = SupabaseAuthService(client: client)
        community = SupabaseCommunityRepository(client: client)
    }
}

public final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    private static func account(_ user: User) -> Account {
        Account(id: user.id, email: user.email)
    }

    public func currentAccount() async -> Account? {
        client.auth.currentUser.map(Self.account)
    }

    public func accountChanges() -> AsyncStream<Account?> {
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                for await (_, session) in client.auth.authStateChanges {
                    continuation.yield(session.map { Self.account($0.user) })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func signIn(email: String, password: String) async throws -> Account {
        do {
            return Self.account(try await client.auth.signIn(email: email, password: password).user)
        } catch {
            throw friendly(error)
        }
    }

    public func signUp(email: String, password: String, displayName: String) async throws -> SignUpResult {
        do {
            let response = try await client.auth.signUp(
                email: email, password: password,
                data: displayName.isEmpty ? nil : ["display_name": .string(displayName)])
            switch response {
            case .session(let session): return .signedIn(Self.account(session.user))
            case .user: return .confirmEmail
            }
        } catch {
            throw friendly(error)
        }
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }

    public func sendPasswordReset(email: String) async throws {
        do { try await client.auth.resetPasswordForEmail(email) } catch { throw friendly(error) }
    }
}

public final class SupabaseCommunityRepository: CommunityRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    private var userID: UUID {
        get throws {
            guard let id = client.auth.currentUser?.id else { throw CommunityError.signInRequired }
            return id
        }
    }

    public func upcomingEvents(from: Date) async throws -> [CourtEvent] {
        do {
            let iso = ISO8601DateFormatter().string(from: from.addingTimeInterval(-3 * 3600))
            return try await client.from("event_listing")
                .select()
                .gte("starts_at", value: iso)
                .order("starts_at")
                .limit(200)
                .execute()
                .value(decoder: OpenCourtJSON.decoder())
        } catch {
            throw friendly(error)
        }
    }

    public func createEvent(_ event: NewEvent) async throws {
        _ = try userID
        do { try await client.from("events").insert(event).execute() } catch { throw friendly(error) }
    }

    public func cancelEvent(id: UUID) async throws {
        do {
            try await client.from("events").update(["status": "cancelled"])
                .eq("id", value: id.uuidString).execute()
        } catch {
            throw friendly(error)
        }
    }

    public func register(eventID: UUID) async throws {
        _ = try userID
        do {
            try await client.rpc("register_for_event", params: ["p_event": eventID.uuidString]).execute()
        } catch {
            throw friendly(error)
        }
    }

    public func unregister(eventID: UUID) async throws {
        do {
            try await client.rpc("unregister_from_event", params: ["p_event": eventID.uuidString])
                .execute()
        } catch {
            throw friendly(error)
        }
    }

    public func myRegistrations() async throws -> Set<UUID> {
        struct Row: Decodable { let event_id: UUID }
        let me = try userID
        do {
            let rows: [Row] = try await client.from("event_registrations")
                .select("event_id").eq("user_id", value: me.uuidString).execute().value
            return Set(rows.map(\.event_id))
        } catch {
            throw friendly(error)
        }
    }

    public func profile(id: UUID) async throws -> PlayerProfile? {
        do {
            let rows: [PlayerProfile] = try await client.from("profiles")
                .select().eq("id", value: id.uuidString).limit(1).execute().value
            return rows.first
        } catch {
            throw friendly(error)
        }
    }

    public func saveProfile(_ profile: PlayerProfile) async throws {
        do { try await client.from("profiles").upsert(profile).execute() } catch { throw friendly(error) }
    }

    public func busyHours(siteID: String) async throws -> [BusyHour] {
        do {
            return try await client.from("site_busy_hours")
                .select().eq("site_id", value: siteID).execute().value
        } catch {
            throw friendly(error)
        }
    }
}

/// Server and auth errors, reworded for people.
func friendly(_ error: Error) -> Error {
    if error is CommunityError { return error }
    if let e = error as? PostgrestError { return CommunityError.server(e.message) }
    if let e = error as? AuthError {
        let text = e.message.lowercased()
        if text.contains("invalid login") { return CommunityError.server("wrong email or password") }
        if text.contains("not confirmed") {
            return CommunityError.server("confirm your email first (check your inbox), then sign in")
        }
        if text.contains("already registered") {
            return CommunityError.server("that email already has an account; sign in instead")
        }
        return CommunityError.server(e.message)
    }
    return error
}
