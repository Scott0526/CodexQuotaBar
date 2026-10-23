import AppKit
import SwiftUI
import Charts
import OSLog

final class UsageStore: ObservableObject {
    private let preview: Bool
    init(preview: Bool = false) { self.preview = preview }
    @Published var local: LocalUsageReport?
    @Published var account: AccountUsage?
    @Published var accountSeries: [UsageDay] = []
    @Published var localLoading = false
    @Published var accountLoading = false
    @Published var localError: String?
    @Published var accountError: String?
    @Published var accountUpdated: Date?
    private let scanner = UsageLogScanner()
    private let queue = DispatchQueue(label: "local.codex.quota-bar.usage", qos: .utility)
    private var localAttempt: Date?
    private var accountAttempt: Date?
    func reload(force: Bool = false) {
        guard !preview else { return }
        let now = Date()
        if !localLoading && (force || localAttempt.map { now.timeIntervalSince($0) >= 30 } ?? true) {
            localAttempt = now; localLoading = true
            queue.async {
                let started = Date()
                let result = Result { try self.scanner.scan(catalog: PricingCatalog.load()) }
                DispatchQueue.main.async {
                    self.localLoading = false
                    switch result {
                    case .success(let report):
                        self.local = report; self.localError = nil
                        Logger(subsystem: "local.codex.quota-bar", category: "daily").notice("Incremental local usage scan completed in \(Date().timeIntervalSince(started), privacy: .public) seconds; read \(report.scannedBytes, privacy: .public) bytes")
                    case .failure(let error): self.localError = error.localizedDescription
                    }
                }
            }
        }
        if !accountLoading && (force || accountAttempt.map { now.timeIntervalSince($0) >= 300 } ?? true) {
            accountAttempt = now; accountLoading = true
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try QuotaReader.request("account/usage/read") as AccountUsage }
                DispatchQueue.main.async {
                    self.accountLoading = false
                    switch result {
                    case .success(let value): self.account = value; self.accountSeries = Self.makeAccountSeries(value); self.accountUpdated = Date(); self.accountError = nil
                    case .failure: self.accountError = "账号日统计暂不可用，可继续查看本机明细。"
                    }
                }
            }
        }
    }
    static func makeAccountSeries(_ account: AccountUsage) -> [UsageDay] {
        guard let buckets = account.dailyUsageBuckets, !buckets.isEmpty else { return [] }
        // The API returns date-only buckets with no timezone contract. Keep these
        // server dates distinct from the local calendar used for session logs.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        let parsed = buckets.compactMap { day -> UsageDay? in
            guard day.tokens >= 0, let date = formatter.date(from: day.startDate) else { return nil }
            var value = UsageDay(date: date); value.amounts.input = day.tokens; value.records = 1
            return value
        }.sorted { $0.date < $1.date }
        guard let end = parsed.last?.date else { return [] }
        let calendar = Calendar.current
        let byDate = Dictionary(parsed.map { ($0.date, $0) }, uniquingKeysWith: { _, new in new })
        return (0..<30).reversed().map {
            let date = calendar.date(byAdding: .day, value: -$0, to: end)!
            return byDate[date] ?? UsageDay(date: date)
        }
    }

}

