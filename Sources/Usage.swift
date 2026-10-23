import Foundation

struct AccountUsage: Decodable {
    struct Day: Decodable { let startDate: String; let tokens: Int64 }
    let dailyUsageBuckets: [Day]?
}
struct TokenAmounts: Equatable, Hashable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var writes: Int64 = 0
    var total: Int64 { input + output } // Cached input is a subset; reasoning is part of output.
    static func parse(_ value: [String: Any]) -> TokenAmounts? {
        guard let i = value["input_tokens"] as? NSNumber, let o = value["output_tokens"] as? NSNumber else { return nil }
        let input = i.int64Value, output = o.int64Value
        let cached = (value["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0
        let writes = (value["cache_write_input_tokens"] as? NSNumber)?.int64Value ?? 0
        guard input >= 0, input <= 1_000_000_000_000, output >= 0, output <= 1_000_000_000_000,
              cached >= 0, cached <= input, writes >= 0, writes <= input else { return nil }
        return TokenAmounts(input: input, cached: cached, output: output, writes: writes)
    }
    mutating func add(_ value: TokenAmounts) {
        input += value.input; cached += value.cached; output += value.output; writes += value.writes
    }
}
struct TokenRecord {
    let key: String
    let date: Date
    let model: String
    let speed: String
    let amounts: TokenAmounts
}
struct PricingCatalog: Decodable {
    struct Rate: Decodable {
        let input: Double, output: Double, cached: Double
        let longInput: Double, longOutput: Double, longCached: Double
        let longThreshold: Int64
    }
    let verifiedAt: String
    let source: String
    let basis: String
    let models: [String: Rate]
    static func load(url: URL? = nil) throws -> PricingCatalog {
        guard let url = url ?? Bundle.main.url(forResource: "prices", withExtension: "json") else {
            throw UsageFailure.message("价格表缺失，无法估算费用。")
        }
        return try JSONDecoder().decode(PricingCatalog.self, from: Data(contentsOf: url))
    }
    func cost(_ record: TokenRecord) -> Double? {
        var name = record.model
        // Resolve only explicit documented aliases and dated snapshots of known models.
        if name == "gpt-5.6" { name = "gpt-5.6-sol" }
        let exact = models[name]
        let dated = models.first { name.hasPrefix($0.key + "-") && name.dropFirst($0.key.count + 1).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }?.value
        guard let rate = exact ?? dated, record.amounts.writes == 0 else { return nil }
        let multiplier: Double
        switch record.speed.lowercased() {
        case "standard", "default", "": multiplier = 1
        case "fast", "priority": multiplier = 2
        case "flex", "batch": multiplier = 0.5
        case "ultrafast" where name == "gpt-6.1-sol" || name == "gpt-6-astra": multiplier = 6
        default: return nil
        }
        let a = record.amounts
        let long = a.input > rate.longThreshold
        let inputRate = long ? rate.longInput : rate.input
        let cacheRate = long ? rate.longCached : rate.cached
        let outputRate = long ? rate.longOutput : rate.output
        return (Double(a.input - a.cached) * inputRate + Double(a.cached) * cacheRate + Double(a.output) * outputRate) * multiplier / 1_000_000
    }
}
enum UsageFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
struct ModelUsage: Identifiable {
    let id: String
    var amounts = TokenAmounts()
    var cost: Double = 0
    var unpriced: Int = 0
    var priced: Int = 0
}
struct UsageDay: Identifiable {
    let date: Date
    var id: Date { date }
    var amounts = TokenAmounts()
    var cost: Double = 0
    var unpriced: Int = 0
    var priced: Int = 0
    var records: Int = 0
    var models: [String: ModelUsage] = [:]
    var costValue: Double? { priced > 0 ? cost : (records == 0 ? 0 : nil) }
    mutating func add(_ record: TokenRecord, cost: Double?) {
        records += 1; amounts.add(record.amounts)
        var model = models[record.model] ?? ModelUsage(id: record.model)
        model.amounts.add(record.amounts)
        if let cost = cost { self.cost += cost; priced += 1; model.cost += cost; model.priced += 1 }
        else { unpriced += 1; model.unpriced += 1 }
        models[record.model] = model
    }
}
struct LocalUsageReport {
    let days: [UsageDay]
    let scannedBytes: Int64
    let files: Int
    let skipped: Int
    let priceDate: String
    let generatedAt: Date
    var today: UsageDay { days.last! }
    var yesterday: UsageDay { days[days.count - 2] }
    static func aggregate(records: [TokenRecord], catalog: PricingCatalog, now: Date, calendar: Calendar = .current, bytes: Int64 = 0, files: Int = 0, skipped: Int = 0) -> LocalUsageReport {
        let end = calendar.startOfDay(for: now)
        var days = (0..<30).reversed().map { UsageDay(date: calendar.date(byAdding: .day, value: -$0, to: end)!) }
        let indices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.date, $0.offset) })
        var seen = Set<String>()
        for record in records {
            guard seen.insert(record.key).inserted, let index = indices[calendar.startOfDay(for: record.date)] else { continue }
            days[index].add(record, cost: catalog.cost(record))
        }
        return LocalUsageReport(days: days, scannedBytes: bytes, files: files, skipped: skipped, priceDate: catalog.verifiedAt, generatedAt: now)
    }
}

