import AppKit
import SwiftUI
import ServiceManagement
import Darwin
import CoreText
import OSLog

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var barColor: NSColor {
        if remaining >= 70 { return .systemGreen }
        if remaining >= 20 { return .systemOrange }
        return .systemRed
    }
    var label: String {
        guard let m = windowDurationMins else { return "—" }
        if m % 1440 == 0 { return "\(m / 1440)d" }
        if m % 60 == 0 { return "\(m / 60)h" }
        return "\(m)m"
    }
    var resetDescription: String {
        guard let t = resetsAt else { return "重置时间暂不可用" }
        let date = Date(timeIntervalSince1970: t)
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        let seconds = t - Date().timeIntervalSince1970
        if seconds <= 0 { return "等待服务端更新 · \(f.string(from: date))" }
        let mins = max(1, Int(ceil(seconds / 60)))
        let relative = mins >= 1440 ? "\(mins / 1440)天 \((mins % 1440) / 60)小时" : (mins >= 60 ? "\(mins / 60)小时 \(mins % 60)分钟" : "\(mins)分钟")
        return "\(relative)后重置 · \(f.string(from: date))"
    }
}
struct Bucket: Decodable { let primary: QuotaWindow?; let secondary: QuotaWindow?; let planType: String?; let limitId: String? }
struct Limits: Decodable {
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?
    var codex: Bucket? {
        if let value = rateLimitsByLimitId?["codex"] { return value }
        return rateLimits.limitId == nil || rateLimits.limitId == "codex" ? rateLimits : nil
    }
}
enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

// Use the documented local app-server protocol. No credential files are read or copied.
final class QuotaReader {
    static func executable() -> String? {
        let bundled = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return (bundled + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func read() throws -> Bucket {
        guard let cli = executable() else { throw QuotaError.message("未找到 Codex CLI，请先安装或打开 Codex / ChatGPT。") }
        let p = Process(); let input = Pipe(); let output = Pipe()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["app-server", "--listen", "stdio://"]
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        // Do not inherit per-turn API keys or alternate Codex homes from an agent environment.
        var env = ProcessInfo.processInfo.environment
        for k in ["OPENAI_API_KEY", "OPENAI_ACCESS_TOKEN", "CODEX_HOME", "CODEX_API_KEY"] { env.removeValue(forKey: k) }
        p.environment = env
        try p.run()
        let deadline = DispatchWorkItem {
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
            // Reap the child; force exit if a CLI version ignores SIGTERM.
            let killer = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: killer)
            p.waitUntilExit(); killer.cancel()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_quota_bar", "title": "Codex Quota Bar", "version": "1.0.0"]]])
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw QuotaError.message("读取额度连接失败，稍后会自动重试。")
            }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.count > 2_000_000 { throw QuotaError.message("额度响应过大，请更新 Codex CLI。") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                if let err = message["error"] as? [String: Any] {
                    let code = err["code"] as? Int ?? 0
                    throw QuotaError.message("额度读取失败（\(code)）。请确认 Codex 已用 ChatGPT 账号登录后重试。")
                }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] {
                    let limits = try JSONDecoder().decode(Limits.self, from: JSONSerialization.data(withJSONObject: result))
                    guard let bucket = limits.codex, bucket.primary != nil || bucket.secondary != nil else {
                        throw QuotaError.message("该账号暂未返回 Codex 额度。请确认使用 ChatGPT 账号登录。")
                    }
                    return bucket
                }
            }
        }
        throw QuotaError.message("额度读取超时或连接中断，稍后会自动重试。")
    }
}

