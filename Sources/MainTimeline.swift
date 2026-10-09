import SwiftUI

// MARK: - «Камни» и «Не успел»

extension Store {
    struct Stone {
        let block: PlanBlock
        let task: TaskItem
    }

    /// Прошедшие сегодня блоки несделанных задач (без более поздних блоков по той же задаче).
    /// На шкале они «тащатся» за красной линией.
    func stones(now: Date) -> [Stone] {
        let cal = Calendar.current
        return data.blocks
            .filter { $0.end <= now && cal.isDate($0.start, inSameDayAs: now) }
            .compactMap { b -> Stone? in
                guard let t = task(b.taskID), !t.done else { return nil }
                if data.blocks.contains(where: { $0.taskID == t.id && $0.end > now }) { return nil }
                return Stone(block: b, task: t)
            }
            .sorted { $0.block.start < $1.block.start }
    }

    /// Камень → обратно в список, в «Не успел».
    func returnToList(blockID: UUID, now: Date = Date()) {
        guard let b = data.blocks.first(where: { $0.id == blockID }) else { return }
        var d = data
        d.blocks.removeAll { $0.id == blockID }
        if let i = d.tasks.firstIndex(where: { $0.id == b.taskID }), !d.tasks[i].done {
            d.tasks[i].missedAt = min(b.end, now)
        }
        data = d
    }

    /// «Делаю сейчас»: блок переезжает на текущее время с той же длительностью.
    func doNow(blockID: UUID, now: Date = Date()) {
        guard let b = data.blocks.first(where: { $0.id == blockID }) else { return }
        let start = now.roundedUp(minutes: 5)
        updateBlock(blockID, start: start, end: start.addingTimeInterval(b.end.timeIntervalSince(b.start)))
    }

    /// Поставить задачу прямо сейчас (из «Не успел»).
    func startNow(taskID: UUID, now: Date = Date()) -> String {
        guard let t = task(taskID) else { return "" }
        let start = now.roundedUp(minutes: 5)
        placeBlock(taskID: taskID, start: start, minutes: defaultBlockMinutes(t, now: now))
        return "\(t.title) → \(Fmt.time(start))"
    }

    /// Ближайшее окно завтра или позже.
    func moveToTomorrow(taskID: UUID, now: Date = Date()) -> String {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        for off in 0..<7 {
            plan(day: cal.date(byAdding: .day, value: off, to: tomorrow)!, now: now, only: taskID)
            if let b = nextBlock(for: taskID, now: now) {
                if let i = data.tasks.firstIndex(where: { $0.id == taskID }) { data.tasks[i].missedAt = nil }
                return "Перенесено: \(Fmt.when(b.start, now: now))"
            }
        }
        return "Не нашлось свободного окна"
    }

    /// Камни прошлых дней (и сегодняшние после конца дня) возвращаются в список «Не успел».
    func rolloverStones(now: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let dayOver = now >= dayBounds(now).end
        var d = data
        var changed = false
        for b in d.blocks where b.end <= now && (b.start < today || dayOver) {
            guard let i = d.tasks.firstIndex(where: { $0.id == b.taskID }), !d.tasks[i].done else { continue }
            if d.blocks.contains(where: { $0.taskID == b.taskID && $0.end > now }) { continue }
            if b.start < today && b.end < today.addingTimeInterval(-86400 * 2) && d.tasks[i].missedAt != nil { continue }
            d.blocks.removeAll { $0.id == b.id }
            d.tasks[i].missedAt = max(d.tasks[i].missedAt ?? .distantPast, b.end)
            changed = true
        }
        if changed { data = d }
    }

    /// «Не успел»: вернулись с шкалы или прошёл дедлайн.
    func overdueTasks(filter: UUID?, now: Date) -> [TaskItem] {
        let stoneIDs = Set(stones(now: now).map(\.task.id))
        return data.tasks.filter { t in
            guard !t.done, filter == nil || t.projectID == filter, !stoneIDs.contains(t.id) else { return false }
            let pending = data.blocks.contains { $0.taskID == t.id && $0.end > now }
            if t.missedAt != nil && !pending { return true }
            if let dl = t.deadline, dl < now { return true }
            return false
        }
        .sorted { ($0.missedAt ?? $0.deadline ?? .distantPast) > ($1.missedAt ?? $1.deadline ?? .distantPast) }
    }

