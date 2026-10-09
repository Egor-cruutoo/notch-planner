import Foundation

/// Результат разбора строки быстрого ввода.
struct ParsedInput: Equatable {
    enum Kind { case task, event }

    var kind: Kind = .task
    var title = ""
    var projectName: String?
    var estimate: Int?           // минуты
    var deadline: Date?
    var priority = false
    var day: Date?               // день события
    var startMinutes: Int?       // от полуночи
    var endMinutes: Int?
    var weekdays: [Int] = []     // повтор события по дням недели
    var location: String?
    var allDay = false           // мероприятие на весь день (со скриншота)
}

/// Разбирает строки вида:
///   «Домашка по матану #учёба 1.5ч до пт !»
///   «14:00-15:30 Пара по физике #учёба»
///   «по пн ср 9:00-10:30 Матан #учёба»
///   «завтра в 10:00 созвон 30м»
enum QuickParser {
    static let weekdayNames: [String: Int] = {
        var m: [String: Int] = [:]
        let table: [(Int, [String])] = [
            (2, ["пн", "пон", "понедельник", "понедельника", "понедельнику", "понедельникам", "mon", "monday"]),
            (3, ["вт", "вторник", "вторника", "вторнику", "вторникам", "tue", "tuesday"]),
            (4, ["ср", "среда", "среду", "среды", "среде", "средам", "wed", "wednesday"]),
            (5, ["чт", "четверг", "четверга", "четвергу", "четвергам", "thu", "thursday"]),
            (6, ["пт", "пятница", "пятницу", "пятницы", "пятнице", "пятницам", "fri", "friday"]),
            (7, ["сб", "суббота", "субботу", "субботы", "субботе", "субботам", "sat", "saturday"]),
            (1, ["вс", "воскресенье", "воскресенья", "воскресенью", "воскресеньям", "sun", "sunday"]),
        ]
        for (day, names) in table { for n in names { m[n] = day } }
        return m
    }()

    static let recurringWords: Set<String> = ["по", "каждый", "каждую", "каждое", "каждые", "every", "еженедельно"]
    static let deadlineWords: Set<String> = ["до", "к", "by", "due"]
    static let prepositions: Set<String> = ["в", "во", "на", "с", "со", "at", "on", "from"]
    static let rangeWords: Set<String> = ["-", "–", "—", "до", "to"]

    static func parse(_ text: String, now: Date = Date(), calendar cal: Calendar = .current) -> ParsedInput {
        var r = ParsedInput()
        let raw = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func low(_ i: Int) -> String? {
            guard i < raw.count else { return nil }
            return raw[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        }

        var titleWords: [String] = []
        var date: Date?
        var deadlineMinutes: Int?
        var afterDeadlineDate = false
        var i = 0

        while i < raw.count {
            let tok = raw[i]
            let w = low(i)!
            let next = low(i + 1)
            let deadlineContext = afterDeadlineDate
            afterDeadlineDate = false

            // «до пт 18:00» — время относится к сроку
            if deadlineContext, r.startMinutes == nil, deadlineMinutes == nil, let m = parseTime(w) {
                deadlineMinutes = m
                i += 1; continue
            }

            // #проект
            if tok.hasPrefix("#"), tok.count > 1 {
                let name = String(tok.dropFirst())
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: .punctuationCharacters)
                if !name.isEmpty { r.projectName = name }
                i += 1; continue
            }

            // ! — важно
            if tok == "!" || tok == "!!" || w == "!важно" {
                r.priority = true
                i += 1; continue
            }

            // по пн ср / каждый вт / по будням
            if recurringWords.contains(w), let n = next, weekdays(in: n) != nil {
                var j = i + 1
                while let lw = low(j), let wds = weekdays(in: lw) {
                    r.weekdays += wds
                    j += 1
                    if low(j) == "и", let after = low(j + 1), weekdays(in: after) != nil { j += 1 }
                }
                i = j; continue
            }

            // через неделю / через 3 дня
            if w == "через", let n = next {
                if n.hasPrefix("недел") {
                    date = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))
                    i += 2; continue
                }
                if let num = Int(n), let unit = low(i + 2) {
                    if unit.hasPrefix("дн") || unit.hasPrefix("ден") {
                        date = cal.date(byAdding: .day, value: num, to: cal.startOfDay(for: now))
                        i += 3; continue
                    }
                    if unit.hasPrefix("недел") {
                        date = cal.date(byAdding: .day, value: 7 * num, to: cal.startOfDay(for: now))
                        i += 3; continue
                    }
                }
            }

