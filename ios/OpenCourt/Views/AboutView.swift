import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("How it works") {
                    Text("When every court is full, the custom is one game, then rotate. "
                         + "A camera counts people on each court and in line. Each group gets "
                         + "20 minutes while others are waiting; when time is up, the light "
                         + "at their court turns amber. If the group moves up a court, their "
                         + "time moves with them. When they leave, the light goes out.")
                    Text("If nobody is waiting, no clock runs and the light never comes on.")
                }
                Section("Privacy") {
                    Label("No video is recorded or stored.", systemImage: "video.slash")
                    Label("No faces, no recognition. It can't tell one person from another "
                          + "on a different day.", systemImage: "person.crop.circle.badge.xmark")
                    Label("Only counts and court states leave the device.",
                          systemImage: "number")
                    Label("Your phone's location, if you share it, is used on the phone to "
                          + "sort parks by distance. It is never sent anywhere.",
                          systemImage: "location.slash")
                }
                Section("Estimates") {
                    Text("Wait times are rough guesses from how long current games have run. "
                         + "If the sensor goes quiet, the app says so instead of guessing.")
                }
            }
            .navigationTitle("About OpenCourt")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
