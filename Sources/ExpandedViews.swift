import SwiftUI

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let day = model.selectedDay(now: store.now)
        VStack(spacing: 12) {
            HeaderRow(model: model, store: store)
                .frame(height: model.notchHeight)
            if model.importPhase != .idle {
                ImportPanel(model: model, store: store)
            } else if model.showSettings {
                SettingsPanel(model: model, store: store)
            } else if model.page == .homework {
                HomeworkPage(model: model, store: store)
            } else if model.page == .hwPlanner {
                WeekPlanner(model: model, store: store)
            } else {
                TimelinePanel(model: model, store: store)
                EventBar(model: model, store: store)
                HStack(alignment: .top, spacing: 12) {
                    ChatsPanel(model: model, store: store)
                        .frame(width: (model.expandedSize.width - 52 - 12) * 0.52)
                    TasksColumn(model: model, store: store)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
        .foregroundStyle(.white)
        .coordinateSpace(name: "main")
        .overlay(alignment: .topLeading) { overlays(day: day) }
    }

    /// Карточка подробностей под шкалой и задача, которую тащат на шкалу.
    @ViewBuilder private func overlays(day: Date) -> some View {
        if model.page == .plan && !model.showSettings && model.importPhase == .idle {
            if let sel = model.timelineSelection, let geo = model.timelineGeo {
                let all = store.timelineItems(day: day, now: store.now)
                    + store.allDayItems(for: day).map { TimelineDisplay(item: $0, start: $0.start, end: $0.end, stone: false) }
                if let d = all.first(where: { $0.id == sel }) {
                    let cardW: CGFloat = 360
                    let anchor = d.item.allDay ? geo.frame.minX + 160 : geo.frame.minX + geo.x(of: d.start)
                    TimelineDetailsCard(display: d, model: model, store: store)
                        .frame(width: cardW)
                        .offset(x: max(26, min(model.expandedSize.width - cardW - 26, anchor - 40)), y: geo.frame.maxY + 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if let td = model.taskDrag, let t = store.task(td.taskID) {
                FloatingChip(title: t.title, minutes: store.defaultBlockMinutes(t, now: store.now), color: store.taskColor(t))
                    .offset(x: td.location.x + 12, y: td.location.y + 8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Шапка у выреза

struct HeaderRow: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let progress = store.todayProgress(now: store.now)
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    SegmentTab(title: "План", selected: model.page == .plan && !model.showSettings) {
                        model.showSettings = false
                        model.page = .plan
                    }
                    SegmentTab(title: store.openHomeworkCount > 0 ? "ДЗ \(store.openHomeworkCount)" : "ДЗ",
                               selected: model.page == .homework && !model.showSettings) {
                        model.showSettings = false
                        model.page = .homework
                    }
                    SegmentTab(title: "Расписать", selected: model.page == .hwPlanner && !model.showSettings) {
                        model.showSettings = false
                        model.page = .hwPlanner
                    }
                }
                .padding(.trailing, 4)
                Text(Fmt.dayTitle(store.now))
                    .font(.system(size: 13, weight: .semibold))
                Text(Fmt.time(store.now))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: model.notchWidth + 24)

            HStack(spacing: 4) {
                if progress.total > 0 {
                    HStack(spacing: 6) {
                        Text("Сегодня \(progress.done) из \(progress.total)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        ProgressRing(value: Double(progress.done) / Double(progress.total))
                            .frame(width: 13, height: 13)
                    }
                    .padding(.trailing, 6)
                }
                IconButton(symbol: model.pinned ? "pin.fill" : "pin", active: model.pinned) {
                    model.pinned.toggle()
                }
                .help("Не сворачивать")
                IconButton(symbol: model.showSettings ? "xmark" : "gearshape", active: model.showSettings) {
                    model.showSettings.toggle()
                }
                .help("Настройки")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Шкала дня

struct TimelineStrip: View {
    let items: [AgendaItem]
    let day: Date
    let now: Date
    let startHour: Int
    let endHour: Int
    var selectedID: String? = nil
    var onSelect: (String) -> Void = { _ in }

    struct Lane: Identifiable {
        let item: AgendaItem
        let lane: Int
        var id: String { item.id }
    }

    static func lanes(_ items: [AgendaItem]) -> [Lane] {
        var ends: [Date] = []
        var out: [Lane] = []
        for it in items.sorted(by: { $0.start < $1.start }) {
            if let i = ends.firstIndex(where: { $0 <= it.start }) {
                ends[i] = it.end
                out.append(Lane(item: it, lane: i))
            } else {
                ends.append(it.end)
                out.append(Lane(item: it, lane: ends.count - 1))
            }
        }
        return out
    }

    private func hourRange(_ cal: Calendar, dayStart: Date) -> (Int, Int) {
        var lo = startHour, hi = endHour
        for it in items {
            let s = Int(it.start.timeIntervalSince(dayStart) / 3600)
            let e = Int((it.end.timeIntervalSince(dayStart) / 3600).rounded(.up))
            lo = min(lo, max(0, s))
            hi = max(hi, min(24, e))
        }
        if hi <= lo { hi = min(24, lo + 1) }
        return (lo, hi)
    }

    var body: some View {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let isToday = cal.isDate(day, inSameDayAs: now)
        let (lo, hi) = hourRange(cal, dayStart: dayStart)
        let lanes = TimelineStrip.lanes(items)
        let laneCount = max(1, (lanes.map(\.lane).max() ?? 0) + 1)

        GeometryReader { geo in
            let w = geo.size.width
            let span = CGFloat(hi - lo)
            let origin = dayStart.addingTimeInterval(TimeInterval(lo * 3600))
            let trackH: CGFloat = 30
            let laneH = (trackH - 4) / CGFloat(laneCount)
            let step = w / span < 38 ? 2 : 1
            let xOf: (Date) -> CGFloat = { d in CGFloat(d.timeIntervalSince(origin) / 3600) / span * w }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: w, height: trackH)

                ForEach(Array(lo...hi), id: \.self) { h in
                    let hx = CGFloat(h - lo) / span * w
                    if h > lo && h < hi {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 1, height: trackH)
                            .offset(x: hx)
                    }
                    if h < hi && (h - lo) % step == 0 {
                        Text(String(format: "%02d:00", h % 24))
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.35))
                            .offset(x: hx + (h == lo ? 2 : -14), y: trackH + 4)
                    }
                }

                if isToday && now > origin {
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: min(w, max(0, xOf(now))), height: trackH)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                ForEach(lanes) { entry in
                    let x0 = max(0, xOf(entry.item.start))
                    let x1 = min(w, xOf(entry.item.end))
                    if x1 > x0 {
                        TimelineBlock(item: entry.item, width: max(3, x1 - x0 - 1), height: laneH - 1, now: now,
                                      selected: selectedID == entry.item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(entry.item.id) }
                            .offset(x: x0, y: 2 + CGFloat(entry.lane) * laneH)
                    }
                }

                if isToday && now >= origin && xOf(now) <= w {
                    NowMarker(height: trackH + 6)
                        .offset(x: xOf(now) - 3.5, y: -3)
                }
            }
        }
    }
}

struct TimelineBlock: View {
    let item: AgendaItem
    let width: CGFloat
    let height: CGFloat
    let now: Date
    var selected = false

    var body: some View {
        let past = item.end <= now
        let isTask = item.isTaskBlock
        let fill = item.color.opacity(item.done ? 0.25 : (isTask ? 0.5 : 0.92) * (past ? 0.55 : 1))
        RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
                    .strokeBorder(selected ? Color.white : item.color.opacity(isTask ? 0.9 : 0), lineWidth: selected ? 1.5 : 1)
            )
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                if width > 46 && height > 11 {
                    Text(item.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isTask ? Color.white : Color.black.opacity(0.78))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(width: width, alignment: .leading)
                }
            }
    }
}

struct NowMarker: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(Palette.red).frame(width: 7, height: 7)
            Rectangle().fill(Palette.red).frame(width: 2, height: height - 7)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

// MARK: - Быстрый ввод

struct QuickAddField: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    var homeworkMode = false
    @FocusState private var focused: Bool

    var body: some View {
        let raw = QuickParser.parse(model.quickText, now: store.now)
        let parsed = homeworkMode ? QuickParser.asHomework(raw) : raw
        HStack(spacing: 10) {
            Image(systemName: homeworkMode ? "graduationcap.fill" : parsed.kind == .event ? "calendar.badge.plus" : "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(focused ? 0.9 : 0.5))
                .frame(width: 18)
            TextField("", text: $model.quickText,
                      prompt: Text(homeworkMode
                                   ? "ДЗ: Листок 5 #матан до пт 18:00   ·   своя оценка: 2ч   ·   ! — важно"
                                   : "Задача: Домашка #учёба 1.5ч до пт   ·   Событие: 14:00-15:30 Пара   ·   Повтор: по пн ср 9:00-10:30 Матан"))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(submit)
            if !model.quickText.trimmingCharacters(in: .whitespaces).isEmpty {
                ParsePreview(parsed: parsed, store: store, homework: homeworkMode)
            } else if let toast = model.toast {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.colors[3])
                    Text(toast)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize()
                .transition(.opacity)
            } else {
                if NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
                    Button {
                        if let image = NSImage(pasteboard: .general) { model.onImportImage(image) }
                    } label: {
                        Label("скриншот из буфера", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.colors[3]))
                    .help("Найти мероприятия на картинке из буфера обмена")
                    .fixedSize()
                }
                Text("⌃⌥T")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.25))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(focused ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(focused ? 0.2 : 0.06), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.makeKey(); focused = true }
        .onChange(of: model.focusToken) { _, _ in
            focused = true
            model.pendingFocus = false
        }
        .onAppear {
            if model.pendingFocus {
                DispatchQueue.main.async {
                    focused = true
                    model.pendingFocus = false
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }

    private func submit() {
        let p = QuickParser.parse(model.quickText, now: Date())
        if let message = homeworkMode ? store.addHomework(p) : store.add(p) {
            model.quickText = ""
            model.flash(message)
        } else {
            NSSound.beep()
        }
    }
}

struct ParsePreview: View {
    let parsed: ParsedInput
    @ObservedObject var store: Store
    var homework = false

    var body: some View {
        let now = store.now
        HStack(spacing: 4) {
            if homework, let name = parsed.projectName {
                let existing = store.findCourse(named: name)
                Chip(icon: existing == nil ? "book.closed" : "book.closed.fill",
                     text: existing?.name ?? name.capitalizedFirst,
                     color: existing.map { Palette.color($0.colorIndex) } ?? Color.white.opacity(0.75))
            } else if let name = parsed.projectName {
                let existing = store.findProject(named: name)
                Chip(icon: existing == nil ? "folder.badge.plus" : "folder.fill",
                     text: existing?.name ?? name.capitalizedFirst,
                     color: existing.map { Palette.color($0.colorIndex) } ?? Color.white.opacity(0.75))
            }
            switch parsed.kind {
            case .event:
                if let s = parsed.startMinutes {
                    let e = parsed.endMinutes ?? (s + (parsed.estimate ?? 60))
                    Chip(icon: "clock.fill", text: "\(hm(s))–\(hm(e))", color: Palette.colors[4])
                }
                if !parsed.weekdays.isEmpty {
                    Chip(icon: "repeat", text: Fmt.weekdays(parsed.weekdays), color: Palette.colors[6])
                } else if let d = parsed.day {
                    Chip(icon: "calendar", text: Fmt.dayWord(d, now: now), color: Palette.colors[5])
                }
                if let target = store.writeCalendarTitle {
                    Chip(icon: "arrow.up.right", text: target, color: Palette.colors[3])
                }
            case .task:
                let courseEstimate = homework ? parsed.projectName.flatMap { store.findCourse(named: $0) }?.estimate ?? 60 : nil
                Chip(icon: "hourglass", text: Fmt.duration(parsed.estimate ?? courseEstimate ?? store.data.settings.defaultEstimate))
                if let d = parsed.deadline {
                    let info = Fmt.deadline(d, now: now)
                    Chip(icon: "flag.fill", text: info.text, color: info.color == Color.white.opacity(0.55) ? Palette.colors[5] : info.color)
                }
            }
            if parsed.priority { Chip(icon: "exclamationmark", text: "важно", color: Palette.red) }
            Image(systemName: "return")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.leading, 4)
        }
    }

    private func hm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}

// MARK: - Расписание дня

struct AgendaColumn: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let now = store.now
        let day = model.selectedDay(now: now)
        let items = store.agenda(for: day)
        let allDay = store.allDayItems(for: day)
        let free = store.freeMinutes(day: day, now: now)
        let planned = store.plannedMinutes(day: day)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                IconButton(symbol: "chevron.left", size: 11) { shift(-1) }
                Button { shift(-model.dayOffset) } label: {
                    Text(dayTitle(day, now: now))
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(minWidth: 110)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(model.dayOffset == 0 ? 0.14 : 0.07)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(model.dayOffset == 0 ? "Сегодня" : "Вернуться к сегодня")
                IconButton(symbol: "chevron.right", size: 11) { shift(1) }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        let result = store.plan(day: day)
                        model.flash(result.message)
                    }
                } label: {
                    Label("Распределить", systemImage: "wand.and.stars")
                }
                .buttonStyle(PillButtonStyle(tint: Palette.colors[5], prominent: true))
                .help("Раскидать незакрытые задачи по свободным окнам — сначала срочные")
                Menu {
                    Button("Убрать задачи из плана на этот день") { store.clearPlan(day: day) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !allDay.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("весь день")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                        ForEach(allDay) { item in
                            Button {
                                withAnimation(.snappy) { model.expandedAgendaID = model.expandedAgendaID == item.id ? nil : item.id }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(item.color).frame(width: 6, height: 6)
                                    Text(item.title).lineLimit(1)
                                }
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(item.color.opacity(model.expandedAgendaID == item.id ? 0.3 : 0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let open = allDay.first(where: { $0.id == model.expandedAgendaID }) {
                    AgendaDetails(item: open, model: model, store: store)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(open.color.opacity(0.1)))
                }
            }

            if items.isEmpty {
                EmptyState(icon: "sun.max",
                           title: model.dayOffset == 0 ? "День свободен" : "Пока пусто",
                           hint: "Опиши мероприятие в строке сверху — DeepSeek добавит его в календарь.\nИли нажми «Распределить» — задачи встанут в свободные окна")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 3) {
                            ForEach(items) { item in
                                AgendaRow(item: item, now: now, model: model, store: store)
                                    .id(item.id)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .onAppear {
                        if let target = items.first(where: { $0.end > now }) {
                            proxy.scrollTo(target.id, anchor: .top)
                        }
                    }
                    .onChange(of: model.expandedAgendaID) { _, id in
                        if let id, items.contains(where: { $0.id == id }) {
                            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Label("свободно \(Fmt.duration(free))", systemImage: "circle.dashed")
                if planned > 0 { Label("задачи \(Fmt.duration(planned))", systemImage: "square.stack.3d.up.fill") }
                Spacer()
                Text("\(String(format: "%02d", store.data.settings.dayStartHour)):00–\(String(format: "%02d", store.data.settings.dayEndHour)):00")
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.38))
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    private func shift(_ delta: Int) {
        withAnimation(.snappy) {
            model.dayOffset = max(-30, min(90, model.dayOffset + delta))
            model.expandedAgendaID = nil
        }
    }

    private func dayTitle(_ day: Date, now: Date) -> String {
        let word = Fmt.dayWord(day, now: now)
        if word == "сегодня" || word == "завтра" || word == "вчера" { return word.capitalizedFirst + ", " + Fmt.dayMonth(day) }
        return Fmt.shortDate(day)
    }
}

struct AgendaRow: View {
    let item: AgendaItem
    let now: Date
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        let isNow = item.start <= now && now < item.end
        let past = item.end <= now
        let open = model.expandedAgendaID == item.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.time(item.start))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    Text(Fmt.time(item.end))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(width: 40, alignment: .trailing)

                RoundedRectangle(cornerRadius: 2)
                    .fill(item.isTaskBlock ? item.color.opacity(0.55) : item.color)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(open ? 3 : 1)
                        .strikethrough(item.done, color: .white.opacity(0.5))
                        .foregroundStyle(item.done ? .white.opacity(0.45) : .white)
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                        Text(subtitle).lineLimit(1)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.42))
                }
                Spacer(minLength: 4)
                if isNow {
                    Text("сейчас")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(Color.black.opacity(0.8))
                        .background(Capsule().fill(item.color))
                        .fixedSize()
                }
                if case let .block(_, taskID) = item.kind {
                    CheckButton(done: item.done, color: item.color) {
                        withAnimation(.snappy) { store.toggleDone(taskID) }
                    }
                } else {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(hover || open ? 0.5 : 0))
                }
            }
            if open {
                AgendaDetails(item: item, model: model, store: store)
                    .padding(.leading, 53)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isNow || open ? item.color.opacity(open ? 0.12 : 0.16) : Color.white.opacity(hover ? 0.06 : 0)))
        .opacity(past && !isNow && !open ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            withAnimation(.snappy) { model.expandedAgendaID = open ? nil : item.id }
        }
        .contextMenu { AgendaMenu(item: item, model: model, store: store) }
    }

    private var icon: String {
        switch item.kind {
        case .event: return item.recurring ? "repeat" : "calendar"
        case .block: return "checklist"
        case .calendar: return "calendar.circle"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch item.kind {
        case .event: parts.append(item.recurring ? "каждую неделю" : "событие")
        case .block: parts.append("задача")
        case .calendar: parts.append(item.calendarName ?? "Календарь")
        }
        if let p = item.projectName { parts.append(p) }
        if let loc = item.location { parts.append(loc) }
        parts.append(Fmt.duration(item.minutes))
        return parts.joined(separator: " · ")
    }
}

