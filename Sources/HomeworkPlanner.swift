import SwiftUI

// MARK: - Логика раскладки ДЗ по слотам

extension Store {
    func remainingMinutes(_ t: TaskItem, now: Date) -> Int {
        max(0, Int((remainingSeconds(for: t, now: now) / 60).rounded()))
    }

    /// Сколько ставить блоком по умолчанию: остаток (или вся оценка, если уже всё расписано), кратно 15 минутам.
    func defaultBlockMinutes(_ t: TaskItem, now: Date) -> Int {
        let rest = remainingMinutes(t, now: now)
        let base = rest >= 15 ? min(rest, max(15, data.settings.maxChunk)) : t.estimate
        return min(240, max(15, Int((Double(base) / 15).rounded(.up)) * 15))
    }

    @discardableResult
    func placeBlock(taskID: UUID, start: Date, minutes: Int) -> PlanBlock {
        let b = PlanBlock(taskID: taskID, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                          manual: true, toCalendar: true)
        var d = data
        d.blocks.append(b)
        if let i = d.tasks.firstIndex(where: { $0.id == taskID }) { d.tasks[i].missedAt = nil }
        data = d
        return b
    }

    /// Передвинутый или растянутый вручную блок становится «ручным».
    func updateBlock(_ id: UUID, start: Date, end: Date) {
        guard let i = data.blocks.firstIndex(where: { $0.id == id }) else { return }
        var b = data.blocks[i]
        b.start = start
        b.end = end
        b.manual = true
        b.toCalendar = true
        b.hwAuto = nil
        var d = data
        d.blocks[i] = b
        if let t = d.tasks.firstIndex(where: { $0.id == b.taskID }) { d.tasks[t].missedAt = nil }
        data = d
    }

    func homeworkMinutes(on day: Date) -> Int {
        let cal = Calendar.current
        let hw = Set(data.tasks.filter(\.isHomework).map(\.id))
        return Int(data.blocks
            .filter { hw.contains($0.taskID) && cal.isDate($0.start, inSameDayAs: day) }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60)
    }

    func removeHomeworkBlocks(autoOnly: Bool, days: [Date], now: Date = Date()) {
        let cal = Calendar.current
        let hw = Set(data.tasks.filter(\.isHomework).map(\.id))
        data.blocks.removeAll { b in
            hw.contains(b.taskID) && b.start >= now && (!autoOnly || b.hwAuto == true)
                && days.contains { cal.isDate($0, inSameDayAs: b.start) }
        }
    }

