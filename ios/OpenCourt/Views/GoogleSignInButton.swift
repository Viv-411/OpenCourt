import OpenCourtKit
import SwiftUI

/// "Continue with Google", following Google's branding guidelines for the light button:
/// white fill, grey outline, the official G logo, and the wording Google allows.
struct GoogleSignInButton: View {
    @Environment(SessionStore.self) private var session
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("GoogleG")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Continue with Google")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(red: 0.45, green: 0.47, blue: 0.46), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(session.isWorking)
        .accessibilityLabel("Continue with Google")
    }
}