/// Подробности мероприятия: время, место, заметки, ссылка — и действия.
struct AgendaDetails: View {
    let item: AgendaItem
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let details: EventDetails? = {
            if case let .calendar(eventID) = item.kind { return store.calendarService.details(eventID: eventID, start: item.start) }
            return nil
        }()
        let location = details?.location ?? item.location
        VStack(alignment: .leading, spacing: 6) {
            line("clock", item.allDay ? "весь день, \(Fmt.shortDate(item.start))"
                                      : "\(Fmt.shortDate(item.start)), \(Fmt.time(item.start))–\(Fmt.time(item.end)) · \(Fmt.duration(item.minutes))")
            if let location {
                HStack(spacing: 6) {
                    line("mappin.and.ellipse", location)
                    if let url = URL(string: "https://maps.apple.com/?q=" + (location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                        IconButton(symbol: "map", size: 10) { NSWorkspace.shared.open(url) }
                            .help("Открыть в Картах")
                    }
                }
            }
            if let d = details {
                line("calendar", d.calendar + (d.recurring ? " · повторяется" : ""))
            } else if item.recurring {
                line("repeat", "каждую неделю")
            }
            if case let .block(_, taskID) = item.kind, let t = store.task(taskID) {
                line("hourglass", "оценка \(Fmt.duration(t.estimate))" + (t.deadline.map { " · срок \(Fmt.when($0, now: store.now))" } ?? ""))
            }
            if let url = details?.url {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(url.absoluteString, systemImage: "link").lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.colors[5])
            }
            if let notes = details?.notes {
                Text(notes)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                AgendaActions(item: item, model: model, store: store)
            }
            .padding(.top, 2)
        }
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.75))
    }
}