final class QuotaStore: ObservableObject {
    @Published var bucket: Bucket?
    @Published var updated: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var showUsed = UserDefaults.standard.bool(forKey: "showUsed") {
        didSet { UserDefaults.standard.set(showUsed, forKey: "showUsed"); changed?() }
    }
    @Published var login = SMAppService.mainApp.status == .enabled
    var changed: (() -> Void)?
    private var timer: Timer?
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc func wake() { refresh() }
    func refresh() {
        guard !loading else { return }
        loading = true; changed?()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try QuotaReader.read() }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let bucket):
                    self.bucket = bucket; self.updated = Date(); self.error = nil
                    Logger(subsystem: "local.codex.quota-bar", category: "refresh").notice("Quota refresh succeeded")
                case .failure(let error):
                    self.error = error.localizedDescription
                    Logger(subsystem: "local.codex.quota-bar", category: "refresh").error("Quota refresh failed; will retry")
                }
                self.changed?()
            }
        }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            login = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func value(_ w: QuotaWindow) -> Double { showUsed ? max(0, min(100, w.usedPercent)) : w.remaining }
}

// Render eagerly into a bitmap. AppKit receives a finished image, so status-item
// replication never calls our text drawing code inside an NSView snapshot.
final class QuotaStatusRenderer {
    let store: QuotaStore
    private let textGap: CGFloat = 8
    private let barStart: CGFloat = 28
    private let segmentPitch: CGFloat = 7
    private let segmentWidth: CGFloat = 4.5
    private let rightInset: CGFloat = 4
    private let font = CTFontCreateWithName("Menlo-Bold" as CFString, 9, nil)
    private var barEnd: CGFloat { barStart + 4 * segmentPitch + segmentWidth }
    private var rows: [(QuotaWindow?, String)] { [(store.bucket?.primary, "5h"), (store.bucket?.secondary, "7d")] }
    init(store: QuotaStore) { self.store = store }
    private func percentageText(for window: QuotaWindow?) -> String {
        guard let window = window else { return "—" }
        return "\(Int(store.value(window).rounded()))%\(store.error == nil ? "" : "·")"
    }
    private func line(_ text: String, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    private func width(_ text: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, color: CGColor(gray: 0, alpha: 1)), nil, nil, nil))
    }
    var renderKey: String {
        rows.map { "\($0.0?.label ?? $0.1)|\($0.0?.usedPercent.description ?? "nil")|\(percentageText(for: $0.0))" }.joined(separator: ";")
    }
    var contentWidth: CGFloat {
        ceil(barEnd + textGap + (rows.map { width(percentageText(for: $0.0)) }.max() ?? 0) + rightInset)
    }
    func image(height: CGFloat, foreground: NSColor, scale: CGFloat = 2) -> NSImage? {
        let size = NSSize(width: contentWidth, height: max(22, height))
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        let textColor = foreground.cgColor
        let rowHeight: CGFloat = 10
        let base = (size.height - 2 * rowHeight) / 2
        func drawText(_ text: String, x: CGFloat, y: CGFloat) {
            let textLine = line(text, color: textColor)
            var ascent: CGFloat = 0; var descent: CGFloat = 0
            CTLineGetTypographicBounds(textLine, &ascent, &descent, nil)
            context.textPosition = CGPoint(x: x, y: y + (rowHeight - ascent - descent) / 2 + descent)
            CTLineDraw(textLine, context)
        }
        for (i, row) in rows.enumerated() {
            let y = base + CGFloat(1 - i) * rowHeight
            let label = row.0?.label ?? row.1
            drawText(label, x: barStart - textGap - width(label), y: y)
            let fill = row.0.map { store.value($0) / 100 } ?? 0
            let color = store.error != nil ? NSColor.systemGray : (row.0?.barColor ?? .systemGray)
            for j in 0..<5 {
                let rect = CGRect(x: barStart + CGFloat(j) * segmentPitch, y: y + 1.5, width: segmentWidth, height: 7)
                let path = CGPath(roundedRect: rect, cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)
                context.setFillColor(textColor.copy(alpha: 0.16) ?? textColor)
                context.addPath(path); context.fillPath()
                let fraction = max(0, min(1, fill * 5 - Double(j)))
                if fraction > 0 {
                    context.saveGState()
                    context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height))
                    context.setFillColor(color.cgColor); context.addPath(path); context.fillPath()
                    context.restoreGState()
                }
            }
            drawText(percentageText(for: row.0), x: barEnd + textGap, y: y)
        }
        guard let bitmap = context.makeImage() else { return nil }
        let image = NSImage(cgImage: bitmap, size: size)
        image.isTemplate = false
        return image
    }
}

