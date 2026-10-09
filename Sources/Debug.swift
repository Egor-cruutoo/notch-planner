import AppKit
import SwiftUI
import Carbon.HIToolbox

/// `Ostrovok --selftest` — проверка разбора строки и планировщика без интерфейса.
enum SelfTest {
    static func refNow() -> Date {
        // Четверг, 8 октября 2026, 13:20
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 13, minute: 20))!
    }

    static func run() -> Bool {
        let now = refNow()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
        func eod(_ offset: Int) -> Date { day(offset).addingTimeInterval(23 * 3600 + 59 * 60) }

        var ok = true
        func check(_ input: String, _ label: String, _ cond: (ParsedInput) -> Bool) {
            let p = QuickParser.parse(input, now: now)
            let pass = cond(p)
            if !pass { ok = false }
            print(pass ? "✓" : "✗", label.padding(toLength: 34, withPad: " ", startingAt: 0), "«\(input)» →", describe(p))
        }

        check("Домашка по матану #учёба 1.5ч до пт !", "задача с проектом/оценкой/сроком") {
            $0.kind == .task && $0.title == "Домашка по матану" && $0.projectName == "учёба"
                && $0.estimate == 90 && $0.deadline == eod(1) && $0.priority
        }
        check("Эссе по истории 2 часа к 12.10", "«2 часа» и дата через «к»") {
            $0.title == "Эссе по истории" && $0.estimate == 120 && $0.deadline == eod(4)
        }
        check("купить продукты сегодня 20м", "сегодня + минуты") {
            $0.title == "купить продукты" && $0.estimate == 20 && $0.deadline == eod(0)
        }
        check("14:00-15:30 Пара по физике #учёба", "событие с диапазоном") {
            $0.kind == .event && $0.title == "Пара по физике" && $0.startMinutes == 14 * 60
                && $0.endMinutes == 15 * 60 + 30 && $0.day == today
        }
        check("завтра в 10:00 созвон 30м", "событие завтра с длительностью") {
            $0.kind == .event && $0.title == "созвон" && $0.startMinutes == 600 && $0.estimate == 30 && $0.day == day(1)
        }
        check("по пн ср 9:00-10:30 Матан #учёба", "повтор по дням недели") {
            $0.kind == .event && $0.weekdays == [2, 4] && $0.title == "Матан" && $0.startMinutes == 540
        }
        check("каждый вт,чт с 18:00 до 19:30 английский", "повтор, «с … до …»") {
            $0.kind == .event && $0.weekdays == [3, 5] && $0.startMinutes == 1080 && $0.endMinutes == 1170 && $0.title == "английский"
        }
        check("подготовиться к экзамену по истории", "«к»/«по» без даты остаются в тексте") {
            $0.kind == .task && $0.title == "подготовиться к экзамену по истории" && $0.deadline == nil
        }
        check("сдать лабу до 18:00", "срок со временем сегодня") {
            $0.title == "сдать лабу" && $0.deadline == today.addingTimeInterval(18 * 3600)
        }
        check("встреча на 2 часа в пт 15:00 #работа", "событие в пятницу") {
            $0.kind == .event && $0.title == "встреча" && $0.day == day(1) && $0.estimate == 120 && $0.startMinutes == 900
        }
        check("прочитать главу 3 через неделю 45м", "через неделю") {
            $0.title == "прочитать главу 3" && $0.deadline == eod(7) && $0.estimate == 45
        }
        check("сдать лабу до пт 18:00", "срок «до пт 18:00»") {
            $0.kind == .task && $0.title == "сдать лабу" && $0.deadline == day(1).addingTimeInterval(18 * 3600)
        }
        check("#личные_дела оплатить интернет", "проект с подчёркиванием") {
            $0.projectName == "личные дела" && $0.title == "оплатить интернет"
        }

        // Планировщик
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ostrovok-selftest.json")
        let store = Store(fileURL: tmp, persist: false)
        store.data = AppData()
        store.now = now
        _ = store.add(QuickParser.parse("14:00-15:30 Пара #учёба", now: now))
        _ = store.add(QuickParser.parse("17:00-18:00 Созвон #работа", now: now))
        _ = store.add(QuickParser.parse("Домашка по матану #учёба 2ч до пт !", now: now))
        _ = store.add(QuickParser.parse("Эссе #учёба 3ч до 12.10", now: now))
        _ = store.add(QuickParser.parse("Спортзал #личное 1ч", now: now))
        let result = store.plan(day: now, now: now)
        print("\nПлан на 08.10 после 13:20 (окно до 23:00):", result.message)
        for item in store.agenda(for: now) {
            print("  \(Fmt.time(item.start))–\(Fmt.time(item.end))  \(item.isTaskBlock ? "▶" : "■") \(item.title)")
        }
        let agenda = store.agenda(for: now)
        var overlaps = false
        for (a, b) in zip(agenda, agenda.dropFirst()) where b.start < a.end { overlaps = true }
        let planCheck = !overlaps && result.placed == 3 && result.unplaced.isEmpty
            && agenda.first(where: \.isTaskBlock)?.title == "Домашка по матану"
        print(planCheck ? "✓" : "✗", "блоки не пересекаются, срочная задача первой")
        if !planCheck { ok = false }

        // Домашки из Moodle
        let hwStore = Store(fileURL: tmp, persist: false)
        hwStore.data = AppData()
        hwStore.now = now
        let first = hwStore.applyHomework(ICSParser.parse(SelfTest.sampleICS), now: now)
        let hw = hwStore.homeworkTasks(course: nil, showDone: true)
        print("\nДЗ из Moodle: добавлено \(first.added)")
        for t in hw {
            print("  \(Fmt.shortDate(t.deadline!)) \(Fmt.time(t.deadline!))  [\(hwStore.course(t.courseID)?.name ?? "—")]  \(t.title)")
        }
        let utc: (Int, Int, Int, Int) -> Date = { mo, d, h, mi in
            var c = DateComponents(); c.year = 2026; c.month = mo; c.day = d; c.hour = h; c.minute = mi
            var g = Calendar(identifier: .gregorian); g.timeZone = TimeZone(identifier: "UTC")!
            return g.date(from: c)!
        }
        let titles = hw.map(\.title)
        var hwOK = first.added == 5
            && titles == ["Листок 5", "Тест по главе 3", "Эссе: промышленная революция", "Лабораторная работа 2: сортировки", "Проект: курсовая, этап 1"]
            && hw[0].deadline == utc(10, 9, 20, 59)
            && hwStore.data.courses.map(\.name).sorted() == ["Алгоритмы", "Английский", "История", "Матанализ 2к"]
            && hw.last?.deadline == cal.startOfDay(for: cal.date(from: DateComponents(year: 2026, month: 10, day: 20))!).addingTimeInterval(23 * 3600 + 59 * 60)
        // Повторная синхронизация: дедлайн перенесли, отметка «сдано» сохраняется.
        hwStore.toggleDone(hw[1].id)
        let moved = SelfTest.sampleICS.replacingOccurrences(of: "DTSTART:20261009T205900Z", with: "DTSTART:20261010T205900Z")
        let second = hwStore.applyHomework(ICSParser.parse(moved), now: now)
        hwOK = hwOK && second.added == 0 && second.updated == 1
            && hwStore.task(hw[0].id)?.deadline == utc(10, 10, 20, 59) && hwStore.task(hw[1].id)?.done == true
        // Оценка предмета переезжает на его ДЗ, кроме изменённых вручную.
        let algo = hwStore.data.courses.first { $0.name == "Алгоритмы" }!
        hwStore.updateTask(hw[3].id) { $0.estimate = 30; $0.customEstimate = true }
        hwStore.setCourseEstimate(algo.id, minutes: 180)
        hwOK = hwOK && hwStore.task(hw[4].id)?.estimate == 180 && hwStore.task(hw[3].id)?.estimate == 30
        // Ручной блок «Распределить» не сносит.
        _ = hwStore.scheduleManual(taskID: hw[0].id, start: today.addingTimeInterval(19 * 3600), minutes: 60)
        hwStore.plan(day: now, now: now)
        hwOK = hwOK && hwStore.data.blocks.contains { $0.manual == true && $0.start == today.addingTimeInterval(19 * 3600) }
        print(hwOK ? "✓" : "✗", "разбор Moodle, повторная синхронизация, оценки предметов, ручные блоки")
        if !hwOK { ok = false }

        // Авто-раскладка ДЗ по неделе
        let ps = Store(fileURL: tmp, persist: false)
        ps.data = AppData()
        ps.now = now
        ps.data.settings.hwDailyCap = 120
        for line in ["по пн вт ср чт пт 9:00-10:30 Пара", "по пн вт ср чт пт 10:40-12:10 Пара", "по пн ср 13:00-14:30 Семинар"] {
            _ = ps.add(QuickParser.parse(line, now: now))
        }
        ps.applyHomework(ICSParser.parse(SelfTest.sampleICS), now: now)
        let algoC = ps.data.courses.first { $0.name == "Алгоритмы" }!
        ps.setCourseEstimate(algoC.id, minutes: 150)
        let manualTask = ps.homeworkTasks(course: nil, showDone: false)[2]
        let manualBlock = ps.placeBlock(taskID: manualTask.id, start: day(1).addingTimeInterval(16 * 3600), minutes: 30)
        let r1 = ps.distributeHomework(now: now)
        let snapshot1 = ps.data.blocks.map { "\($0.taskID)\($0.start)\($0.end)" }.sorted()
        let r2 = ps.distributeHomework(now: now)
        let snapshot2 = ps.data.blocks.map { "\($0.taskID)\($0.start)\($0.end)" }.sorted()
        print("\nАвто-раскладка ДЗ (лимит 2ч в день): \(r1.placed) распределено, не влезло \(r1.unplaced.count)")
        var plannerOK = r1.unplaced.isEmpty && r1.placed == 5 && snapshot1 == snapshot2 && r2.placed == r1.placed
            && ps.data.blocks.contains { $0.id == manualBlock.id && $0.start == manualBlock.start }
        for off in 0..<14 {
            let d = day(off)
            let items = ps.agenda(for: d)
            for (a, b) in zip(items, items.dropFirst()) where b.start < a.end { plannerOK = false; print("  ✗ пересечение \(a.title) / \(b.title)") }
            if ps.homeworkMinutes(on: d) > 120 + 30 { plannerOK = false; print("  ✗ перебор лимита \(Fmt.shortDate(d))") }
            for it in items where it.isTaskBlock {
                if case let .block(_, tid) = it.kind, let dl = ps.task(tid)?.deadline, it.end > dl { plannerOK = false; print("  ✗ после дедлайна: \(it.title)") }
                print("  \(Fmt.shortDate(it.start)) \(Fmt.time(it.start))–\(Fmt.time(it.end))  \(it.title)")
            }
        }
        print(plannerOK ? "✓" : "✗", "без пересечений, до дедлайнов, лимит в день, ручные блоки на месте, повтор даёт то же")
        if !plannerOK { ok = false }

        // Скриншот → текст (Apple Vision, локально)
        let shot = SelfTest.sampleScreenshot()
        let ocrText = (try? OCR.recognize(shot.cgImage(forProposedRect: nil, context: nil, hints: nil)!)) ?? ""
        print("\nРаспознано со скриншота:\n" + ocrText.split(separator: "\n").map { "  │ " + $0 }.joined(separator: "\n"))
        let ocrOK = ocrText.contains("Хакатон") && ocrText.contains("18:30") && ocrText.lowercased().contains("лекция")
        print(ocrOK ? "✓" : "✗", "текст со скриншота распознан")
        if !ocrOK { ok = false }

        // Ответ DeepSeek → мероприятия
        let answer = """
        {"events":[
          {"title":"Хакатон ФКН","date":"2026-10-10","start":"10:00","end":"18:30","location":"Покровский б-р, 11","weekly_days":[]},
          {"title":"Открытая лекция по ML","date":"2026-10-13","start":"19:00","end":null,"location":null,"weekly_days":[]},
          {"title":"Английский","date":"2026-10-09","start":"09:30","end":"10:50","location":"ауд. 402","weekly_days":[5,2]},
          {"title":"День открытых дверей","date":"2026-10-17","start":null,"end":null,"location":null,"weekly_days":[1]},
          {"title":"","date":"2026-10-11","start":"12:00"}
        ]}
        """
        var parseOK = false
        if case .success(let evs) = DeepSeek.parse("```json\n" + answer + "\n```") {
            parseOK = evs.count == 4
                && evs[0].title == "Хакатон ФКН" && evs[0].start == 600 && evs[0].end == 1110 && evs[0].location == "Покровский б-р, 11"
                && evs[1].end == nil && evs[2].weekdays == [3, 6] && evs[3].start == nil && evs[3].weekdays.isEmpty
                && cal.isDate(evs[0].day, inSameDayAs: day(2))
            let imp = Store(fileURL: tmp, persist: false)
            imp.data = AppData()
            imp.now = now
            for e in evs { _ = imp.add(e.parsedInput) }
            let sat = imp.agenda(for: day(2))
            parseOK = parseOK && sat.first?.title == "Хакатон ФКН" && Fmt.time(sat.first!.end) == "18:30"
                && imp.agenda(for: day(5)).contains { $0.title == "Открытая лекция по ML" && $0.minutes == 60 }
                && imp.agenda(for: day(5)).contains { $0.title == "Английский" && $0.recurring }      // вт 13-го
                && imp.allDayItems(for: day(9)).contains { $0.title == "День открытых дверей" }     // весь день → событие
                && imp.data.tasks.isEmpty
        }
        print(parseOK ? "✓" : "✗", "ответ DeepSeek разобран, мероприятия встали в расписание")
        if !parseOK { ok = false }

        // Задачи и заметки прямо в проект
        let ns = Store(fileURL: tmp, persist: false)
        ns.data = AppData()
        let study = ns.ensureProject(named: "Учёба")
        _ = ns.addTask("прочитать статью 40м до пт", projectID: study.id)
        ns.addNote("Спросить у куратора про практику\nи про общагу", projectID: study.id)
        let tk = ns.data.tasks.first
        var notesOK = tk?.projectID == study.id && tk?.estimate == 40 && tk?.title == "Прочитать статью"
            && ns.notes(project: study.id).count == 1 && ns.notes(project: nil).count == 1
        ns.noteToTask(ns.data.notes[0].id)
        notesOK = notesOK && ns.data.notes.isEmpty && ns.data.tasks.contains { $0.title == "Спросить у куратора про практику" && $0.projectID == study.id }
        print(notesOK ? "✓" : "✗", "задачи и заметки в проект без хештега, заметка → задача")
        if !notesOK { ok = false }

        // Пересечения в сетке недели — колонками
        let mk: (String, Int, Int) -> AgendaItem = { id, from, to in
            AgendaItem(id: id, title: id, start: today.addingTimeInterval(TimeInterval(from * 60)),
                       end: today.addingTimeInterval(TimeInterval(to * 60)), color: .white, kind: .calendar(id))
        }
        let slots = PlannerLayout.overlapSlots([mk("A", 600, 720), mk("B", 660, 780), mk("C", 750, 840), mk("D", 900, 960)])
        let overlapOK = slots["A"]?.col == 0 && slots["B"]?.col == 1 && slots["C"]?.col == 0
            && slots["A"]?.cols == 2 && slots["C"]?.cols == 2 && slots["D"]?.cols == 1
        print(overlapOK ? "✓" : "✗", "пересекающиеся мероприятия встают рядом, а не друг на друга")
        if !overlapOK { ok = false }

        // Мероприятие на весь день — событие (не задача); «Отменить» убирает добавленное
        let ad = Store(fileURL: tmp, persist: false)
        ad.data = AppData()
        ad.now = now
        var halloween = ParsedInput()
        halloween.kind = .event
        halloween.title = "Ярмарка студклубов"
        halloween.day = day(22)
        halloween.allDay = true
        ad.lastCreated = []
        _ = ad.add(halloween)
        _ = ad.add(QuickParser.parse("завтра 19:00-21:00 ужин", now: now))
        var allDayOK = ad.data.tasks.isEmpty && ad.allDayItems(for: day(22)).first?.title == "Ярмарка студклубов"
            && ad.agenda(for: day(22)).isEmpty && ad.agenda(for: day(1)).count == 1
        _ = ad.undoLastCreated()
        allDayOK = allDayOK && ad.data.events.isEmpty
        print(allDayOK ? "✓" : "✗", "«весь день» — событие, а не задача; «Отменить» убирает добавленное")
        if !allDayOK { ok = false }

        // «Камни»: несделанный блок тащится за «сейчас», потом возвращается в «Не успел»
        let st = Store(fileURL: tmp, persist: false)
        st.data = AppData()
        st.now = now
        let study2 = st.ensureProject(named: "Учёба")
        _ = st.addTask("Конспект 1ч", projectID: study2.id)
        _ = st.addTask("Вчерашнее 30м", projectID: study2.id)
        let konspekt = st.data.tasks[0], yesterdayTask = st.data.tasks[1]
        let b1 = st.placeBlock(taskID: konspekt.id, start: today.addingTimeInterval(10 * 3600), minutes: 60)
        _ = st.placeBlock(taskID: yesterdayTask.id, start: day(-1).addingTimeInterval(15 * 3600), minutes: 30)
        var stoneOK = st.stones(now: now).map(\.task.id) == [konspekt.id]
        let shown = st.timelineItems(day: now, now: now).first { $0.stone }
        stoneOK = stoneOK && shown?.start == now && shown?.end == now.addingTimeInterval(3600)
        st.rolloverStones(now: now)                                  // вчерашний — в «Не успел»
        stoneOK = stoneOK && st.overdueTasks(filter: nil, now: now).map(\.id) == [yesterdayTask.id]
        st.doNow(blockID: b1.id, now: now)                           // «Делаю сейчас»
        stoneOK = stoneOK && st.stones(now: now).isEmpty
            && st.data.blocks.first { $0.taskID == konspekt.id }?.start == now.roundedUp(minutes: 5)
        let later = now.addingTimeInterval(2 * 3600)
        let stoneBlock = st.stones(now: later).first?.block
        st.returnToList(blockID: stoneBlock!.id, now: later)         // «Вернуть в список»
        stoneOK = stoneOK && st.overdueTasks(filter: nil, now: later).count == 2
        _ = st.startNow(taskID: konspekt.id, now: later)             // «сейчас» из «Не успел»
        stoneOK = stoneOK && st.overdueTasks(filter: nil, now: later).map(\.id) == [yesterdayTask.id]
            && st.task(konspekt.id)?.missedAt == nil
        print(stoneOK ? "✓" : "✗", "«камень» тащится за линией, «делаю сейчас», возврат в «Не успел», «сейчас»")
        if !stoneOK { ok = false }

        // Чаты: текст, фото, файлы; удаление чистит файлы; порядок чатов
        let chatDir = FileManager.default.temporaryDirectory.appendingPathComponent("ostrovok-chat-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        let cs = Store(fileURL: chatDir.appendingPathComponent("data.json"), persist: false)
        cs.data = AppData()
        let a = cs.ensureProject(named: "Учёба"), b = cs.ensureProject(named: "Работа"), c = cs.ensureProject(named: "Личное")
        let doc = chatDir.appendingPathComponent("конспект.txt")
        try? "лекция 3".write(to: doc, atomically: true, encoding: .utf8)
        cs.sendMessage(chat: a.id, text: "Ссылка на зум в чате группы", pending: [])
        cs.sendMessage(chat: a.id, text: "", pending: [PendingAttachment(file: doc, name: doc.lastPathComponent),
                                                       PendingAttachment(image: SelfTest.sampleScreenshot(), name: "Изображение.png")])
        let msgs = cs.chatMessages(a.id)
        let stored = msgs.last?.attachments ?? []
        var chatOK = msgs.count == 2 && stored.count == 2 && stored.contains { $0.isImage } && stored.contains { !$0.isImage && $0.originalName == "конспект.txt" }
            && stored.allSatisfy { FileManager.default.fileExists(atPath: cs.attachmentURL($0).path) }
        cs.deleteMessage(msgs.last!.id)
        chatOK = chatOK && stored.allSatisfy { !FileManager.default.fileExists(atPath: cs.attachmentURL($0).path) }
        cs.moveChat(c.id, before: a.id)
        chatOK = chatOK && cs.data.projects.map(\.name) == ["Личное", "Учёба", "Работа"]
        cs.moveChat(c.id, by: 2)
        chatOK = chatOK && cs.data.projects.map(\.name) == ["Учёба", "Работа", "Личное"]
        _ = cs.messageToTask(msgs[0].id)
        chatOK = chatOK && cs.data.tasks.contains { $0.title == "Ссылка на зум в чате группы" && $0.projectID == a.id }
        cs.deleteChat(b.id)
        chatOK = chatOK && cs.data.projects.count == 2
        // Старые заметки переезжают в чаты
        var legacy = AppData()
        legacy.projects = [a]
        legacy.notes = [Note(text: "старая заметка", projectID: a.id), Note(text: "без проекта", projectID: nil)]
        let legacyURL = chatDir.appendingPathComponent("legacy.json")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(legacy).write(to: legacyURL)
        let migrated = Store(fileURL: legacyURL, persist: false)
        chatOK = chatOK && migrated.data.notes.isEmpty && migrated.chatMessages(a.id).first?.text == "старая заметка"
            && migrated.data.projects.contains { $0.name == "Заметки" }
        try? FileManager.default.removeItem(at: chatDir)
        print(chatOK ? "✓" : "✗", "чаты: текст, фото, файлы, удаление, порядок, старые заметки → чаты")
        if !chatOK { ok = false }

        // Строка ввода: задачи тоже уходят в расписание
        let taskAnswer = """
        {"events":[{"title":"Ужин с Катей","date":"2026-10-10","start":"19:00","end":"21:00","location":"Пушкин","weekly_days":[]}],
         "tasks":[{"title":"Написать эссе","date":"2026-10-09","start":null,"estimate_minutes":120,"deadline":"2026-10-12","project":"Учёба"},
                  {"title":"Позвонить в деканат","date":"2026-10-08","start":"15:00","estimate_minutes":15,"deadline":null,"project":null}]}
        """
        var taskOK = false
        if case .success(let found) = DeepSeek.parse(taskAnswer) {
            let ts = Store(fileURL: tmp, persist: false)
            ts.data = AppData()
            ts.now = now
            let studyP = ts.ensureProject(named: "Учёба")
            ts.lastCreated = []
            let msgs = found.map { $0.isTask ? ts.addImportedTask($0, now: now) : (ts.add($0.parsedInput) ?? "") }
            let essay = ts.data.tasks.first { $0.title == "Написать эссе" }
            let call = ts.data.tasks.first { $0.title == "Позвонить в деканат" }
            let essayBlock = essay.flatMap { e in ts.data.blocks.first { $0.taskID == e.id } }
            let callBlock = call.flatMap { c in ts.data.blocks.first { $0.taskID == c.id } }
            taskOK = found.count == 3 && found.filter(\.isTask).count == 2
                && essay?.projectID == studyP.id && essay?.estimate == 120 && essay?.deadline == day(4).addingTimeInterval(23 * 3600 + 59 * 60)
                && essayBlock.map { cal.isDate($0.start, inSameDayAs: day(1)) } == true                // в указанный день
                && callBlock?.start == today.addingTimeInterval(15 * 3600) && callBlock.map { $0.end.timeIntervalSince($0.start) } == 900
                && ts.agenda(for: day(2)).contains { $0.title == "Ужин с Катей" }
            print("  " + msgs.joined(separator: " | "))
            _ = ts.undoLastCreated()
            taskOK = taskOK && ts.data.tasks.isEmpty && ts.data.blocks.isEmpty && ts.data.events.isEmpty
        }
        print(taskOK ? "✓" : "✗", "задачи из строки ввода сразу встают в расписание, «Отменить» убирает их")
        if !taskOK { ok = false }

        // Сочетания ⌘A / ⌘V в полях островка (раньше без меню «Правка» был «бульк»)
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 60),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
        field.stringValue = "проверка"
        panel.contentView?.addSubview(field)
        panel.makeFirstResponder(field)
        func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
        }
        let handledA = panel.performKeyEquivalent(with: key(kVK_ANSI_A, "ф", .command))   // русская раскладка: ⌘ + «ф»
        let editor = field.currentEditor() as? NSTextView
        let allSelected = editor?.selectedRange() == NSRange(location: 0, length: ("проверка" as NSString).length)
        let pasteRoutes = IslandPanel.editAction(for: key(kVK_ANSI_V, "м", .command)) == #selector(NSText.paste(_:))
            && editor?.responds(to: #selector(NSText.paste(_:))) == true
        let keysOK = handledA && allSelected && pasteRoutes
        print(keysOK ? "✓" : "✗", "⌘A/⌘V в полях островка работают (и в русской раскладке)")
        if !keysOK { ok = false }

        print(ok ? "\nВсё в порядке" : "\nЕсть ошибки")
        return ok
    }

    /// Картинка «как скриншот афиши» для проверки распознавания.
    static func sampleScreenshot() -> NSImage {
        let size = NSSize(width: 900, height: 420)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let lines: [(String, CGFloat, NSFont)] = [
            ("Анонсы на неделю 🎓", 360, .boldSystemFont(ofSize: 30)),
            ("Хакатон ФКН — суббота, 10 октября, 10:00–18:30", 300, .systemFont(ofSize: 24)),
            ("Покровский б-р, 11, регистрация до пятницы", 262, .systemFont(ofSize: 20)),
            ("Открытая лекция по ML — вторник 13.10 в 19:00", 200, .systemFont(ofSize: 24)),
            ("Английский: по понедельникам и четвергам 9:30–10:50, ауд. 402", 140, .systemFont(ofSize: 22)),
            ("День открытых дверей — 17 октября", 80, .systemFont(ofSize: 22)),
        ]
        for (text, y, font) in lines {
            (text as NSString).draw(at: NSPoint(x: 40, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        return image
    }

    static let sampleICS = [
        "BEGIN:VCALENDAR",
        "METHOD:PUBLISH",
        "PRODID:-//Moodle Pty Ltd//NONSGML Moodle Version 2024100700//EN",
        "VERSION:2.0",
        "BEGIN:VEVENT", "UID:4101@lms.example.ru", "SUMMARY:Листок 5 is due",
        "DESCRIPTION:Решить задачи 1–8\\, оформить в LaTeX", "CLASS:PUBLIC",
        "DTSTART:20261009T205900Z", "DTEND:20261009T205900Z", "CATEGORIES:Матанализ_2к", "END:VEVENT",
        "BEGIN:VEVENT", "UID:4102@lms.example.ru", "SUMMARY:Срок сдачи «Эссе: промышленная революция»",
        "DTSTART:20261012T205900Z", "CATEGORIES:История", "END:VEVENT",
        "BEGIN:VEVENT", "UID:4103@lms.example.ru", "SUMMARY:Тест по главе 3 открывается",
        "DTSTART:20261008T060000Z", "CATEGORIES:Английский", "END:VEVENT",
        "BEGIN:VEVENT", "UID:4104@lms.example.ru", "SUMMARY:Тест по главе 3 закрывается",
        "DTSTART:20261011T205900Z", "CATEGORIES:Английский", "END:VEVENT",
        "BEGIN:VEVENT", "UID:4105@lms.example.ru", "SUMMARY:Лабораторная работа 2: сорт",
        " ировки is due",
        "DTSTART:20261015T205900Z", "CATEGORIES:Алгоритмы", "END:VEVENT",
        "BEGIN:VEVENT", "UID:4106@lms.example.ru", "SUMMARY:Проект: курсовая\\, этап 1 is due",
        "DTSTART;VALUE=DATE:20261020", "CATEGORIES:Алгоритмы", "END:VEVENT",
        "BEGIN:VEVENT", "UID:4107@lms.example.ru", "SUMMARY:Листок 4 is due",
        "DTSTART:20261001T205900Z", "CATEGORIES:Матанализ_2к", "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    static func describe(_ p: ParsedInput) -> String {
        var parts = ["\(p.kind == .task ? "задача" : "событие") «\(p.title)»"]
        if let pr = p.projectName { parts.append("#\(pr)") }
        if let e = p.estimate { parts.append(Fmt.duration(e)) }
        if let d = p.deadline { parts.append("срок \(Fmt.shortDate(d)) \(Fmt.time(d))") }
        if let s = p.startMinutes { parts.append("с \(s / 60):\(String(format: "%02d", s % 60))") }
        if let e = p.endMinutes { parts.append("до \(e / 60):\(String(format: "%02d", e % 60))") }
        if let d = p.day, p.kind == .event { parts.append("день \(Fmt.shortDate(d))") }
        if !p.weekdays.isEmpty { parts.append(Fmt.weekdays(p.weekdays)) }
        if p.priority { parts.append("важно") }
        return parts.joined(separator: ", ")
    }
}

/// `Ostrovok --snapshot <папка>` — рендер состояний островка в PNG на демо-данных.
enum Snapshot {
    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = SelfTest.refNow()
        let store = Store(fileURL: dir.appendingPathComponent("demo.json"), persist: false)
        var data = AppData()
        data.projects = [Project(name: "Учёба", colorIndex: 5), Project(name: "Работа", colorIndex: 1), Project(name: "Личное", colorIndex: 3)]
        store.data = data
        store.now = now
        for line in [
            "по пн ср чт 9:00-10:30 Матанализ #учёба",
            "11:00-12:30 Английский #учёба",
            "16:30-17:15 Созвон по проекту #работа",
            "Домашка по матану #учёба 1.5ч до пт !",
            "Эссе по истории #учёба 2ч до 12.10",
            "Дописать лендинг #работа 1ч завтра",
            "Прочитать главу 3 #учёба 45м",
            "Спортзал #личное 1ч",
            "Купить продукты #личное 20м сегодня",
        ] {
            _ = store.add(QuickParser.parse(line, now: now))
        }
        for line in ["16:00-17:30 Встреча студклуба", "завтра 10:00-11:30 Лекция приглашённого профессора",
                     "завтра 10:30-12:00 Консультация по проекту"] {
            _ = store.add(QuickParser.parse(line, now: now))
        }
        var hw = ParsedInput()
        hw.kind = .event; hw.title = "Ярмарка студклубов"; hw.allDay = true
        hw.day = Calendar.current.startOfDay(for: now)
        _ = store.add(hw)
        store.plan(day: now, now: now.addingTimeInterval(-40 * 60))
        if let t = store.data.tasks.first(where: { $0.title.hasPrefix("Купить") }) { store.toggleDone(t.id) }
        // Дальше «сейчас» = 13:20, первый блок уже идёт.
        store.now = now

        let model = IslandModel()
        model.notchWidth = 186
        model.notchHeight = 32
        model.wingWidth = 150
        model.expandedSize = CGSize(width: 1360, height: 620)

        render(model, store, to: dir.appendingPathComponent("1-collapsed.png"), crop: 120)
        model.peek = Peek(icon: "bell.fill", title: "Созвон по проекту", subtitle: "Через 5м · в 16:30", color: Palette.colors[1])
        render(model, store, to: dir.appendingPathComponent("2-peek.png"), crop: 140)
        model.peek = nil
        model.state = .expanded
        render(model, store, to: dir.appendingPathComponent("3-expanded.png"))
        // чаты с заметками, фото и файлом
        if let study = store.data.projects.first(where: { $0.name == "Учёба" }) {
            store.sendMessage(chat: study.id, text: "Ссылка на зум по матану — в чате группы", pending: [])
            store.sendMessage(chat: study.id, text: "Скрин расписания на семестр", pending: [PendingAttachment(image: SelfTest.sampleScreenshot(), name: "Изображение.png")])
            let doc = dir.appendingPathComponent("Билеты к экзамену.pdf")
            try? Data("demo".utf8).write(to: doc)
            store.sendMessage(chat: study.id, text: "", pending: [PendingAttachment(file: doc, name: doc.lastPathComponent)])
            model.selectedChat = study.id
        }
        if let work = store.data.projects.first(where: { $0.name == "Работа" }) {
            store.sendMessage(chat: work.id, text: "Идея: сделать лендинг тёмным", pending: [])
        }
        // «камень»: блок утром не сделан
        if let t = store.data.tasks.first(where: { $0.title.hasPrefix("Прочитать главу") }) {
            store.data.blocks.removeAll { $0.taskID == t.id }
            _ = store.placeBlock(taskID: t.id, start: Calendar.current.startOfDay(for: now).addingTimeInterval(11 * 3600 + 45 * 60), minutes: 45)
        }
        if let t = store.data.tasks.first(where: { $0.title.hasPrefix("Спортзал") }) {
            store.data.blocks.removeAll { $0.taskID == t.id }
            if let i = store.data.tasks.firstIndex(where: { $0.id == t.id }) { store.data.tasks[i].missedAt = now.addingTimeInterval(-86400) }
        }
        render(model, store, to: dir.appendingPathComponent("3-expanded.png"))
        model.timelineSelection = store.timelineItems(day: now, now: now).first { $0.stone }?.id
        render(model, store, to: dir.appendingPathComponent("3b-details.png"))
        model.timelineSelection = store.timelineItems(day: now, now: now).first { $0.item.title == "Созвон по проекту" }?.id
        render(model, store, to: dir.appendingPathComponent("3c-event-details.png"))
        model.timelineSelection = nil
        model.quickText = "Лаба по физике #учёба 2ч до пт !"
        render(model, store, to: dir.appendingPathComponent("4-typing.png"))
        model.quickText = ""
        model.showSettings = true
        render(model, store, to: dir.appendingPathComponent("5-settings.png"))
        model.showSettings = false

        store.applyHomework(ICSParser.parse(SelfTest.sampleICS), now: now)
        if let c = store.data.courses.first(where: { $0.name == "Матанализ 2к" }) {
            store.data.courses[store.data.courses.firstIndex(of: c)!].name = "Матанализ"
            store.setCourseEstimate(c.id, minutes: 90)
        }
        if let first = store.homeworkTasks(course: nil, showDone: false).first {
            _ = store.scheduleManual(taskID: first.id, start: Calendar.current.startOfDay(for: now).addingTimeInterval(19 * 3600), minutes: 90)
        }
        model.page = .homework
        render(model, store, to: dir.appendingPathComponent("7-homework.png"))
        store.distributeHomework(now: now)
        model.page = .hwPlanner
        model.plannerSelectedTask = store.homeworkTasks(course: nil, showDone: false).first { $0.title.hasPrefix("Эссе") }?.id
        render(model, store, to: dir.appendingPathComponent("9-planner.png"))
        model.page = .homework
        model.schedulingTaskID = store.homeworkTasks(course: nil, showDone: false).dropFirst(2).first?.id
        render(model, store, to: dir.appendingPathComponent("8-homework-schedule.png"))
        model.schedulingTaskID = nil
        model.page = .plan
        model.state = .collapsed
        model.dropZone = true
        render(model, store, to: dir.appendingPathComponent("10-dropzone.png"), crop: 160)
        model.dropZone = false
        model.state = .expanded
        model.importImage = SelfTest.sampleScreenshot()
        model.importPhase = .review
        let cal = Calendar.current
        let base = cal.startOfDay(for: now)
        model.importEvents = [
            ImportedEvent(title: "Хакатон ФКН", day: base.addingTimeInterval(2 * 86400), start: 600, end: 1110,
                          location: "Покровский б-р, 11", weekdays: []),
            ImportedEvent(title: "Открытая лекция по ML", day: base.addingTimeInterval(5 * 86400), start: 1140, end: nil,
                          location: nil, weekdays: []),
            ImportedEvent(title: "Английский", day: base.addingTimeInterval(4 * 86400), start: 570, end: 650,
                          location: "ауд. 402", weekdays: [2, 5]),
            ImportedEvent(title: "День открытых дверей", day: base.addingTimeInterval(9 * 86400), start: nil, end: nil,
                          location: nil, weekdays: [], selected: false),
        ]
        render(model, store, to: dir.appendingPathComponent("11-import.png"))
        model.importPhase = .idle
        if let study = store.data.projects.first {
            store.addNote("Спросить у куратора про практику и про общагу", projectID: study.id)
            store.addNote("Ссылка на зум по матану — в чате группы", projectID: study.id)
            model.projectFilter = study.id
        }
        model.listMode = .notes
        model.composerText = ""
        render(model, store, to: dir.appendingPathComponent("12-notes.png"))
        model.listMode = .tasks
        render(model, store, to: dir.appendingPathComponent("13-project-tasks.png"))
        model.projectFilter = nil
        model.wingWidth = 290
        model.state = .collapsed
        render(model, store, to: dir.appendingPathComponent("6-collapsed-wide.png"), crop: 120)
        print("Снимки сохранены в \(dir.path)")
    }

    private static func render(_ model: IslandModel, _ store: Store, to url: URL, crop: CGFloat? = nil) {
        let size = NSSize(width: model.expandedSize.width + 80, height: crop ?? (model.expandedSize.height + 60))
        let root = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.72, green: 0.52, blue: 0.58)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandRootView(model: model, store: store)
        }
        .frame(width: size.width, height: size.height)
        .transaction { $0.disablesAnimations = true }

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