    /// Раскладывает все открытые ДЗ по свободным окнам до дедлайнов: сначала срочные,
    /// с запасом 12 часов до срока (если влезает) и не больше `hwDailyCap` минут ДЗ в день.
    /// Блоки, поставленные руками, не трогает; прошлую авто-раскладку пересобирает.
    @discardableResult
    func distributeHomework(now: Date = Date(), days: Int = 14) -> PlanResult {
        let cal = Calendar.current
        let st = data.settings
        let today = cal.startOfDay(for: now)
        let pause = TimeInterval(st.breakMinutes * 60)
        let cap = TimeInterval(max(30, st.hwDailyCap) * 60)
        let maxChunk = TimeInterval(max(15, st.maxChunk) * 60)
        let hwIDs = Set(data.tasks.filter(\.isHomework).map(\.id))

        var blocks = data.blocks
        blocks.removeAll { $0.hwAuto == true && $0.start >= now }
        // «Камни» по ДЗ раскладываем заново.
        let doneIDs = Set(data.tasks.filter(\.done).map(\.id))
        blocks.removeAll { b in hwIDs.contains(b.taskID) && b.end <= now && cal.isDate(b.start, inSameDayAs: now) && !doneIDs.contains(b.taskID) }

        var free: [Int: [(Date, Date)]] = [:]
        var used: [Int: TimeInterval] = [:]
        func dayDate(_ off: Int) -> Date { cal.date(byAdding: .day, value: off, to: today)! }
        func prepare(_ off: Int) {
            guard free[off] == nil else { return }
            let day = dayDate(off)
            var (from, to) = dayBounds(day)
            if off == 0 { from = max(from, now.roundedUp(minutes: 15)) }
            var busy = agenda(for: day).filter { !$0.isTaskBlock }
                .map { ($0.start.addingTimeInterval(-pause), $0.end.addingTimeInterval(pause)) }
            busy += blocks.filter { cal.isDate($0.start, inSameDayAs: day) }
                .map { ($0.start, $0.end.addingTimeInterval(pause)) }
            free[off] = from < to ? Store.freeIntervals(from: from, to: to, busy: busy) : []
            used[off] = blocks.filter { cal.isDate($0.start, inSameDayAs: day) && hwIDs.contains($0.taskID) }
                .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }

        let homework = data.tasks.filter { $0.isHomework && !$0.done }.sorted { a, b in
            let da = a.deadline ?? .distantFuture, db = b.deadline ?? .distantFuture
            if da != db { return da < db }
            if a.priority != b.priority { return a.priority }
            return a.createdAt < b.createdAt
        }

        var result = PlanResult()
        for t in homework {
            var rest = remainingSeconds(for: t, blocks: blocks, now: now)
            if rest < 5 * 60 { continue }
            var deadline = t.deadline ?? today.addingTimeInterval(TimeInterval(days * 86400))
            if deadline <= now { deadline = cal.date(byAdding: .day, value: 2, to: today)! }   // просрочено — как можно скорее
            var placedAny = false
            for buffer in [TimeInterval(12 * 3600), 0] {
                let limit = deadline.addingTimeInterval(-buffer)
                var off = 0
                while off < days && rest >= 5 * 60 {
                    if dayDate(off) >= limit { break }
                    prepare(off)
                    var intervals = free[off]!
                    var i = 0
                    while i < intervals.count && rest >= 5 * 60 {
                        let capLeft = cap - used[off]!
                        if capLeft < 15 * 60 { break }
                        let s = intervals[i].0
                        let e = min(intervals[i].1, limit)
                        let want = min(rest, maxChunk, capLeft)
                        if e.timeIntervalSince(s) < min(want, 30 * 60) { i += 1; continue }
                        let chunk = (min(want, e.timeIntervalSince(s)) / 300).rounded(.down) * 300
                        guard chunk >= 5 * 60 else { i += 1; continue }
                        blocks.append(PlanBlock(taskID: t.id, start: s, end: s.addingTimeInterval(chunk),
                                                manual: true, toCalendar: true, hwAuto: true))
                        used[off]! += chunk
                        rest -= chunk
                        placedAny = true
                        intervals[i].0 = s.addingTimeInterval(chunk + pause)
                        if intervals[i].1.timeIntervalSince(intervals[i].0) < 60 { intervals.remove(at: i) }
                    }
                    free[off] = intervals
                    off += 1
                }
                if rest < 5 * 60 { break }
            }
            if placedAny { result.placed += 1 }
            if rest >= 5 * 60 { result.unplaced.append(t.title) }
        }
        data.blocks = blocks
        return result
    }
}

// MARK: - Сетка недели

struct PlannerLayout {
    let origin: CGPoint      // левый верх колонок дней (в координатах планировщика)
    let colW: CGFloat
    let height: CGFloat
    let lo: Int
    let hi: Int
    let days: [Date]

    var ppm: CGFloat { height / CGFloat(max(1, hi - lo) * 60) }

    func dayIndex(of date: Date) -> Int? {
        let cal = Calendar.current
        return days.firstIndex { cal.isDate($0, inSameDayAs: date) }
    }

    func y(_ date: Date, day i: Int) -> CGFloat {
        let m = CGFloat(date.timeIntervalSince(days[i]) / 60) - CGFloat(lo * 60)
        return origin.y + min(max(0, m), CGFloat((hi - lo) * 60)) * ppm
    }

    func rect(start: Date, end: Date, day i: Int) -> CGRect {
        let top = y(start, day: i), bottom = y(end, day: i)
        return CGRect(x: origin.x + CGFloat(i) * colW + 2, y: top, width: colW - 4, height: max(5, bottom - top))
    }

    /// Прямоугольник с учётом пересечений: одновременные дела встают рядом колонками.
    func rect(start: Date, end: Date, day i: Int, slot: OverlapSlot?) -> CGRect {
        let full = rect(start: start, end: end, day: i)
        guard let slot, slot.cols > 1 else { return full }
        let w = full.width / CGFloat(slot.cols)
        return CGRect(x: full.minX + CGFloat(slot.col) * w, y: full.minY, width: max(4, w - 2), height: full.height)
    }

    struct OverlapSlot {
        let col: Int
        let cols: Int
    }