struct QuotaCard: View {
    let window: QuotaWindow?
    let fallback: String
    @ObservedObject var store: QuotaStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.map { $0.label == "5h" ? "5 小时额度" : ($0.label == "7d" ? "7 天额度" : "\($0.label)额度") } ?? fallback).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(window.map { "\(Int(store.value($0).rounded()))%" } ?? "—").font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color(nsColor: window?.barColor ?? .systemGray))
                        .frame(width: geo.size.width * CGFloat(window.map { store.value($0) / 100 } ?? 0))
                }
            }.frame(height: 7)
            Text(window?.resetDescription ?? "等待额度数据").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(14).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
struct QuotaPopover: View {
    @ObservedObject var store: QuotaStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20, weight: .medium)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 额度").font(.system(size: 17, weight: .semibold))
                    Text("ChatGPT \(store.bucket?.planType?.capitalized ?? "账号")").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                else { Circle().fill(store.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6) }
            }
            Picker("百分比", selection: $store.showUsed) {
                Text("剩余额度").tag(false)
                Text("已用额度").tag(true)
            }.pickerStyle(.segmented)
            VStack(spacing: 10) {
                QuotaCard(window: store.bucket?.primary, fallback: "5 小时额度", store: store)
                QuotaCard(window: store.bucket?.secondary, fallback: "7 天额度", store: store)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if store.bucket != nil { Text("以上为上次成功读取的数据").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            HStack {
                Text(store.updated.map { "\($0.formatted(date: .omitted, time: .shortened)) 更新 · 每分钟刷新" } ?? "正在连接 Codex…").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(action: { store.refresh() }) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(store.loading).help("立即刷新")
            }
            Divider()
            HStack {
                Toggle("登录时启动", isOn: Binding(get: { store.login }, set: { _ in store.toggleLogin() })).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("当前 ChatGPT 账号的 Codex 配额").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(18).frame(width: 330)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = QuotaStore()
    var item: NSStatusItem!
    var renderer: QuotaStatusRenderer!
    private var appearanceObservation: NSKeyValueObservation?
    private var lastImageKey: String?
    private var imageUpdateScheduled = false
    let popover = NSPopover()
    var wakeObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch should not add a duplicate status item.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codex.quota-bar").count > 1 { NSApp.terminate(nil); return }
        renderer = QuotaStatusRenderer(store: store)
        item = NSStatusBar.system.statusItem(withLength: renderer.contentWidth)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self; button.action = #selector(toggle)
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.old, .new]) { [weak self] _, change in
                // AppKit can notify while applying an image even when the theme
                // has not changed. Do not turn that notification into another draw.
                guard change.oldValue?.name != change.newValue?.name else { return }
                self?.scheduleImageUpdate()
            }
        }
        popover.behavior = .transient; popover.animates = true; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: QuotaPopover(store: store))
        store.changed = { [weak self] in self?.update() }
        store.start()
    }
    func scheduleImageUpdate() {
        guard !imageUpdateScheduled else { return }
        imageUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.imageUpdateScheduled = false
            self?.updateImage()
        }
    }
    func updateImage() {
        guard let button = item?.button else { return }
        let appearance = button.effectiveAppearance
        let height = button.bounds.height
        let scale = button.window?.backingScaleFactor ?? 2
        let key = "\(renderer.renderKey)|\(appearance.name.rawValue)|\(height)|\(scale)"
        // Check before entering the appearance context or assigning an image:
        // both operations can themselves cause effectiveAppearance notifications.
        guard key != lastImageKey else { return }
        lastImageKey = key
        appearance.performAsCurrentDrawingAppearance {
            if let image = renderer.image(height: height, foreground: .labelColor, scale: scale) {
                if item.length != image.size.width { item.length = image.size.width }
                button.image = image
                Logger(subsystem: "local.codex.quota-bar", category: "render").notice("Status image rendered after content or appearance change")
            } else {
                lastImageKey = nil
            }
        }
    }
    func update() {
        updateImage()
        let values = [store.bucket?.primary, store.bucket?.secondary].compactMap { $0 }.map { "\($0.label) \(store.showUsed ? "已用" : "剩余") \(Int(store.value($0).rounded()))%" }.joined(separator: "，")
        let text = "Codex · \(values.isEmpty ? "正在读取额度" : values)\(store.error == nil ? "" : " · 更新失败")"
        item.button?.toolTip = text
        item.button?.setAccessibilityLabel(text)
        if store.updated != nil && !UserDefaults.standard.bool(forKey: "didShowIntroduction") {
            UserDefaults.standard.set(true, forKey: "didShowIntroduction")
            toggle()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { toggle() }
        return false
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            store.login = SMAppService.mainApp.status == .enabled
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if store.error != nil || (store.updated.map { Date().timeIntervalSince($0) > 60 } ?? true) { store.refresh() }
        }
    }

}

