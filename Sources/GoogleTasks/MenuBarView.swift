import SwiftUI

/// Compact quick-add + task list shown from the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var newTitle = ""
    @FocusState private var addFocused: Bool

    /// Shares the main window's selection, so the menu bar count always matches this list.
    private var listID: String? { model.selectedListID }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase != .signedIn {
                Text("Not signed in").font(.headline)
                Button("Open Google Tasks…") { openMain() }
            } else {
                HStack {
                    Picker("List", selection: Binding(get: { listID ?? "" }, set: { model.selectedListID = $0 })) {
                        ForEach(model.lists) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    SyncStatusView()
                }

                TextField("Add a task", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit {
                        let title = newTitle
                        newTitle = ""
                        model.addTask(title: title, listID: listID)
                    }

                let rows = model.activeRows(listID: listID).filter { $0.depth == 0 }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if rows.isEmpty {
                            Text("Nothing to do 🎉")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        ForEach(rows) { row in
                            TaskRow(task: row.task, listID: listID, compact: true)
                        }
                    }
                }
                // Rows with a due-date badge are taller.
                .frame(height: min(max(rows.reduce(0) { $0 + ($1.task.dueDate == nil ? 28 : 48) }, 60), 380))
            }

            Divider()
            HStack {
                Button("Open Google Tasks") { openMain() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { addFocused = true }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