            // до пт / к 12.10 / до 18:00
            if deadlineWords.contains(w), let n = next {
                if let d = parseDate(n, now: now, cal: cal) {
                    date = d
                    afterDeadlineDate = true
                    i += 2; continue
                }
                if let m = parseTime(n) {
                    if r.startMinutes != nil, r.endMinutes == nil { r.endMinutes = m } else { deadlineMinutes = m }
                    i += 2; continue
                }
            }

            // в 15:00 / во вторник / с 10:00 — предлог просто пропускаем
            if prepositions.contains(w), let n = next,
               parseDate(n, now: now, cal: cal) != nil || parseTime(n) != nil || parseTimeRange(n) != nil
                || parseDuration(n) != nil || (Double(n) != nil && low(i + 2).flatMap(durationUnit) != nil) {
                i += 1; continue
            }

            // 14:00-15:30
            if let (a, b) = parseTimeRange(w) {
                r.startMinutes = a; r.endMinutes = b
                i += 1; continue
            }

            // 14:00 [- 15:30]
            if let m = parseTime(w) {
                if r.startMinutes == nil {
                    r.startMinutes = m
                    if let sep = low(i + 1), rangeWords.contains(sep), let t2 = low(i + 2), let m2 = parseTime(t2) {
                        r.endMinutes = m2
                        i += 3; continue
                    }
                } else if r.endMinutes == nil {
                    r.endMinutes = m
                }
                i += 1; continue
            }

            // 1.5ч / 45м / 1ч30м
            if let mins = parseDuration(w) {
                r.estimate = (r.estimate ?? 0) + mins
                i += 1; continue
            }
            // 2 часа / 30 минут / полтора часа
            if let n = next, let unit = durationUnit(n) {
                let number: Double? = w == "полтора" ? 1.5 : Double(w.replacingOccurrences(of: ",", with: "."))
                if let number {
                    r.estimate = (r.estimate ?? 0) + Int((number * unit).rounded())
                    i += 2; continue
                }
            }
            if w == "полчаса" {
                r.estimate = (r.estimate ?? 0) + 30
                i += 1; continue
            }

            // сегодня / завтра / пт / 12.10
            if let d = parseDate(w, now: now, cal: cal) {
                date = d
                i += 1; continue
            }

