import Foundation
import EventKit

// MARK: - Types

struct CalendarJSON: Codable {
    let title: String
    let source: String
    let color: String
    let allowsContentModifications: Bool
}

struct EventJSON: Codable {
    let eventIdentifier: String
    let title: String
    let notes: String
    let startDate: String
    let endDate: String
    let isAllDay: Bool
    let calendar: String
    let hasRecurrenceRules: Bool
    let recurrenceRule: String?
}

struct CalendarsResponse: Codable { let calendars: [CalendarJSON] }
struct EventsResponse: Codable { let calendar: String; let events: [EventJSON] }
struct EventCreateResponse: Codable { let success: Bool; let eventIdentifier: String; let message: String }

// MARK: - Handlers

func handleGetCalendars() -> HTTPResponse {
    let calendars = eventStore.calendars(for: .event)
    let items = calendars.map { cal in
        CalendarJSON(
            title: cal.title,
            source: cal.source.title,
            color: hexColor(from: cal.cgColor),
            allowsContentModifications: cal.allowsContentModifications
        )
    }
    return jsonResponse(CalendarsResponse(calendars: items))
}

func handleGetEvents(calendarName: String, req: HTTPRequest) -> HTTPResponse {
    guard let startStr = req.queryParams["start"],
          let endStr = req.queryParams["end"] else {
        return jsonError("start and end query parameters are required", status: 400)
    }

    guard let startComponents = parseDateString(startStr),
          let endComponents = parseDateString(endStr),
          let startDate = Calendar.current.date(from: startComponents),
          let endDate = Calendar.current.date(from: endComponents) else {
        return jsonError("Invalid date format", status: 400)
    }

    let allCalendars = eventStore.calendars(for: .event)
    let calendarsArray: [EKCalendar]

    // Special "__ALL__" name to query all calendars at once
    if calendarName == "__ALL__" {
        calendarsArray = allCalendars
    } else {
        guard let calendar = allCalendars.first(where: { $0.title == calendarName }) else {
            return jsonError("Calendar not found: \(calendarName)", status: 404)
        }
        calendarsArray = [calendar]
    }

    let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendarsArray)
    let events = eventStore.events(matching: predicate)

    let items = events.map { event -> EventJSON in
        let startStr = formatDateComponents(
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.startDate),
            isAllDay: event.isAllDay
        )
        let endStr = formatDateComponents(
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.endDate),
            isAllDay: event.isAllDay
        )
        let recurrenceRule: String? = event.recurrenceRules?.first.map { serializeRecurrenceRule($0) }

        return EventJSON(
            eventIdentifier: event.eventIdentifier,
            title: event.title ?? "",
            notes: event.notes ?? "",
            startDate: startStr,
            endDate: endStr,
            isAllDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            hasRecurrenceRules: event.hasRecurrenceRules,
            recurrenceRule: recurrenceRule
        )
    }

    return jsonResponse(EventsResponse(calendar: calendarName, events: items))
}

func handleCreateEvent(req: HTTPRequest) -> HTTPResponse {
    guard let body = req.jsonBody(),
          let title = body["title"] as? String,
          let calendarName = body["calendar"] as? String,
          let startDateStr = body["startDate"] as? String,
          let endDateStr = body["endDate"] as? String else {
        return jsonError("title, calendar, startDate, and endDate are required", status: 400)
    }

    guard let startComponents = parseDateString(startDateStr),
          let endComponents = parseDateString(endDateStr),
          let startDate = Calendar.current.date(from: startComponents),
          let endDate = Calendar.current.date(from: endComponents) else {
        return jsonError("Invalid date format", status: 400)
    }

    let calendars = eventStore.calendars(for: .event)
    guard let calendar = calendars.first(where: { $0.title == calendarName }) else {
        return jsonError("Calendar not found: \(calendarName)", status: 404)
    }

    let event = EKEvent(eventStore: eventStore)
    event.title = title
    event.calendar = calendar
    event.startDate = startDate
    event.endDate = endDate
    event.isAllDay = body["isAllDay"] as? Bool ?? false
    event.notes = body["notes"] as? String ?? ""

    if let ruleStr = body["recurrenceRule"] as? String,
       let rule = parseRecurrenceRule(ruleStr) {
        event.addRecurrenceRule(rule)
    }

    do {
        try eventStore.save(event, span: .thisEvent)
        return jsonResponse(EventCreateResponse(
            success: true, eventIdentifier: event.eventIdentifier, message: "Event created"
        ))
    } catch {
        return jsonError("Failed to create event: \(error.localizedDescription)")
    }
}

