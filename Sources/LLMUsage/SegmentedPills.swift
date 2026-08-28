import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

/// A row of glass capsule segments — the app's stand-in for `Picker(.segmented)`, which
/// draws its own opaque chrome and looks pasted onto the glass.
struct SegmentedPills<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Namespace private var pill

    init(options: [Option], selection: Binding<Option>, label: @escaping (Option) -> String) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.system(.callout, design: .rounded)
                            .weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Color.clear
                                    .silverGlass(in: Capsule(), tintOpacity: 0.32, interactive: true)
                                    .shadow(color: Brand.glow.opacity(0.28), radius: 7, y: 2)
                                    .matchedGeometryEffect(id: "segment", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

extension RefreshFrequency {
    /// The full labels ("Every 15 minutes") are too long to sit four-across in a pill row.
    var shortLabel: String {
        switch self {
        case .everyMinute: "1 min"
        case .every5Minutes: "5 min"
        case .every15Minutes: "15 min"
        case .every30Minutes: "30 min"
        }
    }
}