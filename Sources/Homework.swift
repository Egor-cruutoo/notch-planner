import Foundation
import SwiftUI

// MARK: - iCalendar (.ics)

struct ICSEvent {
    var uid = ""
    var summary = ""
    var start: Date?
    var end: Date?
    var allDay = false
    var categories: String?
    var description: String?
}

enum ICSParser {
    static func parse(_ text: String) -> [ICSEvent] {
        // Склеиваем «сложенные» строки (продолжение начинается с пробела или таба).
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }

        var events: [ICSEvent] = []
        var current: ICSEvent?
        for line in lines {
            if line == "BEGIN:VEVENT" { current = ICSEvent(); continue }
            if line == "END:VEVENT" {
                if let c = current { events.append(c) }
                current = nil
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon]
            let value = String(line[line.index(after: colon)...])
            let parts = head.split(separator: ";").map(String.init)
            guard let name = parts.first?.uppercased() else { continue }
            var params: [String: String] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            switch name {
            case "UID": current!.uid = value
            case "SUMMARY": current!.summary = unescape(value)
            case "DESCRIPTION": current!.description = unescape(value)
            case "CATEGORIES": current!.categories = unescape(value)
            case "DTSTART":
                let (d, allDay) = parseDate(value, params)
                current!.start = d
                current!.allDay = allDay
            case "DTEND": current!.end = parseDate(value, params).0
            default: break
            }
        }
        return events
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\\", with: "\u{1}")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\u{1}", with: "\\")
    }

    static func parseDate(_ v: String, _ params: [String: String]) -> (Date?, Bool) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || v.count == 8 {
            f.dateFormat = "yyyyMMdd"
            f.timeZone = .current
            return (f.date(from: v), true)
        }
        if v.hasSuffix("Z") {
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            f.timeZone = TimeZone(identifier: "UTC")
        } else {
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            f.timeZone = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current
        }
        return (f.date(from: v), false)
    }
}

// MARK: - Moodle → домашки

enum MoodleHomework {
    struct Item {
        let uid: String
        let title: String
        let courseKey: String?
        let deadline: Date
    }

    private static let suffixes = [" is due", " closes", " should be completed", " deadline",
                                   " закрывается", " должно быть выполнено", " срок сдачи"]
    private static let prefixes = ["срок сдачи", "крайний срок", "дедлайн", "due:", "deadline:"]

    /// Превращает событие календаря Moodle в дедлайн. «Открывается» и «оценивание» пропускаем.
    static func item(from ev: ICSEvent) -> Item? {
        guard let start = ev.start, !ev.uid.isEmpty else { return nil }
        let low = ev.summary.lowercased()
        if low.hasSuffix(" opens") || low.contains("открывается") || low.contains("to be graded") || low.contains("оценивани") {
            return nil
        }
        var title = ev.summary.trimmingCharacters(in: .whitespaces)
        for s in suffixes where title.lowercased().hasSuffix(s) { title = String(title.dropLast(s.count)) }
        for p in prefixes where title.lowercased().hasPrefix(p) { title = String(title.dropFirst(p.count)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—«»\"“”'"))
        if title.isEmpty { title = ev.summary }
        let deadline = ev.allDay ? start.addingTimeInterval(23 * 3600 + 59 * 60) : start
        let course = ev.categories?.trimmingCharacters(in: .whitespaces)
        return Item(uid: ev.uid, title: title, courseKey: (course?.isEmpty ?? true) ? nil : course, deadline: deadline)
    }
}

enum HomeworkSyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}

// MARK: - Домашки в хранилище

extension Store {
    func course(_ id: UUID?) -> Course? {
        guard let id else { return nil }
        return data.courses.first { $0.id == id }
    }

    func courseColor(_ id: UUID?) -> Color {
        course(id).map { Palette.color($0.colorIndex) } ?? Palette.neutral
    }

    func taskColor(_ t: TaskItem) -> Color {
        t.isHomework ? courseColor(t.courseID) : color(for: t.projectID)
    }

    func taskGroupName(_ t: TaskItem) -> String? {
        if t.isHomework { return course(t.courseID).map { "ДЗ · \($0.name)" } ?? "ДЗ" }
        return project(t.projectID)?.name
    }