            titleWords.append(tok)
            i += 1
        }

        r.title = titleWords.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))

        if r.startMinutes != nil {
            r.kind = .event
            r.day = r.weekdays.isEmpty ? (date ?? cal.startOfDay(for: now)) : cal.startOfDay(for: now)
        } else {
            r.kind = .task
            var base = date
            if base == nil, deadlineMinutes != nil { base = cal.startOfDay(for: now) }
            if base == nil, let first = r.weekdays.first { base = nextWeekday(first, now: now, cal: cal) }
            if let base {
                let m = deadlineMinutes ?? (23 * 60 + 59)
                r.deadline = cal.date(byAdding: .minute, value: m, to: cal.startOfDay(for: base))
            }
            r.weekdays = []
        }
        return r
    }

    // MARK: - Токены

    static func weekdays(in token: String) -> [Int]? {
        if token == "будни" || token == "будням" || token == "weekdays" { return [2, 3, 4, 5, 6] }
        if token == "выходные" || token == "выходным" || token == "weekends" { return [7, 1] }
        let parts = token.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let d = weekdayNames[p] else { return nil }
            out.append(d)
        }
        return out
    }

    static func nextWeekday(_ weekday: Int, now: Date, cal: Calendar) -> Date {
        let today = cal.startOfDay(for: now)
        let current = cal.component(.weekday, from: today)
        let ahead = (weekday - current + 7) % 7
        return cal.date(byAdding: .day, value: ahead, to: today)!
    }

    static func parseDate(_ w: String, now: Date, cal: Calendar) -> Date? {
        let today = cal.startOfDay(for: now)
        switch w {
        case "сегодня", "today": return today
        case "завтра", "tomorrow": return cal.date(byAdding: .day, value: 1, to: today)
        case "послезавтра": return cal.date(byAdding: .day, value: 2, to: today)
        default: break
        }
        if let wd = weekdayNames[w] { return nextWeekday(wd, now: now, cal: cal) }

        // 12.10 / 12.10.2026 / 12/10
        let pattern = #"^(\d{1,2})[./](\d{2})(?:[./](\d{2}|\d{4}))?$"#
        guard let m = w.range(of: pattern, options: .regularExpression), m == w.startIndex..<w.endIndex else { return nil }
        let nums = w.split(whereSeparator: { $0 == "." || $0 == "/" }).compactMap { Int($0) }
        guard nums.count >= 2, (1...31).contains(nums[0]), (1...12).contains(nums[1]) else { return nil }
        var comps = DateComponents()
        comps.day = nums[0]
        comps.month = nums[1]
        if nums.count == 3 {
            comps.year = nums[2] < 100 ? 2000 + nums[2] : nums[2]
            return cal.date(from: comps)
        }
        comps.year = cal.component(.year, from: now)
        guard var d = cal.date(from: comps) else { return nil }
        // Дата уже прошла больше месяца назад — значит, имелся в виду следующий год.
        if d < cal.date(byAdding: .day, value: -30, to: today)! {
            d = cal.date(byAdding: .year, value: 1, to: d)!
        }
        return d
    }

    static func parseTime(_ w: String) -> Int? {
        let parts = w.split(separator: ":")
        guard parts.count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        if h == 24 && m != 0 { return nil }
        return h * 60 + m
    }

    static func parseTimeRange(_ w: String) -> (Int, Int)? {
        for sep in ["-", "–", "—"] where w.contains(sep) {
            let parts = w.components(separatedBy: sep)
            guard parts.count == 2, let a = parseTime(parts[0]), let b = parseTime(parts[1]) else { return nil }
            return (a, b)
        }
        return nil
    }

    static func durationUnit(_ w: String) -> Double? {
        switch w {
        case "ч", "час", "часа", "часов", "h", "hr", "hrs", "hour", "hours": return 60
        case "м", "мин", "минут", "минуты", "минуту", "m", "min", "mins", "minutes": return 1
        default: return nil
        }
    }

    static func parseDuration(_ w: String) -> Int? {
        let s = w.replacingOccurrences(of: ",", with: ".")
        // 1ч30м / 1h30
        if let r = s.range(of: #"^(\d+)(ч|h)(\d+)(м|мин|m|min)?$"#, options: .regularExpression), r.lowerBound == s.startIndex {
            let digits = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if digits.count == 2 { return digits[0] * 60 + digits[1] }
        }
        // 1.5ч / 2h
        if s.range(of: #"^\d+(\.\d+)?(ч|час|часа|часов|h|hr|hrs)$"#, options: .regularExpression) != nil {
            let num = s.prefix(while: { $0.isNumber || $0 == "." })
            if let v = Double(num) { return Int((v * 60).rounded()) }
        }
        // 45м / 30min
        if s.range(of: #"^\d+(м|мин|минут|m|min|mins)$"#, options: .regularExpression) != nil {
            let num = s.prefix(while: { $0.isNumber })
            return Int(num)
        }
        return nil
    }
}
