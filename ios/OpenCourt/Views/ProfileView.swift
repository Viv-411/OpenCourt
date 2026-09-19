import OpenCourtKit
import SwiftUI

/// The "You" tab: account, profile, your events, your parks and app info.
struct ProfileView: View {
    @Environment(SessionStore.self) private var session
    @Environment(EventsStore.self) private var events
    @Environment(SiteStore.self) private var sites
    @Environment(FavoritesStore.self) private var favorites
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var signIn: SignInView.Mode?
    @State private var editing = false
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            List {
                if let profile = session.profile, session.isSignedIn {
                    Section {
                        HStack(spacing: 14) {
                            Text(profile.initials)
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(Theme.accent.gradient, in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayName).font(.title3.bold())
                                if let email = session.account?.email {
                                    Text(email).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(profileLine(profile)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        Button("Edit profile", systemImage: "pencil") { editing = true }
                    }
                    Section("Your events") {
                        if myEvents.isEmpty {
                            Text("Events you sign up for or post will show up here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(myEvents) { e in
                            NavigationLink(value: e) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.headline)
                                    Text("\(e.startsAt.eventDay) · \(e.place)")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(e.organizerID == session.account?.id ? "Organizing" : "Going")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 48))
                                .foregroundStyle(Theme.accent)
                            Text("Join the community").font(.title3.bold())
                            Text("Browsing courts never needs an account. Sign in to post events, "
                                 + "sign up for tournaments and open play, and set your skill level.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            HStack {
                                Button("Sign in") { signIn = .signIn }
                                    .buttonStyle(.bordered)
                                Button("Create account") { signIn = .create }
                                    .buttonStyle(.borderedProminent)
                            }
                            .controlSize(.large)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }

                Section {
                    let mine = sites.sites.filter { favorites.contains($0.id) }
                    if mine.isEmpty {
                        Text("Tap the star on a park to keep it at the top of your list.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mine) { site in
                        Label(site.name, systemImage: "star.fill")
                            .foregroundStyle(.primary, Theme.amber)
                    }
                } header: {
                    Text("Your parks")
                }

                Section("OpenCourt") {
                    Button("How it works & privacy", systemImage: "hand.raised") { showingAbout = true }
                    Button("Show the welcome tour", systemImage: "sparkles") { hasSeenWelcome = false }
                    if session.isSignedIn {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right",
                               role: .destructive) {
                            Task { await session.signOut() }
                        }
                    }
                }
                Section {
                } footer: {
                    Text(sites.isDemo ? "Showing demo data." : "Version \(appVersion)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(session.isSignedIn ? "You" : "Account")
            .navigationDestination(for: CourtEvent.self) { EventDetailView(eventID: $0.id) }
            .sheet(item: $signIn) { SignInView(mode: $0) }
            .sheet(isPresented: $editing) { EditProfileView() }
            .sheet(isPresented: $showingAbout) { AboutView() }
        }
    }

    private var myEvents: [CourtEvent] {
        let me = session.account?.id
        return events.events.filter { events.going.contains($0.id) || $0.organizerID == me }
    }

    private func profileLine(_ p: PlayerProfile) -> String {
        var parts: [String] = []
        if let s = p.skillLevel { parts.append(String(format: "Skill %.1f", s)) }
        if let home = p.homeSite, let site = sites.sites.first(where: { $0.id == home }) {
            parts.append("Plays at \(site.name)")
        }
        return parts.isEmpty ? "Add your skill level and home park" : parts.joined(separator: " · ")
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }
}

struct EditProfileView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SiteStore.self) private var sites
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasSkill = false
    @State private var skill = 3.0
    @State private var home = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Display name", text: $name)
                }
                Section {
                    Toggle("Show my skill level", isOn: $hasSkill.animation())
                    if hasSkill {
                        Stepper(value: $skill, in: 2...8, step: 0.25) {
                            HStack {
                                Text("Skill")
                                Spacer()
                                Text(skill, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Skill level")
                } footer: {
                    Text("2.0 is brand new, 3.0 plays steady rallies, 4.0 is a strong club player, "
                         + "5.0+ is tournament level. If you have a DUPR rating, use that.")
                }
                Section("Home park") {
                    Picker("Home park", selection: $home) {
                        Text("None").tag("")
                        ForEach(sites.sites) { Text($0.name).tag($0.id) }
                    }
                }
                if let error = session.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || session.isWorking)
                }
            }
            .onAppear {
                guard let p = session.profile else { return }
                name = p.displayName
                hasSkill = p.skillLevel != nil
                skill = p.skillLevel ?? 3.0
                home = p.homeSite ?? ""
            }
        }
    }

    private func save() {
        guard var p = session.profile else { return }
        p.displayName = name.trimmingCharacters(in: .whitespaces)
        p.skillLevel = hasSkill ? skill : nil
        p.homeSite = home.isEmpty ? nil : home
        Task { if await session.saveProfile(p) { dismiss() } }
    }
}
