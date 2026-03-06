import Foundation
import EventKit

// MARK: - Types

struct ReminderJSON: Codable {
    let name: String
    let notes: String
    let completed: Bool
    let priority: Int
    let due_date: String?
}

struct ListsResponse: Codable { let lists: [String] }
struct RemindersResponse: Codable { let list: String; let reminders: [ReminderJSON] }

// MARK: - Handlers

func handleGetLists() -> HTTPResponse {
    let calendars = eventStore.calendars(for: .reminder)
    return jsonResponse(ListsResponse(lists: calendars.map { $0.title }))
}

func handleGetReminders(listName: String) -> HTTPResponse {
    guard let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) else {
        return jsonError("List not found: \(listName)", status: 404)
    }

    // EventKit's reminder fetch is async. Semaphore makes it synchronous for our handler.
    let predicate = eventStore.predicateForIncompleteReminders(
        withDueDateStarting: nil, ending: nil, calendars: [calendar]
    )
    let semaphore = DispatchSemaphore(value: 0)
    var fetched: [EKReminder] = []

    eventStore.fetchReminders(matching: predicate) { reminders in
        fetched = reminders ?? []
        semaphore.signal()
    }
    semaphore.wait()

    let items = fetched.map { reminder -> ReminderJSON in
        let dueDateString: String? = reminder.dueDateComponents?.date.map {
            ISO8601DateFormatter().string(from: $0)
        }
        return ReminderJSON(
            name: reminder.title ?? "",
            notes: reminder.notes ?? "",
            completed: reminder.isCompleted,
            priority: reminder.priority,
            due_date: dueDateString
        )
    }

    return jsonResponse(RemindersResponse(list: listName, reminders: items))
}

func handleCreateReminder(req: HTTPRequest) -> HTTPResponse {
    guard let body = req.jsonBody(),
          let title = body["title"] as? String,
          let listName = body["list"] as? String else {
        return jsonError("title and list are required", status: 400)
    }

    guard let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) else {
        return jsonError("List not found: \(listName)", status: 404)
    }

    let reminder = EKReminder(eventStore: eventStore)
    reminder.title = title
    reminder.notes = body["notes"] as? String ?? ""
    reminder.calendar = calendar
    reminder.priority = body["priority"] as? Int ?? 0

    if let dueDateStr = body["dueDate"] as? String, !dueDateStr.isEmpty {
        if let components = parseDateString(dueDateStr) {
            reminder.dueDateComponents = components
        }
    }

    do {
        try eventStore.save(reminder, commit: true)
        return jsonSuccess("Reminder created")
    } catch {
        return jsonError("Failed to save: \(error.localizedDescription)")
    }
}

func handleCompleteReminder(name: String, req: HTTPRequest) -> HTTPResponse {
    let body = req.jsonBody() ?? [:]
    guard let listName = body["list"] as? String else {
        return jsonError("list is required in body", status: 400)
    }

    guard let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) else {
        return jsonError("List not found: \(listName)", status: 404)
    }

    let predicate = eventStore.predicateForReminders(in: [calendar])
    let semaphore = DispatchSemaphore(value: 0)
    var found = false

    eventStore.fetchReminders(matching: predicate) { reminders in
        if let reminder = reminders?.first(where: { $0.title == name && !$0.isCompleted }) {
            reminder.isCompleted = true
            try? eventStore.save(reminder, commit: true)
            found = true
        }
        semaphore.signal()
    }
    semaphore.wait()

    return found ? jsonSuccess("Reminder completed") : jsonError("Reminder not found: \(name)", status: 404)
}

func handleUpdateReminder(name: String, req: HTTPRequest) -> HTTPResponse {
    let body = req.jsonBody() ?? [:]
    guard let listName = body["list"] as? String else {
        return jsonError("list is required in body", status: 400)
    }

    guard let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) else {
        return jsonError("List not found: \(listName)", status: 404)
    }

    let predicate = eventStore.predicateForReminders(in: [calendar])
    let semaphore = DispatchSemaphore(value: 0)
    var found = false

    eventStore.fetchReminders(matching: predicate) { reminders in
        if let reminder = reminders?.first(where: { $0.title == name && !$0.isCompleted }) {
            if let newTitle = body["title"] as? String { reminder.title = newTitle }
            if let newNotes = body["notes"] as? String { reminder.notes = newNotes }
            if let newDueDate = body["dueDate"] as? String {
                reminder.dueDateComponents = newDueDate.isEmpty ? nil : parseDateString(newDueDate)
            }
            if let newPriority = body["priority"] as? Int { reminder.priority = newPriority }
            try? eventStore.save(reminder, commit: true)
            found = true
        }
        semaphore.signal()
    }
    semaphore.wait()

    return found ? jsonSuccess("Reminder updated") : jsonError("Reminder not found: \(name)", status: 404)
}

func handleDeleteReminder(name: String, req: HTTPRequest) -> HTTPResponse {
    guard let listName = req.queryParams["list"] else {
        return jsonError("list query parameter is required", status: 400)
    }

    guard let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == listName }) else {
        return jsonError("List not found: \(listName)", status: 404)
    }

    let predicate = eventStore.predicateForReminders(in: [calendar])
    let semaphore = DispatchSemaphore(value: 0)
    var found = false

    eventStore.fetchReminders(matching: predicate) { reminders in
        if let reminder = reminders?.first(where: { $0.title == name }) {
            try? eventStore.remove(reminder, commit: true)
            found = true
        }
        semaphore.signal()
    }
    semaphore.wait()

    return found ? jsonSuccess("Reminder deleted") : jsonError("Reminder not found: \(name)", status: 404)
}
