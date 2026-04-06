import SwiftUI
import UIKit

struct ConsoleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var copiedAll = false
    @State private var copiedRow: UUID?

    var body: some View {
        PRCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SectionHeader(
                        "Console",
                        icon: "terminal.fill",
                        color: PRTheme.accent,
                        subtitle: "SDK log akışını burada takip et"
                    )
                    Spacer()
                    Text("\(appState.logStore.entries.count) lines")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    copyAllButton
                    clearButton
                }
                .padding(.bottom, PRTheme.spacing)

                Divider().padding(.vertical, 8)

                if appState.logStore.entries.isEmpty {
                    EmptyStateView("No log entries yet", icon: "text.alignleft")
                        .frame(height: 120)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(appState.logStore.entries) { entry in
                                    logRow(entry)
                                        .id(entry.id)
                                }
                            }
                        }
                        .frame(minHeight: 300, maxHeight: 500)
                        .onChange(of: appState.logStore.entries.count) { _ in
                            if let last = appState.logStore.entries.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onAppear {
                            if let last = appState.logStore.entries.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Log Row

    private func logRow(_ entry: LogStore.Entry) -> some View {
        Button {
            UIPasteboard.general.string = entry.plainText
            copiedRow = entry.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedRow = nil }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(entry.formattedTime)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .leading)

                Text(entry.level.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(levelColor(entry.level))
                    .frame(width: 40, alignment: .leading)

                Text(entry.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(copiedRow == entry.id ? PRTheme.success : messageForeground(entry.level))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if copiedRow == entry.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PRTheme.success)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(copiedRow == entry.id ? PRTheme.success.opacity(0.08) : PRTheme.rowBackground.opacity(0.45))
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Buttons

    private var copyAllButton: some View {
        Button {
            UIPasteboard.general.string = appState.logStore.formattedForCopy()
            copiedAll = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAll = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copiedAll ? "Copied!" : "Copy All")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(copiedAll ? PRTheme.success : PRTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((copiedAll ? PRTheme.success : PRTheme.accent).opacity(0.12))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(appState.logStore.entries.isEmpty)
    }

    private var clearButton: some View {
        Button {
            appState.logStore.clear()
        } label: {
            Text("Clear")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PRTheme.error)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Colors

    private func levelColor(_ level: LogStore.Level) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return PRTheme.info
        case .warning: return PRTheme.warning
        case .error:   return PRTheme.error
        }
    }

    private func messageForeground(_ level: LogStore.Level) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return .primary
        case .warning: return PRTheme.warning.opacity(0.9)
        case .error:   return PRTheme.error
        }
    }
}
