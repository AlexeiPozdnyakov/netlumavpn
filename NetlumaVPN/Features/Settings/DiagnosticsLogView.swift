import SwiftUI
import UIKit

/// Read-only viewer for the diagnostics ring buffer (`AppLogStore`). The app and the
/// tunnel extension both write here through `AppLogger`, so this surfaces the
/// extension's `.tunnel` / `.xray` logs — the only place the engine's start/failure
/// reason is visible without a Mac + Console.
struct DiagnosticsLogView: View {
    @State private var events: [AppLogEvent] = []
    @State private var categoryFilter: AppLogCategory?

    private let logStore = AppLogStore()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var displayedEvents: [AppLogEvent] {
        let newestFirst = Array(events.reversed())
        guard let categoryFilter else {
            return newestFirst
        }
        return newestFirst.filter { $0.category == categoryFilter }
    }

    private var exportText: String {
        displayedEvents
            .map { "\(Self.timeFormatter.string(from: $0.date)) [\($0.category.rawValue)/\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if displayedEvents.isEmpty {
                    Text("No logs recorded yet.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 48)
                } else {
                    ForEach(displayedEvents) { event in
                        eventRow(event)
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(NetlumaVPNTheme.backgroundGradient)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NetlumaVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        categoryFilter = nil
                    } label: {
                        Label("All", systemImage: categoryFilter == nil ? "checkmark" : "line.3.horizontal.decrease")
                    }
                    ForEach(AppLogCategory.allCases) { category in
                        Button {
                            categoryFilter = category
                        } label: {
                            Label(category.rawValue, systemImage: categoryFilter == category ? "checkmark" : "circle")
                        }
                    }

                    Divider()

                    Button {
                        reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = exportText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: exportText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        logStore.clear()
                        reload()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func eventRow(_ event: AppLogEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: event.date))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                Text(event.category.rawValue.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(NetlumaVPNTheme.blue)
                Spacer(minLength: 0)
                Text(event.level.rawValue.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(levelColor(event.level))
            }
            Text(event.message)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(NetlumaVPNTheme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(NetlumaVPNTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
        }
    }

    private func levelColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .info:
            NetlumaVPNTheme.secondaryText
        case .warning:
            NetlumaVPNTheme.warning
        case .error:
            NetlumaVPNTheme.danger
        }
    }

    private func reload() {
        events = logStore.loadEvents()
    }
}
