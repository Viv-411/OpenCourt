import OpenCourtKit
import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(EventsStore.self) private var events
    @Environment(SiteStore.self) private var sites
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var tab: Tab = Tab(rawValue: AppConfig.argument("-tab") ?? "") ?? .courts

    enum Tab: String { case courts, events, you }

    var body: some View {
        TabView(selection: $tab) {
            SiteListView()
                .tabItem { Label("Courts", systemImage: "sportscourt.fill") }
                .tag(Tab.courts)
            EventsView()
                .tabItem { Label("Events", systemImage: "calendar") }
                .tag(Tab.events)
            ProfileView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
                .tag(Tab.you)
        }
        .task {
            session.start()
            async let parks: Void = sites.loadSites()
            async let upcoming: Void = events.load(signedIn: session.isSignedIn)
            _ = await (parks, upcoming)
        }
        .onChange(of: session.account) { _, account in
            Task { await events.load(signedIn: account != nil) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenWelcome && !AppConfig.arguments.contains("-skipWelcome") },
            set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeView { hasSeenWelcome = true }
        }
    }
}
