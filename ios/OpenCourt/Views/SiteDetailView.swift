import OpenCourtKit
import SwiftUI

struct SiteDetailView: View {
    @Environment(SiteStore.self) private var store
    @Environment(EventsStore.self) private var events
    @Environment(FavoritesStore.self) private var favorites
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    let site: Site

    private var snapshot: SiteSnapshot? {
        store.snapshot?.site.id == site.id ? store.snapshot : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.isDemo { DemoBadge() }
                if let snapshot {
                    let freshness = snapshot.freshness(at: store.now)
                    FreshnessBanner(freshness: freshness, updatedAt: snapshot.site.updatedAt,
                                    now: store.now)
                    WaitSummary(site: snapshot.site, trustworthy: freshness.isTrustworthy)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
                              spacing: 12) {
                        ForEach(snapshot.courts) { court in
                            CourtCard(court: court, now: store.now,
                                      dimmed: !freshness.isTrustworthy)
                        }
                    }
                    Legend()
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
                if let lat = site.latitude, let lon = site.longitude,
                   let url = directionsURL(latitude: lat, longitude: lon, name: site.name) {
                    Button("Directions", systemImage: "car.fill") { openURL(url) }
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
    @ViewBuilder var upcoming: some View {
        let here = events.events(at: site.id).prefix(3)
        if !here.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Coming up here").font(.headline)
                ForEach(Array(here)) { e in
                    NavigationLink(value: e) {
                        EventRow(event: e, going: events.going.contains(e.id))
                            .padding(10)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func parkInfo(_ s: Site) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About this park").font(.headline)
            if let address = s.address, !address.isEmpty, address != "Demo data" {
                Label(address, systemImage: "mappin.and.ellipse")
            }
            Label("\(s.courtCount) outdoor courts", systemImage: "sportscourt")
            Label("Free to play, first come first served", systemImage: "person.2.wave.2")
            Label("One game, then rotate when people are waiting", systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct WaitSummary: View {
    let site: Site
    let trustworthy: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                stat(title: "Wait if you arrive now",
                     value: trustworthy ? WaitFormat.wait(site.waitSeconds).capitalizedFirst : "—",
                     big: true)
                if trustworthy, let ahead = site.groupsAhead, ahead > 0 {
                    Text(ahead == 1 ? "1 group ahead of you" : "\(ahead) groups ahead of you")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                stat(title: "In line", value: trustworthy ? "\(site.peopleWaiting)" : "—")
                stat(title: nextFreeTitle, value: trustworthy ? nextFree : "—")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    /// A court that is open right now goes to whoever is already in line, so say that
    /// instead of "free now" next to a non-zero wait.
    private var courtOpenNow: Bool { (site.nextFreeSeconds ?? 60) < 60 }

    private var nextFreeTitle: String {
        courtOpenNow && site.peopleWaiting > 0 ? "Open court" : "Next court free"
    }

    private var nextFree: String {
        guard let s = site.nextFreeSeconds else { return "—" }
        if courtOpenNow { return site.peopleWaiting > 0 ? "line's turn" : "now" }
        return "~" + WaitFormat.duration(TimeInterval(s))
    }

    private func stat(title: String, value: String, big: Bool = false) -> some View {
        VStack(alignment: big ? .leading : .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(big ? .largeTitle.weight(.semibold) : .title3.weight(.semibold))
                .monospacedDigit()
        }
    }
}

struct Legend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LightIndicator(mode: .solid)
                Text("Amber means a group's time is up: 20 minutes on court "
                     + "while others are waiting.")
            }
            Text("Estimates only. Counts come from a camera that doesn't record or identify "
                 + "anyone.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.top, 8)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
