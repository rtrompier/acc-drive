import SwiftUI

/// Simple status window shown while signed out.
struct LoginView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cloud")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Autodesk Construction Cloud")
                .font(.headline)
            Text("Click the cloud icon in the menu bar and choose \u{201C}Sign in to Autodesk\u{201D} to mount your ACC files in Finder.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 380, height: 220)
    }
}
