import MapKit
import OpenCourtKit
import SwiftUI

struct SiteListView: View {
    @Environment(SiteStore.self) private var store
    @Environment(FavoritesStore.self) private var favorites
    @State private var mode: Mode = .list
    @State private var path = NavigationPath()

    enum Mode: String, CaseIterable, Identifiable {
        case list = "List", map = "Map"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.sites.isEmpty {
                    emptyState
                } else if mode == .list {
                    list
                } else {
                    map
                }
            }
            .navigationTitle("OpenCourt")
            .navigationDestination(for: Site.self) { SiteDetailView(site: $0) }
            .navigationDestination(for: CourtEvent.self) { EventDetailView(eventID: $0.id) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
            .task {
                await store.loadSites()
                openSiteFromLaunchArguments()
            }
            .refreshable { await store.loadSites() }
        }
    }

    /// `-openSite <id>` jumps straight to a site (handy for screenshots and UI checks).
    private func openSiteFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard path.isEmpty, let i = args.firstIndex(of: "-openSite"), i + 1 < args.count,
              let site = store.sites.first(where: { $0.id == args[i + 1] }) else { return }
        path.append(site)
    }

    private var list: some View {
        List {
            if store.isDemo {
                Section { DemoBadge() }
            }
            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle") }
            }
            let starred = store.sites.filter { favorites.contains($0.id) }
            let others = store.sites.filter { !favorites.contains($0.id) }
            if !starred.isEmpty {
                Section("Your parks") { rows(starred) }
            }
            Section(starred.isEmpty ? "" : "More parks") { rows(others) }
        }
    }

    private func rows(_ list: [Site]) -> some View {
        ForEach(list) { site in
            NavigationLink(value: site) {
                SiteRow(site: site, now: store.now, starred: favorites.contains(site.id))
            }
            .swipeActions(edge: .leading) {
                Button {
                    withAnimation { favorites.toggle(site.id) }
                } label: {
                    Label(favorites.contains(site.id) ? "Unstar" : "Star",
                          systemImage: favorites.contains(site.id) ? "star.slash" : "star.fill")
                }
                .tint(Theme.amber)
            }
        }
    }

    private var map: some View {
        Map {
            ForEach(store.sites.filter { $0.latitude != nil && $0.longitude != nil }) { site in
                Annotation(site.name, coordinate: CLLocationCoordinate2D(
                    latitude: site.latitude!, longitude: site.longitude!)) {
                    NavigationLink(value: site) {
                        Text(site.peopleWaiting == 0 ? "–" : "\(site.peopleWaiting)")
                            .font(.caption.bold())
                            .frame(width: 30, height: 30)
                            .background(markerColor(site), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("\(site.name), \(site.headline(at: store.now))")
                }
            }
        }
    }

    private func markerColor(_ site: Site) -> Color {
        guard site.freshness(at: store.now) == .live else { return .gray }
        return site.peopleWaiting == 0 ? Theme.open : Theme.accent
    }

    @ViewBuilder private var emptyState: some View {
        if store.isLoading {
            ProgressView("Loading courts…")
        } else {
            ContentUnavailableView {
                Label("No courts", systemImage: "sportscourt")
            } description: {
                Text(store.errorMessage ?? "No sites are set up yet.")
            } actions: {
                Button("Try again") { Task { await store.loadSites() } }
            }
        }
    }
}

struct SiteRow: View {
    let site: Site
    let now: Date
    var starred = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(site.name).font(.headline)
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                            .accessibilityLabel("Starred")
                    }
                }
                Text(site.headline(at: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(site.courtCount) courts")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var fresh: Bool { site.freshness(at: now) == .live }
    private var icon: String {
        guard fresh else { return "wifi.slash" }
        return site.peopleWaiting == 0 ? "checkmark.circle.fill" : "person.3.fill"
    }
    private var color: Color {
        guard fresh else { return .secondary }
        return site.peopleWaiting == 0 ? Theme.open : Theme.accent
    }
}