enum UsageFormat {
    static func tokens(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
    static func money(_ cost: Double?) -> String {
        guard let cost = cost else { return "未计价" }
        if cost > 0 && cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
struct UsageMetric: View {
    let title: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
struct DailyUsageView: View {
    @ObservedObject var usage: UsageStore
    @State private var accountSource = false
    @State private var costMode = false
    @State private var selectedDate: Date?
    @State private var showMethod = false
    private var days: [UsageDay] { accountSource ? usage.accountSeries : usage.local?.days ?? [] }
    private var selected: UsageDay? {
        if let date = selectedDate, let found = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) { return found }
        return days.last
    }
    private var busy: Bool { accountSource ? usage.accountLoading : usage.localLoading }
    private var issue: String? { accountSource ? usage.accountError : usage.localError }
    private var periodTokens: Int64 { days.reduce(0) { $0 + $1.amounts.total } }
    private var periodCost: Double { days.reduce(0) { $0 + $1.cost } }
    private var periodCostLabel: String {
        guard days.contains(where: { $0.priced > 0 }) || !days.contains(where: { $0.records > 0 }) else { return "未计价" }
        return "\(days.contains(where: { $0.unpriced > 0 }) ? "≥" : "≈")\(UsageFormat.money(periodCost))"
    }
    private var models: [ModelUsage] { selected?.models.values.sorted { $0.amounts.total > $1.amounts.total } ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Daily Usage").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(action: { usage.reload(force: true) }) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(usage.localLoading || usage.accountLoading).help("刷新每日用量")
                }
                Picker("统计来源", selection: $accountSource) {
                    Text("本机明细与估算").tag(false)
                    Text("账号每日总量").tag(true)
                }.pickerStyle(.segmented).labelsHidden().onChange(of: accountSource) { _ in selectedDate = nil; costMode = false }
                if let issue = issue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
                    if selected != nil { Text("显示上次成功读取的数据").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if let day = selected {
                    HStack {
                        Text(day.date, format: .dateTime.month().day()).font(.system(size: 12, weight: .medium))
                        if !accountSource && Calendar.current.isDateInToday(day.date) { Text("今天").font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer()
                        Text(accountSource ? "服务端日期" : "本机 · \(TimeZone.current.abbreviation() ?? TimeZone.current.identifier)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        UsageMetric(title: "Tokens", value: UsageFormat.tokens(day.amounts.total), detail: accountSource ? "账号每日总量，可能延迟" : "输入 + 输出（含缓存与推理）")
                        if !accountSource {
                            UsageMetric(title: "API 等价估算 · USD", value: UsageFormat.money(day.costValue), detail: day.unpriced > 0 ? "\(day.unpriced) 条记录未计价 · 部分估算" : "现价折算，非订阅扣费")
                        }
                    }
                    if !accountSource {
                        HStack {
                            detail("非缓存输入", UsageFormat.tokens(day.amounts.input - day.amounts.cached))
                            Spacer()
                            detail("缓存命中", UsageFormat.tokens(day.amounts.cached))
                            Spacer()
                            detail("输出", UsageFormat.tokens(day.amounts.output))
                        }.padding(.horizontal, 3)
                    }
                    HStack {
                        Text("近 30 天").font(.system(size: 12, weight: .medium))
                        Spacer()
                        if !accountSource {
                            Picker("图表单位", selection: $costMode) { Text("Tokens").tag(false); Text("费用").tag(true) }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 115)
                        }
                        Text(costMode ? periodCostLabel : UsageFormat.tokens(periodTokens)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                    Chart(days) { item in
                        BarMark(x: .value("日期", item.date, unit: .day), y: .value(costMode ? "USD 估算" : "Tokens", costMode ? item.cost : Double(item.amounts.total)))
                            .foregroundStyle(Calendar.current.isDate(item.date, inSameDayAs: day.date) ? Color.orange : Color.orange.opacity(0.4))
                    }
                    .chartXAxis {
                        AxisMarks(values: days.enumerated().compactMap { $0.offset % 7 == 0 && $0.offset < 25 ? $0.element.date : nil }) { _ in
                            AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits)).font(.system(size: 9))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let n = value.as(Double.self) {
                                    Text(costMode ? UsageFormat.money(n) : UsageFormat.tokens(Int64(max(0, n)))).font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle().fill(Color.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    if case .active(let point) = phase { select(point, proxy: proxy, geo: geo) }
                                }
                                .gesture(DragGesture(minimumDistance: 0).onChanged { select($0.location, proxy: proxy, geo: geo) })
                        }
                    }
                    .frame(height: 140).accessibilityLabel("近三十天\(costMode ? "API 等价估算费用" : "token")柱状图；移动指针或点击查看日期明细")
                    if accountSource {
                        Text("账号图表不含模型或输入／输出拆分，不能直接用于费用计算。").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        if days.contains(where: { $0.unpriced > 0 }) && costMode {
                            Text("费用柱仅计入可计价记录；缺失信息不按 $0 估价。").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                        if !models.isEmpty {
                            Text("当日模型分布").font(.system(size: 12, weight: .medium))
                            ForEach(models.prefix(5)) { model in
                                HStack(spacing: 7) {
                                    Circle().fill(Color.orange.opacity(0.7)).frame(width: 5, height: 5)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.id).font(.system(size: 11)).lineLimit(1)
                                        GeometryReader { geometry in
                                            Capsule().fill(Color.orange.opacity(0.3)).frame(width: geometry.size.width * CGFloat(Double(model.amounts.total) / Double(max(1, day.amounts.total))))
                                        }.frame(height: 3)
                                    }
                                    Spacer()
                                    Text(UsageFormat.tokens(model.amounts.total)).font(.system(size: 11)).monospacedDigit()
                                    Text(model.priced > 0 ? "\(model.unpriced > 0 ? "≥" : "≈")\(UsageFormat.money(model.cost))" : "未计价")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(minWidth: 54, alignment: .trailing)
                                }.padding(.vertical, 3)
                            }
                        } else { Text("该日期无本机用量记录").font(.system(size: 11)).foregroundStyle(.secondary) }
                        if let skipped = usage.local?.skipped, skipped > 0 {
                            Text("有 \(skipped) 条记录缺少可用计数或无法解析，未计入汇总。").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                        Text("仅本机日志，可包含切换账号前的会话；不代表账号全部用量。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else if !busy && issue == nil {
                    Text(accountSource ? "服务端未返回每日统计。" : "暂无本机用量记录。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                } else if busy && selected == nil {
                    Text("正在读取用量，首次加载可能需要几秒…").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                DisclosureGroup("计算口径与价格") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本机按当地日期统计，重复事件去重；输入已包含缓存，输出已包含推理，不重复相加。")
                        Text("使用 \(usage.local?.priceDate ?? "2026-10-23") 的 API 价格快照，历史记录也按这份现价折算。计入单次请求长上下文倍率；未记录速度时按 Standard 估算，不含工具、区域等附加费。未知模型／速度或缓存写入记录标为未计价。")
                        Text("账号日统计来自服务端，日期口径与本机明细可能不同。")
                        Link("查看 OpenAI API 价格", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
                }.font(.system(size: 10))
            }.padding(.trailing, 5)
        }.frame(height: 520)
            .onAppear { usage.reload() }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).foregroundStyle(.secondary); Text(value).monospacedDigit() }.font(.system(size: 10))
    }
    private func select(_ point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        let x = point.x - geo[proxy.plotAreaFrame].origin.x
        guard x >= 0, x <= proxy.plotAreaSize.width, let date: Date = proxy.value(atX: x),
              days.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else { return }
        let day = Calendar.current.startOfDay(for: date)
        if selectedDate != day { selectedDate = day }
    }
}
