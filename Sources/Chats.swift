import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - Хранение

/// То, что прикрепили, но ещё не отправили.
struct PendingAttachment: Identifiable {
    let id = UUID()
    var file: URL?
    var image: NSImage?
    var name: String
}

extension Store {
    var attachmentsDir: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
    }

    func attachmentURL(_ a: ChatAttachment) -> URL {
        attachmentsDir.appendingPathComponent(a.storedName)
    }

    func chatMessages(_ chat: UUID) -> [ChatMessage] {
        data.messages.filter { $0.chatID == chat }.sorted { $0.date < $1.date }
    }

    func lastMessage(_ chat: UUID) -> ChatMessage? {
        data.messages.filter { $0.chatID == chat }.max { $0.date < $1.date }
    }

    /// Отправить заметку: текст и/или вложения (файлы копируются в папку Островка).
    @discardableResult
    func sendMessage(chat: UUID, text: String, pending: [PendingAttachment]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        var attachments: [ChatAttachment] = []
        for p in pending {
            if let url = p.file {
                let ext = url.pathExtension
                let stored = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
                let dest = attachmentsDir.appendingPathComponent(stored)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    NSLog("Ostrovok: не удалось скопировать вложение: \(error)")
                    continue
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
                attachments.append(ChatAttachment(storedName: stored, originalName: url.lastPathComponent, isImage: isImage, size: size))
            } else if let image = p.image,
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let stored = UUID().uuidString + ".png"
                let dest = attachmentsDir.appendingPathComponent(stored)
                guard (try? png.write(to: dest)) != nil else { continue }
                attachments.append(ChatAttachment(storedName: stored, originalName: p.name, isImage: true, size: Int64(png.count)))
            }
        }
        guard !t.isEmpty || !attachments.isEmpty else { return false }
        data.messages.append(ChatMessage(chatID: chat, text: t, attachments: attachments))
        return true
    }

    func deleteMessage(_ id: UUID) {
        guard let m = data.messages.first(where: { $0.id == id }) else { return }
        for a in m.attachments { try? FileManager.default.removeItem(at: attachmentURL(a)) }
        data.messages.removeAll { $0.id == id }
    }

    func messageToTask(_ id: UUID) -> String {
        guard let m = data.messages.first(where: { $0.id == id }) else { return "" }
        let title = m.text.split(separator: "\n").first.map(String.init)
            ?? m.attachments.first?.originalName ?? "Задача"
        data.tasks.append(TaskItem(title: title, projectID: m.chatID, estimate: data.settings.defaultEstimate))
        return "Задача в «\(project(m.chatID)?.name ?? "проект")»"
    }

    func newChat() -> UUID {
        let used = Set(data.projects.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !used.contains($0) } ?? data.projects.count
        let p = Project(name: "Новый чат", colorIndex: color)
        data.projects.append(p)
        return p.id
    }

    /// Удалить чат = проект вместе с заметками и вложениями. Задачи остаются, без проекта.
    func deleteChat(_ id: UUID) {
        for m in data.messages where m.chatID == id {
            for a in m.attachments { try? FileManager.default.removeItem(at: attachmentURL(a)) }
        }
        data.messages.removeAll { $0.chatID == id }
        deleteProject(id)
    }

    func moveChat(_ id: UUID, by delta: Int) {
        guard let i = data.projects.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(data.projects.count - 1, i + delta))
        guard i != j else { return }
        var list = data.projects
        let p = list.remove(at: i)
        list.insert(p, at: j)
        data.projects = list
    }

    func moveChat(_ id: UUID, before target: UUID) {
        guard id != target, let from = data.projects.firstIndex(where: { $0.id == id }),
              let to = data.projects.firstIndex(where: { $0.id == target }) else { return }
        var list = data.projects
        let p = list.remove(at: from)
        list.insert(p, at: to)
        data.projects = list
    }
}

/// Превью картинок без загрузки полного размера.
enum Thumbs {
    private static var cache: [String: NSImage] = [:]

    static func image(_ url: URL, maxPixels: Int = 520) -> NSImage? {
        if let c = cache[url.path] { return c }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache[url.path] = img
        return img
    }
}

/// Из перетаскивания/буфера → вложения.
func loadPending(_ providers: [NSItemProvider], into model: IslandModel) {
    for provider in providers {
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { model.chatPending.append(PendingAttachment(file: url, name: url.lastPathComponent)) }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage else { return }
                DispatchQueue.main.async { model.chatPending.append(PendingAttachment(image: img, name: "Изображение.png")) }
            }
        }
    }
}

// MARK: - Панель чатов

