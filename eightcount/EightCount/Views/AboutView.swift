import SwiftUI

/// About EightCount + the privacy policy (Apple wants it reachable inside
/// the app). The full text is in eightcount/PRIVACY.md on GitHub.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    static let privacyURL = URL(string: "https://github.com/splatfire/splatfire/blob/claude/nice-bardeen-84bg5p/eightcount/PRIVACY.md")!
    static let supportURL = URL(string: "https://github.com/splatfire/splatfire/issues")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("EightCount").font(.title2.weight(.bold))
                        Text("Learn choreography in 8-counts.")
                            .foregroundStyle(Theme.secondaryText)
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
                Section("Privacy") {
                    privacyLine("lock.shield", "No data collected. No accounts, ads, analytics or tracking. The app doesn't use the internet.")
                    privacyLine("iphone", "Your videos, notes and recordings stay on this iPhone. Deleting the app deletes them.")
                    privacyLine("camera", "The camera is only used to record you dancing. Recordings stay on your iPhone.")
                    privacyLine("sparkles", "The AI analysis and tips run on your iPhone (Apple's on-device models). Nothing is uploaded.")
                    Link(destination: Self.privacyURL) {
                        Label("Full privacy policy", systemImage: "doc.text")
                    }
                }
                Section {
                    Link(destination: Self.supportURL) {
                        Label("Help & feedback", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func privacyLine(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accent)
        }
    }
}
