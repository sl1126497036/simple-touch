// SimpleTouch — 妙控鼠标多指手势引擎
//
// 用 MultitouchSupport 直接读取触摸帧，在鼠标按下时回看一小段历史来判定手指数，
// 避免 BetterTouchTool 的 tap 判定在妙控鼠标上把单击误判成三指。
//
// 配置文件：~/.config/simple-touch/config.json（首次运行自动生成）
//
// 子命令：
//   SimpleTouch                 正常运行（常驻监听）
//   SimpleTouch --dry-run       观察模式，只打印判定，不拦截事件
//   SimpleTouch --do=<动作>     执行一次动作后退出
//   SimpleTouch --windows       打印当前窗口列表（诊断）
//   SimpleTouch --help          帮助

import Foundation
import CoreGraphics
import AppKit

// MARK: - MultitouchSupport 私有框架绑定

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float = 0
    var y: Float = 0
}

private struct MTReadout {
    var pos = MTPoint()
    var vel = MTPoint()
}

/// MultitouchSupport 上报的单个触点。
///
/// 布局来自反向工程的公开定义（steike.com，被多个开源项目沿用）：
/// ```
/// int frame; double timestamp;
/// int identifier, state, foo3, foo4;
/// mtReadout normalized;        // pos.x pos.y vel.x vel.y
/// float size; int zero1;
/// float angle, majorAxis, minorAxis;
/// mtReadout mm; int zero2; float unk2;
/// ```
/// 位置在 normalized.pos，不在结构体开头。
/// 早先把 x/y 放在开头，实际读到的是 frame 和 timestamp 的字节，
/// 位移、方向、量程全部建立在错位数据上，这是之前所有滑动问题的根源。
private struct MTFinger {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var foo3: Int32 = 0
    var foo4: Int32 = 0
    var normalized = MTReadout()
    var size: Float = 0
    var zero1: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var mm = MTReadout()
    var zero2: Int32 = 0
    var unk2: Float = 0
}