struct AgendaActions: View {
    let item: AgendaItem
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        switch item.kind {
        case .event(let id):
            Button(item.recurring ? "Удалить повторяющееся" : "Удалить", role: .destructive) {
                store.deleteEvent(id)
                model.expandedAgendaID = nil
            }
            .buttonStyle(PillButtonStyle(tint: Palette.red))
        case .block(let blockID, let taskID):
            Button(item.done ? "Вернуть в работу" : "Готово") { store.toggleDone(taskID) }
                .buttonStyle(PillButtonStyle(tint: item.color, prominent: !item.done))
            Button("Убрать из плана") { store.deleteBlock(blockID) }
                .buttonStyle(PillButtonStyle())
        case .calendar(let eventID):
            Button("Удалить из календаря", role: .destructive) {
                model.flash(store.deleteCalendarEvent(eventID, start: item.start))
                model.expandedAgendaID = nil
            }
            .buttonStyle(PillButtonStyle(tint: Palette.red))
        }
    }
}

struct AgendaMenu: View {
    let item: AgendaItem
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        switch item.kind {
        case .event(let id):
            Button(item.recurring ? "Удалить повторяющееся событие" : "Удалить событие", role: .destructive) {
                store.deleteEvent(id)
            }
        case .block(let blockID, let taskID):
            Button(item.done ? "Вернуть задачу в работу" : "Готово") { store.toggleDone(taskID) }
            Button("Убрать этот блок из плана") { store.deleteBlock(blockID) }
            Button("Перенести на ближайшее окно") {
                store.deleteBlock(blockID)
                model.flash(store.scheduleNext(taskID))
            }
        case .calendar(let eventID):
            Text(item.calendarName.map { "Календарь «\($0)»" } ?? "Событие из Календаря")
            Button("Удалить из календаря", role: .destructive) {
                model.flash(store.deleteCalendarEvent(eventID, start: item.start))
            }
        }
    }
}

