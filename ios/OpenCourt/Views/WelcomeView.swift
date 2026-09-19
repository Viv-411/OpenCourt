import OpenCourtKit
import SwiftUI

/// First-launch introduction: what OpenCourt does, how the light works, and the privacy
/// promise. Ends with an optional account step; browsing never needs one.
struct WelcomeView: View {
    let onDone: () -> Void
    @State private var page = 0
    @State private var signIn: SignInView.Mode?

    private struct Page {
        let symbol: String
        let color: Color
        let title: String
        let body: String
    }

    private let pages = [
        Page(symbol: "sportscourt.fill", color: Theme.accent, title: "See the courts before you go",
             body: "Which courts are open, how many people are waiting, and roughly how long "
                 + "you'd wait, live from the park."),
        Page(symbol: "light.beacon.max.fill", color: Theme.amber, title: "Fair turns, no arguments",
             body: "When people are waiting, each group gets 20 minutes. When time's up, the "
                 + "light at their court turns amber, so nobody has to be the one to say it."),
        Page(symbol: "hand.raised.fill", color: Theme.court, title: "Private by design",
             body: "The camera counts people and nothing else. No video is recorded or stored, "
                 + "and it can't recognize anyone."),
        Page(symbol: "calendar", color: Color(red: 0.80, green: 0.32, blue: 0.50),
             title: "Find people to play with",
             body: "Tournaments, open play, clinics and socials at your parks. Sign up in a tap, "
                 + "or post your own."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { onDone() }
                    .padding()
                    .opacity(page < pages.count - 1 ? 1 : 0)
            }
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    pageView(pages[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                if page < pages.count - 1 {
                    Button {
                        withAnimation { page += 1 }
                    } label: {
                        Text("Next").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        signIn = .create
                    } label: {
                        Text("Create an account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        signIn = .signIn
                    } label: {
                        Text("I have an account").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button("Continue without an account") { onDone() }
                        .font(.subheadline)
                        .padding(.top, 4)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(minHeight: 150, alignment: .top)
        }
        .sheet(item: $signIn) { mode in
            SignInView(mode: mode) { onDone() }
        }
    }

    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: p.symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 140, height: 140)
                .background(p.color.gradient, in: Circle())
                .shadow(color: p.color.opacity(0.35), radius: 20, y: 8)
            Text(p.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(p.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
        .padding()
    }
}