private typealias ContactCallback = @convention(c) (
    Int32, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

private typealias CreateListFn = @convention(c) () -> CFArray?
private typealias RegisterFn = @convention(c) (MTDeviceRef, ContactCallback?) -> Void
private typealias StartStopFn = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias DeviceStopFn = @convention(c) (MTDeviceRef) -> Void

// MARK: - 配置

// MARK: - 手势与动作

/// 一个动作。kind 决定 value 的语义：
///   preset       预置动作（apps / screenshot / missioncontrol / appexpose / showdesktop / spotlight / none）
///   openApp      bundle id 或 .app 路径
///   url          任意 URL
///   keyShortcut  键名 + modifiers（control / option / command / shift / fn）
///   shell        由 /bin/sh -c 执行
struct ActionSpec {
    var kind: String = "preset"
    var value: String = "none"
    var modifiers: [String] = []

    static func preset(_ name: String) -> ActionSpec {
        ActionSpec(kind: "preset", value: name, modifiers: [])
    }

    /// 界面上显示的一行摘要
    var summary: String {
        switch kind {
        case "preset": return PresetActions.title(value)
        case "openApp": return "打开 \(value)"
        case "url": return "打开链接 \(value)"
        case "keyShortcut":
            let m = modifiers.map { KeyMap.modifierSymbol($0) }.joined()
            return "按键 \(m)\(value)"
        case "shell": return "命令 \(value)"
        default: return value
        }
    }
}

/// 一条绑定自己的识别参数：点按用回看窗口，滑动用位移阈值。
/// 新建绑定时从全局 tuning 复制默认值。
struct BindingParams {
    var windowMs: Double = 300        // 点按：回看窗口
    var cooldownMs: Double = 450      // 触发冷却
    /// 滑动：连续移动距离阈值（满量程比例）。实测三指在鼠标上可滑动
    /// 的距离有限，通常只有满量程 5%~12%，阈值必须按这个量级设。
    var threshold: Double = 0.03
    var maxDurationMs: Double = 2500  // 滑动：最长时长（慢速滑动也要放行）
    var invert: Bool = false          // 滑动：上下方向反转

    init() {}

    init(from tuning: TuningConfig) {
        windowMs = tuning.tapWindowMs
        cooldownMs = tuning.cooldownMs
        threshold = tuning.swipeThreshold
        maxDurationMs = tuning.swipeMaxDurationMs
        invert = tuning.swipeInvert
    }
}

/// 一条“手势 → 动作”绑定。手势由手指数和类型唯一确定。
struct GestureBinding {
    var fingers: Int = 3
    var gesture: String = "tap"
    var action: ActionSpec = .preset("none")
    var params = BindingParams()

    var gestureTitle: String { GestureType.title(gesture) }
    var isTap: Bool { gesture == "tap" }
    /// 轻触：手指快速碰一下表面就离开，不按下
    var isTouch: Bool { gesture == "touch" }

    /// 同一个手势用同一个键做冷却
    var key: String { "\(fingers)-\(gesture)" }
}

enum GestureType {
    static let all = ["tap", "touch", "swipeUp", "swipeDown", "swipeLeft", "swipeRight"]

    static func title(_ key: String) -> String {
        switch key {
        case "tap": return "点按"
        case "touch": return "轻触"
        case "swipeUp": return "上滑"
        case "swipeDown": return "下滑"
        case "swipeLeft": return "左滑"
        case "swipeRight": return "右滑"
        default: return key
        }
    }
}

struct TuningConfig {
    /// 判定点按手指数时回看的时间窗。机械按压会让触摸层丢掉几帧，
    /// 窗口太短就会把多指点按判成单指。
    var tapWindowMs: Double = 300
    var cooldownMs: Double = 450
    var swipeThreshold: Double = 0.03
    var swipeMaxDurationMs: Double = 2500
    var swipeInvert: Bool = false
    /// 手指数容错：允许实测比绑定多一根手指也算命中，取值 0 或 1。
    /// 默认 0。设为 1 会让三指动作命中二指绑定，只在识别确实不稳定时才用。
    var fingerTolerance: Int = 0
    /// 边缘防误触：距离鼠标边缘这个比例范围内的触点直接忽略。
    /// 手掌、指腹侧面蹭到鼠标边缘产生的触点不再计入。
    var edgeMargin: Double = 0
    var debug: Bool = false
}

struct AppConfig {
    var bindings: [GestureBinding] = []
    var tuning = TuningConfig()

    /// 点按绑定：回看窗口大的先试，避免小窗口先匹配本应属于大窗口的多指
    var tapBindings: [GestureBinding] {
        bindings.filter { $0.isTap }.sorted { $0.params.windowMs > $1.params.windowMs }
    }

    var swipeBindings: [GestureBinding] {
        bindings.filter { !$0.isTap }
    }

    /// 查某个手势对应的绑定。多指识别偶尔会多报一根手指，所以从实际手指数逐级退到 3 指查找。
    func binding(fingers: Int, gesture: String) -> GestureBinding? {
        var n = fingers
        while n >= 3 {
            if let hit = bindings.first(where: { $0.fingers == n && $0.gesture == gesture }) {
                return hit
            }
            n -= 1
        }
        return nil
    }
}

enum ConfigStore {
    static var directory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/simple-touch"
    }

    static var path: String { "\(directory)/config.json" }

    static let defaultJSON = """
    {
      "bindings": [
        { "fingers": 3, "gesture": "tap",       "action": { "kind": "preset", "value": "apps" } },
        { "fingers": 3, "gesture": "swipeUp",   "action": { "kind": "preset", "value": "missioncontrol" } },
        { "fingers": 3, "gesture": "swipeDown", "action": { "kind": "preset", "value": "showdesktop" } },
        { "fingers": 4, "gesture": "tap",       "action": { "kind": "preset", "value": "screenshot" } }
      ],
      "tuning": {
        "tapWindowMs": 300,
        "cooldownMs": 450,
        "swipeThreshold": 0.03,
        "swipeMaxDurationMs": 2500,
        "swipeInvert": false,
        "fingerTolerance": 0,
        "edgeMargin": 0,
        "debug": false
      }
    }

    """

    static func load() -> AppConfig {
        var cfg = AppConfig()

        var raw = FileManager.default.contents(atPath: path)
        if raw == nil {
            write(defaultJSON)
            Log.info("[配置] 已生成默认文件：\(path)")
            raw = defaultJSON.data(using: .utf8)
        }

        guard let data = raw,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return cfg
        }

        // 先读全局 tuning：它给每条绑定的参数提供默认值
        if let t = root["tuning"] as? [String: Any] {
            if let v = t["tapWindowMs"] as? Double { cfg.tuning.tapWindowMs = v }
            if let v = t["cooldownMs"] as? Double { cfg.tuning.cooldownMs = v }
            if let v = t["swipeThreshold"] as? Double { cfg.tuning.swipeThreshold = v }
            if let v = t["swipeMaxDurationMs"] as? Double { cfg.tuning.swipeMaxDurationMs = v }
            if let v = t["swipeInvert"] as? Bool { cfg.tuning.swipeInvert = v }
            if let v = t["fingerTolerance"] as? Int { cfg.tuning.fingerTolerance = v }
            if let v = t["edgeMargin"] as? Double { cfg.tuning.edgeMargin = v }
            if let v = t["debug"] as? Bool { cfg.tuning.debug = v }
        }

        if let list = root["bindings"] as? [[String: Any]] {
            for item in list {
                let fingers = item["fingers"] as? Int ?? 3
                let gesture = item["gesture"] as? String ?? "tap"
                guard let action = parseAction(item["action"]) else { continue }
                cfg.bindings.append(GestureBinding(fingers: fingers,
                                                   gesture: gesture,
                                                   action: action,
                                                   params: parseParams(item["params"], fallback: cfg.tuning)))
            }
        } else if let g = root["gestures"] as? [String: Any] {
            // 旧版固定字段迁移为绑定表
            let legacy = [("tap3", 3, "tap"), ("tap4", 4, "tap"),
                          ("swipe3Up", 3, "swipeUp"), ("swipe3Down", 3, "swipeDown")]
            for (key, fingers, gesture) in legacy {
                guard let v = g[key] as? String, v != "none" else { continue }
                cfg.bindings.append(GestureBinding(fingers: fingers,
                                                   gesture: gesture,
                                                   action: .preset(v),
                                                   params: BindingParams(from: cfg.tuning)))
            }
            Log.info("[配置] 已从旧格式迁移")
        }

        return cfg
    }

    /// 每条绑定的识别参数，缺省时用全局 tuning
    static func parseParams(_ raw: Any?, fallback: TuningConfig) -> BindingParams {
        var p = BindingParams(from: fallback)
        guard let d = raw as? [String: Any] else { return p }
        if let v = d["windowMs"] as? Double { p.windowMs = v }
        if let v = d["cooldownMs"] as? Double { p.cooldownMs = v }
        if let v = d["threshold"] as? Double { p.threshold = v }
        if let v = d["maxDurationMs"] as? Double { p.maxDurationMs = v }
        if let v = d["invert"] as? Bool { p.invert = v }
        return p
    }

    static func parseAction(_ raw: Any?) -> ActionSpec? {
        if let s = raw as? String { return .preset(s) }
        guard let d = raw as? [String: Any] else { return nil }
        return ActionSpec(
            kind: d["kind"] as? String ?? "preset",
            value: d["value"] as? String ?? "",
            modifiers: d["modifiers"] as? [String] ?? []
        )
    }

    /// 把配置写回文件（设置界面保存时用），保持缩进可读
    static func serialize(_ cfg: AppConfig) -> String {
        var rows: [String] = []
        for b in cfg.bindings {
            let mods = b.action.modifiers.map { quote($0) }.joined(separator: ", ")
            let p = b.params
            rows.append("    { \"fingers\": \(b.fingers), \"gesture\": \(quote(b.gesture)), "
                        + "\"action\": { \"kind\": \(quote(b.action.kind)), "
                        + "\"value\": \(quote(b.action.value)), \"modifiers\": [\(mods)] },\n"
                        + "      \"params\": { \"windowMs\": \(Int(p.windowMs)), "
                        + "\"cooldownMs\": \(Int(p.cooldownMs)), "
                        + "\"threshold\": \(String(format: "%.2f", p.threshold)), "
                        + "\"maxDurationMs\": \(Int(p.maxDurationMs)), "
                        + "\"invert\": \(p.invert) } }")
        }

        let t = cfg.tuning
        return """
        {
          "bindings": [
        \(rows.joined(separator: ",\n"))
          ],
          "tuning": {
            "tapWindowMs": \(Int(t.tapWindowMs)),
            "cooldownMs": \(Int(t.cooldownMs)),
            "swipeThreshold": \(String(format: "%.2f", t.swipeThreshold)),
            "swipeMaxDurationMs": \(Int(t.swipeMaxDurationMs)),
            "swipeInvert": \(t.swipeInvert),
            "fingerTolerance": \(t.fingerTolerance),
            "edgeMargin": \(String(format: "%.2f", t.edgeMargin)),
            "debug": \(t.debug)
          }
        }

        """
    }

    /// JSON 字符串转义
    static func quote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              var text = String(data: data, encoding: .utf8) else { return "\"\"" }
        text.removeFirst()          // [
        text.removeLast()           // ]
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func write(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 触摸过滤

/// 触摸帧在回调线程里过滤，参数由 Engine 在主线程写入、回调线程只读，用简单静态量传递
enum TouchFilter {
    static var edgeMargin: Double = 0
    /// 触点坐标不做量程换算，直接用归一化值（实测为 0~1）
    static let scaleX: Double = 1
    static let scaleY: Double = 1
    static var scaleDetected = false
}

// MARK: - 触摸帧缓冲

final class TouchBuffer {
    static let shared = TouchBuffer()

    private struct Frame {
        let t: Double
        let n: Int
    }

    private var frames: [Frame] = []
    /// 当前正在进行的触摸段（手指落下 → 全部抬起）
    private var currentSegment: [Int] = []
    private let lock = NSLock()
    private let capacity = 512

    var tuning = TuningConfig()

    /// 最近一次“多指确实在移动”的时间点。
    ///
    /// 注意这里记的不是“有多指”，而是“多指在动”。妙控鼠标在正常握持时
    /// 触摸层会长期上报 2~3 个触点（手掌、指腹贴着），如果出现多指就拦截滚动，
    /// 滚轮会持续失效，表现为滚动迟滞、无法滚动。
    ///
    /// 这个值给滚动回调做快路径判断用，刻意不加锁：滚动事件每秒上百次，
    /// 每次都去抢触摸数据的锁会把触摸回调堵住。Double 在 arm64 上单条指令读写。
    private(set) var lastMultiTime: Double = 0

    /// 由滑动力度判定：多指且确实产生了位移时调用
    func noteMultiMove() {
        lastMultiTime = CACurrentMediaTime()
    }

    /// 上一帧的原始触点数（未做边缘过滤），只用于日志
    private(set) var lastRawCount = 0

    func push(_ n: Int, raw: Int = 0) {
        lastRawCount = raw
        let now = CACurrentMediaTime()

        let f = Frame(t: now, n: n)
        lock.lock()
        frames.append(f)
        // 一次清掉一批，避免每帧都搬移整个数组
        if frames.count > capacity + 128 {
            frames.removeFirst(frames.count - capacity)
        }
        // 维护触摸段
        if n > 0 {
            currentSegment.append(n)
            if currentSegment.count > 600 { currentSegment.removeFirst(200) }
        } else if !currentSegment.isEmpty {
            currentSegment = []
        }
        lock.unlock()
    }

    /// 判定点击时手指数，回看窗口由调用方指定（每条点按绑定的参数不同）。
    ///
    /// 两个条件同时成立才算多指手势：
    /// 1. 回看窗口里出现过多指（最大手指数不小于 3，且至少 4 帧）
    /// 2. 按下前 120 毫秒内，多指帧占多数
    ///
    /// 第二条是防误触的关键。妙控鼠标上手掌边缘常常蹭出 2 指，偶尔凑成 3 指，
    /// 只看第一条，三指手势刚结束、残留帧还在窗口里时，紧接着的单指点击
    /// 就会被判成三指。要求“按下那一刻多指还是多数”能排除这种残留。
    func fingerCount(windowMs: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        let cutoff = now - max(0.08, windowMs / 1000)
        var window = frames.filter { $0.t >= cutoff && $0.n > 0 }.map { $0.n }
        if window.isEmpty { window = currentSegment }

        guard window.count >= 3 else { return nil }

        let maxFingers = window.max() ?? 0
        guard maxFingers >= 3 else { return nil }      // 单指、双指一律放行
        guard window.filter({ $0 >= 3 }).count >= 4 else { return nil }

        // 按下瞬间多指必须还在：最近 120ms 内多指帧过半
        let recent = frames.filter { $0.t >= now - 0.12 }.map { $0.n }
        guard !recent.isEmpty else { return nil }
        let recentMulti = recent.filter { $0 >= 3 }.count
        guard recentMulti * 2 >= recent.count else { return nil }

        return maxFingers
    }

    /// 当前是否处在多指触摸中（用于拦截三指滑动引发的页面滚动）
    ///
    /// 无锁 O(1)：滚动回调频率很高，不可在此获取触摸数据的锁
    func multiFingerActive(window: Double = 0.12) -> Bool {
        CACurrentMediaTime() - lastMultiTime < window
    }

    func recentSequence(window: Double = 0.12) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return Array(currentSegment.suffix(20))
    }
}

