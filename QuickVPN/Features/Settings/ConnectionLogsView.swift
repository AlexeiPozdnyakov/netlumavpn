import SwiftUI

struct ConnectionLogsView: View {
    @State private var events: [AppLogEvent] = []
    private let store = AppLogStore()

    var body: some View {
        List {
            if events.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Connection events will appear here after profile import or tunnel actions.")
                )
            } else {
                ForEach(events.reversed()) { event in
                    LogEventRow(event: event)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(QuickVPNTheme.backgroundGradient)
        .navigationTitle("Connection Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        store.clear()
                        refresh()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Log Actions")
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        events = store.loadEvents()
    }
}

private struct LogEventRow: View {
    let event: AppLogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(levelColor)
                    .frame(width: 20)

                Text(event.level.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(levelColor)

                Text(event.category.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(event.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(event.message)
                .font(.footnote)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch event.level {
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .error:
            "xmark.octagon"
        }
    }

    private var levelColor: Color {
        switch event.level {
        case .info:
            .blue
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

#Preview {
    NavigationStack {
        ConnectionLogsView()
    }
}