    /// Раскладка пересекающихся дел по колонкам (как в обычном календаре).
    static func overlapSlots(_ items: [AgendaItem]) -> [String: OverlapSlot] {
        var result: [String: OverlapSlot] = [:]
        var cluster: [(id: String, col: Int)] = []
        var colEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            for c in cluster { result[c.id] = OverlapSlot(col: c.col, cols: colEnds.count) }
            cluster = []
            colEnds = []
        }
        for it in items.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if !cluster.isEmpty && it.start >= clusterEnd { flush() }
            if cluster.isEmpty { clusterEnd = it.end }
            if let c = colEnds.firstIndex(where: { $0 <= it.start }) {
                colEnds[c] = it.end
                cluster.append((it.id, c))
            } else {
                colEnds.append(it.end)
                cluster.append((it.id, colEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, it.end)
        }
        flush()
        return result
    }

    /// День и время (кратно 15 минутам) под точкой.
    func slot(at p: CGPoint) -> (day: Int, start: Date)? {
        guard p.x >= origin.x, p.x < origin.x + colW * CGFloat(days.count),
              p.y >= origin.y - 6, p.y <= origin.y + height + 6 else { return nil }
        let i = min(days.count - 1, Int((p.x - origin.x) / colW))
        let m = (p.y - origin.y) / ppm + CGFloat(lo * 60)
        let snapped = Int((m / 15).rounded()) * 15
        let clamped = min(max(snapped, lo * 60), hi * 60 - 15)
        return (i, days[i].addingTimeInterval(TimeInterval(clamped * 60)))
    }
}

enum PlannerDragKind: Equatable {
    case new(UUID)       // тащим ДЗ из списка
    case move(UUID)      // двигаем блок
    case resize(UUID)    // тянем низ блока
}

struct PlannerDrag: Equatable {
    var kind: PlannerDragKind
    var location: CGPoint
    var grabMinutes: CGFloat = 0
}

struct Ghost {
    let taskID: UUID
    let day: Int
    let start: Date
    let end: Date
    let movingBlock: UUID?
}

