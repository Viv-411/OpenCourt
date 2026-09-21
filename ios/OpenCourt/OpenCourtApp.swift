import OpenCourtKit
import OpenCourtSupabase
import SwiftUI

@main
struct OpenCourtApp: App {
    @State private var app = AppConfig.make()
    @State private var favorites = FavoritesStore()
    @State private var location = LocationStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app.sites)
                .environment(app.session)
                .environment(app.events)
                .environment(favorites)
                .environment(location)
                .tint(Theme.accent)
        }
    }
}

/// The app's stores, wired to either the live backend or built-in demo data.
@MainActor
struct AppStores {
    let sites: SiteStore
    let session: SessionStore
    let events: EventsStore
}

@MainActor
enum AppConfig {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// Where confirmation and password-reset emails send people (GitHub Pages, web/auth/).
    static let emailLinkPage = URL(string: "https://viv-411.github.io/OpenCourt/auth/")

    static func argument(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Reads `SupabaseHost` / `SupabaseAnonKey` from Info.plist (filled from
    /// Config/Secrets.xcconfig). Without them, or with `-demo`, the app runs on demo data.
    ///
    /// Launch arguments for testing: `-demo`, `-openSite <id>`, `-demoMinutes <n>`,
    /// `-tab courts|events|you`, `-skipWelcome`, `-signedIn` (demo only).
    static func make() -> AppStores {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = (info["SupabaseHost"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["SupabaseAnonKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !arguments.contains("-demo"), !host.isEmpty, !key.isEmpty, !host.contains("$("),
           let url = URL(string: "https://\(host)") {
            let backend = SupabaseBackend(url: url, anonKey: key, emailLinkPage: emailLinkPage)
            return AppStores(
                sites: SiteStore(repository: backend.status),
                session: SessionStore(auth: backend.auth, community: backend.community),
                events: EventsStore(community: backend.community))
        }
        // `-demoMinutes N` starts the demo feed N minutes in (e.g. to show a court whose
        // time is up without waiting).
        var start = Date()
        if let minutes = argument("-demoMinutes").flatMap(Double.init) {
            start.addTimeInterval(-minutes * 60)
        }
        let community = DemoCommunityRepository()
        return AppStores(
            sites: SiteStore(repository: DemoRepository(start: start), isDemo: true),
            session: SessionStore(auth: DemoAuthService(signedIn: arguments.contains("-signedIn")),
                                  community: community),
            events: EventsStore(community: community))
    }
}
