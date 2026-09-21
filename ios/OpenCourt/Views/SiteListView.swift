import MapKit
import OpenCourtKit
import SwiftUI

struct SiteListView: View {
    @Environment(SiteStore.self) private var store
    @Environment(FavoritesStore.self) private var favorites
    @Environment(LocationStore.self) private var location
    @Environment(\.openURL) private var openURL
    @State private var mode: Mode = Mode(rawValue: (AppConfig.argument("-view") ?? "").capitalized) ?? .list
    @State private var path = NavigationPath()
    @State private var camera: MapCameraPosition = .automatic

    enum Mode: String, CaseIterable, Identifiable {
        case list = "List", map = "Map"
        var id: String { rawValue }
    }

    /// Closest first once we know where the phone is; otherwise the backend's order.
    private var ordered: [Site] { Nearby.sorted(store.sites, from: location.coordinate) }

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
            .navigationBarTitleDisplayMode(mode == .map ? .inline : .large)
            .navigationDestination(for: Site.self) { SiteDetailView(site: $0) }
            .navigationDestination(for: CourtEvent.self) { EventDetailView(eventID: $0.id) }
            .toolbar {
                if store.isDemo {
                    ToolbarItem(placement: .topBarTrailing) { DemoBadge() }
                }
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
            .onAppear { location.refresh() }
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
            if let error = store.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle") }
            }
            if location.coordinate == nil {
                Section { LocationPrompt() }
            }
            let starred = ordered.filter { favorites.contains($0.id) }
            let others = ordered.filter { !favorites.contains($0.id) }
            if !starred.isEmpty {
                Section("Your parks") { rows(starred) }
            }
            if let header = othersHeader(hasStarred: !starred.isEmpty) {
                Section(header) { rows(others) }
            } else {
                Section { rows(others) }
            }
        }
        .animation(.snappy, value: location.coordinate)
    }

    private func othersHeader(hasStarred: Bool) -> String? {
        if location.coordinate != nil {
            return hasStarred ? "More parks, nearest first" : "Nearest to you"
        }
        return hasStarred ? "More parks" : nil
    }

    private func rows(_ list: [Site]) -> some View {
        ForEach(list) { site in
            NavigationLink(value: site) {
                SiteRow(site: site, now: store.now, starred: favorites.contains(site.id),
                        distance: site.distanceText(from: location.coordinate))
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
        .sensoryFeedback(.selection, trigger: favorites.ids)
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            // The pin draws its own label, so MapKit's title is hidden below.
            ForEach(store.sites) { site in
                if let coordinate = site.coordinate {
                    Annotation(site.name, coordinate: CLLocationCoordinate2D(
                        latitude: coordinate.latitude, longitude: coordinate.longitude)) {
                        NavigationLink(value: site) { MapPin(site: site, now: store.now) }
                            .accessibilityLabel("\(site.name), \(site.headline(at: store.now))")
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onAppear { camera = fitted }
        .onChange(of: store.sites) { camera = fitted }
        .onChange(of: location.coordinate) { camera = fitted }
        .safeAreaInset(edge: .bottom) {
            if location.canAsk {
                Button("Show my location") { location.request() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
    }

    /// Every park plus the phone's own dot, with room around the edges so no pin or label
    /// ends up half off the screen (`.automatic` frames them flush).
    private var fitted: MapCameraPosition {
        let points = store.sites.compactMap(\.coordinate) + [location.coordinate].compactMap { $0 }
        guard !points.isEmpty else { return .automatic }
        let latitudes = points.map(\.latitude), longitudes = points.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else {
            return .automatic
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.015, (maxLat - minLat) * 1.7),
                                    longitudeDelta: max(0.015, (maxLon - minLon) * 1.7))
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    @ViewBuilder private var emptyState: some View {
        if store.isLoading {
            ProgressView("Finding courts…")
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

/// Asks for location in context, on a card that says what it's for and where it goes.
private struct LocationPrompt: View {
    @Environment(LocationStore.self) private var location
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "location.fill", color: Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(location.isDenied ? "Location is off" : "Find the closest courts")
                    .font(.subheadline.weight(.semibold))
                Text(location.isDenied
                     ? "Turn it on in Settings to sort parks by distance."
                     : "Sort parks by distance. Your location stays on your phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if location.isLocating {
                ProgressView()
            } else if location.isDenied {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Use") { location.request() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A map marker: how many are waiting, coloured by whether a court is free.
private struct MapPin: View {
    let site: Site
    let now: Date

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(radius: 3, y: 1)
            Text(site.name)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private var live: Bool { site.freshness(at: now) == .live }
    private var label: String {
        guard live else { return "?" }
        return site.peopleWaiting == 0 ? "0" : "\(site.peopleWaiting)"
    }
    private var color: Color {
        guard live else { return .secondary }
        return site.peopleWaiting == 0 ? Theme.open : Theme.amber
    }
}

struct SiteRow: View {
    let site: Site
    let now: Date
    var starred = false
    var distance: String?

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: icon, color: color, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(site.name).font(.headline)
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.amber)
                            .accessibilityLabel("Starred")
                    }
                }
                Text(site.headline(at: now))
                    .font(.subheadline)
                    .foregroundStyle(open ? Theme.open : .secondary)
                HStack(spacing: 6) {
                    Text("\(site.courtCount) courts")
                    if let distance {
                        Text("·")
                        Label(distance, systemImage: "location.fill")
                            .labelStyle(.titleAndIcon)
                            .imageScale(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var live: Bool { site.freshness(at: now) == .live }
    private var open: Bool { live && site.peopleWaiting == 0 }
    private var icon: String {
        guard live else { return "wifi.slash" }
        return open ? "checkmark" : "person.3.fill"
    }
    private var color: Color {
        guard live else { return .secondary }
        return open ? Theme.open : Theme.accent
    }
}