func handleUpdateEvent(eventId: String, req: HTTPRequest) -> HTTPResponse {
    guard let event = eventStore.event(withIdentifier: eventId) else {
        return jsonError("Event not found: \(eventId)", status: 404)
    }
    let body = req.jsonBody() ?? [:]

    if let title = body["title"] as? String { event.title = title }
    if let notes = body["notes"] as? String { event.notes = notes }

    if let startStr = body["startDate"] as? String, let endStr = body["endDate"] as? String {
        if let sc = parseDateString(startStr), let ec = parseDateString(endStr),
           let sd = Calendar.current.date(from: sc), let ed = Calendar.current.date(from: ec) {
            event.startDate = sd
            event.endDate = ed
            event.isAllDay = body["isAllDay"] as? Bool ?? event.isAllDay
        }
    }

    do {
        try eventStore.save(event, span: .thisEvent)
        return jsonSuccess("Event updated")
    } catch {
        return jsonError("Failed to update event: \(error.localizedDescription)")
    }
}

func handleDeleteEvent(eventId: String, req: HTTPRequest) -> HTTPResponse {
    guard let event = eventStore.event(withIdentifier: eventId) else {
        return jsonError("Event not found: \(eventId)", status: 404)
    }
    let span: EKSpan = req.queryParams["span"] == "future" ? .futureEvents : .thisEvent
    do {
        try eventStore.remove(event, span: span, commit: true)
        return jsonSuccess("Event deleted")
    } catch {
        return jsonError("Failed to delete event: \(error.localizedDescription)")
    }
}

// MARK: - Helpers

func formatDateComponents(_ components: DateComponents, isAllDay: Bool) -> String {
    if isAllDay {
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
    guard let date = Calendar.current.date(from: components) else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
}

func hexColor(from cgColor: CGColor?) -> String {
    guard let c = cgColor, let components = c.components, components.count >= 3 else { return "#808080" }
    return String(format: "#%02X%02X%02X",
                  Int(components[0] * 255), Int(components[1] * 255), Int(components[2] * 255))
}

// MARK: - Recurrence Rules (simplified iCalendar RRULE format)

func parseRecurrenceRule(_ ruleString: String) -> EKRecurrenceRule? {
    guard !ruleString.isEmpty else { return nil }

    var frequency: EKRecurrenceFrequency?
    var daysOfWeek: [EKRecurrenceDayOfWeek]?
    var interval = 1
    var end: EKRecurrenceEnd?

    for part in ruleString.components(separatedBy: ";") {
        let kv = part.components(separatedBy: "=")
        guard kv.count == 2 else { continue }

        switch kv[0] {
        case "FREQ":
            switch kv[1] {
            case "DAILY": frequency = .daily
            case "WEEKLY": frequency = .weekly
            case "MONTHLY": frequency = .monthly
            case "YEARLY": frequency = .yearly
            default: break
            }
        case "BYDAY":
            let dayMap: [String: EKWeekday] = [
                "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
                "TH": .thursday, "FR": .friday, "SA": .saturday
            ]
            daysOfWeek = kv[1].components(separatedBy: ",").compactMap { dayMap[$0].map { EKRecurrenceDayOfWeek($0) } }
        case "INTERVAL":
            interval = Int(kv[1]) ?? 1
        case "COUNT":
            if let count = Int(kv[1]) { end = EKRecurrenceEnd(occurrenceCount: count) }
        case "UNTIL":
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = kv[1].contains("T") ? "yyyyMMdd'T'HHmmss" : "yyyyMMdd"
            if let date = formatter.date(from: kv[1]) { end = EKRecurrenceEnd(end: date) }
        default: break
        }
    }

    guard let freq = frequency else { return nil }
    return EKRecurrenceRule(
        recurrenceWith: freq, interval: interval,
        daysOfTheWeek: daysOfWeek, daysOfTheMonth: nil,
        monthsOfTheYear: nil, weeksOfTheYear: nil,
        daysOfTheYear: nil, setPositions: nil, end: end
    )
}

func serializeRecurrenceRule(_ rule: EKRecurrenceRule) -> String {
    var parts: [String] = []
    switch rule.frequency {
    case .daily: parts.append("FREQ=DAILY")
    case .weekly: parts.append("FREQ=WEEKLY")
    case .monthly: parts.append("FREQ=MONTHLY")
    case .yearly: parts.append("FREQ=YEARLY")
    @unknown default: parts.append("FREQ=DAILY")
    }
    if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
    if let days = rule.daysOfTheWeek, !days.isEmpty {
        let dayMap: [EKWeekday: String] = [
            .sunday: "SU", .monday: "MO", .tuesday: "TU", .wednesday: "WE",
            .thursday: "TH", .friday: "FR", .saturday: "SA"
        ]
        parts.append("BYDAY=" + days.compactMap { dayMap[$0.dayOfTheWeek] }.joined(separator: ","))
    }
    if let end = rule.recurrenceEnd {
        if end.occurrenceCount > 0 { parts.append("COUNT=\(end.occurrenceCount)") }
    }
    return parts.joined(separator: ";")
}