// Only turn_context metadata and token_count events are decoded. Message/tool
// contents are neither retained nor interpreted. The cache is memory-only.
final class UsageLogCursor {
    var offset: UInt64 = 0
    var size: UInt64 = 0
    var inode: UInt64 = 0
    var modified = Date.distantPast
    var prefix = Data()
    var suffix = Data()
    var pending = Data()
    var discarding = false
    var model = "未知模型"
    var speed = "standard"
    var previous: TokenAmounts?
    var records: [TokenRecord] = []
    var skipped = 0
    let fractional = ISO8601DateFormatter()
    let plain = ISO8601DateFormatter()
    init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    func consume(_ line: Data, cutoff: Date) {
        // JSON field order is not fixed. Filter complete lines without decoding
        // conversation payloads, then validate the top-level event type below.
        guard line.range(of: Data("\"turn_context\"".utf8)) != nil || line.range(of: Data("\"token_count\"".utf8)) != nil else { return }
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let payload = root["payload"] as? [String: Any] else { skipped += 1; return }
        if root["type"] as? String == "turn_context" {
            model = payload["model"] as? String ?? "未知模型"
            speed = payload["service_tier"] as? String ?? payload["speed"] as? String ?? "standard"
            return
        }
        guard root["type"] as? String == "event_msg", payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
              let totals = info["total_token_usage"] as? [String: Any], let cumulative = TokenAmounts.parse(totals) else { return }
        let old = previous
        previous = cumulative
        if old == cumulative { return } // status-only repeats of the same usage snapshot
        let usage: TokenAmounts
        if let last = info["last_token_usage"] as? [String: Any], let parsed = TokenAmounts.parse(last) {
            usage = parsed
        } else if let old = old, cumulative.input >= old.input, cumulative.cached >= old.cached, cumulative.output >= old.output, cumulative.writes >= old.writes {
            usage = TokenAmounts(input: cumulative.input - old.input, cached: cumulative.cached - old.cached, output: cumulative.output - old.output, writes: cumulative.writes - old.writes)
        } else { skipped += 1; return } // never assign the full historical cumulative count to today
        guard usage.total > 0, let stamp = root["timestamp"] as? String,
              let date = fractional.date(from: stamp) ?? plain.date(from: stamp), date >= cutoff else { return }
        let key = "\(stamp)|\(cumulative.input)|\(cumulative.cached)|\(cumulative.output)|\(cumulative.writes)|\(usage.input)|\(usage.output)"
        records.append(TokenRecord(key: key, date: date, model: model, speed: speed, amounts: usage))
    }
    func append(_ chunk: Data, cutoff: Date) {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
            if !discarding {
                pending.append(chunk[start..<end])
                if pending.count > 4_000_000 { pending.removeAll(keepingCapacity: false); discarding = true; skipped += 1 }
            }
            if end < chunk.endIndex {
                if !discarding { consume(pending, cutoff: cutoff) }
                pending.removeAll(keepingCapacity: true); discarding = false
                start = end + 1
            } else { break }
        }
    }
}
final class UsageLogScanner {
    private var cursors: [String: UsageLogCursor] = [:]
    let root: URL
    init(root: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path).appendingPathComponent("sessions")) { self.root = root }
    func scan(catalog: PricingCatalog, now: Date = Date(), calendar: Calendar = .current) throws -> LocalUsageReport {
        let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { throw UsageFailure.message("未找到本机 Codex 会话日志。") }
        var active = Set<String>(); var bytes: Int64 = 0
        for case let url as URL in iterator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let modified = attrs[.modificationDate] as? Date ?? .distantPast
            let key = url.path; active.insert(key)
            var cursor = cursors[key] ?? UsageLogCursor()
            if cursor.size == size && cursor.modified == modified && cursor.inode == inode { continue }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let prefix = try file.read(upToCount: Int(min(256, cursor.offset == 0 ? size : cursor.offset))) ?? Data()
            var same = cursor.inode == inode && size >= cursor.offset && (cursor.offset == 0 || prefix == cursor.prefix)
            if same && cursor.offset > 0 {
                try file.seek(toOffset: cursor.offset - UInt64(cursor.suffix.count))
                same = (try file.read(upToCount: cursor.suffix.count) ?? Data()) == cursor.suffix
            }
            if !same { cursor = UsageLogCursor() }
            try file.seek(toOffset: cursor.offset)
            while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
                cursor.append(chunk, cutoff: cutoff); cursor.offset += UInt64(chunk.count); bytes += Int64(chunk.count)
            }
            try file.seek(toOffset: 0)
            cursor.prefix = try file.read(upToCount: Int(min(256, cursor.offset))) ?? Data()
            let suffixLength = min(128, cursor.offset)
            try file.seek(toOffset: cursor.offset - suffixLength)
            cursor.suffix = try file.read(upToCount: Int(suffixLength)) ?? Data()
            // Stamp from before parsing; an append during the scan forces another read next time.
            cursor.size = size; cursor.inode = inode; cursor.modified = modified
            cursor.records.removeAll { $0.date < cutoff }
            cursors[key] = cursor
        }
        cursors = cursors.filter { active.contains($0.key) }
        return LocalUsageReport.aggregate(records: cursors.values.flatMap { $0.records }, catalog: catalog, now: now, calendar: calendar, bytes: bytes, files: active.count, skipped: cursors.values.reduce(0) { $0 + $1.skipped })
    }
}
