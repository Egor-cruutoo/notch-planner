import AppKit
import Vision
import Security

// MARK: - Связка ключей

/// Секреты (ключ DeepSeek) — в Связке ключей macOS, а не в файле с данными.
enum Keychain {
    private static let service = "local.ostrovok.app"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecAttrLabel as String] = "Островок — ключ DeepSeek"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// MARK: - Распознавание текста (локально, Apple Vision)

enum OCR {
    /// Текст со скриншота построчно; ячейки одной строки (например, в таблице расписания) — через « | ».
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = ["ru-RU", "en-US"].filter { supported.contains($0) }
        if !wanted.isEmpty { request.recognitionLanguages = wanted }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        struct Line { let text: String; let box: CGRect }
        let lines = (request.results ?? []).compactMap { obs in
            obs.topCandidates(1).first.map { Line(text: $0.string, box: obs.boundingBox) }
        }
        // У Vision начало координат внизу — идём сверху вниз и склеиваем то, что на одной высоте.
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - line.box.midY) < max(anchor.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  |  ") }
            .joined(separator: "\n")
    }
}

// MARK: - DeepSeek: текст → мероприятия

struct ImportedEvent: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var day: Date
    var start: Int?          // минуты от полуночи
    var end: Int?
    var location: String?
    var weekdays: [Int]      // 1 = вс … 7 = сб
    var selected = true
    // Задача (а не мероприятие): ставится в расписание как блок
    var isTask = false
    var estimate: Int? = nil
    var deadline: Date? = nil
    var projectName: String? = nil
    var dayGiven = true      // у задачи указан день

    var parsedInput: ParsedInput {
        var p = ParsedInput()
        p.kind = .event
        p.title = title
        p.day = Calendar.current.startOfDay(for: day)
        p.startMinutes = start
        p.endMinutes = end
        p.weekdays = weekdays
        p.location = location
        p.allDay = start == nil
        return p
    }
}

enum DeepSeekError: LocalizedError {
    case noKey
    case badKey
    case noMoney
    case badModel(String)
    case http(Int, String)
    case badAnswer

    var errorDescription: String? {
        switch self {
        case .noKey: return "Нужен ключ DeepSeek — вставь его в настройках (шестерёнка → «Островок»)"
        case .badKey: return "DeepSeek не принял ключ — проверь его в настройках"
        case .noMoney: return "На счёте DeepSeek закончились деньги"
        case .badModel(let m): return "DeepSeek не знает модель «\(m)» — поменяй её в настройках"
        case .http(let code, let msg): return "DeepSeek ответил ошибкой \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        case .badAnswer: return "DeepSeek вернул что-то непонятное — попробуй ещё раз"
        }
    }
}

enum DeepSeek {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let keyAccount = "deepseek-api-key"

