import SwiftUI

/// Day-grouped list of past entries. Newest day first; today pinned at the top.
struct SidebarView: View {
    @ObservedObject var store: JournalStore

    var body: some View {
        List(selection: selection) {
            Section("Days") {
                ForEach(store.days) { day in
                    row(day)
                        .tag(day.key)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { store.selectedDay },
            set: { if let key = $0 { store.select(key) } }
        )
    }

    private func row(_ day: Day) -> some View {
        HStack(spacing: 6) {
            Text(label(for: day.key))
                .fontWeight(day.key == store.todayKey ? .semibold : .regular)
            Spacer()
            if day.key == store.todayKey {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Today — new entries land here")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            Text("⌘⇧Space toggle · ⌘↩ save · esc hide")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    /// `2026-08-05` -> `Today` / `Yesterday` / `Tue 5 Aug 2026`
    private func label(for key: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: key) else { return key }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let display = DateFormatter()
        display.dateFormat = "EEE d MMM yyyy"
        return display.string(from: date)
    }
}
