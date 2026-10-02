import OpenCourtKit
import SwiftUI

/// A park's page, in the order someone at the gate needs it: how long the wait is, which
/// courts are in play, when it's usually busy, what's coming up, then the park itself.
struct SiteDetailView: View {
    @Environment(SiteStore.self) private var store
    @Environment(EventsStore.self) private var events
    @Environment(FavoritesStore.self) private var favorites
    @Environment(LocationStore.self) private var location
    @Environment(\.scenePhase) private var scenePhase
    let site: Site

    private var snapshot: SiteSnapshot? {
        store.snapshot?.site.id == site.id ? store.snapshot : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let snapshot {
                    let freshness = snapshot.freshness(at: store.now)
                    if !freshness.isTrustworthy {
                        FreshnessBanner(freshness: freshness, updatedAt: snapshot.site.updatedAt,
                                        now: store.now)
                    }
                    WaitHero(site: snapshot.site, now: store.now, isDemo: store.isDemo)
                    courts(snapshot, trustworthy: freshness.isTrustworthy)
                    BusyTimesCard(site: snapshot.site)
                    upcoming
                    parkInfo(snapshot.site)
                } else if let error = store.errorMessage {
                    ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding()
        }
        .navigationTitle(site.name)
        .navigationBarTitleDisplayMode(site.name.count > 20 ? .inline : .large)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    favorites.toggle(site.id)
                } label: {
                    Label(favorites.contains(site.id) ? "Unstar" : "Star",
                          systemImage: favorites.contains(site.id) ? "star.fill" : "star")
                }
                .tint(Theme.amber)
                .sensoryFeedback(.selection, trigger: favorites.ids)
                if let lat = site.latitude, let lon = site.longitude {
                    Button("Directions", systemImage: "car.fill") {
                        openDirections(latitude: lat, longitude: lon, name: site.name)
                    }
                }
            }
        }
        .refreshable { await store.refresh(siteID: site.id) }
        .onAppear { store.follow(siteID: site.id) }
        .onDisappear { store.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.follow(siteID: site.id) } else { store.stop() }
        }
    }
}

extension SiteDetailView {
    func courts(_ snapshot: SiteSnapshot, trustworthy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Courts") {
                if trustworthy {
                    Text(snapshot.courtSummary).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(snapshot.courts) { court in
                    CourtCard(court: court, now: store.now, dimmed: !trustworthy)
                }
            }
            // Explain amber where it's seen, and only then; it's always under "About" too.
            if trustworthy, snapshot.courts.contains(where: { $0.light != .off }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LightIndicator(mode: .solid)
                    Text("Amber means a group's time is up: 20 minutes on court while others "
                         + "are waiting.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var upcoming: some View {
        let here = events.events(at: site.id).prefix(3)
        if !here.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Coming up here")
                ForEach(Array(here)) { e in
                    NavigationLink(value: e) {
                        EventRow(event: e, going: events.going.contains(e.id))
                            .card(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func parkInfo(_ s: Site) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("About this park")
            VStack(alignment: .leading, spacing: 12) {
                if let distance = s.distanceText(from: location.coordinate) {
                    Label("\(distance) away", systemImage: "location.fill")
                }
                if let address = s.address, !address.isEmpty, address != "Demo data" {
                    Label(address, systemImage: "mappin.and.ellipse")
                }
                Label("\(s.courtCount) outdoor courts", systemImage: "sportscourt")
                Label("Free to play, first come first served", systemImage: "person.2.wave.2")
                Label("One game, then rotate when people are waiting",
                      systemImage: "arrow.triangle.2.circlepath")
                Divider()
                Label("Amber light: a group's time is up, after 20 minutes on court while "
                      + "others wait", systemImage: "light.beacon.max")
                Label("Estimates only. The camera doesn't record or identify anyone.",
                      systemImage: "video.slash")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .card()
        }
    }
}

/// The answer to "how long would I wait?", as big as the screen allows, with plain
/// sentences under it for who's ahead and when a court frees up.
struct WaitHero: View {
    let site: Site
    let now: Date
    var isDemo = false
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    var body: some View {
        let wait = site.waitDisplay(at: now)
        let details = site.waitDetails(at: now)
        VStack(alignment: .leading, spacing: 10) {
            Text("Wait if you arrive now")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            number(wait)
            if let first = details.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(first).foregroundStyle(.primary)
                    ForEach(details.dropFirst(), id: \.self) { Text($0) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            footer
        }
        .card(20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func number(_ wait: WaitDisplay) -> some View {
        switch wait.tone {
        case .waiting:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(wait.value)
                    .font(.system(size: 84 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("min")
                    .font(.system(size: 30 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(wait.spoken)
        case .open:
            Text("No wait")
                .font(.system(size: 60 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.open)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        case .unknown:
            Text(wait.unit.capitalizedFirst)
                .font(.system(size: 40 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    @ViewBuilder private var footer: some View {
        let live = site.freshness(at: now) == .live
        if live || isDemo {
            HStack(spacing: 6) {
                if live, let updated = site.updatedAt {
                    Circle().fill(Theme.open).frame(width: 7, height: 7)
                    Text("Live · updated \(WaitFormat.age(now.timeIntervalSince(updated)))")
                }
                Spacer()
                if isDemo { DemoBadge() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