    static func systemPrompt(now: Date) -> String {
        let f = DateFormatter()
        f.locale = Fmt.ru
        f.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        return """
        Ты извлекаешь мероприятия из текста, распознанного со скриншота (расписание пар, афиша, сообщение в чате, письмо, приглашение).
        Сейчас \(f.string(from: now)) (\(iso.string(from: now))), часовой пояс \(TimeZone.current.identifier).
        Верни только JSON такого вида:
        {"events":[{"title":"...","date":"YYYY-MM-DD","start":"HH:MM","end":"HH:MM","location":"...","weekly_days":[]}],
         "tasks":[{"title":"...","date":"YYYY-MM-DD","start":"HH:MM","estimate_minutes":60,"deadline":"YYYY-MM-DD HH:MM","project":"..."}]}
        Что куда:
        - events — мероприятия: пары, встречи, созвоны, концерты, тренировки — то, что происходит в определённое время или месте.
        - tasks — дела, которые человек делает сам: сделать, написать, прочитать, подготовить, купить, сдать, позвонить, разобрать.
        Для tasks:
        - date/start — когда делать, если сказано («завтра в 15:00 написать эссе»; «в субботу убраться» — только date); иначе null.
        - estimate_minutes — сколько займёт, если сказано («2 часа», «полчаса»), иначе оцени по смыслу (15–180).
        - deadline — если есть срок («до пятницы», «к 12.10»; без времени — 23:59), иначе null.
        - project — если явно назван проект или предмет, иначе null.
        Правила для events:
        - Относительные даты («сегодня», «завтра», «в пятницу», «12 октября») переводи в даты относительно текущей. Если год не указан — ближайшая будущая дата.
        - Если указано только время без даты — это сегодня, если время ещё не прошло, иначе завтра.
        - start/end — 24-часовой формат. Нет времени окончания — end: null. Нет времени вообще — start и end: null.
        - title — коротко и понятно, на языке источника, без даты и времени (например «Пара: Матанализ», «Встреча с куратором», «Концерт Кино»).
        - location — аудитория/адрес/ссылка, если есть, иначе null.
        - weekly_days заполняй, только если явно сказано, что повторяется каждую неделю, или это недельное расписание пар: числа 1–7 (1 = понедельник … 7 = воскресенье); тогда date — ближайшее занятие.
        - Не выдумывай: только то, что есть в тексте. Задача — не мероприятие. Ничего нет — {"events":[],"tasks":[]}.
        - Если пользователь сам описал мероприятие словами и не указал конец, но длительность очевидна (пара — 1:30, встреча/созвон — 1 час, ужин — 2 часа, кино — 2:30) — поставь end по здравому смыслу; иначе end: null.
        - «В 7 вечера» = 19:00, «в полдень» = 12:00, «утром» без точного времени — start: null.
        """
    }

    /// Пробует модель из настроек, а если её нет — запасную.
    static func extractEvents(text: String, now: Date, model: String, key: String, typed: Bool = false,
                              completion: @escaping (Result<[ImportedEvent], Error>) -> Void) {
        let primary = model.trimmingCharacters(in: .whitespaces).isEmpty ? "deepseek-v4-flash" : model
        let models = primary == "deepseek-chat" ? [primary] : [primary, "deepseek-chat"]
        let message = typed
            ? "Пользователь описал мероприятие своими словами:\n<<<\n\(text)\n>>>\nВерни JSON."
            : "Текст со скриншота:\n<<<\n\(text)\n>>>\nВерни JSON."
        attempt(models: models, index: 0, message: message, now: now, key: key, completion: completion)
    }

    private static func attempt(models: [String], index: Int, message: String, now: Date, key: String,
                                completion: @escaping (Result<[ImportedEvent], Error>) -> Void) {
        request(model: models[index], message: message, now: now, key: key) { result in
            if case .failure(let error) = result, case DeepSeekError.badModel = error, index + 1 < models.count {
                attempt(models: models, index: index + 1, message: message, now: now, key: key, completion: completion)
            } else {
                completion(result)
            }
        }
    }