// MARK: - 滑动手势

final class SwipeEngine {
    static let shared = SwipeEngine()

    private var inSegment = false
    private var startTime: Double = 0
    private var startX: Double = 0
    private var startY: Double = 0
    private var lastX: Double = 0
    private var lastY: Double = 0
    /// 段内坐标极值，用来算摆幅
    private var minX: Double = 0
    private var maxX: Double = 0
    private var minY: Double = 0
    private var maxY: Double = 0
    private var frameCount = 0
    private var maxFingers = 0
    /// 逐帧位移累加（连续移动距离）
    private var pathSumX: Double = 0
    private var pathSumY: Double = 0
    /// 上一帧的满指位置，用来算逐帧位移
    private var prevPosX: Double = 0
    private var prevPosY: Double = 0
    /// 本次触摸段内是否发生过机械点击。发生过即不判定为滑动
    private var segmentHadClick = false

    var verbose = false
    /// 一段多指触摸结束时把原始数据交出去，匹配哪条绑定由 Engine 决定
    var onSegmentEnd: ((SwipeSample) -> Void)?

    func feed(count: Int, avgX: Double, avgY: Double, vx: Double = 0, vy: Double = 0) {
        let now = CACurrentMediaTime()
        // 手掌长期贴着表面时，触摸层会持续上报触点，段永远不会结束
        // （实测出现过 8.2 秒、547 帧的段）。超过 2 秒不可能是手势，直接丢弃。
        if inSegment, now - startTime > 2.0 {
            inSegment = false
        }

        if count >= 1 {
            if !inSegment {
                inSegment = true
                startTime = now
                startX = avgX
                startY = avgY
                minX = avgX; maxX = avgX
                minY = avgY; maxY = avgY
                frameCount = 0
                maxFingers = 0
                segmentHadClick = false
                pathSumX = 0; pathSumY = 0
                prevPosX = avgX; prevPosY = avgY
            }
            // 手指数上升时把起点前移：滑动的起点应该是手指全部就位的那一帧，
            // 而不是只有一根手指刚碰到表面的那一帧
            if count > maxFingers {
                maxFingers = count
                startX = avgX
                startY = avgY
                minX = avgX; maxX = avgX
                minY = avgY; maxY = avgY
                pathSumX = 0; pathSumY = 0
                prevPosX = avgX; prevPosY = avgY
            }

            // 只在满手指数帧上更新终点和极值。手指抬起时触点数会从 3 掉到 2、1，
            // 剩余触点的平均位置会突然跳变，当作终点会使方向翻转
            if count == maxFingers {
                lastX = avgX
                lastY = avgY
                minX = min(minX, avgX); maxX = max(maxX, avgX)
                minY = min(minY, avgY); maxY = max(maxY, avgY)

                // 连续移动距离：把每一帧的位移累加。同向滑动会叠加成真实距离，
                // 来回抖动会正负抵消，自然被排除。方向直接看这个累加值的符号，
                // 不用首尾差（首尾差会被“手指滑出感应区”带偏）。
                pathSumX += avgX - prevPosX
                pathSumY += avgY - prevPosY
                prevPosX = avgX
                prevPosY = avgY
            }
            frameCount += 1

            // 只有“多指确实在移动”才算滑动中，用于决定要不要拦滚动。
            // 静置不动的多指触点不拦截，否则滚轮持续失效。
            if maxFingers >= 3 {
                let travel = max(abs(lastX - startX), abs(lastY - startY))
                if travel > 0.06 { TouchBuffer.shared.noteMultiMove() }
            }
            return
        }

        guard inSegment else { return }
        inSegment = false

        let dt = (now - startTime) * 1000
        let sample = SwipeSample(
            fingers: maxFingers,
            dx: lastX - startX,
            dy: lastY - startY,
            spanX: maxX - minX,
            spanY: maxY - minY,
            startX: startX,
            startY: startY,
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            pathX: pathSumX,
            pathY: pathSumY,
            frames: frameCount,
            durationMs: dt,
            hadClick: segmentHadClick
        )

        if verbose {
            Log.debug(String(format: "[手势] 段结束：frames=%d max=%d dt=%.0fms 连续(dy=%+.3f dx=%+.3f) y范围 %.3f~%.3f",
                             frameCount, maxFingers, dt, sample.pathX, sample.pathY, sample.minY, sample.maxY))
        }

        onSegmentEnd?(sample)
    }

