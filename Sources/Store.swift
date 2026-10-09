import Foundation
import SwiftUI
import Combine

struct PlanResult {
    var placed = 0
    var unplaced: [String] = []
    var noTime = false

    var message: String {
        if noTime { return "На этот день свободного времени уже нет" }
        if placed == 0 && unplaced.isEmpty { return "Нечего распределять — всё уже в плане" }
        var s = "Распределено задач: \(placed)"
        if !unplaced.isEmpty { s += " · не влезло: \(unplaced.count)" }
        return s
    }
}

final class Store: ObservableObject {
    @Published var data: AppData {
        didSet {
            scheduleSave()
            if oldValue.settings.hiddenCalendarIDs != data.settings.hiddenCalendarIDs { calendarService.invalidate() }
            scheduleCalendarSync()
        }
    }
    @Published var now = Date()
    @Published var calendarVersion = 0
    @Published var homeworkSync: HomeworkSyncState = .idle

    let calendarService = CalendarService()
    let fileURL: URL
    private let persist: Bool
    private var saveWork: DispatchWorkItem?
    private var syncWork: DispatchWorkItem?
    var lastCreated: [CreatedRef] = []

    static var defaultURL: URL {
        if let custom = ProcessInfo.processInfo.environment["OSTROVOK_DATA"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ostrovok", isDirectory: true)
            .appendingPathComponent("data.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL = Store.defaultURL, persist: Bool = true) {
        self.fileURL = fileURL
        self.persist = persist
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var loaded = AppData()
        if let raw = try? Data(contentsOf: fileURL) {
            do {
                loaded = try Store.decoder.decode(AppData.self, from: raw)
            } catch {
                // Не затираем испорченный файл молча — сохраняем копию рядом.
                let backup = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("data.broken-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
                NSLog("Ostrovok: не удалось прочитать данные (\(error)), копия: \(backup.path)")
            }
        } else {
            loaded.projects = [
                Project(name: "Учёба", colorIndex: 5),
                Project(name: "Работа", colorIndex: 1),
                Project(name: "Личное", colorIndex: 3),
            ]
        }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        loaded.blocks.removeAll { $0.end < cutoff }
        // Старые заметки → сообщения в чатах проектов.
        let migrateNotes = !loaded.notes.isEmpty
        if migrateNotes {
            var inboxID = loaded.projects.first(where: { $0.name == "Заметки" })?.id
            for n in loaded.notes.reversed() {
                var chat = n.projectID.flatMap { pid in loaded.projects.first { $0.id == pid }?.id }
                if chat == nil {
                    if inboxID == nil {
                        let p = Project(name: "Заметки", colorIndex: 4)
                        loaded.projects.append(p)
                        inboxID = p.id
                    }
                    chat = inboxID
                }
                loaded.messages.append(ChatMessage(chatID: chat!, date: n.createdAt, text: n.text))
            }
            loaded.notes = []
        }
        data = loaded

        calendarService.onChange = { [weak self] in self?.calendarVersion += 1 }
        if migrateNotes { saveNow() }
    }

    // MARK: - Сохранение

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard persist else { return }
        do {
            let raw = try Store.encoder.encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ostrovok: ошибка сохранения: \(error)")
        }
    }

    // MARK: - Календарь (Яндекс, iCloud, Google — всё, что подключено к Календарю macOS)

    /// Название календаря, куда пишутся новые события, если запись включена.
    var writeCalendarTitle: String? {
        guard data.settings.useCalendar else { return nil }
        return calendarService.writableCalendar(data.settings.writeCalendarID)?.title
    }

    private func scheduleCalendarSync() {
        guard persist else { return }
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncCalendarNow() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Выгружает блоки плана в выбранный календарь (или убирает их оттуда, если выгрузка выключена).
    func syncCalendarNow() {
        let st = data.settings
        guard persist, st.useCalendar, calendarService.hasAccess else { return }
        let startOfToday = Calendar.current.startOfDay(for: Date())
        var exports: [PlanExport] = []
        for b in data.blocks where b.end > startOfToday && (st.exportPlan || b.toCalendar == true) {
            guard let t = task(b.taskID) else { continue }
            let group = course(t.courseID).map { "ДЗ · \($0.name)" } ?? project(t.projectID)?.name
            let suffix = group.map { " · \($0)" } ?? ""
            exports.append(PlanExport(key: b.id.uuidString, title: (t.done ? "✓ " : "▶ ") + t.title + suffix,
                                      start: b.start, end: b.end))
        }
        calendarService.syncPlan(exports, calendarID: st.writeCalendarID, from: startOfToday)
    }

    func deleteCalendarEvent(_ eventID: String, start: Date) -> String {
        do {
            try calendarService.deleteOccurrence(eventID: eventID, start: start)
            return "Удалено из календаря"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Проекты

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return data.projects.first { $0.id == id }
    }

    func color(for projectID: UUID?) -> Color {
        project(projectID).map { Palette.color($0.colorIndex) } ?? Palette.neutral
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е").trimmingCharacters(in: .whitespaces)
    }

    /// Ищет проект по имени (без учёта регистра и ё/е, можно начало слова), иначе ничего.
    func findProject(named raw: String) -> Project? {
        let key = Store.normalize(raw)
        guard !key.isEmpty else { return nil }
        if let exact = data.projects.first(where: { Store.normalize($0.name) == key }) { return exact }
        let prefixed = data.projects.filter { Store.normalize($0.name).hasPrefix(key) }
        return key.count >= 2 && prefixed.count == 1 ? prefixed[0] : nil
    }

    @discardableResult
    func ensureProject(named raw: String) -> Project {
        if let p = findProject(named: raw) { return p }
        let used = Set(data.projects.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !used.contains($0) } ?? data.projects.count
        let p = Project(name: raw.trimmingCharacters(in: .whitespaces).capitalizedFirst, colorIndex: color)
        data.projects.append(p)
        return p
    }

    func addProject() {
        let used = Set(data.projects.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !used.contains($0) } ?? data.projects.count
        data.projects.append(Project(name: "Новый проект", colorIndex: color))
    }

    func deleteProject(_ id: UUID) {
        data.projects.removeAll { $0.id == id }
        for i in data.tasks.indices where data.tasks[i].projectID == id { data.tasks[i].projectID = nil }
        for i in data.events.indices where data.events[i].projectID == id { data.events[i].projectID = nil }
        for i in data.notes.indices where data.notes[i].projectID == id { data.notes[i].projectID = nil }
    }

    // MARK: - Добавление из быстрого ввода

    /// Возвращает текст для подтверждения или nil, если добавлять нечего.
    func add(_ p: ParsedInput) -> String? {
        let cal = Calendar.current
        switch p.kind {
        case .task:
            guard !p.title.isEmpty else { return nil }
            let projectID = p.projectName.map { ensureProject(named: $0).id }
            data.tasks.append(TaskItem(
                title: p.title.capitalizedFirst,
                projectID: projectID,
                estimate: p.estimate ?? data.settings.defaultEstimate,
                deadline: p.deadline,
                priority: p.priority
            ))
            return "Задача добавлена"
        case .event:
            guard let day = p.day else { return nil }
            let projectID = p.projectName.map { ensureProject(named: $0).id }
            let dayStart = cal.startOfDay(for: day)
            if p.allDay || p.startMinutes == nil {
                return addAllDay(p, day: dayStart, projectID: projectID)
            }
            let sm = p.startMinutes!
            let start = dayStart.addingTimeInterval(TimeInterval(sm * 60))
            var endMinutes = p.endMinutes ?? (sm + (p.estimate ?? 60))
            if endMinutes <= sm { endMinutes += 24 * 60 }
            let end = dayStart.addingTimeInterval(TimeInterval(endMinutes * 60))
            let title = p.title.isEmpty ? "Событие" : p.title.capitalizedFirst

            if writeCalendarTitle != nil {
                // Пишем прямо в выбранный календарь (например, Яндекс) — macOS сама отправит на сервер.
                var shift = 0
                if !p.weekdays.isEmpty {
                    // Первое вхождение — ближайший подходящий день недели.
                    shift = (0..<7).first { off in
                        let d = cal.date(byAdding: .day, value: off, to: dayStart)!
                        return p.weekdays.contains(cal.component(.weekday, from: d))
                    } ?? 0
                }
                let s = cal.date(byAdding: .day, value: shift, to: start)!
                let e = cal.date(byAdding: .day, value: shift, to: end)!
                do {
                    let created = try calendarService.createEvent(title: title, start: s, end: e, weekdays: p.weekdays,
                                                                  calendarID: data.settings.writeCalendarID,
                                                                  location: p.location)
                    let calName = created.calendarTitle
                    lastCreated.append(.calendar(created.eventID, s))
                    calendarVersion += 1
                    if !p.weekdays.isEmpty { return "В «\(calName)»: \(Fmt.weekdays(p.weekdays))" }
                    return "В «\(calName)»: \(Fmt.when(s, now: now))"
                } catch {
                    NSLog("Ostrovok: не удалось записать в календарь: \(error)")
                }
            }

            let local = EventItem(
                title: title,
                projectID: projectID,
                start: start,
                end: end,
                weekdays: p.weekdays,
                location: p.location
            )
            data.events.append(local)
            lastCreated.append(.local(local.id))
            if !p.weekdays.isEmpty { return "Событие \(Fmt.weekdays(p.weekdays))" }
            return "Событие: \(Fmt.when(start, now: now))"
        }
    }

    /// Мероприятие на весь день — событие «весь день» (в календаре или в Островке), не блокирует время в плане.
    private func addAllDay(_ p: ParsedInput, day: Date, projectID: UUID?) -> String {
        let title = p.title.isEmpty ? "Мероприятие" : p.title.capitalizedFirst
        if writeCalendarTitle != nil,
           let created = try? calendarService.createEvent(title: title, start: day, end: day.addingTimeInterval(86400 - 60),
                                                          weekdays: [], calendarID: data.settings.writeCalendarID,
                                                          location: p.location, allDay: true) {
            lastCreated.append(.calendar(created.eventID, day))
            calendarVersion += 1
            return "В «\(created.calendarTitle)»: \(Fmt.dayWord(day, now: now)), весь день"
        }
        let local = EventItem(title: title, projectID: projectID, start: day, end: day.addingTimeInterval(86400 - 60),
                              location: p.location, allDay: true)
        data.events.append(local)
        lastCreated.append(.local(local.id))
        return "Весь день: \(title), \(Fmt.dayWord(day, now: now))"
    }

    // MARK: - Отмена последнего добавления

    enum CreatedRef {
        case local(UUID)
        case calendar(String, Date)
        case task(UUID)
    }

    /// Задача из строки ввода: создаём и сразу ставим в расписание —
    /// на указанное время, а если его нет, в ближайшее свободное окно (в указанный день или с сегодняшнего).
    func addImportedTask(_ e: ImportedEvent, now: Date = Date()) -> String {
        let cal = Calendar.current
        let pid = e.projectName.flatMap { findProject(named: $0)?.id }
        let t = TaskItem(title: e.title.capitalizedFirst, projectID: pid,
                         estimate: e.estimate ?? data.settings.defaultEstimate, deadline: e.deadline)
        data.tasks.append(t)
        lastCreated.append(.task(t.id))
        let day = cal.startOfDay(for: e.day)
        if let s = e.start {
            let start = day.addingTimeInterval(TimeInterval(s * 60))
            placeBlock(taskID: t.id, start: start, minutes: t.estimate)
            return "Задача на \(Fmt.when(start, now: now)): \(t.title)"
        }
        let firstDay = e.dayGiven ? max(day, cal.startOfDay(for: now)) : cal.startOfDay(for: now)
        for off in 0..<7 {
            plan(day: cal.date(byAdding: .day, value: off, to: firstDay)!, now: now, only: t.id)
            if remainingSeconds(for: t, now: now) < 5 * 60 { break }
        }
        if let b = nextBlock(for: t.id, now: now) {
            return "Задача на \(Fmt.when(b.start, now: now)): \(t.title)"
        }
        return "Задача добавлена, но свободного окна не нашлось: \(t.title)"
    }

    func undoLastCreated() -> String {
        var removed = 0
        for ref in lastCreated {
            switch ref {
            case .local(let id):
                if data.events.contains(where: { $0.id == id }) { deleteEvent(id); removed += 1 }
            case .calendar(let eventID, let start):
                if (try? calendarService.deleteOccurrence(eventID: eventID, start: start)) != nil { removed += 1 }
            case .task(let id):
                if task(id) != nil { deleteTask(id); removed += 1 }
            }
        }
        lastCreated = []
        calendarVersion += 1
        return removed > 0 ? "Отменено" : "Нечего отменять"
    }

    /// Если календарь связан, но не выбрано, куда писать — берём Яндекс, если он есть.
    func autoPickWriteCalendar() {
        guard data.settings.useCalendar, calendarService.hasAccess, writeCalendarTitle == nil else { return }
        if let y = calendarService.calendars().first(where: { $0.writable && $0.looksLikeYandex }) {
            data.settings.writeCalendarID = y.id
        }
    }

    /// Мероприятия на весь день (не участвуют в шкале и в раскладке задач).
    func allDayItems(for day: Date) -> [AgendaItem] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        var items: [AgendaItem] = []
        for e in data.events where e.allDay == true && cal.isDate(e.start, inSameDayAs: dayStart) {
            items.append(AgendaItem(id: "e-\(e.id)", title: e.title, start: e.start, end: e.end,
                                    color: color(for: e.projectID), kind: .event(e.id),
                                    projectName: project(e.projectID)?.name, location: e.location, allDay: true))
        }
        if data.settings.useCalendar {
            _ = calendarVersion
            for c in calendarService.events(on: dayStart, hidden: Set(data.settings.hiddenCalendarIDs)) where c.allDay {
                items.append(AgendaItem(id: "c-\(c.id)", title: c.title, start: c.start, end: c.end, color: c.color,
                                        kind: .calendar(c.eventID), calendarName: c.calendarName,
                                        location: c.location, allDay: true))
            }
        }
        return items
    }

    // MARK: - Заметки

    func addNote(_ text: String, projectID: UUID?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        data.notes.insert(Note(text: t, projectID: projectID), at: 0)
    }

    func notes(project: UUID?) -> [Note] {
        data.notes.filter { project == nil || $0.projectID == project }
    }

    func updateNote(_ id: UUID, text: String) {
        guard let i = data.notes.firstIndex(where: { $0.id == id }) else { return }
        data.notes[i].text = text
    }

    func deleteNote(_ id: UUID) { data.notes.removeAll { $0.id == id } }

    /// Заметка → задача в том же проекте.
    func noteToTask(_ id: UUID) {
        guard let n = data.notes.first(where: { $0.id == id }) else { return }
        let firstLine = n.text.split(separator: "\n").first.map(String.init) ?? n.text
        var d = data
        d.tasks.append(TaskItem(title: firstLine, projectID: n.projectID, estimate: d.settings.defaultEstimate))
        d.notes.removeAll { $0.id == id }
        data = d
    }

    /// Задача из строки проекта: проект задан явно, #хештег не нужен.
    func addTask(_ text: String, projectID: UUID?) -> String? {
        var p = QuickParser.parse(text, now: Date())
        if p.kind == .event {
            // В строке проекта время — это срок, а не событие.
            p = QuickParser.asHomework(p)
        }
        guard !p.title.isEmpty else { return nil }
        let pid = p.projectName.map { ensureProject(named: $0).id } ?? projectID
        data.tasks.append(TaskItem(title: p.title.capitalizedFirst, projectID: pid,
                                   estimate: p.estimate ?? data.settings.defaultEstimate,
                                   deadline: p.deadline, priority: p.priority))
        return "Задача в «\(project(pid)?.name ?? "без проекта")»"
    }

    /// Перенести события, созданные в Островке, в подключённый календарь (например, Яндекс).
    func moveLocalEventsToCalendar() -> String {
        guard let calID = data.settings.writeCalendarID, writeCalendarTitle != nil else { return "Не выбран календарь для записи" }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var moved = 0
        var keep: [EventItem] = []
        for e in data.events {
            if e.weekdays.isEmpty && e.end < today { keep.append(e); continue }   // прошедшие оставляем
            if e.allDay == true {
                let day = cal.startOfDay(for: e.start)
                if (try? calendarService.createEvent(title: e.title, start: day, end: day.addingTimeInterval(86400 - 60),
                                                     weekdays: [], calendarID: calID, location: e.location, allDay: true)) != nil {
                    moved += 1
                } else {
                    keep.append(e)
                }
                continue
            }
            var start = e.start, end = e.end
            if !e.weekdays.isEmpty {
                // первое вхождение с сегодняшнего дня
                let offset = e.start.timeIntervalSince(cal.startOfDay(for: e.start))
                let duration = e.end.timeIntervalSince(e.start)
                let shift = (0..<7).first { off in
                    let d = cal.date(byAdding: .day, value: off, to: today)!
                    return e.weekdays.contains(cal.component(.weekday, from: d))
                } ?? 0
                start = cal.date(byAdding: .day, value: shift, to: today)!.addingTimeInterval(offset)
                end = start.addingTimeInterval(duration)
            }
            if (try? calendarService.createEvent(title: e.title, start: start, end: end, weekdays: e.weekdays,
                                                 calendarID: calID, location: e.location)) != nil {
                moved += 1
            } else {
                keep.append(e)
            }
        }
        data.events = keep
        calendarVersion += 1
        return "Перенесено событий: \(moved)"
    }

    var localUpcomingEventsCount: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return data.events.filter { !$0.weekdays.isEmpty || $0.end >= today }.count
    }

    // MARK: - Задачи

    func task(_ id: UUID) -> TaskItem? { data.tasks.first { $0.id == id } }

    func updateTask(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&data.tasks[i])
    }

    func toggleDone(_ id: UUID) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        let nowDone = !data.tasks[i].done
        data.tasks[i].done = nowDone
        data.tasks[i].doneAt = nowDone ? Date() : nil
        if nowDone {
            // Сделано — будущие блоки под эту задачу больше не нужны, время освобождается.
            let t = Date()
            data.blocks.removeAll { $0.taskID == id && $0.start > t }
        }
    }

