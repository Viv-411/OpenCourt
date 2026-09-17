import MapKit
import OpenCourtKit
import SwiftUI

struct SiteListView: View {
    @Environment(SiteStore.self) private var store
    @State private var mode: Mode = .list
    @State private var showingAbout = false
    @State private var path: [Site] = []

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
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
            }
            .sheet(isPresented: $showingAbout) { AboutView() }
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
        path = [site]
    }

    private var list: some View {
        List {
            if store.isDemo {
                Section { DemoBadge() }
            }
            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle") }
            }
            Section {
                ForEach(store.sites) { site in
                    NavigationLink(value: site) { SiteRow(site: site, now: store.now) }
                }
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(.headline)
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
