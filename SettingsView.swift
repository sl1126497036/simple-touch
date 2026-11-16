// SimpleTouch 设置界面
//
// 绑定可增删，每条绑定带自己的识别参数：点按用回看窗口，滑动用位移阈值。
import SwiftUI
import AppKit

private let kindOptions: [(id: String, label: String)] = [
    ("preset", "预置动作"),
    ("openApp", "打开应用"),
    ("url", "打开链接"),
    ("keyShortcut", "发送按键"),
    ("shell", "执行命令")
]

/// 切换动作类型时填入的默认参数
private func defaultParams(for kind: String) -> (value: String, modifiers: [String]) {
    switch kind {
    case "preset": return ("apps", [])
    case "openApp": return ("com.apple.Safari", [])
    case "url": return ("https://", [])
    case "keyShortcut": return ("up", ["control"])
    case "shell": return ("", [])
    default: return ("", [])
    }
}

private struct DraftBinding: Identifiable {
    let id = UUID()
    var fingers: Int
    var gesture: String
    var kind: String
    var value: String
    var modifiers: [String]
    var params: BindingParams

    init(_ binding: GestureBinding) {
        fingers = binding.fingers
        gesture = binding.gesture
        kind = binding.action.kind
        value = binding.action.value
        modifiers = binding.action.modifiers
        params = binding.params
    }

    init(fingers: Int, gesture: String, kind: String, value: String,
         modifiers: [String], params: BindingParams) {
        self.fingers = fingers
        self.gesture = gesture
        self.kind = kind
        self.value = value
        self.modifiers = modifiers
        self.params = params
    }

    var spec: ActionSpec {
        ActionSpec(kind: kind, value: value, modifiers: modifiers)
    }

    var gestureTitle: String { GestureType.title(gesture) }
    var isTap: Bool { gesture == "tap" }
    var isTouch: Bool { gesture == "touch" }
}

struct SettingsView: View {
    @State private var drafts: [DraftBinding]
    @State private var selection: UUID?
    @State private var tuning: TuningConfig
    @State private var toastVisible = false

