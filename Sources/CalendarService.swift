import EventKit
import SwiftUI

struct CalendarEvent {
    let id: String          // уникален для конкретного вхождения повторяющегося события
    let eventID: String     // eventIdentifier в EventKit
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let calendarName: String
    let location: String?
    let allDay: Bool
}

struct EventDetails {
    let location: String?
    let notes: String?
    let url: URL?
    let calendar: String
    let recurring: Bool
}

struct CreatedEvent {
    let calendarTitle: String
    let eventID: String
}

struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let source: String
    let color: Color
    let writable: Bool

    var looksLikeYandex: Bool {
        let s = (source + " " + title).lowercased()
        return s.contains("yandex") || s.contains("яндекс")
    }
}

/// Блок плана, который выгружается в календарь.
struct PlanExport {
    let key: String
    let title: String
    let start: Date
    let end: Date
}

enum CalendarError: LocalizedError {
    case noCalendar
    case notFound

    var errorDescription: String? {
        switch self {
        case .noCalendar: return "Календарь для записи недоступен"
        case .notFound: return "Событие не найдено"
        }
    }
}

/// Связь с системным Календарём macOS. Яндекс, Google, iCloud и т. п. подключаются в
/// «Учётных записях интернета», а синхронизацию с сервером делает сама macOS.
final class CalendarService {
    static let marker = "ostrovok-block:"

