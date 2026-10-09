import Foundation
import SwiftUI

// MARK: - Данные

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
}

struct TaskItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var projectID: UUID?
    var estimate: Int            // минуты
    var deadline: Date?
    var priority = false
    var done = false
    var doneAt: Date?
    var createdAt = Date()
    // Домашки (из LMS или добавленные на странице «ДЗ»)
    var homework: Bool?
    var courseID: UUID?
    var externalID: String?      // UID события в календаре LMS
    var customEstimate: Bool?    // оценку поменяли вручную — не перезаписывать оценкой предмета
    var missedAt: Date?          // не успел — вернулась в список «Не успел»

    var isHomework: Bool { homework == true }
}

/// Предмет (курс в LMS). Оценка — сколько обычно уходит на одно ДЗ по нему.
struct Course: Codable, Identifiable, Hashable {
    var id = UUID()
    var key: String              // как называется в LMS (короткое имя курса)
    var name: String             // как показывать
    var colorIndex: Int
    var estimate: Int            // минуты
}

struct EventItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var projectID: UUID?
    var start: Date
    var end: Date
    /// Пусто — разовое событие. Иначе повтор каждую неделю (1 = вс, 2 = пн … 7 = сб).
    var weekdays: [Int] = []
    var location: String?
    var allDay: Bool?
}

/// Вложение в чате-заметках: файл лежит в папке attachments рядом с данными.
struct ChatAttachment: Codable, Identifiable, Hashable {
    var id = UUID()
    var storedName: String
    var originalName: String
    var isImage: Bool
    var size: Int64
}

/// Сообщение в чате проекта (заметка для себя).
struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var chatID: UUID
    var date = Date()
    var text: String
    var attachments: [ChatAttachment] = []
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var projectID: UUID?
    var createdAt = Date()
}

/// Кусок времени, выделенный под задачу в расписании.
struct PlanBlock: Codable, Identifiable, Hashable {
    var id = UUID()
    var taskID: UUID
    var start: Date
    var end: Date
    var manual: Bool?            // поставлен вручную — «Распределить» его не трогает
    var toCalendar: Bool?        // всегда выгружать в календарь
    var hwAuto: Bool?            // поставлен «Разложить автоматически» на странице ДЗ
}

struct AppSettings: Codable, Equatable {
    var dayStartHour = 9
    var dayEndHour = 23
    var breakMinutes = 10
    var maxChunk = 90
    var defaultEstimate = 30
    var useCalendar = false
    var wideCollapsed = false
    var showMenuBarIcon = true
    var hiddenCalendarIDs: [String] = []
    var writeCalendarID: String?
    var exportPlan = false
    var openOnHover = false      // false — открывать только по клику
    var closeOnLeave = true      // сворачивать, когда мышь уходит с островка
    var homeworkFeedURL = ""     // ссылка экспорта календаря Moodle (.ics)
    var homeworkLastSync: Date?
    var hwDailyCap = 180         // не больше стольких минут ДЗ в день при авто-раскладке
    var deepseekModel = "deepseek-v4-flash"
    var importAutoAdd = false    // мероприятия со скриншота добавлять без подтверждения
    var deepseekKeySaved = false // сам ключ — в Связке ключей

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        dayStartHour = try c.decodeIfPresent(Int.self, forKey: .dayStartHour) ?? d.dayStartHour
        dayEndHour = try c.decodeIfPresent(Int.self, forKey: .dayEndHour) ?? d.dayEndHour
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? d.breakMinutes
        maxChunk = try c.decodeIfPresent(Int.self, forKey: .maxChunk) ?? d.maxChunk
        defaultEstimate = try c.decodeIfPresent(Int.self, forKey: .defaultEstimate) ?? d.defaultEstimate
        useCalendar = try c.decodeIfPresent(Bool.self, forKey: .useCalendar) ?? d.useCalendar
        wideCollapsed = try c.decodeIfPresent(Bool.self, forKey: .wideCollapsed) ?? d.wideCollapsed
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
        hiddenCalendarIDs = try c.decodeIfPresent([String].self, forKey: .hiddenCalendarIDs) ?? []
        writeCalendarID = try c.decodeIfPresent(String.self, forKey: .writeCalendarID)
        exportPlan = try c.decodeIfPresent(Bool.self, forKey: .exportPlan) ?? d.exportPlan
        openOnHover = try c.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? d.openOnHover
        closeOnLeave = try c.decodeIfPresent(Bool.self, forKey: .closeOnLeave) ?? d.closeOnLeave
        homeworkFeedURL = try c.decodeIfPresent(String.self, forKey: .homeworkFeedURL) ?? ""
        homeworkLastSync = try c.decodeIfPresent(Date.self, forKey: .homeworkLastSync)
        hwDailyCap = try c.decodeIfPresent(Int.self, forKey: .hwDailyCap) ?? d.hwDailyCap
        deepseekModel = try c.decodeIfPresent(String.self, forKey: .deepseekModel) ?? d.deepseekModel
        importAutoAdd = try c.decodeIfPresent(Bool.self, forKey: .importAutoAdd) ?? d.importAutoAdd
        deepseekKeySaved = try c.decodeIfPresent(Bool.self, forKey: .deepseekKeySaved) ?? d.deepseekKeySaved
    }
}