    /// 标记本段发生过机械点击，后续不再判定为滑动
    func markClick() {
        if inSegment { segmentHadClick = true }
    }
}

/// 一段多指触摸的原始特征，不含任何阈值判断
struct SwipeSample {
    let fingers: Int
    /// 首尾净位移
    let dx: Double
    let dy: Double
    /// 段内摆幅（最大减最小）。手指滑出感应区被截断时，净位移会缩水，摆幅不会。
    let spanX: Double
    let spanY: Double
    /// 起点与段内极值，用于净位移接近 0 时判方向
    let startX: Double
    let startY: Double
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    /// 连续移动距离：逐帧位移的累加。同向滑动会叠加，来回抖动会互相抵消。
    /// 这才是“滑了多远”的直接度量，不受起点终点选取影响。
    let pathX: Double
    let pathY: Double
    let frames: Int
    let durationMs: Double
    let hadClick: Bool

    /// 沿主轴的连续移动距离
    func path(horizontal: Bool) -> Double { horizontal ? pathX : pathY }

    /// 主方向符号：连续移动距离的方向
    func directionSign(horizontal: Bool) -> Double {
        let d = path(horizontal: horizontal)
        if abs(d) > 0.001 { return d }
        return horizontal ? dx : dy
    }
}

// MARK: - 预置动作与按键表

enum PresetActions {
    /// 名称、界面显示名
    static let all: [(String, String)] = [
        ("apps", "应用程序网格"),
        ("screenshot", "区域截图到剪贴板"),
        ("missioncontrol", "调度中心"),
        ("appexpose", "应用程序窗口"),
        ("showdesktop", "显示桌面"),
        ("spotlight", "聚焦搜索"),
        ("none", "无动作")
    ]

    static func title(_ name: String) -> String {
        all.first { $0.0 == name }?.1 ?? name
    }
}

enum KeyMap {
    /// 常用键名 → 虚拟键码
    static let all: [(String, CGKeyCode)] = [
        ("up", 126), ("down", 125), ("left", 123), ("right", 124),
        ("space", 49), ("return", 36), ("escape", 53), ("tab", 48), ("delete", 51),
        ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97),
        ("f7", 98), ("f8", 100), ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111),
        ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5),
        ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45),
        ("o", 31), ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32),
        ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)
    ]

    static let modifiers = ["command", "option", "control", "shift", "fn"]

    static func code(for name: String) -> CGKeyCode? {
        all.first { $0.0 == name.lowercased() }?.1
    }

    static func flag(for modifier: String) -> CGEventFlags? {
        switch modifier {
        case "command": return .maskCommand
        case "option": return .maskAlternate
        case "control": return .maskControl
        case "shift": return .maskShift
        case "fn": return .maskSecondaryFn
        default: return nil
        }
    }

    static func flags(_ list: [String]) -> CGEventFlags {
        var out: CGEventFlags = []
        for m in list {
            if let f = flag(for: m) { out.insert(f) }
        }
        return out
    }

    static func modifierSymbol(_ name: String) -> String {
        switch name {
        case "command": return "⌘"
        case "option": return "⌥"
        case "control": return "⌃"
        case "shift": return "⇧"
        case "fn": return "fn"
        default: return name
        }
    }
}

// MARK: - 动作执行

enum ActionRunner {
    static func perform(_ spec: ActionSpec) {
        switch spec.kind {
        case "preset":
            performPreset(spec.value)
        case "openApp":
            openApp(spec.value)
        case "url":
            run("/usr/bin/open", [spec.value])
        case "keyShortcut":
            guard let code = KeyMap.code(for: spec.value) else {
                Log.err("未知按键：\(spec.value)")
                return
            }
            sendKey(code, flags: KeyMap.flags(spec.modifiers))
        case "shell":
            run("/bin/sh", ["-c", spec.value])
        default:
            Log.err("未知动作类型：\(spec.kind)")
        }
    }

    private static func performPreset(_ name: String) {
        switch name {
        case "apps":
            run("/usr/bin/open", ["-b", "com.apple.apps.launcher"])
        case "screenshot":
            run("/usr/sbin/screencapture", ["-i", "-c"])
        case "spotlight":
            sendKey(49, flags: .maskCommand)
        case "missioncontrol":
            // 直接唤起 Mission Control，比发键盘事件可靠
            run("/usr/bin/open", ["-b", "com.apple.exposelauncher"])
        case "appexpose":
            sendKey(125, flags: [.maskControl, .maskSecondaryFn])
        case "showdesktop":
            // 系统里“显示桌面”绑的是 F11 + fn，缺 fn 标志系统无法识别
            sendKey(103, flags: [.maskSecondaryFn])
        case "none", "":
            break
        default:
            if name.hasPrefix("exec:") {
                run("/bin/sh", ["-c", String(name.dropFirst(5))])
            } else {
                Log.err("未知动作：\(name)")
            }
        }
    }

    private static func openApp(_ target: String) {
        if target.contains("/") {
            run("/usr/bin/open", ["-a", target])
        } else {
            run("/usr/bin/open", ["-b", target])
        }
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(12_000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}

// MARK: - 开机启动

/// 用 LaunchAgent 实现开机启动。
///
/// 不让 launchd 直接执行 app 内的二进制：那样 TCC 无法识别 bundle，
/// 会丢辅助功能权限。改为让 launchd 调 `open -a`，与手动点击启动一致。
enum LaunchAtLogin {
    static let label = "com.simpletouch.app"

    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    /// 勾选状态按“配置文件在 + launchd 已登记”双重判断。
    /// 只看文件会出现已勾选但未注册的情况。
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath) && isRegistered
    }

    static var isRegistered: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.contains(label)
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        if on {
            guard writePlist() else { return false }
            _ = run(["/bin/launchctl", "unload", "-w", plistPath])
            return run(["/bin/launchctl", "load", "-w", plistPath])
        }
        _ = run(["/bin/launchctl", "unload", "-w", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        return !isEnabled
    }

    private static func writePlist() -> Bool {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>-a</string>
            <string>\(Bundle.main.bundlePath)</string>
          </array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = xml.data(using: .utf8) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: plistPath))
            return true
        } catch {
            return false
        }
    }

    private static func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - 菜单栏

