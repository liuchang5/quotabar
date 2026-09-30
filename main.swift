// QuotaBar — 跨云厂商 AI Coding Plan / Agent / API 额度菜单栏监控
// v6：多套餐切换（学 Claude Bar 的 Claude/Codex 标签）+ 设置窗口（可配置认证与凭据，可分享）
// 数据源：① arkcli usage plan（本机登录态，Coding Plan / Agent Plan 均支持）
//         ② AK/SK 直查 GetAFPUsage OpenAPI（Agent Plan 个人版，可给别人用）
// 模型价格·三榜单图表保留 v5.3 逻辑
import AppKit
import Foundation
import CryptoKit

// MARK: - 配置模型

struct PlanConfig: Codable {
    var id: String
    var name: String          // 显示名（如「方舟CodingPlan」）
    var product: String       // "coding-plan" | "agent-plan"
    var authMode: String      // "arkcli" | "aksk"
    var ak: String
    var sk: String
    var note: String
}

struct AppConfig: Codable {
    var plans: [PlanConfig]
    var activePlanID: String
    var refreshInterval: TimeInterval

    static func `default`() -> AppConfig {
        AppConfig(
            plans: [
                PlanConfig(id: UUID().uuidString, name: "方舟CodingPlan", product: "coding-plan", authMode: "arkcli", ak: "", sk: "", note: "Coding Plan 个人版（本机 arkcli 登录）"),
                PlanConfig(id: UUID().uuidString, name: "方舟AgentPlan", product: "agent-plan", authMode: "arkcli", ak: "", sk: "", note: "Agent Plan 个人版（本机 arkcli 登录）")
            ],
            activePlanID: "",
            refreshInterval: 600
        )
    }
}

final class ConfigStore {
    static let shared = ConfigStore()
    let fileURL: URL
    var config: AppConfig

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: fileURL),
           let c = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = c
        } else {
            config = AppConfig.default()
            config.activePlanID = config.plans.first?.id ?? ""
            save()
        }
        if config.plans.first(where: { $0.id == config.activePlanID }) == nil {
            config.activePlanID = config.plans.first?.id ?? ""
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func activePlan() -> PlanConfig? {
        config.plans.first(where: { $0.id == config.activePlanID })
    }
}

// MARK: - 数据模型

struct PlanPeriod {
    var label: String       // 5h / daily / weekly / monthly
    var percent: Double
    var used: Double
    var total: Double
    var resetAt: String
}

struct PlanSnapshot {
    var product: String
    var planName: String
    var tier: String
    var periods: [PlanPeriod]
    var error: String?
}

// MARK: - arkcli 查询

let arkcliPath = "/opt/homebrew/bin/arkcli"

func runCLI(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: arkcliPath)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["ARKCLI_NO_UPDATE_NOTIFIER"] = "1"
    p.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return nil
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: outData, encoding: .utf8)
}

func fetchViaArkcli(_ cfg: PlanConfig) -> PlanSnapshot {
    let product = cfg.product
    guard let out = runCLI(["usage", "plan", "--product", product, "--format", "json"]),
          let data = out.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["items"] as? [[String: Any]],
          let first = items.first else {
        return PlanSnapshot(product: product, planName: cfg.name, tier: "", periods: [], error: "arkcli 查询失败，请确认本机已登录（arkcli auth login）")
    }
    let subscribed = (first["subscribed"] as? Bool) ?? false
    let tier = first["tier"] as? String ?? ""
    guard subscribed, let periods = first["periods"] as? [[String: Any]] else {
        return PlanSnapshot(product: product, planName: cfg.name, tier: tier, periods: [], error: "未订阅该套餐或暂无限额数据")
    }
    var result: [PlanPeriod] = []
    for p in periods {
        guard let label = p["label"] as? String else { continue }
        let used = (p["used"] as? NSNumber)?.doubleValue ?? 0
        let total = (p["total"] as? NSNumber)?.doubleValue ?? 0
        let percent = (p["percent"] as? NSNumber)?.doubleValue ?? (total > 0 ? used / total * 100 : 0)
        let reset = p["reset_at"] as? String ?? ""
        result.append(PlanPeriod(label: label, percent: percent, used: used, total: total, resetAt: reset))
    }
    return PlanSnapshot(product: product, planName: cfg.name, tier: tier, periods: result, error: nil)
}

// MARK: - 火山引擎 OpenAPI 签名（HMAC-SHA256，AK/SK）