    private let ekStore = EKEventStore()
    private var cache: [Date: [CalendarEvent]] = [:]
    var onChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ekStore, queue: .main) { [weak self] _ in
            self?.invalidate()
        }
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        if hasAccess { completion(true); return }
        ekStore.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.invalidate()
                completion(granted)
            }
        }
    }

    func invalidate() {
        cache.removeAll()
        onChange?()
    }

    /// Подтянуть свежие данные с серверов (Яндекс и т. п.).
    func refresh() {
        guard hasAccess else { return }
        ekStore.refreshSourcesIfNecessary()
        invalidate()
    }

    // MARK: - Календари

    func calendars() -> [CalendarInfo] {
        guard hasAccess else { return [] }
        return ekStore.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                                color: Color(nsColor: $0.color), writable: $0.allowsContentModifications) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func writableCalendar(_ id: String?) -> EKCalendar? {
        guard hasAccess, let id, let cal = ekStore.calendar(withIdentifier: id), cal.allowsContentModifications else { return nil }
        return cal
    }

    // MARK: - Чтение

    /// Ключ блока плана, если событие выгружено Островком (такие не показываем второй раз).
    static func blockKey(of ev: EKEvent) -> String? {
        if let url = ev.url, url.scheme == "ostrovok" { return url.lastPathComponent }
        if let notes = ev.notes, let r = notes.range(of: marker) {
            return String(notes[r.upperBound...].prefix(36))
        }
        return nil
    }

    func events(on day: Date, hidden: Set<String>) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        if let cached = cache[start] { return cached }
        let calendars = ekStore.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { cache[start] = []; return [] }
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let predicate = ekStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let result = ekStore.events(matching: predicate)
            .filter { CalendarService.blockKey(of: $0) == nil }
            .map { ev in
                CalendarEvent(
                    id: "\(ev.eventIdentifier ?? UUID().uuidString)-\(ev.startDate.timeIntervalSince1970)",
                    eventID: ev.eventIdentifier ?? "",
                    title: ev.title ?? "Событие",
                    start: ev.startDate,
                    end: ev.endDate,
                    color: Color(nsColor: ev.calendar.color),
                    calendarName: ev.calendar.title,
                    location: ev.location.flatMap { $0.isEmpty ? nil : $0 },
                    allDay: ev.isAllDay
                )
            }
        cache[start] = result
        return result
    }

    // MARK: - Запись

    /// Создаёт событие (при `weekdays` — еженедельный повтор). Возвращает название календаря.
    func createEvent(title: String, start: Date, end: Date, weekdays: [Int], calendarID: String?,
                     location: String? = nil, allDay: Bool = false) throws -> CreatedEvent {
        guard let cal = writableCalendar(calendarID) else { throw CalendarError.noCalendar }
        let ev = EKEvent(eventStore: ekStore)
        ev.calendar = cal
        ev.title = title
        ev.startDate = start
        ev.endDate = end
        ev.isAllDay = allDay
        ev.location = location
        if !weekdays.isEmpty {
            let days = weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
            ev.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
                                                  daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                                  daysOfTheYear: nil, setPositions: nil, end: nil))
        }
        try ekStore.save(ev, span: .futureEvents, commit: true)
        invalidate()
        return CreatedEvent(calendarTitle: cal.title, eventID: ev.eventIdentifier ?? "")
    }

    /// Подробности события: место, заметки, ссылка.
    func details(eventID: String, start: Date) -> EventDetails? {
        guard hasAccess else { return nil }
        let predicate = ekStore.predicateForEvents(withStart: start.addingTimeInterval(-60),
                                                   end: start.addingTimeInterval(86400), calendars: nil)
        let ev = ekStore.events(matching: predicate)
            .first { $0.eventIdentifier == eventID && abs($0.startDate.timeIntervalSince(start)) < 1 }
            ?? ekStore.event(withIdentifier: eventID)
        guard let ev else { return nil }
        let notes = ev.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventDetails(location: ev.location.flatMap { $0.isEmpty ? nil : $0 },
                            notes: (notes?.isEmpty ?? true) ? nil : notes,
                            url: ev.url, calendar: ev.calendar.title, recurring: ev.hasRecurrenceRules)
    }

    /// Удаляет одно вхождение события (у повторяющихся — только этот день).
    func deleteOccurrence(eventID: String, start: Date) throws {
        let predicate = ekStore.predicateForEvents(withStart: start.addingTimeInterval(-60),
                                                   end: start.addingTimeInterval(60), calendars: nil)
        guard let ev = ekStore.events(matching: predicate)
            .first(where: { $0.eventIdentifier == eventID && abs($0.startDate.timeIntervalSince(start)) < 1 })
        else { throw CalendarError.notFound }
        try ekStore.remove(ev, span: .thisEvent, commit: true)
        invalidate()
    }

    /// Приводит выгруженные блоки плана в календаре к нужному состоянию: создаёт новые,
    /// двигает изменённые, удаляет лишние. Трогает только события с меткой Островка.
    func syncPlan(_ blocks: [PlanExport], calendarID: String?, from: Date) {
        guard hasAccess else { return }
        let target = writableCalendar(calendarID)
        var wanted: [String: PlanExport] = [:]
        if target != nil { for b in blocks { wanted[b.key] = b } }

        let latest = blocks.map(\.end).max() ?? from
        let horizon = max(from.addingTimeInterval(15 * 86400), latest.addingTimeInterval(86400))
        let predicate = ekStore.predicateForEvents(withStart: from, end: horizon, calendars: nil)

        var seen = Set<String>()
        var changed = false
        for ev in ekStore.events(matching: predicate) {
            guard let key = CalendarService.blockKey(of: ev) else { continue }
            if let b = wanted[key], let target, ev.calendar.calendarIdentifier == target.calendarIdentifier, !seen.contains(key) {
                seen.insert(key)
                if ev.title != b.title || ev.startDate != b.start || ev.endDate != b.end {
                    ev.title = b.title
                    ev.startDate = b.start
                    ev.endDate = b.end
                    if (try? ekStore.save(ev, span: .thisEvent, commit: false)) != nil { changed = true }
                }
            } else {
                if (try? ekStore.remove(ev, span: .thisEvent, commit: false)) != nil { changed = true }
            }
        }
        if let target {
            for (key, b) in wanted where !seen.contains(key) {
                let ev = EKEvent(eventStore: ekStore)
                ev.calendar = target
                ev.title = b.title
                ev.startDate = b.start
                ev.endDate = b.end
                ev.url = URL(string: "ostrovok://block/\(key)")
                ev.notes = "Запланировано в Островке\n\(CalendarService.marker)\(key)"
                if (try? ekStore.save(ev, span: .thisEvent, commit: false)) != nil { changed = true }
            }
        }
        if changed {
            do { try ekStore.commit() } catch { NSLog("Ostrovok: синхронизация плана с календарём: \(error)") }
        }
    }
}
