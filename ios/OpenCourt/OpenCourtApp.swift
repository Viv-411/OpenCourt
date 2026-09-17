import OpenCourtKit
import OpenCourtSupabase
import SwiftUI

@main
struct OpenCourtApp: App {
    @State private var store: SiteStore = AppConfig.makeStore()

    var body: some Scene {
        WindowGroup {
            SiteListView()
                .environment(store)
                .tint(Theme.accent)
        }
    }
}

@MainActor
enum AppConfig {
    /// Reads `SupabaseHost` / `SupabaseAnonKey` from Info.plist (filled from
    /// Config/Secrets.xcconfig). Without them, or with `-demo` in the launch arguments, the
    /// app runs on built-in demo data.
    static func makeStore() -> SiteStore {
        let info = Bundle.main.infoDictionary ?? [:]
        let host = (info["SupabaseHost"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["SupabaseAnonKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let forceDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        if !forceDemo, !host.isEmpty, !key.isEmpty, !host.contains("$("),
           let url = URL(string: "https://\(host)") {
            return SiteStore(repository: SupabaseStatusRepository(url: url, anonKey: key))
        }
        // `-demoMinutes N` starts the demo feed N minutes in (e.g. to show a court whose
        // time is up without waiting).
        var start = Date()
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoMinutes"), i + 1 < args.count,
           let minutes = Double(args[i + 1]) {
            start.addTimeInterval(-minutes * 60)
        }
        return SiteStore(repository: DemoRepository(start: start), isDemo: true)
    }
}
