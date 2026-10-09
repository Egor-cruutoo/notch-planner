import SwiftUI

/// Страница «ДЗ»: каждая домашка — линия от «сейчас» до дедлайна.
struct HomeworkPage: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let hasFeed = !store.data.settings.homeworkFeedURL.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHomework = store.data.tasks.contains { $0.isHomework }
        VStack(spacing: 12) {
            QuickAddField(model: model, store: store, homeworkMode: true)
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if !hasFeed && !hasHomework {
                        LMSConnectCard(store: store, model: model)
                    } else {
                        HomeworkLines(model: model, store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))

                CourseSidebar(model: model, store: store)
                    .frame(width: 280)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Линии

struct HomeworkLines: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    private let labelWidth: CGFloat = 330

    var body: some View {
        let now = store.now
        let filter = model.hwCourseFilter.flatMap { store.course($0)?.id }
        let items = store.homeworkTasks(course: filter, showDone: model.hwShowDone)
        let horizon = HomeworkLines.horizon(items: items, now: now)

        VStack(alignment: .leading, spacing: 8) {
            toolbar(filter: filter)
            if items.isEmpty {
                EmptyState(icon: "graduationcap",
                           title: store.data.tasks.contains { $0.isHomework } ? "Все ДЗ сданы" : "Домашек пока нет",
                           hint: "Они подтянутся из LMS, или добавь сам: «Листок 5 #матан до пт 18:00»")
            } else {
                GeometryReader { geo in
                    let lineWidth = max(120, geo.size.width - labelWidth - 14)
                    VStack(spacing: 4) {
                        DayAxis(now: now, end: horizon, width: lineWidth)
                            .frame(height: 16)
                            .padding(.leading, labelWidth + 14)
                        ZStack(alignment: .topLeading) {
                            DayGrid(now: now, end: horizon, width: lineWidth)
                                .padding(.leading, labelWidth + 14)
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: 2) {
                                    ForEach(items) { t in
                                        HomeworkRow(task: t, model: model, store: store, now: now, end: horizon,
                                                    labelWidth: labelWidth, lineWidth: lineWidth)
                                    }
                                }
                                .padding(.bottom, 6)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    /// Правый край шкалы — полночь после самого дальнего дедлайна (от 7 до 35 дней).
    static func horizon(items: [TaskItem], now: Date) -> Date {
        let cal = Calendar.current
        let latest = items.filter { !$0.done }.compactMap(\.deadline).max() ?? now
        let days = min(35, max(7, Int(ceil(latest.timeIntervalSince(now) / 86400)) + 1))
        return cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now))!
    }

    @ViewBuilder private func toolbar(filter: UUID?) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "Все", count: store.openHomeworkCount, color: .white, selected: filter == nil) {
                        model.hwCourseFilter = nil
                    }
                    ForEach(store.data.courses) { c in
                        FilterChip(title: c.name, count: store.openHomework(course: c.id),
                                   color: Palette.color(c.colorIndex), selected: filter == c.id) {
                            model.hwCourseFilter = c.id
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            SyncStatus(store: store)
            Button {
                withAnimation(.snappy) { model.hwShowDone.toggle() }
            } label: {
                Image(systemName: model.hwShowDone ? "eye.fill" : "eye.slash")
            }
            .buttonStyle(PillButtonStyle())
            .help(model.hwShowDone ? "Скрыть сданные" : "Показать сданные")
        }
    }
}

struct SyncStatus: View {
    @ObservedObject var store: Store

    var body: some View {
        let hasFeed = !store.data.settings.homeworkFeedURL.trimmingCharacters(in: .whitespaces).isEmpty
        if hasFeed {
            HStack(spacing: 6) {
                switch store.homeworkSync {
                case .syncing:
                    ProgressView().controlSize(.mini)
                    Text("обновляю…")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.orange)
                    Text(message).lineLimit(1)
                case .idle:
                    if let last = store.data.settings.homeworkLastSync {
                        Text("LMS: \(Fmt.ago(last, now: store.now))")
                    }
                }
                IconButton(symbol: "arrow.clockwise", size: 11) { store.syncHomework() }
                    .help("Обновить из LMS")
                if let host = store.homeworkFeedHost, let url = URL(string: "https://\(host)/my/") {
                    IconButton(symbol: "safari", size: 11) { NSWorkspace.shared.open(url) }
                        .help("Открыть LMS")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: 360, alignment: .trailing)
        }
    }
}

struct DayAxis: View {
    let now: Date
    let end: Date
    let width: CGFloat

    private static let dayF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "EE d"
        return f
    }()

    var body: some View {
        let days = DayGrid.midnights(now: now, end: end)
        let total = end.timeIntervalSince(now)
        let perDay = width / CGFloat(total / 86400)
        ZStack(alignment: .topLeading) {
            Text("сейчас")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Palette.red)
            ForEach(days, id: \.self) { d in
                let x = CGFloat(d.timeIntervalSince(now) / total) * width
                if perDay > 26 || Calendar.current.component(.weekday, from: d) == 2 {
                    Text(DayAxis.dayF.string(from: d))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(isWeekend(d) ? 0.28 : 0.42))
                        .fixedSize()
                        .offset(x: x + 3)
                        .opacity(x > 40 && x < width - 20 ? 1 : 0)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func isWeekend(_ d: Date) -> Bool {
        let w = Calendar.current.component(.weekday, from: d)
        return w == 1 || w == 7
    }
}

struct DayGrid: View {
    let now: Date
    let end: Date
    let width: CGFloat

    static func midnights(now: Date, end: Date) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        var d = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        while d < end {
            out.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    var body: some View {
        let total = end.timeIntervalSince(now)
        let days = DayGrid.midnights(now: now, end: end)
        let cal = Calendar.current
        ZStack(alignment: .topLeading) {
            ForEach(days, id: \.self) { d in
                let x = CGFloat(d.timeIntervalSince(now) / total) * width
                let w = cal.component(.weekday, from: d)
                if w == 7 {
                    // Выходные слегка подсвечены
                    let dayW = CGFloat(min(2 * 86400, end.timeIntervalSince(d)) / total) * width
                    Rectangle().fill(Color.white.opacity(0.03)).frame(width: dayW).offset(x: x)
                }
                Rectangle().fill(Color.white.opacity(w == 2 ? 0.12 : 0.06)).frame(width: 1).offset(x: x)
            }
            Rectangle().fill(Palette.red.opacity(0.7)).frame(width: 1.5)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct HomeworkRow: View {
    let task: TaskItem
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let now: Date
    let end: Date
    let labelWidth: CGFloat
    let lineWidth: CGFloat
    @State private var hover = false

    var body: some View {
        let color = store.courseColor(task.courseID)
        let course = store.course(task.courseID)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 9) {
                    CheckButton(done: task.done, color: color) {
                        withAnimation(.snappy) { store.toggleDone(task.id) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .strikethrough(task.done, color: .white.opacity(0.5))
                            .foregroundStyle(task.done ? .white.opacity(0.4) : .white)
                        HStack(spacing: 4) {
                            Text(course?.name ?? "Без предмета").foregroundStyle(color.opacity(0.9))
                            if let d = task.deadline {
                                let info = Fmt.deadline(d, now: now)
                                Text("· \(info.text)").foregroundStyle(info.color)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !task.done {
                        EstimateMenu(task: task, store: store)
                        IconButton(symbol: "calendar.badge.plus", active: model.schedulingTaskID == task.id, size: 11) {
                            withAnimation(.snappy) {
                                model.schedulingTaskID = model.schedulingTaskID == task.id ? nil : task.id
                            }
                        }
                        .help("Записать на время")
                    }
                }
                .frame(width: labelWidth)

                DeadlineLine(task: task, store: store, color: color, now: now, end: end, width: lineWidth)
                    .frame(width: lineWidth, height: 30)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hover || model.schedulingTaskID == task.id ? 0.05 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .contextMenu { menu }

            if model.schedulingTaskID == task.id {
                ScheduleStrip(task: task, model: model, store: store)
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(task.done ? "Вернуть в работу" : "Сдано") { store.toggleDone(task.id) }
        if !task.done {
            Button("Поставить в ближайшее окно") { model.flash(store.scheduleNext(task.id)) }
            Button("Записать на время…") { model.schedulingTaskID = task.id }
            Button("Расписать в сетке недели") {
                model.plannerSelectedTask = task.id
                model.page = .hwPlanner
            }
            if store.nextBlock(for: task.id, now: Date()) != nil {
                Button("Убрать из плана") { store.unplanTask(task.id) }
            }
        }
        Divider()
        Menu("Предмет") {
            Button("Без предмета") { store.updateTask(task.id) { $0.courseID = nil } }
            ForEach(store.data.courses) { c in
                Button((task.courseID == c.id ? "✓ " : "") + c.name) {
                    store.updateTask(task.id) {
                        $0.courseID = c.id
                        if $0.customEstimate != true { $0.estimate = c.estimate }
                    }
                }
            }
        }
        Button("Удалить", role: .destructive) { store.deleteTask(task.id) }
    }
}

/// Линия от «сейчас» до дедлайна, поверх — когда ДЗ запланировано делать.
struct DeadlineLine: View {
    let task: TaskItem
    @ObservedObject var store: Store
    let color: Color
    let now: Date
    let end: Date
    let width: CGFloat

    var body: some View {
        let total = end.timeIntervalSince(now)
        let xOf: (Date) -> CGFloat = { d in CGFloat(d.timeIntervalSince(now) / total) * width }
        let blocks = store.data.blocks.filter { $0.taskID == task.id && $0.end > now }
        ZStack(alignment: .leading) {
            if let deadline = task.deadline {
                if deadline <= now {
                    // Просрочено — красная метка у «сейчас».
                    HStack(spacing: 5) {
                        Capsule().fill(Palette.red).frame(width: 14, height: 8)
                        Text("просрочено на \(Fmt.countdown(now.timeIntervalSince(deadline)))")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Palette.red)
                    }
                } else {
                    let x = min(width, xOf(deadline))
                    let fill = task.done ? AnyShapeStyle(color.opacity(0.18))
                                         : AnyShapeStyle(LinearGradient(colors: [color.opacity(0.35), color],
                                                                         startPoint: .leading, endPoint: .trailing))
                    Capsule()
                        .fill(fill)
                        .frame(width: max(8, x), height: 8)
                    if deadline <= end {
                        Circle()
                            .fill(task.done ? color.opacity(0.4) : color)
                            .overlay(Circle().strokeBorder(Color.black, lineWidth: 2))
                            .frame(width: 13, height: 13)
                            .offset(x: x - 6.5)
                    }
                    let label = "\(Fmt.time(deadline)) · через \(Fmt.countdown(deadline.timeIntervalSince(now)))"
                    if width - x > 130 {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize()
                            .offset(x: x + 10)
                            .opacity(task.done ? 0 : 1)
                    } else {
                        // Справа места нет — подпись на самой линии, перед точкой дедлайна.
                        Text(label)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.7)))
                            .fixedSize()
                            .frame(width: max(0, x - 10), alignment: .trailing)
                            .opacity(task.done ? 0 : 1)
                    }
                }
            } else {
                Text("без срока")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.3))
            }

            // Запланированные блоки
            ForEach(blocks) { b in
                let bx = max(0, xOf(b.start))
                let bw = max(5, CGFloat(b.end.timeIntervalSince(b.start) / total) * width)
                if bx < width {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white)
                        .frame(width: min(bw, width - bx), height: 16)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: bx)
                        .help("\(Fmt.when(b.start, now: now)) · \(Fmt.duration(Int(b.end.timeIntervalSince(b.start) / 60)))")
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct EstimateMenu: View {
    let task: TaskItem
    @ObservedObject var store: Store

    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60, 90, 120, 180, 240, 360], id: \.self) { m in
                Button((task.estimate == m ? "✓ " : "") + Fmt.duration(m)) {
                    store.updateTask(task.id) {
                        $0.estimate = m
                        $0.customEstimate = true
                    }
                }
            }
            if task.customEstimate == true, let c = store.course(task.courseID) {
                Divider()
                Button("Как у предмета (\(Fmt.duration(c.estimate)))") {
                    store.updateTask(task.id) {
                        $0.estimate = c.estimate
                        $0.customEstimate = nil
                    }
                }
            }
        } label: {
            Badge(text: Fmt.duration(task.estimate), color: Color.white.opacity(task.customEstimate == true ? 0.85 : 0.55),
                  icon: "hourglass")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Сколько займёт")
    }
}

/// Выбор дня и времени, когда делать ДЗ. Блок попадает в план и в календарь.
struct ScheduleStrip: View {
    let task: TaskItem
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var dayOffset = 0
    @State private var startMinutes = 18 * 60
    @State private var duration = 60
    @State private var ready = false

    var body: some View {
        let now = store.now
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let lastOffset = task.deadline.map { max(1, min(6, cal.dateComponents([.day], from: today, to: cal.startOfDay(for: $0)).day ?? 6)) } ?? 6
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0...lastOffset, id: \.self) { off in
                    let d = cal.date(byAdding: .day, value: off, to: today)!
                    SegmentTab(title: off == 0 ? "сегодня" : off == 1 ? "завтра" : Fmt.dayWord(d, now: now),
                               selected: dayOffset == off) {
                        dayOffset = off
                        suggest()
                    }
                }
            }
            Divider().frame(height: 18).overlay(Color.white.opacity(0.1))
            ValueStepper(text: String(format: "%02d:%02d", startMinutes / 60, startMinutes % 60)) {
                startMinutes = max(0, startMinutes - 15)
            } plus: {
                startMinutes = min(23 * 60 + 45, startMinutes + 15)
            }
            ValueStepper(text: Fmt.duration(duration)) {
                duration = max(15, duration - 15)
            } plus: {
                duration = min(8 * 60, duration + 15)
            }
            if let deadline = task.deadline, startDate.addingTimeInterval(TimeInterval(duration * 60)) > deadline {
                Text("позже дедлайна")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.orange)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Button {
                let msg = store.scheduleManual(taskID: task.id, start: startDate, minutes: duration)
                model.flash(msg)
                withAnimation(.snappy) { model.schedulingTaskID = nil }
            } label: {
                Label(store.writeCalendarTitle.map { "В «\($0)»" } ?? "В план", systemImage: "calendar.badge.plus")
                    .lineLimit(1)
            }
            .buttonStyle(PillButtonStyle(tint: store.courseColor(task.courseID), prominent: true))
            .fixedSize()
            IconButton(symbol: "xmark", size: 10) {
                withAnimation(.snappy) { model.schedulingTaskID = nil }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        .onAppear {
            guard !ready else { return }
            ready = true
            duration = task.estimate
            // Первый день, где есть окно под ДЗ.
            for off in 0...lastOffsetFor(now: now) {
                dayOffset = off
                if suggestFound() { return }
            }
            dayOffset = 0
            suggest()
        }
    }

    private var startDate: Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: store.now))!
        return day.addingTimeInterval(TimeInterval(startMinutes * 60))
    }

    private func lastOffsetFor(now: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return task.deadline.map { max(1, min(6, cal.dateComponents([.day], from: today, to: cal.startOfDay(for: $0)).day ?? 6)) } ?? 6
    }

    @discardableResult
    private func suggestFound() -> Bool {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: store.now))!
        guard let slot = store.suggestSlot(minutes: duration, day: day, now: store.now) else { return false }
        let comps = cal.dateComponents([.hour, .minute], from: slot)
        startMinutes = (comps.hour ?? 18) * 60 + (comps.minute ?? 0)
        return true
    }

    private func suggest() {
        if !suggestFound() { startMinutes = max(startMinutes, 18 * 60) }
    }
}