struct WeekPlanner: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var drag: PlannerDrag?
    @State private var hover: CGPoint?

    private let listWidth: CGFloat = 290
    private let timeColumn: CGFloat = 30

    var body: some View {
        let now = store.now
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let days = (0..<7).map { cal.date(byAdding: .day, value: model.plannerWeek * 7 + $0, to: today)! }
        let agendas = days.map { store.agenda(for: $0) }
        let allDays = days.map { store.allDayItems(for: $0) }
        let slots = agendas.map { PlannerLayout.overlapSlots($0) }
        let headerHeight: CGFloat = allDays.contains { !$0.isEmpty } ? 48 : 30
        let (lo, hi) = hourRange(agendas: agendas, days: days)

        VStack(spacing: 10) {
            toolbar(days: days)
            GeometryReader { geo in
                let gridX = listWidth + 12
                let colW = (geo.size.width - gridX - timeColumn) / 7
                let layout = PlannerLayout(origin: CGPoint(x: gridX + timeColumn, y: headerHeight), colW: colW,
                                           height: geo.size.height - headerHeight - 4, lo: lo, hi: hi, days: days)
                let ghost = currentGhost(layout: layout, now: now)
                let focusID = ghost?.taskID ?? model.plannerSelectedTask

                ZStack(alignment: .topLeading) {
                    gridBackground(layout: layout, now: now, focusID: focusID, allDays: allDays)

                    PlannerList(model: model, store: store, drag: $drag, now: now) { taskID, location in
                        dropNew(taskID: taskID, at: location, layout: layout)
                    }
                    .frame(width: listWidth, height: geo.size.height)

                    // События и чужие блоки — только для вида, клики проходят насквозь.
                    ForEach(Array(days.indices), id: \.self) { i in
                        ForEach(agendas[i].filter { !isHomeworkBlock($0) }) { item in
                            StaticPlannerItem(item: item, rect: layout.rect(start: item.start, end: item.end, day: i, slot: slots[i][item.id]),
                                              hovered: hoveredItem(layout: layout, agendas: agendas, slots: slots)?.item.id == item.id)
                        }
                    }
                    .allowsHitTesting(false)

                    // Блоки ДЗ — можно двигать, тянуть и удалять.
                    ForEach(Array(days.indices), id: \.self) { i in
                        ForEach(agendas[i].filter(isHomeworkBlock)) { item in
                            homeworkBlock(item, layout: layout, day: i, slot: slots[i][item.id], focusID: focusID, ghost: ghost)
                        }
                    }

                    if let ghost {
                        GhostView(ghost: ghost, layout: layout, store: store, agendas: agendas)
                            .allowsHitTesting(false)
                    }
                    if drag == nil, let hit = hoveredItem(layout: layout, agendas: agendas, slots: slots) {
                        InfoCard(item: hit.item, store: store)
                            .frame(width: 230, alignment: .leading)
                            .offset(x: hit.rect.maxX + 240 < geo.size.width ? hit.rect.maxX + 6 : hit.rect.minX - 236,
                                    y: min(hit.rect.minY, geo.size.height - 120))
                            .allowsHitTesting(false)
                    }
                    if let drag, case .new(let id) = drag.kind, layout.slot(at: drag.location) == nil, let t = store.task(id) {
                        FloatingChip(title: t.title, minutes: store.defaultBlockMinutes(t, now: now),
                                     color: store.courseColor(t.courseID))
                            .offset(x: drag.location.x + 10, y: drag.location.y + 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .coordinateSpace(name: "planner")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .onAppear(perform: selectFirstIfNeeded)
    }

    // MARK: Шкала времени

    private func hourRange(agendas: [[AgendaItem]], days: [Date]) -> (Int, Int) {
        var lo = store.data.settings.dayStartHour
        var hi = store.data.settings.dayEndHour
        for (i, items) in agendas.enumerated() {
            for it in items {
                lo = min(lo, max(0, Int(it.start.timeIntervalSince(days[i]) / 3600)))
                hi = max(hi, min(24, Int((it.end.timeIntervalSince(days[i]) / 3600).rounded(.up))))
            }
        }
        return (lo, max(hi, lo + 1))
    }

    // MARK: Верхняя панель

    @ViewBuilder private func toolbar(days: [Date]) -> some View {
        let cap = store.data.settings.hwDailyCap
        HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", size: 11) { model.plannerWeek = max(0, model.plannerWeek - 1) }
                .opacity(model.plannerWeek == 0 ? 0.3 : 1)
            Text(weekTitle(days))
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 120)
            IconButton(symbol: "chevron.right", size: 11) { model.plannerWeek = min(3, model.plannerWeek + 1) }
                .opacity(model.plannerWeek >= 3 ? 0.3 : 1)
            Text("выбери ДЗ и кликай в сетку · или перетаскивай · блок тянется за низ")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("ДЗ в день до")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
            ValueStepper(text: Fmt.duration(cap)) {
                store.data.settings.hwDailyCap = max(30, cap - 30)
            } plus: {
                store.data.settings.hwDailyCap = min(12 * 60, cap + 30)
            }
            Menu {
                Button("Убрать авто-раскладку") { store.removeHomeworkBlocks(autoOnly: true, days: days) }
                Button("Убрать все блоки ДЗ на этой неделе") { store.removeHomeworkBlocks(autoOnly: false, days: days) }
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
            Button {
                withAnimation(.spring(response: 0.35)) {
                    let r = store.distributeHomework()
                    model.flash(r.placed == 0 && r.unplaced.isEmpty ? "Все ДЗ уже расписаны"
                                : "Расписано ДЗ: \(r.placed)" + (r.unplaced.isEmpty ? "" : " · не влезло: \(r.unplaced.count)"))
                    selectFirstIfNeeded(force: true)
                }
            } label: {
                Label("Разложить автоматически", systemImage: "wand.and.stars")
            }
            .buttonStyle(PillButtonStyle(tint: Palette.colors[5], prominent: true))
            .help("Раскидать все ДЗ по свободным окнам до дедлайнов. Ручные блоки останутся на месте.")
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }

    private func weekTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        if model.plannerWeek == 0 { return "Эта неделя" }
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "d MMM"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    // MARK: Фон сетки

    /// Мероприятие (не ДЗ) под курсором — для карточки с подробностями.
    private func hoveredItem(layout: PlannerLayout, agendas: [[AgendaItem]],
                             slots: [[String: PlannerLayout.OverlapSlot]]) -> (item: AgendaItem, rect: CGRect)? {
        guard let p = hover else { return nil }
        for i in agendas.indices {
            for item in agendas[i] where !isHomeworkBlock(item) {
                let r = layout.rect(start: item.start, end: item.end, day: i, slot: slots[i][item.id])
                if r.contains(p) { return (item, r) }
            }
        }
        return nil
    }

    @ViewBuilder private func gridBackground(layout: PlannerLayout, now: Date, focusID: UUID?, allDays: [[AgendaItem]]) -> some View {
        let cal = Calendar.current
        let focus = focusID.flatMap { store.task($0) }
        let cap = store.data.settings.hwDailyCap
        ZStack(alignment: .topLeading) {
            // Часы
            ForEach(Array(layout.lo...layout.hi), id: \.self) { h in
                let y = layout.origin.y + CGFloat((h - layout.lo) * 60) * layout.ppm
                Rectangle()
                    .fill(Color.white.opacity(h % 3 == 0 ? 0.08 : 0.04))
                    .frame(width: layout.colW * 7, height: 1)
                    .offset(x: layout.origin.x, y: y)
                if h < layout.hi {
                    Text(String(format: "%02d", h % 24))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.32))
                        .offset(x: layout.origin.x - timeColumn + 4, y: y - 6)
                }
            }
            // Дни
            ForEach(Array(layout.days.enumerated()), id: \.offset) { i, day in
                let x = layout.origin.x + CGFloat(i) * layout.colW
                let isToday = cal.isDate(day, inSameDayAs: now)
                let weekday = cal.component(.weekday, from: day)
                let load = store.homeworkMinutes(on: day)
                Rectangle()
                    .fill(Color.white.opacity(weekday == 1 || weekday == 7 ? 0.035 : 0.015))
                    .frame(width: layout.colW - 2, height: layout.height)
                    .offset(x: x + 1, y: layout.origin.y)
                VStack(alignment: .leading, spacing: 0) {
                    Text(dayLabel(day, now: now))
                        .font(.system(size: 11.5, weight: isToday ? .bold : .semibold))
                        .foregroundStyle(isToday ? Color.white : Color.white.opacity(0.7))
                    Text(load > 0 ? "ДЗ \(Fmt.duration(load)) / \(Fmt.duration(cap))" : " ")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(load > cap ? Palette.orange : Color.white.opacity(0.38))
                    if let first = allDays[i].first {
                        HStack(spacing: 3) {
                            Circle().fill(first.color).frame(width: 5, height: 5)
                            Text(first.title + (allDays[i].count > 1 ? " +\(allDays[i].count - 1)" : "")).lineLimit(1)
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(first.color.opacity(0.18)))
                        .help(allDays[i].map(\.title).joined(separator: "\n"))
                    }
                }
                .frame(width: layout.colW - 6, alignment: .leading)
                .offset(x: x + 4, y: 0)
                // Прошедшее время сегодня
                if isToday {
                    let ny = layout.y(now, day: i)
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: layout.colW - 2, height: max(0, ny - layout.origin.y))
                        .offset(x: x + 1, y: layout.origin.y)
                    Rectangle()
                        .fill(Palette.red)
                        .frame(width: layout.colW - 2, height: 1.5)
                        .offset(x: x + 1, y: ny)
                }
                // После дедлайна выбранного ДЗ — штриховка
                if let d = focus?.deadline {
                    let dayEnd = cal.date(byAdding: .day, value: 1, to: day)!
                    if d < day {
                        Hatch().frame(width: layout.colW - 2, height: layout.height)
                            .offset(x: x + 1, y: layout.origin.y)
                    } else if d < dayEnd {
                        let dy = layout.y(d, day: i)
                        Hatch().frame(width: layout.colW - 2, height: max(0, layout.origin.y + layout.height - dy))
                            .offset(x: x + 1, y: dy)
                        HStack(spacing: 3) {
                            Image(systemName: "flag.fill")
                            Text("сдать до \(Fmt.time(d))")
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Palette.red)
                        .fixedSize()
                        .offset(x: x + 5, y: min(dy, layout.origin.y + layout.height - 14) - 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .named("planner")) { phase in
            switch phase {
            case .active(let p): hover = p
            case .ended: hover = nil
            }
        }
        .onTapGesture(coordinateSpace: .named("planner")) { p in
            guard let id = model.plannerSelectedTask, let slot = layout.slot(at: p), let t = store.task(id) else { return }
            place(taskID: id, start: slot.start, minutes: store.defaultBlockMinutes(t, now: store.now))
        }
    }

    private func dayLabel(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "EE d"
        let base = f.string(from: d).capitalizedFirst
        return Calendar.current.isDate(d, inSameDayAs: now) ? "Сегодня, \(Calendar.current.component(.day, from: d))" : base
    }

    // MARK: Блоки ДЗ

    private func isHomeworkBlock(_ item: AgendaItem) -> Bool {
        if case let .block(_, taskID) = item.kind { return store.task(taskID)?.isHomework == true }
        return false
    }

    @ViewBuilder
    private func homeworkBlock(_ item: AgendaItem, layout: PlannerLayout, day: Int, slot: PlannerLayout.OverlapSlot?,
                               focusID: UUID?, ghost: Ghost?) -> some View {
        if case let .block(blockID, taskID) = item.kind {
            let rect = layout.rect(start: item.start, end: item.end, day: day, slot: slot)
            let auto = store.data.blocks.first { $0.id == blockID }?.hwAuto == true
            PlannerBlockView(
                item: item, rect: rect, auto: auto,
                highlighted: focusID == taskID,
                dimmed: ghost?.movingBlock == blockID,
                onTap: { model.plannerSelectedTask = taskID },
                onDelete: { withAnimation(.snappy) { store.deleteBlock(blockID) } },
                onDone: { store.toggleDone(taskID) },
                moveChanged: { v in
                    if drag == nil {
                        drag = PlannerDrag(kind: .move(blockID), location: v.location,
                                           grabMinutes: (v.startLocation.y - rect.minY) / layout.ppm)
                    } else {
                        drag?.location = v.location
                    }
                },
                moveEnded: { v in finishDrag(at: v.location, layout: layout) },
                resizeChanged: { v in
                    if drag == nil { drag = PlannerDrag(kind: .resize(blockID), location: v.location) } else { drag?.location = v.location }
                },
                resizeEnded: { v in finishDrag(at: v.location, layout: layout) }
            )
        }
    }

    // MARK: Призрак (куда встанет блок)

    private func currentGhost(layout: PlannerLayout, now: Date) -> Ghost? {
        if let drag {
            switch drag.kind {
            case .new(let id):
                guard let t = store.task(id), let s = layout.slot(at: drag.location) else { return nil }
                let m = store.defaultBlockMinutes(t, now: now)
                return Ghost(taskID: id, day: s.day, start: s.start, end: s.start.addingTimeInterval(TimeInterval(m * 60)), movingBlock: nil)
            case .move(let bid):
                guard let b = store.data.blocks.first(where: { $0.id == bid }) else { return nil }
                let p = CGPoint(x: drag.location.x, y: drag.location.y - drag.grabMinutes * layout.ppm)
                guard let s = layout.slot(at: p) else { return nil }
                return Ghost(taskID: b.taskID, day: s.day, start: s.start, end: s.start.addingTimeInterval(b.end.timeIntervalSince(b.start)), movingBlock: bid)
            case .resize(let bid):
                guard let b = store.data.blocks.first(where: { $0.id == bid }), let di = layout.dayIndex(of: b.start) else { return nil }
                let p = CGPoint(x: layout.origin.x + CGFloat(di) * layout.colW + 2, y: drag.location.y)
                guard let s = layout.slot(at: p) else { return nil }
                let end = max(b.start.addingTimeInterval(15 * 60), s.start)
                return Ghost(taskID: b.taskID, day: di, start: b.start, end: end, movingBlock: bid)
            }
        }
        if let id = model.plannerSelectedTask, let t = store.task(id), let p = hover, let s = layout.slot(at: p) {
            let m = store.defaultBlockMinutes(t, now: now)
            return Ghost(taskID: id, day: s.day, start: s.start, end: s.start.addingTimeInterval(TimeInterval(m * 60)), movingBlock: nil)
        }
        return nil
    }

    // MARK: Действия

    private func finishDrag(at location: CGPoint, layout: PlannerLayout) {
        defer { drag = nil }
        guard let d = drag else { return }
        var final = d
        final.location = location
        drag = final
        guard let g = currentGhost(layout: layout, now: store.now) else { return }
        switch d.kind {
        case .new:
            place(taskID: g.taskID, start: g.start, minutes: Int(g.end.timeIntervalSince(g.start) / 60))
        case .move(let bid), .resize(let bid):
            guard g.start >= store.now.addingTimeInterval(-60) else { NSSound.beep(); return }
            withAnimation(.snappy) { store.updateBlock(bid, start: g.start, end: g.end) }
        }
    }

    private func dropNew(taskID: UUID, at location: CGPoint, layout: PlannerLayout) {
        guard let slot = layout.slot(at: location), let t = store.task(taskID) else { return }
        place(taskID: taskID, start: slot.start, minutes: store.defaultBlockMinutes(t, now: store.now))
    }

    private func place(taskID: UUID, start: Date, minutes: Int) {
        guard start >= store.now.addingTimeInterval(-60) else {
            model.flash("Это время уже прошло")
            return
        }
        guard let t = store.task(taskID) else { return }
        withAnimation(.snappy) { store.placeBlock(taskID: taskID, start: start, minutes: minutes) }
        model.flash("\(t.title) → \(Fmt.when(start, now: store.now))")
        // Расписали полностью — сразу выбираем следующее ДЗ.
        if store.remainingMinutes(t, now: store.now) < 5 {
            let open = store.homeworkTasks(course: nil, showDone: false).filter { store.remainingMinutes($0, now: store.now) >= 5 }
            model.plannerSelectedTask = open.first?.id
        }
    }

    private func selectFirstIfNeeded() { selectFirstIfNeeded(force: false) }

    private func selectFirstIfNeeded(force: Bool) {
        if !force, let id = model.plannerSelectedTask, store.task(id)?.done == false { return }
        let open = store.homeworkTasks(course: nil, showDone: false).filter { store.remainingMinutes($0, now: store.now) >= 5 }
        model.plannerSelectedTask = open.first?.id
    }
}

// MARK: - Список ДЗ слева

struct PlannerList: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @Binding var drag: PlannerDrag?
    let now: Date
    let onDrop: (UUID, CGPoint) -> Void

    var body: some View {
        let all = store.homeworkTasks(course: nil, showDone: false)
        let open = all.filter { store.remainingMinutes($0, now: now) >= 5 }
        let planned = all.filter { store.remainingMinutes($0, now: now) < 5 }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Не расписано")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.45))
                Text("\(open.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    if open.isEmpty {
                        Text(all.isEmpty ? "Домашек нет — добавь на странице «ДЗ»" : "Всё расписано 🎉")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    ForEach(open) { t in chip(t) }
                    if !planned.isEmpty {
                        Text("Расписано")
                            .font(.system(size: 11, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        ForEach(planned) { t in chip(t) }
                    }
                }
            }
        }
    }

    private func chip(_ t: TaskItem) -> some View {
        PlannerChip(task: t, store: store, now: now, selected: model.plannerSelectedTask == t.id,
                    dragging: drag?.kind == .new(t.id))
            .onTapGesture {
                model.plannerSelectedTask = model.plannerSelectedTask == t.id ? nil : t.id
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("planner"))
                    .onChanged { v in
                        if drag == nil {
                            model.plannerSelectedTask = t.id
                            drag = PlannerDrag(kind: .new(t.id), location: v.location)
                        } else {
                            drag?.location = v.location
                        }
                    }
                    .onEnded { v in
                        drag = nil
                        onDrop(t.id, v.location)
                    }
            )
    }
}

struct PlannerChip: View {
    let task: TaskItem
    @ObservedObject var store: Store
    let now: Date
    let selected: Bool
    let dragging: Bool

    var body: some View {
        let color = store.courseColor(task.courseID)
        let rest = store.remainingMinutes(task, now: now)
        let next = store.nextBlock(for: task.id, now: now)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(store.course(task.courseID)?.name ?? "Без предмета").foregroundStyle(color.opacity(0.9))
                    if let d = task.deadline {
                        let info = Fmt.deadline(d, now: now)
                        Text("· \(info.text)").foregroundStyle(info.color)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if rest >= 5 {
                Badge(text: rest < task.estimate ? "ещё \(Fmt.duration(rest))" : Fmt.duration(rest), icon: "hourglass")
            } else if let next {
                Badge(text: Fmt.dayWord(next.start, now: now) == "сегодня" ? Fmt.time(next.start) : Fmt.when(next.start, now: now),
                      color: color, icon: "checkmark")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? color.opacity(0.2) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? color.opacity(0.9) : Color.clear, lineWidth: 1.5))
        .opacity(rest < 5 && !selected ? 0.6 : (dragging ? 0.5 : 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Элементы сетки

struct StaticPlannerItem: View {
    let item: AgendaItem
    let rect: CGRect
    var hovered = false

    var body: some View {
        let isTask = item.isTaskBlock
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.black)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isTask ? item.color.opacity(0.22) : item.color.opacity(hovered ? 0.3 : 0.16))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(hovered ? 0.6 : 0.08), lineWidth: 1)
            Rectangle().fill(item.color.opacity(isTask ? 0.6 : 0.9)).frame(width: 2.5)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            if rect.height > 13 {
                Text(item.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(rect.height > 30 ? 2 : 1)
                    .padding(.leading, 6).padding(.top, 2).padding(.trailing, 2)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}

struct PlannerBlockView: View {
    let item: AgendaItem
    let rect: CGRect
    let auto: Bool
    let highlighted: Bool
    let dimmed: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void
    let moveChanged: (DragGesture.Value) -> Void
    let moveEnded: (DragGesture.Value) -> Void
    let resizeChanged: (DragGesture.Value) -> Void
    let resizeEnded: (DragGesture.Value) -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(item.color.opacity(item.done ? 0.3 : 0.92))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(highlighted ? 0.95 : 0), lineWidth: 1.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(rect.height > 34 ? 2 : 1)
                if rect.height > 26 {
                    Text("\(Fmt.time(item.start))–\(Fmt.time(item.end))\(auto ? " · авто" : "")")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .opacity(0.7)
                }
            }
            .foregroundStyle(Color.black.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.top, 3)

            if hover && rect.height > 16 {
                HStack(spacing: 2) {
                    Spacer()
                    smallButton("checkmark", action: onDone)
                    smallButton("xmark", action: onDelete)
                }
                .padding(2)
            }
            // Ручка внизу — растянуть/сжать
            VStack {
                Spacer()
                Capsule()
                    .fill(Color.black.opacity(hover ? 0.35 : 0))
                    .frame(width: 18, height: 3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("planner"))
                        .onChanged(resizeChanged)
                        .onEnded(resizeEnded))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .opacity(dimmed ? 0.3 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("planner"))
            .onChanged(moveChanged)
            .onEnded(moveEnded))
        .contextMenu {
            Button(item.done ? "Вернуть в работу" : "Сдано", action: onDone)
            Button("Убрать блок", role: .destructive, action: onDelete)
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct GhostView: View {
    let ghost: Ghost
    let layout: PlannerLayout
    @ObservedObject var store: Store
    let agendas: [[AgendaItem]]

    var body: some View {
        let rect = layout.rect(start: ghost.start, end: ghost.end, day: ghost.day)
        let color = store.task(ghost.taskID).map { store.courseColor($0.courseID) } ?? .white
        let warning = warningText
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Fmt.time(ghost.start))–\(Fmt.time(ghost.end))")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
            if let warning {
                Text(warning).font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(warning == nil ? Color.white : Palette.red)
        .padding(.horizontal, 5)
        .padding(.top, 3)
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(warning == nil ? color : Palette.red, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .offset(x: rect.minX, y: rect.minY)
    }

    private var warningText: String? {
        if ghost.start < store.now.addingTimeInterval(-60) { return "уже прошло" }
        if let d = store.task(ghost.taskID)?.deadline, ghost.end > d { return "позже дедлайна" }
        let clash = agendas[ghost.day].contains { item in
            if case let .block(bid, _) = item.kind, bid == ghost.movingBlock { return false }
            return item.start < ghost.end && ghost.start < item.end
        }
        return clash ? "пересекается" : nil
    }
}

struct FloatingChip: View {
    let title: String
    let minutes: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).lineLimit(1)
            Text(Fmt.duration(minutes)).opacity(0.6)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color(white: 0.18)))
        .overlay(Capsule().strokeBorder(color.opacity(0.8), lineWidth: 1))
        .fixedSize()
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }
}

/// Штриховка «после дедлайна».
struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            ctx.stroke(path, with: .color(Palette.red.opacity(0.18)), lineWidth: 1)
        }
        .background(Palette.red.opacity(0.05))
        .clipped()
    }
}

/// Карточка с подробностями мероприятия при наведении в сетке.
struct InfoCard: View {
    let item: AgendaItem
    @ObservedObject var store: Store

    var body: some View {
        let details: EventDetails? = {
            if case let .calendar(eventID) = item.kind { return store.calendarService.details(eventID: eventID, start: item.start) }
            return nil
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(item.color).frame(width: 8, height: 8).padding(.top, 4)
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(Fmt.time(item.start))–\(Fmt.time(item.end)) · \(Fmt.duration(item.minutes))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            if let loc = details?.location ?? item.location {
                Label(loc, systemImage: "mappin").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            if let cal = details?.calendar ?? item.calendarName ?? item.projectName {
                Label(cal + ((details?.recurring ?? item.recurring) ? " · повторяется" : ""), systemImage: "calendar")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            if let notes = details?.notes {
                Text(notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(item.color.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }
}
