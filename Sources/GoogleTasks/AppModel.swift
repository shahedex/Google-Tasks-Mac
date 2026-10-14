import AppKit
import Foundation
import Network
import Observation

enum SortMode: String, CaseIterable, Identifiable {
    case myOrder = "My order"
    case dueDate = "Date"
    var id: String { rawValue }
}

/// A task plus its nesting depth, ready for display.
struct TaskRowItem: Identifiable, Hashable {
    let task: GTask
    let depth: Int
    var id: String { task.id }
}

enum SyncStatus: Equatable {
    case syncing
    case offline(pending: Int)
    case failed(message: String, pending: Int)
    case pending(Int)
    case synced(Date?)
}

/// Offline-first store: the UI reads and writes local data, and changes are queued
/// and pushed to Google in the background whenever the network is available.
@MainActor
@Observable
final class AppModel {
    enum Phase { case needsClientConfig, signedOut, signedIn }

    private(set) var phase: Phase = .needsClientConfig
    private(set) var lists: [TaskList] = []
    private(set) var tasksByList: [String: [GTask]] = [:]
    var selectedListID: String? {
        didSet { if !isDemo { UserDefaults.standard.set(selectedListID, forKey: "selectedListID") } }
    }
    var selectedTaskID: String?
    var sortMode: SortMode = .myOrder
    var showCompleted = false
    var isSigningIn = false
    /// Only used for user-initiated actions (sign-in). Sync problems never pop up.
    var errorMessage: String?

    private(set) var pendingOps: [PendingOp] = []
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var networkAvailable = true
    private(set) var lastAttemptWasOffline = false
    private(set) var syncProblem: String?

    @ObservationIgnored let auth: OAuthManager
    /// Demo models (used to render README screenshots) never touch the network or disk.
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private lazy var api = TasksAPI(auth: auth)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Local IDs that have been replaced by server IDs.
    @ObservationIgnored private(set) var idRemaps: [String: String] = [:]