struct ValueStepper: View {
    let text: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus", size: 9, action: minus)
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 48)
            IconButton(symbol: "plus", size: 9, action: plus)
        }
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .fixedSize()
    }
}

// MARK: - Предметы

struct CourseSidebar: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var editingFeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Предметы")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.45))
                Text("сколько обычно уходит на одно ДЗ")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.32))
            }
            if store.data.courses.isEmpty {
                Text("Появятся сами из LMS или из «#предмет» в строке ввода.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(store.data.courses) { c in
                            CourseRow(course: binding(for: c.id), store: store, model: model)
                        }
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            if editingFeed {
                FeedField(store: store, model: model) { editingFeed = false }
            } else {
                Button {
                    editingFeed = true
                } label: {
                    Label(store.data.settings.homeworkFeedURL.isEmpty ? "Подключить Moodle" : "Ссылка на LMS",
                          systemImage: "link")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    private func binding(for id: UUID) -> Binding<Course> {
        Binding(
            get: { store.data.courses.first { $0.id == id } ?? Course(key: "", name: "", colorIndex: 0, estimate: 60) },
            set: { newValue in
                if let i = store.data.courses.firstIndex(where: { $0.id == id }) { store.data.courses[i] = newValue }
            })
    }
}

struct CourseRow: View {
    @Binding var course: Course
    @ObservedObject var store: Store
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Button {
                    course.colorIndex = (course.colorIndex + 1) % Palette.colors.count
                } label: {
                    Circle().fill(Palette.color(course.colorIndex)).frame(width: 11, height: 11).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Сменить цвет")
                TextField("Название", text: $course.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                let open = store.openHomework(course: course.id)
                if open > 0 {
                    Text("\(open)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            HStack(spacing: 6) {
                ValueStepper(text: Fmt.duration(course.estimate)) {
                    store.setCourseEstimate(course.id, minutes: max(15, course.estimate - 15))
                } plus: {
                    store.setCourseEstimate(course.id, minutes: min(10 * 60, course.estimate + 15))
                }
                if course.key != course.name {
                    Text(course.key)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.25))
                        .lineLimit(1)
                        .help("Название в LMS")
                }
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .contextMenu {
            Button("Показать только этот предмет") { model.hwCourseFilter = course.id }
            Button("Удалить предмет", role: .destructive) {
                if model.hwCourseFilter == course.id { model.hwCourseFilter = nil }
                store.deleteCourse(course.id)
            }
        }
    }
}

struct FeedField: View {
    @ObservedObject var store: Store
    @ObservedObject var model: IslandModel
    var onDone: () -> Void = {}
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $text, prompt: Text("https://…/calendar/export_execute.php?…"))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                .onSubmit(save)
            HStack(spacing: 6) {
                Button("Сохранить", action: save)
                    .buttonStyle(PillButtonStyle(tint: Palette.colors[3], prominent: true))
                if !store.data.settings.homeworkFeedURL.isEmpty {
                    Button("Отключить") {
                        store.data.settings.homeworkFeedURL = ""
                        store.homeworkSync = .idle
                        onDone()
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.red))
                }
            }
        }
        .onAppear { text = store.data.settings.homeworkFeedURL }
    }

    private func save() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.data.settings.homeworkFeedURL = value
        if !value.isEmpty { store.syncHomework() }
        onDone()
    }
}

struct LMSConnectCard: View {
    @ObservedObject var store: Store
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill").foregroundStyle(Palette.colors[5])
                Text("Подключи Moodle — дедлайны будут подтягиваться сами")
                    .font(.system(size: 14, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 5) {
                step(1, "Открой LMS → «Календарь» → «Импорт или экспорт календарей» → «Экспортировать календарь».")
                step(2, "Выбери «Все курсы» и «Недавние и следующие 60 дней», нажми «Получить URL календаря».")
                step(3, "Скопируй ссылку и вставь сюда:")
            }
            FeedField(store: store, model: model)
                .frame(maxWidth: 560)
            Text("В ссылке твой личный ключ — Островок хранит её только на этом Mac. Можно и без LMS: пиши ДЗ в строку выше — «Листок 5 #матан до пт 18:00».")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.1)))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
