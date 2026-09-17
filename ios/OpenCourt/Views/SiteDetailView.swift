import OpenCourtKit
import SwiftUI

struct SiteDetailView: View {
    @Environment(SiteStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
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
        .refreshable { await store.refresh(siteID: site.id) }
        .onAppear { store.follow(siteID: site.id) }
        .onDisappear { store.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.follow(siteID: site.id) } else { store.stop() }
        }
    }
}

struct WaitSummary: View {
    let site: Site
    let trustworthy: Bool

    var body: some View {
        HStack(alignment: .top) {
            stat(title: "Wait if you arrive now",
                 value: trustworthy ? WaitFormat.wait(site.waitSeconds).capitalizedFirst : "—",
                 big: true)
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                stat(title: "In line", value: trustworthy ? "\(site.peopleWaiting)" : "—")
                stat(title: "Next court free",
                     value: trustworthy ? nextFree : "—")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var nextFree: String {
        guard let s = site.nextFreeSeconds else { return "—" }
        return s < 60 ? "now" : "~" + WaitFormat.duration(TimeInterval(s))
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