    var studyProjectID: UUID? { findProject(named: "учеба")?.id }

    func findCourse(named raw: String) -> Course? {
        let key = Store.normalize(raw.replacingOccurrences(of: "_", with: " "))
        guard !key.isEmpty else { return nil }
        if let c = data.courses.first(where: { Store.normalize($0.name) == key || Store.normalize($0.key) == key }) { return c }
        let prefixed = data.courses.filter { Store.normalize($0.name).hasPrefix(key) }
        return key.count >= 2 && prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Индекс предмета по названию из LMS (создаёт новый, если такого нет).
    static func courseIndex(for key: String, in courses: inout [Course]) -> Int {
        let norm = normalize(key)
        if let i = courses.firstIndex(where: { normalize($0.key) == norm || normalize($0.name) == norm }) { return i }
        let used = Set(courses.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !used.contains($0) } ?? courses.count
        let pretty = key.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces).capitalizedFirst
        courses.append(Course(key: key, name: pretty, colorIndex: color, estimate: 60))
        return courses.count - 1
    }

    var openHomeworkCount: Int { data.tasks.filter { $0.isHomework && !$0.done }.count }

    func homeworkTasks(course: UUID?, showDone: Bool) -> [TaskItem] {
        let base = data.tasks.filter { $0.isHomework && (course == nil || $0.courseID == course) }
        let open = base.filter { !$0.done }.sorted {
            ($0.deadline ?? .distantFuture, $0.createdAt) < ($1.deadline ?? .distantFuture, $1.createdAt)
        }
        guard showDone else { return open }
        let done = base.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        return open + done.prefix(30)
    }

    func openHomework(course: UUID) -> Int {
        data.tasks.filter { $0.isHomework && !$0.done && $0.courseID == course }.count
    }

    // MARK: Предметы

    func setCourseEstimate(_ id: UUID, minutes: Int) {
        guard let i = data.courses.firstIndex(where: { $0.id == id }) else { return }
        var d = data
        d.courses[i].estimate = minutes
        // Новая оценка предмета переезжает на все открытые ДЗ, где её не меняли руками.
        for j in d.tasks.indices where d.tasks[j].courseID == id && !d.tasks[j].done && d.tasks[j].customEstimate != true {
            d.tasks[j].estimate = minutes
        }
        data = d
    }

    func deleteCourse(_ id: UUID) {
        var d = data
        d.courses.removeAll { $0.id == id }
        for j in d.tasks.indices where d.tasks[j].courseID == id { d.tasks[j].courseID = nil }
        data = d
    }

    // MARK: Ручное добавление

    func addHomework(_ input: ParsedInput) -> String? {
        let p = QuickParser.asHomework(input)
        guard !p.title.isEmpty else { return nil }
        var courseID: UUID?
        var estimate = 60
        if let name = p.projectName {
            var courses = data.courses
            let i: Int
            if let found = findCourse(named: name), let idx = courses.firstIndex(where: { $0.id == found.id }) {
                i = idx
            } else {
                i = Store.courseIndex(for: name, in: &courses)
                data.courses = courses
            }
            courseID = courses[i].id
            estimate = courses[i].estimate
        }
        data.tasks.append(TaskItem(
            title: p.title.capitalizedFirst,
            projectID: studyProjectID,
            estimate: p.estimate ?? estimate,
            deadline: p.deadline,
            priority: p.priority,
            homework: true,
            courseID: courseID,
            customEstimate: p.estimate != nil ? true : nil
        ))
        return "ДЗ добавлено"
    }

    // MARK: Синхронизация с LMS

    var homeworkFeedHost: String? {
        URL(string: Store.httpURL(data.settings.homeworkFeedURL))?.host
    }