    private static func request(model: String, message: String, now: Date, key: String,
                                completion: @escaping (Result<[ImportedEvent], Error>) -> Void) {
        var req = URLRequest(url: endpoint, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt(now: now)],
                ["role": "user", "content": message],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard (200..<300).contains(code) else {
                let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
                if code == 401 {
                    completion(.failure(DeepSeekError.badKey))
                } else if code == 402 {
                    completion(.failure(DeepSeekError.noMoney))
                } else if [400, 404, 422].contains(code) && message.lowercased().contains("model") {
                    completion(.failure(DeepSeekError.badModel(model)))
                } else {
                    completion(.failure(DeepSeekError.http(code, String(message.prefix(120)))))
                }
                return
            }
            guard let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            else { completion(.failure(DeepSeekError.badAnswer)); return }
            completion(parse(content))
        }.resume()
    }

    /// Разбор ответа модели (отдельно — чтобы проверять без сети).
    static func parse(_ content: String) -> Result<[ImportedEvent], Error> {
        var raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("```") {   // на всякий случай — если ответ пришёл в блоке кода
            raw = raw.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let r = raw.range(of: "```", options: .backwards) { raw = String(raw[..<r.lowerBound]) }
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["events"] != nil || obj["tasks"] != nil else { return .failure(DeepSeekError.badAnswer) }
        let list = obj["events"] as? [[String: Any]] ?? []
        let taskList = obj["tasks"] as? [[String: Any]] ?? []
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        let events: [ImportedEvent] = list.compactMap { e in
            guard let title = (e["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                  let dateStr = e["date"] as? String, let day = df.date(from: dateStr) else { return nil }
            let start = (e["start"] as? String).flatMap(QuickParser.parseTime)
            var end = (e["end"] as? String).flatMap(QuickParser.parseTime)
            if start == nil { end = nil }
            let location = (e["location"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            // ISO-дни недели (1 = пн … 7 = вс) → как в Calendar (1 = вс … 7 = сб)
            let iso = (e["weekly_days"] as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") } ?? []
            let weekdays = Array(Set(iso.filter { (1...7).contains($0) }.map { $0 % 7 + 1 })).sorted()
            return ImportedEvent(title: title, day: day, start: start, end: end, location: location,
                                 weekdays: start == nil ? [] : weekdays)
        }
        let dtf = DateFormatter()
        dtf.locale = Locale(identifier: "en_US_POSIX")
        dtf.timeZone = .current
        dtf.dateFormat = "yyyy-MM-dd HH:mm"
        let tasks: [ImportedEvent] = taskList.compactMap { t in
            guard let title = (t["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            let day = (t["date"] as? String).flatMap { df.date(from: $0) }
            let start = day == nil ? nil : (t["start"] as? String).flatMap(QuickParser.parseTime)
            let estimate = (t["estimate_minutes"] as? Int) ?? (t["estimate_minutes"] as? Double).map { Int($0) }
            var deadline: Date? = nil
            if let dl = t["deadline"] as? String {
                deadline = dtf.date(from: dl) ?? df.date(from: dl).map { $0.addingTimeInterval(23 * 3600 + 59 * 60) }
            }
            let project = (t["project"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            var e = ImportedEvent(title: title, day: day ?? Calendar.current.startOfDay(for: Date()), start: start, end: nil,
                                  location: nil, weekdays: [])
            e.isTask = true
            e.estimate = estimate.map { max(5, min(8 * 60, $0)) }
            e.deadline = deadline
            e.projectName = project
            e.dayGiven = day != nil
            return e
        }
        return .success(events + tasks)
    }
}

// MARK: - Сценарий «кинул скриншот → мероприятия в расписании»

enum ImportPhase: Equatable {
    case idle
    case reading
    case thinking
    case review
    case failed(String)
}

extension IslandController {
    /// Широкая строка: описание мероприятия словами → DeepSeek → календарь.
    func importText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.aiBusy else { return }
        guard let key = store.deepseekKey() else {
            // Без ключа: «14:00-15:30 Пара» — событие, всё остальное — задача в ближайшее окно.
            let p = QuickParser.parse(trimmed, now: Date())
            store.lastCreated = []
            let undo: () -> Void = { [weak self] in self?.model.flash(self?.store.undoLastCreated()) }
            if p.kind == .event {
                if let msg = store.add(p) {
                    model.quickText = ""
                    model.flash(msg, undo: undo)
                }
            } else if !p.title.isEmpty {
                var e = ImportedEvent(title: p.title, day: Calendar.current.startOfDay(for: Date()), start: nil, end: nil,
                                      location: nil, weekdays: [])
                e.isTask = true
                e.estimate = p.estimate
                e.deadline = p.deadline
                e.projectName = p.projectName
                e.dayGiven = false
                model.quickText = ""
                model.flash(store.addImportedTask(e), undo: undo)
            }
            return
        }
        model.aiBusy = true
        DeepSeek.extractEvents(text: trimmed, now: Date(), model: store.data.settings.deepseekModel, key: key, typed: true) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.aiBusy = false
                switch result {
                case .failure(let error):
                    self.model.flash(error.localizedDescription)
                case .success(let events) where events.isEmpty:
                    self.model.flash("Не понял, что добавить — попробуй сформулировать иначе")
                case .success(let events):
                    self.model.quickText = ""
                    self.model.importImage = nil
                    self.model.importSourceText = trimmed
                    self.model.importEvents = events
                    if self.store.data.settings.importAutoAdd {
                        self.addImported()
                    } else {
                        self.model.importPhase = .review
                    }
                }
            }
        }
    }

    func importImage(_ image: NSImage) {
        model.dropZone = false
        model.importSourceText = nil
        model.importImage = image
        model.importEvents = []
        model.importPhase = .reading
        model.showSettings = false
        expand(focus: false)

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            model.importPhase = .failed("Не получилось открыть картинку")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = (try? OCR.recognize(cg)) ?? ""
            DispatchQueue.main.async {
                guard let self, self.model.importPhase == .reading else { return }
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
                    self.model.importPhase = .failed("На картинке не нашёл текста")
                    return
                }
                guard let key = self.store.deepseekKey() else {
                    self.model.importPhase = .failed(DeepSeekError.noKey.localizedDescription)
                    return
                }
                self.model.importPhase = .thinking
                DeepSeek.extractEvents(text: text, now: Date(), model: self.store.data.settings.deepseekModel, key: key) { result in
                    DispatchQueue.main.async {
                        guard self.model.importPhase == .thinking else { return }   // отменили
                        switch result {
                        case .failure(let error):
                            self.model.importPhase = .failed(error.localizedDescription)
                        case .success(let all) where all.filter({ !$0.isTask }).isEmpty:
                            self.model.importPhase = .failed("Мероприятий на скриншоте не нашёл")
                        case .success(let all):
                            self.model.importEvents = all.filter { !$0.isTask }
                            self.model.importPhase = .review
                            if self.store.data.settings.importAutoAdd { self.addImported() }
                        }
                    }
                }
            }
        }
    }

    func addImported() {
        let chosen = model.importEvents.filter(\.selected)
        store.lastCreated = []
        var messages: [String] = []
        for e in chosen {
            if e.isTask {
                messages.append(store.addImportedTask(e))
            } else if let m = store.add(e.parsedInput) {
                messages.append(m)
            }
        }
        model.importPhase = .idle
        model.importEvents = []
        model.importImage = nil
        model.importSourceText = nil
        let undo: () -> Void = { [weak self] in self?.model.flash(self?.store.undoLastCreated()) }
        if messages.count == 1 {
            model.flash(messages[0], undo: undo)
        } else if !messages.isEmpty {
            model.flash("Добавлено: \(messages.count)", undo: undo)
        }
    }

    func cancelImport() {
        model.importPhase = .idle
        model.importEvents = []
        model.importImage = nil
        model.importSourceText = nil
    }
}

extension Store {
    private static var cachedKey: String?

    func deepseekKey() -> String? {
        if let k = Store.cachedKey { return k }
        guard data.settings.deepseekKeySaved, let k = Keychain.get(DeepSeek.keyAccount), !k.isEmpty else { return nil }
        Store.cachedKey = k
        return k
    }

    func saveDeepseekKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, Keychain.set(k, for: DeepSeek.keyAccount) else { return false }
        Store.cachedKey = k
        data.settings.deepseekKeySaved = true
        return true
    }

    func deleteDeepseekKey() {
        Keychain.delete(DeepSeek.keyAccount)
        Store.cachedKey = nil
        data.settings.deepseekKeySaved = false
    }
}
