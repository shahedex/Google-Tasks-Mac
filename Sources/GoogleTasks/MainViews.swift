import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            TaskListView()
                .inspector(isPresented: $showInspector) {
                    TaskDetailView()
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $model.sortMode) {
                    ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Sort tasks")

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .help("Sync now")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show or hide task details")
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newListTitle = ""
    @State private var addingList = false
    @State private var renaming: TaskList?
    @State private var renameText = ""
    @State private var deleting: TaskList?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedListID) {
            Section("Lists") {
                ForEach(model.lists) { list in
                    HStack {
                        Label(list.title, systemImage: "list.bullet")
                        Spacer()
                        if let count = model.incompleteCount(listID: list.id), count > 0 {
                            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tag(list.id)
                    .contextMenu {
                        Button("Rename…") { renameText = list.title; renaming = list }
                        Button("Delete List…", role: .destructive) { deleting = list }
                            .disabled(list.id == model.defaultListID)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    newListTitle = ""
                    addingList = true
                } label: {
                    Label("New list", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                SyncStatusView()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("New list", isPresented: $addingList) {
            TextField("Title", text: $newListTitle)
            Button("Create") { model.createList(title: newListTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename list", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let list = renaming { model.renameList(list, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \"\(deleting?.title ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete list and all its tasks", role: .destructive) {
                if let list = deleting { model.deleteList(list) }
            }
        } message: {
            Text("This also deletes it from Google Tasks on all your devices.")
        }
    }
}

// MARK: - Task list

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        @Bindable var model = model
        let listID = model.selectedListID
        let rows = model.activeRows(listID: listID)
        let completed = model.completedTasks(listID: listID)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
                TextField("Add a task", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($addFocused)
                    .onSubmit {
                        let title = newTitle
                        newTitle = ""
                        model.addTask(title: title, listID: listID)
                        addFocused = true
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            List(selection: $model.selectedTaskID) {
                if rows.isEmpty && model.tasksByList[listID ?? ""] != nil {
                    Text(completed.isEmpty ? "No tasks yet" : "All tasks complete 🎉")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                        .selectionDisabled()
                }
                ForEach(rows) { row in
                    TaskRow(task: row.task, listID: listID)
                        .padding(.leading, CGFloat(row.depth) * 26)
                        .tag(row.task.id)
                }
                if !completed.isEmpty {
                    Section(isExpanded: $model.showCompleted) {
                        ForEach(completed) { task in
                            TaskRow(task: task, listID: listID).tag(task.id)
                        }
                    } header: {
                        Text("Completed (\(completed.count))")
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if listID != nil && model.tasksByList[listID ?? ""] == nil {
                    if case .offline = model.syncStatus {
                        ContentUnavailableView("Not downloaded yet", systemImage: "wifi.slash",
                                               description: Text("This list will appear when you're back online."))
                    } else {
                        ProgressView()
                    }
                } else if listID == nil && model.lists.isEmpty {
                    if case .offline = model.syncStatus {
                        ContentUnavailableView("You're offline", systemImage: "wifi.slash",
                                               description: Text("Your tasks will download when you're back online."))
                    } else {
                        ProgressView()
                    }
                }
            }
            .onDeleteCommand {
                if let task = model.task(id: model.selectedTaskID, in: listID) {
                    model.deleteTask(task, listID: listID)
                }
            }
        }
        .navigationTitle(model.selectedList?.title ?? "Google Tasks")
        .onAppear { addFocused = true }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: GTask
    let listID: String?
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                model.toggleCompleted(task, listID: listID)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(compact ? .body : .title3)
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayTitle)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(compact ? 1 : 3)
                if !compact, let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let due = task.dueDate, !task.isCompleted {
                    DueBadge(date: due)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 2 : 4)
        .contextMenu {
            Button(task.isCompleted ? "Mark Not Done" : "Mark Done") {
                model.toggleCompleted(task, listID: listID)
            }
            if task.parent == nil && !task.isCompleted && !compact {
                Button("Add Subtask") {
                    model.addTask(title: "New subtask", listID: listID, parent: task.id)
                }
            }
            if model.lists.count > 1 {
                Menu("Move to List") {
                    ForEach(model.lists.filter { $0.id != listID }) { list in
                        Button(list.title) {
                            model.moveTask(task, from: listID, to: list.id)
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                model.deleteTask(task, listID: listID)
            }
        }
    }
}

struct DueBadge: View {
    let date: Date

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let overdue = date < today
        let label: String = {
            if cal.isDateInToday(date) { return "Today" }
            if cal.isDateInTomorrow(date) { return "Tomorrow" }
            if cal.isDateInYesterday(date) { return "Yesterday" }
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: today)
            return date.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                           : .dateTime.day().month(.abbreviated).year())
        }()
        Label(label, systemImage: "calendar")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(overdue ? Color.red.opacity(0.6) : Color.secondary.opacity(0.35)))
            .foregroundStyle(overdue ? Color.red : Color.secondary)
    }
}

// MARK: - Detail inspector

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var loadedTaskID: String?
    @State private var newSubtask = ""
    @FocusState private var focus: Field?

    private enum Field { case title, notes, subtask }

    var body: some View {
        let listID = model.selectedListID
        if let task = model.task(id: model.selectedTaskID, in: listID) {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.title3)
                        .focused($focus, equals: .title)
                        .onSubmit { save(task) }
                    Toggle("Completed", isOn: Binding(
                        get: { task.isCompleted },
                        set: { _ in model.toggleCompleted(task, listID: listID) }
                    ))
                }
                Section("Details") {
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 110)
                        .focused($focus, equals: .notes)
                        .scrollContentBackground(.hidden)
                }
                Section("Due date") {
                    Toggle("Has due date", isOn: $hasDue)
                        .onChange(of: hasDue) { save(task) }
                    if hasDue {
                        DatePicker("Date", selection: $due, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .onChange(of: due) { save(task) }
                    }
                }
                if task.parent == nil {
                    let subtasks = model.tasks(in: listID)
                        .filter { $0.parent == task.id }
                        .sorted { ($0.position ?? "") < ($1.position ?? "") }
                    Section("Subtasks") {
                        ForEach(subtasks) { sub in
                            TaskRow(task: sub, listID: listID, compact: true)
                        }
                        TextField("Add subtask", text: $newSubtask)
                            .focused($focus, equals: .subtask)
                            .onSubmit {
                                let t = newSubtask
                                newSubtask = ""
                                model.addTask(title: t, listID: listID, parent: task.id)
                                focus = .subtask
                            }
                    }
                }
                Section {
                    if let link = task.webViewLink, let url = URL(string: link) {
                        Link("Open in Google Tasks ↗", destination: url)
                    }
                    Button("Delete task", role: .destructive) {
                        model.deleteTask(task, listID: listID)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { load(task) }
            .onChange(of: task.id) { oldID, newID in
                if model.resolvedID(oldID) == newID {
                    // Same task, it just received its server ID: keep any edits in progress.
                    loadedTaskID = newID
                    return
                }
                if let old = model.task(id: oldID, in: listID) { save(old) }
                load(task)
            }
            .onChange(of: task.updated) {
                // Pick up remote changes when the user isn't editing.
                if focus == nil { load(task) }
            }
            .onChange(of: focus) { old, _ in
                if old == .title || old == .notes { save(task) }
            }
            .onDisappear { save(task) }
        } else {
            ContentUnavailableView("No task selected", systemImage: "checklist", description: Text("Select a task to see its details."))
        }
    }

    private func load(_ task: GTask) {
        loadedTaskID = task.id
        title = task.title ?? ""
        notes = task.notes ?? ""
        hasDue = task.dueDate != nil
        due = task.dueDate ?? Calendar.current.startOfDay(for: Date())
    }

    private func save(_ task: GTask) {
        guard loadedTaskID == task.id else { return }
        let t = title, n = notes, d = hasDue ? due : nil
        model.updateTask(task, listID: model.selectedListID, title: t, notes: n, due: d)
    }
}