struct ChatsPanel: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var dropTargeted = false

    var body: some View {
        let chats = store.data.projects
        let selected = model.selectedChat.flatMap { id in chats.first { $0.id == id } } ?? chats.first
        HStack(spacing: 0) {
            ChatList(model: model, store: store, selectedID: selected?.id)
                .frame(width: 190)
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            if let chat = selected {
                ChatView(chat: chat, model: model, store: store)
            } else {
                EmptyState(icon: "bubble.left.and.text.bubble.right", title: "Чатов пока нет",
                           hint: "Нажми ✎ слева — каждый проект это чат для заметок, фото и файлов")
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if dropTargeted, let chat = selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.color(chat.colorIndex), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.55)))
                    .overlay(
                        Label("Кинь сюда — сохраню в «\(chat.name)»", systemImage: "tray.and.arrow.down.fill")
                            .font(.system(size: 14, weight: .semibold))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            if model.selectedChat == nil { model.selectedChat = selected?.id }
            loadPending(providers, into: model)
            model.chatFocusToken += 1
            return true
        }
    }
}

struct ChatList: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    let selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Чаты")
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                IconButton(symbol: "square.and.pencil", size: 11) {
                    let id = store.newChat()
                    model.selectedChat = id
                    model.makeKey()
                    model.renamingChat = id
                }
                .help("Новый чат")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.data.projects) { chat in
                        ChatRow(chat: chat, store: store, selected: chat.id == selectedID,
                                dragging: model.draggingChat == chat.id)
                            .onTapGesture { model.selectedChat = chat.id }
                            .onDrag {
                                model.draggingChat = chat.id
                                return NSItemProvider(object: chat.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ChatReorderDelegate(target: chat.id, store: store, model: model))
                            .contextMenu {
                                Button("Переименовать") {
                                    model.selectedChat = chat.id
                                    model.makeKey()
                                    model.renamingChat = chat.id
                                }
                                Button("Сменить цвет") {
                                    if let i = store.data.projects.firstIndex(where: { $0.id == chat.id }) {
                                        store.data.projects[i].colorIndex = (store.data.projects[i].colorIndex + 1) % Palette.colors.count
                                    }
                                }
                                Divider()
                                Button("Выше") { withAnimation(.snappy) { store.moveChat(chat.id, by: -1) } }
                                Button("Ниже") { withAnimation(.snappy) { store.moveChat(chat.id, by: 1) } }
                                Divider()
                                Button("Удалить чат…", role: .destructive) {
                                    model.selectedChat = chat.id
                                    model.confirmDeleteChat = chat.id
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }
}

/// Перетаскивание чатов в списке — меняем порядок на лету.
struct ChatReorderDelegate: DropDelegate {
    let target: UUID
    let store: Store
    let model: IslandModel

    func dropEntered(info: DropInfo) {
        guard let dragging = model.draggingChat, dragging != target else { return }
        withAnimation(.snappy) { store.moveChat(dragging, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.draggingChat = nil
        return true
    }
}

struct ChatRow: View {
    let chat: Project
    @ObservedObject var store: Store
    let selected: Bool
    let dragging: Bool
    @State private var hover = false

    var body: some View {
        let color = Palette.color(chat.colorIndex)
        let last = store.lastMessage(chat.id)
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(color.opacity(0.9))
                Text(String(chat.name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(chat.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let last {
                        Text(Fmt.dayWord(last.date, now: store.now) == "сегодня" ? Fmt.time(last.date) : Fmt.dayWord(last.date, now: store.now))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Text(preview(last))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? color.opacity(0.2) : Color.white.opacity(hover ? 0.05 : 0)))
        .opacity(dragging ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private func preview(_ m: ChatMessage?) -> String {
        guard let m else { return "пусто" }
        if !m.text.isEmpty { return m.text.replacingOccurrences(of: "\n", with: " ") }
        if let a = m.attachments.first { return a.isImage ? "📷 Фото" : "📎 \(a.originalName)" }
        return ""
    }
}

// MARK: - Чат

struct ChatView: View {
    let chat: Project
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let color = Palette.color(chat.colorIndex)
        let messages = store.chatMessages(chat.id)
        VStack(spacing: 0) {
            // Шапка
            HStack(spacing: 8) {
                if model.renamingChat == chat.id {
                    TextField("Название", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onAppear {
                            nameDraft = chat.name
                            DispatchQueue.main.async { nameFocused = true }
                        }
                        .onChange(of: nameFocused) { _, f in if !f { commitName() } }
                } else {
                    Text(chat.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .onTapGesture(count: 2) {
                            model.makeKey()
                            model.renamingChat = chat.id
                        }
                }
                Text("\(messages.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                let open = store.openCount(project: chat.id)
                if open > 0 {
                    Button {
                        model.projectFilter = chat.id
                    } label: {
                        Label("задачи \(open)", systemImage: "checklist")
                    }
                    .buttonStyle(PillButtonStyle(tint: color))
                    .help("Показать задачи этого проекта справа")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            if model.confirmDeleteChat == chat.id {
                HStack(spacing: 8) {
                    Text("Удалить «\(chat.name)» и \(messages.count) заметок? Задачи останутся.")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Button("Удалить") {
                        model.confirmDeleteChat = nil
                        model.selectedChat = nil
                        store.deleteChat(chat.id)
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.red, prominent: true))
                    Button("Отмена") { model.confirmDeleteChat = nil }
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.red.opacity(0.12))
            }

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Сообщения
            if messages.isEmpty {
                EmptyState(icon: "text.bubble", title: "Пусто",
                           hint: "Пиши заметки, кидай фото и файлы — всё останется в этом чате")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                                if i == 0 || !Calendar.current.isDate(messages[i - 1].date, inSameDayAs: m.date) {
                                    Text(daySeparator(m.date))
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.white.opacity(0.06)))
                                        .padding(.top, 4)
                                }
                                MessageBubble(message: m, color: color, model: model, store: store)
                                    .id(m.id)
                            }
                        }
                        .padding(10)
                    }
                    .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last { withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onChange(of: chat.id) { _, _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            ChatComposer(chat: chat, model: model, store: store)
        }
    }

    private func commitName() {
        guard model.renamingChat == chat.id else { return }
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, let i = store.data.projects.firstIndex(where: { $0.id == chat.id }) {
            store.data.projects[i].name = n
        }
        model.renamingChat = nil
    }

    private func daySeparator(_ d: Date) -> String {
        let word = Fmt.dayWord(d, now: store.now)
        if word == "сегодня" || word == "вчера" { return word.capitalizedFirst }
        return Fmt.shortDate(d)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let color: Color
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 40)
            if hover {
                HStack(spacing: 0) {
                    if !message.text.isEmpty {
                        IconButton(symbol: "doc.on.doc", size: 10) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            model.flash("Скопировано")
                        }
                        .help("Скопировать текст")
                    }
                    IconButton(symbol: "checklist", size: 10) { model.flash(store.messageToTask(message.id)) }
                        .help("Сделать задачей")
                    IconButton(symbol: "trash", size: 10, tint: Palette.red) {
                        withAnimation(.snappy) { store.deleteMessage(message.id) }
                    }
                    .help("Удалить")
                }
                .padding(.bottom, 4)
            }
            VStack(alignment: .trailing, spacing: 5) {
                ForEach(message.attachments.filter(\.isImage)) { a in
                    let url = store.attachmentURL(a)
                    if let img = Thumbs.image(url) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .help("Открыть")
                            .contextMenu { attachmentMenu(a, url) }
                    }
                }
                ForEach(message.attachments.filter { !$0.isImage }) { a in
                    let url = store.attachmentURL(a)
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.originalName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file))
                                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { attachmentMenu(a, url) }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(Fmt.time(message.date))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.18)))
            .fixedSize(horizontal: message.text.count < 40, vertical: false)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private func attachmentMenu(_ a: ChatAttachment, _ url: URL) -> some View {
        Button("Открыть") { NSWorkspace.shared.open(url) }
        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Скопировать") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
    }
}

struct ChatComposer: View {
    let chat: Project
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        let color = Palette.color(chat.colorIndex)
        let canSend = !model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.chatPending.isEmpty
        VStack(spacing: 6) {
            if !model.chatPending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.chatPending) { p in
                            HStack(spacing: 5) {
                                if let img = p.image ?? p.file.flatMap({ Thumbs.image($0, maxPixels: 120) }) {
                                    Image(nsImage: img).resizable().scaledToFill().frame(width: 26, height: 26)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                } else if let f = p.file {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 22, height: 22)
                                }
                                Text(p.name).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 140)
                                IconButton(symbol: "xmark", size: 8) { model.chatPending.removeAll { $0.id == p.id } }
                            }
                            .padding(.leading, 5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            HStack(alignment: .bottom, spacing: 6) {
                IconButton(symbol: "paperclip", size: 12) { model.onPickFiles() }
                    .help("Прикрепить файлы")
                TextField("", text: $model.chatDraft, prompt: Text("Заметка в «\(chat.name)»… (фото и файлы — перетащи или ⌘V)"), axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 5)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSend ? color : Color.white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(focused ? 0.1 : 0.06)))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .onTapGesture { model.makeKey(); focused = true }
        }
        .padding(.top, 6)
        .onChange(of: focused) { _, f in model.chatComposerFocused = f }
        .onChange(of: model.chatFocusToken) { _, _ in model.makeKey(); focused = true }
    }

    private func send() {
        if store.sendMessage(chat: chat.id, text: model.chatDraft, pending: model.chatPending) {
            model.chatDraft = ""
            model.chatPending = []
        }
    }
}
