import Foundation

// MARK: - Models

struct TaskList: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var updated: String?
}

struct GTask: Codable, Identifiable, Hashable {
    var id: String
    var title: String?
    var notes: String?
    var status: String?
    var due: String?
    var completed: String?
    var parent: String?
    var position: String?
    var updated: String?
    var deleted: Bool?
    var hidden: Bool?
    var webViewLink: String?

    var isCompleted: Bool { status == "completed" }
    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(untitled)" : t
    }

    /// Google stores due dates as midnight UTC; time-of-day is not exposed by the API.
    var dueDate: Date? { due.flatMap(GDate.parseDue) }
    var completedDate: Date? { completed.flatMap(GDate.parseTimestamp) }
}

private struct Page<T: Decodable>: Decodable {
    var items: [T]?
    var nextPageToken: String?
}

enum GDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static var utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func parseTimestamp(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }

    /// Converts the API's UTC-midnight due timestamp into the same calendar day at local midnight.
    static func parseDue(_ s: String) -> Date? {
        guard let utc = parseTimestamp(s) else { return nil }
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: utc)
        return Calendar.current.date(from: comps)
    }

    /// Encodes a local calendar day as the API expects (midnight UTC of that day).
    static func formatDue(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}

enum APIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message): return "Google Tasks error (\(code)): \(message)"
        }
    }
}

// MARK: - Client

/// Thin client for the Google Tasks REST API v1.
@MainActor
final class TasksAPI {
    private let auth: OAuthManager
    private let base = URL(string: "https://tasks.googleapis.com/tasks/v1/")!

    init(auth: OAuthManager) { self.auth = auth }

    // Task lists

    func taskLists() async throws -> [TaskList] {
        try await paged(path: "users/@me/lists", query: ["maxResults": "100"])
    }

    func createList(title: String) async throws -> TaskList {
        try decode(await send("POST", "users/@me/lists", body: ["title": title]))
    }

    func renameList(id: String, title: String) async throws -> TaskList {
        try decode(await send("PATCH", "users/@me/lists/\(id)", body: ["title": title]))
    }

    func deleteList(id: String) async throws {
        _ = try await send("DELETE", "users/@me/lists/\(id)")
    }

    // Tasks

    func tasks(listID: String) async throws -> [GTask] {
        let all: [GTask] = try await paged(path: "lists/\(listID)/tasks", query: [
            "maxResults": "100",
            "showCompleted": "true",
            // Tasks completed in Google's own apps are marked hidden; include them.
            "showHidden": "true",
        ])
        return all.filter { $0.deleted != true }
    }

    func createTask(listID: String, title: String, notes: String? = nil, due: Date? = nil, parent: String? = nil) async throws -> GTask {
        var body: [String: Any] = ["title": title]
        if let notes, !notes.isEmpty { body["notes"] = notes }
        if let due { body["due"] = GDate.formatDue(due) }
        var query: [String: String] = [:]
        if let parent { query["parent"] = parent }
        return try decode(await send("POST", "lists/\(listID)/tasks", query: query, body: body))
    }

    /// Pass `NSNull()` as a value to clear a field.
    func patchTask(listID: String, taskID: String, fields: [String: Any]) async throws -> GTask {
        try decode(await send("PATCH", "lists/\(listID)/tasks/\(taskID)", body: fields))
    }

    func deleteTask(listID: String, taskID: String) async throws {
        _ = try await send("DELETE", "lists/\(listID)/tasks/\(taskID)")
    }

    func moveTask(listID: String, taskID: String, parent: String?, previous: String?, destinationListID: String? = nil) async throws -> GTask {
        var query: [String: String] = [:]
        if let destinationListID { query["destinationTasklist"] = destinationListID }
        if let parent { query["parent"] = parent }
        if let previous { query["previous"] = previous }
        return try decode(await send("POST", "lists/\(listID)/tasks/\(taskID)/move", query: query))
    }

    // MARK: Plumbing

    private func paged<T: Decodable>(path: String, query: [String: String]) async throws -> [T] {
        var results: [T] = []
        var token: String?
        repeat {
            var q = query
            if let token { q["pageToken"] = token }
            let page: Page<T> = try decode(await send("GET", path, query: q))
            results += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        return results
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, retried: Bool = false) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken(forceRefresh: retried))", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await networkSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && !retried {
            return try await send(method, path, query: query, body: body, retried: true)
        }
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status, message)
        }
        return data
    }
}