    /// Что показать на шкале: камни прицеплены к «сейчас» друг за другом.
    func timelineItems(day: Date, now: Date) -> [TimelineDisplay] {
        let items = agenda(for: day)
        guard Calendar.current.isDate(day, inSameDayAs: now) else {
            return items.map { TimelineDisplay(item: $0, start: $0.start, end: $0.end, stone: false) }
        }
        let stoneIDs = Set(stones(now: now).map { "b-\($0.block.id)" })
        var out: [TimelineDisplay] = []
        var cursor = now
        for it in items where stoneIDs.contains(it.id) {
            let duration = it.end.timeIntervalSince(it.start)
            out.append(TimelineDisplay(item: it, start: cursor, end: cursor.addingTimeInterval(duration), stone: true))
            cursor = cursor.addingTimeInterval(duration)
        }
        for it in items where !stoneIDs.contains(it.id) {
            out.append(TimelineDisplay(item: it, start: it.start, end: it.end, stone: false))
        }
        return out.sorted { $0.start < $1.start }
    }
}

struct TimelineDisplay: Identifiable {
    let item: AgendaItem
    let start: Date
    let end: Date
    let stone: Bool
    var id: String { item.id }
    var blockID: UUID? { if case let .block(b, _) = item.kind { return b } else { return nil } }
}

/// Где на экране шкала и какое время у её краёв — чтобы ронять на неё задачи из списка.
struct TimelineGeo: Equatable {
    var frame: CGRect
    var origin: Date
    var span: TimeInterval
    var day: Date

    func time(atX x: CGFloat) -> Date {
        origin.addingTimeInterval(span * Double(x / max(1, frame.width)))
    }
    func x(of date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(origin) / span) * frame.width
    }
}

struct TaskDrag: Equatable {
    var taskID: UUID
    var location: CGPoint
}

extension Date {
    func snapped(minutes: Int) -> Date {
        let step = TimeInterval(minutes * 60)
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / step).rounded() * step)
    }
}

// MARK: - Шкала дня на главной