enum VolcSigner {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func sha256Hex(_ s: String) -> String {
        sha256Hex(Data(s.utf8))
    }
    static func hmacData(_ key: Data, _ msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }
    static func hmacHex(_ key: Data, _ msg: String) -> String {
        hmacData(key, Data(msg.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 生成火山引擎 OpenAPI 的 Authorization 签名头
    static func authorization(ak: String, sk: String, method: String, path: String,
                              query: [String: String], headers: [String: String],
                              body: Data, region: String = "cn-beijing", service: String = "ark",
                              xDate: String) -> String {
        let shortDate = String(xDate.prefix(8))
        let bodyHash = sha256Hex(body)

        // Canonical Query（按 key 字母序，RFC3986 编码）
        let canonQuery = query.keys.sorted().map { k -> String in
            let v = query[k] ?? ""
            return "\(urlEncode(k))=\(urlEncode(v))"
        }.joined(separator: "&")

        // Canonical Headers（host;x-content-sha256;x-date）
        let host = headers["Host"] ?? ""
        let canonHeaders = "host:\(host)\nx-content-sha256:\(bodyHash)\nx-date:\(xDate)\n"
        let signedHeaders = "host;x-content-sha256;x-date"

        let canonicalRequest = "\(method)\n\(path)\n\(canonQuery)\n\(canonHeaders)\n\(signedHeaders)\n\(bodyHash)"
        let stringToSign = "HMAC-SHA256\n\(xDate)\n\(shortDate)\n\(sha256Hex(canonicalRequest))"

        let kDate = hmacData(Data(sk.utf8), Data(shortDate.utf8))
        let kRegion = hmacData(kDate, Data(region.utf8))
        let kService = hmacData(kRegion, Data(service.utf8))
        let kSigning = hmacData(kService, Data("request".utf8))
        let signature = hmacData(kSigning, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        return "HMAC-SHA256 Credential=\(ak)/\(shortDate)/\(region)/\(service)/request, SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func xDateNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: Date())
    }
}

// MARK: - AK/SK 直查 GetAFPUsage（Agent Plan 个人版）

func fetchViaAKSK(_ cfg: PlanConfig) -> PlanSnapshot {
    guard cfg.product == "agent-plan", !cfg.ak.isEmpty, !cfg.sk.isEmpty else {
        return PlanSnapshot(product: cfg.product, planName: cfg.name, tier: "", periods: [], error: "Agent Plan AK/SK 查询需要填写 AK 与 SK")
    }
    let host = "ark.cn-beijing.volcengineapi.com"
    let path = "/"
    let query = ["Action": "GetAFPUsage", "Version": "2024-01-01"]
    let body = Data("{}".utf8)
    let xDate = VolcSigner.xDateNow()
    var headers: [String: String] = [
        "Host": host,
        "Content-Type": "application/json; charset=UTF-8",
        "X-Content-Sha256": VolcSigner.sha256Hex(body),
        "X-Date": xDate
    ]
    headers["Authorization"] = VolcSigner.authorization(
        ak: cfg.ak, sk: cfg.sk, method: "POST", path: path,
        query: query, headers: headers, body: body, xDate: xDate)

    let urlStr = "https://\(host)\(path)?\(VolcSigner.urlEncode("Action"))=GetAFPUsage&\(VolcSigner.urlEncode("Version"))=2024-01-01"
    guard let url = URL(string: urlStr) else {
        return PlanSnapshot(product: cfg.product, planName: cfg.name, tier: "", periods: [], error: "URL 构造失败")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = body
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let semaphore = DispatchSemaphore(value: 0)
    var respData: Data?
    var respErr: String?
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err {
            respErr = err.localizedDescription
        } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            respErr = "HTTP \(http.statusCode): \(String(data: data ?? Data(), encoding: .utf8) ?? "")"
        } else {
            respData = data
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()

    guard let data = respData,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = json["Result"] as? [String: Any] else {
        return PlanSnapshot(product: cfg.product, planName: cfg.name, tier: "", periods: [], error: respErr ?? "返回解析失败（请检查 AK/SK 与套餐订阅）")
    }

    let tier = result["PlanType"] as? String ?? ""
    var periods: [PlanPeriod] = []
    let map: [(String, String)] = [("AFPFiveHour", "5h"), ("AFPDaily", "daily"), ("AFPWeekly", "weekly"), ("AFPMonthly", "monthly")]
    for (key, label) in map {
        guard let w = result[key] as? [String: Any] else { continue }
        let quota = (w["Quota"] as? NSNumber)?.doubleValue ?? 0
        let used = (w["Used"] as? NSNumber)?.doubleValue ?? 0
        let resetMs = (w["ResetTime"] as? NSNumber)?.doubleValue ?? 0
        let percent = quota > 0 ? used / quota * 100 : 0
        let resetStr = resetMs > 0 ? formatMillis(resetMs) : ""
        periods.append(PlanPeriod(label: label, percent: percent, used: used, total: quota, resetAt: resetStr))
    }
    return PlanSnapshot(product: cfg.product, planName: cfg.name, tier: tier, periods: periods, error: nil)
}

func formatMillis(_ ms: Double) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000)
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: d)
}

// MARK: - 统一查询入口

func fetchPlan(_ cfg: PlanConfig) -> PlanSnapshot {
    if cfg.authMode == "aksk" && cfg.product == "agent-plan" {
        return fetchViaAKSK(cfg)
    }
    return fetchViaArkcli(cfg)
}

// MARK: - 模型价格（保留 v5.3：官方 API 标价 + 三榜单）

struct ModelPrice {
    let name: String
    let input: Double?
    let output: Double?
    let cache: Double?
    let kind: String
    let note: String
    let elo: Int?
    let livebench: Double?
    let sweV: Double?
    let benchmark: String?
}

let modelPrices: [ModelPrice] = [
    ModelPrice(name: "claude-opus-5-5", input: 4.00, output: 20.00, cache: 0.20, kind: "图片+文本", note: "Anthropic 旗舰", elo: 1551, livebench: 89.3, sweV: 96.0, benchmark: nil),
    ModelPrice(name: "claude-fable-5-1", input: 10.00, output: 50.00, cache: 0.25, kind: "图片+文本", note: "Anthropic 长程旗舰", elo: 1551, livebench: 86.4, sweV: 95.0, benchmark: nil),
    ModelPrice(name: "gpt-6-astra", input: 10.00, output: 50.00, cache: 1.00, kind: "图片+文本", note: "OpenAI 旗舰", elo: 1542, livebench: nil, sweV: nil, benchmark: nil),
    ModelPrice(name: "kimi-k3", input: 3.00, output: 15.00, cache: 0.30, kind: "图片+文本", note: "Kimi 旗舰 / 1M", elo: 1541, livebench: 81.5, sweV: 93.4, benchmark: nil),
    ModelPrice(name: "claude-opus-4.8", input: 5.00, output: 25.00, cache: 0.50, kind: "图片+文本", note: "Anthropic 经典旗舰 · 编程基准", elo: 1534, livebench: 81.8, sweV: 88.6, benchmark: "编程基准"),
    ModelPrice(name: "glm-5.3", input: 1.13, output: 3.94, cache: 0.28, kind: "纯文本", note: "¥8 / ¥28", elo: nil, livebench: 79.0, sweV: 95.4, benchmark: nil),
    ModelPrice(name: "deepseek-v4.1-flash", input: 0.15, output: 0.60, cache: 0.003, kind: "图片+文本", note: "峰谷 ¥1~2 / ¥4~8 · TB2.1 90.6", elo: nil, livebench: 80.0, sweV: nil, benchmark: nil),
    ModelPrice(name: "deepseek-v4-pro", input: 0.66, output: 1.98, cache: 0.022, kind: "纯文本", note: "峰谷 ¥4.5~9 / ¥13.5~27", elo: nil, livebench: 77.2, sweV: 80.6, benchmark: nil),
    ModelPrice(name: "kimi-k2.7-code", input: 0.95, output: 4.00, cache: 0.19, kind: "图片+文本", note: "官方 $0.95 / $4.0 · K2.6 SWE-V 80.2", elo: nil, livebench: 74.0, sweV: nil, benchmark: nil),
    ModelPrice(name: "glm-5.3-flash", input: 0.11, output: 0.39, cache: 0.03, kind: "图片+文本", note: "¥0.8 / ¥2.8 原生多模态", elo: nil, livebench: nil, sweV: 92.0, benchmark: nil),
    ModelPrice(name: "claude-sonnet-4.6", input: 3.00, output: 15.00, cache: 0.30, kind: "图片+文本", note: "Anthropic 经典中坚 · 日常基准", elo: 1529, livebench: 79.3, sweV: 79.6, benchmark: "日常基准"),
    ModelPrice(name: "minimax-m3", input: 0.30, output: 1.20, cache: 0.06, kind: "图片+文本", note: "≤512k 五折后", elo: nil, livebench: 68.2, sweV: 80.5, benchmark: nil),
    ModelPrice(name: "doubao-seed-2.1-pro", input: 0.85, output: 4.23, cache: 0.17, kind: "图+视频+文本", note: "¥6 / ¥30 · SWE-V 76.5（2.0 系）", elo: nil, livebench: nil, sweV: 76.5, benchmark: nil),
    ModelPrice(name: "doubao-seed-evolving", input: 0.85, output: 4.23, cache: 0.17, kind: "图+视频+文本", note: "¥6 / ¥30 周级滚动", elo: nil, livebench: nil, sweV: nil, benchmark: nil),
    ModelPrice(name: "doubao-seed-2.0-mini", input: 0.11, output: 1.13, cache: 0.02, kind: "图+视频+音频+文本", note: "¥0.2~0.8 / ¥2~8 · LCB v6 64.1", elo: nil, livebench: nil, sweV: nil, benchmark: nil),
    ModelPrice(name: "doubao-seed-2.1-lite", input: nil, output: nil, cache: nil, kind: "三模态", note: "价格见方舟官网", elo: nil, livebench: nil, sweV: nil, benchmark: nil)
]

enum SortMode: Int, CaseIterable {
    case ability, elo, livebench, sweV, output, input
    var label: String {
        switch self {
        case .ability: return "综合编码能力（默认）"
        case .elo:     return "LMArena ELO（高→低）"
        case .livebench: return "LiveBench Coding（高→低）"
        case .sweV:    return "SWE-bench Verified（高→低）"
        case .output:  return "输出价格（高→低）"
        case .input:   return "输入价格（高→低）"
        }
    }
}

final class PriceChartView: NSView {
    private let rows: [ModelPrice]
    var sortMode: SortMode = .ability { didSet { needsDisplay = true } }
    private let rowH: CGFloat = 38
    private let headH: CGFloat = 36
    private let legendH: CGFloat = 64
    private let nameW: CGFloat = 150
    private let plotX: CGFloat = 160
    private let plotW: CGFloat = 186
    private let valX: CGFloat = 398
    private let badgeX: CGFloat = 408
    private let badgeW: CGFloat = 96
    private let arenaX: CGFloat = 518
    private let colW: CGFloat = 126
    private let maxOut: Double = 50.0

    init(models: [ModelPrice]) {
        self.rows = models
        let h = headH + CGFloat(models.count) * rowH + legendH
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: h))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private func logScale(_ v: Double) -> CGFloat {
        let t = log2(1 + v) / log2(1 + maxOut)
        return CGFloat(min(max(t, 0), 1))
    }
    private func makeRanks(_ values: [(idx: Int, v: Double)]) -> [Int: Int] {
        let sorted = values.sorted { $0.v > $1.v }
        var result: [Int: Int] = [:]
        var rank = 0
        var last: Double?
        for (i, item) in sorted.enumerated() {
            if last != item.v { rank = i + 1; last = item.v }
            result[item.idx] = rank
        }
        return result
    }
    private func sortedRows() -> [ModelPrice] {
        let n = rows.count
        let idxs = Array(0..<n)
        let order: [Int]
        switch sortMode {
        case .ability: order = idxs
        case .elo:
            order = idxs.sorted { a, b in
                let (x, y) = (rows[a].elo, rows[b].elo)
                switch (x, y) {
                case (let p?, let q?): return p == q ? a < b : p > q
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        case .livebench:
            order = idxs.sorted { a, b in
                let (x, y) = (rows[a].livebench, rows[b].livebench)
                switch (x, y) {
                case (let p?, let q?): return p == q ? a < b : p > q
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        case .sweV:
            order = idxs.sorted { a, b in
                let (x, y) = (rows[a].sweV, rows[b].sweV)
                switch (x, y) {
                case (let p?, let q?): return p == q ? a < b : p > q
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        case .output:
            order = idxs.sorted { a, b in
                let (x, y) = (rows[a].output ?? -1, rows[b].output ?? -1)
                return x == y ? a < b : x > y
            }
        case .input:
            order = idxs.sorted { a, b in
                let (x, y) = (rows[a].input ?? -1, rows[b].input ?? -1)
                return x == y ? a < b : x > y
            }
        }
        return order.map { rows[$0] }
    }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let rows = sortedRows()

        let headTitle = "官方 API 标价（$/1M）· 蓝=输入 橙=输出 · 对数刻度 · 已按「\(sortMode.label)」排序" as NSString
        headTitle.draw(at: NSPoint(x: 12, y: 8), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 10.5), .foregroundColor: NSColor.labelColor
        ])
        let cols: [(String, String, NSColor)] = [
            ("LMArena ELO", "2026-09-25 · 180万票", NSColor.systemIndigo),
            ("LiveBench", "Coding · 2026-09", NSColor.systemTeal),
            ("SWE-bench V", "2026-09 · Vals/llm-stats", NSColor.systemGreen)
        ]
        for (i, c) in cols.enumerated() {
            let x = arenaX + CGFloat(i) * colW
            (c.0 as NSString).draw(at: NSPoint(x: x, y: 6), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: c.2
            ])
            (c.1 as NSString).draw(at: NSPoint(x: x, y: 21), withAttributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor
            ])
        }

        let ticks: [Double] = [0.5, 1, 2, 4, 8, 16, 32]
        let axisY = headH + 12
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        for v in ticks {
            let x = plotX + logScale(v) * plotW
            ctx.move(to: CGPoint(x: x, y: axisY))
            ctx.addLine(to: CGPoint(x: x, y: axisY + CGFloat(rows.count) * rowH))
            ctx.strokePath()
            let labelText = v < 1 ? String(format: "$%.1f", v) : String(format: "$%.0f", v)
            (labelText as NSString).draw(at: NSPoint(x: x - 12, y: axisY - 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor
            ])
        }

        var eloEntries: [(idx: Int, v: Double)] = []
        var lbEntries: [(idx: Int, v: Double)] = []
        var sweEntries: [(idx: Int, v: Double)] = []
        for (i, m) in rows.enumerated() {
            if let e = m.elo { eloEntries.append((i, Double(e))) }
            if let l = m.livebench { lbEntries.append((i, l)) }
            if let s = m.sweV { sweEntries.append((i, s)) }
        }
        let rankMaps: [[Int: Int]] = [makeRanks(eloEntries), makeRanks(lbEntries), makeRanks(sweEntries)]

        for (i, m) in rows.enumerated() {
            let y = headH + CGFloat(i) * rowH
            var nameColor = NSColor.labelColor
            var nameWeight: NSFont.Weight = .medium
            if let bench = m.benchmark {
                let bc = bench == "编程基准" ? NSColor.systemPurple : NSColor.systemBlue
                bc.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: y + 2, width: 896, height: rowH - 4), xRadius: 6, yRadius: 6).fill()
                bc.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: NSRect(x: 12, y: y + 9, width: 40, height: 14), xRadius: 7, yRadius: 7).fill()
                (bench as NSString).draw(at: NSPoint(x: 16, y: y + 11), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: bc
                ])
                nameColor = bc
                nameWeight = .bold
            }
            let nameX: CGFloat = m.benchmark == nil ? 12 : 60
            (m.name as NSString).draw(at: NSPoint(x: nameX, y: y + 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: nameWeight), .foregroundColor: nameColor
            ])
            (m.note as NSString).draw(at: NSPoint(x: 12, y: y + 24), withAttributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor
            ])
            if let out = m.output {
                let wOut = logScale(out) * plotW
                NSColor.systemOrange.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: plotX, y: y + 4, width: max(wOut, 3), height: 9), xRadius: 2, yRadius: 2).fill()
            }
            if let inp = m.input {
                let wIn = logScale(inp) * plotW
                NSColor.systemBlue.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: NSRect(x: plotX, y: y + 16, width: max(wIn, 3), height: 9), xRadius: 2, yRadius: 2).fill()
            }
            if let out = m.output {
                let outText = String(format: "$%.2f", out) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.systemOrange
                ]
                outText.draw(at: NSPoint(x: valX - outText.size(withAttributes: attrs).width, y: y + 3), withAttributes: attrs)
            }
            if let inp = m.input {
                let inText = String(format: "$%.3g", inp) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.systemBlue
                ]
                inText.draw(at: NSPoint(x: valX - inText.size(withAttributes: attrs).width, y: y + 15), withAttributes: attrs)
            }
            let badgeRect = NSRect(x: badgeX, y: y + 8, width: badgeW - 4, height: 17)
            let isMulti = m.kind != "纯文本"
            let badgeColor = isMulti ? NSColor.systemPink : NSColor.systemGray
            badgeColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 8.5, yRadius: 8.5).fill()
            badgeColor.setStroke()
            ctx.setLineWidth(0.8)
            NSBezierPath(roundedRect: badgeRect, xRadius: 8.5, yRadius: 8.5).stroke()
            let badgeText = m.kind as NSString
            let battrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: badgeColor
            ]
            let bsz = badgeText.size(withAttributes: battrs)
            badgeText.draw(at: NSPoint(x: badgeRect.midX - bsz.width / 2, y: badgeRect.minY + 4), withAttributes: battrs)
            let scores: [(Double?, NSColor)] = [
                (m.elo.map { Double($0) }, NSColor.systemIndigo),
                (m.livebench, NSColor.systemTeal),
                (m.sweV, NSColor.systemGreen)
            ]
            for (si, s) in scores.enumerated() {
                let x = arenaX + CGFloat(si) * colW + 2
                if let v = s.0 {
                    let isElo = si == 0
                    let alpha: CGFloat = isElo ? 0.25 : 0.18
                    s.1.withAlphaComponent(alpha).setFill()
                    let cellRect = NSRect(x: x, y: y + 7, width: colW - 14, height: 16)
                    NSBezierPath(roundedRect: cellRect, xRadius: 4, yRadius: 4).fill()
                    let txt = isElo ? String(format: "%.0f", v) : String(format: "%.1f", v)
                    let full = NSMutableAttributedString()
                    full.append(NSAttributedString(string: txt, attributes: [
                        .font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: s.1
                    ]))
                    if let rank = rankMaps[si][i] {
                        full.append(NSAttributedString(string: "  #\(rank)", attributes: [
                            .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: s.1.withAlphaComponent(0.72)
                        ]))
                    }
                    full.draw(at: NSPoint(x: x + 7, y: y + 9))
                } else {
                    let dash = "--" as NSString
                    dash.draw(at: NSPoint(x: x + 7, y: y + 9), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.quaternaryLabelColor
                    ])
                }
            }
        }

        let legendY = headH + CGFloat(rows.count) * rowH + 10
        let leg1 = "🖼 粉色徽标=多模态（可识图）· 灰色=纯文本 · 紫底=编程基准（Opus 4.8）· 蓝底=日常基准（Sonnet 4.6）· 三榜单统一标准对比：紫=LMArena ELO 青=LiveBench Coding 绿=SWE-bench Verified · 分数后的 #N = 本图 16 款模型内、该榜有分模型的相对名次（同分并列）" as NSString
        leg1.draw(at: NSPoint(x: 12, y: legendY), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.secondaryLabelColor
        ])
        let leg2 = "价格为厂商官方 API 标价（非套餐抵扣系数）；人民币按 7.1 折算；DeepSeek 为峰谷定价空闲档；三榜单均为统一 harness 对比、覆盖国产模型；GLM-5.3-Flash 的 SWE-V 92.0 为 Vals max 推理档；数据核验于 2026-09" as NSString
        leg2.draw(at: NSPoint(x: 12, y: legendY + 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.tertiaryLabelColor
        ])
    }
}

