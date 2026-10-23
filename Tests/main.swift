import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL \(message)\n", stderr); exit(1) }
    print("PASS \(message)")
}
let catalog = try PricingCatalog.load(url: URL(fileURLWithPath: CommandLine.arguments[1]))
var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let iso = ISO8601DateFormatter()
let now = iso.date(from: "2026-10-23T04:00:00Z")!
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-quota-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
func json(_ value: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
func context(_ model: String, speed: String = "standard") -> String {
    json(["type": "turn_context", "payload": ["model": model, "service_tier": speed]])
}
func event(_ stamp: String, total: TokenAmounts, last: TokenAmounts?, reasoning: Int = 0) -> String {
    func amount(_ a: TokenAmounts) -> [String: Any] { ["input_tokens": a.input, "cached_input_tokens": a.cached, "output_tokens": a.output, "cache_write_input_tokens": a.writes, "reasoning_output_tokens": reasoning, "total_tokens": a.total] }
    var info: [String: Any] = ["total_token_usage": amount(total)]
    if let last = last { info["last_token_usage"] = amount(last) }
    return json(["type": "event_msg", "timestamp": stamp, "payload": ["type": "token_count", "info": info]])
}
let small = TokenAmounts(input: 1000, cached: 600, output: 100)
let first = event("2026-10-23T01:00:00Z", total: small, last: small, reasoning: 50)
let path = root.appendingPathComponent("rollout-test.jsonl")
try (context("gpt-6.1-sol") + "\n" + first + "\n" + first + "\n").write(to: path, atomically: true, encoding: .utf8)
let scanner = UsageLogScanner(root: root)
let initial = try scanner.scan(catalog: catalog, now: now, calendar: calendar)
expect(initial.today.amounts.total == 1100 && initial.today.records == 1, "duplicate status snapshots counted once; reasoning not added twice")
expect(initial.today.amounts.cached == 600, "cached input remains a subset of input")
expect(abs(initial.today.cost - 0.00186) < 0.00000001, "cache-read discount and output rate produce $0.00186")
let unchanged = try scanner.scan(catalog: catalog, now: now, calendar: calendar)
expect(unchanged.scannedBytes == 0, "unchanged files are not reread")
// Copied fork history is counted once across files, without depending on file names.
try (context("gpt-6.1-sol") + "\n" + first + "\n").write(to: root.appendingPathComponent("rollout-fork.jsonl"), atomically: true, encoding: .utf8)
let copied = try scanner.scan(catalog: catalog, now: now, calendar: calendar)
expect(copied.today.amounts.total == 1100, "fork copies deduplicated across files")
let next = TokenAmounts(input: 2000, cached: 1000, output: 200)
let cumulative = TokenAmounts(input: 3000, cached: 1600, output: 300)
let second = context("gpt-6-astra") + "\n" + event("2026-10-23T02:00:00Z", total: cumulative, last: next)
let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd()
let data = Data(second.utf8); let midpoint = data.count / 2
try handle.write(contentsOf: data.prefix(midpoint))
let partial = try scanner.scan(catalog: catalog, now: now, calendar: calendar)
expect(partial.today.amounts.total == 1100, "partial final JSON line is not counted")
try handle.write(contentsOf: data.suffix(data.count - midpoint) + Data([10])); try handle.close()
let appended = try scanner.scan(catalog: catalog, now: now, calendar: calendar)
expect(appended.today.amounts.total == 3300 && appended.today.records == 2, "appended complete record counted exactly once")
expect(appended.today.models["gpt-6-astra"]?.amounts.total == 2200, "model switches attributed to the active turn context")
expect(appended.scannedBytes < 1000, "append scan reads only added bytes")
let yesterday = event("2026-10-22T15:59:59Z", total: small, last: small)
let todayBoundary = event("2026-10-22T16:00:01Z", total: cumulative, last: next)
let cursor = UsageLogCursor(); cursor.consume(Data(context("gpt-6.1-sol").utf8), cutoff: .distantPast)
cursor.consume(Data(yesterday.utf8), cutoff: .distantPast); cursor.consume(Data(todayBoundary.utf8), cutoff: .distantPast)
let boundary = LocalUsageReport.aggregate(records: cursor.records, catalog: catalog, now: now, calendar: calendar)
expect(boundary.yesterday.amounts.total == 1100 && boundary.today.amounts.total == 2200, "local midnight uses Asia/Shanghai instead of UTC")
let long = TokenRecord(key: "long", date: now, model: "gpt-6.1-sol", speed: "standard", amounts: TokenAmounts(input: 300000, cached: 200000, output: 1000))
expect(abs(catalog.cost(long)! - 0.455) < 0.000001, "long-context multipliers applied per request including cached input")
let fast = TokenRecord(key: "fast", date: now, model: "gpt-6.1-sol", speed: "fast", amounts: small)
expect(abs(catalog.cost(fast)! - 0.00372) < 0.000001, "fast tier multiplier applied")
let unknown = TokenRecord(key: "unknown", date: now, model: "new-unpriced-model", speed: "standard", amounts: small)
let partialCost = LocalUsageReport.aggregate(records: [unknown, long], catalog: catalog, now: now, calendar: calendar)
expect(partialCost.today.unpriced == 1 && partialCost.today.amounts.total == 302100 && partialCost.today.priced == 1, "unpriced models retained in tokens and marked partial rather than free")
let onlyUnknown = LocalUsageReport.aggregate(records: [unknown], catalog: catalog, now: now, calendar: calendar)
expect(onlyUnknown.today.costValue == nil, "unknown-only days do not fabricate $0 cost")
let reset = event("2026-10-23T03:00:00Z", total: small, last: small)
let resetCursor = UsageLogCursor()
resetCursor.consume(Data(event("2026-10-23T02:00:00Z", total: cumulative, last: next).utf8), cutoff: .distantPast)
resetCursor.consume(Data(reset.utf8), cutoff: .distantPast)
expect(resetCursor.records.count == 2 && resetCursor.records.last?.amounts.total == 1100, "counter reset does not produce negative deltas or lifetime totals")
let missingLast = UsageLogCursor()
missingLast.consume(Data(event("2026-10-23T02:00:00Z", total: cumulative, last: nil).utf8), cutoff: .distantPast)
expect(missingLast.records.isEmpty && missingLast.skipped == 1, "missing initial last-usage record does not bill the full historical total")
// Replace the whole file with a new shorter history; old cache must disappear.
try (context("gpt-6.1-sol") + "\n" + reset + "\n").write(to: path, atomically: true, encoding: .utf8)
try FileManager.default.removeItem(at: root.appendingPathComponent("rollout-fork.jsonl"))
let replacement = try scanner.scan(catalog: catalog, now: now, calendar: calendar)
expect(replacement.today.records == 1 && replacement.today.amounts.total == 1100, "truncation/replacement and deleted file evict cached records")
let invalid = TokenAmounts.parse(["input_tokens": 100, "cached_input_tokens": 200, "output_tokens": 5])
expect(invalid == nil, "invalid token counters are rejected")
let nullAccount = try JSONDecoder().decode(AccountUsage.self, from: Data(#"{"summary":{},"dailyUsageBuckets":null}"#.utf8))
expect(nullAccount.dailyUsageBuckets == nil, "missing server buckets remain unavailable")
print("All usage checks passed")