// MARK: - Строка мероприятий (DeepSeek)

struct EventBar: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        let hasKey = store.data.settings.deepseekKeySaved
        HStack(spacing: 10) {
            Image(systemName: model.aiBusy ? "sparkles" : "calendar.badge.plus")
                .font(.system(size: 16))
                .foregroundStyle(model.aiBusy ? Palette.colors[6] : .white.opacity(focused ? 0.9 : 0.5))
                .symbolEffect(.pulse, isActive: model.aiBusy)
                .frame(width: 18)
            TextField("", text: $model.quickText,
                      prompt: Text(hasKey ? "Мероприятие или задача — поставлю в расписание: «в сб в 19:00 ужин с Катей» · «написать эссе завтра 2ч»"
                                          : "«14:00-15:30 Пара» — событие · «эссе 2ч до пт» — задача в ближайшее окно"))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { model.onImportText(model.quickText) }
                .disabled(model.aiBusy)
            if model.aiBusy {
                ProgressView().controlSize(.small)
                Text("DeepSeek разбирает…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
            } else if let toast = model.toast {
                HStack(spacing: 6) {
                    Image(systemName: model.undoAction != nil ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(model.undoAction != nil ? Palette.colors[3] : Palette.orange)
                    Text(toast).lineLimit(1)
                    if let undo = model.undoAction {
                        Button("Отменить") {
                            model.undoAction = nil
                            undo()
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize()
                .transition(.opacity)
            } else {
                if !model.quickText.isEmpty {
                    Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                }
                CalendarTargetMenu(model: model, store: store)
                if NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
                    Button {
                        if let image = NSImage(pasteboard: .general) { model.onImportImage(image) }
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.colors[3]))
                    .help("Мероприятия со скриншота из буфера обмена")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(focused ? 0.11 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(model.aiBusy ? Palette.colors[6].opacity(0.6) : Color.white.opacity(focused ? 0.2 : 0.06), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.makeKey(); focused = true }
        .onChange(of: model.focusToken) { _, _ in
            focused = true
            model.pendingFocus = false
        }
        .onAppear {
            if model.pendingFocus {
                DispatchQueue.main.async {
                    focused = true
                    model.pendingFocus = false
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }
}

/// Куда попадут мероприятия: выбор календаря прямо у строки ввода.
struct CalendarTargetMenu: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let linked = store.data.settings.useCalendar && store.calendarService.hasAccess
        let target = store.writeCalendarTitle
        Menu {
            if linked {
                ForEach(store.calendarService.calendars().filter(\.writable)) { c in
                    Button((c.id == store.data.settings.writeCalendarID ? "✓ " : "") + "\(c.title) — \(c.source)") {
                        store.data.settings.writeCalendarID = c.id
                    }
                }
                Divider()
                Button((target == nil ? "✓ " : "") + "Только в Островке") { store.data.settings.writeCalendarID = nil }
            } else {
                Button("Связать с Календарём…") { model.showSettings = true }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: target == nil ? "tray" : "calendar")
                Text(target.map { "→ \($0)" } ?? (linked ? "→ куда? выбрать" : "→ Островок"))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(target == nil && linked ? Palette.orange : .white.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Куда добавлять мероприятия")
    }
}

// MARK: - Задачи

struct TasksColumn: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let filter = model.projectFilter.flatMap { id in store.project(id)?.id }
        let overdue = store.overdueTasks(filter: filter, now: store.now)
        let overdueIDs = Set(overdue.map(\.id))
        let tasks = store.visibleTasks(filter: filter, showDone: model.showDone).filter { !overdueIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(title: "Все", count: store.openCount(project: nil), color: .white,
                                   selected: filter == nil) { pick(nil) }
                        ForEach(store.data.projects) { p in
                            FilterChip(title: p.name, count: store.openCount(project: p.id),
                                       color: Palette.color(p.colorIndex), selected: filter == p.id) { pick(p.id) }
                        }
                    }
                }
                Spacer(minLength: 0)
                do {
                    Button {
                        withAnimation(.snappy) { model.showDone.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.showDone ? "eye.fill" : "eye.slash")
                            Text("готово \(store.doneCount)")
                        }
                    }
                    .buttonStyle(PillButtonStyle(tint: .white))
                    .help(model.showDone ? "Скрыть выполненные" : "Показать выполненные")
                    .fixedSize()
                }
            }

            ProjectComposer(model: model, store: store, projectID: filter)

            if tasks.isEmpty && overdue.isEmpty {
                EmptyState(icon: "checkmark.seal",
                           title: store.data.tasks.isEmpty ? "Задач пока нет" : "Здесь всё сделано",
                           hint: "Нажми на проект сверху и пиши задачу в строку выше.\nЗадачу можно перетащить на шкалу дня — встанет на это время")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        if !overdue.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Не успел")
                                Text("\(overdue.count)").opacity(0.6)
                                Spacer()
                                Text("перетащи на шкалу или «сейчас» / «завтра»")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.red)
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                            ForEach(overdue) { t in
                                TaskRow(task: t, model: model, store: store, showProject: filter == nil, overdue: true)
                            }
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.vertical, 4)
                        }
                        ForEach(tasks) { t in
                            TaskRow(task: t, model: model, store: store, showProject: filter == nil)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    /// Нажал на проект — выбираем его и сразу ставим курсор в строку ввода.
    private func pick(_ id: UUID?) {
        model.projectFilter = id
        model.makeKey()
        model.composerFocusToken += 1
    }
}

/// Строка «задача / заметка в выбранный проект» — без хештегов.
struct ProjectComposer: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let projectID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let project = store.project(projectID)
        let color = project.map { Palette.color($0.colorIndex) } ?? Color.white
        let name = project?.name
        let notes = false
        HStack(spacing: 8) {
            Image(systemName: notes ? "note.text.badge.plus" : "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(color.opacity(0.9))
            TextField("", text: $model.composerText, prompt: Text(placeholder(notes: notes, name: name)), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
            if !model.composerText.isEmpty {
                Image(systemName: "return")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(focused ? 0.14 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(focused ? 0.5 : 0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.makeKey(); focused = true }
        .onChange(of: model.composerFocusToken) { _, _ in focused = true }
    }

    private func placeholder(notes: Bool, name: String?) -> String {
        if notes { return name.map { "Заметка в «\($0)»…" } ?? "Заметка без проекта…" }
        return name.map { "Задача в «\($0)» — можно «1ч до пт»" } ?? "Задача без проекта — или выбери проект сверху"
    }

    private func submit() {
        let text = model.composerText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let msg = store.addTask(text, projectID: projectID) {
            model.flash(msg)
        } else {
            NSSound.beep()
            return
        }
        model.composerText = ""
    }
}

struct NoteRow: View {
    let note: Note
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let showProject: Bool
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let color = store.color(for: note.projectID)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.8)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text(note.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) { startEdit() }
                }
                HStack(spacing: 6) {
                    if showProject, let p = store.project(note.projectID) {
                        Text(p.name).foregroundStyle(color.opacity(0.9))
                    }
                    Text("\(Fmt.dayWord(note.createdAt, now: store.now)), \(Fmt.time(note.createdAt))")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            }
            if hover && !editing {
                HStack(spacing: 0) {
                    IconButton(symbol: "doc.on.doc", size: 10.5) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                        model.flash("Скопировано")
                    }
                    .help("Скопировать")
                    IconButton(symbol: "checklist", size: 10.5) { store.noteToTask(note.id); model.flash("Стало задачей") }
                        .help("Сделать задачей")
                    IconButton(symbol: "pencil", size: 10.5) { startEdit() }
                        .help("Изменить")
                    IconButton(symbol: "trash", size: 10.5, tint: Palette.red) {
                        withAnimation(.snappy) { store.deleteNote(note.id) }
                    }
                    .help("Удалить")
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.07 : 0.045)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Изменить") { startEdit() }
            Button("Сделать задачей") { store.noteToTask(note.id) }
            Menu("Проект") {
                Button("Без проекта") {
                    if let i = store.data.notes.firstIndex(where: { $0.id == note.id }) { store.data.notes[i].projectID = nil }
                }
                ForEach(store.data.projects) { p in
                    Button(p.name) {
                        if let i = store.data.notes.firstIndex(where: { $0.id == note.id }) { store.data.notes[i].projectID = p.id }
                    }
                }
            }
            Divider()
            Button("Удалить", role: .destructive) { store.deleteNote(note.id) }
        }
    }

    private func startEdit() {
        draft = note.text
        model.makeKey()
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { store.updateNote(note.id, text: t) }
    }
}

struct TaskRow: View {
    let task: TaskItem
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let showProject: Bool
    var overdue = false
    @State private var hover = false

    var body: some View {
        let now = store.now
        let color = store.taskColor(task)
        let next = store.nextBlock(for: task.id, now: now)
        HStack(spacing: 10) {
            CheckButton(done: task.done, color: color) {
                withAnimation(.snappy) { store.toggleDone(task.id) }
            }
            VStack(alignment: .leading, spacing: 1) {
                if model.editingTaskID == task.id {
                    TitleEditor(text: task.title) { newTitle in
                        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { store.updateTask(task.id) { $0.title = trimmed } }
                        model.editingTaskID = nil
                    }
                } else {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .strikethrough(task.done, color: .white.opacity(0.5))
                        .foregroundStyle(task.done ? .white.opacity(0.4) : .white)
                        .onTapGesture(count: 2) { startEditing() }
                }
                if overdue {
                    Text(overdueReason)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.red.opacity(0.9))
                } else if showProject || task.isHomework, let group = store.taskGroupName(task) {
                    Text(group)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(color.opacity(0.85))
                }
            }
            Spacer(minLength: 6)
            if overdue && !task.done {
                Button("сейчас") { withAnimation(.snappy) { model.flash(store.startNow(taskID: task.id)) } }
                    .buttonStyle(PillButtonStyle(tint: Palette.colors[3], prominent: true))
                    .help("Поставить на шкалу прямо сейчас")
                Button("завтра") { withAnimation(.snappy) { model.flash(store.moveToTomorrow(taskID: task.id)) } }
                    .buttonStyle(PillButtonStyle())
                    .help("В ближайшее свободное окно завтра")
            }
            if hover && !task.done && model.editingTaskID != task.id && !overdue {
                IconButton(symbol: "calendar.badge.clock", size: 11) {
                    model.flash(store.scheduleNext(task.id))
                }
                .help("Поставить в ближайшее свободное окно")
                IconButton(symbol: "pencil", size: 11) { startEditing() }
                    .help("Переименовать")
                IconButton(symbol: "trash", size: 11, tint: Palette.red) {
                    withAnimation(.snappy) { store.deleteTask(task.id) }
                }
                .help("Удалить")
            }
            if !task.done {
                if task.priority { Badge(text: "!", color: Palette.red) }
                if let next {
                    Badge(text: Fmt.dayWord(next.start, now: now) == "сегодня" ? Fmt.time(next.start) : Fmt.when(next.start, now: now),
                          color: color, icon: "play.fill")
                }
                Badge(text: Fmt.duration(task.estimate), icon: "hourglass")
                if let d = task.deadline {
                    let info = Fmt.deadline(d, now: now)
                    Badge(text: info.text, color: info.color, icon: "flag.fill")
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(overdue ? Palette.red.opacity(hover ? 0.14 : 0.08) : Color.white.opacity(hover ? 0.06 : 0)))
        .opacity(model.taskDrag?.taskID == task.id ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(task.done ? nil : DragGesture(minimumDistance: 6, coordinateSpace: .named("main"))
            .onChanged { v in model.taskDrag = TaskDrag(taskID: task.id, location: v.location) }
            .onEnded { v in dropOnTimeline(v.location) })
        .help(task.done ? "" : "Перетащи на шкалу дня сверху — встанет на это время")
        .contextMenu { menu }
    }

    private var overdueReason: String {
        let now = store.now
        if let m = task.missedAt { return "не сделано \(Fmt.when(m, now: now))" }
        if let d = task.deadline { return "срок прошёл: \(Fmt.dayWord(d, now: now)) \(Fmt.time(d))" }
        return "не сделано"
    }

    /// Уронили задачу на шкалу — ставим блок на это время.
    private func dropOnTimeline(_ p: CGPoint) {
        defer { model.taskDrag = nil }
        guard let g = model.timelineGeo, g.frame.insetBy(dx: 0, dy: -14).contains(p) else { return }
        let start = g.time(atX: p.x - g.frame.minX).snapped(minutes: 5)
        let minutes = store.defaultBlockMinutes(task, now: store.now)
        withAnimation(.snappy) { store.placeBlock(taskID: task.id, start: start, minutes: minutes) }
        model.flash("\(task.title) → \(Fmt.when(start, now: store.now))")
    }

    private func startEditing() {
        model.makeKey()
        model.editingTaskID = task.id
    }

    @ViewBuilder private var menu: some View {
        Button(task.done ? "Вернуть в работу" : "Готово") { store.toggleDone(task.id) }
        if !task.done {
            Button("Поставить в ближайшее окно") { model.flash(store.scheduleNext(task.id)) }
            if store.nextBlock(for: task.id, now: Date()) != nil {
                Button("Убрать из плана") { store.unplanTask(task.id) }
            }
        }
        Divider()
        Menu("Проект") {
            Button("Без проекта") { store.updateTask(task.id) { $0.projectID = nil } }
            ForEach(store.data.projects) { p in
                Button((task.projectID == p.id ? "✓ " : "") + p.name) {
                    store.updateTask(task.id) { $0.projectID = p.id }
                }
            }
        }
        Menu("Сколько займёт") {
            ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { m in
                Button((task.estimate == m ? "✓ " : "") + Fmt.duration(m)) {
                    store.updateTask(task.id) { $0.estimate = m }
                }
            }
        }
        Menu("Дедлайн") {
            ForEach(Array([("Сегодня", 0), ("Завтра", 1), ("Через 3 дня", 3), ("Через неделю", 7)].enumerated()), id: \.offset) { _, pair in
                Button(pair.0) {
                    let cal = Calendar.current
                    let d = cal.date(byAdding: .day, value: pair.1, to: cal.startOfDay(for: Date()))!
                    store.updateTask(task.id) { $0.deadline = d.addingTimeInterval(23 * 3600 + 59 * 60) }
                }
            }
            if task.deadline != nil {
                Divider()
                Button("Без дедлайна") { store.updateTask(task.id) { $0.deadline = nil } }
            }
        }
        Button(task.priority ? "Снять отметку «важно»" : "Отметить важной") {
            store.updateTask(task.id) { $0.priority.toggle() }
        }
        Button("Переименовать") { startEditing() }
        Divider()
        Button("Удалить", role: .destructive) { store.deleteTask(task.id) }
    }
}

struct TitleEditor: View {
    @State var text: String
    let onCommit: (String) -> Void
    @FocusState private var focused: Bool
    @State private var committed = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($focused)
            .onSubmit(commit)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard !committed else { return }
        committed = true
        onCommit(text)
    }
}