final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let onSettings: () -> Void
    private let onReload: () -> Void
    private let onQuit: () -> Void
    private var appearanceObserver: NSKeyValueObservation?
    private var themeObserver: NSObjectProtocol?

    init(onSettings: @escaping () -> Void,
         onReload: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.onSettings = onSettings
        self.onReload = onReload
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = Self.makeStatusIcon(dark: Self.isDarkMenuBar)
            button.toolTip = "SimpleTouch"
        }

        // 跟随系统明暗：浅色白底黑线，深色深底白线
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.scheduleIconRefresh()
        }
        themeObserver = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleIconRefresh()
        }

        let menu = NSMenu()

        let settings = NSMenuItem(title: "设置…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开配置文件", action: #selector(openConfigTapped), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let launch = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchTapped), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 SimpleTouch", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    /// 菜单栏图标：半透明实心底板 + 镂空图案（透出菜单栏背景），底板以外完全透明
    /// 深色菜单栏用白底，浅色菜单栏用深底，保证图案始终能被背景反衬出来
    /// 用 even-odd 复合路径一次填充（笔画先转为填充区域），镂空区域完全透明，矢量绘制清晰
    private static func makeStatusIcon(dark: Bool) -> NSImage {
        let side: CGFloat = 20
        let plateColor: NSColor = dark
            ? NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 0.94)
            : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.94)

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let combined = CGMutablePath()

            // 底板
            combined.addPath(CGPath(
                roundedRect: CGRect(x: 0.5, y: 0.5, width: side - 1.0, height: side - 1.0),
                cornerWidth: 5.6, cornerHeight: 5.6, transform: nil
            ))

            // 鼠标轮廓：描边路径转成填充区域，参与 even-odd 挖空
            let body = CGPath(
                roundedRect: CGRect(x: 4.9, y: 3.3, width: 10.2, height: 13.4),
                cornerWidth: 5.1, cornerHeight: 5.1, transform: nil
            )
            combined.addPath(body.copy(
                strokingWithWidth: 1.4, lineCap: .round, lineJoin: .round, miterLimit: 10
            ))

            // 三颗触点
            let d: CGFloat = 1.6
            for x in [7.5, 10.0, 12.5] {
                combined.addEllipse(in: CGRect(x: x - d / 2, y: 12.35 - d / 2, width: d, height: d))
            }

            // 接缝
            let seam = CGMutablePath()
            seam.move(to: CGPoint(x: 6.95, y: 9.85))
            seam.addLine(to: CGPoint(x: 13.05, y: 9.85))
            combined.addPath(seam.copy(
                strokingWithWidth: 1.0, lineCap: .round, lineJoin: .round, miterLimit: 10
            ))

            let path = NSBezierPath(cgPath: combined)
            path.windingRule = .evenOdd
            plateColor.setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 当前菜单栏是否为深色
    private static var isDarkMenuBar: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 主题切换后 effectiveAppearance 有延迟，延后重绘
    private func scheduleIconRefresh() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyStatusIcon), object: nil)
        perform(#selector(applyStatusIcon), with: nil, afterDelay: 0.25)
    }

    @objc private func applyStatusIcon() {
        item.button?.image = Self.makeStatusIcon(dark: Self.isDarkMenuBar)
    }

    @objc private func settingsTapped() { onSettings() }
    @objc private func reloadTapped() { onReload() }
    @objc private func quitTapped() { onQuit() }

    @objc private func openConfigTapped() {
        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigStore.path))
    }

    @objc private func toggleLaunchTapped(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        let ok = LaunchAtLogin.setEnabled(enable)
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
        if !ok {
            Log.err("开机启动设置失败：检查 ~/Library/LaunchAgents 是否可写")
        }
    }

    deinit {
        appearanceObserver?.invalidate()
        if let themeObserver {
            DistributedNotificationCenter.default.removeObserver(themeObserver)
        }
    }
}

// MARK: - 主引擎

final class Engine {
    private var devices: [MTDeviceRef] = []
    private var stopFn: DeviceStopFn?
    private var eventTap: CFMachPort?
    /// 每条绑定各自的最近触发时间，用于按绑定冷却
    private var lastFire: [String: Double] = [:]
    /// 手势触发后短暂屏蔽滚动：惯性滚动会滞后于手指抬起，不挡会漏出去
    private var scrollBlockUntil: Double = 0
    /// 连续屏蔽滚动的起点，用来给屏蔽加时长上限
    private var scrollSuppressStart: Double = 0

    private var config: AppConfig
    private let dryRun: Bool
    private let verbose: Bool

    private static var contactCallback: ContactCallback?

    // 触摸探针统计，只在 --probe 下使用
    static var probeMode = false
    /// 采集模式：触点数变化时打印每个触点的坐标与接触面积
    static var learnMode = false
    static var lastPrintedCount = -1
    static var pFrames = 0
    static var pRaw = 0
    static var pKept = 0
    static var pSamples = 0
    static var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0

    init(config: AppConfig, dryRun: Bool, verbose: Bool) {
        self.config = config
        self.dryRun = dryRun
        self.verbose = verbose
    }

    func start() -> Bool {
        TouchBuffer.shared.tuning = config.tuning
        TouchFilter.edgeMargin = config.tuning.edgeMargin
        SwipeEngine.shared.verbose = verbose
        SwipeEngine.shared.onSegmentEnd = { [weak self] sample in
            self?.handleSwipeSegment(sample)
        }

        return loadMultitouch() && installEventTap()
    }

    /// 用一段触摸的原始特征匹配非点按绑定（轻触、滑动），每条绑定用自己的阈值
    private func handleSwipeSegment(_ sample: SwipeSample) {
        guard !sample.hadClick else { return }         // 本段发生过机械点击，不可能匹配轻触或滑动

        let now = CACurrentMediaTime()

        // 精确手指数优先；容错默认关闭，开启后也只在该手指数没有任何绑定时生效。
        // 跨手指数匹配正是“三指动作触发二指绑定”的来源。
        let tolerance = max(0, config.tuning.fingerTolerance)
        let exactExists = config.bindings.contains { !$0.isTap && $0.fingers == sample.fingers }

        // 滑动优先于轻触：位移已达到滑动量级时不应先命中轻触
        let ordered = config.bindings.enumerated()
            .filter { !$0.element.isTap }
            .sorted { a, b in
                if a.element.isTouch != b.element.isTouch { return !a.element.isTouch }
                return a.offset < b.offset
            }
            .map { $0.element }

        for binding in ordered {
            let matched: Bool
            if sample.fingers == binding.fingers {
                matched = true
            } else if tolerance > 0, !exactExists {
                matched = sample.fingers == binding.fingers + tolerance
            } else {
                matched = false
            }
            guard matched else { continue }

            let label: String

            if binding.isTouch {
                // 轻触：短暂接触后立即离开，位移小、时长短。
                // 位移用连续移动距离，与滑动口径一致，避免微小抖动被判成净位移 0
                guard sample.durationMs >= 25, sample.durationMs <= 350 else { continue }
                let moved = max(abs(sample.pathX), abs(sample.pathY))
                guard moved <= binding.params.threshold else { continue }
                label = "轻触"
            } else {
                // 手指数已在上方匹配，这里不再写死 3 指，
                // 否则 1 指、2 指滑动永远不会生效

                // 轴向由绑定本身决定，不按摆幅大小推断：
                // 纵向滑动时手指难免横向偏移，按摆幅推断会把上下滑判成左右滑
                let horizontal = (binding.gesture == "swipeLeft" || binding.gesture == "swipeRight")
                // 幅度用连续移动距离，不用首尾差也不用摆幅
                let travel = abs(sample.path(horizontal: horizontal))
                let cross = abs(sample.path(horizontal: !horizontal))
                guard travel >= cross else { continue }      // 主轴必须占优

                let sign = sample.directionSign(horizontal: horizontal)
                let direction: String
                if horizontal {
                    direction = sign > 0 ? "swipeRight" : "swipeLeft"
                } else {
                    let up = binding.params.invert ? (sign < 0) : (sign > 0)
                    direction = up ? "swipeUp" : "swipeDown"
                }
                guard direction == binding.gesture else { continue }

                // 帧数仅作技术下限：至少 2 帧才能算出距离。
                // 不可用帧数作灵敏度门槛：滑动越慢帧数越多，快速滑动帧数很少，
                // 以帧数筛选会排除全部快速操作。
                guard sample.frames >= 2 else { continue }
                guard sample.durationMs <= binding.params.maxDurationMs else { continue }
                guard travel >= binding.params.threshold else { continue }

                // 单向性：连续移动距离必须占摆幅的大部分，否则是来回抖动
                let span = horizontal ? sample.spanX : sample.spanY
                guard span <= 0 || travel >= span * 0.5 else { continue }

                label = GestureType.title(direction)
            }

            guard now - lastFire[binding.key, default: 0] >= binding.params.cooldownMs / 1000 else { continue }

            lastFire[binding.key] = now
            Log.info("\(sample.fingers) 指\(label) → \(binding.action.summary)")
            scrollBlockUntil = now + 0.45
            ActionRunner.perform(binding.action)
            return
        }

        if verbose {
            Log.debug(String(format: "[手势] 未匹配绑定：max=%d frames=%d dt=%.0fms 连续(dx=%+.3f dy=%+.3f) 净(dy=%+.3f) 幅(dy=%.3f)",
                             sample.fingers, sample.frames, sample.durationMs,
                             sample.pathX, sample.pathY, sample.dy, sample.spanY))
        }
    }