    let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        let list = config.bindings.map(DraftBinding.init)
        _drafts = State(initialValue: list)
        _selection = State(initialValue: list.first?.id)
        _tuning = State(initialValue: config.tuning)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 12) {
            bindingPane
            globalPane
            footer
        }
        .padding(16)
        .frame(width: 720)
        .overlay(alignment: .top) {
            if toastVisible {
                Label("已保存并生效", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
                    )
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: 绑定列表 + 详情

    private var bindingPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(drafts) { draft in
                                rowButton(draft)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selection) { newValue in
                        guard let newValue else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
                Divider()
                Button {
                    add()
                } label: {
                    Label("添加绑定", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 7)
            }
            .frame(width: 268)
            .background(Color.primary.opacity(0.04))

            Divider()

            ScrollView {
                if let index = selectedIndex {
                    detail($drafts[index])
                        .padding(16)
                } else {
                    Text("选择左侧绑定以编辑参数")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 60)
                }
            }
        }
        .frame(height: 360)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private func rowButton(_ draft: DraftBinding) -> some View {
        let active = selection == draft.id
        return Button {
            selection = draft.id
        } label: {
            HStack(spacing: 6) {
                Text("\(draft.fingers) 指")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                Text(draft.gestureTitle).font(.callout)
                Text("→").foregroundStyle(.tertiary)
                Text(draft.spec.summary).font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(draft.id)
        .contextMenu {
            Button("删除", role: .destructive) { remove(draft.id) }
        }
    }

    @ViewBuilder
    private func detail(_ draft: Binding<DraftBinding>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("手势").font(.headline)
                Spacer()
                Button("删除") { remove(draft.wrappedValue.id) }
                    .foregroundStyle(.red)
            }

            Picker("", selection: draft.fingers) {
                ForEach([1, 2, 3, 4, 5], id: \.self) { n in Text("\(n) 指").tag(n) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("", selection: draft.gesture) {
                ForEach(GestureType.all, id: \.self) { g in
                    Text(GestureType.title(g)).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider().padding(.vertical, 2)

            Text("动作").font(.headline)

            Picker("", selection: draft.kind) {
                ForEach(kindOptions, id: \.id) { opt in
                    Text(opt.label).tag(opt.id)
                }
            }
            .labelsHidden()
            .onChange(of: draft.wrappedValue.kind) { newKind in
                let fallback = defaultParams(for: newKind)
                draft.wrappedValue.value = fallback.value
                draft.wrappedValue.modifiers = fallback.modifiers
            }

            actionParams(draft)

            Divider().padding(.vertical, 2)

            // 识别参数跟随手势类型：点按不显示滑动参数，反之亦然
            if draft.wrappedValue.isTap {
                Text("点按识别").font(.headline)
                paramSlider("回看窗口 ms", draft.params.windowMs, 80...600, "%.0f")
                paramSlider("触发冷却 ms", draft.params.cooldownMs, 100...1000, "%.0f")
            } else if draft.wrappedValue.isTouch {
                Text("轻触识别").font(.headline)
                paramSlider("最大位移", draft.params.threshold, 0.02...0.30, "%.2f")
                paramSlider("触发冷却 ms", draft.params.cooldownMs, 100...1000, "%.0f")
                Text("手指轻碰表面并离开，位移小于阈值时触发。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("滑动识别").font(.headline)
                paramSlider("距离阈值", draft.params.threshold, 0.01...0.20, "%.2f")
                paramSlider("最大时长 ms", draft.params.maxDurationMs, 200...2000, "%.0f")
                Toggle("反转上下滑方向", isOn: draft.params.invert)
            }
        }
    }

    @ViewBuilder
    private func actionParams(_ draft: Binding<DraftBinding>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch draft.wrappedValue.kind {
            case "preset":
                Picker("", selection: draft.value) {
                    ForEach(0..<PresetActions.all.count, id: \.self) { i in
                        let item = PresetActions.all[i]
                        Text(item.1).tag(item.0)
                    }
                }
                .labelsHidden()

            case "openApp":
                TextField("bundle id 或 /Applications/xxx.app", text: draft.value)
                    .textFieldStyle(.roundedBorder)

            case "url":
                TextField("https://…", text: draft.value)
                    .textFieldStyle(.roundedBorder)

            case "shell":
                TextField("shell 命令", text: draft.value)
                    .textFieldStyle(.roundedBorder)

            case "keyShortcut":
                HStack(spacing: 6) {
                    Picker("", selection: draft.value) {
                        ForEach(0..<KeyMap.all.count, id: \.self) { i in
                            let key = KeyMap.all[i]
                            Text(key.0).tag(key.0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    ForEach(KeyMap.modifiers, id: \.self) { name in
                        modifierChip(name, draft: draft)
                    }
                    Spacer()
                }

            default:
                TextField("参数", text: draft.value)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func modifierChip(_ name: String, draft: Binding<DraftBinding>) -> some View {
        let on = draft.wrappedValue.modifiers.contains(name)
        return Button {
            if on {
                draft.wrappedValue.modifiers.removeAll { $0 == name }
            } else {
                draft.wrappedValue.modifiers.append(name)
            }
        } label: {
            Text(KeyMap.modifierSymbol(name))
                .font(.caption)
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(on ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08))
        )
        .foregroundStyle(on ? Color.white : Color.primary)
    }

    private func paramSlider(_ title: String, _ value: Binding<Double>,
                             _ range: ClosedRange<Double>, _ format: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: 全局参数

    private var globalPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("全局").font(.subheadline.weight(.semibold))
            HStack {
                Text("边缘范围").font(.caption).frame(width: 76, alignment: .leading)
                Slider(value: $tuning.edgeMargin, in: 0...0.3)
                Text(String(format: "%.2f", tuning.edgeMargin))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            Text("忽略靠近边缘的触点，防止手掌接触边缘造成误触。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("输出调试日志", isOn: $tuning.debug)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("恢复默认") { reset() }
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 绑定

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return drafts.firstIndex { $0.id == selection }
    }

    private func add() {
        let used = Set(drafts.map { "\($0.fingers)-\($0.gesture)" })
        let candidates = [3, 4, 5].flatMap { n in GestureType.all.map { (n, $0) } }
        let free = candidates.first { !used.contains("\($0.0)-\($0.1)") } ?? (3, "tap")

        // 点按默认应用网格，滑动默认无动作，避免新建后误触发
        let isTap = free.1 == "tap"
        let draft = DraftBinding(fingers: free.0,
                                 gesture: free.1,
                                 kind: "preset",
                                 value: isTap ? "apps" : "none",
                                 modifiers: [],
                                 params: BindingParams(from: tuning))
        drafts.append(draft)
        selection = draft.id          // 选中并滚动到可见位置，否则会被列表底部遮挡
    }

    private func remove(_ id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        if selection == id {
            selection = drafts.indices.contains(index) ? drafts[index].id : drafts.last?.id
        }
    }

    private func save() {
        var cfg = AppConfig()
        cfg.bindings = drafts.map { draft in
            var spec = draft.spec
            // 动作为空不写入配置，否则读回来的绑定不执行任何动作
            if spec.value.trimmingCharacters(in: .whitespaces).isEmpty {
                spec.value = defaultParams(for: spec.kind).value
            }
            return GestureBinding(fingers: draft.fingers,
                                  gesture: draft.gesture,
                                  action: spec,
                                  params: draft.params)
        }
        cfg.tuning = tuning

        ConfigStore.write(ConfigStore.serialize(cfg))
        onSave(cfg)

        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { toastVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeOut(duration: 0.22)) { toastVisible = false }
        }
    }

    private func reset() {
        guard let data = ConfigStore.defaultJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["bindings"] as? [[String: Any]] else { return }

        let defaults = TuningConfig()
        tuning = defaults
        drafts = list.compactMap { item in
            guard let action = ConfigStore.parseAction(item["action"]) else { return nil }
            return DraftBinding(fingers: item["fingers"] as? Int ?? 3,
                                gesture: item["gesture"] as? String ?? "tap",
                                kind: action.kind,
                                value: action.value,
                                modifiers: action.modifiers,
                                params: ConfigStore.parseParams(item["params"], fallback: defaults))
        }
        selection = drafts.first?.id
    }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView(config: config, onSave: onSave))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "SimpleTouch 设置"
        w.contentView = hosting
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
