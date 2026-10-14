import SwiftUI

/// Small, unobtrusive sync indicator: offline / syncing / unsynced changes / last synced.
struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Re-render periodically so "2 min ago" stays current.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let (icon, text, color, help) = describe(model.syncStatus, now: context.date)
            HStack(spacing: 5) {
                if model.syncStatus == .syncing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).foregroundStyle(color)
                }
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(help)
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.refresh() } }
        }
    }

    private func describe(_ status: SyncStatus, now: Date) -> (String, String, Color, String) {
        switch status {
        case .syncing:
            return ("arrow.triangle.2.circlepath", "Syncing…", .secondary, "Syncing with Google Tasks")
        case .offline(let pending):
            let text = pending > 0 ? "Offline · \(changes(pending)) to sync" : "Offline"
            return ("wifi.slash", text, .orange, "You're offline. Changes are saved on this Mac and will sync automatically when you're back online.")
        case .failed(let message, let pending):
            let text = pending > 0 ? "\(changes(pending)) not synced" : "Sync issue"
            return ("exclamationmark.icloud", text, .orange, "\(message)\nClick to retry.")
        case .pending(let pending):
            return ("icloud.and.arrow.up", "\(changes(pending)) to sync", .secondary, "Waiting to sync. Click to sync now.")
        case .synced(let date):
            guard let date else { return ("icloud", "Not synced yet", .secondary, "Click to sync now.") }
            let ago = now.timeIntervalSince(date) < 60
                ? "just now"
                : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            return ("checkmark.icloud", "Synced \(ago)", .secondary,
                    "Up to date as of \(date.formatted(date: .abbreviated, time: .shortened)). Click to sync now.")
        }
    }

    private func changes(_ n: Int) -> String { n == 1 ? "1 change" : "\(n) changes" }
}