// MARK: - 设置窗口

final class SettingsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var panel: NSPanel!
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let nameField = NSTextField()
    private let productPopup = NSPopUpButton()
    private let authPopup = NSPopUpButton()
    private let akField = NSTextField()
    private let skField = NSSecureTextField()
    private let noteField = NSTextField()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    var onSave: (() -> Void)?
    private var editingID: String?

    func show() {
        if panel == nil {
            buildPanel()
        }
        panel.center()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        panel.title = "QuotaBar 设置"
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.level = .floating
        panel.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        panel.contentView = container

        // 左：套餐列表
        let cols: [NSTableColumn] = [
            { let c = NSTableColumn(identifier: .init("name")); c.title = "名称"; c.width = 130; return c }(),
            { let c = NSTableColumn(identifier: .init("product")); c.title = "套餐"; c.width = 90; return c }(),
            { let c = NSTableColumn(identifier: .init("auth")); c.title = "认证"; c.width = 90; return c }()
        ]
        for c in cols { tableView.addTableColumn(c) }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // 右上标题
        let formTitle = NSTextField(labelWithString: "套餐配置（填写后保存）")
        formTitle.font = NSFont.boldSystemFont(ofSize: 12)
        formTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(formTitle)

        // 表单字段
        func makeField(_ label: String, _ field: NSTextField, placeholder: String) -> NSTextField {
            let l = NSTextField(labelWithString: label)
            l.font = NSFont.systemFont(ofSize: 11)
            l.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(l)
            field.placeholderString = placeholder
            field.font = NSFont.systemFont(ofSize: 11)
            field.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(field)
            return l
        }
        let lName = makeField("显示名称", nameField, placeholder: "如：我的Agent Plan")
        let lProduct = NSTextField(labelWithString: "套餐类型")
        lProduct.font = NSFont.systemFont(ofSize: 11)
        lProduct.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lProduct)
        productPopup.addItems(withTitles: ["Coding Plan 个人版", "Agent Plan 个人版"])
        productPopup.font = NSFont.systemFont(ofSize: 11)
        productPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(productPopup)

        let lAuth = NSTextField(labelWithString: "认证方式")
        lAuth.font = NSFont.systemFont(ofSize: 11)
        lAuth.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lAuth)
        authPopup.addItems(withTitles: ["arkcli 本机登录（推荐）", "AK·SK 直查 OpenAPI"])
        authPopup.font = NSFont.systemFont(ofSize: 11)
        authPopup.translatesAutoresizingMaskIntoConstraints = false
        authPopup.target = self
        authPopup.action = #selector(authChanged)
        container.addSubview(authPopup)

        let lAk = makeField("Access Key（AK）", akField, placeholder: "控制台 → 访问控制 → 访问密钥")
        let lSk = makeField("Secret Key（SK）", skField, placeholder: "仅本机保存，用于查询额度")
        let lNote = makeField("备注", noteField, placeholder: "可选，如：企业账号 / 个人")

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = NSColor.secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hintLabel)
        updateHint()

        // 按钮
        let addBtn = NSButton(title: "＋ 添加套餐", target: self, action: #selector(addPlan))
        addBtn.font = NSFont.systemFont(ofSize: 11)
        addBtn.bezelStyle = .rounded
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addBtn)
        let delBtn = NSButton(title: "－ 删除所选", target: self, action: #selector(delPlan))
        delBtn.font = NSFont.systemFont(ofSize: 11)
        delBtn.bezelStyle = .rounded
        delBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(delBtn)
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(saveBtn)
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeBtn.font = NSFont.systemFont(ofSize: 11)
        closeBtn.bezelStyle = .rounded
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scrollView.widthAnchor.constraint(equalToConstant: 330),
            scrollView.heightAnchor.constraint(equalToConstant: 420),

            formTitle.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: 24),
            formTitle.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),

            lName.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            lName.topAnchor.constraint(equalTo: formTitle.bottomAnchor, constant: 14),
            nameField.leadingAnchor.constraint(equalTo: lName.trailingAnchor, constant: 10),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            nameField.centerYAnchor.constraint(equalTo: lName.centerYAnchor),

            lProduct.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            lProduct.topAnchor.constraint(equalTo: lName.bottomAnchor, constant: 14),
            productPopup.leadingAnchor.constraint(equalTo: lProduct.trailingAnchor, constant: 10),
            productPopup.widthAnchor.constraint(equalToConstant: 170),
            productPopup.centerYAnchor.constraint(equalTo: lProduct.centerYAnchor),

            lAuth.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            lAuth.topAnchor.constraint(equalTo: lProduct.bottomAnchor, constant: 14),
            authPopup.leadingAnchor.constraint(equalTo: lAuth.trailingAnchor, constant: 10),
            authPopup.widthAnchor.constraint(equalToConstant: 190),
            authPopup.centerYAnchor.constraint(equalTo: lAuth.centerYAnchor),

            lAk.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            lAk.topAnchor.constraint(equalTo: lAuth.bottomAnchor, constant: 14),
            akField.leadingAnchor.constraint(equalTo: lAk.trailingAnchor, constant: 10),
            akField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            akField.centerYAnchor.constraint(equalTo: lAk.centerYAnchor),

            lSk.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            lSk.topAnchor.constraint(equalTo: lAk.bottomAnchor, constant: 14),
            skField.leadingAnchor.constraint(equalTo: lSk.trailingAnchor, constant: 10),
            skField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            skField.centerYAnchor.constraint(equalTo: lSk.centerYAnchor),

            lNote.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            lNote.topAnchor.constraint(equalTo: lSk.bottomAnchor, constant: 14),
            noteField.leadingAnchor.constraint(equalTo: lNote.trailingAnchor, constant: 10),
            noteField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            noteField.centerYAnchor.constraint(equalTo: lNote.centerYAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: lNote.bottomAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            addBtn.leadingAnchor.constraint(equalTo: formTitle.leadingAnchor),
            addBtn.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 18),
            delBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 10),
            delBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),

            saveBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            saveBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            closeBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -10),
            closeBtn.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor)
        ])

        tableView.reloadData()
        if tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadForm(at: 0)
        }
    }

    @objc private func authChanged() {
        updateHint()
        let enabled = authPopup.indexOfSelectedItem == 1
        akField.isEnabled = enabled
        skField.isEnabled = enabled
    }

    private func updateHint() {
        let isAksk = authPopup.indexOfSelectedItem == 1
        hintLabel.stringValue = isAksk
            ? "AK/SK 直查模式：支持 Agent Plan 个人版（GetAFPUsage）。AK/SK 在「火山引擎控制台 → 访问控制 → 访问密钥」创建；ark- API Key 只能调用模型、不能查额度。Coding Plan 个人版暂未开放公开查询 API，请选 arkcli 模式。"
            : "arkcli 模式：使用本机 arkcli 登录态查询（Coding Plan / Agent Plan 均可）。分享给他人使用时，对方需自行登录 arkcli 或改用 AK/SK 模式。"
    }

    private func loadForm(at row: Int) {
        let plans = ConfigStore.shared.config.plans
        guard plans.indices.contains(row) else { return }
        let p = plans[row]
        editingID = p.id
        nameField.stringValue = p.name
        productPopup.selectItem(at: p.product == "agent-plan" ? 1 : 0)
        authPopup.selectItem(at: p.authMode == "aksk" ? 1 : 0)
        akField.stringValue = p.ak
        skField.stringValue = p.sk
        noteField.stringValue = p.note
        authChanged()
    }

    private func writeForm() {
        guard let id = editingID,
              let idx = ConfigStore.shared.config.plans.firstIndex(where: { $0.id == id }) else { return }
        var p = ConfigStore.shared.config.plans[idx]
        p.name = nameField.stringValue.isEmpty ? p.name : nameField.stringValue
        p.product = productPopup.indexOfSelectedItem == 1 ? "agent-plan" : "coding-plan"
        p.authMode = authPopup.indexOfSelectedItem == 1 ? "aksk" : "arkcli"
        p.ak = akField.stringValue
        p.sk = skField.stringValue
        p.note = noteField.stringValue
        ConfigStore.shared.config.plans[idx] = p
    }

    @objc private func addPlan() {
        let newPlan = PlanConfig(id: UUID().uuidString, name: "新套餐", product: "agent-plan", authMode: "arkcli", ak: "", sk: "", note: "")
        ConfigStore.shared.config.plans.append(newPlan)
        tableView.reloadData()
        let row = ConfigStore.shared.config.plans.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        loadForm(at: row)
    }

    @objc private func delPlan() {
        guard let id = editingID,
              let idx = ConfigStore.shared.config.plans.firstIndex(where: { $0.id == id }) else { return }
        ConfigStore.shared.config.plans.remove(at: idx)
        if ConfigStore.shared.config.activePlanID == id {
            ConfigStore.shared.config.activePlanID = ConfigStore.shared.config.plans.first?.id ?? ""
        }
        editingID = nil
        tableView.reloadData()
        if tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadForm(at: 0)
        } else {
            nameField.stringValue = ""; akField.stringValue = ""; skField.stringValue = ""; noteField.stringValue = ""
        }
    }

    @objc private func save() {
        writeForm()
        ConfigStore.shared.save()
        tableView.reloadData()
        onSave?()
        panel.close()
    }

    @objc private func closePanel() {
        panel.close()
    }

    // MARK: NSTableViewDataSource / Delegate
    func numberOfRows(in tableView: NSTableView) -> Int {
        ConfigStore.shared.config.plans.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let plans = ConfigStore.shared.config.plans
        guard plans.indices.contains(row) else { return nil }
        let p = plans[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "name": text = p.name
        case "product": text = p.product == "agent-plan" ? "Agent" : "Coding"
        case "auth": text = p.authMode == "aksk" ? "AK/SK" : "arkcli"
        default: text = ""
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.font = NSFont.systemFont(ofSize: 11)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 { loadForm(at: row) }
    }
    func windowWillClose(_ notification: Notification) {
        // 未保存的编辑丢弃（重新载入）
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var snapshots: [String: PlanSnapshot] = [:]
    private var lastRefreshText = "尚未刷新"
    private var pricePanel: NSPanel?
    private var settings: SettingsWindowController?
    private var priceChartView: PriceChartView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        refreshNow()
        let interval = ConfigStore.shared.config.refreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarText()
        rebuildMenu()
    }

    // MARK: 信号条（颜色随消耗档位，参考 Claude Bar 风格）

    private func statusColor(_ pct: Double) -> NSColor {
        if pct >= 90 { return NSColor.systemRed }
        if pct >= 75 { return NSColor.systemOrange }
        if pct >= 50 { return NSColor.systemYellow }
        return NSColor.systemGreen
    }

    private func signalIcon(percent: Double, failed: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        let ctx = NSGraphicsContext.current!.cgContext
        let color = failed ? NSColor.systemGray : statusColor(percent)
        let bars: [(x: CGFloat, h: CGFloat)] = [(1, 5), (6, 9), (11, 13)]
        for b in bars {
            let rect = NSRect(x: b.x, y: 15 - b.h, width: 3, height: b.h)
            color.setFill()
            ctx.fill(rect)
        }
        return img
    }

    private func activeSnapshot() -> PlanSnapshot? {
        guard let ap = ConfigStore.shared.activePlan() else { return nil }
        return snapshots[ap.id]
    }

    private func updateMenuBarText() {
        guard let button = statusItem.button else { return }
        let snap = activeSnapshot()
        let ap = ConfigStore.shared.activePlan()
        let failed = snap?.error != nil || snap == nil

        var pct: Double = -1
        if !failed, let s = snap {
            let h5 = s.periods.first(where: { $0.label == "5h" || $0.label == "session" })
            let wk = s.periods.first(where: { $0.label == "weekly" })
            if let h = h5, let w = wk {
                pct = h.percent >= w.percent ? h.percent : w.percent
            } else if let h = h5 { pct = h.percent }
            else if let w = wk { pct = w.percent }
        }

        button.image = signalIcon(percent: pct >= 0 ? pct : 0, failed: failed || pct < 0)

        if pct < 0 {
            button.attributedTitle = NSAttributedString(string: " CP --%", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.systemGray
            ])
            button.toolTip = "\(ap?.name ?? "套餐") 数据获取失败，点击菜单查看详情"
            return
        }

        let s = snap!
        let h5 = s.periods.first(where: { $0.label == "5h" || $0.label == "session" })
        let wk = s.periods.first(where: { $0.label == "weekly" })
        let color = statusColor(pct)
        var title: String
        var tip: String
        if let h = h5, let w = wk {
            if h.percent >= w.percent {
                title = " 5H \(String(format: "%.1f%%", h.percent))"
                tip = "\(ap?.name ?? "") 近5小时用量 \(String(format: "%.2f%%", h.percent))"
            } else {
                title = " W \(String(format: "%.1f%%", w.percent))"
                tip = "\(ap?.name ?? "") 近一周用量 \(String(format: "%.2f%%", w.percent))"
            }
        } else if let h = h5 {
            title = " 5H \(String(format: "%.1f%%", h.percent))"
            tip = "\(ap?.name ?? "") 近5小时用量 \(String(format: "%.2f%%", h.percent))"
        } else if let w = wk {
            title = " W \(String(format: "%.1f%%", w.percent))"
            tip = "\(ap?.name ?? "") 近一周用量 \(String(format: "%.2f%%", w.percent))"
        } else {
            title = " CP --%"
            tip = "\(ap?.name ?? "") 额度监控"
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color
        ])
        button.toolTip = tip
    }

    // MARK: 数据获取

    func refreshNow() {
        let plans = ConfigStore.shared.config.plans
        guard !plans.isEmpty else {
            rebuildMenu()
            return
        }
        let group = DispatchGroup()
        var results: [String: PlanSnapshot] = [:]
        for plan in plans {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let snap = fetchPlan(plan)
                DispatchQueue.main.async {
                    results[plan.id] = snap
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.snapshots = results
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            self.lastRefreshText = formatter.string(from: Date())
            self.updateMenuBarText()
            self.rebuildMenu()
        }
    }

    // MARK: 菜单

    private func rebuildMenu() {
        let menu = NSMenu()
        let ap = ConfigStore.shared.activePlan()
        let titleItem = NSMenuItem(title: "QuotaBar · \(ap?.name ?? "未配置")", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // 套餐切换（学 ClaudeBar 的套餐标签）
        let switchHeader = NSMenuItem(title: "切换套餐（点击激活）", action: nil, keyEquivalent: "")
        switchHeader.isEnabled = false
        menu.addItem(switchHeader)
        for plan in ConfigStore.shared.config.plans {
            let item = NSMenuItem(title: plan.name, action: #selector(switchPlan(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = plan.id
            item.state = plan.id == ConfigStore.shared.config.activePlanID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 当前套餐额度窗口
        let header = NSMenuItem(title: "额度窗口（已用百分比）· \(ap?.name ?? "")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let snap = snapshots[ConfigStore.shared.config.activePlanID] {
            if let err = snap.error {
                let e = NSMenuItem(title: "⚠ \(err)", action: nil, keyEquivalent: "")
                e.isEnabled = false
                menu.addItem(e)
            } else if snap.periods.isEmpty {
                let e = NSMenuItem(title: "暂无额度数据（请检查认证/订阅）", action: nil, keyEquivalent: "")
                e.isEnabled = false
                menu.addItem(e)
            } else {
                for p in snap.periods {
                    let name = periodLabel(p.label)
                    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    let attr = NSMutableAttributedString()
                    attr.append(NSAttributedString(
                        string: "\(name)：\(String(format: "%.2f%%", p.percent))",
                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]))
                    if !p.resetAt.isEmpty {
                        attr.append(NSAttributedString(
                            string: " · \(friendlyReset(p.resetAt))",
                            attributes: [
                                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]))
                    }
                    attr.append(NSAttributedString(string: "  "))
                    attr.append(progressBarAttr(p.percent))
                    item.attributedTitle = attr
                    menu.addItem(item)
                }
            }
        } else {
            let e = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }

        menu.addItem(.separator())

        let chartItem = NSMenuItem(title: "📊 模型价格·类型·三榜单（官方价）", action: #selector(priceChartClicked), keyEquivalent: "p")
        chartItem.target = self
        menu.addItem(chartItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…（套餐与密钥）", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refresh = NSMenuItem(title: "立即刷新（\(lastRefreshText) 更新）", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "退出 QuotaBar", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func periodLabel(_ label: String) -> String {
        switch label {
        case "5h", "session": return "近5小时"
        case "daily": return "近一天"
        case "weekly": return "近一周"
        case "monthly": return "近一月"
        default: return label
        }
    }

    // 重置时间人性化：今天/明天/「M月d日 HH:mm」，不显示时区（默认当前时区）
    private func friendlyReset(_ raw: String) -> String {
        guard let d = parseResetDate(raw) else { return raw }
        let cal = Calendar.current
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        if cal.isDateInToday(d) { return "今天 \(hm.string(from: d)) 重置" }
        if cal.isDateInTomorrow(d) { return "明天 \(hm.string(from: d)) 重置" }
        let md = DateFormatter()
        md.dateFormat = "M月d日 HH:mm"
        return "\(md.string(from: d)) 重置"
    }

    private func parseResetDate(_ raw: String) -> Date? {
        // arkcli: ISO8601 带时区；AK/SK: yyyy-MM-dd HH:mm:ss（本地）
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: raw)
    }

    // 档位颜色：与菜单栏信号条一致（<50% 绿 / 50–75% 黄 / 75–90% 橙 / ≥90% 红）
    private func tierColor(_ percent: Double) -> NSColor {
        if percent >= 90 { return NSColor.systemRed }
        if percent >= 75 { return NSColor.systemOrange }
        if percent >= 50 { return NSColor.systemYellow }
        return NSColor.systemGreen
    }

    // 10 格进度条：已用格子用档位色，剩余格子浅灰
    private func progressBarAttr(_ percent: Double) -> NSAttributedString {
        let filled = max(0, min(10, Int((percent / 10).rounded())))
        let color = tierColor(percent)
        let gray = NSColor.tertiaryLabelColor
        let s = NSMutableAttributedString()
        for i in 0..<10 {
            let c = i < filled ? color : gray
            s.append(NSAttributedString(string: "▰", attributes: [
                .foregroundColor: c,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            ]))
        }
        return s
    }

    @objc private func switchPlan(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ConfigStore.shared.config.activePlanID = id
        ConfigStore.shared.save()
        updateMenuBarText()
        rebuildMenu()
    }

    @objc private func settingsClicked() {
        if settings == nil {
            let s = SettingsWindowController()
            s.onSave = { [weak self] in
                self?.refreshNow()
            }
            settings = s
        }
        settings?.show()
    }

    @objc private func priceChartClicked() {
        if let panel = pricePanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        panel.title = "模型官方价格与类型"
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.level = .floating

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        container.autoresizingMask = [.width, .height]

        let chart = PriceChartView(models: modelPrices)
        priceChartView = chart

        let popup = NSPopUpButton(frame: NSRect(x: 16, y: 604, width: 240, height: 26))
        popup.addItems(withTitles: SortMode.allCases.map { $0.label })
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = #selector(sortChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(popup)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scroll.documentView = chart
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            popup.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            popup.widthAnchor.constraint(equalToConstant: 240),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 8)
        ])

        panel.contentView = container
        panel.setContentSize(NSSize(width: 900, height: 640))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pricePanel = panel
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        let mode = SortMode(rawValue: sender.indexOfSelectedItem) ?? .ability
        priceChartView?.sortMode = mode
    }

    @objc private func refreshClicked() {
        refreshNow()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
