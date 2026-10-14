import Foundation

// MARK: - Pending operations

/// A partial task update. Empty `notes` clears the notes; `clearDue` clears the due date.
struct TaskPatch: Codable, Equatable {
    var title: String?
    var notes: String?
    var due: String?
    var clearDue = false
    var status: String?

    var isEmpty: Bool { title == nil && notes == nil && due == nil && !clearDue && status == nil }

    var apiFields: [String: Any] {
        var f: [String: Any] = [:]
        if let title { f["title"] = title }
        if let notes { f["notes"] = notes.isEmpty ? NSNull() : notes }
        if let due { f["due"] = due } else if clearDue { f["due"] = NSNull() }
        if let status {
            f["status"] = status
            if status == "needsAction" { f["completed"] = NSNull() }
        }
        return f
    }

    func apply(to task: inout GTask) {
        if let title { task.title = title }
        if let notes { task.notes = notes.isEmpty ? nil : notes }
        if let due { task.due = due } else if clearDue { task.due = nil }
        if let status {
            task.status = status
            task.completed = status == "completed" ? (task.completed ?? ISO8601DateFormatter().string(from: Date())) : nil
        }
    }
}

/// A change made locally that still has to be sent to Google.
/// IDs starting with `local-` refer to items not yet created on the server.
enum SyncOp: Codable, Equatable {
    case createTask(tempID: String, listID: String, title: String, notes: String?, due: String?, parent: String?, position: String)
    case patchTask(listID: String, taskID: String, patch: TaskPatch)
    case deleteTask(listID: String, taskID: String)
    case moveTask(taskID: String, from: String, to: String)
    case createList(tempID: String, title: String)
    case renameList(listID: String, title: String)
    case deleteList(listID: String)

    /// Rewrites every ID in the operation (used when a local ID gets its server ID).
    func mapIDs(_ f: (String) -> String) -> SyncOp {
        switch self {
        case let .createTask(t, l, title, notes, due, parent, pos):
            return .createTask(tempID: f(t), listID: f(l), title: title, notes: notes, due: due, parent: parent.map(f), position: pos)
        case let .patchTask(l, t, p): return .patchTask(listID: f(l), taskID: f(t), patch: p)
        case let .deleteTask(l, t): return .deleteTask(listID: f(l), taskID: f(t))
        case let .moveTask(t, from, to): return .moveTask(taskID: f(t), from: f(from), to: f(to))
        case let .createList(t, title): return .createList(tempID: f(t), title: title)
        case let .renameList(l, title): return .renameList(listID: f(l), title: title)
        case let .deleteList(l): return .deleteList(listID: f(l))
        }
    }
}

struct PendingOp: Codable, Identifiable, Equatable {
    var id = UUID()
    var op: SyncOp
}

enum LocalID {
    static func make() -> String { "local-\(UUID().uuidString)" }
    static func isLocal(_ id: String) -> Bool { id.hasPrefix("local-") }
}

/// Positions for tasks created offline. Server positions are zero-padded digits, so
/// "!" sorts before all of them (top of list) and "~" after them (end of subtasks).
enum LocalPosition {
    static func top() -> String {
        String(format: "!%015.0f", 1e15 - Date().timeIntervalSince1970 * 1000)
    }
    static func bottom() -> String {
        String(format: "~%015.0f", Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Disk cache

/// Persists the last known data and the pending-change queue in Application Support.
enum LocalStore {
    struct Snapshot: Codable {
        var lists: [TaskList]
        var tasksByList: [String: [GTask]]
        var lastSynced: Date?
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GoogleTasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var snapshotURL: URL { directory.appendingPathComponent("cache.json") }
    private static var queueURL: URL { directory.appendingPathComponent("pending.json") }

    static func loadSnapshot() -> Snapshot? { read(Snapshot.self, from: snapshotURL) }
    static func loadQueue() -> [PendingOp] { read([PendingOp].self, from: queueURL) ?? [] }
    static func save(_ snapshot: Snapshot) { write(snapshot, to: snapshotURL) }
    static func save(_ queue: [PendingOp]) { write(queue, to: queueURL) }

    static func clear() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: queueURL)
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Error classification

extension Error {
    /// True for connectivity problems that should be retried quietly later.
    var isNetworkError: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
             .callIsActive, .secureConnectionFailed, .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
}

/// Shared session with short timeouts, so a dead connection fails fast instead of hanging.
let networkSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 30
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
}()