    private func loadMultitouch() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            Log.err("MultitouchSupport 加载失败")
            return false
        }
        guard let s1 = dlsym(handle, "MTDeviceCreateList"),
              let s2 = dlsym(handle, "MTRegisterContactFrameCallback"),
              let s3 = dlsym(handle, "MTDeviceStart"),
              let s4 = dlsym(handle, "MTDeviceStop") else {
            Log.err("MultitouchSupport 符号缺失")
            return false
        }

        let createList = unsafeBitCast(s1, to: CreateListFn.self)
        let register = unsafeBitCast(s2, to: RegisterFn.self)
        let startDevice = unsafeBitCast(s3, to: StartStopFn.self)
        stopFn = unsafeBitCast(s4, to: DeviceStopFn.self)

        guard let list = createList() else {
            Log.err("未发现触摸设备：确认鼠标已连接")
            return false
        }

        Log.info("[触摸] 触点结构体 \(MemoryLayout<MTFinger>.size) 字节")

        let cb: ContactCallback = { _, fingersPtr, rawN, _, _ in
            let raw = Int(rawN)
            let margin = TouchFilter.edgeMargin
            var kept = 0
            var avgX: Double = 0
            var avgY: Double = 0

            if raw > 0, let p = fingersPtr {
                let fp = p.bindMemory(to: MTFinger.self, capacity: raw)

                if !TouchFilter.scaleDetected {
                    TouchFilter.scaleDetected = true
                }

                let sx = TouchFilter.scaleX
                let sy = TouchFilter.scaleY

                for i in 0..<raw {
                    let x = Double(fp[i].normalized.pos.x) / sx
                    let y = Double(fp[i].normalized.pos.y) / sy
                    if Engine.probeMode {
                        Engine.minX = min(Engine.minX, x); Engine.maxX = max(Engine.maxX, x)
                        Engine.minY = min(Engine.minY, y); Engine.maxY = max(Engine.maxY, y)
                        Engine.pSamples += 1
                    }
                    // 边缘带内的触点直接丢弃：手掌、指侧蹭到鼠标边缘最常造成的假触点
                    if margin > 0,
                       x < margin || x > 1 - margin || y < margin || y > 1 - margin {
                        continue
                    }
                    kept += 1
                    avgX += x
                    avgY += y
                }
                if kept > 0 {
                    avgX /= Double(kept)
                    avgY /= Double(kept)
                }

                // 采集模式：手指数一变就把每个触点的位置和接触面积打出来，
                // 用来区分“真的三根手指”和“手掌边缘蹭出的假触点”
                if Engine.learnMode, kept != Engine.lastPrintedCount, kept >= 2 {
                    Engine.lastPrintedCount = kept
                    var parts: [String] = []
                    for i in 0..<raw {
                        parts.append(String(format: "(%.1f,%.1f 面积%.1f)",
                                            Double(fp[i].normalized.pos.x), Double(fp[i].normalized.pos.y), Double(fp[i].size)))
                    }
                    print("#\(kept)指  " + parts.joined(separator: "   "))
                    fflush(stdout)
                }
            }

            // 全部触点都被边缘带/禁用区域滤掉时，视作没有触摸。
            // 早先这里会伪造一个 0.5 的坐标把帧塞回去，结果恒定的 0.5
            // 会污染位移累积，启用边缘过滤后整段失效。

            if Engine.probeMode {
                Engine.pFrames += 1
                Engine.pRaw += raw
                Engine.pKept += kept
            }
            TouchBuffer.shared.push(kept, raw: raw)
            SwipeEngine.shared.feed(count: kept, avgX: avgX, avgY: avgY)
            return 0
        }
        Engine.contactCallback = cb

        let total = CFArrayGetCount(list)
        for i in 0..<total {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            devices.append(dev)
            register(dev, cb)
            startDevice(dev, 0)
        }

        guard !devices.isEmpty else { return false }
        Log.info("已接管 \(devices.count) 个触摸设备")
        return true
    }

    private func installEventTap() -> Bool {
        if !dryRun && !AXIsProcessTrusted() {
            Log.err("缺少“辅助功能”权限：系统设置 → 隐私与安全性 → 辅助功能")
            return false
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<Engine>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    // 两种禁用都不重开。在没有授权的情况下重新 enable，tap 会进入
                    // “启用但不放行事件”的中间态：回调不再被调用，事件也出不去，
                    // 整个会话的鼠标和滚轮一起卡死。正确做法是立即停止监听并退出。
                    engine.abort(type == .tapDisabledByTimeout ? "事件监听被系统停用" : "辅助功能授权被撤销")
                    return Unmanaged.passUnretained(event)
                }
                if type == .leftMouseDown { return engine.handleMouseDown(event) }
                if type == .scrollWheel { return engine.handleScrollWheel(event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.err("事件监听创建失败：检查辅助功能权限")
            return false
        }

        eventTap = tap
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 发生机械点击时无条件标记：这一段触摸不可能是滑动，
        // 与点按判定是否成功无关（否则判定失败时滑动会接手，造成双重误触）
        SwipeEngine.shared.markClick()

        if verbose {
            Log.debug("[点击] 原始 \(TouchBuffer.shared.lastRawCount) 触点：\(TouchBuffer.shared.recentSequence())")
        }

        // 逐条点按绑定用自己的回看窗口判定，窗口大的先试
        var hit: GestureBinding?
        var hitFingers = 0
        for binding in config.tapBindings {
            guard let n = TouchBuffer.shared.fingerCount(windowMs: binding.params.windowMs) else { continue }
            // 精确手指数优先；容错默认关闭
            let tolerance = max(0, config.tuning.fingerTolerance)
            let exactExists = config.tapBindings.contains { $0.fingers == n }
            let matched = n == binding.fingers
                || (tolerance > 0 && !exactExists && n == binding.fingers + tolerance)
            if matched {
                hit = binding
                hitFingers = n
                break
            }
        }

        guard let binding = hit else { return Unmanaged.passUnretained(event) }
        // 绑定了却选了“无动作”，就当作没这个手势，点击照常生效
        guard !(binding.action.kind == "preset" && binding.action.value == "none") else {
            return Unmanaged.passUnretained(event)
        }

        let now = CACurrentMediaTime()
        guard now - lastFire[binding.key, default: 0] >= binding.params.cooldownMs / 1000 else {
            return Unmanaged.passUnretained(event)
        }

        lastFire[binding.key] = now

        if dryRun {
            Log.info("[dry-run] \(hitFingers) 指点按 → \(binding.action.summary)")
            return Unmanaged.passUnretained(event)
        }

        Log.info("\(hitFingers) 指点按 → \(binding.action.summary)")
        scrollBlockUntil = now + 0.45
        ActionRunner.perform(binding.action)
        return nil      // 拦截本次点击，避免点击穿透到下层界面
    }

    /// 三指在鼠标表面滑动时，系统会同时产生滚动事件，
    /// 切调度中心的同时页面也随之滚动。多指期间以及手势触发后的
    /// 惯性滚动窗口内，一律拦截滚动事件。
    private func handleScrollWheel(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if dryRun { return Unmanaged.passUnretained(event) }

        let now = CACurrentMediaTime()
        if now < scrollBlockUntil { return nil }

        // 只在多指确实在滑动的短窗口内拦截滚动。手掌静置的常驻触点不拦截，
        // 否则滚轮无法使用（此前正是此处把常驻触点当成了滑动）
        if TouchBuffer.shared.multiFingerActive(window: 0.25) {
            // 上限保护：连续拦截不超过 1 秒
            if scrollSuppressStart == 0 { scrollSuppressStart = now }
            if now - scrollSuppressStart > 1.0 {
                scrollSuppressStart = 0
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        scrollSuppressStart = 0
        return Unmanaged.passUnretained(event)
    }

    /// 触摸探针：只读触摸数据，不建事件监听，也不需要辅助功能权限。
    /// 用于确认触点是否被系统上报、边缘过滤丢弃的比例。
    func probe(seconds: Double) {
        Engine.probeMode = true
        _ = loadMultitouch()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        Engine.probeMode = false

        print("帧数 \(Engine.pFrames)，原始触点累计 \(Engine.pRaw)，边缘过滤后 \(Engine.pKept)")
        if Engine.pSamples > 0 {
            print(String(format: "x 范围 %.3f ~ %.3f   y 范围 %.3f ~ %.3f",
                         Engine.minX, Engine.maxX, Engine.minY, Engine.maxY))
        } else {
            print("没有采到触点")
        }
    }

    /// 手势采集：只读触摸，不建事件监听、不触发任何动作。
    /// 每一段触摸打印净位移与摆幅，用来确认方向符号和实际滑动幅度。
    func learn(seconds: Double) {
        SwipeEngine.shared.verbose = false
        Engine.learnMode = true
        SwipeEngine.shared.onSegmentEnd = { sample in
            let direction = abs(sample.dy) >= abs(sample.dx) ? "纵向" : "横向"
            print(String(format: "#%d指 %@  %5.0fms %3d帧  连续 dy=%+.3f dx=%+.3f   净 dy=%+.3f   幅 dy=%.3f%@",
                         sample.fingers, direction, sample.durationMs, sample.frames,
                         sample.pathY, sample.pathX, sample.dy, sample.spanY,
                         sample.hadClick ? "  (含点击)" : ""))
            fflush(stdout)
        }

        _ = loadMultitouch()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
        Engine.learnMode = false
        print("采集结束")
    }

    /// 分阶段采集：按顺序提示做不同手势，逐段记录特征，用于校准方向和阈值
    func capture() {
        _ = loadMultitouch()
        var current = ""
        var lines: [String] = []

        SwipeEngine.shared.verbose = false
        SwipeEngine.shared.onSegmentEnd = { sample in
            guard !current.isEmpty else { return }
            let axis = abs(sample.pathY) >= abs(sample.pathX) ? "纵" : "横"
            lines.append(String(format: "%@ | %d指 %@ %5.0fms %3d帧 连续 dy=%+.3f dx=%+.3f 净 dy=%+.3f 幅 dy=%.3f%@",
                                current, sample.fingers, axis, sample.durationMs, sample.frames,
                                sample.pathY, sample.pathX, sample.dy, sample.spanY,
                                sample.hadClick ? " (含点击)" : ""))
        }

        let plan: [(String, Double)] = [
            ("三指上滑", 15),
            ("三指下滑", 15),
            ("三指点按", 12),
            ("单指点按", 12)
        ]

        for (label, dur) in plan {
            current = label
            print("")
            print("========================================")
            print("  请做：\(label)，3 次，间隔 1 秒")
            print("  \(Int(dur)) 秒后自动进入下一项")
            print("========================================")
            fflush(stdout)

            let end = Date().addingTimeInterval(dur)
            while Date() < end {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        current = ""
        print("")
        print("================ 采集结果 ================")
        for line in lines { print(line) }
        print("================ 采集结束 ================")
        fflush(stdout)
    }

    /// 测量四个方向上的最大可用滑动距离，用于阈值定标
    func measureRange() {
        _ = loadMultitouch()
        var current = ""
        var rows: [(String, Double, Double, Double, Double)] = []

        SwipeEngine.shared.verbose = false
        SwipeEngine.shared.onSegmentEnd = { s in
            guard !current.isEmpty else { return }
            rows.append((current, s.spanY, s.spanX, s.pathY, s.pathX))
            let dist = max(abs(s.pathY), abs(s.pathX))
            let speed = s.durationMs > 0 ? dist / (s.durationMs / 1000) : 0
            print(String(format: "  → %@｜距离 纵%.3f 横%.3f｜速度 %.2f/秒｜时长 %3.0fms",
                         current, abs(s.pathY), abs(s.pathX), speed, s.durationMs))
            fflush(stdout)
        }

        let plan: [(String, Double)] = [
            ("从最前推到最靠后", 15),
            ("从最靠后推到最前", 15),
            ("从最左滑到最右", 15),
            ("从最右滑到最左", 15)
        ]

        for (label, dur) in plan {
            current = label
            print("")
            print("========================================")
            print("  请做：单指\(label)，3 次，滑动尽量覆盖整个鼠标表面")
            print("  \(Int(dur)) 秒后自动进入下一项")
            print("========================================")
            fflush(stdout)

            let end = Date().addingTimeInterval(dur)
            while Date() < end {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        current = ""
        print("")
        print("================ 可用距离汇总 ================")
        for label in plan.map({ $0.0 }) {
            let group = rows.filter { $0.0 == label }
            guard !group.isEmpty else {
                print("\(label)：没有采到样本")
                continue
            }
            let maxSpanY = group.map { $0.1 }.max() ?? 0
            let maxSpanX = group.map { $0.2 }.max() ?? 0
            let maxPathY = group.map { abs($0.3) }.max() ?? 0
            let maxPathX = group.map { abs($0.4) }.max() ?? 0
            let maxFingers = group.count
            print(String(format: "%@：样本 %d 段｜纵向最大幅 %.3f、连续 %.3f｜横向最大幅 %.3f、连续 %.3f",
                         label, maxFingers, maxSpanY, maxPathY, maxSpanX, maxPathX))
        }
        print("============================================")
        fflush(stdout)
    }

    /// 撤销授权或出现致命状态时调用。只要进程还在而事件监听失效，
    /// 整个会话的鼠标都会被截住，所以必须立刻停止监听并退出。
    ///
    /// 必须在调用线程上同步做完：走主队列会等主线程空闲，而权限被撤销时
    /// 主线程正被系统挂起，退出就永远等不到，输入无法恢复。
    func abort(_ reason: String) {
        let tap = eventTap
        eventTap = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        Log.err("\(reason)，已停止监听并退出")
        exit(0)
    }

    /// 看门狗：授权被撤销时系统不一定发通知，主动查一次
    func watchdogTick() {
        guard eventTap != nil else { return }
        if !AXIsProcessTrusted() {
            abort("辅助功能授权已失效")
            return
        }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            abort("事件监听被系统停用")
        }
    }

    /// 运行时应用新配置（设置界面保存后调用）
    func applyConfig(_ cfg: AppConfig) {
        config = cfg
        TouchFilter.edgeMargin = cfg.tuning.edgeMargin
        SwipeEngine.shared.verbose = cfg.tuning.debug
        Log.info("[配置] 已应用")
    }

    func shutdown() {
        for d in devices { stopFn?(d) }
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: false) }
    }
}

// MARK: - 日志

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // GUI 方式启动时 stdout 会被 LaunchServices 丢弃，所以同时写文件
    private static let filePath = "/tmp/simpletouch-app.log"
    private static let queue = DispatchQueue(label: "com.simpletouch.app.log")
    private static var handle: FileHandle?

    /// 事件回调线程只做入队，文件 IO 全部放到串行队列。
    ///
    /// 原来每次日志都 open/seek/write/close，写在 CGEvent 回调里；
    /// 磁盘响应慢时回调会超过系统时限，tap 被判定超时后输入随之失效。
    private static func write(_ line: String) {
        print(line)
        fflush(stdout)

        if handle == nil {
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil)
            }
            handle = FileHandle(forWritingAtPath: filePath)
            handle?.seekToEndOfFile()
        }
        if let h = handle, let data = (line + "\n").data(using: .utf8) {
            h.write(data)
        }
    }

    private static func enqueue(_ level: String, _ message: String) {
        queue.async {
            write("[\(formatter.string(from: Date()))] [\(level)] \(message)")
        }
    }

    static func info(_ s: String) { enqueue("i", s) }
    static func debug(_ s: String) { enqueue("d", s) }

    /// 退出前的错误必须同步落盘，否则进程结束时队列内容会丢
    static func err(_ s: String) {
        queue.sync {
            write("[\(formatter.string(from: Date()))] [!] \(s)")
        }
        FileHandle.standardError.write(("[!] \(s)\n").data(using: .utf8)!)
    }
}