    func deleteTask(_ id: UUID) {
        data.tasks.removeAll { $0.id == id }
        data.blocks.removeAll { $0.taskID == id }
    }

    func unplanTask(_ id: UUID) {
        let t = Date()
        data.blocks.removeAll { $0.taskID == id && $0.end > t }
    }

    func deleteEvent(_ id: UUID) { data.events.removeAll { $0.id == id } }
    func deleteBlock(_ id: UUID) { data.blocks.removeAll { $0.id == id } }

    func nextBlock(for taskID: UUID, now: Date) -> PlanBlock? {
        data.blocks.filter { $0.taskID == taskID && $0.end > now }.min { $0.start < $1.start }
    }

    func urgencyKey(_ t: TaskItem) -> Date {
        let base = t.deadline ?? now.addingTimeInterval(14 * 86400)
        return t.priority ? base.addingTimeInterval(-3 * 86400) : base
    }

    func taskOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        let ka = urgencyKey(a), kb = urgencyKey(b)
        if ka != kb { return ka < kb }
        return a.createdAt < b.createdAt
    }

    func visibleTasks(filter: UUID?, showDone: Bool) -> [TaskItem] {
        let base = data.tasks.filter { filter == nil || $0.projectID == filter }
        let open = base.filter { !$0.done }.sorted(by: taskOrder)
        guard showDone else { return open }
        let done = base.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
        return open + done.prefix(40)
    }

    func openCount(project: UUID?) -> Int {
        data.tasks.filter { !$0.done && (project == nil || $0.projectID == project) }.count
    }

    var doneCount: Int { data.tasks.filter(\.done).count }

    func overdueCount(now: Date) -> Int {
        data.tasks.filter { !$0.done && ($0.deadline.map { $0 < now } ?? false) }.count
    }

    func nextDeadlineTask(now: Date) -> TaskItem? {
        data.tasks.filter { !$0.done && $0.deadline != nil }.min { $0.deadline! < $1.deadline! }
    }

    /// Задачи «на сегодня»: запланированные на сегодня, со сроком до конца дня и закрытые сегодня.
    func todayProgress(now: Date) -> (done: Int, total: Int) {
        let cal = Calendar.current
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let planned = Set(data.blocks.filter { cal.isDate($0.start, inSameDayAs: now) }.map(\.taskID))
        let relevant = data.tasks.filter { t in
            if let doneAt = t.doneAt, t.done { return cal.isDate(doneAt, inSameDayAs: now) }
            if planned.contains(t.id) { return true }
            if let d = t.deadline, d < endOfToday { return true }
            return false
        }
        return (relevant.filter(\.done).count, relevant.count)
    }

    // MARK: - Расписание дня

    func agenda(for day: Date) -> [AgendaItem] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let weekday = cal.component(.weekday, from: dayStart)
        var items: [AgendaItem] = []

        for e in data.events where e.allDay != true {
            let projectName = project(e.projectID)?.name
            if e.weekdays.isEmpty {
                guard cal.isDate(e.start, inSameDayAs: dayStart) else { continue }
                items.append(AgendaItem(id: "e-\(e.id)", title: e.title, start: e.start, end: e.end,
                                        color: color(for: e.projectID), kind: .event(e.id),
                                        projectName: projectName, location: e.location))
            } else if e.weekdays.contains(weekday), dayStart >= cal.startOfDay(for: e.start) {
                let offset = e.start.timeIntervalSince(cal.startOfDay(for: e.start))
                let start = dayStart.addingTimeInterval(offset)
                items.append(AgendaItem(id: "e-\(e.id)-\(Int(dayStart.timeIntervalSince1970))", title: e.title,
                                        start: start, end: start.addingTimeInterval(e.end.timeIntervalSince(e.start)),
                                        color: color(for: e.projectID), kind: .event(e.id),
                                        recurring: true, projectName: projectName, location: e.location))
            }
        }

        for b in data.blocks where cal.isDate(b.start, inSameDayAs: dayStart) {
            guard let t = task(b.taskID) else { continue }
            items.append(AgendaItem(id: "b-\(b.id)", title: t.title, start: b.start, end: b.end,
                                    color: taskColor(t), kind: .block(b.id, task: t.id),
                                    done: t.done, projectName: taskGroupName(t)))
        }

        if data.settings.useCalendar {
            _ = calendarVersion
            for c in calendarService.events(on: dayStart, hidden: Set(data.settings.hiddenCalendarIDs)) where !c.allDay {
                items.append(AgendaItem(id: "c-\(c.id)", title: c.title, start: c.start, end: c.end,
                                        color: c.color, kind: .calendar(c.eventID), calendarName: c.calendarName,
                                        location: c.location))
            }
        }
        return items.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    func currentItem(now: Date) -> AgendaItem? {
        agenda(for: now).first { $0.start <= now && now < $0.end && !$0.done }
    }

    func nextItem(now: Date) -> AgendaItem? {
        agenda(for: now).first { $0.start > now && !$0.done }
    }

    func dayBounds(_ day: Date) -> (start: Date, end: Date) {
        let s = Calendar.current.startOfDay(for: day)
        let st = data.settings
        return (s.addingTimeInterval(TimeInterval(st.dayStartHour * 3600)),
                s.addingTimeInterval(TimeInterval(st.dayEndHour * 3600)))
    }

    /// Свободные минуты дня (с учётом событий и уже запланированных блоков).
    func freeMinutes(day: Date, now: Date) -> Int {
        var (from, to) = dayBounds(day)
        if Calendar.current.isDate(day, inSameDayAs: now) { from = max(from, now) }
        guard from < to else { return 0 }
        let busy = agenda(for: day).map { ($0.start, $0.end) }
        let free = Store.freeIntervals(from: from, to: to, busy: busy)
        return Int(free.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60)
    }

    func plannedMinutes(day: Date) -> Int {
        agenda(for: day).filter { $0.isTaskBlock && !$0.done }.reduce(0) { $0 + $1.minutes }
    }

    // MARK: - Планировщик

    static func freeIntervals(from: Date, to: Date, busy: [(Date, Date)]) -> [(Date, Date)] {
        var result: [(Date, Date)] = []
        var cursor = from
        for (s, e) in busy.sorted(by: { $0.0 < $1.0 }) {
            if e <= cursor { continue }
            if s > cursor { result.append((cursor, min(s, to))) }
            cursor = max(cursor, e)
            if cursor >= to { break }
        }
        if cursor < to { result.append((cursor, to)) }
        return result.filter { $0.1.timeIntervalSince($0.0) >= 60 }
    }

    /// Сколько секунд по задаче ещё не запланировано (учитываются блоки с сегодняшнего дня).
    func remainingSeconds(for t: TaskItem, blocks: [PlanBlock]? = nil, now: Date) -> TimeInterval {
        // Считаем только то, что ещё впереди: прошедший блок по несделанной задаче — это «камень», а не сделанная работа.
        let planned = (blocks ?? data.blocks)
            .filter { $0.taskID == t.id && $0.end > now }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        return TimeInterval(t.estimate * 60) - planned
    }

    /// Раскладывает незакрытые задачи по свободным окнам дня — сначала самые срочные.
    /// Если `only` задан, планируется только эта задача и существующий план не трогается.
    @discardableResult
    func plan(day: Date, now: Date = Date(), only: UUID? = nil) -> PlanResult {
        let cal = Calendar.current
        let st = data.settings
        guard cal.startOfDay(for: day) >= cal.startOfDay(for: now) else { return PlanResult(noTime: true) }

        var (winStart, winEnd) = dayBounds(day)
        if cal.isDate(day, inSameDayAs: now) { winStart = max(winStart, now.roundedUp(minutes: 5)) }

        let doneIDs = Set(data.tasks.filter(\.done).map(\.id))
        var blocks = data.blocks
        if only == nil {
            // «Камни» (прошедшие несделанные блоки) перепланируем заново.
            blocks.removeAll { b in b.end <= now && cal.isDate(b.start, inSameDayAs: now) && !doneIDs.contains(b.taskID) }
            // Перепланирование: убираем будущие блоки этого дня у незакрытых задач.
            blocks.removeAll { cal.isDate($0.start, inSameDayAs: day) && $0.start >= winStart && !doneIDs.contains($0.taskID) && $0.manual != true }
        }
        guard winEnd.timeIntervalSince(winStart) >= 15 * 60 else {
            data.blocks = blocks
            return PlanResult(noTime: true)
        }

        let pause = TimeInterval(st.breakMinutes * 60)
        var busy: [(Date, Date)] = agenda(for: day)
            .filter { !$0.isTaskBlock }
            .map { ($0.start.addingTimeInterval(-pause), $0.end.addingTimeInterval(pause)) }
        busy += blocks.filter { cal.isDate($0.start, inSameDayAs: day) }
            .map { ($0.start, $0.end.addingTimeInterval(pause)) }
        var free = Store.freeIntervals(from: winStart, to: winEnd, busy: busy)

        let candidates = data.tasks
            .filter { !$0.done && (only == nil || $0.id == only) }
            .sorted(by: taskOrder)

        var result = PlanResult()
        let maxChunk = TimeInterval(max(15, st.maxChunk) * 60)
        for t in candidates {
            var rest = remainingSeconds(for: t, blocks: blocks, now: now)
            if rest < 5 * 60 { continue }
            var placedAny = false
            while rest >= 5 * 60 {
                // Сначала окно, куда кусок влезает целиком; иначе режем на части от 45 минут;
                // совсем мелкие окна — только если больше некуда.
                let target = min(rest, maxChunk)
                func fits(_ need: TimeInterval) -> Int? {
                    free.firstIndex { $0.1.timeIntervalSince($0.0) >= need }
                }
                guard let i = fits(target) ?? fits(min(45 * 60, target)) ?? fits(min(15 * 60, target)) else { break }
                let length = free[i].1.timeIntervalSince(free[i].0)
                let chunk = min(rest, maxChunk, length)
                let s = free[i].0
                blocks.append(PlanBlock(taskID: t.id, start: s, end: s.addingTimeInterval(chunk)))
                free[i].0 = s.addingTimeInterval(chunk + pause)
                if free[i].1.timeIntervalSince(free[i].0) < 60 { free.remove(at: i) }
                rest -= chunk
                placedAny = true
            }
            if placedAny { result.placed += 1 }
            if rest >= 5 * 60 { result.unplaced.append(t.title) }
        }
        data.blocks = blocks
        return result
    }

    /// Ставит одну задачу в ближайшее свободное окно (сегодня или в следующие дни).
    func scheduleNext(_ id: UUID, now: Date = Date()) -> String {
        guard let t = task(id), !t.done else { return "Задача уже закрыта" }
        if remainingSeconds(for: t, now: now) < 5 * 60 {
            if let b = nextBlock(for: id, now: now) { return "Уже в плане: \(Fmt.when(b.start, now: now))" }
            return "Уже в плане"
        }
        let today = Calendar.current.startOfDay(for: now)
        for offset in 0..<7 {
            let day = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            plan(day: day, now: now, only: id)
            if remainingSeconds(for: t, now: now) < 5 * 60 { break }
        }
        if let b = nextBlock(for: id, now: now) { return "В плане: \(Fmt.when(b.start, now: now))" }
        return "Не нашлось свободного окна на неделе"
    }

    func clearPlan(day: Date, now: Date = Date()) {
        let cal = Calendar.current
        let doneIDs = Set(data.tasks.filter(\.done).map(\.id))
        data.blocks.removeAll { cal.isDate($0.start, inSameDayAs: day) && $0.start >= now && !doneIDs.contains($0.taskID) && $0.manual != true }
    }
}