struct TimelinePanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var drag: BlockDrag?

    struct BlockDrag: Equatable {
        enum Mode: Equatable { case move, left, right }
        var blockID: UUID
        var mode: Mode
        var startX: CGFloat
        var x: CGFloat
        var y: CGFloat
        var origStart: Date
        var origEnd: Date
        var stone: Bool
    }

    private let trackHeight: CGFloat = 48

    var body: some View {
        let now = store.now
        let day = model.selectedDay(now: now)
        let display = store.timelineItems(day: day, now: now)
        let allDay = store.allDayItems(for: day)
        let stones = Calendar.current.isDate(day, inSameDayAs: now) ? display.filter(\.stone) : []
        VStack(spacing: 6) {
            header(day: day, now: now, allDay: allDay, stones: stones)
            GeometryReader { geo in
                track(width: geo.size.width, frameInMain: geo.frame(in: .named("main")), display: display, day: day, now: now)
            }
            .frame(height: trackHeight + 16)
        }
    }

    // MARK: Шапка: дни, «весь день», распределить

    @ViewBuilder
    private func header(day: Date, now: Date, allDay: [AgendaItem], stones: [TimelineDisplay]) -> some View {
        let free = store.freeMinutes(day: day, now: now)
        let planned = store.plannedMinutes(day: day)
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", size: 10) { shift(-1) }
            Button { shift(-model.dayOffset) } label: {
                Text(dayTitle(day, now: now))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 104)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(model.dayOffset == 0 ? 0.14 : 0.07)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(model.dayOffset == 0 ? "Сегодня" : "Вернуться к сегодня")
            IconButton(symbol: "chevron.right", size: 10) { shift(1) }

            if !allDay.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(allDay) { item in
                            Button {
                                select(item.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(item.color).frame(width: 6, height: 6)
                                    Text(item.title).lineLimit(1)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(item.color.opacity(model.timelineSelection == item.id ? 0.35 : 0.16)))
                            }
                            .buttonStyle(.plain)
                            .help("Весь день")
                        }
                    }
                }
                .frame(maxWidth: 420)
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 6)

            if !stones.isEmpty {
                Button { select(stones[0].id) } label: {
                    Label("не сделано: \(stones.count)", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(PillButtonStyle(tint: Palette.red))
                .help("Блоки, время которых прошло, а задача не отмечена — они тащатся за красной линией")
            }
            Text("свободно \(Fmt.duration(free))" + (planned > 0 ? " · задачи \(Fmt.duration(planned))" : ""))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize()
            Button {
                withAnimation(.spring(response: 0.35)) { model.flash(store.plan(day: day).message) }
            } label: {
                Label("Распределить", systemImage: "wand.and.stars")
            }
            .buttonStyle(PillButtonStyle(tint: Palette.colors[5], prominent: true))
            .help("Раскидать незакрытые задачи по свободным окнам — сначала срочные (и «камни» тоже)")
            Menu {
                Button("Убрать задачи из плана на этот день") { store.clearPlan(day: day) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: 24)
    }

    // MARK: Дорожка

    @ViewBuilder
    private func track(width w: CGFloat, frameInMain: CGRect, display: [TimelineDisplay], day: Date, now: Date) -> some View {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let (lo, hi) = hourRange(display, dayStart: dayStart)
        let origin = dayStart.addingTimeInterval(TimeInterval(lo * 3600))
        let span = TimeInterval((hi - lo) * 3600)
        let geo = TimelineGeo(frame: CGRect(x: frameInMain.minX, y: frameInMain.minY, width: w, height: trackHeight),
                              origin: origin, span: span, day: dayStart)
        let xOf: (Date) -> CGFloat = { geo.x(of: $0) }
        let isToday = cal.isDate(day, inSameDayAs: now)
        let shown = display.map { d -> TimelineDisplay in
            guard let drag, d.blockID == drag.blockID else { return d }
            let (s, e) = draggedTimes(drag, geo: geo)
            return TimelineDisplay(item: d.item, start: s, end: e, stone: false)
        }
        let lanes = lanesFor(shown)
        let laneCount = max(1, (lanes.map(\.lane).max() ?? 0) + 1)
        let laneH = (trackHeight - 4) / CGFloat(laneCount)
        let step = w / CGFloat(max(1, hi - lo)) < 40 ? 2 : 1

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(model.taskDrag != nil && geo.frame.insetBy(dx: 0, dy: -14).contains(model.taskDrag!.location) ? 0.1 : 0.05))
                .frame(width: w, height: trackHeight)

            ForEach(Array(lo...hi), id: \.self) { h in
                let hx = CGFloat(h - lo) / CGFloat(hi - lo) * w
                if h > lo && h < hi {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1, height: trackHeight).offset(x: hx)
                }
                if h < hi && (h - lo) % step == 0 {
                    Text(String(format: "%02d:00", h % 24))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                        .offset(x: hx + (h == lo ? 2 : -14), y: trackHeight + 3)
                }
            }

            if isToday && now > origin {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: min(w, max(0, xOf(now))), height: trackHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            ForEach(lanes, id: \.display.id) { entry in
                let d = entry.display
                let x0 = max(0, xOf(d.start)), x1 = min(w, xOf(d.end))
                if x1 > x0 {
                    TrackBlock(display: d, width: max(4, x1 - x0 - 1), height: laneH - 1,
                               selected: model.timelineSelection == d.id, dragging: drag?.blockID == d.blockID && d.blockID != nil,
                               returning: drag?.blockID == d.blockID && (drag?.y ?? 0) > trackHeight + 24,
                               now: now,
                               onTap: { select(d.id) },
                               onDrag: { mode, value in dragChanged(d, mode: mode, value: value) },
                               onDragEnd: { value in dragEnded(value, geo: geo) })
                        .offset(x: x0, y: 2 + CGFloat(entry.lane) * laneH)
                }
            }

            // Задачу тащат из списка — показываем, куда встанет
            if let td = model.taskDrag, geo.frame.insetBy(dx: 0, dy: -14).contains(td.location), let t = store.task(td.taskID) {
                let start = geo.time(atX: td.location.x - geo.frame.minX).snapped(minutes: 5)
                let end = start.addingTimeInterval(TimeInterval(store.defaultBlockMinutes(t, now: now) * 60))
                let gx = xOf(start)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(store.taskColor(t).opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(store.taskColor(t), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .overlay(alignment: .leading) {
                        Text("\(Fmt.time(start))–\(Fmt.time(end))")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .fixedSize()
                    }
                    .frame(width: max(30, xOf(end) - gx), height: trackHeight - 4)
                    .offset(x: gx, y: 2)
                    .allowsHitTesting(false)
            }

            if let drag, drag.y > trackHeight + 24 {
                Text(drag.stone ? "отпусти — вернётся в «Не успел»" : "отпусти — вернётся в список")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.orange)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .offset(x: max(0, min(w - 220, drag.x - 100)), y: trackHeight + 1)
                    .allowsHitTesting(false)
            }

            if isToday && now >= origin && xOf(now) <= w {
                NowMarker(height: trackHeight + 6)
                    .offset(x: xOf(now) - 3.5, y: -3)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "track")
        .onAppear { model.timelineGeo = geo }
        .onChange(of: geo) { _, g in model.timelineGeo = g }
    }

    private struct LaneEntry {
        let display: TimelineDisplay
        let lane: Int
    }

    private func lanesFor(_ items: [TimelineDisplay]) -> [LaneEntry] {
        var ends: [Date] = []
        var out: [LaneEntry] = []
        for it in items.sorted(by: { $0.start < $1.start }) {
            if let i = ends.firstIndex(where: { $0 <= it.start }) {
                ends[i] = it.end
                out.append(LaneEntry(display: it, lane: i))
            } else {
                ends.append(it.end)
                out.append(LaneEntry(display: it, lane: ends.count - 1))
            }
        }
        return out
    }

    private func hourRange(_ items: [TimelineDisplay], dayStart: Date) -> (Int, Int) {
        var lo = store.data.settings.dayStartHour, hi = store.data.settings.dayEndHour
        for it in items {
            lo = min(lo, max(0, Int(it.start.timeIntervalSince(dayStart) / 3600)))
            hi = max(hi, min(24, Int((it.end.timeIntervalSince(dayStart) / 3600).rounded(.up))))
        }
        return (lo, max(hi, lo + 1))
    }

    // MARK: Перетаскивание и растягивание блоков задач

    private func dragChanged(_ d: TimelineDisplay, mode: BlockDrag.Mode, value: DragGesture.Value) {
        guard let bid = d.blockID else { return }
        if drag == nil {
            drag = BlockDrag(blockID: bid, mode: mode, startX: value.startLocation.x, x: value.location.x, y: value.location.y,
                             origStart: d.start, origEnd: d.end, stone: d.stone)
            model.timelineSelection = nil
        } else {
            drag?.x = value.location.x
            drag?.y = value.location.y
        }
    }

    private func draggedTimes(_ g: BlockDrag, geo: TimelineGeo) -> (Date, Date) {
        let delta = geo.span * Double((g.x - g.startX) / max(1, geo.frame.width))
        let minLen: TimeInterval = 10 * 60
        switch g.mode {
        case .move:
            let s = g.origStart.addingTimeInterval(delta).snapped(minutes: 5)
            return (s, s.addingTimeInterval(g.origEnd.timeIntervalSince(g.origStart)))
        case .left:
            let s = min(g.origEnd.addingTimeInterval(-minLen), g.origStart.addingTimeInterval(delta).snapped(minutes: 5))
            return (s, g.origEnd)
        case .right:
            let e = max(g.origStart.addingTimeInterval(minLen), g.origEnd.addingTimeInterval(delta).snapped(minutes: 5))
            return (g.origStart, e)
        }
    }

    private func dragEnded(_ value: DragGesture.Value, geo: TimelineGeo) {
        guard var g = drag else { return }
        g.x = value.location.x
        g.y = value.location.y
        drag = nil
        if g.mode == .move && g.y > trackHeight + 24 {
            withAnimation(.snappy) {
                if g.stone {
                    store.returnToList(blockID: g.blockID)
                    model.flash("Вернул в «Не успел»")
                } else {
                    store.deleteBlock(g.blockID)
                    model.flash("Вернул в список")
                }
            }
            return
        }
        let (s, e) = draggedTimes(g, geo: geo)
        withAnimation(.snappy) { store.updateBlock(g.blockID, start: s, end: e) }
        model.flash("\(Fmt.time(s))–\(Fmt.time(e)) · \(Fmt.duration(Int(e.timeIntervalSince(s) / 60)))")
    }

    private func select(_ id: String) {
        withAnimation(.snappy) { model.timelineSelection = model.timelineSelection == id ? nil : id }
    }

    private func shift(_ delta: Int) {
        withAnimation(.snappy) {
            model.dayOffset = max(-30, min(90, model.dayOffset + delta))
            model.timelineSelection = nil
        }
    }

    private func dayTitle(_ day: Date, now: Date) -> String {
        let word = Fmt.dayWord(day, now: now)
        if word == "сегодня" || word == "завтра" || word == "вчера" { return word.capitalizedFirst + ", " + Fmt.dayMonth(day) }
        return Fmt.shortDate(day)
    }
}

/// Блок на шкале. Задачи можно двигать и тянуть за края; «камень» — красный пунктир.
struct TrackBlock: View {
    let display: TimelineDisplay
    let width: CGFloat
    let height: CGFloat
    let selected: Bool
    let dragging: Bool
    let returning: Bool
    let now: Date
    let onTap: () -> Void
    let onDrag: (TimelinePanel.BlockDrag.Mode, DragGesture.Value) -> Void
    let onDragEnd: (DragGesture.Value) -> Void
    @State private var hover = false

    var body: some View {
        let item = display.item
        let isTask = item.isTaskBlock
        let stone = display.stone
        let past = !stone && display.end <= now
        let color = stone ? Palette.red : item.color
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
                .fill(Color.black)
            RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
                .fill(color.opacity(item.done ? 0.22 : (stone ? 0.28 : isTask ? 0.45 : 0.9) * (past ? 0.55 : 1)))
            RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
                .strokeBorder(selected ? Color.white : color.opacity(isTask || stone ? 0.95 : 0),
                              style: StrokeStyle(lineWidth: selected ? 1.6 : 1, dash: stone ? [4, 3] : []))
            if width > 40 && height > 11 {
                HStack(spacing: 3) {
                    if stone { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5, weight: .bold)) }
                    Text(item.title).lineLimit(1)
                    if stone && width > 150 {
                        Text("· не сделано").opacity(0.75).lineLimit(1)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isTask || stone ? Color.white : Color.black.opacity(0.78))
                .padding(.horizontal, 6)
            }
            if (isTask || stone) && hover && width > 24 {
                HStack {
                    handle(.left)
                    Spacer(minLength: 0)
                    handle(.right)
                }
            }
        }
        .frame(width: width, height: height)
        .opacity(returning ? 0.4 : (dragging ? 0.85 : 1))
        .shadow(color: dragging ? .black.opacity(0.6) : .clear, radius: 6, y: 2)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onTap)
        .gesture(isTask ? DragGesture(minimumDistance: 3, coordinateSpace: .named("track"))
            .onChanged { onDrag(.move, $0) }
            .onEnded(onDragEnd) : nil)
        .help(isTask ? "Тяни — перенести, за края — изменить длительность, вниз — вернуть в список" : item.title)
    }

    private func handle(_ mode: TimelinePanel.BlockDrag.Mode) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.85))
            .frame(width: 3, height: max(6, height - 10))
            .frame(width: 9, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("track"))
                .onChanged { onDrag(mode, $0) }
                .onEnded(onDragEnd))
    }
}

// MARK: - Карточка подробностей под шкалой

struct TimelineDetailsCard: View {
    let display: TimelineDisplay
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        let item = display.item
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(display.stone ? Palette.red : item.color).frame(width: 9, height: 9).padding(.top, 4)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                IconButton(symbol: "xmark", size: 10) { model.timelineSelection = nil }
            }
            if display.stone, case let .block(blockID, taskID) = item.kind {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Не сделано — было \(Fmt.time(item.start))–\(Fmt.time(item.end)), тащится за красной линией уже \(Fmt.countdown(store.now.timeIntervalSince(item.end)))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Сделано") {
                            store.toggleDone(taskID)
                            model.timelineSelection = nil
                        }
                        .buttonStyle(PillButtonStyle(tint: Palette.colors[3], prominent: true))
                        Button("Делаю сейчас") {
                            store.doNow(blockID: blockID)
                            model.timelineSelection = nil
                        }
                        .buttonStyle(PillButtonStyle(tint: item.color))
                        Button("Вернуть в список") {
                            store.returnToList(blockID: blockID)
                            model.timelineSelection = nil
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            } else {
                AgendaDetails(item: item, model: model, store: store)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder((display.stone ? Palette.red : item.color).opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
    }
}