// MARK: - 入口

func printHelp() {
    print("""
    SimpleTouch — 妙控鼠标多指手势引擎

    用法：
      SimpleTouch                正常运行（常驻监听）
      SimpleTouch --dry-run      观察模式：只打印判定，不拦截事件
      SimpleTouch --verbose      打印每次点击的判定细节
      SimpleTouch --do=<动作名>  执行一次预置动作后退出（自测用）
      SimpleTouch --windows      打印当前窗口列表
      SimpleTouch --help         显示帮助

    手势由“手指数 + 类型”确定，类型可取 tap / touch / swipeUp / swipeDown / swipeLeft / swipeRight。
    动作在配置文件的 bindings 里定义，kind 支持：
      preset       预置动作：apps / screenshot / missioncontrol / appexpose /
                   showdesktop / spotlight / none
      openApp      打开应用，value 填 bundle id 或 .app 路径
      url          打开链接
      keyShortcut  发送按键，value 填键名，modifiers 填 command/option/control/shift/fn
      shell        执行 shell 命令

    配置文件：\(ConfigStore.path)
    """)
}

let argv = CommandLine.arguments

if argv.contains("--help") || argv.contains("-h") {
    printHelp()
    exit(0)
}

if argv.contains("--windows") {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else {
        print("无法获取窗口列表")
        exit(1)
    }
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let name = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let wd = (b["Width"] as? NSNumber)?.intValue ?? 0
        let ht = (b["Height"] as? NSNumber)?.intValue ?? 0
        print("\(owner)|\(name)|layer=\(layer)|\(wd)x\(ht)")
    }
    exit(0)
}

