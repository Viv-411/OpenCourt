import Foundation

/// Where court status comes from. The app talks only to this protocol.
public protocol StatusRepository: Sendable {
    func sites() async throws -> [Site]
    func snapshot(siteID: String) async throws -> SiteSnapshot
    /// Emits whenever something at the site changed. Values carry no data: callers refetch.
    /// This keeps the live path simple and the fetch path the single source of truth.
    func changes(siteID: String) -> AsyncStream<Void>
}

public enum RepositoryError: LocalizedError, Equatable {
    case siteNotFound(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .siteNotFound(let id): "Couldn't find site \(id)."
        case .notConfigured: "The app isn't connected to a server."
        }
    }
}