if let index = CommandLine.arguments.firstIndex(of: "--render-check"), CommandLine.arguments.count > index + 1 {
    _ = NSApplication.shared
    let store = QuotaStore()
    let renderer = QuotaStatusRenderer(store: store)
    var smallest: CGFloat = .greatestFiniteMagnitude
    var largest: CGFloat = 0
    for i in 0..<2000 {
        store.bucket = Bucket(primary: QuotaWindow(usedPercent: Double(i % 101), windowDurationMins: 300, resetsAt: nil), secondary: QuotaWindow(usedPercent: Double((i + 31) % 101), windowDurationMins: 10080, resetsAt: nil), planType: "plus", limitId: "codex")
        store.error = i % 13 == 0 ? "test unavailable" : nil
        guard let image = renderer.image(height: 24, foreground: i % 2 == 0 ? .black : .white) else { fatalError("Bitmap rendering failed") }
        smallest = min(smallest, image.size.width); largest = max(largest, image.size.width)
    }
    store.error = nil
    store.bucket = Bucket(primary: QuotaWindow(usedPercent: 34, windowDurationMins: 300, resetsAt: nil), secondary: QuotaWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: nil), planType: "plus", limitId: "codex")
    let image = renderer.image(height: 24, foreground: .white, scale: 4)!
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    print("PASS 2000 bitmap renders; dynamic width \(smallest)…\(largest) pt; no custom status view")
    exit(0)
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--probe") {
    do {
        let b = try QuotaReader.read()
        for w in [b.primary, b.secondary].compactMap({ $0 }) { print("\(w.label): remaining=\(Int(w.remaining.rounded()))% used=\(Int(w.usedPercent.rounded()))% reset=\(w.resetsAt ?? 0)") }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--self-test") {
    func check(_ ok: @autoclosure () -> Bool, _ label: String) { if !ok() { fatalError(label) }; print("PASS \(label)") }
    let sample = #"{"rateLimits":{"limitId":"codex_other","primary":null,"secondary":null,"planType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":null},"secondary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":1730947200},"planType":"plus"}}}"#
    let b = try JSONDecoder().decode(Limits.self, from: Data(sample.utf8)).codex!
    check(b.primary!.remaining == 72, "used percentage is converted to remaining")
    check(b.secondary!.label == "7d", "weekly window comes from duration")
    check(b.primary!.resetDescription == "重置时间暂不可用", "missing reset is not invented")
    check(QuotaWindow(usedPercent: 120, windowDurationMins: nil, resetsAt: nil).remaining == 0, "clamp exhausted quota")
    check(QuotaWindow(usedPercent: -20, windowDurationMins: 60, resetsAt: nil).remaining == 100, "clamp negative usage")
    let other = try JSONDecoder().decode(Limits.self, from: Data(#"{"rateLimits":{"limitId":"other","primary":null,"secondary":null,"planType":null}}"#.utf8))
    check(other.codex == nil, "never display another model bucket as Codex")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
