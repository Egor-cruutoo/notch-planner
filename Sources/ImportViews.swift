import SwiftUI
import UniformTypeIdentifiers

/// Принимает перетащенную картинку (файл со скриншотом или само изображение).
func loadDroppedImage(_ providers: [NSItemProvider], model: IslandModel) -> Bool {
    guard let provider = providers.first else { return false }
    if provider.canLoadObject(ofClass: URL.self) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            let image = url.flatMap { NSImage(contentsOf: $0) }
            DispatchQueue.main.async {
                if let image { model.onImportImage(image) } else { model.flash("Это не картинка") }
            }
        }
        return true
    }
    if provider.canLoadObject(ofClass: NSImage.self) {
        _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
            if let image = obj as? NSImage { DispatchQueue.main.async { model.onImportImage(image) } }
        }
        return true
    }
    return false
}

/// Зона «кинь сюда», когда к вырезу тащат файл.
struct DropZoneView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let hot = model.dropTargeted
        let green = Palette.colors[3]
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchHeight)
            HStack(spacing: 12) {
                Image(systemName: hot ? "photo.badge.checkmark.fill" : "photo.badge.plus")
                    .font(.system(size: 24))
                    .foregroundStyle(hot ? green : Color.white.opacity(0.7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hot ? "Отпускай!" : "Кинь скриншот сюда")
                        .font(.system(size: 14, weight: .semibold))
                    Text("найду мероприятия и добавлю в расписание")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hot ? green : Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.15), value: hot)
    }
}

/// Разбор скриншота: превью, найденные мероприятия, «Добавить».
struct ImportPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.importImage == nil, let source = model.importSourceText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ты написал")
                        .font(.system(size: 10.5, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.4))
                    Text(source)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(width: 280, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            }
            if let image = model.importImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    @ViewBuilder private var content: some View {
        switch model.importPhase {
        case .idle:
            EmptyView()
        case .reading, .thinking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.importPhase == .reading ? "Распознаю текст на скриншоте…" : "DeepSeek разбирает мероприятия…")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(model.importPhase == .reading ? "Прямо на Mac, картинка никуда не уходит."
                                               : "Отправлен только распознанный текст.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button("Отмена", action: model.onCancelImport).buttonStyle(PillButtonStyle())
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.orange)
                Text(message)
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.data.settings.deepseekKeySaved {
                DeepSeekKeyField(store: store, model: model) {
                    if let image = model.importImage { model.onImportImage(image) }
                }
                .frame(maxWidth: 520)
            }
            Spacer()
            HStack(spacing: 8) {
                if store.data.settings.deepseekKeySaved, let image = model.importImage {
                    Button("Попробовать снова") { model.onImportImage(image) }
                        .buttonStyle(PillButtonStyle(tint: Palette.colors[5], prominent: true))
                }
                Button("Закрыть", action: model.onCancelImport).buttonStyle(PillButtonStyle())
            }
        case .review:
            let chosen = model.importEvents.filter(\.selected).count
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.colors[3])
                Text("Нашёл мероприятий: \(model.importEvents.count)")
                    .font(.system(size: 14, weight: .semibold))
                Text("проверь и поправь, если что")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach($model.importEvents) { $event in
                        ImportRow(event: $event, now: store.now)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    model.onAddImported()
                } label: {
                    Label("Добавить (\(chosen))", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(PillButtonStyle(tint: Palette.colors[3], prominent: true))
                .disabled(chosen == 0)
                Text(store.writeCalendarTitle.map { "→ в «\($0)»" } ?? "→ в Островок")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Отмена", action: model.onCancelImport).buttonStyle(PillButtonStyle())
            }
        }
    }
}

struct ImportRow: View {
    @Binding var event: ImportedEvent
    let now: Date

    var body: some View {
        let cal = Calendar.current
        HStack(alignment: .top, spacing: 10) {
            CheckButton(done: event.selected, color: Palette.colors[3]) { event.selected.toggle() }
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Название", text: $event.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                HStack(spacing: 6) {
                    HStack(spacing: 0) {
                        IconButton(symbol: "chevron.left", size: 9) {
                            event.day = cal.date(byAdding: .day, value: -1, to: event.day)!
                        }
                        let word = Fmt.dayWord(event.day, now: now)
                        Text(word == "сегодня" || word == "завтра" ? "\(Fmt.shortDate(event.day)) · \(word)" : Fmt.shortDate(event.day))
                            .font(.system(size: 11.5, weight: .semibold))
                            .frame(minWidth: 120)
                        IconButton(symbol: "chevron.right", size: 9) {
                            event.day = cal.date(byAdding: .day, value: 1, to: event.day)!
                        }
                    }
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    if event.isTask {
                        Chip(icon: "checklist", text: "задача · \(Fmt.duration(event.estimate ?? 30))", color: Palette.colors[1])
                        Chip(icon: "clock.fill", text: event.start == nil ? "в ближайшее окно" : timeText, color: Palette.colors[4])
                        if let d = event.deadline {
                            Chip(icon: "flag.fill", text: Fmt.deadline(d, now: now).text, color: Palette.orange)
                        }
                    } else {
                        Chip(icon: "clock.fill", text: timeText, color: Palette.colors[4])
                    }
                    if !event.weekdays.isEmpty {
                        Chip(icon: "repeat", text: Fmt.weekdays(event.weekdays), color: Palette.colors[6])
                    }
                    if let loc = event.location {
                        Chip(icon: "mappin", text: String(loc.prefix(40)), color: Color.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(event.selected ? 0.06 : 0.02)))
        .opacity(event.selected ? 1 : 0.5)
    }

    private var timeText: String {
        guard let s = event.start else { return "весь день" }
        let hm = { (m: Int) in String(format: "%02d:%02d", (m / 60) % 24, m % 60) }
        return event.end.map { "\(hm(s))–\(hm($0))" } ?? hm(s)
    }
}

struct DeepSeekKeyField: View {
    @ObservedObject var store: Store
    @ObservedObject var model: IslandModel
    var onSaved: () -> Void = {}
    @State private var draft = ""

    var body: some View {
        if store.data.settings.deepseekKeySaved {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(Palette.colors[3])
                Text("Ключ DeepSeek в Связке ключей")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 4)
                Button("Удалить") { store.deleteDeepseekKey() }
                    .buttonStyle(PillButtonStyle(tint: Palette.red))
            }
        } else {
            HStack(spacing: 6) {
                SecureField("", text: $draft, prompt: Text("Ключ DeepSeek: sk-…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .onSubmit(save)
                Button("Сохранить", action: save)
                    .buttonStyle(PillButtonStyle(tint: Palette.colors[3], prominent: true))
                    .fixedSize()
            }
        }
    }

    private func save() {
        if store.saveDeepseekKey(draft) {
            draft = ""
            model.flash("Ключ сохранён")
            onSaved()
        } else {
            model.flash("Не получилось сохранить ключ")
        }
    }
}