if argv.contains("--probe") {
    let secs = argv.compactMap { Double($0) }.first ?? 8
    let eng = Engine(config: ConfigStore.load(), dryRun: true, verbose: true)
    eng.probe(seconds: secs)
    exit(0)
}

if argv.contains("--range") {
    let eng = Engine(config: ConfigStore.load(), dryRun: true, verbose: false)
    eng.measureRange()
    exit(0)
}

if argv.contains("--capture") {
    let eng = Engine(config: ConfigStore.load(), dryRun: true, verbose: false)
    eng.capture()
    exit(0)
}

if argv.contains("--learn") {
    let secs = argv.compactMap { Double($0) }.first ?? 40
    print("开始采集 \(Int(secs)) 秒。请依次做：三指上滑 3 次、三指下滑 3 次，每次间隔 1 秒。")
    fflush(stdout)
    let eng = Engine(config: ConfigStore.load(), dryRun: true, verbose: false)
    eng.learn(seconds: secs)
    exit(0)
}

if let doArg = argv.first(where: { $0.hasPrefix("--do=") }) {
    let action = String(doArg.dropFirst(5))
    Log.info("单次执行：\(action)")
    ActionRunner.perform(.preset(action))
    exit(0)
}

let config = ConfigStore.load()
let dryRun = argv.contains("--dry-run")
let verbose = argv.contains("--verbose") || config.tuning.debug

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

Log.info("SimpleTouch 启动\(dryRun ? "（观察模式）" : "")")
if config.bindings.isEmpty {
    Log.info("配置里没有任何绑定：在设置界面添加")
} else {
    for b in config.bindings {
        Log.info("\(b.fingers) 指\(b.gestureTitle)→\(b.action.summary)")
    }
}

let engine = Engine(config: config, dryRun: dryRun, verbose: verbose)

guard engine.start() else {
    Log.err("启动失败：见上方错误")
    exit(1)
}

// 看门狗走独立线程：主线程在授权变更期间可能被系统挂起，
// 挂在主队列上的定时器那时不会执行，输入就无法恢复。
DispatchQueue.global(qos: .utility).async {
    while true {
        Thread.sleep(forTimeInterval: 0.3)
        engine.watchdogTick()
    }
}

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let settingsWindow = SettingsWindowController()

let statusBar = StatusBarController(
    onSettings: {
        settingsWindow.show(config: ConfigStore.load()) { newConfig in
            engine.applyConfig(newConfig)
        }
    },
    onReload: {
        let fresh = ConfigStore.load()
        engine.applyConfig(fresh)
        
    },
    onQuit: {
        Log.info("退出")
        engine.shutdown()
        exit(0)
    }
)
_ = statusBar

// 权限看门狗
//
// 用户随时可能在系统设置里删除辅助功能授权。授权一撤销，事件监听就处于
// 失效状态：事件被拦截但回调不再被调用，整台机器的鼠标会卡死。
// 所以一旦发现授权被撤销，必须立即停止监听并退出，仅保留一条日志。
if !dryRun {
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        if !AXIsProcessTrusted() {
            engine.abort("辅助功能授权失效")
        }
    }
}

Log.info("就绪")
nsApp.run()