struct AppData: Codable {
    var projects: [Project] = []
    var tasks: [TaskItem] = []
    var events: [EventItem] = []
    var blocks: [PlanBlock] = []
    var courses: [Course] = []
    var notes: [Note] = []
    var messages: [ChatMessage] = []
    var settings = AppSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        tasks = try c.decodeIfPresent([TaskItem].self, forKey: .tasks) ?? []
        events = try c.decodeIfPresent([EventItem].self, forKey: .events) ?? []
        blocks = try c.decodeIfPresent([PlanBlock].self, forKey: .blocks) ?? []
        courses = try c.decodeIfPresent([Course].self, forKey: .courses) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }
}

// MARK: - Расписание дня

enum AgendaKind: Hashable {
    case event(UUID)
    case block(UUID, task: UUID)
    case calendar(String)   // eventIdentifier
}

struct AgendaItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let kind: AgendaKind
    var done = false
    var recurring = false
    var projectName: String? = nil
    var calendarName: String? = nil
    var location: String? = nil
    var allDay = false

    var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
    var isTaskBlock: Bool { if case .block = kind { return true } else { return false } }
}

// MARK: - Цвета

enum Palette {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.45, blue: 0.42), // коралловый
        Color(red: 1.00, green: 0.64, blue: 0.26), // оранжевый
        Color(red: 0.98, green: 0.84, blue: 0.32), // жёлтый
        Color(red: 0.45, green: 0.86, blue: 0.50), // зелёный
        Color(red: 0.33, green: 0.82, blue: 0.86), // бирюзовый
        Color(red: 0.42, green: 0.64, blue: 1.00), // синий
        Color(red: 0.68, green: 0.54, blue: 1.00), // фиолетовый
        Color(red: 1.00, green: 0.52, blue: 0.80), // розовый
    ]
    static let neutral = Color(white: 0.62)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.36)
    static let orange = Color(red: 1.00, green: 0.64, blue: 0.26)
    static let yellow = Color(red: 0.98, green: 0.84, blue: 0.32)

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

// MARK: - Форматирование

enum Fmt {
    static let ru = Locale(identifier: "ru_RU")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = ru
        f.dateFormat = format
        return f
    }

    private static let timeF = make("HH:mm")
    private static let dayTitleF = make("EEEE, d MMMM")
    private static let shortF = make("EE, d MMM")
    private static let weekdayF = make("EE")
    private static let dayMonthF = make("d MMM")

    static func time(_ d: Date) -> String { timeF.string(from: d) }
    static func dayMonth(_ d: Date) -> String { dayMonthF.string(from: d) }
    static func dayTitle(_ d: Date) -> String { dayTitleF.string(from: d).capitalizedFirst }
    static func shortDate(_ d: Date) -> String { shortF.string(from: d).capitalizedFirst }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)м" }
        if m == 0 { return "\(h)ч" }
        return "\(h)ч \(m)м"
    }

    static func duration(seconds: TimeInterval) -> String {
        duration(max(1, Int((seconds / 60).rounded(.up))))
    }

    /// «сегодня», «завтра», «пт», «10 окт.»
    static func dayWord(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "сегодня" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        if days == 1 { return "завтра" }
        if days == -1 { return "вчера" }
        if days > 1 && days < 7 { return weekdayF.string(from: d) }
        return dayMonthF.string(from: d)
    }

    static func when(_ d: Date, now: Date) -> String { "\(dayWord(d, now: now)) в \(time(d))" }

    static func deadline(_ d: Date, now: Date) -> (text: String, color: Color) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: d)
        let endOfDay = comps.hour == 23 && comps.minute == 59
        let suffix = endOfDay ? "" : " \(time(d))"
        if d < now { return ("просрочено", Palette.red) }
        if cal.isDate(d, inSameDayAs: now) { return ("сегодня" + suffix, Palette.orange) }
        let word = dayWord(d, now: now)
        if word == "завтра" { return ("завтра" + suffix, Palette.yellow) }
        return ("до " + word + suffix, Color.white.opacity(0.55))
    }

    static let weekdayShort = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]

    static func weekdays(_ list: [Int]) -> String {
        let order = [2, 3, 4, 5, 6, 7, 1]
        let set = Set(list)
        if set == [2, 3, 4, 5, 6] { return "по будням" }
        if set == [1, 7] { return "по выходным" }
        if set.count == 7 { return "каждый день" }
        return "по " + order.filter(set.contains).map { weekdayShort[$0 - 1] }.joined(separator: ", ")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Date {
    func roundedUp(minutes: Int) -> Date {
        let step = TimeInterval(minutes * 60)
        let t = (timeIntervalSinceReferenceDate / step).rounded(.up) * step
        return Date(timeIntervalSinceReferenceDate: t)
    }
}
