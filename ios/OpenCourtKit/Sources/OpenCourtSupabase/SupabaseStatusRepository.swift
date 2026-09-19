import Foundation
import OpenCourtKit
import Supabase

/// Live data from the OpenCourt backend (backend/supabase/migrations).
///
/// Reads use the public anon key; row level security only allows reading status.
public final class SupabaseStatusRepository: StatusRepository {
    private let client: SupabaseClient

    public init(url: URL, anonKey: String) {
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func sites() async throws -> [Site] {
        try await client.from("site_overview")
            .select()
            .order("name")
            .execute()
            .value(decoder: OpenCourtJSON.decoder())
    }

    public func snapshot(siteID: String) async throws -> SiteSnapshot {
        async let siteRows: [Site] = client.from("site_overview")
            .select()
            .eq("id", value: siteID)
            .limit(1)
            .execute()
            .value(decoder: OpenCourtJSON.decoder())
        async let courts: [CourtStatus] = client.from("court_status")
            .select()
            .eq("site_id", value: siteID)
            .order("number")
            .execute()
            .value(decoder: OpenCourtJSON.decoder())
        guard let site = try await siteRows.first else {
            throw RepositoryError.siteNotFound(siteID)
        }
        return try await SiteSnapshot(site: site, courts: courts)
    }

    public func changes(siteID: String) -> AsyncStream<Void> {
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                let channel = client.channel("site-\(siteID)")
                let site = channel.postgresChange(
                    AnyAction.self, schema: "public", table: "site_status",
                    filter: .eq("site_id", value: siteID))
                let courts = channel.postgresChange(
                    AnyAction.self, schema: "public", table: "court_status",
                    filter: .eq("site_id", value: siteID))
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()  // the store's polling keeps data fresh
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in site { continuation.yield() } }
                    group.addTask { for await _ in courts { continuation.yield() } }
                }
                await client.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension PostgrestResponse {
    func value<V: Decodable>(decoder: JSONDecoder) throws -> V {
        try decoder.decode(V.self, from: data)
    }
}