    static func httpURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("webcal://") { return "https://" + s.dropFirst(9) }
        return s
    }

    func syncHomework() {
        let raw = Store.httpURL(data.settings.homeworkFeedURL)
        guard !raw.isEmpty, homeworkSync != .syncing else { return }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            homeworkSync = .failed("Это не похоже на ссылку")
            return
        }
        homeworkSync = .syncing
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        URLSession.shared.dataTask(with: request) { [weak self] body, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.homeworkSync = .failed("Нет связи с LMS: \(error.localizedDescription)")
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code), let body,
                      let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) else {
                    self.homeworkSync = .failed("LMS ответила ошибкой \(code)")
                    return
                }
                guard text.contains("BEGIN:VCALENDAR") else {
                    self.homeworkSync = .failed("По ссылке не календарь — нужна ссылка из «Экспортировать календарь»")
                    return
                }
                self.applyHomework(ICSParser.parse(text), now: Date())
                self.data.settings.homeworkLastSync = Date()
                self.homeworkSync = .idle
            }
        }.resume()
    }

    /// Добавляет новые дедлайны и обновляет сроки у уже известных. Отметки «сделано» и ручные оценки не трогает.
    @discardableResult
    func applyHomework(_ events: [ICSEvent], now: Date) -> (added: Int, updated: Int) {
        var tasks = data.tasks
        var courses = data.courses
        var added = 0, updated = 0
        let study = studyProjectID
        for ev in events {
            guard let hw = MoodleHomework.item(from: ev) else { continue }
            let ci = hw.courseKey.map { Store.courseIndex(for: $0, in: &courses) }
            if let i = tasks.firstIndex(where: { $0.externalID == hw.uid }) {
                if tasks[i].deadline != hw.deadline {
                    tasks[i].deadline = hw.deadline
                    updated += 1
                }
                if tasks[i].courseID == nil, let ci { tasks[i].courseID = courses[ci].id }
            } else {
                guard hw.deadline > now.addingTimeInterval(-3 * 86400) else { continue }   // старьё не тащим
                tasks.append(TaskItem(
                    title: hw.title,
                    projectID: study,
                    estimate: ci.map { courses[$0].estimate } ?? 60,
                    deadline: hw.deadline,
                    homework: true,
                    courseID: ci.map { courses[$0].id },
                    externalID: hw.uid
                ))
                added += 1
            }
        }
        var d = data
        d.courses = courses
        d.tasks = tasks
        data = d
        return (added, updated)
    }

    // MARK: Запись ДЗ на конкретное время

    /// Ближайшее свободное окно в этот день под задачу (с шагом 15 минут).
    func suggestSlot(minutes: Int, day: Date, now: Date) -> Date? {
        let cal = Calendar.current
        var (from, to) = dayBounds(day)
        if cal.isDate(day, inSameDayAs: now) { from = max(from, now) }
        from = from.roundedUp(minutes: 15)
        guard from < to else { return nil }
        let pause = TimeInterval(data.settings.breakMinutes * 60)
        let busy = agenda(for: day).map { ($0.start.addingTimeInterval(-pause), $0.end.addingTimeInterval(pause)) }
        let free = Store.freeIntervals(from: from, to: to, busy: busy)
        let need = TimeInterval(minutes * 60)
        for (s, e) in free {
            let start = s.roundedUp(minutes: 15)
            if e.timeIntervalSince(start) >= need { return start }
        }
        return nil
    }

    func scheduleManual(taskID: UUID, start: Date, minutes: Int) -> String {
        data.blocks.append(PlanBlock(taskID: taskID, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                     manual: true, toCalendar: true))
        if let cal = writeCalendarTitle { return "В «\(cal)»: \(Fmt.when(start, now: now))" }
        return "В плане: \(Fmt.when(start, now: now))"
    }
}

extension QuickParser {
    /// На странице «ДЗ» время в строке — это срок сдачи, а не событие.
    static func asHomework(_ input: ParsedInput) -> ParsedInput {
        var p = input
        if p.kind == .event, let day = p.day, let m = p.startMinutes {
            p.deadline = Calendar.current.startOfDay(for: day).addingTimeInterval(TimeInterval(m * 60))
            p.kind = .task
            p.startMinutes = nil
            p.endMinutes = nil
            p.weekdays = []
        }
        return p
    }
}

extension Fmt {
    /// «45 мин», «5 ч», «2 д 4 ч»
    static func countdown(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes)) мин" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) ч" }
        let d = hours / 24, h = hours % 24
        return h == 0 ? "\(d) д" : "\(d) д \(h) ч"
    }

    static func ago(_ d: Date, now: Date) -> String {
        let s = now.timeIntervalSince(d)
        if s < 90 { return "только что" }
        return "\(countdown(s)) назад"
    }
}
