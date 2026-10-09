import SwiftUI
import ServiceManagement

struct SettingsPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(title: "План дня") {
                VStack(spacing: 8) {
                    StepperRow(title: "Начало дня", value: hours(\.dayStartHour, other: \.dayEndHour, isStart: true),
                               range: 0...23) { String(format: "%02d:00", $0) }
                    StepperRow(title: "Конец дня", value: hours(\.dayEndHour, other: \.dayStartHour, isStart: false),
                               range: 1...24) { String(format: "%02d:00", $0) }
                    StepperRow(title: "Перерыв между делами", value: $store.data.settings.breakMinutes,
                               range: 0...60, step: 5) { "\($0) мин" }
                    StepperRow(title: "Самый длинный блок", value: $store.data.settings.maxChunk,
                               range: 15...240, step: 15) { Fmt.duration($0) }
                    StepperRow(title: "Оценка по умолчанию", value: $store.data.settings.defaultEstimate,
                               range: 5...240, step: 5) { Fmt.duration($0) }
                    Text("«Распределить» ставит незакрытые задачи в свободные окна между событиями: сначала с ближним дедлайном и важные, длинные — частями.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Card(title: "Проекты") {
                VStack(spacing: 6) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(store.data.projects) { p in
                                ProjectEditRow(project: binding(for: p.id),
                                               count: store.openCount(project: p.id)) {
                                    if model.projectFilter == p.id { model.projectFilter = nil }
                                    store.deleteProject(p.id)
                                }
                            }
                        }
                    }
                    Button {
                        model.makeKey()
                        store.addProject()
                    } label: {
                        Label("Новый проект", systemImage: "plus")
                    }
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Проект можно создать и прямо из строки ввода: «#диплом».")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Card(title: "Календарь") {
                CalendarSettings(model: model, store: store, linkBinding: calendarBinding)
            }

            Card(title: "Островок") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text("Открывать")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 4)
                        SegmentTab(title: "по клику", selected: !store.data.settings.openOnHover) {
                            store.data.settings.openOnHover = false
                        }
                        SegmentTab(title: "наведением", selected: store.data.settings.openOnHover) {
                            store.data.settings.openOnHover = true
                        }
                    }
                    SettingToggle(title: "Сворачивать, когда уводишь мышь", isOn: $store.data.settings.closeOnLeave)
                    SettingToggle(title: "Широкий островок", isOn: $store.data.settings.wideCollapsed)
                    SettingToggle(title: "Иконка в строке меню", isOn: $store.data.settings.showMenuBarIcon)
                    SettingToggle(title: "Запускать при входе", isOn: launchBinding)
                    Divider().overlay(Color.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Скриншоты с мероприятиями")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                        DeepSeekKeyField(store: store, model: model)
                        HStack(spacing: 6) {
                            Text("Модель")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                            TextField("deepseek-v4-flash", text: $store.data.settings.deepseekModel)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                        }
                        SettingToggle(title: "Добавлять без подтверждения", isOn: $store.data.settings.importAutoAdd)
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 3) {
                        HelpLine(key: "⌃⌥T", text: "открыть и сразу писать")
                        HelpLine(key: "Esc", text: "свернуть (или клик мимо)")
                        HelpLine(key: "скриншот", text: "кинь на островок")
                        HelpLine(key: "1.5ч до пт !", text: "оценка, срок, важно")
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.saveNow()
                        NSApp.terminate(nil)
                    } label: {
                        Label("Выйти из Островка", systemImage: "power")
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.red))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func hours(_ key: WritableKeyPath<AppSettings, Int>, other: WritableKeyPath<AppSettings, Int>, isStart: Bool) -> Binding<Int> {
        Binding(
            get: { store.data.settings[keyPath: key] },
            set: { v in
                var s = store.data.settings
                s[keyPath: key] = v
                if isStart, s[keyPath: other] <= v { s[keyPath: other] = min(24, v + 1) }
                if !isStart, s[keyPath: other] >= v { s[keyPath: other] = max(0, v - 1) }
                store.data.settings = s
            })
    }

    private func binding(for id: UUID) -> Binding<Project> {
        Binding(
            get: { store.data.projects.first { $0.id == id } ?? Project(name: "", colorIndex: 0) },
            set: { newValue in
                if let i = store.data.projects.firstIndex(where: { $0.id == id }) { store.data.projects[i] = newValue }
            })
    }

    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { store.data.settings.useCalendar },
            set: { on in
                guard on else { store.data.settings.useCalendar = false; return }
                store.calendarService.requestAccess { granted in
                    var s = store.data.settings
                    s.useCalendar = granted
                    defer { DispatchQueue.main.async { store.autoPickWriteCalendar() } }
                    // Если подключён Яндекс — сразу предлагаем писать туда.
                    if granted, s.writeCalendarID == nil,
                       let yandex = store.calendarService.calendars().first(where: { $0.writable && $0.looksLikeYandex }) {
                        s.writeCalendarID = yandex.id
                    }
                    store.data.settings = s
                    if !granted {
                        model.flash("Нет доступа: Системные настройки → Конфиденциальность → Календари")
                    }
                }
            })
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    model.flash("Не получилось: \(error.localizedDescription)")
                }
                model.launchAtLogin = SMAppService.mainApp.status == .enabled
            })
    }
}

struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let format: (Int) -> String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            HStack(spacing: 0) {
                IconButton(symbol: "minus", size: 10) { value = max(range.lowerBound, value - step) }
                Text(format(value))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 52)
                IconButton(symbol: "plus", size: 10) { value = min(range.upperBound, value + step) }
            }
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }
}

struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    // Свой переключатель: системный в неактивном окне рисуется серым и не читается.
    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOn.toggle() }
        } label: {
            HStack {
                Text(title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Palette.colors[3] : Color.white.opacity(0.16))
                    Circle().fill(Color.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1)
                }
                .frame(width: 30, height: 17)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HelpLine: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

struct ProjectEditRow: View {
    @Binding var project: Project
    let count: Int
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                project.colorIndex = (project.colorIndex + 1) % Palette.colors.count
            } label: {
                Circle()
                    .fill(Palette.color(project.colorIndex))
                    .frame(width: 13, height: 13)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Сменить цвет")
            TextField("Название", text: $project.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            if confirmDelete {
                Button("Удалить?") { onDelete() }
                    .buttonStyle(PillButtonStyle(tint: Palette.red, prominent: true))
                    .fixedSize()
            } else {
                IconButton(symbol: "trash", size: 10.5) {
                    confirmDelete = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDelete = false }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct CalendarSettings: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let linkBinding: Binding<Bool>

    var body: some View {
        let st = store.data.settings
        let linked = st.useCalendar && store.calendarService.hasAccess
        let calendars = linked ? store.calendarService.calendars() : []
        let hidden = Set(st.hiddenCalendarIDs)
        let target = calendars.first { $0.id == st.writeCalendarID && $0.writable }

        VStack(alignment: .leading, spacing: 9) {
            SettingToggle(title: "Связать с Календарём", isOn: linkBinding)
            if linked {
                Text("Показывать")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(calendars) { c in
                            CalendarRow(info: c, visible: !hidden.contains(c.id)) {
                                var ids = st.hiddenCalendarIDs
                                if let i = ids.firstIndex(of: c.id) { ids.remove(at: i) } else { ids.append(c.id) }
                                store.data.settings.hiddenCalendarIDs = ids
                            }
                        }
                    }
                }
                .frame(maxHeight: 112)

                HStack(spacing: 6) {
                    Text("Новые события")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 4)
                    Menu {
                        Button("Только в Островке") { store.data.settings.writeCalendarID = nil }
                        Divider()
                        ForEach(calendars.filter(\.writable)) { c in
                            Button("\(c.title) — \(c.source)") { store.data.settings.writeCalendarID = c.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let target { Circle().fill(target.color).frame(width: 7, height: 7) }
                            Text(target?.title ?? "только в Островке").lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if let target, store.localUpcomingEventsCount > 0 {
                    Button {
                        model.flash(store.moveLocalEventsToCalendar())
                    } label: {
                        Label("Перенести события Островка (\(store.localUpcomingEventsCount)) в «\(target.title)»",
                              systemImage: "arrow.up.forward.app")
                            .lineLimit(1)
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.colors[5]))
                    .help("События, добавленные до подключения календаря, переедут в него")
                }

                SettingToggle(title: "План задач — в календарь", isOn: $store.data.settings.exportPlan)
                    .disabled(target == nil)
                    .opacity(target == nil ? 0.4 : 1)

                if !calendars.contains(where: \.looksLikeYandex) {
                    YandexHint()
                } else {
                    Text(st.exportPlan
                         ? "Блоки «Распределить» появятся в календаре и на телефоне; при перепланировании обновятся."
                         : "События из строки ввода сразу уходят в выбранный календарь.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Островок показывает события из Календаря macOS, пишет туда новые и не ставит задачи поверх них.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                YandexHint()
            }
        }
    }
}

struct CalendarRow: View {
    let info: CalendarInfo
    let visible: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(visible ? info.color : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(info.color, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                Text(info.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(visible ? 0.85 : 0.4))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(info.source)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct YandexHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Яндекс Календарь")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("Системные настройки → Учётные записи интернета → Добавить → CalDAV, вручную: сервер caldav.yandex.ru, логин @yandex.ru, пароль приложения из Яндекс ID.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
