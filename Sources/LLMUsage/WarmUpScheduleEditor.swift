import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

struct WarmUpScheduleEditor: View {
    @State private var draft: WarmUpSchedule
    @State private var time: Date
    @Environment(\.dismiss) private var dismiss
    private let save: (WarmUpSchedule) -> Void

    init(schedule: WarmUpSchedule, save: @escaping (WarmUpSchedule) -> Void) {
        _draft = State(initialValue: schedule)
        _time = State(initialValue: Self.date(hour: schedule.hour, minute: schedule.minute))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Schedule")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            LabeledContent("Time") {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
            LabeledContent("Days") {
                PillRow(Self.weekdays) { weekday in
                    Pill(title: WarmUpSchedule.shortName(weekday: weekday),
                         isOn: draft.weekdays.contains(weekday)) { toggle(weekday, in: &draft.weekdays) }
                }
            }
            LabeledContent("Clients") {
                PillRow(WarmUpClient.allCases) { client in
                    Pill(title: client.title, isOn: draft.clients.contains(client)) {
                        toggle(client, in: &draft.clients)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
                    save(WarmUpSchedule(id: draft.id, enabled: draft.enabled,
                                        hour: components.hour ?? 0, minute: components.minute ?? 0,
                                        weekdays: draft.weekdays, clients: draft.clients))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.weekdays.isEmpty || draft.clients.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(AmbientBackground(.popover))
    }

    private func toggle<Element: Hashable>(_ element: Element, in set: inout Set<Element>) {
        if set.contains(element) { set.remove(element) } else { set.insert(element) }
    }

    /// Weekday buttons follow the machine's first day of week.
    private static var weekdays: [Int] {
        let first = Calendar.autoupdatingCurrent.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private static func date(hour: Int, minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }
}

private struct PillRow<Element: Hashable, Content: View>: View {
    private let elements: [Element]
    private let content: (Element) -> Content

    init(_ elements: [Element], @ViewBuilder content: @escaping (Element) -> Content) {
        self.elements = elements
        self.content = content
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(elements, id: \.self, content: content)
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct Pill: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, design: .rounded).weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : Color.white.opacity(0.55))
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background {
                    if isOn {
                        Color.clear
                            .silverGlass(in: Capsule(), tintOpacity: 0.32, interactive: true)
                            .shadow(color: Brand.glow.opacity(0.28), radius: 7, y: 2)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
