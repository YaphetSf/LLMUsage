import AppKit
import LLMUsageUI
import SwiftUI

struct AboutView: View {
    @Environment(\.themeAccent) private var themeAccent

    private static let shortVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("About")
                identityCard
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var identityCard: some View {
        HStack(spacing: 18) {
            LLMUsageMark()
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 8) {
                Wordmark(size: 24)
                InfoChip { Text("Version \(Self.shortVersion)") }
                Text("Ding Zhong")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Link(destination: URL(string: "https://dingz.uk")!) {
                    HStack(spacing: 5) {
                        Text("dingz.uk")
                            .underline()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(themeAccent)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}