    init(demo: Bool = false) {
        isDemo = demo
        auth = OAuthManager(loadFromKeychain: !demo)
        if demo { return }
        selectedListID = UserDefaults.standard.string(forKey: "selectedListID")
        if let snapshot = LocalStore.loadSnapshot() {
            lists = snapshot.lists
            tasksByList = snapshot.tasksByList
            lastSynced = snapshot.lastSynced
        }
        pendingOps = LocalStore.loadQueue()
        updatePhase()

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(available: path.status == .satisfied) }
        }
        pathMonitor.start(queue: .main)

        if phase == .signedIn { start() }
    }

    private func updatePhase() {
        if !auth.hasClientConfig { phase = .needsClientConfig }
        else if !auth.isSignedIn { phase = .signedOut }
        else { phase = .signedIn }
    }

    private func start() {
        Task { await refresh() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Retry sooner while there are changes waiting to go out.
                let hasBacklog = !(self?.pendingOps.isEmpty ?? true)
                try? await Task.sleep(for: .seconds(hasBacklog ? 20 : 60))
                await self?.refresh()
            }
        }
    }

    private func networkChanged(available: Bool) {
        let cameBack = available && !networkAvailable
        networkAvailable = available
        if cameBack { Task { await refresh() } }
    }

    // MARK: Auth

    func saveClientConfig(_ config: OAuthClientConfig) {
        auth.saveClientConfig(config)
        updatePhase()
    }

    func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await auth.signIn()
            updatePhase()
            start()
        } catch {
            errorMessage = error.isNetworkError
                ? "You're offline. Connect to the internet to sign in."
                : error.localizedDescription
        }
    }

    func signOut() {
        pollTask?.cancel()
        auth.signOut()
        lists = []
        tasksByList = [:]
        pendingOps = []
        lastSynced = nil
        selectedTaskID = nil
        syncProblem = nil
        LocalStore.clear()
        updatePhase()
    }

    func resetClientConfig() {
        signOut()
        auth.forgetClientConfig()
        updatePhase()
    }

    // MARK: Derived data

    var selectedList: TaskList? { lists.first { $0.id == selectedListID } }

    var defaultListID: String? { lists.first?.id }

    var syncStatus: SyncStatus {
        if !networkAvailable { return .offline(pending: pendingOps.count) }
        if isSyncing { return .syncing }
        if lastAttemptWasOffline { return .offline(pending: pendingOps.count) }
        if let syncProblem { return .failed(message: syncProblem, pending: pendingOps.count) }
        if !pendingOps.isEmpty { return .pending(pendingOps.count) }
        return .synced(lastSynced)
    }

    func tasks(in listID: String?) -> [GTask] {
        guard let listID else { return [] }
        return tasksByList[listID] ?? []
    }

    func task(id: String?, in listID: String?) -> GTask? {
        guard let id else { return nil }
        return tasks(in: listID).first { $0.id == id }
    }

    /// Incomplete tasks (including subtasks), or nil if the list hasn't loaded yet.
    func incompleteCount(listID: String?) -> Int? {
        guard let listID, let tasks = tasksByList[listID] else { return nil }
        return tasks.filter { !$0.isCompleted }.count
    }

    /// Incomplete tasks, with subtasks nested under their parents.
    func activeRows(listID: String?) -> [TaskRowItem] {
        let active = tasks(in: listID).filter { !$0.isCompleted }
        let ids = Set(active.map(\.id))
        let byPosition: (GTask, GTask) -> Bool = { ($0.position ?? "") < ($1.position ?? "") }

        switch sortMode {
        case .myOrder:
            let children = Dictionary(grouping: active.filter { $0.parent != nil && ids.contains($0.parent!) }, by: { $0.parent! })
            let roots = active.filter { $0.parent == nil || !ids.contains($0.parent!) }.sorted(by: byPosition)
            return roots.flatMap { root in
                [TaskRowItem(task: root, depth: 0)]
                    + (children[root.id] ?? []).sorted(by: byPosition).map { TaskRowItem(task: $0, depth: 1) }
            }
        case .dueDate:
            return active.sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?): return x == y ? byPosition(a, b) : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byPosition(a, b)
                }
            }
            .map { TaskRowItem(task: $0, depth: 0) }
        }
    }

    func completedTasks(listID: String?) -> [GTask] {
        tasks(in: listID)
            .filter(\.isCompleted)
            .sorted { ($0.completedDate ?? .distantPast) > ($1.completedDate ?? .distantPast) }
    }

    // MARK: Sync engine

    /// Pushes queued changes, then pulls the latest data. Never shows alerts.
    func refresh() async {
        guard phase == .signedIn, !isDemo else { return }
        guard !isSyncing else { syncAgain = true; return }
        guard networkAvailable else { return }
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            syncAgain = false
            do {
                try await pushPendingChanges()
                try await pullLatest()
                lastSynced = Date()
                lastAttemptWasOffline = false
                syncProblem = nil
                persistSnapshot()
            } catch {
                if case AuthError.notSignedIn = error {
                    // Keep local data and queued changes; just ask to sign in again.
                    pollTask?.cancel()
                    updatePhase()
                    return
                }
                if error.isNetworkError {
                    lastAttemptWasOffline = true
                } else {
                    syncProblem = error.localizedDescription
                }
                return
            }
        } while syncAgain
    }

    private func pushPendingChanges() async throws {
        while let next = pendingOps.first {
            do {
                try await perform(next.op)
            } catch let APIError.http(code, message) where (400..<500).contains(code) && code != 401 && code != 429 {
                // Rejected for good (e.g. the task was deleted on another device): drop it.
                NSLog("Dropping change \(next.op) after HTTP \(code): \(message)")
            }
            pendingOps.removeAll { $0.id == next.id }
            persistQueue()
        }
    }

    private func perform(_ op: SyncOp) async throws {
        switch op {
        case let .createTask(tempID, listID, title, notes, due, parent, _):
            let created = try await api.createTask(listID: listID, title: title, notes: notes, due: due.flatMap(GDate.parseDue), parent: parent)
            remap(tempID, to: created.id)
            if parent == nil {
                // Best effort: a failure here only affects ordering, and retrying the
                // whole operation would create a duplicate.
                _ = try? await api.moveTask(listID: listID, taskID: created.id, parent: nil, previous: nil)
            }

        case let .patchTask(listID, taskID, patch):
            _ = try await api.patchTask(listID: listID, taskID: taskID, fields: patch.apiFields)

        case let .deleteTask(listID, taskID):
            try await api.deleteTask(listID: listID, taskID: taskID)

        case let .moveTask(taskID, from, to):
            do {
                _ = try await api.moveTask(listID: from, taskID: taskID, parent: nil, previous: nil, destinationListID: to)
            } catch APIError.http(400, _) {
                try await copyThenDelete(taskID: taskID, from: from, to: to)
            }

        case let .createList(tempID, title):
            let list = try await api.createList(title: title)
            remap(tempID, to: list.id)

        case let .renameList(listID, title):
            _ = try await api.renameList(id: listID, title: title)

        case let .deleteList(listID):
            try await api.deleteList(id: listID)
        }
    }

    /// Fallback for cross-list moves when the API doesn't support `destinationTasklist`.
    private func copyThenDelete(taskID: String, from: String, to: String) async throws {
        let local = tasks(in: to)
        guard let task = local.first(where: { $0.id == taskID }) else { return }
        let copy = try await api.createTask(listID: to, title: task.title ?? "", notes: task.notes, due: task.dueDate)
        if task.isCompleted {
            _ = try await api.patchTask(listID: to, taskID: copy.id, fields: ["status": "completed"])
        }
        for sub in local.filter({ $0.parent == taskID }).sorted(by: { ($0.position ?? "") > ($1.position ?? "") }) {
            let subCopy = try await api.createTask(listID: to, title: sub.title ?? "", notes: sub.notes, due: sub.dueDate, parent: copy.id)
            if sub.isCompleted {
                _ = try await api.patchTask(listID: to, taskID: subCopy.id, fields: ["status": "completed"])
            }
        }
        try await api.deleteTask(listID: from, taskID: taskID)
        remap(taskID, to: copy.id)
    }

    /// Replaces server data with the latest copy, then re-applies any changes
    /// that were made while the download was in flight.
    private func pullLatest() async throws {
        let fetchedLists = try await api.taskLists()
        var fetchedTasks: [String: [GTask]] = [:]
        try await withThrowingTaskGroup(of: (String, [GTask]).self) { group in
            for list in fetchedLists {
                group.addTask { @MainActor in (list.id, try await self.api.tasks(listID: list.id)) }
            }
            for try await (id, tasks) in group { fetchedTasks[id] = tasks }
        }
        lists = fetchedLists
        tasksByList = fetchedTasks
        for pending in pendingOps { applyLocally(pending.op) }

        if selectedListID == nil || !lists.contains(where: { $0.id == selectedListID }) {
            selectedListID = lists.first?.id
        }
        if let sel = selectedTaskID, task(id: sel, in: selectedListID) == nil {
            selectedTaskID = nil
        }
    }

    /// Swaps a local placeholder ID for the real server ID everywhere.
    private func remap(_ old: String, to new: String) {
        guard old != new else { return }
        idRemaps[old] = new
        let f: (String) -> String = { $0 == old ? new : $0 }

        lists = lists.map { var l = $0; l.id = f(l.id); return l }
        var remapped: [String: [GTask]] = [:]
        for (listID, tasks) in tasksByList {
            remapped[f(listID)] = tasks.map { var t = $0; t.id = f(t.id); t.parent = t.parent.map(f); return t }
        }
        tasksByList = remapped
        pendingOps = pendingOps.map { PendingOp(id: $0.id, op: $0.op.mapIDs(f)) }
        if let s = selectedListID { selectedListID = f(s) }
        if let s = selectedTaskID { selectedTaskID = f(s) }
        persistQueue()
        persistSnapshot()
    }

    /// The current ID for something that may have had a local ID.
    func resolvedID(_ id: String) -> String { idRemaps[id] ?? id }

    // MARK: Local application

    private func enqueue(_ op: SyncOp) {
        applyLocally(op)
        pendingOps.append(PendingOp(op: op))
        persistQueue()
        persistSnapshot()
        Task { await refresh() }
    }

    private func applyLocally(_ op: SyncOp) {
        switch op {
        case let .createTask(tempID, listID, title, notes, due, parent, position):
            guard tasksByList[listID]?.contains(where: { $0.id == tempID }) != true else { return }
            let task = GTask(id: tempID, title: title, notes: notes, status: "needsAction", due: due, parent: parent, position: position)
            tasksByList[listID, default: []].append(task)

        case let .patchTask(listID, taskID, patch):
            guard let i = tasksByList[listID]?.firstIndex(where: { $0.id == taskID }) else { return }
            patch.apply(to: &tasksByList[listID]![i])

        case let .deleteTask(listID, taskID):
            tasksByList[listID]?.removeAll { $0.id == taskID || $0.parent == taskID }

        case let .moveTask(taskID, from, to):
            let moving = tasks(in: from).filter { $0.id == taskID || $0.parent == taskID }
            guard !moving.isEmpty else { return }
            tasksByList[from]?.removeAll { $0.id == taskID || $0.parent == taskID }
            tasksByList[to, default: []] += moving.map { t in
                var t = t
                if t.id == taskID { t.parent = nil; t.position = LocalPosition.top() }
                return t
            }

        case let .createList(tempID, title):
            guard !lists.contains(where: { $0.id == tempID }) else { return }
            lists.append(TaskList(id: tempID, title: title))
            tasksByList[tempID] = tasksByList[tempID] ?? []

        case let .renameList(listID, title):
            if let i = lists.firstIndex(where: { $0.id == listID }) { lists[i].title = title }

        case let .deleteList(listID):
            lists.removeAll { $0.id == listID }
            tasksByList[listID] = nil
        }
    }

    private func persistSnapshot() {
        guard !isDemo else { return }
        LocalStore.save(LocalStore.Snapshot(lists: lists, tasksByList: tasksByList, lastSynced: lastSynced))
    }

    private func persistQueue() {
        guard !isDemo else { return }
        LocalStore.save(pendingOps)
    }

    // MARK: Task mutations (instant, synced in the background)

    func addTask(title: String, listID: String?, parent: String? = nil, due: Date? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let listID, !title.isEmpty else { return }
        enqueue(.createTask(
            tempID: LocalID.make(), listID: listID, title: title, notes: nil,
            due: due.map(GDate.formatDue), parent: parent,
            position: parent == nil ? LocalPosition.top() : LocalPosition.bottom()
        ))
    }

    func toggleCompleted(_ task: GTask, listID: String?) {
        guard let listID else { return }
        enqueue(.patchTask(listID: listID, taskID: task.id, patch: TaskPatch(status: task.isCompleted ? "needsAction" : "completed")))
    }

    func updateTask(_ task: GTask, listID: String?, title: String, notes: String, due: Date?) {
        guard let listID else { return }
        var patch = TaskPatch()
        if title != (task.title ?? "") { patch.title = title }
        if notes != (task.notes ?? "") { patch.notes = notes }
        let newDue = due.map(GDate.formatDue)
        if newDue != task.dueDate.map(GDate.formatDue) {
            if let newDue { patch.due = newDue } else { patch.clearDue = true }
        }
        guard !patch.isEmpty else { return }
        enqueue(.patchTask(listID: listID, taskID: task.id, patch: patch))
    }

    func deleteTask(_ task: GTask, listID: String?) {
        guard let listID else { return }
        if selectedTaskID == task.id { selectedTaskID = nil }
        enqueue(.deleteTask(listID: listID, taskID: task.id))
    }

    func moveTask(_ task: GTask, from listID: String?, to destination: String) {
        guard let listID, listID != destination else { return }
        if selectedTaskID == task.id { selectedTaskID = nil }
        enqueue(.moveTask(taskID: task.id, from: listID, to: destination))
    }

    // MARK: List mutations

    func createList(title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let tempID = LocalID.make()
        enqueue(.createList(tempID: tempID, title: title))
        selectedListID = tempID
    }

    func renameList(_ list: TaskList, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != list.title else { return }
        enqueue(.renameList(listID: list.id, title: title))
    }

    func deleteList(_ list: TaskList) {
        enqueue(.deleteList(listID: list.id))
        if selectedListID == list.id { selectedListID = lists.first?.id }
    }

    // MARK: Demo data

    func loadDemo(lists: [TaskList], tasks: [String: [GTask]], selectedListID: String?, selectedTaskID: String? = nil,
                  pendingChanges: Int = 0, offline: Bool = false, lastSynced: Date? = Date()) {
        precondition(isDemo)
        phase = .signedIn
        self.lists = lists
        tasksByList = tasks
        self.selectedListID = selectedListID
        self.selectedTaskID = selectedTaskID
        pendingOps = (0..<pendingChanges).map { _ in PendingOp(op: .deleteList(listID: "demo")) }
        networkAvailable = !offline
        self.lastSynced = lastSynced
    }
}
